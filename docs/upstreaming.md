# upstreaming

0001 to 0003 have been sent, and `patches/out/` holds exactly what went out,
cover letter and recipient lists included. they
were generated against linux-next, the base commit is at the end of each, and
they also apply to fedora's 7.1.13. the camera patches in `patches/camera/`
haven't been sent. not everything on this machine is supported yet (see
[remaining.md](remaining.md)), what follows is what's been sent and what isn't
ready.

`scripts/get_maintainer.pl` in the kernel tree gives the exact recipient list
for each file, the lists below are the obvious ones.

## patches

| patch | where | state |
|---|---|---|
| 0001, `out/scmi/0001-firmware-arm_scmi-perf-ignore-an-implausible-sustain.patch` | arm-scmi, linux-arm-kernel, the arm_scmi maintainers, stable | sent. a real kernel bug, `Fixes:` the commit that added turbo marking. |
| 0002, `out/dts/0001-arm64-dts-qcom-x1e80100-dell-inspiron-14-plus-7441-a.patch` | linux-arm-msm, devicetree, the qcom dt maintainers | sent, 1/2 of the dts series. in the inspiron dts, not the thena dtsi, until a latitude 7455 owner confirms the same wiring. one cosmetic flash glitch that is probably `leds-qcom-lpg`, not this dt. |
| 0003, `out/dts/0002-arm64-dts-qcom-x1e80100-dell-inspiron-14-plus-7441-f.patch` | linux-arm-msm, devicetree | sent, 2/2 of the dts series. the touchscreen has never worked upstream. |
| 0004, `camera/0004-clk-qcom-camcc-x1e80100-fix-MCLK-rates-for-the-38.4-.patch` | linux-clk, linux-arm-msm | ready and tested (mclk4 reads exactly 19.2 mhz), needs a `Signed-off-by` added. only the 19.2 mhz entry is touched, the pll sourced rates were not measured. |
| 0005, `camera/0005-arm64-dts-qcom-hamoa-add-camss-camcc-and-CCI.patch` | linux-arm-msm, devicetree, linux-media | not ready as one patch. the csiphy reg size fix (8 kb, not the binding example's 4 kb, any stream attempt oopses otherwise) should be split out, it is ready on its own. the cci nodes use `qcom,msm8996-cci` as the generic v2 compatible, `qcom,i2c-cci.yaml` needs an x1e80100 entry sorted out first. the interrupts were measured, not inferred, and that reasoning is in the commit message. |
| 0006, `camera/0006-arm64-dts-qcom-x1-dell-thena-add-the-front-camera.patch` | none yet | bring-up only, and marked as such in the patch itself. csiphy0, the lane mapping, and the avdd and dvdd rails are unverified, and the `regulator-always-on` on `vreg_cam_1p8` is a workaround. not for upstream until frames arrive. |

background for 0001 is in [cpufreq.md](cpufreq.md), 0002 in
[backlight.md](backlight.md), 0003 in [touchscreen.md](touchscreen.md), and
0004 to 0006 in [camera.md](camera.md). those have the full traces, the things
that were ruled out, and how each was confirmed.

a second, independent hardening for 0001 would be in
`cpufreq_frequency_table_cpuinfo()`: if skipping boost entries leaves the
table empty, fall back to counting them rather than returning `-EINVAL`, since
a policy cannot enable boost before it exists. this kernel already carries scmi
quirks for the platform (`quirk_perf_level_get_fc_force`,
`quirk_clock_rates_triplet_out_of_spec`), so a quirk entry would be an equally
reasonable home for the workaround if the maintainers prefer it.

## not patches

| item | where | notes |
|---|---|---|
| enable `CONFIG_SM_VIDEOCC_8550` on aarch64 | fedora kernel bugzilla | the driver already matches `qcom,x1e80100-videocc` and its kconfig help names the platform. the only thing between a supported x1e80100 laptop and working video decode. already on for `SM_VIDEOCC_8250`, `SM_VIDEOCC_8350`, `SC_VIDEOCC_7280`. the smallest change here and it helps every fedora x1e user. |
| build `CONFIG_ARM_SCMI_CPUFREQ=y` like the other scmi drivers | fedora kernel bugzilla | a modular scmi driver can never autoload (no file2alias handler, and the device is only created on driver request). fedora already builds `ARM_SCMI_PERF_DOMAIN` and `ARM_SCMI_POWER_DOMAIN` in. |
| the latitude 7455 firmware authenticates on the 7441 | linux-firmware, the fedora snapdragon wiki page | not a patch, but the finding that unblocked everything else, and it does not appear to be documented anywhere. dell would have to grant redistribution for the 7441 directory itself, as it did for the xps 13 9345. |

## in rough order of value to others

1. fedora enabling `CONFIG_SM_VIDEOCC_8550`
2. the scmi sustained frequency patch (0001)
3. the csiphy reg size fix and the camcc mclk divider (from 0005, and 0004)
4. the pwm backlight and the touchscreen address (0002, 0003)
5. documenting that latitude 7455 firmware works on the 7441
