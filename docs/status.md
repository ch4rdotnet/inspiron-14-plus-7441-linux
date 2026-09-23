# status

baseline fedora 44 workstation, aarch64, linux-firmware 20260810. running
kernel `7.1.13-200.dellfix.fc44` with all six patches (`patches/out/` and `patches/camera/`) and the
config from `config/kernel-local`. assessed 2026-09-07, updated as things were
fixed.

upstream support for the machine itself is already in the kernel, the board dts
landed in 6.16 and fedora ships `x1e80100-dell-inspiron-14-plus-7441.dtb`.
most of what was broken traced to one missing class of file, the dell signed
qualcomm firmware ([firmware.md](firmware.md)). the rest came down to a kernel
bug, two device tree gaps, and a disabled fedora config option, one document
each.

everything below that describes a failure has since been fixed unless it says
otherwise. the diagnoses are kept because they show how each was established.
the open list is in [remaining.md](remaining.md).

## table

| subsystem | state | notes |
|---|---|---|
| boot, storage | works | |
| display (edp panel, modeset) | works | |
| backlight brightness | works | pwm backlight added to the dt, [backlight.md](backlight.md) |
| touchscreen | works | dt had the wrong i2c address, [touchscreen.md](touchscreen.md) |
| external dp over usb-c | untested | the adsp is up now so it should work, nobody has tried |
| keyboard, touchpad, power button | works | |
| wifi 7 (WCN785x, ath12k) | works | |
| bluetooth | works | |
| usb (all ports, hubs, dongles) | works | |
| microsd reader | works | |
| thermal sensors | works | 59 zones |
| gpu acceleration | works | zap shader from the dell firmware, zero errors since |
| battery and charging status | works | adsp firmware, plus the initramfs fix |
| audio | works | speakers, headphones, jack. crossover in [audio.md](audio.md) |
| hardware video decode and encode | works | needed `CONFIG_SM_VIDEOCC_8550=m`, [video-decode.md](video-decode.md) |
| cpu frequency scaling | works | all 10 cores, 3 policies, kernel patch, [cpufreq.md](cpufreq.md) |
| battery runtime | ~8 w idle | was ~12 w before cpufreq was fixed |
| fingerprint (goodix 27c6:631c) | works | `goodixmoc` in libfprint |
| suspend and resume (`deep`) | works | the adsp survives it |
| stability | four hard hangs, three on the patched kernel | no kernel message captured, three involve deep suspend, [hangs.md](hangs.md) |
| camera | in progress | sensor probes and streams, the csiphy never locks, [camera.md](camera.md) |
| fan | not controllable | the ec is reachable but its curve is autonomous, [fan-control.md](fan-control.md) |
| cpu7, cpu11 | never boot | x1p bin on an x1e device tree, cosmetic, [soc.md](soc.md) |

## gpu, adreno x1-85

fixed by `qcdxkmsuc8380.mbn`. the gmu firmware and sqe microcode always loaded
fine (they ship in linux-firmware), the zap shader, the signed trustzone blob
that takes the gpu out of secure mode, was the only missing piece.

before and after, counted over a whole boot:

| kernel message | before | after |
|---|---|---|
| `zap_shader_load_mdt ... *ERROR* Unable to load` | dozens | 0 |
| `adreno_load_gpu ... gpu hw init failed: -2` | dozens | 0 |
| `a6xx_gmu_set_oob ... Timeout waiting for GMU OOB` | dozens | 0 |

the zap shader does not need to be in the initramfs, `msm` retries lazily and
picks the firmware up after switch-root:

```
[drm:adreno_request_fw [msm]] loaded qcom/gen70500_sqe.fw from new location
[drm:adreno_request_fw [msm]] loaded qcom/gen70500_gmu.bin from new location
[drm] Loaded GMU firmware v4.3.17
```

mesa 26.1.8 already ships `msm_dri.so` and `freedreno_icd.aarch64.json`, so
userspace needed no work. `glxinfo -B` from a desktop session names an adreno
device with `Accelerated: yes` instead of llvmpipe.

## battery and the adsp

there is no traditional ec on the battery path. battery and charger state come
from the pmic, reached over `pmic_glink`, glink, and a service running on the
adsp. with the firmware in the initramfs the adsp boots cleanly every time:

```
remoteproc remoteproc0: Booting fw image qcom/x1e80100/dell/inspiron-14-plus-7441/qcadsp8380.mbn, size 22021416
remoteproc remoteproc1: remote processor cdsp is now up
remoteproc remoteproc0: remote processor adsp is now up
PDR: Indication received from msm/adsp/charger_pd, state: 0x1fffffff, trans-id: 1
PDR: Indication received from msm/adsp/audio_pd, state: 0x1fffffff, trans-id: 1
```

and the battery reports real values:

