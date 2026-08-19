// SPDX-License-Identifier: GPL-2.0-only
/*
 * HMBIRD sched_ext entity leak hotfix (Vendor Hook version).
 *
 * This module registers on android_vh_free_task, which is called inside
 * free_task() after all HMBIRD cleanup has completed, and before the
 * task_struct itself is freed. This is the safe point to kfree the per-task
 * hmbird_entity.
 *
 * For SM8750/HMBIRD kernel with CONFIG_ANDROID_VENDOR_HOOKS=y.
 */
#include <linux/atomic.h>
#include <linux/build_bug.h>
#include <linux/debugfs.h>
#include <linux/err.h>
#include <linux/module.h>
#include <linux/seq_file.h>
#include <linux/sched.h>
#include <linux/sched/hmbird.h>      /* HMBIRD scheduler definitions */
#include <linux/slab.h>
#include <linux/string.h>
#include <trace/hooks/sched.h>
#include <generated/utsrelease.h>

#ifndef CONFIG_ARM64
#error "scx_leak_hotfix supports arm64 only"
#endif

#ifndef CONFIG_HMBIRD_SCHED
#error "scx_leak_hotfix requires CONFIG_HMBIRD_SCHED"
#endif

#ifndef CONFIG_TRACEPOINTS
#error "scx_leak_hotfix requires CONFIG_TRACEPOINTS"
#endif

#ifndef CONFIG_ANDROID_VENDOR_HOOKS
#error "scx_leak_hotfix requires CONFIG_ANDROID_VENDOR_HOOKS"
#endif

#define HOTFIX_NAME                    "scx_leak_hotfix"
#define HOTFIX_TARGET_RELEASE          "6.6.118-android15-8-g29d86c5fc9dd-abogki428889875-4k"
#define HOTFIX_ENTITY_SIZE             288      /* from BTF: sizeof(struct hmbird_entity) = 288 */
#define HOTFIX_MODULE_SIZE             1536     /* from compile error: sizeof(struct module) = 1536 */

static_assert(sizeof(struct hmbird_entity) == HOTFIX_ENTITY_SIZE);
static_assert(sizeof(struct module) == HOTFIX_MODULE_SIZE);

struct hotfix_counters {
	atomic64_t hook_calls;
	atomic64_t freed;
	atomic64_t skipped_null;
	atomic64_t owner_mismatch;
	atomic64_t claim_race;
	atomic64_t bad_task;
};

static struct hotfix_counters counters = {
	.hook_calls = ATOMIC64_INIT(0),
	.freed = ATOMIC64_INIT(0),
	.skipped_null = ATOMIC64_INIT(0),
	.owner_mismatch = ATOMIC64_INIT(0),
	.claim_race = ATOMIC64_INIT(0),
	.bad_task = ATOMIC64_INIT(0),
};

static struct dentry *debugfs_root;
static bool hotfix_active;

static void hotfix_free_task(void *unused, struct task_struct *task)
{
	unsigned long old_ptr;
	struct hmbird_entity *ent;

	(void)unused;
	atomic64_inc(&counters.hook_calls);

	if (unlikely(!task)) {
		atomic64_inc(&counters.bad_task);
		return;
	}

	/* HMBIRD stores entity pointer in android_oem_data1[HMBIRD_TS_IDX] */
	old_ptr = READ_ONCE(task->android_oem_data1[HMBIRD_TS_IDX]);
	if (!old_ptr) {
		atomic64_inc(&counters.skipped_null);
		return;
	}

	ent = (struct hmbird_entity *)old_ptr;

	if (unlikely(READ_ONCE(ent->task) != task)) {
		atomic64_inc(&counters.owner_mismatch);
		pr_warn_ratelimited(HOTFIX_NAME
			": ownership mismatch, refusing free\n");
		return;
	}

	if (unlikely(cmpxchg(&task->android_oem_data1[HMBIRD_TS_IDX],
			     old_ptr, 0) != old_ptr)) {
		atomic64_inc(&counters.claim_race);
		return;
	}

	kfree(ent);
	atomic64_inc(&counters.freed);
}

static int hotfix_stats_show(struct seq_file *m, void *unused)
{
	(void)unused;
	seq_printf(m, "active %u\n", READ_ONCE(hotfix_active));
	seq_printf(m, "hook_calls %lld\n",
		   atomic64_read(&counters.hook_calls));
	seq_printf(m, "freed %lld\n", atomic64_read(&counters.freed));
	seq_printf(m, "skipped_null %lld\n",
		   atomic64_read(&counters.skipped_null));
	seq_printf(m, "owner_mismatch %lld\n",
		   atomic64_read(&counters.owner_mismatch));
	seq_printf(m, "claim_race %lld\n",
		   atomic64_read(&counters.claim_race));
	seq_printf(m, "bad_task %lld\n",
		   atomic64_read(&counters.bad_task));
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

	ret = register_trace_android_vh_free_task(hotfix_free_task, NULL);
	if (ret) {
		pr_err(HOTFIX_NAME ": android_vh_free_task registration failed: %d\n",
		       ret);
		return ret;
	}

	ret = hotfix_debugfs_init();
	if (ret) {
		pr_err(HOTFIX_NAME ": debugfs setup failed: %d\n", ret);
		goto unregister_hook;
	}

	WRITE_ONCE(hotfix_active, true);
	pr_info(HOTFIX_NAME ": active via android_vh_free_task, release=%s\n",
		UTS_RELEASE);
	return 0;

unregister_hook:
	unregister_trace_android_vh_free_task(hotfix_free_task, NULL);
	tracepoint_synchronize_unregister();
	return ret;
}

static void __exit hotfix_exit(void)
{
	WRITE_ONCE(hotfix_active, false);
	unregister_trace_android_vh_free_task(hotfix_free_task, NULL);
	tracepoint_synchronize_unregister();
	debugfs_remove_recursive(debugfs_root);
	debugfs_root = NULL;

	pr_info(HOTFIX_NAME
		": removed calls=%lld freed=%lld null=%lld owner=%lld race=%lld bad=%lld\n",
		atomic64_read(&counters.hook_calls),
		atomic64_read(&counters.freed),
		atomic64_read(&counters.skipped_null),
		atomic64_read(&counters.owner_mismatch),
		atomic64_read(&counters.claim_race),
		atomic64_read(&counters.bad_task));
}

module_init(hotfix_init);
module_exit(hotfix_exit);

MODULE_AUTHOR("scx-memlf contributors (HMBIRD Vendor Hook adaptation)");
MODULE_DESCRIPTION("HMBIRD sched_ext entity leak hotfix via Android vendor hook");
MODULE_LICENSE("GPL");
MODULE_VERSION("2.0.0-hmbird-vh");
MODULE_INFO(target_release, HOTFIX_TARGET_RELEASE);
MODULE_INFO(target_entity_size, __stringify(HOTFIX_ENTITY_SIZE));
MODULE_INFO(target_module_size, __stringify(HOTFIX_MODULE_SIZE));