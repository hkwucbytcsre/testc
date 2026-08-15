# SCX Leak Hotfix Design

## Goal

Provide an MT6989-specific, arm64 loadable kernel module that repairs the
missing `struct sched_ext_entity` destructor on the target OnePlus/Oplus
kernel without changing scheduler behavior or scanning already-orphaned slab
objects.

## Confirmed Target

- Source repository: `/root/android_kernel_oneplus_mt6989`
- Branch: `oneplus/mt6989_v_15.0.2_ace5_race`
- Source commit: `b1ea2c8ce2ef0f73927a593aa450f88143e3584a`
- Target release embedded in the supplied kernel image:
  `6.1.115-android14-oki-xiaoxiaow`
- Target image: `/root/scx-memlf/vmlinux`
- Target configuration confirms `CONFIG_SLIM_SCHED=y`,
  `CONFIG_SCHED_CLASS_EXT=y`, `CONFIG_TRACEPOINTS=y`,
  `CONFIG_ANDROID_VENDOR_HOOKS=y`, `CONFIG_MODVERSIONS=y`,
  `CONFIG_CFI_CLANG=y`, and `CONFIG_DEBUG_FS=y`.
- The supplied `vmlinux` is an ARM64 kernel `Image`, not an ELF `vmlinux`.
  It is useful for release/config/image validation but is not sufficient by
  itself to build a loadable module.

## Root Cause

The target vendor source changes `task_struct::scx` from an embedded
`struct sched_ext_entity` to an `ANDROID_KABI_USE()` pointer. `scx_pre_fork()`
allocates the entity with `kmalloc(sizeof(struct sched_ext_entity), GFP_KERNEL)`
and initializes `scx->task = p`. The target `scx_cancel_fork()` and
`sched_ext_free()` perform their SCX cleanup but do not free the pointer.

## Architecture

The module registers one callback on Android's exported
`android_vh_free_task` vendor hook. `free_task()` invokes this hook after
`sched_ext_free()` on normal task teardown and after `scx_cancel_fork()` on a
failed fork, but before releasing the `task_struct` itself. This provides one
common, final lifecycle point without return probes or text patching.

The callback:

1. Rejects a missing task pointer.
2. Reads `p->scx` with `READ_ONCE()`.
3. Rejects NULL.
4. Verifies `scx->task == p` as an ownership/layout sanity check.
5. Claims the pointer with `cmpxchg(&p->scx, scx, NULL)`.
6. Calls `kfree(scx)` only after the atomic claim succeeds.
7. Increments the free counter.

The callback does not allocate, sleep, scan slabs, patch kernel text, use
absolute addresses, or log per task. Unexpected ownership mismatches use
rate-limited warnings only. It runs once per final task destruction, not on
general syscall paths.

## ABI And Fail-Closed Policy

The module is intentionally not a generic SCX module. Build-time guards require
arm64, `CONFIG_SLIM_SCHED`, `CONFIG_SCHED_CLASS_EXT`, `CONFIG_TRACEPOINTS`, and
`CONFIG_ANDROID_VENDOR_HOOKS`. The MT6989 profile additionally checks the
expected `struct sched_ext_entity` and `struct module` sizes from the exact
source build.

Runtime preflight and module initialization reject a target when the required
configuration, symbols, or module ABI metadata are unavailable. The module
must be built using the exact target source branch, prepared generated headers,
matching `.config`, matching `Module.symvers`, and the Android Clang/LLVM
toolchain used for the target kernel. This repository includes a
`Module.symvers` reconstructed from the target image's export and CRC tables.

No fallback to kprobe, ftrace, or text-patch hooks is implemented when the
Android vendor hook is absent.
No attempt is made to reclaim objects belonging to tasks that died before the
module was loaded.

## Module Components

- `scx_leak_hotfix.c`: vendor-hook callback, transactional registration,
  counters, debugfs stats, and module metadata.
- `Makefile`: external-module build using `KDIR`, `O`, `LLVM`, and `ARCH`.
- `README.md`: exact build prerequisites, load/unload commands, deployment
  limits, and validation procedure.
- `profiles/mt6989_ace5_race.md`: source/image/config profile and known ABI
  requirements.
- `scripts/preflight.sh`: target and build-artifact checks with explicit
  PASS/FAIL output.
- `scripts/stress_test.sh`: controlled task churn and `processes`/
  `kmalloc-256` measurements.
- `scripts/collect_stats.sh`: meminfo, slabinfo, buddyinfo, extfrag, and
  module debugfs stats collection.
- `.github/workflows/build.yml`: reproducible cloud-build entry point that
  expects exact kernel source/build artifacts rather than guessing a kernel
  ABI.

## Observability

The module maintains atomic counters for hook calls, frees, NULL skips, owner
mismatches, claim races, and invalid task contexts. Debugfs stats
are exposed at:

`/sys/kernel/debug/scx_leak_hotfix/stats`

A valid deployment requires `owner_mismatch`, `claim_race`, and `bad_task` to
remain zero while `hook_calls` and `freed` increase during stress.

## Initialization And Removal

Initialization performs ABI checks, registers `android_vh_free_task`, then
creates debugfs. A debugfs failure rolls back the hook registration. Removal
unregisters the hook, calls `tracepoint_synchronize_unregister()`, removes
debugfs, and prints final counters.

Production deployment keeps the module resident and loads it early from
post-fs-data. `rmmod` is for development validation only; unloading resumes
the original leak for later tasks and does not recover previously orphaned
objects.

## Verification

Static verification checks source symbols, config guards, absence of hardcoded
addresses/offsets, and shell syntax. Build verification uses the exact
prepared kernel output and checks `modinfo`. Runtime verification requires:

- the Android vendor hook registered;
- five-minute task churn without warning, crash, UAF, double-free, slab/list
  corruption, or RCU stall;
- `owner_mismatch == 0`;
- `hook_calls` and `freed` increasing while tasks churn;
- `kmalloc-256` no longer growing approximately one object per created task;
- longer reboot and early-load validation before production use.

The vendor-hook v2 artifact is build-, ABI-, and runtime-verified. A 10096-task
run produced zero `kmalloc-256` growth and ended with 20313 successful frees,
all safety counters at zero, no kprobe entries, no pstore record, and no kernel
anomaly.
