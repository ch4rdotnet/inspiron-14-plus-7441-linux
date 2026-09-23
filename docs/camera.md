# camera

status: **the soc side works, the sensor probes and streams, the csiphy never
locks, no frames arrive.** everything from the sensor's i2c to the vfe write
master is identified and in the device tree (patches 0004, 0005, 0006, in
`patches/camera/`, built with `scripts/build-kernel.sh --camera`). what is
left needs either qualcomm's downstream camera tree or a logic probe.

two earlier claims in these notes were wrong, and the corrections matter:

1. "no CAMSS support for this soc in any kernel". wrong, the driver has matched
   `qcom,x1e80100-camss` all along.
2. "the cci register base is not published anywhere reachable". wrong, it is in
   this machine's own uefi, see [acpi-tables.md](acpi-tables.md).

## what works

`camss` and `camcc` are described in the dt (patch 0005) and both probe:

```
$ ls -l /sys/bus/platform/devices/acb7000.isp/driver
-> qcom-camss
$ ls -l /sys/bus/platform/devices/ade0000.clock-controller/driver
-> camcc-x1e80100          # 56 clock consumers
$ media-ctl -d /dev/media0 -p
driver          qcom-camss
model           Qualcomm Camera Subsystem
bus info        platform:acb7000.isp
```

41 entities, the full pipeline:

| block | instances |
|---|---|
| csiphy (mipi d-phy receivers) | csiphy0, 1, 2, 4 |
| csid (csi decoders) | csid0..csid4 |
| vfe (isp) | vfe0..vfe3, each with 3 or 4 rdi paths and a pix path |
| capture nodes | 16, `/dev/video2` .. `/dev/video17` |

no smmu faults, no probe errors. the dt came from the upstream binding examples
(`hamoa.dtsi`: `camss: isp@acb7000` with 17 reg ranges, 29 clocks, 13
interrupts, 4 interconnects, 8 iommu sids, 3 power domains, plus
`camcc: clock-controller@ade0000`), with one correction to the csiphy windows
described below.

## the missing link, cci

sensors don't sit on a normal i2c bus. they hang off cci, qualcomm's dedicated
camera i2c master. upstream has no cci node for x1e80100 and `qcom,i2c-cci.yaml`
has no compatible for it, so there was no bus to attach a sensor to and no way
to even ask the sensor what it is.

the register bases are in the dsdt that dell's uefi hands to windows. device
`\_SB.CAMP`, `_HID` `QCOM0C32`, `_CRS`:

```
Memory32Fixed  0x0ac13000  4K
Memory32Fixed  0x0ac19000  48K
Memory32Fixed  0x0ac15000  4K
Memory32Fixed  0x0ac16000  4K
Interrupt      SPI 460
Interrupt      SPI 271
Interrupt      SPI 459
Gpio (Io)      pin 99      \_SB.GIO0
Gpio (Io)      pin 110     \_SB.GIO0
```

cross checks that say these are real:

- `0x0acca000`, `0x0ace4000`, `0x0ace6000`, `0x0ace8000`, `0x0acec000`,
  `0x0acf6000`, `0x0acf7000`, `0x0acf8000` also appear in that dsdt and are
  already in the upstream camss reg list. same soc, same numbers, the dsdt is
  describing the block that works.
- `0x0ac15000` and `0x0ac16000` are `cci0` and `cci1` on every soc of this
  generation (sm8450, sm8550, sm8650, milos).
- `0x0ac13000` plus spi 460 is exactly sa8775p's `cci0`, and spi 271 is exactly
  sa8775p's `cci1`. so x1e appears to share gic assignments with sa8775p even
  though the address layout looks like sm8550's.
- none of spi 459, 460, 271 is claimed by anything in `hamoa.dtsi`.
- `include/dt-bindings/clock/qcom,x1e80100-camcc.h` defines `CAM_CC_CCI_0_CLK`
  and `CAM_CC_CCI_1_CLK` and nothing else, so at most two of those apertures
  are cci.

