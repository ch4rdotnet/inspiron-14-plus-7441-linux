#!/usr/bin/env bash
# print every brightness change as it happens, to see what is writing them
#
#   watch-brightness.sh          (sudo to also see the pwm duty)
#
# gsd-power sets brightness to idle-brightness (default 30) on idle, so a level
# below that goes brighter first, which explains a flash on idle but not the
# flash on a single slider click. see docs/remaining.md

[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
B=/sys/class/backlight/backlight
[[ -d $B ]] || { echo "no pwm backlight at $B" >&2; exit 1; }
echo "idle-brightness = $(gsettings get org.gnome.settings-daemon.plugins.power idle-brightness 2>/dev/null)"
echo "idle-dim        = $(gsettings get org.gnome.settings-daemon.plugins.power idle-dim 2>/dev/null)"
echo "max_brightness  = $(cat $B/max_brightness)"
echo
printf '%-12s %6s %8s  %s\n' time level delta pwm
prev=""
while :; do
    cur=$(cat "$B/brightness" 2>/dev/null)
    if [[ $cur != "$prev" ]]; then
        d=""; [[ -n $prev ]] && d=$(( cur - prev ))
        pwm=""; [[ $EUID -eq 0 ]] && pwm=$(grep -A4 pwmchip0 /sys/kernel/debug/pwm 2>/dev/null | grep -oE 'duty: [0-9]+ ns' | head -1)
        printf '%-12s %6s %8s  %s\n' "$(date +%H:%M:%S.%2N)" "$cur" "${d:+$( (( d > 0 )) && echo "+$d" || echo "$d")}" "$pwm"
        prev=$cur
    fi
    sleep 0.1
done
