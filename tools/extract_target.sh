#!/bin/sh
# Extract the exact build inputs from a target kernel image or a live device.
#
# Building a loadable module for a vendor kernel needs three things the vendor
# does not ship: the kernel .config, the symbol CRC table, and the exact
# release string. All three can be recovered without the vendor's build tree.
#
# Usage:
#   tools/extract_target.sh <KDIR> <Image> [outdir] [kallsyms]
#
#   KDIR      kernel source tree (for scripts/extract-ikconfig)
#   Image     raw decompressed arm64 kernel Image
#   outdir    where to write target.config and Module.symvers (default: ci)
#   kallsyms  symbol source (default: /proc/kallsyms, i.e. run this on target)
#
# Module.symvers recovery reads the CRCs out of the image itself, so the
# kallsyms source must describe the same kernel as the image.
set -eu

KDIR="${1:?usage: extract_target.sh <KDIR> <Image> [outdir] [kallsyms]}"
IMAGE="${2:?usage: extract_target.sh <KDIR> <Image> [outdir] [kallsyms]}"
OUTDIR="${3:-ci}"
KALLSYMS="${4:-/proc/kallsyms}"

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
old_kptr_restrict=""

restore_kptr_restrict()
{
	if [ -n "$old_kptr_restrict" ] &&
	   [ -w /proc/sys/kernel/kptr_restrict ]; then
		echo "$old_kptr_restrict" > /proc/sys/kernel/kptr_restrict
		printf 'restored kernel.kptr_restrict=%s\n' "$old_kptr_restrict"
	fi
}

trap restore_kptr_restrict EXIT HUP INT TERM

if [ ! -x "$KDIR/scripts/extract-ikconfig" ]; then
	printf 'error: %s/scripts/extract-ikconfig not found\n' "$KDIR" >&2
	exit 1
fi
if [ ! -f "$IMAGE" ]; then
	printf 'error: no such image: %s\n' "$IMAGE" >&2
	exit 1
fi

mkdir -p "$OUTDIR"

printf '=== kernel configuration ===\n'
if "$KDIR/scripts/extract-ikconfig" "$IMAGE" > "$OUTDIR/target.config"; then
	printf 'wrote %s (%s lines)\n' "$OUTDIR/target.config" \
		"$(wc -l < "$OUTDIR/target.config")"
else
	printf 'error: extract-ikconfig failed; is CONFIG_IKCONFIG_PROC=y?\n' >&2
	exit 1
fi

printf '\n=== release and vermagic ===\n'
# Do not derive the release from CONFIG_LOCALVERSION: vendors often pass
# LOCALVERSION on the make command line instead, leaving the config empty even
# though the real release carries a suffix. The image's own banner and vermagic
# strings are authoritative.
banner=$(strings -a "$IMAGE" | grep -m1 '^Linux version ' || true)
release=$(printf '%s\n' "$banner" | awk '{print $3}')
vermagic=$(strings -a "$IMAGE" |
	grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+.* SMP .*aarch64$' || true)
printf 'release  = %s\n' "${release:-unknown}"
printf 'vermagic = %s\n' "${vermagic:-unknown}"
localversion=$(grep -E '^CONFIG_LOCALVERSION=' "$OUTDIR/target.config" |
	sed 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/')
base=$(printf '%s\n' "$release" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)
if [ -z "$localversion" ] && [ -n "$release" ] && [ "$release" != "$base" ]; then
	printf '\nNote: CONFIG_LOCALVERSION is empty but the release is "%s".\n' "$release"
	printf '  The suffix came from the make command line, so pass it yourself:\n'
	printf '    make ... LOCALVERSION=%s\n' "${release#"$base"}"
	printf '  and set CONFIG_LOCALVERSION to match, or vermagic will differ.\n'
fi
toolchain=$(printf '%s\n' "$banner" |
	grep -oE 'based on r[0-9a-z]+|clang version [0-9.]+' | tr '\n' ' ')
[ -n "$toolchain" ] && printf 'toolchain = %s\n' "$toolchain"

# Note the spoofing trap explicitly: susfs rewrites uname().
if grep -q '^CONFIG_KSU_SUSFS_SPOOF_UNAME=y' "$OUTDIR/target.config"; then
	printf '\nWARNING: CONFIG_KSU_SUSFS_SPOOF_UNAME=y\n'
	printf '  `uname -r` is spoofed and will NOT match the real release.\n'
	printf '  Use /proc/sys/kernel/osrelease or /proc/version instead.\n'
fi

printf '\n=== layout-critical options ===\n'
for opt in CONFIG_MODVERSIONS CONFIG_MODULE_SIG_FORCE CONFIG_DEBUG_INFO_BTF \
	CONFIG_DEBUG_INFO_BTF_MODULES CONFIG_CFI_CLANG CONFIG_LTO_NONE \
	CONFIG_TRACEPOINTS CONFIG_ANDROID_VENDOR_HOOKS; do
	value=$(grep -E "^${opt}=" "$OUTDIR/target.config" || true)
	printf '%-34s %s\n' "$opt" "${value:-not set}"
done
printf '\nCONFIG_DEBUG_INFO_BTF_MODULES decides sizeof(struct module).\n'
printf 'Getting it wrong loads a module that then panics the device.\n'

printf '\n=== symbol CRC table ===\n'
if [ ! -r "$KALLSYMS" ]; then
	printf 'error: cannot read %s\n' "$KALLSYMS" >&2
	exit 1
fi
restrict=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo "?")
if [ "$KALLSYMS" = /proc/kallsyms ] && [ "$restrict" != 0 ]; then
	printf 'kptr_restrict is %s; addresses read as zero. Lowering it.\n' "$restrict"
	old_kptr_restrict=$restrict
	echo 0 > /proc/sys/kernel/kptr_restrict
fi
python3 "$HERE/gen_symvers.py" "$IMAGE" "$KALLSYMS" "$OUTDIR/Module.symvers"

printf '\ndone. Build with:\n'
printf '  cp %s/target.config $KDIR/.config\n' "$OUTDIR"
printf '  cp %s/Module.symvers $KDIR/Module.symvers\n' "$OUTDIR"
printf '  make -C $KDIR ARCH=arm64 LLVM=1 LOCALVERSION= olddefconfig\n'
printf '  make -C $KDIR ARCH=arm64 LLVM=1 LOCALVERSION= -j"$(nproc)" modules_prepare\n'
