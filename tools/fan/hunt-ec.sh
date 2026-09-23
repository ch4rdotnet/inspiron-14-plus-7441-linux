#!/usr/bin/env bash
# everything that needs root in the hunt for a fan controller, read only
#
#   sudo hunt-ec.sh              smbios, gpios, pinmux, scmi, rpmsg, thermal bindings
#   sudo hunt-ec.sh --probe-i2c  also scan every i2c bus (this is what found the ec and the touchscreen)
#
# already ruled out without root, see docs/fan-control.md: no fan in hwmon, no
# fan cooling device, no fan or tach node in the dt, no spi devices, no dell
# platform driver for aarch64, and the qmi tmd service lists only cpu and dsp
# mitigations.

set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../../scripts/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_root

echo "1. smbios cooling device and temperature probes"
if command -v dmidecode >/dev/null; then
    dmidecode -t 27 2>/dev/null | sed 's/^/  /'
    dmidecode -t 28 2>/dev/null | sed 's/^/  /'
else
    for d in /sys/firmware/dmi/entries/27-*/; do od -An -tx1 -v "$d/raw" | sed 's/^/  /'; done
fi

echo
echo "2. dell oem smbios tables (220 has six instances, plausibly per fan or per zone)"
for t in 177 178 179 208 216 217 220 221 222 255; do
    for d in /sys/firmware/dmi/entries/$t-*/; do
        [[ -d $d ]] || continue
        echo "  --- $(basename "$d") ($(stat -c%s "$d/raw") bytes)"
        od -An -tx1 -v "$d/raw" 2>/dev/null | sed 's/^/    /'
        strings "$d/raw" 2>/dev/null | sed 's/^/    str: /'
    done
done

echo
echo "3. every gpio, claimed or not (looking for a fan pwm out or tach in)"
sed 's/^/  /' /sys/kernel/debug/gpio 2>/dev/null

echo
echo "4. pinmux"
for d in /sys/kernel/debug/pinctrl/*/; do
    echo "  --- $(basename "$d")"
    [[ -r $d/pinmux-pins ]] && grep -v UNCLAIMED "$d/pinmux-pins" | sed 's/^/  /'
done

echo
echo "5. scmi protocols the firmware implements"
ls /sys/kernel/debug/scmi/ 2>/dev/null | sed 's/^/  /' || echo "  no scmi debugfs"

echo
echo "6. the adsp power limits rpmsg channel (listing only, never write to it blind)"
ls -la /sys/bus/rpmsg/devices/ | grep -i lmts | sed 's/^/  /'

echo
echo "7. thermal zone -> cooling device bindings"
for z in /sys/class/thermal/thermal_zone*/; do
    t=$(cat "$z/type" 2>/dev/null)
    for c in "$z"cdev*/; do
        [[ -e $c ]] || continue
        echo "  $t -> $(cat "$c/type" 2>/dev/null || basename "$(readlink -f "$c")")"
    done
done | sort -u | head -20

if [[ ${1:-} == --probe-i2c ]]; then
    echo
    echo "8. i2c bus scan (read transactions, can upset a device mid transfer)"
    need_cmd i2cdetect i2c-tools
    for a in /sys/class/i2c-adapter/i2c-*; do
        b=${a##*i2c-}
        echo "  --- i2c-$b ($(cat "$a/name"))"
        i2cdetect -y -r "$b" 2>/dev/null | sed 's/^/  /'
    done
else
    echo
    echo "(add --probe-i2c to scan the i2c buses)"
fi
