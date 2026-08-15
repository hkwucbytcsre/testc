#!/usr/bin/env python3
"""Reconstruct Module.symvers from a raw arm64 kernel Image plus /proc/kallsyms.

Why this exists
---------------
Building an external module against a vendor kernel normally requires the
vendor's `Module.symvers`, which is a build artifact and is almost never
shipped. With `CONFIG_MODVERSIONS=y` the kernel refuses any module whose
symbol CRCs disagree, so a guessed or regenerated table is useless.

The CRCs are, however, present in the kernel image itself: `__kcrctab` sits
right next to `__ksymtab`, and `/proc/kallsyms` tells us where both live. So we
can read them straight out of the running kernel's own image.

Assumptions (all true for arm64 6.1 GKI)
----------------------------------------
* `CONFIG_HAVE_ARCH_PREL32_RELOCATIONS=y`, so each `struct kernel_symbol` is
  three signed 32-bit self-relative offsets (value, name, namespace) rather
  than three 64-bit pointers.
* `CONFIG_MODULE_REL_CRCS` is unset, so `__kcrctab` holds absolute `s32` CRC
  values rather than relative offsets.
* The supplied image is the raw decompressed `Image`, whose file offset 0
  corresponds to the `_text` virtual address.
* `/proc/sys/kernel/kptr_restrict` is 0 so kallsyms addresses are readable.

Verify the assumptions before trusting the output: `tools/verify_ko.py` will
cross-check a built module's `__versions` section against the result.

Usage
-----
    tools/gen_symvers.py <Image> [kallsyms] [output]
"""
import struct
import sys

IMAGE = sys.argv[1] if len(sys.argv) > 1 else "vmlinux"
KALLSYMS = sys.argv[2] if len(sys.argv) > 2 else "/proc/kallsyms"
OUT = sys.argv[3] if len(sys.argv) > 3 else "Module.symvers"

# Section boundary symbols we need to locate the export tables.
WANT = {
    "_text",
    "__start___ksymtab", "__stop___ksymtab",
    "__start___ksymtab_gpl", "__stop___ksymtab_gpl",
    "__start___kcrctab", "__stop___kcrctab",
    "__start___kcrctab_gpl", "__stop___kcrctab_gpl",
}

sym = {}
with open(KALLSYMS) as fh:
    for line in fh:
        parts = line.split()
        if len(parts) >= 3 and parts[2] in WANT and parts[2] not in sym:
            sym[parts[2]] = int(parts[0], 16)

missing = WANT - set(sym)
if missing:
    sys.exit(
        f"missing kallsyms anchors: {sorted(missing)}\n"
        "Check /proc/sys/kernel/kptr_restrict is 0 and CONFIG_KALLSYMS_ALL=y."
    )

text = sym["_text"]
blob = open(IMAGE, "rb").read()


def off(name):
    """File offset of a kernel symbol, assuming Image offset 0 == _text."""
    return sym[name] - text


def cstr(pos):
    end = blob.index(b"\0", pos)
    return blob[pos:end].decode("ascii", "replace")


def entries(sym_start, sym_stop, crc_start, crc_stop, license_):
    so, eo = off(sym_start), off(sym_stop)
    co, ce = off(crc_start), off(crc_stop)
    if not 0 <= so < eo <= len(blob) or not 0 <= co < ce <= len(blob):
        sys.exit(f"{license_}: table offsets fall outside the image; "
                 "is this the raw decompressed Image?")
    n = (eo - so) // 12
    if (ce - co) // 4 != n:
        sys.exit(f"{license_}: ksymtab has {n} entries but kcrctab has "
                 f"{(ce - co) // 4}; PREL32/REL_CRCS assumption is wrong")
    out = []
    for i in range(n):
        base = so + i * 12
        val_off, name_off, ns_off = struct.unpack_from("<iii", blob, base)
        # PREL32 is self-relative: target = &field + value_of_field.
        value_va = sym[sym_start] + i * 12 + val_off
        name_pos = (base + 4) + name_off
        namespace = "" if ns_off == 0 else cstr((base + 8) + ns_off)
        crc = struct.unpack_from("<i", blob, co + i * 4)[0]
        out.append((cstr(name_pos), crc, value_va, license_, namespace))
    return out


rows = entries("__start___ksymtab", "__stop___ksymtab",
               "__start___kcrctab", "__stop___kcrctab", "EXPORT_SYMBOL")
rows += entries("__start___ksymtab_gpl", "__stop___ksymtab_gpl",
                "__start___kcrctab_gpl", "__stop___kcrctab_gpl",
                "EXPORT_SYMBOL_GPL")

# modpost's read_dump() splits on tabs and expects five fields. The namespace
# field must be present even when empty, or the last column is misparsed.
with open(OUT, "w") as fh:
    for name, crc, _va, lic, ns in rows:
        fh.write(f"0x{crc & 0xffffffff:08x}\t{name}\tvmlinux\t{lic}\t{ns}\n")

print(f"wrote {len(rows)} symbols -> {OUT}")

# Cross-check every recovered address against kallsyms. A correct PREL32 decode
# means the value address matches what kallsyms reports for the same name.
#
# A handful of names appear twice: once as a file-local "t" and once as the
# exported global "T" (dev_open, iio_read_channel_ext_info, ...). Only the
# global one can be the export target, so prefer uppercase type letters.
checked = mismatched = 0
kall = {}
with open(KALLSYMS) as fh:
    for line in fh:
        parts = line.split()
        if len(parts) < 3:
            continue
        addr, typ, name = int(parts[0], 16), parts[1], parts[2]
        if name not in kall or (typ.isupper() and not kall[name][1].isupper()):
            kall[name] = (addr, typ)
for name, _crc, va, _lic, _ns in rows:
    entry = kall.get(name)
    if entry is None:
        continue
    checked += 1
    if entry[0] != va:
        mismatched += 1
        if mismatched <= 5:
            print(f"  address mismatch {name}: "
                  f"table={va:#x} kallsyms={entry[0]:#x}")
print(f"address cross-check: {checked - mismatched}/{checked} agree with kallsyms")
if mismatched:
    sys.exit("PREL32 decode looks wrong; do not use this Module.symvers")