```
model:               DELL WYJ4543R      vendor: SWD-COS4.843
state:               charging           charge-cycles: 6
energy-full:         46.43 Wh           energy-full-design: 54 Wh
voltage:             12.165 V           energy-rate: 46.093 W
```

before the firmware, `qcom_battmgr` registered `qcom-battmgr-{ac,bat,usb,wls}`
but had no adsp to answer, so everything read zero and gnome showed
`battery-missing-symbolic`. uefi boots the adsp with a cut-down image that
handles charging only (which is why the machine charged regardless), linux has
to restart it with the full image to get battery reporting, usb-c pd and ucsi,
and displayport altmode.

no userspace pd-mapper is needed on fedora, the kernel ships the in-kernel
`qcom_pd_mapper` module and it autoloaded on its own the moment the adsp came
up. (an earlier draft of these notes said otherwise, that was wrong.)

## audio

the same missing file. the board dt uses the audioreach path
(`qcom,q6apm-lpass-dais`, `qcom,q6prm-lpass-clocks`), so the lpass dais and the
lpass clocks are provided by q6 services on the adsp. no adsp, no clocks, no
pinctrl, no card, and the visible symptom was:

```
platform 6e80000.pinctrl: deferred probe pending:
    qcom-sm8550-lpass-lpi-pinctrl: Failed to get clk 'core'
```

the topology file was never the issue, `X1E80100-Dell-Inspiron-14p-7441-tplg.bin.xz`
ships in linux-firmware and the latitude 7455 symlinks to it. once the adsp ran,
the whole chain came up on its own:

```
wcd938x_codec audio-codec: bound sdw:2:0:0217:010d:00:4
wcd938x_codec audio-codec: bound sdw:3:0:0217:010d:00:3
systemd[1]: Reached target sound.target - Sound Card.
```

with `q6prm_clocks q6apm_lpass_dais q6apm_dai snd_q6dsp_common q6prm snd_q6apm
fastrpc apr qrtr_smd qcom_pd_mapper snd_soc_wsa884x reset_gpio` autoloading.
the card registers every boot with four pcms and a jack input:

```
0 [X1E80100DellIns]: x1e80100 - X1E80100-Dell-Inspiron-14p-7441
                     DellInc.-Inspiron14Plus7441-047JFG
00-00: MultiMedia1 Playback   00-02: MultiMedia3 Capture
00-01: MultiMedia2 Playback   00-03: MultiMedia4 Capture
input: X1E80100-Dell-Inspiron-14p-7441 Headset Jack as .../card0/input9
```

ucm was not a problem either, alsa-ucm ships
`Qualcomm/x1e80100/Dell-Latitude-7455.conf` whose condition
`Regex "Dell Inc.*(Latitude|Inspiron).*"` already matches this machine.

one thing that happened once and has not recurred: the card appeared mid way
through gdm starting, so logind's uaccess rule gave the `/dev/snd` acl to
`gdm-greeter` and pipewire had no local sinks. `scripts/fix-audio-acl.sh` is
the fix if it comes back. the speakers sounded muffled until the tweeter upmix
and crossover in [audio.md](audio.md).

## the initramfs trap

installing the firmware on the root filesystem is not sufficient.
`qcom_q6v5_pas` probes while still in the initramfs, remoteproc has `auto_boot`
set, so it calls `request_firmware()` immediately, and on failure it never
retries:

```
remoteproc remoteproc0: adsp is available
remoteproc remoteproc0: Direct firmware load for .../qcadsp8380.mbn failed with error -2
remoteproc remoteproc0: powering up adsp
remoteproc remoteproc0: request_firmware failed: -2
```

those lines carry pre rtc sync timestamps, which is how you can tell they come
from the initramfs stage. the adsp then stays `offline` for the rest of the
boot. this is why the gpu worked after a reboot but the battery did not, `msm`
retries lazily and remoteproc does not. `scripts/rebuild-initramfs.sh` adds the
adsp and cdsp images via a dracut `install_items` drop-in, and has to be run
again after every kernel install.

## cpu frequency scaling

two separate problems. on a stock fedora kernel there is no cpufreq policy at
all, because `scmi-cpufreq` is never loaded (`modinfo` shows no alias lines,
and the scmi core only creates the `cpufreq` device once the driver registers
and requests it). scmi itself is healthy:

```
arm-scmi arm-scmi.0.auto: SCMI Protocol v2.0 'Qualcomm:' Firmware version 0x20000
scmi-perf-domain scmi_dev.3: Initialized 3 performance domains
```

loading it by hand gets one policy of three. the other two clusters fail
silently because the firmware reports a bogus `sustained_freq_khz` for perf
domains ncc1 and ncc2, every opp gets flagged turbo, and the cpufreq core
rejects the table with `-EINVAL`. full writeup and patch in
[cpufreq.md](cpufreq.md). with patch 0001 and `CONFIG_ARM_SCMI_CPUFREQ=y`:

