# fan control

**verdict: the fan curve is autonomous. there is an ec and it is reachable, but
nothing found so far reads or commands fan speed.** the original verdict here
said "no ec at all", which was wrong, see the correction below. everything that
was checked is listed so nobody has to redo it.

## correction, there is an embedded controller

this file originally concluded "no ec at all". that was wrong, and it was wrong
twice over. the evidence was sitting in the board device tree the whole time:

```dts
&i2c5 {
	status = "okay";

	/* EC @0x3b */
```

reading the dsdt out of this machine's own uefi (see
[acpi-tables.md](acpi-tables.md)) confirms it and names everything.

### what is established

- `\_SB.I2C6` in acpi is `QUP_0_SE_5`, register base `0x00b94000`, which is
  `i2c5@b94000` in the device tree and `i2c-3` in linux (`tools/fan/probe-ec.sh`
  finds the bus by register address rather than trusting the number).
- the ec is at slave address 0x3b, 100 khz. it acks:

  ```
  # i2cdetect -y -r 3
  30: -- -- -- -- -- -- -- -- -- -- -- 3b -- -- -- --
  40: -- -- -- UU -- -- -- -- -- -- -- -- -- -- -- UU
  ```

- it answers a 64 byte block read. command 0x00 returns structured data, what
  look like (temperature, sensor id, flags) triplets:

  ```
  # i2ctransfer -y 3 w1@0x3b 0x00 r64
  11 00 01 00  29 02 44  29 03 44  29 04 44  2a 05 55  2b 06 44  2b 36 35  00 00 ...
               41C id2    41C id3    41C id4    42C id5    43C id6
  ```

- the dsdt documents the register file as `EC00`..`EC7F` (`AttribBytes(0x40)`,
  64 byte block transfers), plus a vendor command escape `0xFB` with
  subcommands, `0x20` "set temperature" and `0x22` "read fan".
- there are real acpi fan devices, `FAN1` and `FAN2`, `_HID PNP0C0B`, each with
  a trip point `_DSM` that programs lower and upper rpm limits through the ec.
  there is also a `FECI` device (`QCOM0D05`) holding fan state and lut fields.

### what this does not establish

- the only `_DSM` function the firmware actually implements on the fan uuid is
  `STMP`, "tell the ec the current temperature". the lut and trip point
  functions dispatch to a stub that returns 0. so even windows does not command
  fan speed here. it feeds the ec a temperature and the ec runs its own curve,
  which is consistent with the qmi and tme findings below.
- the `RFAN` method (read fan rpm) is defined in the dsdt but never called by
  anything, and driving it by hand returns a constant:

  ```
  # i2ctransfer -y 3 w3@0x3b 0xfb 0x22 0x00 r6
  0x00 0x00 0x01 0x00 0x29 0x02      # repeatable, unchanged at 109 C under full load
  # i2ctransfer -y 3 w1@0x3b 0x00   r6
  0x11 0x00 0x01 0x00 0x29 0x02      # the plain block read, same buffer
  ```

  the fan command returns the same telemetry buffer as the plain block read,
  differing only in byte 0. so the ec is not answering `0xFB 0x22` as a
  distinct command, either the framing is still wrong, or the command is simply
  not live on this firmware. that fits `RFAN` being dead code that nothing in
  the dsdt calls.

  framings tried, all giving the same buffer: `FB 22 <fan>`, `FB 22`, with a
  leading length byte, with a leading region offset byte, and fan indices 0 to 3.
- the temperature triplets above did not change between samples taken at 41 c
  idle and at 109 c cpu under a full kernel build. they may be chassis sensors
  that genuinely move slowly, or a static table. unverified either way.

so fan speed still cannot be read or set today. but the reason is no longer
"there is no ec", it is that the ec's fan interface is autonomous and the one
command that would read rpm does not respond as documented. that is a much
smaller gap, and it is pokeable live from userspace with `i2ctransfer`, no
kernel changes needed.

worth trying next: sweep the block read command codes for one whose data tracks
temperature or fan state, re-check the `0xFB` framing (the acpi
`AttribRawProcessBytes` wire format may include a length byte that isn't being
sent), and look at `EC5A`, `EC6B`..`EC72`, `EC76`..`EC7A`, the offsets the dsdt
bothers to name.

this is an ec on a live bus shared with two usb redrivers. reads are low risk.
do not blind write command codes.

## what was ruled out

