// SPDX-License-Identifier: GPL-2.0-only
/*
 * MT6989 sched_ext entity leak hotfix.
 *
 * This module is intentionally tied to the profiled OnePlus/Oplus kernel.  It
 * repairs the missing destructor after the vendor's original cleanup returns.
 */
#include <linux/atomic.h>
#include <linux/build_bug.h>
#include <linux/debugfs.h>
#include <linux/err.h>
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/seq_file.h>
#include <linux/sched.h>
#include <linux/sched/ext.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <generated/utsrelease.h>

#ifndef CONFIG_ARM64
#error "scx_leak_hotfix supports arm64 only"
#endif

#ifndef CONFIG_SLIM_SCHED
#error "scx_leak_hotfix requires CONFIG_SLIM_SCHED"
#endif

#ifndef CONFIG_SCHED_CLASS_EXT
#error "scx_leak_hotfix requires CONFIG_SCHED_CLASS_EXT"
#endif

#ifndef CONFIG_KPROBES
#error "scx_leak_hotfix requires CONFIG_KPROBES"
#endif

#ifndef CONFIG_KRETPROBES
#error "scx_leak_hotfix requires CONFIG_KRETPROBES"
#endif

#define HOTFIX_NAME                    "scx_leak_hotfix"
#define HOTFIX_TARGET_RELEASE          "6.6.118-android15-8-g29d86c5fc9dd-abogki428889875-4k"
#define HOTFIX_ENTITY_SIZE             232
#define HOTFIX_MODULE_SIZE             1536
#define HOTFIX_MAXACTIVE               256

static_assert(sizeof(struct sched_ext_entity) == HOTFIX_ENTITY_SIZE);
static_assert(sizeof(struct module) == HOTFIX_MODULE_SIZE);
static_assert(__same_type(((struct task_struct *)0)->scx,
			  struct sched_ext_entity *));

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
	struct sched_ext_entity *scx;
	struct task_struct *task;

	(void)regs;
	task = READ_ONCE(data->task);
	if (unlikely(!task)) {
		atomic64_inc(&counters.bad_task);
		return 0;
	}

	scx = READ_ONCE(task->scx);
	if (!scx) {
		atomic64_inc(&counters.skipped_null);
		return 0;
	}

	if (unlikely(READ_ONCE(scx->task) != task)) {
		atomic64_inc(&counters.owner_mismatch);
		pr_warn_ratelimited(HOTFIX_NAME
			": %s ownership mismatch, refusing free\n", path);
		return 0;
	}

	if (unlikely(cmpxchg(&task->scx, scx, NULL) != scx)) {
		atomic64_inc(&counters.claim_race);
		return 0;
	}

	kfree(scx);
	atomic64_inc(freed);
	return 0;
}
NOKPROBE_SYMBOL(hotfix_return_common);

static int hotfix_free_return(struct kretprobe_instance *ri,
			      struct pt_regs *regs)
{
	return hotfix_return_common(ri, regs, &counters.freed_normal,
				    "sched_ext_free");
}
NOKPROBE_SYMBOL(hotfix_free_return);

static int hotfix_cancel_return(struct kretprobe_instance *ri,
				struct pt_regs *regs)
{
	return hotfix_return_common(ri, regs, &counters.freed_cancel,
				    "scx_cancel_fork");
}
NOKPROBE_SYMBOL(hotfix_cancel_return);

static struct kretprobe free_probe = {
	.kp = {
		.symbol_name = "sched_ext_free",
	},
	.handler = hotfix_free_return,
	.entry_handler = hotfix_entry_handler,
	.data_size = sizeof(struct hotfix_instance_data),
	.maxactive = HOTFIX_MAXACTIVE,
};

static struct kretprobe cancel_probe = {
	.kp = {
		.symbol_name = "scx_cancel_fork",
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
		pr_err(HOTFIX_NAME ": sched_ext_free probe failed: %d\n", ret);
		return ret;
	}

	ret = register_kretprobe(&cancel_probe);
	if (ret) {
		pr_err(HOTFIX_NAME ": scx_cancel_fork probe failed: %d\n", ret);
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

MODULE_AUTHOR("scx-memlf contributors");
MODULE_DESCRIPTION("MT6989 sched_ext entity leak hotfix");
MODULE_LICENSE("GPL");
MODULE_VERSION("1.0.0");
MODULE_INFO(target_release, HOTFIX_TARGET_RELEASE);
MODULE_INFO(target_scx_size, __stringify(HOTFIX_ENTITY_SIZE));
MODULE_INFO(target_module_size, __stringify(HOTFIX_MODULE_SIZE));
