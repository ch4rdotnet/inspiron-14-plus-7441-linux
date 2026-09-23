# patches

six kernel patches, `git format-patch` output. three in `out/` that everyone
wants, and three in `camera/` that only matter if you're working on the camera,
since it doesn't produce frames yet.

`out/` is exactly what was sent upstream, cover letter, recipient lists, file
names and all, so don't edit anything in it. the scmi patch went on its own and
the two dts ones as a series, which is why `out/` numbers them separately. the
rest of the docs call them 0001 to 0003:

| name in the docs | file |
|---|---|
| 0001 | `out/scmi/0001-firmware-arm_scmi-perf-ignore-an-implausible-sustain.patch` |
| 0002 | `out/dts/0001-arm64-dts-qcom-x1e80100-dell-inspiron-14-plus-7441-a.patch` |
| 0003 | `out/dts/0002-arm64-dts-qcom-x1e80100-dell-inspiron-14-plus-7441-f.patch` |

apply them in that order with `git am`, then the camera ones on top if wanted:

```
git am patches/out/scmi/0001-*.patch patches/out/dts/000[12]-*.patch
git am patches/camera/*.patch             # 0004 to 0006, optional
```

`scripts/build-kernel.sh` folds the same set into the fedora spec's
`linux-kernel-test.patch` hook, leaving out the cover letter, and `--camera`
adds `camera/*.patch` after them (built as `.dellcam` so it doesn't replace the
normal kernel). `PATCHES=...` overrides both. the config change that goes with
them is in `config/kernel-local`, not here.

the camera patches haven't been sent, 0004 is ready, 0005 needs splitting, 0006
is bring-up only. see [docs/upstreaming.md](../docs/upstreaming.md).

| patch | file | status |
|---|---|---|
| 0001 firmware: arm_scmi: perf: ignore an implausible sustained frequency | `drivers/firmware/arm_scmi/perf.c` | sent |
| 0002 arm64: dts: qcom: x1e80100-dell-inspiron-14-plus-7441: add PWM backlight | board dts, a label in `x1-dell-thena.dtsi` | sent |
| 0003 arm64: dts: qcom: x1e80100-dell-inspiron-14-plus-7441: fix touchscreen i2c address | board dts | sent |
| **camera/** | | |
| 0004 clk: qcom: camcc-x1e80100: fix MCLK rates for the 38.4 MHz XO | `drivers/clk/qcom/camcc-x1e80100.c` | tested, needs a signoff |
| 0005 arm64: dts: qcom: hamoa: add camss, camcc and CCI | `hamoa.dtsi` | works, needs splitting for upstream |
| 0006 arm64: dts: qcom: x1-dell-thena: add the front camera | `x1-dell-thena.dtsi` | bring-up only, not for upstream |

## 0001, scmi sustained frequency

the scmi firmware reports a `sustained_freq_khz` below the lowest opp for two of
the three perf domains, so every opp in them is flagged turbo,
`cpufreq_frequency_table_cpuinfo()` skips them all and returns `-EINVAL`, and
the policy is dropped without a message. only 4 of 10 cores got cpufreq and
there was no cpu cooling device at all. it can't be worked around from
userspace because `policy->boost_enabled` is only set after that validation.

the patch computes the lowest opp first and ignores a sustained frequency below
it, with a one time `FW_BUG` warning since the failure was silent before. no-op
on firmware that reports a sane value.

tested. three policies instead of one, idle draw ~12 w to ~8 w.
[docs/cpufreq.md](../docs/cpufreq.md)

## 0002, pwm backlight

the AUO B140QAX01.H can't do brightness over edp aux (dpcd 0x702 has
`BRIGHTNESS_PWM_PIN_CAP` set and `BRIGHTNESS_AUX_SET_CAP` clear), so with no
`backlight` phandle panel-edp registers a backlight with `max_brightness = 0`.
brightness is on PMK8550 gpio5 func3, driven by `pmk8550_pwm`, which uefi
leaves configured and the dt leaves disabled. same wiring as the hp omnibook
x14, described the same way. the panel keeps its `enable-gpios`, so power
sequencing doesn't change. it lives in the inspiron dts rather than the shared
thena dtsi, which only gains a `panel:` label, because the latitude 7455 has a
different panel and only the inspiron has been tested.

tested. the slider works. one glitch, the panel flashes bright before settling
on a new level, suspected to be the lpg's two register duty latch rather than
this dt. [docs/backlight.md](../docs/backlight.md)

## 0003, touchscreen address

the dt put the touchscreen at 0x10. nothing is there, it's at 0x09, which
returns a valid hid-over-i2c descriptor (vid 0x29bd, pid 0x1103) for a windows
precision touchscreen. found by an i2c bus scan while looking for a fan
controller.

tested. `i2c_hid_of` binds at 0-0009 and the device shows up as
`hid-over-i2c 29BD:1103`. [docs/touchscreen.md](../docs/touchscreen.md)

## 0004, camcc mclk divider

the mclk frequency table assumes a 19.2 mhz reference but `bi_tcxo` is 38.4 mhz
on this soc, so every rate comes out at twice its label and 19.2 mhz is
unobtainable. `ov02e10` refuses to probe at any other rate. one line, halve the
pre-divider on the 19.2 mhz entry. the pll sourced rates are left alone, they
haven't been measured.

tested, mclk4 runs at exactly 19.2 mhz. [docs/camera.md](../docs/camera.md)

## 0005, camss, camcc and cci for hamoa

adds the isp, its clock controller and both cci controllers to the soc dtsi.
camss and camcc come from the binding examples with one correction, the csiphy
register windows are 8 kb not 4 kb, the driver programs this soc's csiphys at
`+0x1000` so a 4 kb mapping oopses the kernel in `csiphy_reset()` on any
attempt to stream. the cci register bases came from the dsdt this machine's
uefi hands to windows, and the interrupts were measured on the hardware rather
than guessed (sm8550's address layout with sa8775p's interrupt assignment).

works, both ccis come up and camss streams from the sensor's point of view.
for upstream the csiphy size fix should go on its own, and cci wants a proper
`qcom,x1e80100-cci` compatible in the binding rather than borrowing
`qcom,msm8996-cci`. [docs/camera.md](../docs/camera.md)

## 0006, the front camera on thena

the sensor node, the csiphy port, and the always-on i2c bus for the
OmniVision OV02E10. the sensor probes, enumerates in the media graph, takes
its register table and the stream-on write, and the vfe write master is
programmed. no frames arrive, the csiphy never locks. csiphy0, the lane
mapping and the avdd/dvdd rails are all unverified guesses and the patch says
so. not for upstream in this form. [docs/camera.md](../docs/camera.md)

## where they went

- 0001 to the arm_scmi maintainers, `arm-scmi`, `linux-arm-kernel`, cc stable
- 0002 and 0003 as one series to the qcom dt maintainers, `linux-arm-msm`, `devicetree`
- `out/*/recipients.txt` has the exact lists, from `get_maintainer.pl` on each base

still to go, 0004 to `linux-clk` and `linux-arm-msm`, 0005 and 0006 to
`linux-arm-msm` and `devicetree` once they're ready, and the
`CONFIG_SM_VIDEOCC_8550` and `CONFIG_ARM_SCMI_CPUFREQ=y` changes to fedora's
kernel bugzilla.

0006 was rebased onto the sent 0002. its camss and cci nodes used to sit next to
the backlight nodes in the thena dtsi, and those moved to the inspiron dts. the
content is unchanged. all six apply in order to fedora's 7.1.13 source, and the
7441 and 7455 dtbs build with and without the camera patches.
