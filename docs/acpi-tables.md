# reading the windows acpi tables on a dt booted machine

this is the technique that unblocked the camera. it works for any qualcomm
laptop and turns "nobody has published this register base" into a solved
problem.

## the problem

the x1e80100 camera pipeline (camss plus camcc) is described upstream and
works, see [camera.md](camera.md), but the sensors hang off a cci bus, and
nothing upstream describes cci for this soc:

- `qcom,i2c-cci.yaml` has no x1e80100 compatible
- `hamoa.dtsi` has no cci node
- the register base is not in any datasheet, dts, or vendor tree that is
  reachable

so there was no i2c bus to put a sensor on, and no way to even find out what
the sensor is.

## the insight

the machine ships windows. windows on snapdragon is acpi, not device tree. so
the register bases, interrupt numbers and gpios for every peripheral on this
board, the camera included, are sitting in the dsdt that dell's uefi builds.
linux boots from dt and throws that away, but the firmware still hands it over,
it is in the efi system table:

```
$ sudo cat /sys/firmware/efi/systab
ACPI20=0xd5fd5018
SMBIOS3=0xd5daa000
SMBIOS=0xd5dac000
```

the rsdp is in ram right now. it is just never parsed.

## getting at it

`/dev/mem` will not do it. the region is ordinary system ram, and arm64's
`devmem_is_allowed()` refuses every ram page under `CONFIG_STRICT_DEVMEM`:

```
$ sudo dd if=/dev/mem bs=1 skip=$((0xd5fd5018)) count=36
dd: error reading '/dev/mem': Operation not permitted
```

`iomem=relaxed` does not help either, that only relaxes `iomem_is_exclusive`,
not the ram check.

so, a small module that does the same thing without the check.
`tools/acpi/physmem` exposes a debugfs file where read offset n returns
physical byte n, via `memremap()`:

```
$ make -C tools/acpi/physmem
$ sudo insmod tools/acpi/physmem/physmem.ko
$ sudo dd if=/sys/kernel/debug/physmem bs=1 skip=$((0xd5fd5018)) count=36 status=none | xxd
00000000: 5253 4420 5054 5220 6f51 434f 4d20 2002  RSD PTR oQCOM  .
00000010: 0000 0000 2400 0000 185f fdd5 0000 0000  ....$...._......
```

this needs `CONFIG_MODULE_SIG_FORCE` off and lockdown off. both are true here
(secure boot is disabled), otherwise the module has to be signed with the key
the kernel was built with.

`tools/acpi/acpi-dump.py` then reads the rsdp address from the efi system table,
walks rsdp to xsdt to every table, plus the dsdt that only the fadt points at,
and writes them out:

```
$ sudo tools/acpi/acpi-dump.py acpi-tables
xsdt @ 0xd5fd5f18, 15 tables
  FACP @ 0xd5fd5b98 len=276      oem=QCOM     id=QCOMEDK2
  DSDT @ 0xd5f81018 len=290962   oem=QCOMM    id=SDM8380
  CSRT @ 0xd5fc9018 len=47454    oem=QCOM     id=QCOMEDK2
  IORT @ 0xd5f7f018 len=5366     oem=QCOM     id=QCOMEDK2
  ...
```

`SDM8380` is qualcomm's internal name for the x elite. then `iasl -d DSDT.dat`
(from `acpica-tools`) gives 69k lines of asl describing every peripheral on
this board as windows sees it.

## what came out of it

the camera is `\_SB.CAMP`, `_HID` `QCOM0C32`. its `_CRS` is the whole answer:

```
Memory32Fixed  base=0x0ac13000 size=0x1000  (4K)
Memory32Fixed  base=0x0ac19000 size=0xc000  (48K)
Memory32Fixed  base=0x0ac15000 size=0x1000  (4K)
Memory32Fixed  base=0x0ac16000 size=0x1000  (4K)
Interrupt      GSIV=492 (SPI 460)
Interrupt      GSIV=303 (SPI 271)
Interrupt      GSIV=491 (SPI 459)
Gpio (Io)      pin=99   src=\_SB.GIO0
Gpio (Io)      pin=110  src=\_SB.GIO0
```

see [camera.md](camera.md) for what that means.

`_CRS` is a raw byte buffer in the asl, so the descriptors have to be decoded by
hand. `0x86` is Memory32Fixed, `0x89` is Extended Interrupt, `0x8C` is a gpio
connection. note the offsets inside a `0x8C` descriptor (pin table, resource
source name) are counted from the start of the descriptor, not from the
payload.

the same dsdt also settled the embedded controller question, see
[fan-control.md](fan-control.md).

## other things in here worth mining later

nothing has been done with these yet:

- **CSRT**, 47 kb, core system resources, dma request lines
- **IORT**, 5 kb, smmu topology and stream ids, cross checkable against the dts
- **DBG2**, 1.5 kb, debug uart
- the dsdt has every other peripheral on the board. anything currently marked
  "not described upstream" can be looked up the same way.

## not in this repo

the dumped tables are dell's firmware and are not redistributed here. dumping
them again takes a minute with the module and the script above.
