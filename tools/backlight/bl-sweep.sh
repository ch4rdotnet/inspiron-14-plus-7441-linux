#!/usr/bin/env bash
# step the backlight through levels and dump the pwm state at each, watching for the flash
#
#   sudo bl-sweep.sh              0..100 in steps of 5
#   sudo bl-sweep.sh 10 40 1      10..40 by 1
#   sudo bl-sweep.sh --restore    put brightness back
#
# for the unresolved "flashes bright before settling" glitch. the leading
# theory is the lpg duty spanning two registers and latching half written for
# one period, the brightness-levels table also has segment boundaries every 20.
# note which levels flash. see docs/remaining.md

set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../../scripts/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_root
B=/sys/class/backlight/backlight
[[ -d $B ]] || die "no pwm backlight at $B (patch 0002 not in this kernel?)"
STATE=/tmp/bl-sweep.saved

if [[ ${1:-} == --restore ]]; then
    [[ -f $STATE ]] && { cat "$STATE" > "$B/brightness"; ok "restored to $(cat "$STATE")"; } || warn "no saved level"
    exit 0
fi
cat "$B/brightness" > "$STATE"
from=${1:-0}; to=${2:-100}; step=${3:-5}

pwmstate() {
    awk '/pwmchip0/{c=1} c && /duty:/{print; exit}' /sys/kernel/debug/pwm 2>/dev/null | tr -s ' ' | sed 's/^ *//'
}

echo "watch the screen, note any level where it flashes bright before settling"
echo "saved level $(cat "$STATE"), restore with: sudo $0 --restore"
echo
printf '%-7s %-10s %s\n' level segment "pwm state"
for l in $(seq "$from" "$step" "$to"); do
    echo "$l" > "$B/brightness" 2>/dev/null
    sleep 0.7
    b=""; (( l % 20 == 0 && l != 0 )) && b=" boundary"
    printf '%-7s %-10s %s\n' "$l" "seg$(( l / 20 ))$b" "$(pwmstate)"
done
echo
echo "restore with: sudo $0 --restore"
