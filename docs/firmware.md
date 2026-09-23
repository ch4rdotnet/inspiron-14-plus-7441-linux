# the firmware gap

the gpu, battery and audio were all down to missing firmware, eleven files in
all (video decode needed one of them too, on top of a config option). this is
what they are, why they are missing, and how to get them.

## the missing files

the board device tree hard codes these paths. read them straight out of the
live dt:

```
$ tr -d '\0' < /proc/device-tree/soc@0/gpu@3d00000/zap-shader/firmware-name
qcom/x1e80100/dell/inspiron-14-plus-7441/qcdxkmsuc8380.mbn
```

| file | unlocks |
|---|---|
| `qcadsp8380.mbn` and `adsp_dtbs.elf` | battery and charging status, audio, usb-c pd and ucsi, dp altmode |
| `qccdsp8380.mbn` and `cdsp_dtbs.elf` | compute dsp (npu adjacent workloads) |
| `qcdxkmsuc8380.mbn` | gpu acceleration (the adreno zap shader) |
| `qcvss8380.mbn` | hardware video decode and encode (`qcom-iris`) |

plus the small pd-mapper json descriptors `adspr.jsn`, `adsps.jsn`,
`adspua.jsn`, `battmgr.jsn` and `cdspr.jsn`. eleven files in all, and they
belong in:

```
/lib/firmware/updates/qcom/x1e80100/dell/inspiron-14-plus-7441/
```

`/lib/firmware/updates/` takes precedence over `/lib/firmware/` and survives
linux-firmware upgrades, so use it rather than writing into the distro path.

## what fedora already ships

```
/lib/firmware/qcom/x1e80100/dell/inspiron-14-plus-7441/
└── X1E80100-Dell-Inspiron-14p-7441-tplg.bin.xz     <- audio topology only
```

that is the entire directory, one 1.3 kb file. compare the xps 13 9345, which
is complete:

```
/lib/firmware/qcom/x1e80100/dell/xps13-9345/
├── qcadsp8380.mbn.xz      ├── adsp_dtbs.elf.xz     ├── adspr.jsn
├── qccdsp8380.mbn.xz      ├── cdsp_dtbs.elf.xz     ├── adsps.jsn
├── qcdxkmsuc8380.mbn.xz   ├── battmgr.jsn          ├── adspua.jsn
└── X1E80100-Dell-XPS-13-9345-tplg.bin.xz           └── cdspr.jsn
```

dell granted redistribution rights for the xps 13 9345 blobs and not (yet) for
the inspiron 7441. that is the whole story, a licensing gap, not a technical
one. it is also why none of the blobs are in this repository, only their
checksums in `config/firmware.sha256`.

## why the generic qualcomm blobs don't work

generic qualcomm signed images do exist on disk:

```
/lib/firmware/qcom/x1e80100/adsp.mbn.xz          (5.8 mb)
/lib/firmware/qcom/x1e80100/cdsp.mbn.xz          (1.1 mb)
/lib/firmware/qcom/x1e80100/gen70500_zap.mbn.xz  (2 kb)
```

qualcomm upstreamed these in 2024 for the crd and qcp reference boards. they
were tried (symlinked under the dell path) and fail authentication, as
expected. the images are signed and trustzone verifies the chain against the
oem key fused into the soc, so a qualcomm-crd signed image is rejected on a
dell fused part. that is precisely why linux-firmware carries a separate per
laptop directory instead of one shared blob.

## route a, the latitude 7455 driver pack (confirmed working)

the inspiron 14 plus 7441 and the latitude 7455 are the same board. two
independent confirmations:

1. the upstream kernel series is titled "Add Dell Inspiron 7441 / Latitude 7455", one shared dtsi, two model nodes.
2. linux-firmware symlinks the latitude's audio topology to the inspiron's:
   ```
   X1E80100-Dell-Latitude-7455-tplg.bin.xz -> ../inspiron-14-plus-7441/X1E80100-Dell-Inspiron-14p-7441-tplg.bin.xz
   ```

`Latitude-7455-71MMN_Win11_1.0_A00.exe` (633 mb, dell command | deploy arm
driver pack, windows 11, a00) is an arm64 pe dell update package with the
driverstore payload embedded. `7z` reads it directly, no windows and no
cabextract needed:

