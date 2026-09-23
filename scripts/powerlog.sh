#!/usr/bin/env bash
# sample battery draw, hottest sensor and gpu clock over time. run unplugged.
#
#   powerlog.sh [interval] [duration]     defaults 10s for 600s, ctrl-c prints the summary
#
# two figures are reported because they disagree over short runs. POWER_NOW is
# the gauge's instantaneous reading (negative while discharging). the ENERGY_NOW
# delta is integrated over the run but the gauge quantises it in ~10 mwh steps,
# so trust it over 10 minutes or more. while charging the two agreed within 1%,
# so the gauge itself is sound.

[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
set -uo pipefail
INT=${1:-10}; DUR=${2:-600}
B=/sys/class/power_supply/qcom-battmgr-bat/uevent
[[ -r $B ]] || { echo "no battery data at $B" >&2; exit 1; }

f() { grep "POWER_SUPPLY_$1=" "$B" 2>/dev/null | cut -d= -f2; }
hot() { cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -rn | head -1; }
gpufreq() { cat /sys/class/devfreq/3d00000.gpu/cur_freq 2>/dev/null; }

samples=(); start=$(date +%s)

summary() {
    echo
    if (( ${#samples[@]} )); then
        # samples more than 3x the median are dropped, the gauge spikes on wake
        printf '%s\n' "${samples[@]}" | awk '
            { v = $1 < 0 ? -$1 : $1; a[NR] = v }
            END {
                n = NR
                for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++)
                    if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
                med = a[int((n + 1) / 2)]; s = 0; c = 0; mn = ""; mx = 0
                for (i = 1; i <= n; i++) if (med == 0 || a[i] <= med * 3) {
                    s += a[i]; c++
                    if (mn == "" || a[i] < mn) mn = a[i]
                    if (a[i] > mx) mx = a[i]
                }
                if (c > 0) printf "  POWER_NOW    avg %.1f W  min %.1f W  max %.1f W  (%d of %d samples)\n", s/c, mn, mx, c, n
            }'
    fi
    local e_end dt; e_end=$(f ENERGY_NOW); dt=$(( $(date +%s) - start ))
    awk -v a="${e_start:-0}" -v b="${e_end:-0}" -v t="$dt" 'BEGIN {
        d = (a - b) / 1e6
        if (t > 0 && d > 0) printf "  ENERGY_NOW   %.3f Wh over %ds -> %.1f W average\n", d, t, d * 3600 / t
        else print "  ENERGY_NOW   not usable (charging, or the gauge did not move)"
    }'
    echo
    echo "  reference for this class of laptop: idle ~4-8 W, light use ~8-15 W, heavy gpu 20-35 W"
    exit 0
}
trap summary INT TERM

[[ $(f STATUS) == Discharging ]] || echo "note: not discharging (STATUS=$(f STATUS)), unplug for a real reading"
e_start=$(f ENERGY_NOW)
printf '%-9s %8s %9s %9s %9s\n' time power energy maxtemp gpufreq
end=$(( start + DUR ))
while (( $(date +%s) < end )); do
    p=$(f POWER_NOW); e=$(f ENERGY_NOW); t=$(hot); g=$(gpufreq)
    [[ -n $p ]] && samples+=( "$(awk -v x="$p" 'BEGIN{print x/1e6}')" )
    awk -v ts="$(date +%H:%M:%S)" -v p="${p:-0}" -v e="${e:-0}" -v t="${t:-0}" -v g="${g:-0}" \
        'BEGIN{ printf "%-9s %7.1fW %8.2fWh %8.1fC %6dMHz\n", ts, (p<0?-p:p)/1e6, e/1e6, t/1e3, g/1e6 }'
    sleep "$INT"
done
summary
