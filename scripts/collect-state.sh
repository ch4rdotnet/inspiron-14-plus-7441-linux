#!/usr/bin/env bash
# snapshot the hardware and driver state into one file, for diffing before and after
#
#   collect-state.sh [output]    default state-YYYY-MM-DD.txt in the current directory
#
# the output includes mac addresses and the battery serial, don't publish it as is

[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
set -uo pipefail
out=${1:-state-$(date +%F).txt}
exec > >(tee "$out") 2>&1

sec() { printf '\n\n===== %s =====\n' "$1"; }

sec identity
cat /sys/class/dmi/id/{sys_vendor,product_name,product_sku,board_name,bios_version,bios_date} 2>/dev/null
tr -d '\0' < /proc/device-tree/model; echo
tr '\0' ' ' < /proc/device-tree/compatible; echo
cat /sys/devices/soc0/soc_id /sys/devices/soc0/revision 2>/dev/null | paste -sd' '

sec kernel
uname -a; head -3 /etc/os-release; cat /proc/cmdline

sec cpu
lscpu
echo "online: $(cat /sys/devices/system/cpu/online)"

sec "cpufreq / cpuidle"
for p in /sys/devices/system/cpu/cpufreq/policy*/; do
    [[ -e $p/affected_cpus ]] || continue
    echo "$(basename "$p"): cpus=[$(cat "$p/affected_cpus")] driver=$(cat "$p/scaling_driver") gov=$(cat "$p/scaling_governor") cur=$(cat "$p/scaling_cur_freq") boost=[$(cat "$p/scaling_boost_frequencies" 2>/dev/null)]"
done
for s in /sys/devices/system/cpu/cpu0/cpuidle/state*/; do
    echo "$(cat "$s/name" 2>/dev/null) - $(cat "$s/desc" 2>/dev/null)"; done

sec remoteproc
for d in /sys/class/remoteproc/*/; do
    echo "$d name=$(cat "$d/name" 2>/dev/null) state=$(cat "$d/state" 2>/dev/null) fw=$(cat "$d/firmware" 2>/dev/null)"
done

sec "firmware paths the dt asks for"
for n in soc@0/gpu@3d00000/zap-shader soc@0/video-codec@aa00000 \
         soc@0/remoteproc@6800000 soc@0/remoteproc@32300000; do
    f=/proc/device-tree/$n/firmware-name
    # several nul separated strings (image plus dtb)
    [[ -f $f ]] && { printf '%-36s ' "$n"; tr '\0' ' ' < "$f"; echo; }
done

sec "firmware on disk"
ls -la /lib/firmware/qcom/x1e80100/dell/inspiron-14-plus-7441/ 2>&1
echo "--- updates overlay ---"
ls -la /lib/firmware/updates/qcom/x1e80100/dell/inspiron-14-plus-7441/ 2>&1

sec gpu
ls /sys/class/drm/
glxinfo -B 2>&1 | head -12

sec backlight
for b in /sys/class/backlight/*/; do echo "$(basename "$b"): $(cat "$b/brightness")/$(cat "$b/max_brightness")"; done

sec audio
cat /proc/asound/cards
wpctl status 2>&1 | sed -n '/Audio/,/Video/p'

sec video
ls -l /dev/video* 2>&1
v4l2-ctl --list-devices 2>/dev/null

sec power
for d in /sys/class/power_supply/*/; do echo "--- $d"; cat "$d/uevent" 2>/dev/null; done

sec thermal
echo "$(ls -d /sys/class/thermal/thermal_zone* | wc -l) zones, cooling devices:"
for c in /sys/class/thermal/cooling_device*/; do echo "  $(cat "$c/type")"; done

sec "pci / usb / net"
lspci -nn; echo; lsusb; echo; ip -br link

sec input
grep -E '^N:|^H:' /proc/bus/input/devices | paste - -

sec "platform devices with no driver"
for d in /sys/bus/platform/devices/*/; do
    [[ -e $d/driver || ! -e $d/of_node ]] && continue
    comp=$(tr '\0' ' ' < "$d/of_node/compatible" 2>/dev/null); [[ -n $comp ]] || continue
    printf '  %-34s %s\n' "$(basename "$d")" "$comp"
done | sort

sec "kernel errors this boot"
journalctl -k -b | grep -iE 'fail|error|firmware|timeout|denied' | grep -v ConditionPath | head -120
