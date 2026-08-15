#!/bin/sh
# Compare a struct's layout as your build sees it against the target kernel's
# own BTF. This is what caught the panic in this project: sizeof(struct module)
# was 1072 in the build tree but 1088 in the kernel, so the kernel wrote past
# the module's __this_module section during mod_sysfs_setup().
#
# A CRC and vermagic match tells you nothing about struct layout. Any struct the
# kernel writes into on a module's behalf must be checked separately.
#
# Usage:
#   tools/check_struct_layout.sh <KDIR> <struct-name> [btf-file]
#
# Example:
#   tools/check_struct_layout.sh /path/to/kernel module
#   tools/check_struct_layout.sh /path/to/kernel sched_ext_entity
#
# Requires: bpftool (for the target BTF), clang, python3, and a kernel tree
# already through `make modules_prepare`.
set -eu

KDIR="${1:?usage: check_struct_layout.sh <KDIR> <struct-name> [btf-file]}"
STRUCT="${2:?usage: check_struct_layout.sh <KDIR> <struct-name> [btf-file]}"
BTF="${3:-/sys/kernel/btf/vmlinux}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ ! -r "$BTF" ]; then
	printf 'error: cannot read BTF at %s\n' "$BTF" >&2
	printf 'On the target device this needs CONFIG_DEBUG_INFO_BTF=y.\n' >&2
	exit 1
fi

if ! command -v bpftool >/dev/null 2>&1; then
	printf 'error: bpftool not found; needed to dump target BTF\n' >&2
	exit 1
fi

printf 'target BTF : %s\n' "$BTF"
printf 'struct     : %s\n' "$STRUCT"
printf 'kernel tree: %s\n\n' "$KDIR"

bpftool btf dump file "$BTF" format raw > "$WORK/btf.txt"

# Extract the kernel's member offsets for the requested struct.
python3 - "$WORK/btf.txt" "$STRUCT" > "$WORK/kernel.txt" <<'PY'
import re, sys
path, want = sys.argv[1], sys.argv[2]
lines = open(path, errors='replace').read().split('\n')
start = size = None
for i, line in enumerate(lines):
    m = re.match(r"^\[\d+\] STRUCT '" + re.escape(want) + r"' size=(\d+)", line)
    if m:
        start, size = i, int(m.group(1))
        break
if start is None:
    sys.exit(f"struct {want} not found in target BTF")
print(f"#size {size}")
i = start + 1
while i < len(lines) and not lines[i].startswith('['):
    m = re.search(r"'([A-Za-z_0-9]+)' type_id=\d+ bits_offset=(\d+)", lines[i])
    if m:
        print(f"{m.group(1)} {int(m.group(2)) // 8}")
    i += 1
PY

ksize=$(awk '/^#size /{print $2}' "$WORK/kernel.txt")
printf 'kernel sizeof(struct %s) = %s\n' "$STRUCT" "$ksize"

# Build a throwaway module purely to make clang dump its record layouts.
mkdir -p "$WORK/probe"
{
	cat <<'EOF'
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/sched.h>
#include <linux/sched/ext.h>
EOF
	# clang only dumps layouts for types it is forced to complete, so take the
	# size of the requested struct explicitly.
	printf 'static const unsigned long probe_size = sizeof(struct %s);\n' "$STRUCT"
	cat <<'EOF'
static int __init probe_init(void) { return (int)(probe_size & 1); }
module_init(probe_init);
MODULE_LICENSE("GPL");
EOF
} > "$WORK/probe/probe.c"
cat > "$WORK/probe/Makefile" <<'EOF'
obj-m := probe.o
ccflags-y += -Xclang -fdump-record-layouts
EOF

printf '\nbuilding layout probe...\n'
make -C "$KDIR" M="$WORK/probe" ARCH=arm64 LLVM=1 LOCALVERSION= \
	HOSTCC=gcc HOSTCXX=g++ modules > "$WORK/layout.txt" 2>&1 || {
	printf 'error: probe build failed; see below\n' >&2
	tail -20 "$WORK/layout.txt" >&2
	exit 1
}

python3 - "$WORK/layout.txt" "$WORK/kernel.txt" "$STRUCT" <<'PY'
import re, sys
layout_path, kernel_path, want = sys.argv[1], sys.argv[2], sys.argv[3]
txt = open(layout_path, errors='replace').read().split('\n')

# Use the last dump: earlier ones may be forward declarations.
heads = [i for i, l in enumerate(txt)
         if re.search(r'^\s*0 \| struct ' + re.escape(want) + r'$', l)]
if not heads:
    sys.exit(f"clang produced no record layout for struct {want}")
i = heads[-1]
j = i
while j < len(txt) and '[sizeof=' not in txt[j]:
    j += 1

mine = {}
for line in txt[i + 1:j]:
    if line.count('|') != 1:
        continue
    left, right = line.split('|')
    left = left.strip()
    # Plain members are "1508", bitfields are "1508:0-0". Take the byte offset
    # in both cases so bitfields are compared rather than silently dropped.
    m = re.match(r'^(\d+)(?::\d+-\d+)?$', left)
    if not m:
        continue
    # Only direct members sit at this indent; nested ones are deeper.
    if len(right) - len(right.lstrip()) != 3:
        continue
    name = right.strip().split()[-1].rstrip(';')
    mine[re.sub(r'^\*+', '', name)] = int(m.group(1))

msize = re.search(r'sizeof=(\d+)', txt[j])
msize = int(msize.group(1)) if msize else None

kernel = {}
ksize = None
for line in open(kernel_path):
    if line.startswith('#size '):
        ksize = int(line.split()[1])
        continue
    name, off = line.split()
    kernel[name] = int(off)

print(f"\nbuild  sizeof(struct {want}) = {msize}")
print(f"kernel sizeof(struct {want}) = {ksize}")

problems = 0
if msize != ksize:
    print(f"\nFAIL size mismatch: build={msize} kernel={ksize}")
    problems += 1

bad = [(n, kernel[n], mine.get(n)) for n in kernel if mine.get(n) != kernel[n]]
print(f"members: kernel={len(kernel)} build={len(mine)} mismatched={len(bad)}")
for n, k, m in bad[:20]:
    print(f"  {n}: kernel={k} build={m}")
problems += len(bad)

if problems:
    print(f"\nFAIL {problems} layout problem(s). Do not load a module built "
          "against this configuration.")
    sys.exit(1)
print("\nPASS layout matches the target kernel exactly")
PY
