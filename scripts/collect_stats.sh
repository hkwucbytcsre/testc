#!/bin/sh
# Collect memory and hotfix telemetry for before/after comparison.
set -u

STATS=/sys/kernel/debug/scx_leak_hotfix/stats

section() { printf '\n===== %s =====\n' "$1"; }

printf 'timestamp : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf 'release   : %s\n' "$(uname -r)"
printf 'uptime    : %s\n' "$(awk '{print $1}' /proc/uptime)"

section "hotfix stats"
if [ -r "$STATS" ]; then
	cat "$STATS"
else
	if grep -q '^scx_leak_hotfix ' /proc/modules 2>/dev/null; then
		printf 'module loaded but stats unreadable; mount debugfs:\n'
		printf '  mount -t debugfs debugfs /sys/kernel/debug\n'
	else
		printf 'module not loaded\n'
	fi
fi

section "task counters"
awk '/^processes /{print "processes " $2}' /proc/stat
printf 'threads %s\n' "$(awk '/^Threads:/{print $2}' /proc/loadavg 2>/dev/null || nproc)"

section "meminfo"
grep -E '^(MemTotal|MemFree|MemAvailable|Slab|SReclaimable|SUnreclaim):' /proc/meminfo

section "slabinfo (kmalloc-256 and task caches)"
if [ -r /proc/slabinfo ]; then
	awk 'NR==2 || /^(kmalloc-256|kmalloc-192|task_struct|kmalloc-rnd-[0-9]*-256) /' /proc/slabinfo
else
	printf '/proc/slabinfo unreadable\n'
fi

section "buddyinfo"
cat /proc/buddyinfo 2>/dev/null || printf 'unavailable\n'

section "extfrag index"
cat /sys/kernel/debug/extfrag/extfrag_index 2>/dev/null || printf 'unavailable\n'

section "kernel warnings since boot"
count=$(dmesg 2>/dev/null | grep -ciE 'BUG:|Oops|panic|use-after-free|double free|corruption|RCU stall|CFI failure')
printf 'anomaly lines: %s\n' "${count:-unreadable}"
dmesg 2>/dev/null | grep -i 'scx_leak_hotfix' | tail -5
