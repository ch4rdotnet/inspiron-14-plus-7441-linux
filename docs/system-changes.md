# system changes

everything outside the kernel source that this machine needs. the patches in
`patches/` are only half of it, without the things below the machine boots but
has no gpu, battery, audio or cpufreq. listed in the order you'd apply them to
a fresh install. [INSTALL.md](../INSTALL.md) applies all of it.

## 1. firmware blobs

eleven dell signed files in `/lib/firmware/updates/qcom/x1e80100/dell/inspiron-14-plus-7441/`:

```
qcadsp8380.mbn  adsp_dtbs.elf  adspr.jsn  adsps.jsn  adspua.jsn  battmgr.jsn
qccdsp8380.mbn  cdsp_dtbs.elf  cdspr.jsn
qcdxkmsuc8380.mbn                          <- gpu zap shader
qcvss8380.mbn                              <- video
```

not redistributable, so not in linux-firmware. extracted with `7z` from the
dell latitude 7455 arm driver pack, same board, and the signatures authenticate
on the 7441. `scripts/install-firmware.sh`, details in [firmware.md](firmware.md).

without these: no gpu accel, no battery, no audio, no video.

## 2. firmware in the initramfs

`config/dracut/99-x1e80100-qcom-firmware.conf`, installed to `/etc/dracut.conf.d/`:

```
install_items+=" .../qcadsp8380.mbn .../adsp_dtbs.elf .../qccdsp8380.mbn .../cdsp_dtbs.elf "
```

`qcom_q6v5_pas` probes inside the initramfs and remoteproc's auto-boot does not
retry a failed `request_firmware()`, so the adsp stays offline for the whole
boot unless the images are in there too. `scripts/rebuild-initramfs.sh --all`,
re-run after every kernel install.

without this: battery and audio work until you reboot, then stop.

## 3. backlight modules in the initramfs

`config/dracut/99-x1e80100-backlight.conf`:

```
force_drivers+=" leds-qcom-lpg pwm_bl "
```

patch 0002 gives the panel a `backlight` phandle, which makes the display
depend on `pwm_bl`, which depends on `pmk8550_pwm`, driven by `leds-qcom-lpg`.
none of that is in a stock initramfs, so in the initrd `pwm-backlight` defers
on its pwm, `dp-aux` defers on the backlight, `msm` never finishes binding, and
the panel stays dark until about a second after switch-root. harmless while
the initrd had nothing to show, once the disk was encrypted it meant the luks
prompt was drawn on a dead display. details in
[luks-black-screen.md](luks-black-screen.md).

same rebuild as (2), `scripts/rebuild-initramfs.sh` installs both drop-ins.

## 4. getting scmi-cpufreq loaded

no cpufreq at all without this. it is separate from the turbo bug that patch
0001 fixes, the patch makes the driver work on all three clusters, this makes
the driver load in the first place.

### why it does not autoload

`modinfo scmi-cpufreq` shows zero alias lines, and so does every other scmi
module driver (`scmi-hwmon`, `scmi_iio`, `arm_scmi_powercap`,
`scmi-regulator`). two reasons, both structural:

- `scmi-cpufreq.c` does declare `MODULE_DEVICE_TABLE(scmi, scmi_id_table)`, but `scripts/mod/file2alias.c` has no scmi handler, so modpost cannot turn that table into an alias and the macro is a silent no-op.
- even with an alias it would not help. scmi devices are created on driver request, `scmi_protocol_device_request()` runs when a driver registers. observed directly, `scmi_dev.4:13:cpufreq` did not exist until `modprobe scmi-cpufreq`. udev would never have a device to match against.

so this cannot be fixed by patching scmi-cpufreq. pick one of the two below.

### method a, modules-load.d (no rebuild)

`/etc/modules-load.d/99-scmi-cpufreq.conf` containing `scmi-cpufreq`. works
with fedora's stock `CONFIG_ARM_SCMI_CPUFREQ=m`, useful if you are not building
a kernel. `tools/cpufreq/try-cpufreq.sh --persist` writes it. downside, a config file
that has to travel with the machine, and it loads late rather than at driver
registration time.

