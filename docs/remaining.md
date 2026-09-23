# what is still open

everything that was broken at the start now works apart from the camera. this
is the leftover list, with enough context to pick each up cold.

## 1. brightness flashes bright before settling (cosmetic)

changing brightness sometimes flashes the panel bright before it settles.
reproducible by clicking in gnome's brightness slider, so it is a per change
glitch, not idle dimming.

ruled out: gnome's `idle-brightness` (that would only explain a flash on idle,
not on a single slider click), and the dt `brightness-levels` table.

leading theory: `lpg_pwm_apply()` in `drivers/leds/rgb/leds-qcom-lpg.c`
recalculates duty and calls `lpg_apply()`, which ends with `lpg_apply_sync()`
writing `PWM_SYNC_REG`. the duty value spans two registers, so the hardware may
latch a half written value for one pwm period. `lpg_calc_freq()` is not the
culprit, it only runs on period changes and `pwm-backlight` holds the period at
5 ms.

next step: `sudo tools/backlight/bl-sweep.sh` steps through levels dumping pwm state, to
see whether the flash correlates with particular values or with the
`brightness-levels` segment boundaries at 20/40/60/80. `tools/backlight/watch-brightness.sh`
shows what is writing the level. also worth trying a shorter pwm period in
patch 0002 (the 5 ms came from the hp omnibook), a single period glitch is less
visible at a higher frequency. if it is the two register latch, the fix belongs
in `leds-qcom-lpg`, not in the dt. details in [backlight.md](backlight.md).

## 2. hard hangs (four so far, three on the patched kernel)

the machine has frozen hard four times and needed a power cycle each time.
none left a kernel message, and crash capture was never turned on so up to
five minutes of log is missing from each. three of the four involve deep
suspend, one of them at suspend entry with nothing else running. the only
kernel warning on record is a pmic_glink altmode worker touching the type-c
retimer's i2c bus before it had resumed.

the full record, the hypotheses and the plan are in [hangs.md](hangs.md).
`scripts/hang-report.sh` reads the journal for the boots that ended in a hang.

next step, in this order: `sudo scripts/crash-capture.sh --pm-debug --panic`,
then a day on `s2idle` instead of `deep`, then a day on a kernel without the
camera patches.

## 3. 10 bit video always falls back to software (driver limitation)

the iris decoder's capture queue advertises only `NV12` and `Q08C`, both 8 bit.
no `P010`, no `Q10C`. so 10 bit and hdr content cannot be hardware decoded,
gstreamer fails caps negotiation with `not-negotiated (-4)` and players fall
back to software. not configurable, would need 10 bit output formats added to
the mainline iris driver. `scripts/test-hwdec.sh FILE` says which case a file
is. details in [video-decode.md](video-decode.md).

## 4. firefox gets no hardware video decode (architectural)

firefox's linux hardware decode goes exclusively through vaapi, and there is no
vaapi driver for this hardware. mesa's freedreno has no vaapi state tracker,
and nothing bridges v4l2 stateful m2m to vaapi.

chromium based browsers do work via `--enable-features=V4L2VideoDecoder`
(`scripts/browser-hwdec.sh`). mpv gets vp9 via `--hwdec=v4l2m2m-copy`.
gstreamer players (showtime, clapper) get everything. would need either a
vaapi driver over v4l2 stateful m2m, or a native v4l2 backend in firefox.
neither is a small job.

## 5. fan control (not possible today)

the fan curve is autonomous. there is an ec at 0x3b on `i2c-3` (`b94000.i2c`)
and it answers block reads with what look like temperature triplets, but the
dsdt's fan read command returns the same telemetry buffer as the plain read,
the only `_DSM` the firmware implements on the fan uuid is "tell the ec the
current temperature", and the temperatures did not move between 41 c idle and
109 c under a kernel build. the one reachable firmware thermal interface, qmi
tmd (service 24 on the adsp and cdsp), lists only cpu and dsp voltage and clock
mitigations.

next step: sweep the ec block read command codes for one whose data tracks
temperature or fan state, re-check the `0xfb` framing (the acpi
`AttribRawProcessBytes` wire format may include a length byte), and look at the
`EC5A` and `EC6B` to `EC7A` offsets the dsdt bothers to name.
`tools/fan/probe-ec.sh` is the read only starting point, `tools/fan/qmi-tmd.py` the qmi
client. this is a live ec on a shared bus, don't blind write. full
investigation in [fan-control.md](fan-control.md).

indirectly, the fan responds to die temperature, so fixing cpufreq lowered it,
before that six of ten cores had no throttling path and the fan was the only
response to heat.

## 6. camera (sensor works, the csiphy never locks)

full write-up in [camera.md](camera.md). the sensor is an omnivision OV02E10
(front) with a himax HM1092 aux sensor, on cci1 master 1 (the always-on i2c
pins) at 0x10. `CONFIG_VIDEO_OV02E10=m` is upstream and binds it, no sensor
driver work was needed.

two genuine upstream bugs were found and fixed getting this far, both worth
sending regardless of the camera:

| | |
|---|---|
| camcc mclk divider (patch 0004) | `bi_tcxo` is 38.4 mhz here but the table assumes 19.2, so every mclk came out 2x and 19.2 mhz was unobtainable. `ov02e10` refuses to probe at any other rate. |
| csiphy reg windows (in patch 0005) | 4 kb in the binding against 8 kb of hardware. the driver programs this soc's csiphy at `+0x1000`, so any attempt to stream oopsed the kernel in `csiphy_reset`. |

what works: the sensor probes, enumerates in the media graph, takes its full
register table and the stream-on write, mclk4 runs at exactly 19.2 mhz, vfe
and csid report their versions and the rdi write master is programmed for
1928x1088.

what does not: the csiphy never locks and no frames arrive. eliminated by
sweeping with the out-of-tree modules in `tools/camera/` (each test a module
reload rather than a rebuild): all four csiphys, six analog rail combinations,
and five lane mappings.

next step: the two remaining explanations need either qualcomm's downstream
tree for x1e80100 or a logic probe on the mipi lanes. either the x1e80100
csiphy lane programming in upstream camss has never been run against a real
sensor, or the always-on camera feeds a receiver camss does not model (the
dsdt lists an unidentified 48 kb block at `0x0ac19000`). `tools/camera/capture-camera.sh`
is the capture harness, `tools/camera/probe-cci.sh` the bus check.

## not doing

- crypto engine. `1dfa000.crypto` (`qcom,x1e80100-qce`) is unbound because `CONFIG_CRYPTO_DEV_QCE` is off. leaving it, the oryon cores have armv8 crypto extensions (`aes pmull sha1 sha2 sha3 sha512`) which generally beat the offload, each offload costs a descriptor round trip.
- cpu7 and cpu11 not booting. `psci ... -22`. the dt describes 12 cores, this x1p bin has 10. confirmed cosmetic, see [soc.md](soc.md).
