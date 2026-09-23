#!/usr/bin/env bash
# live view of cluster frequencies, gpu clock, temperatures and system power
#
#   cpumon.sh [interval]    ctrl-c to stop
#
# frequency is per perf domain, not per core (ncc0 = cpu0-3, ncc1 = cpu4-6,
# ncc2 = cpu8-10), there is no per core readout on this soc. power is whole
# system from the battery gauge, there is no per rail telemetry.

[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
set -uo pipefail
INT=${1:-1}

bh=""
for h in /sys/class/hwmon/*/; do
    [[ $(cat "$h/name" 2>/dev/null) == qcom_battmgr_bat ]] && { bh=$h; break; }
done

maxtemp() {
    local m=0 t
    for z in /sys/class/thermal/thermal_zone*/; do
        case $(cat "$z/type" 2>/dev/null) in
            $1*) t=$(cat "$z/temp" 2>/dev/null); (( ${t:-0} > m )) && m=$t ;;
        esac
    done
    echo $(( m / 1000 ))
}

printf '%-9s | %-32s | %-9s | %-20s | %s\n' time "cluster mhz (ncc0/ncc1/ncc2)" "gpu mhz" "temp c c0/c1/c2/gpu" power
while :; do
    line=""
    for p in /sys/devices/system/cpu/cpufreq/policy*/; do
        [[ -e $p/scaling_cur_freq ]] || continue
        line+=$(printf '%5d ' $(( $(cat "$p/scaling_cur_freq") / 1000 )))
    done
    gov=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)
    gpu=$(( $(cat /sys/class/devfreq/3d00000.gpu/cur_freq 2>/dev/null || echo 0) / 1000000 ))
    st=$(grep POWER_SUPPLY_STATUS /sys/class/power_supply/qcom-battmgr-bat/uevent 2>/dev/null | cut -d= -f2)
    pw=$(cat "$bh/power1_input" 2>/dev/null || echo 0)
    printf '%-9s | %-22s %-9s | %6d    | %3s %3s %3s %3s      | %5.1f W %s\n' \
        "$(date +%H:%M:%S)" "$line" "($gov)" "$gpu" \
        "$(maxtemp cpu0)" "$(maxtemp cpu1)" "$(maxtemp cpu2)" "$(maxtemp gpuss)" \
        "$(awk -v v="$pw" 'BEGIN{print v/1e6}')" "$st"
    sleep "$INT"
done
