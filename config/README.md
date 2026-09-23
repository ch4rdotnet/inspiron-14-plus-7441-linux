# config

the files the scripts install, kept here so they can be read, diffed, or
applied by hand.

| file | goes to | installed by |
|---|---|---|
| `kernel-local` | the kernel build (spec hook `Source3001`) | `scripts/build-kernel.sh` |
| `dracut/99-x1e80100-qcom-firmware.conf` | `/etc/dracut.conf.d/` | `scripts/rebuild-initramfs.sh` |
| `dracut/99-x1e80100-backlight.conf` | `/etc/dracut.conf.d/` | `scripts/rebuild-initramfs.sh` |
| `dracut/99-no-tpm.conf` | `/etc/dracut.conf.d/` | `scripts/disable-tpm-wait.sh` |
| `pipewire/51-tweeter-upmix.conf` | `/etc/pipewire/client.conf.d/` and `/etc/pipewire/pipewire-pulse.conf.d/` | `scripts/install-audio-config.sh` |
| `pipewire/52-speaker-crossover.conf` | `/etc/pipewire/pipewire.conf.d/` | `scripts/install-audio-config.sh` |
| `firmware.sha256` | nowhere, checksums of the 11 blobs | `scripts/install-firmware.sh --verify` |

`kernel-local` carries two options, `CONFIG_SM_VIDEOCC_8550=m` for hardware
video decode and `CONFIG_ARM_SCMI_CPUFREQ=y` so cpufreq loads at boot. the
comments in the file say why. [docs/system-changes.md](../docs/system-changes.md)
has the reasoning behind every drop-in.

the upmix file is installed twice because pulse clients (firefox is one) don't
read `client.conf`. rebuild the initramfs after touching anything in `dracut/`,
with `scripts/rebuild-initramfs.sh --all` rather than a bare `dracut -f`, so
the firmware stays in there.

the firmware blobs themselves are not in this repository, they are dell's and
not redistributable. `scripts/install-firmware.sh --extract` pulls them out of
the latitude 7455 driver pack into `firmware/`.
