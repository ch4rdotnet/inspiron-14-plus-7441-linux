#!/usr/bin/env bash
# decode the panel's edp dpcd backlight capability registers
#
#   sudo edp-backlight.sh             read and decode
#   sudo edp-backlight.sh --restore   put 0x721 back in pwm control mode after a --set
#   sudo edp-backlight.sh --set N     percent, refused on this panel (no aux set cap)
#
# this established that the AUO B140QAX01.H cannot do aux brightness at all,
# 0x702 has BRIGHTNESS_PWM_PIN_CAP set and BRIGHTNESS_AUX_SET_CAP clear, so
# drm_edp_backlight_probe_max() bails and max_brightness is 0. the fix is the
# pwm backlight in the device tree (patch 0002), not anything in dpcd.

set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/../../scripts/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_root

python3 - "$@" <<'PY'
import glob, os, sys

CAP1 = {0: "TCON_BACKLIGHT_ADJUSTMENT_CAP", 1: "BACKLIGHT_PIN_ENABLE_CAP",
        2: "BACKLIGHT_AUX_ENABLE_CAP", 3: "PANEL_SELF_TEST_PIN_ENABLE",
        4: "PANEL_SELF_TEST_AUX_ENABLE", 5: "FRC_ENABLE", 6: "COLOR_ENGINE", 7: "SET_POWER_CAP"}
ADJ = {0: "BRIGHTNESS_PWM_PIN_CAP", 1: "BRIGHTNESS_AUX_SET_CAP", 2: "BRIGHTNESS_BYTE_COUNT",
       3: "AUX_PWM_PRODUCT_CAP", 4: "FREQ_PWM_PIN_PASSTHRU_CAP", 5: "FREQ_AUX_SET_CAP",
       6: "DYNAMIC_BACKLIGHT_CAP", 7: "VBLANK_BACKLIGHT_UPDATE_CAP"}
MODES = {0: "pwm pin", 1: "preset", 2: "dpcd/aux", 3: "product specific"}


def rd(fd, a, n=1):
    try:
        return os.pread(fd, n, a)
    except OSError:
        return None


target = None
for path in sorted(glob.glob("/dev/drm_dp_aux*")):
    try:
        fd = os.open(path, os.O_RDWR)
    except OSError:
        continue
    b = rd(fd, 0x700)
    if b and b[0]:
        target = (path, fd)
        break
    os.close(fd)
if not target:
    sys.exit("no dp aux device answered an edp dpcd read, is the panel awake")
path, fd = target
print(f"edp aux device: {path}\n")


def g(a):
    b = rd(fd, a)
    return b[0] if b else None


cap1, adj, mode = g(0x701), g(0x702), g(0x721)
msb, lsb, pn = g(0x722), g(0x723), g(0x724)


def bits(label, val, table):
    print(f"  0x{label} = 0x{val:02x} ({val:08b})")
    for i in range(8):
        print(f"      bit{i} {'set  ' if val >> i & 1 else '.    '} {table[i]}")


bits("701 GENERAL_CAP_1", cap1, CAP1)
print()
bits("702 BACKLIGHT_ADJUSTMENT_CAP", adj, ADJ)
print()
print(f"  0x721 MODE_SET          = 0x{mode:02x}  control mode: {MODES.get(mode & 3)}")
print(f"  0x722/3 BRIGHTNESS      = 0x{msb:02x}{lsb:02x} ({(msb << 8) | lsb})")
print(f"  0x724 PWMGEN_BIT_COUNT  = {pn}\n")

aux_set = bool(adj >> 1 & 1)
if not aux_set:
    print("  verdict: BRIGHTNESS_AUX_SET_CAP is clear, this panel cannot have its")
    print("  brightness set over aux. drm_edp_backlight_probe_max() returns early and")
    print("  leaves max = 0. the fix is a pwm-backlight in the device tree.")
else:
    print(f"  aux brightness is supported, max should be {(1 << pn) - 1}")

args = sys.argv[1:]
if "--restore" in args:
    os.pwrite(fd, bytes([mode & ~0x03]), 0x721)
    print(f"\nrestored 0x721 to pwm control mode (was 0x{mode:02x})")
elif "--set" in args:
    if not aux_set:
        sys.exit("\nrefusing --set, this panel does not support aux brightness")
    pct = float(args[args.index("--set") + 1])
    maxv = (1 << pn) - 1
    level = int(round(maxv * pct / 100))
    os.pwrite(fd, bytes([pn]), 0x724)
    os.pwrite(fd, bytes([(mode & ~0x03) | 0x02]), 0x721)
    os.pwrite(fd, bytes([(level >> 8) & 0xff, level & 0xff]), 0x722)
    print(f"\nset to {pct}% ({level}/{maxv})")
os.close(fd)
PY
