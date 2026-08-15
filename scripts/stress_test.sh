#!/bin/sh
# Measure sched_ext entity leak rate under controlled task churn.
#
# Creates N short-lived tasks and reports how many kmalloc-256 objects the
# kernel retained.  With the hotfix loaded the growth should be a small
# fraction of the task count; without it the ratio approaches 1.0.
set -u

TASKS="${1:-3000}"
SETTLE="${2:-3}"
STATS=/sys/kernel/debug/scx_leak_hotfix/stats

snap_processes() { awk '/^processes /{print $2}' /proc/stat; }
snap_kmalloc256() { awk '/^kmalloc-256 /{print $2}' /proc/slabinfo; }

if [ ! -r /proc/slabinfo ]; then
	printf 'error: /proc/slabinfo unreadable, cannot measure\n' >&2
	exit 1
fi

if grep -q '^scx_leak_hotfix ' /proc/modules 2>/dev/null; then
	loaded=yes
else
	loaded=no
fi
printf 'module loaded : %s\n' "$loaded"
printf 'tasks         : %s\n\n' "$TASKS"

if [ -r "$STATS" ]; then
	freed_before=$(awk '/^freed_normal /{print $2}' "$STATS")
else
	freed_before=""
fi

p1=$(snap_processes)
k1=$(snap_kmalloc256)

i=0
while [ "$i" -lt "$TASKS" ]; do
	/bin/true
	i=$((i + 1))
done

sleep "$SETTLE"

p2=$(snap_processes)
k2=$(snap_kmalloc256)

dp=$((p2 - p1))
dk=$((k2 - k1))

printf 'tasks created      : %d\n' "$dp"
printf 'kmalloc-256 growth : %d\n' "$dk"

if [ "$dp" -gt 0 ]; then
	# Leak ratio in percent, integer arithmetic for shell portability.
	ratio=$(((dk * 100) / dp))
	printf 'leak ratio         : %d%%\n' "$ratio"
	if [ "$loaded" = yes ]; then
		if [ "$ratio" -le 10 ]; then
			verdict="PASS (leak suppressed)"
		else
			verdict="FAIL (still leaking)"
		fi
	else
		if [ "$ratio" -ge 50 ]; then
			verdict="baseline confirms the leak exists"
		else
			verdict="baseline shows no leak; check workload"
		fi
	fi
	printf 'verdict            : %s\n' "$verdict"
fi

if [ -r "$STATS" ]; then
	freed_after=$(awk '/^freed_normal /{print $2}' "$STATS")
	printf 'freed this run     : %d\n' "$((freed_after - freed_before))"
	printf '\n--- %s ---\n' "$STATS"
	cat "$STATS"
fi
