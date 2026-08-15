# Target Profile: MT6989 (OnePlus Ace 5 Racing)

This module is built for exactly one kernel. Loading it elsewhere is refused
at initialisation.

## Kernel

| Property | Value |
|---|---|
| Release | `6.1.115-android14-oki-xiaoxiaow` |
| Base | `6.1.115` (android14 GKI, OKI variant) |
| Arch | `arm64` |
| Builder | `xiaoxiaow@xiaoxiaow_build` |
| Toolchain | Android Clang r487747c, clang 17.0.2, LLD 17.0.2 (+pgo +bolt +lto) |
| vermagic | `6.1.115-android14-oki-xiaoxiaow SMP preempt mod_unload modversions aarch64` |

## Source

| Property | Value |
|---|---|
| Kernel repo | `OnePlusOSS/android_kernel_oneplus_mt6989` |
| Branch | `oneplus/mt6989_v_15.0.2_ace5_race` |
| Commit | `b1ea2c8ce2ef0f73927a593aa450f88143e3584a` |
| Vendor modules repo | `OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_mt6989` (same branch) |

The vendor modules repo is required: the kernel tree carries dangling symlinks
into `../vendor/...` (for example `drivers/soc/oplus/oplus_resctrl`) that must
resolve before `modules_prepare` will run.

All of the values below were recovered from the kernel image and a rooted
device, without any vendor build artifacts. Reproduce with
`make extract KDIR=...`; see the README's "Recovering build inputs" section.

## Configuration

Extracted from the target image with `scripts/extract-ikconfig`.

### The LOCALVERSION trap

`CONFIG_LOCALVERSION` is **empty** in this config even though the release is
`6.1.115-android14-oki-xiaoxiaow`, and `CONFIG_LOCALVERSION_AUTO=y`. The vendor
passed the suffix on the make command line.

Build with the config as extracted and `scripts/setlocalversion` fills the gap
from git instead, producing `6.1.115-g<sha>`. The module then builds cleanly and
`insmod` fails with `-ENOEXEC` on a vermagic mismatch. Set both explicitly:

```sh
./scripts/config --file .config \
  --set-str LOCALVERSION "-android14-oki-xiaoxiaow" \
  --disable LOCALVERSION_AUTO
```

Passing `LOCALVERSION=` on the make command line is *not* enough on its own: it
clears the make variable but `LOCALVERSION_AUTO` still appends the git
description.

Disabling `LOCALVERSION_AUTO` also drops `CONFIG_MODULE_SCMVERSION`, which
depends on it. That is harmless here — `scmversion` is an unconditional member
of `struct module` in this tree, so the size is unaffected.

| Option | Value | Why it matters |
|---|---|---|
| `CONFIG_SLIM_SCHED` | `y` | Gates the vendor `sched_ext` fork paths |
| `CONFIG_SCHED_CLASS_EXT` | `y` | `sched_ext` present |
| `CONFIG_TRACEPOINTS` | `y` | Android vendor-hook transport |
| `CONFIG_ANDROID_VENDOR_HOOKS` | `y` | Exposes `android_vh_free_task` |
| `CONFIG_MODVERSIONS` | `y` | Symbol CRCs must match the target exactly |
| `CONFIG_MODULE_SIG_FORCE` | not set | Unsigned modules load |
| `CONFIG_CFI_CLANG` | `y` | KCFI; indirect-call type ids must agree |
| `CONFIG_LTO_NONE` | `y` | No LTO, so a plain external module build is valid |
| `CONFIG_DEBUG_FS` | `y` | Stats file |
| `CONFIG_KSU_SUSFS_SPOOF_UNAME` | `y` | **`uname -r` is spoofed**, see below |

### uname spoofing

susfs rewrites the `uname()` syscall to return the upstream GKI string
`6.1.115-android14-11-g2d2543bebccf-ab12401295`. The real release is visible in
`/proc/sys/kernel/osrelease` and `/proc/version`, and the module compares
against its own compile-time `UTS_RELEASE`. Any tooling that gates on
`uname -r` will produce a false mismatch.

## Hook Lifecycle

The production module uses the exported `android_vh_free_task` vendor hook,
not kprobes. Its location in generic task teardown is intentional:

```text
normal exit:
  __put_task_struct()
    sched_ext_free(task)
    free_task(task)
      trace_android_vh_free_task(task) -> module callback
      free_task_struct(task)

failed fork:
  sched_cancel_fork(task)
    scx_cancel_fork(task)
  delayed_free_task(task)
    free_task(task)
      trace_android_vh_free_task(task) -> module callback
      free_task_struct(task)
```

Thus both SCX cleanup paths have completed, while `task` and `task->scx` are
still addressable. The callback validates `scx->task == task`, atomically
changes `task->scx` to NULL, then frees the owned allocation. Hook removal is
followed by `tracepoint_synchronize_unregister()` so module text cannot be
freed while a callback is still running.

## ABI Facts

Verified against the target's BTF and by dumping the module's own record
layouts with `-Xclang -fdump-record-layouts`.

| Item | Value |
|---|---|
| `sizeof(struct sched_ext_entity)` | 232 |
| `task_struct::scx` | `struct sched_ext_entity *`, via `ANDROID_KABI_USE(3)` |
| `sizeof(struct module)` | 1088 |

`sizeof(struct module)` is the trap. It is 1088 only when
`CONFIG_DEBUG_INFO_BTF_MODULES` is enabled, which adds the `btf_data_size` and
`btf_data` members:

```c
#ifdef CONFIG_DEBUG_INFO_BTF_MODULES
	unsigned int btf_data_size;
	void *btf_data;
#endif
```

Building without it yields 1072. The kernel then writes past the module's
`__this_module` section during `mod_sysfs_setup()` and panics the device —
the module loads first and dies afterwards, so a successful `insmod` is not
evidence of a correct layout.

Enabling `CONFIG_DEBUG_INFO_BTF_MODULES` requires `pahole`, so the build host
needs `dwarves` installed. Note that `CONFIG_MODULE_SCMVERSION` does *not*
affect the size in this tree: `scmversion` is an unconditional member, unlike
in upstream where it sits behind an `#ifdef`.

The general lesson: every layout-affecting option must match the target
config, not just the ones that look scheduler-related. Verify rather than
assume:

```sh
make check-layout KDIR=/path/to/kernel
```

That compares your build's record layouts against the target's own BTF. Both
structs check out at 70/70 and 18/18 members for this target.

## Symbol CRCs

`CONFIG_MODVERSIONS=y` means every imported symbol's CRC must match the target
exactly, and `Module.symvers` is a build artifact the vendor never ships. It was
recovered from the image's `__ksymtab`/`__kcrctab` sections instead:

| Item | Value |
|---|---|
| Exported symbols recovered | 15242 |
| Address cross-check vs kallsyms | 15242/15242 |
| Imported by vendor-hook v2 | 19, all matching |

Two config facts make this work: `CONFIG_HAVE_ARCH_PREL32_RELOCATIONS=y` on
arm64, so each `kernel_symbol` is three self-relative `s32` offsets rather than
64-bit pointers; and `CONFIG_MODULE_REL_CRCS` unset, so `__kcrctab` holds
absolute CRC values. See `tools/gen_symvers.py`.

## Leaking Code Path

`scx_pre_fork()` allocates:

```c
p->scx = kmalloc(sizeof(struct sched_ext_entity), GFP_KERNEL);
p->scx->task = p;
```

Neither `sched_ext_free()` (normal exit, called from `free_task()`) nor
`scx_cancel_fork()` (failed fork) frees it. One 256-byte `kmalloc-256` object
leaks per created task.

`scx->task` back-pointing at the owning `task_struct` is what makes the fix
safe: the module verifies ownership before freeing.

## Verification Status

The vendor-hook v2 artifact is build-, ABI-, and runtime-verified. Its 19
symbol CRCs match the target and its only hook-specific imports are the
exported `android_vh_free_task` tracepoint plus tracepoint registration APIs.

3000 `/bin/true` invocations, `kmalloc-256` active object delta:

| State | Tasks created | kmalloc-256 growth | Leak ratio |
|---|---|---|---|
| Unloaded v1 baseline | 3045 | +3098 | ~102% |
| Vendor-hook v2, first run | 3518 | +155 | 4% |
| Vendor-hook v2, long run | 10096 | -64 | 0% |

After the long run v2 had processed and freed 20313 entities. All safety
counters were zero; the kprobe list contained no hotfix entries, pstore was
empty, and no kernel anomaly was observed.
