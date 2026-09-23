# the luks prompt is invisible: no display for the whole initrd

## symptom

after adding luks, the disk password prompt is on a black screen. the keyboard
works, typing the passphrase blind unlocks the disk and the machine boots
normally, but nothing is drawn until the desktop appears.

removing `quiet` (and `rhgb`) does not help. that is the tell, it is not
plymouth covering the console, there is no working display at all.

## cause

patch 0002 gave the panel a `backlight` phandle ([backlight.md](backlight.md)).
that created a probe dependency chain:

```
panel (aux-bus)  ->  backlight (pwm-backlight, pwm_bl)  ->  pmk8550_pwm (leds-qcom-lpg + qcom_pbs)
```

`leds-qcom-lpg` is not in the initramfs, so the chain never completes there.
from one boot, `journalctl -b -o short-monotonic`:

```
[ 2.260957] [drm] Initialized simpledrm 1.0.0 for simple-framebuffer.0 on minor 0
[ 2.261071] simple-framebuffer.0: [drm] fb0: simpledrmdrmfb frame buffer device
[ 3.871728] Starting plymouth-start.service - Show Plymouth Boot Screen...
[ 6.521049] display-controller@ae01000: Fixed dependency cycle(s) with ...   <- msm binding, in the initrd
[ 6.785769] Started systemd-ask-password-plymouth.service                    <- the luks prompt
[16.912822] platform backlight: deferred probe pending: pwm-backlight: unable to request PWM
[16.912109] dp-aux aux-aea0000.displayport-controller: deferred probe pending:
                                                       dp-aux: supplier backlight not ready
[44.811658] Finished systemd-cryptsetup@luks-...          <- passphrase typed blind, 38s later
[46.221301] systemd 259.8-1.fc44 running in system mode   <- switch-root
[47.447008] panel-simple-dp-aux ...: Detected AUO B140QAX01.H (0x0ba4)
[47.542017] [drm] Initialized msm 1.13.0 for ae01000.display-controller on minor 1
[47.628993] msm_dpu ae01000.display-controller: [drm] fb0: msmdrmfb frame buffer device
```

read it in order. `pwm-backlight` cannot get its pwm because the provider
driver is absent, so the backlight device never registers. `dp-aux` then defers
on `supplier backlight not ready`. so `msm` never finishes binding and never
lights the panel. it all resolves at 47.4 s, 1.2 seconds after switch-root,
which is exactly when the real rootfs makes `leds-qcom-lpg` available. that
timing is the proof that the module, not the hardware, was what was missing.

meanwhile `msm` has loaded in the initrd (6.52 s) and taken the display
subsystem away from the `simple-framebuffer` uefi left running. plymouth is
drawing on simpledrm's `fb0` the whole time, into a buffer nothing scans out.

not pinned down is whether the uefi scanout dies exactly at the `msm` and mdss
bind at 6.52 s or earlier. it does not change the fix, the prompt at 6.79 s is
after it either way. to find out, watch whether the screen is still lit at the
grub menu and goes dark a few seconds later.

## why it looked like a regression

it isn't a new break. the black window has existed since 0002 added the
backlight phandle, before that `panel-edp` had no backlight to wait for and
probed in the initrd normally. it was invisible because the initrd had nothing
to show, roughly a second between the uefi framebuffer going away and the real
panel coming up.

encrypting the disk put an interactive prompt inside that window, and a 38
second one at that. ([boot-time.md](boot-time.md) was written before the
encryption, hence its "nothing can use a tpm" reasoning, which still holds.)

## fix

put the pwm provider and the backlight driver in the initramfs.
`config/dracut/99-x1e80100-backlight.conf`:

```
force_drivers+=" leds-qcom-lpg pwm_bl "
```

`scripts/rebuild-initramfs.sh` installs it alongside the firmware drop-in and
rebuilds. use that rather than a bare `dracut -f`, so the adsp and cdsp
firmware from [system-changes.md](system-changes.md) stays in there:

```
sudo scripts/rebuild-initramfs.sh --all
```

`force_drivers` rather than `add_drivers`. it also writes a `modules-load.d`
entry inside the initramfs, so the modules load even if udev coldplug does not
match them. `qcom_pbs` is pulled in automatically as a dependency of
`leds-qcom-lpg`.

verify:

```
sudo lsinitrd /boot/initramfs-$(uname -r).img | grep -E 'leds-qcom-lpg|pwm_bl'
```

`scripts/verify.sh` checks the same thing. after a reboot the deferred probe
lines above should be gone and `Detected AUO B140QAX01.H` should land in the
initrd, well before `systemd ... running in system mode`.

re-run after every kernel install, alongside the firmware step.
`scripts/build-kernel.sh --install` does this itself.

## if the panel still does not come up in the initrd

`msm` binds its gpu component before registering the drm device, and the gpu
zap shader (`qcdxkmsuc8380.mbn`) is on the rootfs, not in the initramfs. if
that turns out to block the bind, the alternative is to keep `msm` out of the
initrd entirely and let plymouth keep the uefi framebuffer, which is lit
because uefi leaves the pwm running:

```
sudo grubby --update-kernel=ALL --args="rd.driver.blacklist=msm"
```

`rd.` scoping means this only affects the initramfs, `msm` loads normally
after switch-root. costs a display re-init at switch-root, and gives up
plymouth's native resolution.

## a related trap

`/etc/default/grub` is not what boots this machine. fedora is bls, the kernel
arguments live in `/boot/loader/entries/*.conf`, and editing
`GRUB_CMDLINE_LINUX` changes nothing until `grub2-mkconfig` runs. this is why
removing `quiet` there appeared to have no effect. `grubby` is the tool that
takes effect immediately:

```
sudo grubby --update-kernel=ALL --remove-args="quiet rhgb"
```

## to undo

```
sudo rm /etc/dracut.conf.d/99-x1e80100-backlight.conf
sudo scripts/rebuild-initramfs.sh --all
```

(`rebuild-initramfs.sh --undo` removes both drop-ins, the firmware one
included, which is not what you want here.)