```bash
7z l Latitude-7455-71MMN_Win11_1.0_A00.exe        # 764 files, 146 folders
```

all eleven files are present, under two inf packages:

| archive path (under `Latitude-7455/Win11/arm64/`) | files |
|---|---|
| `chipset/83RG3_A00-00/qcsubsys_ext_adsp8380/` | `qcadsp8380.mbn` (22.0 mb), `adsp_dtbs.elf`, `adspr.jsn`, `adsps.jsn`, `adspua.jsn`, `battmgr.jsn` |
| `chipset/83RG3_A00-00/qcsubsys_ext_cdsp8380/` | `qccdsp8380.mbn` (3.0 mb), `cdsp_dtbs.elf`, `cdspr.jsn` |
| `video/9F6PJ_A00-00/qcdx8380/` | `qcdxkmsuc8380.mbn` (12 kb), `qcvss8380.mbn` (2.3 mb) |

`scripts/install-firmware.sh --extract` pulls exactly those paths out into
`firmware/` (gitignored), checks them against `config/firmware.sha256`, and
installs them:

```bash
sudo scripts/install-firmware.sh --extract firmware/Latitude-7455-71MMN_Win11_1.0_A00.exe
sudo scripts/rebuild-initramfs.sh --all
sudo reboot
```

verification done on the extracted files:

- `file` reports all four `.mbn` as valid signed images, the three dsp ones as `ELF 32-bit LSB executable, QUALCOMM DSP6`, and `qcvss8380.mbn` as tensilica xtensa (correct, the video subsystem runs an xtensa core, not hexagon).
- the five `.jsn` pd-mapper descriptors are plain service descriptors, not signed payloads, and each matches one linux-firmware already ships. `adsps`, `adspua` and `battmgr` are byte identical to fedora's generic `qcom/qcm6490/` copies, `cdspr` to the xps 13 9345's, and `adspr` to the thinkpad x13s's (`qcom/sc8280xp/LENOVO/21BX/`).

result: the 7455 blobs authenticate on the 7441. trustzone accepted all three
signed images, the adsp booted and ran its pd services, the audio q6 stack and
speaker amp drivers autoloaded, the battery appeared in gnome, and the gpu zap
shader loaded with zero errors. same oem key, same "thena" platform. no windows
install was needed at any point. this does not appear to be documented
anywhere else.

## the initramfs trap

installing the blobs on the root filesystem is not enough on its own.
`qcom_q6v5_pas` probes inside the initramfs and remoteproc's auto-boot does not
retry a failed `request_firmware()`, so the adsp stays offline across a reboot
until the images are in the initramfs too. `scripts/rebuild-initramfs.sh`
installs `config/dracut/99-x1e80100-qcom-firmware.conf` and rebuilds. it has
to be run again after every kernel install, or battery and audio die on the new
kernel. the zap shader and the video firmware don't need this, `msm` and iris
retry lazily after switch-root. loading and authenticating the 22 mb adsp image
costs about 0.3 s of boot.

## route b, the 7441's own chipset driver (not needed)

dell's driver page for the inspiron 14 plus 7441 lists a qualcomm chipset
driver as a self extracting `.exe`. those are `7z` extractable on linux too,
and being the 7441's own package it is the exact match source. dell's driver
list api blocks scripted access, so it has to be fetched by hand in a browser.
kept for reference, route a worked.

## route c, install windows (not needed)

the officially documented path. fedora ships `qcom-firmware-extract` (in
updates-testing) for this, it detects the model from `/proc/device-tree/model`,
and the inspiron 14 plus 7441 is on its supported list mapped to
`x1e80100/dell/inspiron-14-plus-7441`. it handles bitlocker volumes read only
via `dislocker` and installs to `/lib/firmware/updates/qcom/<device_path>`.
about 64 gb for a windows 11 arm install.

note that `qcom-firmware-extract` also accepts a plain directory:

```
sudo qcom-firmware-extract -d /path/to/DriverStore/FileRepository
```

so routes a and b feed straight into the same tool, extract the driver pack
anywhere and point `-d` at the resulting `FileRepository`. no windows partition
needed for that flag.

## pd-mapper

no userspace `pd-mapper` package is needed. fedora's kernel ships the in-kernel
`qcom_pd_mapper` module, which autoloads once the adsp is up.
