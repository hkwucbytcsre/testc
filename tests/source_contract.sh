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

require_literal '.symbol_name = "sched_ext_free"'
require_literal '.symbol_name = "scx_cancel_fork"'
require_literal 'READ_ONCE(scx->task) != task'
require_literal 'cmpxchg(&task->scx, scx, NULL)'
require_literal 'kfree(scx)'
require_literal 'static_assert(sizeof(struct module) == HOTFIX_MODULE_SIZE)'
require_literal 'unregister_kretprobe(&cancel_probe)'
require_literal 'unregister_kretprobe(&free_probe)'
require_literal 'normal_nmissed'
require_literal 'cancel_nmissed'

if grep -Eq '\.addr[[:space:]]*=' "$SRC"; then
	fail "hard-coded probe addresses are forbidden"
fi

for script in "$ROOT"/scripts/*.sh "$ROOT"/tools/*.sh; do
	test -f "$script" || continue
	sh -n "$script" || fail "shell syntax: $script"
done

for script in "$ROOT"/tools/*.py; do
	test -f "$script" || continue
	python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$script" ||
		fail "python syntax: $script"
done

# The target config carries CONFIG_LOCALVERSION="" with LOCALVERSION_AUTO=y,
# so any build that does not override both ends up with a git-derived release
# and a vermagic the target kernel rejects. CI hit exactly this, so assert the
# workflow still sets them.
WORKFLOW="$ROOT/.github/workflows/build.yml"
if [ -f "$WORKFLOW" ]; then
	grep -Fq -- '--set-str LOCALVERSION' "$WORKFLOW" ||
		fail "workflow must set CONFIG_LOCALVERSION explicitly"
	grep -Fq -- '--disable LOCALVERSION_AUTO' "$WORKFLOW" ||
		fail "workflow must disable CONFIG_LOCALVERSION_AUTO"
fi

if grep -Fq 'CONFIG_LOCALVERSION_AUTO=y' "$ROOT/ci/target.config" 2>/dev/null &&
   ! grep -Fq 'CONFIG_LOCALVERSION_AUTO' "$ROOT/profiles/mt6989_ace5_race.md"; then
	fail "profile must document the LOCALVERSION_AUTO trap"
fi

printf 'PASS: source safety contract\n'
