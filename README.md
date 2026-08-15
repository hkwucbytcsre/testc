# scx_leak_hotfix

A loadable kernel module that stops a `sched_ext` memory leak on the OnePlus
Ace 5 Racing (MT6989) kernel `6.1.115-android14-oki-xiaoxiaow`.

## The bug

The vendor kernel moves `task_struct::scx` from an embedded struct to a
heap pointer via `ANDROID_KABI_USE(3)`. `scx_pre_fork()` allocates a
232-byte `struct sched_ext_entity` for every task, but neither cleanup path
frees it:

- `sched_ext_free()` — normal task teardown, from `free_task()`
- `scx_cancel_fork()` — failed fork

Result: one leaked `kmalloc-256` object per created task. On this device that
measured as ~102% growth, i.e. essentially exact 1:1 leakage.

## The fix

Two symbol-based kretprobes run *after* the vendor's original cleanup returns,
so the module never races or duplicates existing work. Each return handler:

1. recovers the `task_struct *` its entry handler saved from `regs->regs[0]`
2. reads `p->scx` with `READ_ONCE()`, skipping NULL
3. verifies `scx->task == p` — ownership and layout sanity in one check
4. claims the pointer with `cmpxchg(&p->scx, scx, NULL)`
5. calls `kfree(scx)` only after the claim succeeds

No allocation, no sleeping, no slab scanning, no text patching, no hardcoded
addresses or offsets. Unexpected states increment a counter and, for ownership
mismatches, emit a rate-limited warning.

The module does not reclaim objects orphaned by tasks that died before it was
loaded. It only prevents new leaks.

## Requirements

Build and load require the exact target. See
[`profiles/mt6989_ace5_race.md`](profiles/mt6989_ace5_race.md) for the full
profile, including the two non-obvious traps: `uname -r` is spoofed by susfs,
and `sizeof(struct module)` is 1088 only with `CONFIG_DEBUG_INFO_BTF_MODULES`
enabled. Get the latter wrong and the module loads, then panics the device in
`mod_sysfs_setup()`.

You need:

- kernel source at commit `b1ea2c8ce2ef0f73927a593aa450f88143e3584a`, branch
  `oneplus/mt6989_v_15.0.2_ace5_race`
- the matching vendor modules repo checked out so the tree's `../vendor/...`
  symlinks resolve
- the target `.config`, with `CONFIG_DEBUG_INFO_BTF_MODULES=y` surviving
  `olddefconfig`
- `dwarves` on the build host, since that option needs `pahole`
- `Module.symvers` with CRCs matching the running kernel
- Android Clang r487747c

