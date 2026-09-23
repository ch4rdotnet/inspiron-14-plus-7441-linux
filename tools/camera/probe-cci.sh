#!/usr/bin/env bash
# health check of the cci controllers and a scan of their buses
#
#   sudo probe-cci.sh
#
# the apertures and interrupts are settled (cci0 0x0ac15000 spi 460, cci1
# 0x0ac16000 spi 271, both confirmed on hardware), so this is a check rather
# than an experiment. the sensor is on cci1 master 1, the always-on pins
# gpio235/236, at 0x10, and only answers while mclk4 runs. see docs/camera.md

set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../../scripts/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_root

hdr() { printf '\n%s\n' "$1"; }

hdr "cci platform devices"
found=0
for d in /sys/bus/platform/devices/*.cci; do
    [[ -e $d ]] || continue
    found=1
    if [[ -e $d/driver ]]; then
        printf '  %-16s bound to %s\n' "$(basename "$d")" "$(basename "$(readlink "$d/driver")")"
    else
        printf '  %-16s not bound\n' "$(basename "$d")"
    fi
done
(( found )) || echo "  none, the dt nodes are missing or disabled (patches 0005 and 0006, build-kernel.sh --camera)"

hdr "probe messages"
journalctl -b -k --no-pager 2>/dev/null | grep -iE 'cci|camss|camcc|ov02e10' | tail -25 | sed 's/^/  /'

hdr "interrupts"
grep -iE 'cci' /proc/interrupts | sed 's/^/  /' || echo "  no cci interrupts registered"

hdr "scanning cci buses"
need_cmd i2cdetect i2c-tools
for a in /sys/class/i2c-adapter/i2c-*; do
    [[ -e $a ]] || continue
    n=${a##*i2c-}
    case $(readlink -f "$a/../..") in *cci*) ;; *) continue ;; esac
    echo "  i2c-$n ($(cat "$a/name" 2>/dev/null))"
    i2cdetect -y -r "$n" 2>&1 | sed 's/^/    /'
done

hdr "camera rails"
for r in /sys/class/regulator/*; do
    n=$(cat "$r/name" 2>/dev/null) || continue
    case $n in *cam*|*CAM*|*l7b*|*l1c*) printf '  %-16s state=%s\n' "$n" "$(cat "$r/state" 2>/dev/null)" ;; esac
done

hdr "camera pin mux (91 ldo, 100 mclk, 101-106 cci_i2c, 110 led, 235-237 aon cci and reset)"
f=$(find /sys/kernel/debug/pinctrl -name pinmux-pins 2>/dev/null | grep -i tlmm | head -1)
[[ -n $f ]] && grep -E 'pin (91|100|10[1-6]|110|23[567]) ' "$f" | sed 's/^/  /' || echo "  debugfs not readable"