### method b, build it in (preferred, what this project does)

`config/kernel-local`:

```
CONFIG_ARM_SCMI_CPUFREQ=y
```

fedora already builds the sibling drivers in (`ARM_SCMI_PERF_DOMAIN=y`,
`ARM_SCMI_POWER_DOMAIN=y`), so this is consistent, not a hack. builtin means it
registers at boot, which is exactly what the scmi device model wants.
`CONFIG_CPU_FREQ` and `CONFIG_PM_OPP` need no change, both are bool, both
already `=y`, and `ARM_SCMI_CPUFREQ` selects `PM_OPP` anyway. if you use method
b, delete the modules-load conf from method a, harmless if left but it will try
to modprobe something that is no longer a module.

"build `ARM_SCMI_CPUFREQ=y` like the other two scmi drivers" is a much easier
bug report for fedora than "the scmi device model cannot autoload modular
drivers", see [upstreaming.md](upstreaming.md).

## 5. the video clock controller

also `config/kernel-local`:

```
CONFIG_SM_VIDEOCC_8550=m
```

fedora ships it off. see [video-decode.md](video-decode.md).

without this: no `/dev/video*`.

## 6. the tpm wait

`scripts/disable-tpm-wait.sh` masks `dev-tpm0.device` and `dev-tpmrm0.device`,
adds `rd.systemd.mask=` for both to the kernel command line with grubby (masking
in `/etc/systemd/system` does not reach the initramfs), and installs
`config/dracut/99-no-tpm.conf`. saves 90 seconds per boot. `--undo` reverts.
see [boot-time.md](boot-time.md).

## 7. speaker upmix and crossover

`config/pipewire/51-tweeter-upmix.conf` goes to both
`/etc/pipewire/client.conf.d/` and `/etc/pipewire/pipewire-pulse.conf.d/`
(pulse clients such as firefox don't read client.conf), and
`config/pipewire/52-speaker-crossover.conf` goes to
`/etc/pipewire/pipewire.conf.d/`. the 4 channel sink is FL,FR,RL,RR but the
rear pair are the tweeters. see [audio.md](audio.md).

without this: muffled sound.

## 8. journal sync, optional

`scripts/crash-capture.sh` writes `/etc/systemd/journald.conf.d/99-crash-capture.conf`:

```
[Journal]
SyncIntervalSec=1s
```

there have been four hangs and none was captured, so this is now recommended
rather than optional, with `--pm-debug` as well. see [hangs.md](hangs.md).
it costs extra writes on every boot, so it's its own step in
[INSTALL.md](../INSTALL.md) rather than folded into another script.

## 9. chromium v4l2 decode, optional

`scripts/browser-hwdec.sh` copies the desktop file of every installed chromium
family browser to `~/.local/share/applications/` with these flags on every
`Exec=` line:

```
--enable-features=V4L2VideoDecoder,AcceleratedVideoDecodeLinuxGL
--ignore-gpu-blocklist --enable-accelerated-video-decode
```

chromium's v4l2 path is a chromeos thing and off by default on desktop linux,
but it works here. firefox has no equivalent, it only does vaapi and there is
no vaapi driver for this hardware.

without this: browser video decodes on the cpu.

## not applied

- audio group. `scripts/fix-audio-acl.sh --permanent` would add the user to `audio` to dodge a `/dev/snd` acl race. the race has not recurred since it was seen once, so it was left alone.
- `CONFIG_CRYPTO_DEV_QCE`. deliberately off. the oryon cores have armv8 crypto extensions which beat the offload for most workloads.
- the diagnostic modules in `tools/camera/`. research tooling, built on demand against the running kernel.

## order on a fresh install

1. install the firmware blobs (1)
2. build a kernel with the patches and `config/kernel-local` (4, 5)
3. install it, then the dracut drop-ins (2, 3), rebuilt for all kernels
4. the tpm wait (6) and the pipewire drop-ins (7)
5. reboot
6. `scripts/verify.sh`

[INSTALL.md](../INSTALL.md) walks through it, one script per step.
