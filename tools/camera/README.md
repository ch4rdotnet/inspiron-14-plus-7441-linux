# camera tools

| tool | |
|---|---|
| `probe-cci.sh` | are the cci controllers bound, which interrupts fire, what answers on their buses, are the camera rails and pins in the right state |
| `capture-camera.sh [frames] [csiphy]` | configure the camss pipeline from the sensor to `vfe0_rdi0` and try to grab frames. as of [docs/camera.md](../../docs/camera.md) it gets none |
| `raw10-to-png.py` | unpack a packed mipi raw10 frame, bin the bayer quads, stretch, save |
| `prepare.sh LINUX_TARBALL` | turn the three patch based modules below into buildable trees |

## modules

out-of-tree modules written so a question could be answered by reloading a
module instead of rebuilding a kernel. the drivers they replace are modules
on fedora (`I2C_QCOM_CCI=m`, `VIDEO_QCOM_CAMSS=m`, `VIDEO_OV02E10=m`), so a
diagnostic build can be swapped in live with `modprobe -r` and `insmod`.
building needs the matching `kernel-devel`, see [../README.md](../README.md).

| module | what it does |
|---|---|
| `mmiopeek` | reads a few words of an mmio aperture and never loads. told a live cci (`HW_VERSION 0x10070000`) from something else. only safe when the surrounding clocks are on, 0x0ac14000 is unmapped and reading it raises a synchronous external abort. |
| `aonmclk` | muxes gpio100 to `cam_aon` and enables a camcc mclk by hand. this is what made the sensor answer on the bus, superseded by the dt in patch 0006. |
| `ccidiag` | `i2c-qcom-cci` that reports `CCI_HW_VERSION`, polls the reset-done bit when the interrupt never comes, and maps candidate gic spis to see which one really fires. this measured the cci interrupts. also force-registers cci1 master 1, the bus the sensor is on. |
| `camssdiag` | `qcom-camss` with `phy=N` (swaps csiphy0's reg, clocks and interrupt with another phy's) and `lane0=`, `lane1=`, `clklane=` overrides. swap not overwrite, two subdevs on one window kills the probe, and `.csiphy.id` stays put or dt `port@0` stops matching. |
| `ov02diag` | `ov02e10` with `avdd=` and `dvdd=`, which attach a supply property to the sensor's dt node at load time by `regulator-name`. `of_update_property` isn't exported and the property outlives an unload, so a reload patches the phandle in place. |

`mmiopeek` and `aonmclk` are complete sources. the other three are patches
against the v7.1.13 drivers, `prepare.sh` extracts the pristine sources from
the kernel tarball and applies them:

    tools/camera/prepare.sh build/kernel/linux-7.1.13.tar.xz
    make -C tools/camera/ccidiag

a much newer kernel may need the patches re-derived by hand, they are small
and described in [docs/camera.md](../../docs/camera.md).
