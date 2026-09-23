#!/usr/bin/env python3
"""dump the acpi tables the uefi firmware left in memory on a dt booted machine.

windows on snapdragon is acpi, so the dsdt dell's uefi builds describes every
peripheral on the board, register bases and interrupts included. linux booted
from dt never parses it, but the rsdp address is in the efi system table and
the tables are still in ram. /dev/mem refuses system ram under
CONFIG_STRICT_DEVMEM, so this reads through tools/acpi/physmem instead.

    sudo insmod tools/acpi/physmem/physmem.ko
    sudo acpi-dump.py [outdir]        default ./acpi-tables
    iasl -d acpi-tables/DSDT.dat      then read the .dsl

see docs/acpi-tables.md. the tables are dell's firmware, don't redistribute them.
"""
import os
import re
import struct
import sys

MEM = "/sys/kernel/debug/physmem"


def rd(pa, n):
    with open(MEM, "rb") as f:
        f.seek(pa)
        b = b""
        while len(b) < n:
            c = f.read(n - len(b))
            if not c:
                break
            b += c
        return b


def rsdp_address():
    # ACPI20=0x... in the efi system table
    for line in open("/sys/firmware/efi/systab"):
        m = re.match(r"ACPI20=0x([0-9a-fA-F]+)", line)
        if m:
            return int(m.group(1), 16)
    raise SystemExit("no ACPI20 entry in /sys/firmware/efi/systab")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "acpi-tables"
    if not os.path.exists(MEM):
        raise SystemExit(f"{MEM} missing, insmod tools/acpi/physmem/physmem.ko first")
    os.makedirs(out, exist_ok=True)

    rsdp_pa = rsdp_address()
    rsdp = rd(rsdp_pa, 36)
    if rsdp[:8] != b"RSD PTR ":
        raise SystemExit(f"no rsdp signature at {rsdp_pa:#x}")
    xsdt_pa = struct.unpack_from("<Q", rsdp, 24)[0]
    hdr = rd(xsdt_pa, 36)
    length = struct.unpack_from("<I", hdr, 4)[0]
    xsdt = rd(xsdt_pa, length)
    n = (length - 36) // 8
    print(f"xsdt @ {xsdt_pa:#x}, {n} tables")

    def save(pa):
        h = rd(pa, 36)
        sig = h[:4].decode("latin1").strip()
        ln = struct.unpack_from("<I", h, 4)[0]
        if ln < 36 or ln > 8 * 1024 * 1024:
            print(f"  {sig} @ {pa:#x} bogus length {ln}")
            return None
        data = rd(pa, ln)
        oem = h[10:16].decode("latin1").strip()
        tid = h[16:24].decode("latin1").strip()
        p = os.path.join(out, f"{sig}.dat")
        i = 1
        while os.path.exists(p):
            p = os.path.join(out, f"{sig}{i}.dat")
            i += 1
        open(p, "wb").write(data)
        print(f"  {sig:<4} @ {pa:#010x} len={ln:<8} oem={oem:<8} id={tid:<8} -> {os.path.basename(p)}")
        return h, data

    for pa in [struct.unpack_from("<Q", xsdt, 36 + 8 * i)[0] for i in range(n)]:
        r = save(pa)
        # only the fadt points at the dsdt
        if r and r[0][:4] == b"FACP":
            d = r[1]
            dsdt = struct.unpack_from("<Q", d, 140)[0] if len(d) >= 148 else 0
            if not dsdt:
                dsdt = struct.unpack_from("<I", d, 40)[0]
            if dsdt:
                save(dsdt)


if __name__ == "__main__":
    main()
