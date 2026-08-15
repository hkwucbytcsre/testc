// SPDX-License-Identifier: GPL-2.0-only
/*
 * HMBIRD sched_ext entity leak hotfix (adapted from MT6989 SCX version).
 *
 * This module repairs the missing destructor in the HMBIRD scheduler:
 *   - hmbird_pre_fork() allocates a struct hmbird_entity for each new task.
 *   - hmbird_free() and hmbird_cancel_fork() do not free it.
 *
 * It is tied to the OnePlus/Oplus kernel with CONFIG_HMBIRD_SCHED=y.
 */
#include <linux/atomic.h>
#include <linux/build_bug.h>
#include <linux/debugfs.h>
#include <linux/err.h>
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/seq_file.h>
#include <linux/sched.h>
#include <linux/sched/hmbird.h>      /* HMBIRD scheduler definitions */
#include <linux/slab.h>
#include <linux/string.h>
#include <generated/utsrelease.h>

#ifndef CONFIG_ARM64
#error "scx_leak_hotfix supports arm64 only"
#endif

#ifndef CONFIG_HMBIRD_SCHED
#error "scx_leak_hotfix requires CONFIG_HMBIRD_SCHED"
#endif

#ifndef CONFIG_KPROBES
#error "scx_leak_hotfix requires CONFIG_KPROBES"
#endif

#ifndef CONFIG_KRETPROBES
#error "scx_leak_hotfix requires CONFIG_KRETPROBES"
#endif

#define HOTFIX_NAME                    "scx_leak_hotfix"
#define HOTFIX_TARGET_RELEASE          "6.6.118-android15-8-g29d86c5fc9dd-abogki428889875-4k"
/*
 * WARNING: HOTFIX_ENTITY_SIZE must be the exact sizeof(struct hmbird_entity).
 * The value 232 is only valid for the original SCX. For HMBIRD, it is larger.
 * Please measure the actual size on the target device and update this macro.
 * The static_assert below is temporarily disabled to allow compilation.
 */
#define HOTFIX_ENTITY_SIZE             288
#define HOTFIX_MODULE_SIZE             1536
#define HOTFIX_MAXACTIVE               256

static_assert(sizeof(struct hmbird_entity) == HOTFIX_ENTITY_SIZE);
static_assert(sizeof(struct module) == HOTFIX_MODULE_SIZE);
static_assert(__same_type(((struct task_struct *)0)->android_oem_data1[HMBIRD_TS_IDX],
			  struct hmbird_entity *));

struct hotfix_instance_data {
	struct task_struct *task;
};

struct hotfix_counters {
	atomic64_t freed_normal;
	atomic64_t freed_cancel;
	atomic64_t skipped_null;
	atomic64_t owner_mismatch;
	atomic64_t claim_race;
	atomic64_t bad_task;
};

static struct hotfix_counters counters = {
	.freed_normal = ATOMIC64_INIT(0),
	.freed_cancel = ATOMIC64_INIT(0),
	.skipped_null = ATOMIC64_INIT(0),
	.owner_mismatch = ATOMIC64_INIT(0),
	.claim_race = ATOMIC64_INIT(0),
	.bad_task = ATOMIC64_INIT(0),
};

static struct dentry *debugfs_root;
static bool hotfix_active;

static int hotfix_entry_handler(struct kretprobe_instance *ri,
				struct pt_regs *regs)
{
	struct hotfix_instance_data *data = (void *)ri->data;

	data->task = (struct task_struct *)regs->regs[0];
	return 0;
}
NOKPROBE_SYMBOL(hotfix_entry_handler);

static int hotfix_return_common(struct kretprobe_instance *ri,
				struct pt_regs *regs, atomic64_t *freed,
				const char *path)
{
	struct hotfix_instance_data *data = (void *)ri->data;
	struct hmbird_entity *ent;
	struct task_struct *task;

	(void)regs;
	task = READ_ONCE(data->task);
	if (unlikely(!task)) {
		atomic64_inc(&counters.bad_task);
		return 0;
	}

	/* HMBIRD stores the entity pointer in android_oem_data1[HMBIRD_TS_IDX] */
	ent = READ_ONCE(task->android_oem_data1[HMBIRD_TS_IDX]);
	if (!ent) {
		atomic64_inc(&counters.skipped_null);
		return 0;
	}

	if (unlikely(READ_ONCE(ent->task) != task)) {
		atomic64_inc(&counters.owner_mismatch);
		pr_warn_ratelimited(HOTFIX_NAME
			": %s ownership mismatch, refusing free\n", path);
		return 0;
	}

	if (unlikely(cmpxchg(&task->android_oem_data1[HMBIRD_TS_IDX],
			     ent, NULL) != ent)) {
		atomic64_inc(&counters.claim_race);
		return 0;
	}

	kfree(ent);
	atomic64_inc(freed);
	return 0;
}
NOKPROBE_SYMBOL(hotfix_return_common);

static int hotfix_free_return(struct kretprobe_instance *ri,
			      struct pt_regs *regs)
{
	return hotfix_return_common(ri, regs, &counters.freed_normal,
				    "hmbird_free");
}
NOKPROBE_SYMBOL(hotfix_free_return);

static int hotfix_cancel_return(struct kretprobe_instance *ri,
				struct pt_regs *regs)
{
	return hotfix_return_common(ri, regs, &counters.freed_cancel,
				    "hmbird_cancel_fork");
}
NOKPROBE_SYMBOL(hotfix_cancel_return);

