# backlight: the missing pwm in the device tree

the display works and the panel is lit, but brightness is stuck wherever
firmware left it (about 50%). the panel needs pwm brightness, not edp aux, and
the board dt had no backlight node at all. patch 0002 adds one.

## the hardware, established by inspection

`/sys/kernel/debug/gpio` shows uefi has already configured the pwm pin and left
it running, which is why the panel is lit at a fixed level:

```
gpiochip0 (c42d000.spmi:pmic@0:gpio@8800):
  gpio5 : out  low  func3   vin-0 pull-down 10uA   push-pull  medium
```

`pmic@0` is PMK8550, confirmed by its children rather than its own (misleading)
compatible:

```
pmic@0: qcom,pm8550 qcom,spmi-pmic
  gpio@8800   qcom,pmk8550-gpio qcom,spmi-gpio    status=okay
  pon@1300    qcom,pmk8350-pon                    status=okay
  rtc@6100    qcom,pmk8350-rtc                    status=okay
  pwm         qcom,pmk8550-pwm                    status=disabled   <-- pmk8550_pwm
```

so, PMK8550 gpio5, func3, driven by `pmk8550_pwm`, which the dt leaves
disabled.

tlmm `gpio74` (`edp_bl_en`) is separately `out high func0`, a plain gpio held
high. that is the enable line, and upstream already wires it as the panel's
`enable-gpios`.

`tools/backlight/find-bl-pwm.sh` is the script that found this. two things went wrong the
first time round: it filtered out unclaimed pins, which is exactly where a uefi
configured pin with no linux driver shows up, and it read pinctrl's generic
`pins` file, which shows nothing useful for qualcomm pmic gpios.
`/sys/kernel/debug/gpio` is the file that reports the actual hardware function.
the raw dumps are in `docs/evidence/backlight-pinctrl-dump.txt` and
`docs/evidence/backlight-pinctrl-dump-2.txt`.

this is the same arrangement as the hp omnibook x14, which does have a working
backlight (`x1-hp-omnibook-x14.dtsi`):

```dts
backlight: backlight {
        compatible = "pwm-backlight";
        pwms = <&pmk8550_pwm 0 5000000>;
        ...
        pinctrl-0 = <&edp_bl_en>, <&edp_bl_pwm>;
};
&pmk8550_gpios { edp_bl_pwm: edp-bl-pwm-state { pins = "gpio5"; function = "func3"; }; };
&pmk8550_pwm  { status = "okay"; };
```

## why the aux path could never work

with no `backlight` phandle on the panel, `panel-edp` falls back to
`drm_panel_dp_aux_backlight()` and tries to drive brightness over edp aux
(dpcd). the symptom:

```
$ cat /sys/class/backlight/dp_aux_backlight/max_brightness
0

systemd-backlight: dp_aux_backlight: Maximum brightness is 0, ignoring device.
gnome-shell: Failed creating backlight for Built-in display: Backlight is unusable
             because the maximum brightness 0 is bigger than minimum brightness 0
```

the panel is an AUO B140QAX01.H, detected by `panel-simple-dp-aux`. reading its
dpcd directly (`tools/backlight/edp-backlight.sh`):

```
0x700  DP_EDP_DPCD_REV                     0x05
0x701  DP_EDP_GENERAL_CAP_1                0x9b   (bit0 TCON adj set)
0x702  DP_EDP_BACKLIGHT_ADJUSTMENT_CAP     0x91   (bit0 PWM_PIN_CAP set, bit1 AUX_SET_CAP clear)
0x721  DP_EDP_BACKLIGHT_MODE_SET_REGISTER  0x00   (control mode = pwm pin, not dpcd)
0x722  DP_EDP_BACKLIGHT_BRIGHTNESS_MSB     0x02
0x723  DP_EDP_BACKLIGHT_BRIGHTNESS_LSB     0x00   (0x0200 = 512/1023 = 50%)
0x724  DP_EDP_PWMGEN_BIT_COUNT             0x0a   (10)
0x725  DP_EDP_PWMGEN_BIT_COUNT_CAP_MIN     0x04
0x726  DP_EDP_PWMGEN_BIT_COUNT_CAP_MAX     0x0a
```

`drm_edp_backlight_supported()` only tests 0x701 bit0, which is set, so a
backlight device is registered. but `drm_edp_backlight_init()` then computes
`aux_set` from 0x702 bit1, which is clear, and
`drm_edp_backlight_probe_max()` returns early leaving `max = 0`. the panel
advertises pwm pin brightness only. the bit count of 10 is a red herring, that
code path is never reached.

an earlier theory blamed the upstream "clamp pwm bit count to advertised min
and max" patch, which fixes panels reporting a bit count of zero. that is not
this panel and the patch would change nothing here. the stuck level of
512/1023 matches the observed ~50% exactly, and 0x721 reading `0x00` says the
panel is in pwm control mode.

`tools/backlight/edp-backlight.sh --set` refuses on this panel for that reason. forcing
dpcd mode on it gives a dimmer, degraded result, and `--restore` puts 0x721
back.

## the patch

