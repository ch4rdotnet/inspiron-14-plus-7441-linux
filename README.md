# linux on the dell inspiron 14 plus 7441

fedora on a dell inspiron 14 plus 7441, the snapdragon x plus (10 core) variant.

board `dell,inspiron-14-plus-7441`, dt compatible `qcom,x1e80100` (it is an x1 plus bin running the x1 elite device tree, see [docs/soc.md](docs/soc.md)).

baseline is fedora 44 workstation (fedora 45 testing is next).

## ai/llm disclaimer
LLMs *were* used for some of the research during this project (probing/prototype tooling), however kernel patches and the final setup were written by a human (me lmfao).

some documentation and tooling may have also been created/modified by LLMs (this was a relatively quick project, so help writing documentation is always helpful).

## state

| | |
|---|---|
| works out of the box | boot, storage, display, keyboard, touchpad, wifi 7, bluetooth, usb, microsd, thermal sensors, fingerprint (`goodixmoc`), suspend and resume (`deep`) |
| fixed, firmware | gpu acceleration (adreno x1-85), battery and charging, audio (speakers, headphones, jack) |
| fixed, kernel patch | cpu frequency scaling on all 10 cores, screen brightness, touchscreen |
| fixed, kernel config | hardware video decode and encode, including in chromium browsers |
| fixed, system config | 90 s tpm wait at boot, muffled speakers, invisible luks prompt |
| minor | display randomly flashes bright when changing brightness, 10 bit video falls back to software (a driver limitation), no hardware decode in firefox |
| open | random hard hangs, still diagnosing ([docs/hangs.md](docs/hangs.md)) |
| in progress | camera (help appreciated!) |

remaining things end up in [docs/remaining.md](docs/remaining.md).

## setting it up

```
git clone https://github.com/ch4rdotnet/inspiron-14-plus-7441-linux
cd inspiron-14-plus-7441-linux
```
then follow [INSTALL.md](INSTALL.md).

## layout

| | |
|---|---|
| [INSTALL.md](INSTALL.md) | from scratch on a fresh fedora install |
| [patches/](patches/) | the kernel patches, `git format-patch` output, and what each does. the camera ones are in `patches/camera/` and opt in |
| [config/](config/) | the kernel config fragment and the dracut and pipewire drop-ins |
| [scripts/](scripts/) | one script per install step, verify, and measurement |
| [tools/](tools/) | the diagnostics that found each bug, and the out-of-tree modules |
| [docs/](docs/) | one document per subsystem, with the evidence |

## documents

| | |
|---|---|
| [docs/status.md](docs/status.md) | per subsystem status with the kernel log evidence |
| [docs/soc.md](docs/soc.md) | an x1 plus running an x1 elite device tree, soc_id 615 |
| [docs/hardware.md](docs/hardware.md) | the probed hardware inventory |
| [docs/firmware.md](docs/firmware.md) | the firmware gap and how the latitude 7455 pack fills it |
| [docs/cpufreq.md](docs/cpufreq.md) | the scmi sustained frequency bug, reads as a bug report |
| [docs/backlight.md](docs/backlight.md) | finding the pwm wiring, and the dt patch |
| [docs/touchscreen.md](docs/touchscreen.md) | 0x09, not 0x10 |
| [docs/video-decode.md](docs/video-decode.md) | iris, the videocc config gap, codec limits, which players work |
| [docs/audio.md](docs/audio.md) | the tweeters sit on the rear channels, upmix and crossover |
| [docs/audio-vendor-tuning.md](docs/audio-vendor-tuning.md) | what the vendor acdb holds and why it can't be loaded |
| [docs/boot-time.md](docs/boot-time.md) | 90 s lost to a tpm with no driver, then 5 s to a usb stick |
| [docs/luks-black-screen.md](docs/luks-black-screen.md) | the backlight chain is missing from the initramfs |
| [docs/camera.md](docs/camera.md) | camss, cci, the OV02E10, and where it stops |
| [docs/acpi-tables.md](docs/acpi-tables.md) | reading the windows acpi tables on a dt booted machine |
| [docs/fan-control.md](docs/fan-control.md) | the ec, the qmi thermal service, and why the fan is still autonomous |
| [docs/system-changes.md](docs/system-changes.md) | everything outside the kernel source |
| [docs/hangs.md](docs/hangs.md) | the hard hangs, what the journal has for each, and the plan |
| [docs/remaining.md](docs/remaining.md) | what is still open, and how to pick it up |
| [docs/upstreaming.md](docs/upstreaming.md) | what goes upstream, where, and its state |
| [docs/references.md](docs/references.md) | upstream series, firmware sources, related machines |

## rebuilding the kernel

```
BUILDID=.myfix ./scripts/build-kernel.sh          # ~20 min cold, ~3 with a warm ccache
sudo ./scripts/build-kernel.sh --install .myfix   # installs and rebuilds the initramfs
sudo reboot
```

the initramfs rebuild is not optional. a new kernel gets a fresh initramfs
without the adsp firmware, and battery and audio die without it.
`build-kernel.sh --install` does it, `scripts/rebuild-initramfs.sh --all` does
it on its own.

## license

gpl-2.0, same as the kernel the patches are against. the firmware blobs are
dell's and are not in this repository.