the pins line up too, from `pinctrl-x1e80100.c`:

```
gpio96-99    cam_mclk       sensor master clocks
gpio100      cam_aon
gpio101-106  cci_i2c        three sda/scl pairs
gpio109-113  cci_timer / cci_async
gpio235,236  aon_cci        separate always-on bus
```

no kernel patch is needed for cci itself. `i2c-qcom-cci` already carries
`qcom,msm8996-cci` as the generic v2 entry, which is what every soc of this
generation uses. this is pure dt.

### settled on hardware

a test kernel instantiated all three candidate apertures at once. all three
failed to probe with `CCI reset timeout`, which was not the end of it. a
diagnostic build of the driver (`tools/camera/ccidiag`, an out-of-tree copy,
no rebuild needed since `I2C_QCOM_CCI=m`) that reads `CCI_HW_VERSION` and falls
back to polling `CCI_IRQ_STATUS_0` separated the causes:

```
ac15000.cci: HW_VERSION = 0x10070000   no IRQ, but RST_DONE_ACK IS set -> registers good, IRQ wrong
ac16000.cci: HW_VERSION = 0x10070000   no IRQ, but RST_DONE_ACK IS set -> registers good, IRQ wrong
ac13000.cci: HW_VERSION = 0x00060905   no IRQ and RST_DONE_ACK not set -> reset never completed
```

two real ccis and one impostor. the interrupts were then measured rather than
guessed, by mapping every candidate spi onto the gic by hand, resetting each
controller, and seeing which line rises:

```
ac15000.cci: *** SPI 460 FIRED ***
ac16000.cci: *** SPI 271 FIRED ***
ac13000.cci: (nothing)
```

feeding those back in, both controllers come up:

```
ac15000.cci: using SPI 460 -> *** RESET COMPLETED VIA INTERRUPT - CCI IS UP ***
ac16000.cci: using SPI 271 -> *** RESET COMPLETED VIA INTERRUPT - CCI IS UP ***
i2c-8  Qualcomm-CCI      i2c-9  Qualcomm-CCI      i2c-10  Qualcomm-CCI
```

the final answer, now in patch 0005:

| node | reg | interrupt | clock |
|---|---|---|---|
| `cci0` | 0x0ac15000 | GIC_SPI 460 | `CAM_CC_CCI_0_CLK` |
| `cci1` | 0x0ac16000 | GIC_SPI 271 | `CAM_CC_CCI_1_CLK` |

this is sm8550/sm8650's address layout with sa8775p's interrupt assignment,
which is why guessing from either soc alone got it half wrong, and did.

two apertures are accounted for and two are not. `0x0ac13000` reads
`0x00060905` and is some other block, and spi 459 belongs to neither cci.
`0x0ac14000` is not mapped at all, reading it raises a synchronous external
abort. don't sweep this range blindly (`tools/camera/mmiopeek` reads a few
words of a window and is only safe while the surrounding clocks are on). the
kernel survives the abort, but only because it traps it.

## the board already describes this camera

`x1-dell-thena.dtsi` contains a complete camera wiring description that nothing
references, orphan nodes left in by whoever wrote the board file:

```dts
vreg_cam_1p8: regulator-cam-1p8 {      /* 1.8 V, enabled by tlmm 91 */
	gpio = <&tlmm 91 GPIO_ACTIVE_HIGH>;
	pinctrl-0 = <&cam_ldo_en>;
};

cam_rgb_default: cam-rgb-default-state {
	mclk-pins   { pins = "gpio100";  function = "cam_aon"; drive-strength = <16>; };
	reset-n-pins{ pins = "gpio237";  function = "gpio";    drive-strength = <2>;  };
};

cam_indicator_en: cam-indicator-en-state { pins = "gpio110"; function = "gpio"; };
```

this changes where to look. the mclk pin is `cam_aon`, not `cam_mclk`, and reset
is gpio237, adjacent to the `aon_cci` pins at gpio235/236. so the sensor is on
the always-on bus, not on the `cci_i2c` pins.

