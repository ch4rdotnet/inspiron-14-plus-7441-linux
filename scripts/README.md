# scripts

everything here is fedora specific, finds the project from its own location
(no hardcoded paths), and anything that changes system state has an `--undo`.
`--help` on any of them prints the header.

## bring-up

one script per step, run by hand in the order [INSTALL.md](../INSTALL.md) gives,
with a check after each.

| script | |
|---|---|
| `install-deps.sh` | the packages the other scripts need. `--tools` adds the diagnostics the docs use. |
| `install-firmware.sh` | the eleven dell signed blobs. `--extract PACK` pulls them out of the latitude 7455 driver pack, `--verify` checks them against `config/firmware.sha256`, `--undo` removes them. |
| `rebuild-initramfs.sh` | installs the firmware and backlight dracut drop-ins and rebuilds the initramfs (`--all` for every kernel). required after every kernel install or battery and audio die on the new one. |
| `build-kernel.sh` | fetches fedora dist-git at the tag matching the running kernel, the source tarballs from the lookaside cache, folds the sent patches in `patches/out/` and `config/kernel-local` in, builds the base flavour with ccache. `--install ID` installs and rebuilds the initramfs. `--camera` adds `patches/camera/` and builds as `.dellcam`. |
| `build-progress.sh` | what the build is doing right now, `-w` to watch. reads the spec's own step markers. |
| `disable-tpm-wait.sh` | masks the tpm device units in userspace and on the kernel command line. 1:58 to 15 s boot. |
| `install-audio-config.sh` | the pipewire upmix and crossover drop-ins that fix the muffled speakers. |
| `browser-hwdec.sh` | desktop file overrides that turn on chromium's v4l2 decode path. |
| `verify.sh` | one pass over everything, pass or fail per item. run it from a desktop terminal so the gpu check can use glxinfo. |

## measuring

| script | |
|---|---|
| `powerlog.sh` | battery draw, hottest sensor and gpu clock over time. reports both `POWER_NOW` and the integrated `ENERGY_NOW` delta, which disagree over short runs. run unplugged. |
| `cpumon.sh` | live cluster frequencies, gpu clock, temperatures and system power. |
| `collect-state.sh` | full hardware and driver snapshot to one file, for diffing before and after. contains mac addresses and the battery serial, don't publish it as is. |
| `find-unbound.sh` | dt nodes that are `status=okay` with no driver bound. this is what found the missing videocc. good first check for "why doesn't x work". |
| `test-hwdec.sh` | for a video file, what it is, whether it decodes in software, which decoder gstreamer picks, and forcing the hardware one. warns on 10 bit content. |

## only if it happens

| script | |
|---|---|
| `crash-capture.sh` | 1 s journal sync, optional netconsole, panic-on-lockup and `--pm-debug` (logs every device's suspend callback). there have been four hangs and none was captured, so feel free to run it :P |
| `hang-report.sh` | the boots that ended in a hang, with the kernel, uptime, suspend cycles and the last lines of each. this produced the table in [docs/hangs.md](../docs/hangs.md). |
| `fix-audio-acl.sh` | `/dev/snd` acl went to `gdm-greeter` because the card appeared mid gdm startup. seen once. |

the diagnostics that found each bug are in [tools/](../tools/).
