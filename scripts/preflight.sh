#!/bin/sh
# Verify the running target matches what scx_leak_hotfix.ko was built for.
# Exits non-zero on any FAIL so callers can refuse to load the module.
set -u

TARGET_RELEASE="6.1.115-android14-oki-xiaoxiaow"
KO="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/scx_leak_hotfix.ko}"

fails=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
info() { printf 'INFO  %s\n' "$*"; }

# 1. Architecture.
arch=$(uname -m)
case "$arch" in
aarch64) pass "arch $arch" ;;
*) fail "arch $arch, expected aarch64" ;;
esac

# 2. Kernel release.  Do not trust `uname -r`: CONFIG_KSU_SUSFS_SPOOF_UNAME
#    rewrites the uname() syscall to report an upstream GKI string.  The
#    procfs sources below are not spoofed, and the module itself compares
#    against its compile-time UTS_RELEASE, so those are the authoritative
#    values to check.
release=$(cat /proc/sys/kernel/osrelease 2>/dev/null)
if [ -z "$release" ]; then
	release=$(awk '{print $3}' /proc/version 2>/dev/null)
fi
if [ "$release" = "$TARGET_RELEASE" ]; then
	pass "release $release"
else
	fail "release ${release:-unknown}, expected $TARGET_RELEASE"
fi
spoofed=$(uname -r)
if [ "$spoofed" != "$release" ]; then
	info "uname -r reports '$spoofed' (susfs spoofing; ignored)"
fi

# 3. Target symbols must be present and not inlined away.
for sym in sched_ext_free scx_cancel_fork; do
	if grep -qE " $sym\$" /proc/kallsyms 2>/dev/null; then
		pass "symbol $sym resolvable"
	else
		fail "symbol $sym missing from /proc/kallsyms"
	fi
done

# 4. Kernel configuration, when readable.
if [ -r /proc/config.gz ]; then
	cfg=$(zcat /proc/config.gz 2>/dev/null)
	for opt in CONFIG_SLIM_SCHED CONFIG_SCHED_CLASS_EXT CONFIG_KPROBES \
		CONFIG_KRETPROBES CONFIG_MODVERSIONS; do
		if printf '%s\n' "$cfg" | grep -q "^${opt}=y"; then
			pass "$opt=y"
		else
			fail "$opt is not enabled"
		fi
	done
	if printf '%s\n' "$cfg" | grep -q '^CONFIG_MODULE_SIG_FORCE=y'; then
		fail "CONFIG_MODULE_SIG_FORCE=y requires a signed module"
	else
		pass "CONFIG_MODULE_SIG_FORCE not enforced"
	fi
else
	info "/proc/config.gz unreadable, skipping config checks"
fi

# 5. Module artifact and its vermagic.
if [ -f "$KO" ]; then
	pass "module present at $KO"
	if command -v modinfo >/dev/null 2>&1; then
		vermagic=$(modinfo -F vermagic "$KO" 2>/dev/null)
		case "$vermagic" in
		"$TARGET_RELEASE "*) pass "vermagic $vermagic" ;;
		"") info "vermagic unreadable" ;;
		*) fail "vermagic '$vermagic' does not match $TARGET_RELEASE" ;;
		esac
	fi
else
	fail "module not found at $KO"
fi

# 6. debugfs is needed for the stats file, but not for the fix itself.
if grep -q ' /sys/kernel/debug debugfs ' /proc/mounts 2>/dev/null; then
	pass "debugfs mounted"
else
	info "debugfs not mounted; stats file will be unavailable until you run:"
	info "  mount -t debugfs debugfs /sys/kernel/debug"
fi

printf '\n'
if [ "$fails" -eq 0 ]; then
	printf 'preflight: OK\n'
	exit 0
fi
printf 'preflight: %d check(s) failed, do not load\n' "$fails"
exit 1