The last two are build artifacts the vendor does not ship. Both are recoverable
from the kernel image alone — see [Recovering build inputs](#recovering-build-inputs).
Pre-extracted copies for this target are checked in under `ci/`.

## Build

```sh
make KDIR=/path/to/android_kernel_oneplus_mt6989
```

Prepare the kernel tree first:

```sh
cd "$KDIR"
cp /path/to/scx-memlf/ci/target.config .config
cp /path/to/scx-memlf/ci/Module.symvers Module.symvers

# The extracted config has CONFIG_LOCALVERSION="" with LOCALVERSION_AUTO=y;
# the vendor passed the suffix on the command line. Without both lines below,
# setlocalversion substitutes a git description and insmod fails on vermagic.
./scripts/config --file .config \
  --set-str LOCALVERSION "-android14-oki-xiaoxiaow" \
  --disable LOCALVERSION_AUTO

make ARCH=arm64 LLVM=1 LOCALVERSION= olddefconfig
make ARCH=arm64 LLVM=1 LOCALVERSION= -j"$(nproc)" modules_prepare
```

Confirm the release before building the module:

```sh
cat include/config/kernel.release
# 6.1.115-android14-oki-xiaoxiaow
```

A full kernel build is *not* needed; `modules_prepare` is enough.

Verify the artifact before going near a device:

```sh
make verify        # vermagic, symbol CRCs, and __this_module section size
make check-layout  # struct layouts against the target kernel's own BTF
```

`make verify` alone is not sufficient. A module can have perfect CRCs and
vermagic yet still panic the device if a struct layout differs, so run both.

## Recovering build inputs

No vendor build tree is required. Everything needed comes from the kernel
image plus a rooted device.

```sh
make extract KDIR=/path/to/kernel   # writes ci/target.config and ci/Module.symvers
```

Or directly:

```sh
sh tools/extract_target.sh /path/to/kernel /path/to/Image ci
```

How each piece is recovered:

| Input | Source | Tool |
|---|---|---|
| `.config` | `IKCONFIG` blob embedded in the image | `scripts/extract-ikconfig` |
| release, vermagic, toolchain | version banner strings in the image | `tools/extract_target.sh` |
| `Module.symvers` | `__ksymtab`/`__kcrctab` in the image, located via `/proc/kallsyms` | `tools/gen_symvers.py` |
| struct layouts | target's `/sys/kernel/btf/vmlinux` | `tools/check_struct_layout.sh` |

The CRC recovery is the interesting one. With `CONFIG_MODVERSIONS=y` the kernel
rejects any module whose symbol CRCs disagree, and `Module.symvers` is a build
artifact that is never shipped. But the CRCs live in the image: `__kcrctab` sits
alongside `__ksymtab`, and `/proc/kallsyms` gives their addresses. On arm64 each
`kernel_symbol` entry is three PREL32 self-relative offsets, so the table can be
walked directly. `tools/gen_symvers.py` cross-checks every recovered address
against kallsyms and refuses to emit a table if any disagree — 15242/15242
matched for this target, and the result was byte-identical to a table validated
by a successful `insmod`.

Two prerequisites: `/proc/sys/kernel/kptr_restrict` must be 0, or kallsyms
addresses read as zero; and the image must be the raw decompressed `Image`.

### Tools

| Tool | Purpose |
|---|---|
| `tools/extract_target.sh` | Recover all build inputs from an image; flags layout-critical options |
| `tools/gen_symvers.py` | Rebuild `Module.symvers` from image + kallsyms, with address verification |
| `tools/verify_ko.py` | Check a built `.ko`: vermagic, CRCs, `__this_module` size, undefined symbols |
| `tools/check_struct_layout.sh` | Diff any struct's layout between your build and the target's BTF |

## Load

```sh
sh scripts/preflight.sh          # refuses to pass on a mismatched target
insmod scx_leak_hotfix.ko
mount -t debugfs debugfs /sys/kernel/debug   # only needed for stats
cat /sys/kernel/debug/scx_leak_hotfix/stats
```

`insmod` returning `-EINVAL` means the module's compile-time `UTS_RELEASE` did
not match the running kernel. That is the intended fail-closed behaviour.

debugfs being unmounted does not disable the fix. `debugfs_create_dir()`
returns a placeholder rather than an error, so the probes still run; only the
stats file is missing.

## Verify

```sh
make test                         # static source safety checks
make stress                       # expects leak ratio near 0%
make stats                        # memory and fragmentation snapshot
```

To confirm causality, run the stress test with the module unloaded first. The
ratio should be near 100%, then near 0% once loaded.

Acceptance criteria for a deployment:

- both probes registered (module reaches `Live`)
- `owner_mismatch` stays 0
- `normal_nmissed` and `cancel_nmissed` stay 0
- free counters climb in step with task creation
- `kmalloc-256` no longer grows ~1 object per task
- no `BUG:`, `Oops`, UAF, double-free, slab corruption or RCU stall in dmesg

## Stats fields

| Field | Meaning |
|---|---|
| `active` | Probes registered |
| `freed_normal` | Entities freed on the `sched_ext_free` path |
| `freed_cancel` | Entities freed on the `scx_cancel_fork` path |
| `skipped_null` | `p->scx` already NULL, nothing to do |
| `owner_mismatch` | `scx->task != p`; refused to free. Must stay 0 |
| `claim_race` | Lost the `cmpxchg`; another actor claimed it |
| `bad_task` | No task pointer in probe context |
| `normal_nmissed` / `cancel_nmissed` | kretprobe misses; raise `maxactive` if nonzero |

`freed_cancel` staying 0 is normal — fork failures are rare, and on this kernel
`copy_process()` reaches `free_task()` after `sched_cancel_fork()`, so the
`sched_ext_free` probe covers most of that path anyway.

## Removal

```sh
rmmod scx_leak_hotfix
```

Unloading resumes the leak for tasks created afterwards. For production, load
early from post-fs-data and leave it resident. `rmmod` is for development
validation.

## Measured results

3000 `/bin/true` invocations on the target device:

| State | Tasks created | kmalloc-256 growth | Leak ratio |
|---|---|---|---|
| Unloaded | 3045 | +3098 | ~102% |
| Loaded | 3195 | -14 | 0% |

Across 10359 tasks with the module loaded, growth was +5 objects, with all
error counters at zero.