**no fan in hwmon.** 64 hwmon devices, none with `fan*_input` or `pwm*`. all
are `qcom_tsens` temperature sensors, pmic die sensors, `nvme`, `ath12k_hwmon`
and the battmgr supplies.

**no fan cooling device.** the thermal framework has five, all of them
throttlers, none a fan:

```
cpufreq-cpu0  cpufreq-cpu4  cpufreq-cpu8  devfreq-3d00000.gpu  PCIe_Port_Link_Speed
```

**nothing in the device tree.** no `pwm-fan`, no `gpio-fan`, no tach. the only
matches for "fan" or "cooling" are `#cooling-cells` and `cooling-maps`, which
are the cpu and gpu throttling bindings.

~~**not on i2c.** every enabled bus is accounted for, touchscreen, keyboard,
touchpad, two `ps8833` type-c retimers, two `ptn3222` redrivers. no unknown
device, no ec.~~

~~**no ec at all.** this machine has no embedded controller. that is already
established by the battery path, pmic to `pmic_glink` to adsp, not an ec
interface.~~

both of those are wrong, see the correction at the top. there is an ec, it is
on i2c, and the board dtsi says so in a comment that wasn't read. the battery
reasoning was a non sequitur, battery going via `pmic_glink` says nothing about
whether an ec exists for other things. `tools/fan/hunt-ec.sh` is the root side of
that search (smbios, gpios, pinmux, scmi, rpmsg, thermal bindings, and with
`--probe-i2c` the bus scan that eventually found the ec and, as a side effect,
the touchscreen at the wrong address).

## the qmi thermal service

there is a firmware thermal service, and it is reachable. `qrtr-lookup` shows:

```
Service Version Instance Node  Port
     24       1        1    5     8  Thermal mitigation device service
     24       1       67   10     8  Thermal mitigation device service
```

qmi service 24 is tmd, thermal mitigation device, what qualcomm's
`thermal-engine` uses to drive firmware side cooling. on some platforms a fan
appears here. querying it (`tools/fan/qmi-tmd.py`) works and returns `result=0`:

```
TMD node 5 (ADSP):
  cpuv_restriction_cold      level=0/1
TMD node 10 (CDSP):
  cpuv_restriction_cold      level=0/1
  cdsp_hw                    level=0/1
  cdsp_sw                    level=0/6
```

all cpu and dsp voltage and clock mitigations. no fan device. so the one
firmware thermal interface that can be reached does not control the fan.

the rest of the qmi fabric has nothing relevant either. service registry,
subsystem control, coresight tracing, slimbus, sensor core, and one unknown
service (5017) that returns an empty ack to every probe. `GET_SUPPORTED_MSGS`
is rejected by both tmd (error 57) and the sensor core (error 94), so there is
no further enumeration to do.

## where the fan actually lives

the device tree reserves memory for qualcomm's management engine:

```
tme-crash-dump@81ca0000     tme_crash_dump_mem
tme-log@81ce0000            tme_log_mem
```

plus `tmess_*` coresight trace nodes. tme owns platform thermal management and
drives the fan from its own sensor readings, entirely below and outside linux.
the ap is never given a pwm or a tach line for it, consistent with there being
no fan pin in the dt and no unclaimed pmic pin in a pwm function (the only one,
PMK8550 gpio5 func3, is the display backlight).

getting control would mean reverse engineering the tme interface. not aware of
anyone having done that for any snapdragon x laptop.

## what you can actually do

**indirectly.** the fan responds to die temperature, so anything that lowers
temperature lowers fan speed. this is where fixing cpufreq mattered
([cpufreq.md](cpufreq.md)). before that, six of ten cores had no throttling
path at all and the fan was the only response to heat. now the kernel backs off
clocks first.

**directly, but not the fan.** `tools/fan/qmi-tmd.py --set <dev> <level>` does write
real mitigation levels to firmware. `cdsp_sw` goes to level 6. this throttles
hardware and is not something to use normally, but the mechanism works if it is
ever needed.

## the tool

`tools/fan/qmi-tmd.py` is a small AF_QIPCRTR qmi client, worth keeping as a template
for any qualcomm firmware service. two things that are not obvious and cost
time:

- `bind()` returns EINVAL unless `getsockname()` is called first to learn the
  local node id, then bind with that. binding node 0 does not work.
- the device list tlv is `u8 count`, then per device `u8 name_len, name, u8
  max_level`, not the fixed 32 byte struct the qualcomm headers imply.
