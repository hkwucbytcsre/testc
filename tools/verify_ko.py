#!/usr/bin/env python3
"""Validate a built .ko against a target kernel before loading it.

With CONFIG_MODVERSIONS a wrong CRC only costs you a failed `insmod`. A wrong
`struct module` layout is far worse: the module loads, then the kernel writes
past the module's `__this_module` section in `mod_sysfs_setup()` and panics the
device. This script checks both, plus vermagic, so mistakes surface on the
build host instead of on a phone.

Usage
-----
    tools/verify_ko.py <module.ko> <Module.symvers> [expected-vermagic]

Exits non-zero on any problem.
"""
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

if len(sys.argv) < 3:
    sys.exit(__doc__)

KO = sys.argv[1]
SYMVERS = sys.argv[2]
EXPECTED_VERMAGIC = sys.argv[3] if len(sys.argv) > 3 else None

# Section size that `struct module` must occupy. See profiles/ for why this is
# 1088 rather than 1072 on this target.
EXPECTED_MODULE_SIZE = 1088

failures = []


def ok(msg):
    print(f"PASS  {msg}")


def bad(msg):
    print(f"FAIL  {msg}")
    failures.append(msg)


def info(msg):
    print(f"INFO  {msg}")


def tool(*candidates):
    for name in candidates:
        path = shutil.which(name)
        if path:
            return path
    return None


if not os.path.isfile(KO):
    sys.exit(f"no such module: {KO}")
if not os.path.isfile(SYMVERS):
    sys.exit(f"no such symbol table: {SYMVERS}")

# ---------------------------------------------------------------- section size
readelf = tool("llvm-readelf", "readelf")
if readelf:
    out = subprocess.run([readelf, "-SW", KO], capture_output=True,
                         text=True).stdout
    for line in out.splitlines():
        if ".gnu.linkonce.this_module" in line:
            fields = line.split()
            # readelf -SW columns: [Nr] Name Type Address Off Size ...
            size = int(fields[5], 16)
            if size == EXPECTED_MODULE_SIZE:
                ok(f"__this_module section is {size} bytes")
            else:
                bad(f"__this_module section is {size} bytes, expected "
                    f"{EXPECTED_MODULE_SIZE}; the kernel will overrun it and "
                    "panic. Check CONFIG_DEBUG_INFO_BTF_MODULES.")
            break
    else:
        bad("no .gnu.linkonce.this_module section found")
else:
    info("readelf unavailable, skipping section size check")

# ------------------------------------------------------------------- vermagic
modinfo = tool("modinfo")
vermagic = None
if modinfo:
    proc = subprocess.run([modinfo, "-F", "vermagic", KO],
                          capture_output=True, text=True)
    vermagic = proc.stdout.strip()

if vermagic is None:
    # modinfo may be absent in a minimal container; read .modinfo directly.
    objcopy = tool("llvm-objcopy", "objcopy")
    if objcopy:
        with tempfile.NamedTemporaryFile(suffix=".bin") as tmp:
            subprocess.run([objcopy, f"--dump-section=.modinfo={tmp.name}",
                            KO, os.devnull], check=False)
            blob = open(tmp.name, "rb").read()
        for field in blob.split(b"\0"):
            if field.startswith(b"vermagic="):
                vermagic = field[len(b"vermagic="):].decode()
                break

if vermagic:
    if EXPECTED_VERMAGIC and vermagic != EXPECTED_VERMAGIC:
        bad(f"vermagic '{vermagic}' != expected '{EXPECTED_VERMAGIC}'")
    else:
        ok(f"vermagic {vermagic}")
    if "modversions" not in vermagic:
        info("vermagic lacks 'modversions'; CRC checks below are advisory")
else:
    info("could not read vermagic")

# ----------------------------------------------------------------- symbol CRCs
kern = {}
with open(SYMVERS) as fh:
    for line in fh:
        fields = line.rstrip("\n").split("\t")
        if len(fields) >= 2:
            kern[fields[1]] = int(fields[0], 16)

objcopy = tool("llvm-objcopy", "objcopy")
if not objcopy:
    info("objcopy unavailable, skipping CRC check")
else:
    with tempfile.NamedTemporaryFile(suffix=".bin") as tmp:
        subprocess.run([objcopy, f"--dump-section=__versions={tmp.name}",
                        KO, os.devnull], check=False)
        data = open(tmp.name, "rb").read()

    if not data:
        info("module has no __versions section (CONFIG_MODVERSIONS off?)")
    else:
        # struct modversion_info { unsigned long crc; char name[MODULE_NAME_LEN]; }
        # On arm64 that is 8 + 56 = 64 bytes, with the CRC in the low 4 bytes.
        matched = 0
        problems = 0
        for offset in range(0, len(data) - 63, 64):
            entry = data[offset:offset + 64]
            crc = struct.unpack_from("<I", entry, 0)[0]
            name = entry[8:].split(b"\0")[0].decode()
            expected = kern.get(name)
            if expected is None:
                bad(f"{name} is not exported by the target kernel")
                problems += 1
            elif expected != crc:
                bad(f"CRC mismatch {name}: ko=0x{crc:08x} "
                    f"kernel=0x{expected:08x}")
                problems += 1
            else:
                matched += 1
        if problems == 0:
            ok(f"all {matched} symbol CRCs match the target")

# ------------------------------------------------------------ undefined symbols
nm = tool("llvm-nm", "nm")
if nm:
    out = subprocess.run([nm, "-u", KO], capture_output=True, text=True).stdout
    undefined = []
    for line in out.splitlines():
        parts = line.split()
        if parts:
            name = parts[-1]
            if not re.match(r"^__kcfi_typeid_", name):
                undefined.append(name)
    unresolved = [n for n in undefined if n not in kern]
    if unresolved:
        bad(f"undefined symbols not exported by the kernel: {unresolved}")
    else:
        ok(f"all {len(undefined)} undefined symbols are kernel exports")

print()
if failures:
    print(f"verify_ko: {len(failures)} problem(s); do not load this module")
    sys.exit(1)
print("verify_ko: OK")