```
policy0: cpus=[0 1 2 3]  drv=scmi gov=schedutil  cur=2976000 kHz
policy4: cpus=[4 5 6]    drv=scmi gov=schedutil  cur=998400 kHz
policy8: cpus=[8 9 10]   drv=scmi gov=schedutil  cur=806400 kHz
```

all three report an empty `scaling_boost_frequencies`, each exposes the full
13 frequency table, and the clusters sit at different frequencies under light
load. the machine also gained its first cpu throttling path, `cpufreq-cpu0`,
`cpufreq-cpu4` and `cpufreq-cpu8` cooling devices, where before only the gpu
devfreq and the pcie link existed. idle draw fell from ~12 w to ~8 w.

## backlight

the panel works and the backlight is on, but the level was stuck wherever
firmware left it:

```
$ cat /sys/class/backlight/dp_aux_backlight/max_brightness
0
systemd-backlight: dp_aux_backlight: Maximum brightness is 0, ignoring device.
```

the panel (AUO B140QAX01.H) has `enable-gpios` and `power-supply` but no
`backlight` phandle, so `panel-edp` falls back to aux brightness. reading the
dpcd shows the panel is in pwm control mode (0x721 = 0x00) and cannot set
brightness over aux at all (0x702 bit1 clear), so
`drm_edp_backlight_probe_max()` bails with max 0. an earlier draft blamed the
upstream "clamp pwm bit count" patch, that fixes panels reporting zero bits and
was wrong for this one.

fixed by patch 0002, a `pwm-backlight` on pmk8550 gpio5 func3, the pin uefi had
already configured. see [backlight.md](backlight.md). one cosmetic glitch
remains, the panel flashes bright before settling on a new level.

## touchscreen

dead on a stock kernel because the dt puts it at i2c 0x10 and it is at 0x09.
found by scanning the bus while hunting for a fan controller. patch 0003, see
[touchscreen.md](touchscreen.md).

## hardware video decode

```
qcom-iris aa00000.video-codec: deferred probe timeout, ignoring dependency
qcom-iris aa00000.video-codec: probe with driver qcom-iris failed with error -110
```

`-110` is a dependency that never appeared, not a missing firmware file. the
video clock controller had no driver because fedora ships
`CONFIG_SM_VIDEOCC_8550` off. one config option, see
[video-decode.md](video-decode.md).

## fingerprint

goodix `27c6:631c` on internal usb, handled by libfprint's `goodixmoc` driver
as "Goodix MOC Fingerprint Sensor (press)". nothing to configure beyond
enrolling with `fprintd-enroll` or gnome settings, `fprintd-pam` wires it into
login and sudo. (an earlier draft said there was no driver for this part,
assumed from the vendor id rather than checked against libfprint's table.)

## suspend and resume

`deep` is the default `mem_sleep`. a ~7 minute cycle with the adsp and cdsp
running completed cleanly:

```
PM: suspend entry (deep)
PM: suspend devices took 0.134 seconds
PM: resume devices took 0.310 seconds
Restarting tasks: Done
PM: suspend exit
```

both remoteprocs were still `running` afterwards and the battery kept
reporting. one cosmetic gripe at suspend time, `gnome-shell: Cursor update
failed: drmModeAtomicCommit: Invalid argument`, with no visible consequence.

## battery reporting is accurate

worth stating plainly, because a post resume reading of "0% / unknown" looked
alarming and wasn't. `POWER_NOW` was checked against the `ENERGY_NOW` delta
over 90 seconds:

```
ENERGY_NOW: 4.540 -> 5.650 Wh over 90s
implied charge power: 44.4 W
POWER_NOW reports:    44.9 W      consistent
```

so the gauge is real and `scripts/powerlog.sh` can be trusted. two things
explained the scary reading: the battery genuinely was flat
(`POWER_SUPPLY_CYCLE_COUNT` ticked 6 to 7), and `POWER_SUPPLY_ENERGY_EMPTY` is
4.18 wh, not zero, while upower computes percentage from
`ENERGY_NOW / ENERGY_FULL` and ignores it. the `unknown` state is battmgr not
yet having fresh data from the adsp right after resume, it resolves within a
few seconds.

## stability

four hard hangs, three of them on `dellfix` within two days (2026-09-09 and
10). none logged anything, the journal simply stops, and journald's five
minute sync interval means the last minutes are gone each time. three of the
four involve deep suspend, one froze at `PM: suspend entry (deep)` a minute
after boot with nothing else running. one resume logged an
`i2c i2c-4: Transfer while suspended` warning from the pmic_glink altmode
worker. the record, the suspects and the plan are in [hangs.md](hangs.md).
`scripts/crash-capture.sh --pm-debug --panic` is the prerequisite for learning
anything from the next one.
