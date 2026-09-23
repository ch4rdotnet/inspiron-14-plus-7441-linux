# an x1 plus running an x1 elite device tree

worth stating up front because it explains one oddity and gets blamed for
others.

the soc does not identify as an x1e-80-100:

```
$ cat /sys/devices/soc0/soc_id /sys/devices/soc0/revision
615
2.1
```

the kernel's table only knows `QCOM_ID_X1E80100 = 555`, and 615 falls in a gap
in `include/dt-bindings/arm/qcom,ids.h` (603, 604, then 618), so it is not a
recognised id upstream at all. meanwhile the device tree declares
`compatible = "qcom,x1e80100"`, because that is the dtsi the enablement series
used. the inspiron 14 plus 7441 actually ships a snapdragon x plus x1p-64-100
bin.

the clusters are not uniform either. cluster 0 reports a different silicon
variant from the other two:

| cpus | cluster | midr | variant |
|---|---|---|---|
| 0 to 3 | 0 | `0x512f0011` | 2 |
| 4 to 6 (7 dead) | 1 | `0x511f0011` | 1 |
| 8 to 10 (11 dead) | 2 | `0x511f0011` | 1 |

all ten report `cpu_capacity = 1024` and the dt has no `capacity-dmips-mhz`, so
the scheduler treats them as identical. all three perf domains expose the same
13 opps, 710400 to 3417600 khz, so that is probably harmless here, but it is
the sort of asymmetry a proper x1p dtsi would describe. the upstream series
anticipated this, its v3 changelog renamed the shared dtsi to an `x1-` prefix
explicitly "for future x1p model support".

## what the mismatch definitely causes

cpu7 and cpu11 fail to boot:

```
psci: failed to boot CPU7 (-22)
psci: failed to boot CPU11 (-22)
```

the x1e80100 dtsi declares 12 cpus, this part has 10. cosmetic, and proven not
to affect cpufreq, taking cpu3 offline to give cluster 0 the same
present-but-not-online shape did not break policy0 (see
[cpufreq.md](cpufreq.md)).

## what it plausibly explains, unproven

the bogus sustained frequency that patch 0001 works around. cluster 0, the one
with the different midr variant, is also the only perf domain reporting a valid
`sustained_freq_khz`. that looks like firmware perf attributes populated
properly for the prime cluster and not the others on this bin. the dt is not
the mechanism, scmi is a firmware to kernel interface and what the device tree
claims cannot change what scmi reports. it is a firmware shortcoming on this
part, which being a lightly validated x1p bin may well explain.

## what it does not explain

the backlight (a panel dpcd capability), the battery, audio and gpu firmware
(oem code signing), the touchscreen address, the `qcom-iris` failure (a distro
config option), or the hang.
