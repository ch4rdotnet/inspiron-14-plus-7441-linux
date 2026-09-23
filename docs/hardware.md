# hardware inventory

captured from the running system. regenerate with `scripts/collect-state.sh`
(its output includes mac addresses and the battery serial, so don't publish it
as is).

## identity

| field | value |
|---|---|
| vendor, product | Dell Inc., Inspiron 14 Plus 7441 |
| family, sku | Inspiron, `0C86` |
| board | `047JFG` |
| bios | `2.13.0`, dated 2025-09-19 |
| uefi | 2.70 (Qualcomm Technologies, Inc. 1.00) |
| dt model | `Dell Inspiron 14 Plus 7441` |
| dt compatible | `dell,inspiron-14-plus-7441`, `qcom,x1e80100` |
| codename | "thena", shared platform with the dell latitude 7455 |
| soc id reported | `615`, not recognised upstream, the kernel only knows `QCOM_ID_X1E80100 = 555` |
| soc revision | 2.1 |

## soc

qualcomm snapdragon x, oryon cores. the device tree says `qcom,x1e80100` but
the silicon reports `soc_id 615`, an x plus bin running an x elite device tree.
see [soc.md](soc.md).

- 12 cpus present, cpu7 and cpu11 fail to boot (`psci: failed to boot CPU7 (-22)`), so 10 are online. cosmetic.
- cluster 0 reports midr variant 2 (`0x512f0011`), clusters 1 and 2 variant 1 (`0x511f0011`).
- 3 scmi performance domains (ncc0, ncc1, ncc2), each exposing the same 13 opps, 710400 to 3417600 khz.
- scmi protocol v2.0 `Qualcomm:`, firmware version `0x20000`.
- cpu dt nodes carry `power-domain-names = "psci", "perf"`, dvfs is via scmi perf domains.
- `qseecom` present in tz, version `0x1402000` (the upstream series added the allowlist entry).

## memory and storage

- 16 gib ram (15 gib usable), 8 gib zram swap.
- nvme KIOXIA BG6 (dram-less), 476.9 gb, `1e0f:001a` on pcie root complex `0006:00:00.0`.
- fedora only, no windows partition remains.

| partition | size | fs | mount |
|---|---|---|---|
| `nvme0n1p1` | 600m | vfat | `/boot/efi` |
| `nvme0n1p2` | 2g | ext4 | `/boot` |
| `nvme0n1p3` | 474.4g | btrfs (luks) | `/home` (plus `root` subvol) |

## pcie

```
0004:00:00.0  PCI bridge          Qualcomm SC8380XP PCIe Root Complex [17cb:0111]
0004:01:00.0  Network controller  Qualcomm WCN785x Wi-Fi 7 320MHz 2x2 (FastConnect 7800) [17cb:1107]
0006:00:00.0  PCI bridge          Qualcomm SC8380XP PCIe Root Complex [17cb:0111]
0006:01:00.0  NVMe                KIOXIA BG6 [1e0f:001a]
```

## usb and peripherals

- goodix fingerprint reader `27c6:631c` (internal usb), works with libfprint's `goodixmoc`.
- genesys logic microsd card reader `05e3:0751`.
- via labs usb 2.0 and 3.0 hubs plus a usb billboard device (type-c).

## input

| device | bus and id |
|---|---|
| keyboard | `hid-over-i2c 6243:0000` |
| touchpad | `hid-over-i2c 04F3:32FB` (elan) |
| touchscreen | `hid-over-i2c 29BD:1103` at i2c 0x09 (windows precision touchscreen), needs patch 0003 |
| `gpio-keys` | lid, volume |
| `pmic_pwrkey` | power button |

## display

- dpu `msm_dpu` on `qcom,x1e80100-dpu`.
- connectors `eDP-1` (internal panel), `DP-1`, `DP-2`, `Writeback-1`.
- panel AUO B140QAX01.H, detected by `panel-simple-dp-aux`.
- backlight `pwm-backlight` on pmk8550 gpio5 via `leds-qcom-lpg`, needs patch 0002. the stock dt gives a `dp_aux_backlight` with `max_brightness 0`.

## camera

omnivision OV02E10 front sensor plus a himax HM1092 aux sensor, on cci1 master 1
(the always-on i2c pins, gpio235 and gpio236) at 0x10, with mclk on gpio100 and
reset on gpio237. probes and streams with patches 0004 to 0006, no frames yet.
see [camera.md](camera.md).

## leds

`white:camera-indicator` (gpio110), `mmc0::`, keyboard lock leds.

## thermal

59 thermal zones, 64 hwmon devices, full soc sensor coverage via `qcom_tsens`
and `qcom_spmi_temp_alarm`: per core `cpuN_M_top/btm_thermal`, `gpuss_0..7`,
`nsp0..3`, `camera0/1`, `mem`, `video`, `aoss0..3`, and the pmic dies. five
cooling devices, `cpufreq-cpu0`, `cpufreq-cpu4`, `cpufreq-cpu8`,
`devfreq-3d00000.gpu` and `PCIe_Port_Link_Speed`. no fan among them, see
[fan-control.md](fan-control.md).

## embedded controller

at 0x3b on the bus behind `b94000.i2c` (dt `i2c5`, acpi `\_SB.I2C6`). answers
64 byte block reads. its fan interface is autonomous. see
[fan-control.md](fan-control.md).

## power

`pmic_glink` to `qcom_battmgr`, exposing `qcom-battmgr-{ac,bat,usb,wls}`.
reports properly once the adsp firmware is installed. pack is DELL WYJ4543R,
54 wh design, 46.43 wh present capacity.

## suspend

`/sys/power/mem_sleep` = `s2idle [deep]`, `/sys/power/state` = `freeze mem disk`.
cpuidle states `WFI` and `cpu-sleep-0` (retention).

## software baseline

- fedora linux 44 workstation, kernel `7.1.13-200.fc44.aarch64` stock, `7.1.13-200.dellfix.fc44.aarch64` patched.
- linux-firmware and qcom-firmware `20260810-1.fc44`.
- mesa `26.1.8`, `msm_dri.so`, `kgsl_dri.so` and `freedreno_icd.aarch64.json` all installed.
- pipewire `1.6.8`, wireplumber, gnome.
- boot is shim, grub 2.12, then a systemd-stub uki (`vmlinuz-dtbloader.efi` from `kernel-uki-dtbloader`). the device tree is embedded in the uki as `.dtbauto` sections and selected by smbios match, no dtb file on disk is consulted.
- kernel cmdline `root=UUID=... ro rootflags=subvol=root rhgb quiet` plus the tpm masks from [boot-time.md](boot-time.md), nothing else.
