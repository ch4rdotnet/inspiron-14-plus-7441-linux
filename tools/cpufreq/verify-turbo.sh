#!/usr/bin/env bash
# confirm the scmi turbo diagnosis on a stock kernel before building one
#
#   sudo verify-turbo.sh
#
# probes dev_pm_opp_add_dynamic() and reads the turbo flag straight out of the
# struct dev_pm_opp_data the scmi perf layer passes in (offset 0 turbo u8,
# 4 level u32, 8 freq u64, pointer in x1 on arm64). expect turbo=0 for every
# cpu0 opp and turbo=1 for every cpu4 and cpu8 opp. needs scmi-cpufreq as a
# module, so a stock fedora kernel, not one built with kernel-local.

set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../../scripts/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_root

T=/sys/kernel/tracing; [[ -d $T ]] || T=/sys/kernel/debug/tracing
[[ -w $T/kprobe_events ]] || die "cannot write $T/kprobe_events"
modinfo scmi-cpufreq >/dev/null 2>&1 || die "scmi-cpufreq is built in on this kernel, nothing to reload"

cleanup() {
    echo 0 > "$T/tracing_on" 2>/dev/null
    echo 0 > "$T/events/kprobes/enable" 2>/dev/null
    : > "$T/kprobe_events" 2>/dev/null
}
trap cleanup EXIT

echo 0 > "$T/tracing_on"; : > "$T/trace"; : > "$T/kprobe_events"
echo 'p:oppadd dev_pm_opp_add_dynamic turbo=+0(%x1):u8 level=+4(%x1):u32 freq=+8(%x1):u64' >> "$T/kprobe_events" \
    || die "failed to add the probe, is dev_pm_opp_add_dynamic inlined in this build"
echo 'p:online cpufreq_policy_online cpu=$arg2:u32' >> "$T/kprobe_events"
echo 1 > "$T/events/kprobes/enable"
echo 1 > "$T/tracing_on"

modprobe -r scmi-cpufreq 2>/dev/null || true
sleep 1
modprobe scmi-cpufreq
sleep 3
echo 0 > "$T/tracing_on"

echo "opps added, per policy"
awk '
  /online:/ { for (i=1;i<=NF;i++) if ($i ~ /^cpu=/) { split($i,a,"="); cur=a[2] }
              printf "\n  policy for cpu%s\n", cur; next }
  /oppadd:/ { t=""; l=""; f=""
              for (i=1;i<=NF;i++) {
                if ($i ~ /^turbo=/) { split($i,a,"="); t=a[2] }
                if ($i ~ /^level=/) { split($i,a,"="); l=a[2] }
                if ($i ~ /^freq=/)  { split($i,a,"="); f=a[2] }
              }
              printf "    turbo=%s  level=%-5s  freq=%s\n", t, l, f
              if (t+0 == 1) turbo[cur]++; else normal[cur]++ }
  END { printf "\nsummary\n"
        for (c in turbo)  printf "  cpu%-3s turbo opps: %d\n", c, turbo[c]
        for (c in normal) printf "  cpu%-3s normal opps: %d\n", c, normal[c] }
' "$T/trace"
