#!/usr/bin/env bash
# one pass over everything this project fixes, pass or fail per item
#
#   verify.sh        no root needed, run from a desktop terminal for the gpu check

[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

pass=0; fail=0
good() { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$1"; pass=$((pass + 1)); }
bad()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RST" "$1"; fail=$((fail + 1)); }
skip() { printf '  %s?%s %s\n' "$C_YLW" "$C_RST" "$1"; }

echo "== kernel =="
echo "  $(uname -r)"

echo "== remoteproc =="
for d in /sys/class/remoteproc/*/; do
    n=$(cat "$d/name" 2>/dev/null); s=$(cat "$d/state" 2>/dev/null)
    [[ $s == running ]] && good "$n: $s" || bad "$n: $s"
done

echo "== initramfs =="
img=/boot/initramfs-$(uname -r).img
if [[ -r $img ]]; then
    n=$(lsinitrd "$img" 2>/dev/null | grep -cE 'qcadsp8380|qccdsp8380|adsp_dtbs|cdsp_dtbs')
    (( n >= 4 )) && good "$n/4 firmware files in the image" || bad "only $n/4 firmware files in the image"
    m=$(lsinitrd "$img" 2>/dev/null | grep -cE 'leds-qcom-lpg|pwm_bl')
    (( m >= 2 )) && good "backlight modules in the image" || bad "backlight modules missing from the image"
else
    skip "cannot read $img without root"
fi

echo "== battery =="
b=/sys/class/power_supply/qcom-battmgr-bat/uevent
if [[ -s $b ]] && grep -q 'POWER_SUPPLY_STATUS=' "$b" 2>/dev/null; then
    good "$(grep -E 'POWER_SUPPLY_(STATUS|ENERGY_NOW|ENERGY_FULL)=' "$b" | tr '\n' ' ')"
else
    bad "no battery data (adsp offline?)"
fi

echo "== audio =="
if grep -q . /proc/asound/cards 2>/dev/null && ! grep -q 'no soundcards' /proc/asound/cards; then
    good "card: $(sed -n '1s/^ *//p' /proc/asound/cards)"
    command -v wpctl >/dev/null && wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p' | sed 's/^/    /'
else
    bad "no sound cards"
fi

echo "== cpufreq =="
n=$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null | wc -l)
if (( n == 3 )); then
    good "3 policies: $(for p in /sys/devices/system/cpu/cpufreq/policy*; do printf '[%s] ' "$(cat "$p/affected_cpus")"; done)"
elif (( n == 0 )); then
    bad "no cpufreq policy at all (scmi-cpufreq not loaded)"
else
    bad "$n of 3 policies (the scmi sustained frequency patch is missing)"
fi

echo "== backlight =="
mb=$(cat /sys/class/backlight/*/max_brightness 2>/dev/null | sort -n | tail -1)
(( ${mb:-0} > 0 )) && good "max_brightness $mb" || bad "no usable backlight (max_brightness ${mb:-none})"

echo "== touchscreen =="
grep -q '29BD:1103' /proc/bus/input/devices 2>/dev/null \
    && good "hid-over-i2c 29BD:1103 present" || bad "touchscreen not present (dt still says 0x10?)"

echo "== gpu =="
z=$(journalctl -k -b --no-pager 2>/dev/null | grep -cE 'zap_shader_load_mdt|gpu hw init failed')
(( z == 0 )) && good "no zap shader or gpu init errors this boot" || bad "$z gpu errors this boot"
if r=$(glxinfo -B 2>/dev/null | grep -E 'Device:|Accelerated:' | tr -s ' ') && [[ -n $r ]]; then
    echo "$r" | sed 's/^/    /'
    grep -q 'Accelerated: yes' <<<"$r" && good "hardware accelerated" || bad "software rendering"
else
    skip "glxinfo needs a desktop session"
fi

echo "== video decode =="
iris=$(v4l2-ctl --list-devices 2>/dev/null | awk '/^[^\t]/{blk=$0} /^\t/ && blk ~ /Iris/{print}' | grep -o '/dev/video[0-9]*' | tr '\n' ' ')
if [[ -n $iris ]]; then
    good "iris decoder and encoder: $iris"
elif ls /dev/video* >/dev/null 2>&1; then
    good "$(ls /dev/video* | tr '\n' ' ')"
else
    e=$(journalctl -k -b --no-pager 2>/dev/null | grep -i 'qcom-iris' | tail -1)
    bad "no /dev/video*${e:+ ($e)}"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
