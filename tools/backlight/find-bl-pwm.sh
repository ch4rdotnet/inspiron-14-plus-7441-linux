#!/usr/bin/env bash
# find which pin drives the backlight pwm by reading what uefi left configured, read only
#
#   sudo find-bl-pwm.sh
#
# two things that went wrong the first time: filtering out unclaimed pins,
# which is exactly where a uefi configured pin with no linux driver shows up,
# and reading pinctrl's generic "pins" file, which shows nothing useful for
# qualcomm pmic gpios. /sys/kernel/debug/gpio is the one that reports the real
# hardware function (func3 on pmk8550 gpio5 was the answer).

set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../../scripts/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_root

echo "which pmic is which (spmi address -> compatible)"
for d in /proc/device-tree/soc@0/arbiter@*/spmi@*/pmic@*; do
    [[ -d $d ]] || continue
    printf '  %-12s %s\n' "$(basename "$d")" "$(tr '\0' ' ' < "$d/compatible" 2>/dev/null)"
done

echo
echo "every gpiochip with hardware function, pins in a special function marked ***"
sed -n '/^gpiochip/,$p' /sys/kernel/debug/gpio 2>/dev/null \
  | awk '/^gpiochip/{print "\n  " $0; next} /func[1-9]|pwm|PWM/{print "  *** " $0; next} {print "      " $0}' \
  | grep -vE '^      $' | head -150

echo
echo "pins not in func0"
grep -nE 'func[1-9]' /sys/kernel/debug/gpio 2>/dev/null | sed 's/^/  /' || echo "  none"

echo
echo "pwm and lpg nodes in the dt"
while IFS= read -r n; do
    printf '  %s\n' "${n#/proc/device-tree}"
    printf '     compatible: %s\n' "$(tr '\0' ' ' < "$n/compatible" 2>/dev/null)"
    printf '     status:     %s\n' "$(tr -d '\0' < "$n/status" 2>/dev/null || echo '(none, so okay)')"
done < <(find /proc/device-tree -type d \( -name pwm -o -name 'pwm@*' -o -name 'lpg*' \) 2>/dev/null)
