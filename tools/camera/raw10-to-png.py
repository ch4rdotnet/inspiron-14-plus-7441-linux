#!/usr/bin/env python3
"""turn a packed mipi raw10 bayer frame from the camss rdi path into a png.

the rdi path is a raw dump, no debayer, no gain, no white balance, so this does
the minimum to see whether the sensor is imaging: unpack the 10 bit words,
demosaic grbg by 2x2 binning, and percentile stretch the result.

    raw10-to-png.py IN.raw OUT.png [width] [height]
"""
import sys

import numpy as np
from PIL import Image


def unpack_raw10(buf, width, height):
    # four pixels per five bytes, low bits packed in the fifth
    stride = width * 5 // 4
    usable = stride * height
    if len(buf) < usable:
        raise SystemExit(f"frame is {len(buf)} bytes, need {usable} for {width}x{height}")
    data = np.frombuffer(buf[:usable], dtype=np.uint8).reshape(height, stride)
    grp = data[:, :width * 5 // 4].reshape(height, -1, 5).astype(np.uint16)
    lo = grp[:, :, 4]
    out = np.empty((height, width), dtype=np.uint16)
    for i in range(4):
        out[:, i::4] = (grp[:, :, i] << 2) | ((lo >> (2 * i)) & 0x3)
    return out


def demosaic_grbg(raw):
    g0 = raw[0::2, 0::2].astype(np.float32)
    r = raw[0::2, 1::2].astype(np.float32)
    b = raw[1::2, 0::2].astype(np.float32)
    g1 = raw[1::2, 1::2].astype(np.float32)
    return np.dstack([r, (g0 + g1) / 2, b])


def stretch(rgb):
    lo, hi = np.percentile(rgb, 1), np.percentile(rgb, 99)
    if hi <= lo:
        lo, hi = float(rgb.min()), float(max(rgb.max(), rgb.min() + 1))
    return np.clip((rgb - lo) * 255.0 / (hi - lo), 0, 255).astype(np.uint8)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    width = int(sys.argv[3]) if len(sys.argv) > 3 else 1928
    height = int(sys.argv[4]) if len(sys.argv) > 4 else 1088

    buf = open(src, "rb").read()
    frame_bytes = width * 5 // 4 * height
    frames = max(1, len(buf) // frame_bytes)
    # the last frame, the first ones out of a sensor are still settling
    buf = buf[(frames - 1) * frame_bytes:]

    raw = unpack_raw10(buf, width, height)
    print(f"raw10: {width}x{height}, {frames} frames, min={raw.min()} max={raw.max()} mean={raw.mean():.1f}")
    if raw.max() == raw.min():
        print("frame is a constant value, the sensor is not imaging")
    Image.fromarray(stretch(demosaic_grbg(raw))).save(dst)
    print(f"wrote {dst} ({width // 2}x{height // 2} after 2x2 binning)")


if __name__ == "__main__":
    main()
