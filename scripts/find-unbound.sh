#!/usr/bin/env bash
# list device tree nodes that are status=okay but have no driver bound
#
#   find-unbound.sh        (root for the deferred probe list)
#
# the general form of the qcom-iris failure, the dt describes hardware but the
# driver was never built or never probed. good first check for "why doesn't x
# work". on a finished machine only 1dfa000.crypto and the gmu should remain.

[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
echo "platform devices with no driver:"
for d in /sys/bus/platform/devices/*/; do
    [[ -e $d/driver || ! -e $d/of_node ]] && continue
    comp=$(tr '\0' ' ' < "$d/of_node/compatible" 2>/dev/null)
    [[ -n $comp ]] || continue
    printf '  %-34s %s\n' "$(basename "$d")" "$comp"
done | sort
echo
echo "deferred probes still pending:"
sed 's/^/  /' /sys/kernel/debug/devices_deferred 2>/dev/null || echo "  (needs root)"
