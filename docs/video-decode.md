# hardware video decode: a disabled fedora config option

## symptom

```
qcom-iris aa00000.video-codec: deferred probe timeout, ignoring dependency
qcom-iris aa00000.video-codec: probe with driver qcom-iris failed with error -110
```

no `/dev/video*`, so all video decoding is on the cpu.

`-110` is `ETIMEDOUT` from `driver_deferred_probe_check_state()`, a dependency
provider never appeared. it is not a missing firmware file, `qcvss8380.mbn` was
installed with the rest of the latitude 7455 blobs and the dt node is
`status = "okay"`.

## cause

listing device tree nodes with no driver bound (`scripts/find-unbound.sh`)
shows the real gap:

```
aaf0000.clock-controller   qcom,x1e80100-videocc    <-- unbound
aa00000.video-codec        qcom,x1e80100-iris       <-- waiting on the above
1dfa000.crypto             qcom,x1e80100-qce        <-- unbound (see below)
```

the video clock controller has no driver. fedora ships it disabled:

```
# CONFIG_SM_VIDEOCC_8550 is not set
```

despite `drivers/clk/qcom/videocc-sm8550.c` explicitly matching this soc:

```c
static const struct of_device_id video_cc_sm8550_match_table[] = {
	{ .compatible = "qcom,sm8550-videocc" },
	{ .compatible = "qcom,sm8650-videocc" },
	{ .compatible = "qcom,x1e80100-videocc" },
```

with x1e specific pll configuration and frequency tables in its probe, and a
kconfig help text that names the platform outright:

> Support for the video clock controller on Qualcomm Technologies, Inc. SM8550
> or SM8650 or X1E80100 devices. Say Y if you want to support video devices and
> functionality such as video encode/decode.

that driver provides `video_cc_mvs0c_gdsc` and `video_cc_mvs0_gdsc`, the
`venus` and `vcodec0` power domains iris asks for, plus the `vcodec0_core`
clock. without it, iris waits and times out.

so this is a distro configuration gap, not a kernel code gap. nothing needs
patching.

## fix

`config/kernel-local`, the spec's documented hook for local config changes,
merged over the generated config by `merge.py`:

```
CONFIG_SM_VIDEOCC_8550=m
```

then rebuild with `scripts/build-kernel.sh`.

an aside on rebuild cost. the prediction was that this change would invalidate
the whole ccache, since `autoconf.h` is included by every translation unit. it
did invalidate direct mode, but ccache fell back to preprocessed mode and still
hit 99.99%:

```
Direct:         2175 / 25951  ( 8.38%)
Preprocessed:  23776 / 25951  (91.62%)
```

adding one unrelated `CONFIG_*_MODULE` define does not change the preprocessed
output of files that never reference it. the ~18 minutes was modpost, xz
compressing 5,795 modules, and building rpm payloads, not compilation.

## status: working

after reboot:

```
/dev/video0: 'Iris Decoder'   driver=iris_driver  platform:aa00000.video-codec
/dev/video1: 'Iris Encoder'   driver=iris_driver  platform:aa00000.video-codec

aaf0000.clock-controller -> video_cc-sm8550
aa00000.video-codec      -> qcom-iris
```

both decode and encode. no errors in the log.

## not fixing: the crypto engine

`1dfa000.crypto` (`qcom,x1e80100-qce`) is also unbound, because
`CONFIG_CRYPTO_DEV_QCE` is not set. leaving it that way is deliberate. these
oryon cores have armv8 crypto extensions,

```
aes pmull sha1 sha2 sha3 sha512
```

which generally outperform the qce offload for everything except very large
bulk operations, since each offload costs a descriptor round trip. enabling it
would more likely cost performance than gain it.

## worth reporting

fedora should enable `CONFIG_SM_VIDEOCC_8550` on aarch64. it is the only thing
standing between a supported x1e80100 laptop and working hardware video decode,
the driver is already in the tree, and the option is already enabled for
several other qualcomm socs (`SM_VIDEOCC_8250`, `SM_VIDEOCC_8350`,
`SC_VIDEOCC_7280`, ...). see [upstreaming.md](upstreaming.md).

## codec and format support, read from the driver

```
/dev/video0  Iris Decoder        /dev/video1  Iris Encoder
  compressed in : H264, HEVC, VP9, AV1      raw in  : NV12, Q08C
  raw out       : NV12, Q08C                out     : H264, HEVC
  frame size    : up to 8192 per dimension
```

8 bit only. the capture queue advertises `NV12` and `Q08C` (qcom compressed
8 bit) and nothing else, no `P010`, no `Q10C`. so 10 bit content cannot be
hardware decoded, gstreamer fails caps negotiation with:

```
streaming stopped, reason not-negotiated (-4)
```

that is a driver limitation, not a configuration problem. a 10 bit hdr file
will silently fall back to software (dav1d, libde265, etc) or fail outright
depending on the pipeline. `scripts/test-hwdec.sh FILE` checks the pixel
format first and then tries the hardware decoder explicitly.

note the queue types are easy to get backwards. for an m2m decoder,
`V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE` (10) is the compressed input and
`V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE` (9) is the raw output.

## which players can use it

| player | framework | hardware decode |
|---|---|---|
| showtime (gnome videos) | gstreamer | yes, `v4l2h264dec`, `v4l2h265dec`, `v4l2vp9dec`, `v4l2av1dec`, all ranked primary+1 |
| clapper | gstreamer | yes |
| mpv | ffmpeg | vp9, vp8 and mpeg only. fedora's ffmpeg omits the h264 and hevc v4l2m2m decoders. use `--hwdec=v4l2m2m-copy` |
| helium and other chromium browsers | chromium v4l2 | yes, with flags, see below |
| firefox | ffmpeg plus vaapi | no. needs vaapi, and there is no vaapi driver for this hardware |

## chromium based browsers

chromium has two hardware decode paths on linux. `VaapiVideoDecoder` is a dead
end here (no vaapi driver exists for this hardware), but `V4L2VideoDecoder`
talks to `/dev/video0` directly, and it is compiled into the binary:

```
$ strings /opt/helium/helium | grep -oE "V4L2[A-Za-z]*VideoDecoder"
V4L2VideoDecoder
```

it is a chromeos oriented path and off by default on desktop linux, but
enabling it works. `chrome://gpu` reports "Video Decode: Hardware accelerated":

```
helium --enable-features=V4L2VideoDecoder,AcceleratedVideoDecodeLinuxGL \
       --ignore-gpu-blocklist --enable-accelerated-video-decode
```

`scripts/browser-hwdec.sh` makes it permanent with a desktop file override in
`~/.local/share/applications/`, copied from `/usr/share/applications/` with the
flags added to every `Exec=` line, including the new window and incognito
actions. step 4 of [INSTALL.md](../INSTALL.md) runs it.

firefox has no equivalent path, it only does vaapi, so it cannot be fixed the
same way.

verify a stream is really using it via `chrome://media-internals` (check the
decoder name) or by watching dropped frames in youtube's stats for nerds.
remember 10 bit falls back to software regardless.

## gstreamer rank

the gstreamer v4l2 decoders outrank the software ones already (257 against
256), so no configuration should be needed. if a software decoder still gets
picked, force it:

```
GST_PLUGIN_FEATURE_RANK=v4l2av1dec:MAX,v4l2h264dec:MAX,v4l2h265dec:MAX,v4l2vp9dec:MAX
```

put it in `~/.config/environment.d/gst.conf` to keep it.