it also corrects a guess made earlier: the two gpios in the dsdt `_CRS` are 99
and 110, and gpio110 is the privacy led (`led-camera-indicator`, already wired
up as a gpio-led), not a sensor reset line.

| signal | pin |
|---|---|
| i2c | gpio235, gpio236 (`aon_cci`) |
| mclk | gpio100 (`cam_aon`) |
| reset | gpio237 |
| 1.8 v enable | gpio91 (`vreg_cam_1p8`) |
| privacy led | gpio110 |

## the camera module is on the bus

cci v2 has two masters per controller, four buses, but only three `cci_i2c` pin
pairs exist (gpio101/102, 103/104, 105/106). the fourth master has to surface
somewhere, and the board's camera i2c is on gpio235/236 (`aon_cci`). the dt
declared only one bus for cci1, so master 1 was never registered and never
scanned. force-registering it (`tools/camera/ccidiag`) finds it:

```
i2c-8  Qualcomm-CCI      cci0 master 0     empty
i2c-9  Qualcomm-CCI      cci0 master 1     empty
i2c-10 Qualcomm-CCI      cci1 master 0     empty
i2c-11 Qualcomm-CCI-m1   cci1 master 1     0x50   <-- camera module EEPROM
```

0x50 answers. that is the camera module's calibration eeprom, and it reads out
cleanly with 16 bit addressing (12 bytes per transfer, cci v2's `max_read_len`
quirk):

```
+0    01 1e 00 00 00 00 00 00 00 02 49 02
+12   6e 04 01 03 43 01 c3 04 01 00 d1 00
```

768 bytes were dumped, no ascii anywhere, it is lens shading and awb calibration
tables. so it doesn't name the sensor, but it proves the module is present,
powered enough to talk, and on cci1 master 1. the dt needs a
`cci1_i2c1: i2c-bus@1` node with the `aon_cci` pinctrl, and patch 0005 adds it.

## the sensor, omnivision OV02E10

mclk was the blocker, not power. the module answers i2c on nothing but
`vreg_cam_1p8` plus a master clock, so the earlier guess that avdd and dvdd were
missing was wrong.

the chain that cracked it:

1. `x1-dell-thena.dtsi` puts sensor mclk on gpio100, function `cam_aon`. on
   sm8550 the same function is spelled `cam_aon_mclk4`, so `cam_aon` is mclk4.
   that is the whole clue.
2. mux gpio100 to it, enable `CAM_CC_MCLK4_CLK` (`tools/camera/aonmclk` did
   this by hand), rescan, and a second device appears:

```
i2c-11:  0x10  0x50        <- sensor, and the EEPROM we already had
```

3. it uses 8 bit register addressing (unusual for a modern mipi sensor) and
   reads:

```
0x00  45 02 56 10 01 00 00 00 ...
0x8e  07 88      = 1928       <- width
0x90  04 40      = 1088       <- height
```

4. the dell driver pack names it outright:

```
.../qccamfrontsensor_extension8380/com.qti.sensormodule.ov02e10.bin
.../qccamauxsensor_extension8380/com.qti.sensormodule.hm1092.bin
```

so the front camera is an omnivision OV02E10 and the aux (presence, ir) sensor
is a himax HM1092. everything checks out against the upstream driver.
`ov02e10.c` uses `devm_cci_regmap_init_i2c(client, 8)`, 8 bit addressing, and
its mode table is 1928x1088.

the driver already exists and is already built, `CONFIG_VIDEO_OV02E10=m`, and
`ov02e10.ko` ships in the fedora kernel. it has an of match (`ovti,ov02e10`),
so no driver work is needed, only device tree.

## the camcc bug that blocks it

`ov02e10` refuses to probe unless its clock reads exactly 19.2 mhz:

```c
freq = clk_get_rate(ov02e10->img_clk);
if (freq != OV02E10_MCLK)      /* 19200000 */
	return dev_err_probe(..., "external clock %lu is not supported", freq);
```