`patches/out/dts/0001-arm64-dts-qcom-x1e80100-dell-inspiron-14-plus-7441-a.patch`,
the version sent upstream. it goes in the inspiron's own
`x1e80100-dell-inspiron-14-plus-7441.dts` rather than the shared
`x1-dell-thena.dtsi`, because the latitude 7455 was submitted with a different
panel and a working backlight, and only the inspiron has been tested. the dtsi
only gains a `panel:` label, so the latitude dtb doesn't change. deliberately
minimal, the panel keeps its existing `enable-gpios` and `edp_bl_en` pinctrl so
nothing about panel power sequencing changes. all that is added is the pwm:

```dts
/ {
	backlight: backlight {
		compatible = "pwm-backlight";
		pwms = <&pmk8550_pwm 0 5000000>;   /* 200 hz, as on the omnibook */

		brightness-levels = <0 2048 4096 8192 16384 65535>;
		num-interpolated-steps = <20>;
		default-brightness-level = <80>;

		pinctrl-0 = <&edp_bl_pwm>;
		pinctrl-names = "default";
	};
};

&pmk8550_gpios {
	edp_bl_pwm: edp-bl-pwm-state {
		pins = "gpio5";
		function = "func3";
	};
};

&pmk8550_pwm {
	status = "okay";
};
```

plus, through the new label:

```dts
&panel {
	backlight = <&backlight>;
};
```

the guessed values from the omnibook (channel 0, 5 ms period) turned out to be
right, so no tuning was required.

## how the dtb actually reaches the kernel

not from `/boot/dtb-<ver>/`, which tripped things up initially. the uki embeds
it:

```
/lib/modules/<ver>/vmlinuz-dtbloader.efi, 34 pe sections:
  .dtbauto   raw=211968     <- 25 of these, one per supported board
  ...
  .hwids     raw=11264      <- smbios match table
  .linux     raw=15153664
```

that is systemd-stub's device tree auto selection. the stub reads smbios,
matches against `.hwids`, and installs the matching `.dtbauto` section. editing
the on-disk dtb trees does nothing, they exist for other bootloaders and for the
uki build. `kernel-uki-dtbloader` ships the uki prebuilt from the kernel spec,
so a dts change has to go through a kernel rebuild (`scripts/build-kernel.sh`).

## status: working

built into `kernel-7.1.13-200.dellfix.fc44` and confirmed on hardware:

```
/sys/class/backlight/backlight: brightness=42/100  type=raw  scale=non-linear
/sys/class/pwm/pwmchip0:        npwm=2
modules:                        leds_qcom_lpg, qcom_pbs, led_class_multicolor
```

gnome's brightness slider works. the old useless `dp_aux_backlight` device
(max_brightness 0) is gone, replaced by a real `pwm-backlight`.

two `deferred probe pending` lines appear early in the boot log:

```
platform backlight: deferred probe pending: pwm-backlight: unable to request PWM
dp-aux ...: deferred probe pending: dp-aux: supplier backlight not ready
```

that is the snapshot taken before `leds-qcom-lpg` loaded. they resolve on the
rootfs and need no action there. inside the initramfs they do not resolve,
because the module is not in it, which is invisible until something has to be
drawn in the initrd. with a luks prompt that meant typing the passphrase on a
black screen. `config/dracut/99-x1e80100-backlight.conf`, installed by
`scripts/rebuild-initramfs.sh`, puts `leds-qcom-lpg` and `pwm_bl` in the
initramfs. see [luks-black-screen.md](luks-black-screen.md).

## known issue: brightness flashes bright before settling

changing brightness sometimes makes the panel flash bright before settling on
the new level. reproducible by clicking in gnome's brightness slider, so it is a
per change glitch, not anything to do with idle dimming.

not the dt table. an earlier theory blamed gnome's `idle-brightness = 30`
raising brightness from a lower current level. that explains a flash on idle
but not one from a single slider click (`tools/backlight/watch-brightness.sh` shows what
is writing the level and when).

where it likely is, from reading `drivers/leds/rgb/leds-qcom-lpg.c`:

- `lpg_calc_freq()` only runs when the period changes, and `pwm-backlight`
  holds the period at 5 ms, so the clock divider and pwm resolution are not
  being reselected per level. that rules out the most obvious candidate.
- `lpg_pwm_apply()` takes the lock, recalculates duty, and calls `lpg_apply()`,
  which ends with `lpg_apply_sync()` writing `PWM_SYNC_REG`. the lpg duty value
  spans two registers, so the suspicion is a non-atomic update, the hardware
  latching a half written value for one pwm period before the sync lands.

untested ideas, cheapest first:

1. try a different period (the 5 ms came from the hp omnibook). a shorter
   period makes any single period glitch less visible.
2. check whether the flash correlates with the `brightness-levels` segment
   boundaries at 20/40/60/80. `tools/backlight/bl-sweep.sh` steps through levels and
   dumps pwm state for exactly this.
3. if it is the two register latch, the fix belongs in `leds-qcom-lpg`, not in
   this dt.

cosmetic, and the backlight is otherwise fully working, so this is parked. see
[remaining.md](remaining.md).