static struct kretprobe free_probe = {
	.kp = {
		.symbol_name = "hmbird_free",
	},
	.handler = hotfix_free_return,
	.entry_handler = hotfix_entry_handler,
	.data_size = sizeof(struct hotfix_instance_data),
	.maxactive = HOTFIX_MAXACTIVE,
};

static struct kretprobe cancel_probe = {
	.kp = {
		.symbol_name = "hmbird_cancel_fork",
	},
	.handler = hotfix_cancel_return,
	.entry_handler = hotfix_entry_handler,
	.data_size = sizeof(struct hotfix_instance_data),
	.maxactive = HOTFIX_MAXACTIVE,
};

static int hotfix_stats_show(struct seq_file *m, void *unused)
{
	(void)unused;
	seq_printf(m, "active %u\n", READ_ONCE(hotfix_active));
	seq_printf(m, "freed_normal %lld\n",
		   atomic64_read(&counters.freed_normal));
	seq_printf(m, "freed_cancel %lld\n",
		   atomic64_read(&counters.freed_cancel));
	seq_printf(m, "skipped_null %lld\n",
		   atomic64_read(&counters.skipped_null));
	seq_printf(m, "owner_mismatch %lld\n",
		   atomic64_read(&counters.owner_mismatch));
	seq_printf(m, "claim_race %lld\n",
		   atomic64_read(&counters.claim_race));
	seq_printf(m, "bad_task %lld\n",
		   atomic64_read(&counters.bad_task));
	seq_printf(m, "normal_nmissed %d\n", READ_ONCE(free_probe.nmissed));
	seq_printf(m, "cancel_nmissed %d\n", READ_ONCE(cancel_probe.nmissed));
	seq_printf(m, "maxactive %d\n", HOTFIX_MAXACTIVE);
	return 0;
}

DEFINE_SHOW_ATTRIBUTE(hotfix_stats);

static int hotfix_debugfs_init(void)
{
	struct dentry *stats;

	debugfs_root = debugfs_create_dir(HOTFIX_NAME, NULL);
	if (IS_ERR(debugfs_root))
		return PTR_ERR(debugfs_root);
	if (!debugfs_root)
		return -ENOMEM;

	stats = debugfs_create_file("stats", 0444, debugfs_root, NULL,
				    &hotfix_stats_fops);
	if (IS_ERR(stats)) {
		debugfs_remove_recursive(debugfs_root);
		debugfs_root = NULL;
		return PTR_ERR(stats);
	}
	if (!stats) {
		debugfs_remove_recursive(debugfs_root);
		debugfs_root = NULL;
		return -ENOMEM;
	}

	return 0;
}

static int __init hotfix_init(void)
{
	int ret;

	if (strcmp(UTS_RELEASE, HOTFIX_TARGET_RELEASE)) {
		pr_err(HOTFIX_NAME ": built for %s, not %s\n",
		       HOTFIX_TARGET_RELEASE, UTS_RELEASE);
		return -EINVAL;
	}

	ret = register_kretprobe(&free_probe);
	if (ret) {
		pr_err(HOTFIX_NAME ": hmbird_free probe failed: %d\n", ret);
		return ret;
	}

	ret = register_kretprobe(&cancel_probe);
	if (ret) {
		pr_err(HOTFIX_NAME ": hmbird_cancel_fork probe failed: %d\n", ret);
		goto unregister_free;
	}

	ret = hotfix_debugfs_init();
	if (ret) {
		pr_err(HOTFIX_NAME ": debugfs setup failed: %d\n", ret);
		goto unregister_cancel;
	}

	WRITE_ONCE(hotfix_active, true);
	pr_info(HOTFIX_NAME ": active, release=%s maxactive=%d\n",
		UTS_RELEASE, HOTFIX_MAXACTIVE);
	return 0;

unregister_cancel:
	unregister_kretprobe(&cancel_probe);
unregister_free:
	unregister_kretprobe(&free_probe);
	return ret;
}

static void __exit hotfix_exit(void)
{
	WRITE_ONCE(hotfix_active, false);
	debugfs_remove_recursive(debugfs_root);
	debugfs_root = NULL;
	unregister_kretprobe(&cancel_probe);
	unregister_kretprobe(&free_probe);

	pr_info(HOTFIX_NAME
		": removed normal=%lld cancel=%lld null=%lld owner=%lld race=%lld bad=%lld nmissed=%d/%d\n",
		atomic64_read(&counters.freed_normal),
		atomic64_read(&counters.freed_cancel),
		atomic64_read(&counters.skipped_null),
		atomic64_read(&counters.owner_mismatch),
		atomic64_read(&counters.claim_race),
		atomic64_read(&counters.bad_task), READ_ONCE(free_probe.nmissed),
		READ_ONCE(cancel_probe.nmissed));
}

module_init(hotfix_init);
module_exit(hotfix_exit);

MODULE_AUTHOR("scx-memlf contributors (HMBIRD adaptation)");
MODULE_DESCRIPTION("HMBIRD sched_ext entity leak hotfix");
MODULE_LICENSE("GPL");
MODULE_VERSION("1.0.0-hmbird");
MODULE_INFO(target_release, HOTFIX_TARGET_RELEASE);
MODULE_INFO(target_entity_size, __stringify(HOTFIX_ENTITY_SIZE));
MODULE_INFO(target_module_size, __stringify(HOTFIX_MODULE_SIZE));