that rate is unobtainable on this soc. `camcc-x1e80100.c` has:

```c
F(19200000, P_BI_TCXO, 1, 0, 0),
```

but `bi_tcxo` is 38.4 mhz here, not 19.2:

```
xo-board            76800000
  bi_tcxo           38400000
    cam_cc_mclk4_clk_src   48000000
```

a pre-divider of 1 therefore yields 38.4 mhz, and asking for 19.2 mhz returns
`-EINVAL`. every rate in that table comes out at exactly 2x its label, asking
for 24 mhz gives 48 mhz. the table was written for a 19.2 mhz xo.

the fix is one line, `F(19200000, P_BI_TCXO, 2, 0, 0)`, and it is a genuine
upstream bug, not a board quirk. any sensor needing a 19.2 mhz mclk cannot work
on x1e80100 without it. this is
`patches/camera/0004-clk-qcom-camcc-x1e80100-fix-MCLK-rates-for-the-38.4-.patch`.

## first boot with the sensor node, it probes

with patch 0006 the sensor came up:

```
ov02e10 8-0010: supply avdd not found, using dummy regulator
ov02e10 8-0010: supply dvdd not found, using dummy regulator
```

those two were expected at the time, the module generates its own analog rails
from the 1.8 v input, which is why it answered i2c on `vreg_cam_1p8` alone. no
other complaint, and it binds:

```
/sys/bus/i2c/devices/8-0010/driver -> ov02e10
```

it is in the media graph, and csiphy0 was the right guess as far as binding
goes:

```
- entity 387: ov02e10 8-0010 (1 pad, 1 link)   /dev/v4l-subdev25
	pad0: SOURCE [fmt:SGRBG10_1X10/1928x1088]
		-> "msm_csiphy0":0 [ENABLED,IMMUTABLE]
```

the default links already form a complete path, and formats set cleanly along
all of it:

```
ov02e10 -> msm_csiphy0 -> msm_csid0 -> msm_vfe0_rdi0 -> /dev/video2
```

## the csiphy register windows are too small

`VIDIOC_STREAMON` oopsed:

```
Unable to handle kernel paging request at virtual address ffff80008208e000
  FSC = 0x07: level 3 translation fault ... WnR = 1
Call trace:
  csiphy_reset+0x30/0x70 [qcom_camss]
  csiphy_set_power+0x94/0x1b0 [qcom_camss]
  v4l2_pipeline_pm_get / video_prepare_streaming / vb2_ioctl_streamon
```

a write one page past the end of an ioremap mapping (`x2` = ...8d000 mapped,
faulting write at ...8e000). the camss node inherited 4 kb csiphy windows from
the binding example, but the hardware has 8 kb, and the driver programs this
soc's csiphys at `+0x1000` (`csiphy_init()` sets `regs->offset = 0x1000` for
`CAMSS_X1E80100`):

```
              DT       DSDT
csiphy0    0x1000     0x2000     *** too small ***
csiphy1    0x1000     0x2000     *** too small ***
csiphy2    0x1000     0x2000     *** too small ***
csiphy4    0x4000     0x2000
```

8 kb also makes sense of the layout. 0x0ace4000, 0x0ace6000, 0x0ace8000 are
contiguous on an 8 kb stride, with csiphy4 at 0x0acec000 leaving a gap where
csiphy3 would sit.

this is an upstream bug, not a board quirk. any attempt to stream from camss on
x1e80100 oopses the kernel, which is likely why nobody has reported using it.
fixed by widening the windows to 0x2000 in patch 0005.

`csid_lite1` (0x0acca000) is also 0x1000 in dt against 0x4000 in the dsdt, but
0x4000 there would overlap `vfe_lite1` at 0x0accb000, so it is probably a
combined region in the dsdt's view. left alone, it is not on this path.

## with the csiphy fix, the sensor streams, the phy does not lock

with the windows widened it no longer oopses. the pipeline configures end to
end:

```
ov02e10 -> msm_csiphy0 -> msm_csid0 -> msm_vfe0_rdi0 -> /dev/video0
qcom-camss acb7000.isp: VFE:0  HW Version = 3.0.2
qcom-camss acb7000.isp: CSID:0 HW Version = 3.0.0
qcom-camss acb7000.isp: RDI0 WM:24 width 1928 height 1088 stride 2416
```

but no frames arrive (`tools/camera/capture-camera.sh` reports 0 bytes). what was
established, in order:

**the sensor really is streaming.** i2c tracing during streamon shows the driver
writing its whole register table and then the stream-on register, and the
matching write at stream-off:

```
# echo 1 > /sys/kernel/debug/tracing/events/i2c/enable
i2c_write: i2c-8 a=010 l=2 [fd-00]    page select
i2c_write: i2c-8 a=010 l=2 [a0-01]    STREAM ON      (127 writes in total)
...
i2c_write: i2c-8 a=010 l=2 [a0-00]    STREAM OFF
```

**clocks and supplies are genuinely on** during streaming, csiphy0 at 300 mhz,
csi0phytimer at 266 mhz, csid at 300 mhz, and both `vdd-csiphy-*` rails enabled
with a consumer each.

**"CSIPHY 3PH HW Version = 0x00000000" is a red herring.** scanning the whole
8 kb window while streaming shows the block is alive, it is only the version
words that are unimplemented:

```
0xace4000 + 0x10b0 = 0x000000ff     <- CMN_CSI_COMMON_STATUS[0..7], all error bits latched
...        + 0x10cc = 0x000000ff
0xace4000 scanned 2048 words, 12 non-zero
```

the version is read from STATUS[12..15] (`offset 0x1000` plus
`common_status_offset 0xb0`), which read zero on this soc. STATUS[0..7] reading
0xff is the phy reporting that it is enabled and seeing nothing valid.

## the analog rail hypothesis

the sensor talks i2c perfectly on `vreg_cam_1p8` alone, but an i2c interface
runs off dovdd while the analog section and the mipi transmitter need avdd and
dvdd. the driver logged both as absent at every probe, and dummy regulators
enable successfully and do nothing, which fits the symptom exactly. the sensor
accepts its full register table and the stream-on write, and then transmits
nothing.

nothing in the board file or the dsdt names these rails (the vendor stack
programs the pmic directly), so the unused ldos at the right voltages were
tried:

| supply | rail | |
|---|---|---|
| dovdd | `vreg_cam_1p8` | the board's own camera rail, known |
| avdd | `vreg_l7b_2p8` | 2.8 v, no other consumer |
| dvdd | `vreg_l1c_1p2` | 1.2 v, no other consumer |

these are what patch 0006 carries, marked unverified in the node's comment. they
made no difference.

## what was eliminated, and how

rather than a kernel rebuild per guess (~20 minutes each), both remaining
variables were made runtime selectable, because `I2C_QCOM_CCI`,
`VIDEO_QCOM_CAMSS` and `VIDEO_OV02E10` are all modules:

| tool | what it makes switchable |
|---|---|
| `tools/camera/camssdiag` | out-of-tree camss. `phy=` swaps csiphy0's reg, clock and interrupt with another phy's, `lane0=`, `lane1=`, `clklane=` override the parsed lane positions |
| `tools/camera/ov02diag` | out-of-tree ov02e10. `avdd=` and `dvdd=` attach a supply property to the sensor's dt node at load time, by looking up a rail's phandle by `regulator-name` |

two implementation notes worth keeping. in camssdiag the phy resources must be
swapped, not overwritten, re-pointing makes two subdevs claim the same register
window and camss fails to probe entirely, and `.csiphy.id` must be left alone
or dt `port@0` no longer matches and the sensor drops out of the graph. in
ov02diag, `of_update_property` is not exported and the added property survives
a module unload, so a reload patches the existing phandle in place.

eliminated:

