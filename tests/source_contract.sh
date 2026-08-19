#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/scx_leak_hotfix.c"

fail()
{
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

require_literal()
{
	grep -Fq "$1" "$SRC" || fail "missing source contract: $1"
}

test -f "$SRC" || fail "missing scx_leak_hotfix.c"

# Required header inclusions
require_literal '#include <linux/sched/hmbird.h>'
require_literal '#include <trace/hooks/sched.h>'

# Vendor hook registration / unregistration
require_literal 'register_trace_android_vh_free_task(hotfix_free_task, NULL)'
require_literal 'unregister_trace_android_vh_free_task(hotfix_free_task, NULL)'
require_literal 'tracepoint_synchronize_unregister()'

# Core logic patterns
require_literal 'READ_ONCE(ent->task) != task'
if ! grep -zq 'cmpxchg.*android_oem_data1.*HMBIRD_TS_IDX' "$SRC"; then
    fail "missing source contract: cmpxchg for android_oem_data1 slot"
fi
require_literal 'kfree(ent)'

# Compile-time size assertions
require_literal 'static_assert(sizeof(struct hmbird_entity) == HOTFIX_ENTITY_SIZE)'
require_literal 'static_assert(sizeof(struct module) == HOTFIX_MODULE_SIZE)'

# Ensure no legacy kprobe/kretprobe usage remains
if grep -Eq 'kretprobe|register_kprobe|<linux/kprobes\.h>' "$SRC"; then
	fail "kprobe/kretprobe usage is forbidden in the production module"
fi

if grep -Eq '\.addr[[:space:]]*=' "$SRC"; then
	fail "hard-coded probe addresses are forbidden"
fi

# Shell script syntax checks
for script in "$ROOT"/scripts/*.sh "$ROOT"/tools/*.sh; do
	test -f "$script" || continue
	sh -n "$script" || fail "shell syntax: $script"
done

# Python script syntax checks
for script in "$ROOT"/tools/*.py; do
	test -f "$script" || continue
	python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$script" ||
		fail "python syntax: $script"
done

# Check that CI workflow still sets LOCALVERSION correctly
WORKFLOW="$ROOT/.github/workflows/build.yml"
if [ -f "$WORKFLOW" ]; then
	grep -Fq -- '--set-str LOCALVERSION' "$WORKFLOW" ||
		fail "workflow must set CONFIG_LOCALVERSION explicitly"
	grep -Fq -- '--disable LOCALVERSION_AUTO' "$WORKFLOW" ||
		fail "workflow must disable CONFIG_LOCALVERSION_AUTO"
fi

printf 'PASS: source safety contract\n'