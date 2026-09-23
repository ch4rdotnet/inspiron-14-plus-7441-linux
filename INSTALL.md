# from scratch

everything needed to get a dell inspiron 14 plus 7441 from a fresh fedora install to the state the [README](README.md) describes. each step is one or two scripts you run yourself, then a check that it worked, then what to do if it didn't. do them in order, i'm not helping you otherwise.

| step | script | reboot after |
|---|---|---|
| [1. packages](#step-1-packages) | `install-deps.sh` | no |
| [2. firmware](#step-2-firmware) | `install-firmware.sh`, `rebuild-initramfs.sh` | yes |
| [3. kernel](#step-3-kernel) | `build-kernel.sh` | yes |
| [4. system config](#step-4-system-config) | `disable-tpm-wait.sh`, `install-audio-config.sh`, `browser-hwdec.sh` | yes |
| [5. verify](#step-5-verify) | `verify.sh` | |

every script that changes the system takes `--undo`, and `--help` on any of them prints what it does. run them from the repository root.

## before you start

- secure boot must be off. this boots an unsigned locally built kernel. set it
  in the dell firmware setup (f2 at boot).
- keep a usb stick with a live image around, you'll reboot into a half
  configured machine a few times. unplug it when you're done, it costs 5 s
  of every boot ([docs/boot-time.md](docs/boot-time.md)).
- ~5 gb free for the kernel build tree and rpms, plus 633 mb for the driver
  pack.

## step 0, install fedora

flash the usb, boot into the installer, install, that's it.

update fully and reboot before going further.

```
sudo dnf upgrade --refresh -y && sudo reboot
```

## step 1, packages

```
sudo ./scripts/install-deps.sh           # add --tools for the diagnostics the docs use
```

`7zip` (not `p7zip`, only its `7z` reads the driver pack), `rpm-build`,
`ccache`, `git`, `curl`, `dracut`, `grubby`. ccache turns the second and later
kernel builds from ~20 minutes into ~3.

**check.** `7z` on its own prints a version banner.

**if it didn't work.** a `p7zip` install can shadow `7z`, remove it
(`sudo dnf remove p7zip p7zip-plugins`) and re-run.

## step 2, firmware

these are dell signed qualcomm blobs, not redistributable, so not in
`linux-firmware`. you don't need windows. the dell latitude 7455 is the same
board and its driver pack's signatures authenticate on the 7441.

1. download `Latitude-7455-71MMN_Win11_1.0_A00.exe` (633 mb) from dell support,
   latitude 7455, "dell command | deploy driver pack", windows 11 arm64. put it
   in `firmware/`.
2. extract and install the eleven files, then put the adsp and cdsp ones in the
   initramfs:

```
sudo ./scripts/install-firmware.sh --extract firmware/Latitude-7455-71MMN_Win11_1.0_A00.exe
sudo ./scripts/rebuild-initramfs.sh --all
sudo reboot
```

the initramfs step is not optional. `qcom_q6v5_pas` probes inside the
initramfs and remoteproc never retries a failed `request_firmware()`, so the
adsp stays offline all boot if the images are only on the rootfs.
[docs/firmware.md](docs/firmware.md) has the full reasoning.

**check,** after the reboot:

```
cat /sys/class/remoteproc/*/state            # running, running (adsp and cdsp)
cat /proc/asound/cards                       # a card, not "no soundcards"
cat /sys/class/power_supply/qcom-battmgr-bat/capacity   # a real percentage
```

**if it didn't work.**

- `install-firmware.sh --verify` compares the extracted files against
  `config/firmware.sha256`. a mismatch warning means a different driver pack
  revision, which may still work. missing files means the extraction failed,
  check the pack downloaded fully (633 mb).
- remoteproc `offline` after a reboot means the images aren't in the
  initramfs. `lsinitrd /boot/initramfs-$(uname -r).img | grep -E 'adsp|cdsp'`
  should list four files. if it doesn't, re-run
  `sudo ./scripts/rebuild-initramfs.sh --all` and reboot.
- `journalctl -k -b | grep -iE 'remoteproc|q6v5|firmware'` shows what the
  loader tried and why it failed.
- a card in `/proc/asound/cards` but no sinks in `wpctl status` is a
  `/dev/snd` acl race seen once, `sudo ./scripts/fix-audio-acl.sh` fixes it for
  the boot.
- to back out, `sudo ./scripts/install-firmware.sh --undo` and
  `sudo ./scripts/rebuild-initramfs.sh --undo`, then reboot.

## step 3, kernel

fixes cpufreq (4 of 10 cores), brightness, the touchscreen and video decode.
the three patches sent upstream (`patches/out/`) and two config options from `config/kernel-local`.

```
./scripts/build-kernel.sh --prepare               # dist-git, tarballs, patches, kernel-local
sudo dnf builddep -y build/kernel/kernel.spec     # the kernel's own build requirements
./scripts/build-kernel.sh                         # ~20 min the first time
sudo ./scripts/build-kernel.sh --install          # installs, rebuilds the initramfs
sudo reboot
```

run the build as your user, not root. what it does underneath: clones fedora's
kernel dist-git at the tag matching the running kernel (for example
`kernel-7.1.13-200.fc44`), fetches the source tarballs from the lookaside
cache, concatenates the patches in `patches/out/` into `linux-kernel-test.patch` (which the
spec applies as `Patch999999`), copies `config/kernel-local` over the spec's
own hook, and runs `rpmbuild` for the base flavour only. the release carries a
`.dellfix` suffix so it sits next to the stock kernel in the boot menu, and the
stock kernel stays installed as a fallback.

`config/kernel-local` holds

```
CONFIG_SM_VIDEOCC_8550=m      # video clock controller, hardware video decode
CONFIG_ARM_SCMI_CPUFREQ=y     # builtin, a modular scmi driver cannot autoload
```

[patches/](patches/) says what each patch does, and
[docs/system-changes.md](docs/system-changes.md) has the no-rebuild alternative
to `CONFIG_ARM_SCMI_CPUFREQ=y`.

**check,** after the reboot:

```
uname -r                                     # ...dellfix.fc44.aarch64
ls /sys/devices/system/cpu/cpufreq/          # policy0 policy4 policy8
cat /sys/class/backlight/*/max_brightness    # non zero
```

**if it didn't work.**

- *missing build dependencies.* the build stops early and says so. run the
  `dnf builddep` line above, it needs `--prepare` to have fetched the spec
  first.
- *a patch doesn't apply.* fedora has moved to a kernel where the code the
  patches touch changed. build the last release they're known to apply to
  instead, `rm -rf build/kernel`, then
  `KERNEL_TAG=kernel-7.1.13-200.fc44 ./scripts/build-kernel.sh --prepare` and
  carry on from the builddep line. `git ls-remote --tags
  https://src.fedoraproject.org/rpms/kernel.git 'kernel-7.1*'` lists the tags.
- *the build fails somewhere else.* `build/kernel/build.log` has everything.
  `./scripts/build-progress.sh -w` in another terminal shows where a running
  build is.
- *the new kernel doesn't boot.* pick the stock kernel at the grub menu (hold
  shift or press esc during boot if the menu is hidden). nothing else changed,
  so the machine is back to the end of step 2. remove the patched kernel with
  `sudo dnf remove $(rpm -qa 'kernel*' | grep dellfix)`.
- *it boots but battery and audio are gone.* the new kernel's initramfs lacks
  the firmware. `sudo ./scripts/rebuild-initramfs.sh --all` and reboot
  (`--install` does this, so this only happens with a kernel installed another
  way).
- *it boots the stock kernel by default.*
  `sudo grubby --set-default "$(ls /boot/vmlinuz-*dellfix* | tail -1)"`.

### after every fedora kernel update

a `dnf upgrade` that brings a new stock kernel makes it the default, and it
doesn't have the patches. either boot the `.dellfix` one from the menu, or
rebuild against the new one, which takes ~3 minutes with a warm ccache:

```
rm -rf build/kernel
./scripts/build-kernel.sh --prepare && sudo dnf builddep -y build/kernel/kernel.spec
./scripts/build-kernel.sh && sudo ./scripts/build-kernel.sh --install
```

reboot into the new stock kernel first, the build follows the running one.

### optional, the camera patches

`patches/camera/` holds three more patches that describe the camera to the
kernel. the sensor probes and accepts a stream, but no frames arrive
([docs/camera.md](docs/camera.md)), and they're the least tested part of the
tree, suspected in [docs/hangs.md](docs/hangs.md). only build them if you want
to work on the camera.

```
./scripts/build-kernel.sh --camera
sudo ./scripts/build-kernel.sh --camera --install
```

that's a separate `.dellcam` kernel next to the `.dellfix` one, so you can
switch between them at the boot menu.

## step 4, system config

**tpm wait.** systemd waits 90 s per boot for a tpm that has no driver on this
machine ([docs/boot-time.md](docs/boot-time.md)).

```
sudo ./scripts/disable-tpm-wait.sh
sudo ./scripts/rebuild-initramfs.sh --all
```

check after the next reboot, `systemd-analyze` should be ~15 s, not ~2 min.

**speakers.** the tweeters sit on the rear channels and the default upmix
starves them, so everything sounds muffled ([docs/audio.md](docs/audio.md)).

```
sudo ./scripts/install-audio-config.sh
systemctl --user restart pipewire pipewire-pulse wireplumber
```

check with `speaker-test -c 2 -t wav`, both sides should sound full. if audio
stops entirely, `sudo ./scripts/install-audio-config.sh --undo` and restart
pipewire again.

**browser video decode.** turns on chromium's v4l2 decode path for every
installed chromium family browser ([docs/video-decode.md](docs/video-decode.md)).
firefox can't do hardware decode here, it only does vaapi and there's no vaapi
driver for this hardware.

```
./scripts/browser-hwdec.sh
```

check `chrome://gpu`, "video decode" should say hardware accelerated.

**recommended, crash capture.** there have been four hard hangs and nothing was
captured :( ([docs/hangs.md](docs/hangs.md)). this sets a 1 s journal sync and
logs every device's suspend callback, so the next one leaves evidence. it
costs some extra writes per boot.

```
sudo ./scripts/crash-capture.sh --pm-debug --panic
```

## step 5, verify

```
./scripts/verify.sh
```

run it from a desktop terminal so the gpu check can use `glxinfo`. the
initramfs check needs root (the image is 0600) and is skipped without it,
`sudo ./scripts/verify.sh` covers that one. everything else should pass, each
failure line names what's missing and the step above covers it. more manual
checks:

```
glxinfo -B | grep -E 'Device|Accelerated'    # adreno x1-85, yes
v4l2-ctl --list-devices                      # iris decoder, /dev/video0 and 1
./scripts/find-unbound.sh                    # only crypto and gmu should remain
./scripts/powerlog.sh 10 600                 # unplugged, idle, ~8 w
```

## known limitations

| | |
|---|---|
| camera | the sensor probes and streams but the csiphy never locks, no frames. [docs/camera.md](docs/camera.md) |
| fan | no control :( [docs/fan-control.md](docs/fan-control.md) |
| 10 bit video | the decoder outputs NV12 and Q08C only, hdr falls back to software |
| firefox video | no vaapi driver exists. use a chromium browser or a gstreamer player |
| brightness | flashes bright before settling. cosmetic, unresolved |
| crypto engine | left off deliberately, the cpu's armv8 crypto extensions are faster |
| cpu7, cpu11 | never boot. x1 plus bin on an x1 elite device tree. cosmetic |
| stability | random hard hangs, cause unknown. [docs/hangs.md](docs/hangs.md) |

## versions this was done against

```
Fedora Linux 44 (Workstation Edition) aarch64
kernel        7.1.13-200.fc44 (stock) -> 7.1.13-200.dellfix.fc44 (patched)
linux-firmware / qcom-firmware  20260810-1.fc44
alsa-ucm      1.2.16.1-1.fc44
libfprint     1.94.100-1.fc44
mesa          26.1.8
BIOS          2.13.0 (2025-09-19)
```

the patches also apply to upstream master as of 2026-09-08, the code they touch
was byte-identical.
