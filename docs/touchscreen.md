# touchscreen: wrong i2c address in the device tree

found while hunting for a fan controller. an i2c bus scan turned up a device
the dt does not describe, and it turned out to be the touchscreen.

## symptom

touchscreen does not work. `i2c_hid_of` never binds:

```
$ ls /sys/bus/i2c/devices/0-0010/driver
(none)
```

and tlmm pin 51, the touchscreen interrupt, is left unclaimed in the pinmux,
the driver never probes far enough to take it.

## cause

the dt declares the device at 0x10. nothing responds there:

```
# i2cdetect -y -r 0
00:          -- 09 -- -- -- -- -- --
20: -- -- -- -- -- -- -- -- 28 -- -- -- -- -- -- --
```

0x09 answers. 0x28 also acks but returns all zeros to every read, presumably an
alternate or bootloader address on the same controller.

reading the hid-over-i2c descriptor from 0x09 (write the 2 byte descriptor
register, read 30) gives a valid one. `tools/touchscreen/probe-touchscreen.sh` does this:

```
1e 00   wHIDDescLength    = 30
00 01   bcdVersion        = 1.00
6b 03   wReportDescLength = 875
21 00   wReportDescRegister
24 00   wInputRegister      42 00  wMaxInputLength  = 66
25 00   wOutputRegister     44 00  wMaxOutputLength = 68
22 00   wCommandRegister    23 00  wDataRegister
bd 29   wVendorID  = 0x29bd
03 11   wProductID = 0x1103
02 01   wVersionID
```

and the report descriptor is unambiguous:

```
05 0d   Usage Page (Digitizer)
09 04   Usage (Touch Screen)
a1 01   Collection (Application)
85 10   Report ID (0x10)
05 0d   Usage Page (Digitizer)
09 22   Usage (Finger)
a1 02   Collection (Logical)
09 42   Usage (Tip Switch)
15 00 25 01 75 01 95 01 81 02      1-bit tip switch
95 07 81 03                        7 bits padding
75 08 09 51 95 01 81 02            8-bit contact id
05 01 26 ff 7f 75 10 55 0d 65 ..   16-bit X/Y, unit exponent -3
```

a standard windows precision touchscreen.

## fix

`patches/out/dts/0002-arm64-dts-qcom-x1e80100-dell-inspiron-14-plus-7441-f.patch`,
one line plus the node rename:

```dts
-	touchscreen@10 {
+	touchscreen@9 {
 		compatible = "hid-over-i2c";
-		reg = <0x10>;
+		reg = <0x09>;
```

everything else in the node was already correct. `hid-descr-addr = <0x1>` is
right (the probe used it and got a valid descriptor), and the interrupt and
pinctrl are fine.

## status: working

built into `kernel-7.1.13-200.dellfix.fc44` and confirmed on hardware. touch
input works.

```
$ readlink -f /sys/bus/i2c/devices/0-0009/driver
/sys/bus/i2c/drivers/i2c_hid_of

$ grep "^N: Name" /proc/bus/input/devices
N: Name="hid-over-i2c 29BD:1103"
N: Name="hid-over-i2c 29BD:1103 UNKNOWN"
```

the old `0-0010` device is gone, as expected. no power sequencing turned out to
be needed, the node's lack of `vdd-supply` and `reset-gpios` was never the
problem, the address was.

note the input device is named from the hid vid and pid rather than
"Touchscreen", so `grep -i touch /proc/bus/input/devices` does not find it.
look for `29BD:1103`, which is what `scripts/verify.sh` does.

## note

0x09 is a legal i2c address. only 0x00 to 0x07 and 0x78 to 0x7f are reserved.
since the board dts upstream has 0x10, the touchscreen has never worked
upstream on this machine. see [upstreaming.md](upstreaming.md).