- **csiphy choice.** all four (csiphy0, 1, 2, 4) bind the sensor, none captures.
- **analog rails.** six combinations of the unused ldos at plausible voltages
  (`vreg_l7b_2p8`, `vreg_l9b_2p9`, `vreg_l6b_1p8` against `vreg_l1c_1p2`,
  `vreg_l2i_1p2`). verified genuinely applied, all three rails read `enabled`
  with a consumer during streaming.
- **lane mapping.** clk/data of (0,1), (1,2), (2,3), (1,0) and clk=1 with (2,3).

confirmed good in the same runs: mclk4 enabled at exactly 19.2 mhz, 127 i2c
writes ending in the stream-on register, `VFE:0 3.0.2`, `CSID:0 3.0.0`, and
the rdi write master programmed for 1928x1088 stride 2416. no driver logs an
error anywhere.

one measurement stands out. during streaming, the entire 8 kb csiphy window has
only two non-zero registers:

```
0xace4000 + 0x10d8 = 0x00000040
0xace4000 + 0x10fc = 0x000000d8
0xace4000 scanned 2048 words, 2 non-zero      (idle: 0 non-zero)
```

a configured d-phy would normally have a good deal more set. many qualcomm phy
registers are write only, so this is suggestive rather than conclusive, but it
is consistent with the lane programming not taking effect.

## the two remaining hypotheses

neither can be settled by probing from outside:

1. **the x1e80100 csiphy lane programming in upstream camss has never been
   exercised against a real sensor.** nothing upstream describes a camera on
   any snapdragon x board, and the two bugs found on the way here (the camcc
   divider and the csiphy windows) are exactly the kind that survive when a
   code path has only ever been compiled, not run.
2. **the always-on camera has a receive path camss does not model.** the sensor
   sits on the aon i2c bus with an aon mclk. the dsdt also lists `0x0ac13000`
   (reads `0x00060905`, not a cci) and a 48 kb block at `0x0ac19000` that
   nothing has identified. if the aon camera feeds a receiver in there rather
   than one of the four csiphys, none of the above would ever work.

next steps would need either qualcomm's downstream camera tree for x1e80100, or
a logic probe on the mipi lanes to confirm the sensor is physically
transmitting.

## what is still unknown

- **which csiphy the module's lanes land on.** nothing in the dsdt or the board
  file says. the dt guesses `csiphy0`, and all four have been tried.
- **whether the csiphy supplies are right.** `vreg_l2c_0p8` and `vreg_l2i_1p2`
  in the board file are a guess, picked as unused rails of the right voltage.
- **libcamera.** camss on x1e is new, userspace may not be ready even once the
  kernel is. raw v4l2 capture from an rdi node is enough to prove the pipeline.
- **the aux HM1092.** not attempted, no upstream driver.

not unknown any more, and worth striking off the old list: the sensor part, its
bus, its mclk, its i2c address, its register width, and whether firmware is
needed (it is not, camss has no `request_firmware` at all, so `CAMERA_ICP.mbn`
was never a prerequisite for raw capture).

## honest verdict

everything up to the phy is identified and in the dt. both cci controllers
with measured interrupts, the sensor's bus (cci1 master 1, on the always-on
pins), the part itself, its clock, and the camcc fix that makes that clock
reachable. the driver is upstream and already built. the sensor takes its
register table and the stream-on write, and the vfe is programmed to receive.
the csiphy never locks and no frames arrive, and the reason isn't reachable
from outside the soc.

three of the pieces are upstreamable on their own regardless of whether the
camera ever streams: the camcc mclk divider fix (0004), cci and the csiphy
window fix for x1e80100 (0005), and the board camera nodes (0006, once the
rails and csiphy are confirmed).

tools: `tools/camera/probe-cci.sh` checks the controllers and scans their buses,
`tools/camera/capture-camera.sh` configures the pipeline and tries to grab frames,
`tools/camera/raw10-to-png.py` turns a raw10 frame into something viewable,
`tools/camera/README.md` covers the diagnostic modules.
