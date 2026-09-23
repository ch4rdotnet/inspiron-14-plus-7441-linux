# references

## upstream kernel enablement

- [add dell inspiron 7441 / latitude 7455 (X1E-80-100), v3](https://patchew.org/linux/20250706205723.9790-2-val@packett.cool/),
  the series that enabled this machine (val packett). patches: dt-bindings for
  both models, the shared dts, `firmware: qcom: scm` QSEECOM allowlist entry,
  and a BOE NE14QDM panel entry for the latitude. landed in 6.16.
- [v2 of the same series](https://patchew.org/linux/20250701231643.568854-1-val@packett.cool/)
- [review thread on linux-arm-msm](https://www.spinics.net/lists/linux-arm-msm/msg241267.html)
- [phoronix: new patches get linux booting on the snapdragon x1 powered dell inspiron 14 plus](https://www.phoronix.com/news/Dell-Inspiron-14-Plus-Linux-X1E)

## firmware

- [`qcom-firmware-extract(8)` man page](https://manpages.debian.org/unstable/qcom-firmware-extract/qcom-firmware-extract.8.en.html),
  documents the supported model list (the inspiron 14 plus 7441 maps to
  `x1e80100/dell/inspiron-14-plus-7441`), the `-d` flag for a pre-extracted
  DriverStore, bitlocker handling, and the `/lib/firmware/updates/qcom/<device_path>`
  install target.
- [phoronix: audio firmware upstreamed for qualcomm snapdragon x1 on linux](https://www.phoronix.com/news/Linux-Snapdragon-X1-Audio-FW),
  explains the adsp arrangement. uefi boots a charging only adsp image, linux
  must restart it with the full image to get audio and battery reporting.
  covers the crd/qcp generic blobs.
- [fedora wiki: snapdragon woa laptop install](https://fedoraproject.org/wiki/Snapdragon_WoA_Laptop_Install),
  official fedora procedure. `qcom-firmware-extract` lives in `updates-testing`.
  no 7441 entry.
- [arch `linux-firmware-qcom` file list](https://archlinux.org/packages/core/any/linux-firmware-qcom/files/),
  handy for checking what is and isn't redistributable at any given version.

## dell

- [inspiron 14 plus 7441, drivers and downloads](https://www.dell.com/support/product-details/en-us/product/inspiron-14-7441-laptop/drivers),
  source for the qualcomm chipset driver `.exe` (route b in
  [firmware.md](firmware.md)). the driver list api rejects scripted requests,
  use a browser.
- [dell command | deploy arm driver packs](https://www.dell.com/support/kbdoc/en-us/000226163/dell-command),
  lists arm packs for the xps 13 9345 and latitude 7455 only. the latitude 7455
  pack (windows 11, A00, 2024-07-02) is the same board source for route a. no
  7441 pack exists.

## gpu

- [support for adreno X1-85 gpu, v2](https://lkml.iu.edu/hypermail/linux/kernel/2407.0/03199.html)
- [linux patch to disable the x1e80100 gpu by default (discussion)](https://www.phoronix.com/forums/forum/linux-graphics-x-org-drivers/x-org-drm/1478801-linux-patch-to-disable-the-snapdragon-x-elite-x1e80100-gpu-by-default/page2),
  background on why the zap shader gates gpu bring-up.

## related devices and general x1e work

- [TravMurav/dtbloader issue #8, supporting the rest of the known x1 devices](https://github.com/TravMurav/dtbloader/issues/8)
- [alexVinarskis/linux-x1e80100-dell-tributo](https://github.com/alexVinarskis/linux-x1e80100-dell-tributo),
  dell xps 13 9345 patch set, the closest well documented sibling machine.
- [alexVinarskis/linux-x1e80100-zenbook-a14](https://github.com/alexVinarskis/linux-x1e80100-zenbook-a14)
- [ubuntu faq: 25.04/25.10 on snapdragon x elite](https://discourse.ubuntu.com/t/faq-ubuntu-25-04-25-10-on-snapdragon-x-elite/61016/256)
- [phoronix: ubuntu concept for snapdragon x1 laptops moves to linux 6.16](https://www.phoronix.com/news/Ubuntu-Concept-Linux-6.16-X1E)
- [linaro: qualcomm and linaro enable latest flagship snapdragon compute soc](https://www.linaro.org/blog/qualcomm-and-linaro-enable-latest-flagship-snapdragon-compute-soc/)
- [dell community: inspiron 14 snapdragon linux issues](https://www.dell.com/community/en/conversations/inspiron/inspiron-14-snapdragon-linux-issues/64c105f8f4ccf8a8dececebc)

## hardware specs

- [notebookcheck: dell inspiron 14 plus 7441](https://www.notebookcheck.com/Dell-Inspiron-14-Plus-7441.882965.0.html)
- [notebookcheck: snapdragon x elite X1E-80-100 benchmarks and specs](https://www.notebookcheck.net/Snapdragon-X-Elite-X1E-80-100-Processor-Benchmarks-and-Specs.838567.0.html)

## kernel source paths that matter

| path | why |
|---|---|
| `drivers/firmware/arm_scmi/perf.c` | the sustained frequency turbo bug, patch 0001. [cpufreq.md](cpufreq.md) |
| `drivers/cpufreq/scmi-cpufreq.c`, `drivers/cpufreq/freq_table.c` | why the driver can't autoload, and where the empty table is rejected |
| `drivers/leds/rgb/leds-qcom-lpg.c` | the pmk8550 pwm provider, and the likely home of the brightness flash. [backlight.md](backlight.md) |
| `drivers/clk/qcom/videocc-sm8550.c` | matches `qcom,x1e80100-videocc`, fedora ships it off. [video-decode.md](video-decode.md) |
| `drivers/clk/qcom/camcc-x1e80100.c` | the mclk table written for a 19.2 mhz xo, patch 0004. [camera.md](camera.md) |
| `drivers/media/platform/qcom/camss/` | the isp, and the 4 kb csiphy windows that oops. patch 0005 |
| `drivers/i2c/busses/i2c-qcom-cci.c` | the camera i2c master, `qcom,msm8996-cci` is the generic v2 entry |
| `drivers/media/i2c/ov02e10.c` | the front sensor driver, insists on a 19.2 mhz mclk |
| `arch/arm64/boot/dts/qcom/x1-dell-thena.dtsi` | the shared 7441 / 7455 board file. patch 0006, and the panel label from 0002 |
| `arch/arm64/boot/dts/qcom/x1e80100-dell-inspiron-14-plus-7441.dts` | the 7441 model file, touchscreen address. patch 0003 |
| `arch/arm64/boot/dts/qcom/hamoa.dtsi` | the soc dtsi. camss, camcc and cci nodes, patch 0005 |
| `arch/arm64/boot/dts/qcom/x1-hp-omnibook-x14.dtsi` | the pwm backlight precedent the 0002 patch follows |
| `include/dt-bindings/arm/qcom,ids.h` | soc id 615 is not in it. [soc.md](soc.md) |
| `include/dt-bindings/clock/qcom,x1e80100-camcc.h` | defines `CAM_CC_CCI_0_CLK` and `CAM_CC_CCI_1_CLK` and nothing else, so at most two cci apertures |
