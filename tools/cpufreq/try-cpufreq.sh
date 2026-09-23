#!/usr/bin/env bash
# load scmi-cpufreq by hand on a stock kernel, and the tracing that found the turbo bug
#
#   sudo try-cpufreq.sh              load and report
#   sudo try-cpufreq.sh --persist    also write /etc/modules-load.d so it loads at boot
#   sudo try-cpufreq.sh --undo       unload and remove the modules-load entry
#   sudo try-cpufreq.sh --trace      kretprobes on the policy setup path, per cpu return values
#   sudo try-cpufreq.sh --debug      dynamic_debug across cpufreq/scmi/opp while hotplugging cpu4 and cpu8
#
# a stock fedora kernel has no cpufreq at all, scmi-cpufreq is a module with no
# alias (file2alias has no scmi handler) and scmi devices are only created when
# a driver requests them, so nothing ever loads it. loading it by hand gets
# policy0 only, the other two clusters fail silently, which --trace pins to
# cpufreq_frequency_table_cpuinfo returning -22. see docs/cpufreq.md.
# needs scmi-cpufreq as a module, not the kernel-local build.

set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/../../scripts/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_root
CONF=/etc/modules-load.d/99-scmi-cpufreq.conf
DD=/sys/kernel/debug/dynamic_debug/control
DEBUG_FILES=("file drivers/cpufreq/*" "file drivers/firmware/arm_scmi/*" "file drivers/opp/*" "file drivers/pmdomain/arm/*")

policies() {
    local p any=0
    for p in /sys/devices/system/cpu/cpufreq/policy*/; do
        [[ -e $p/affected_cpus ]] || continue
        echo "  $(basename "$p"): cpus=[$(cat "$p/affected_cpus")] driver=$(cat "$p/scaling_driver") gov=$(cat "$p/scaling_governor") cur=$(cat "$p/scaling_cur_freq") kHz"
        any=1
    done
    (( any )) || echo "  (no policies)"
}

reload() {
    modprobe -r scmi-cpufreq 2>/dev/null || true
    sleep 1
    modprobe scmi-cpufreq
    sleep 3
}

case ${1:-} in
    -h|--help) usage ;;
    --undo)
        rm -f "$CONF"; modprobe -r scmi-cpufreq 2>/dev/null || true
        ok "unloaded, removed $CONF"; exit 0 ;;
    --debug)
        [[ -w $DD ]] || die "cannot write $DD, is debugfs mounted"
        for s in "${DEBUG_FILES[@]}"; do echo "$s +p" > "$DD" 2>/dev/null || true; done
        for c in 4 8; do
            [[ -w /sys/devices/system/cpu/cpu$c/online ]] || continue
            echo; echo "hotplug cpu$c"
            dmesg -C
            echo 0 > "/sys/devices/system/cpu/cpu$c/online"; sleep 1
            echo 1 > "/sys/devices/system/cpu/cpu$c/online"; sleep 3
            dmesg | grep -vE 'qcom-bwmon|adreno 3d00000' | sed 's/^/  /'
        done
        for s in "${DEBUG_FILES[@]}"; do echo "$s -p" > "$DD" 2>/dev/null || true; done
        echo; policies; exit 0 ;;
    --trace)
        # cpufreq_policy_online() has two silent goto out_offline_policy paths after
        # a successful ->init(), validate_and_sort and init_qos (inlined, but the
        # freq_qos_add_request it calls is not), so probe the return values directly
        T=/sys/kernel/tracing; [[ -d $T ]] || T=/sys/kernel/debug/tracing
        [[ -w $T/kprobe_events ]] || die "cannot write $T/kprobe_events"
        cleanup() { echo 0 > "$T/tracing_on"; echo 0 > "$T/events/kprobes/enable"; : > "$T/kprobe_events"; } 2>/dev/null
        trap cleanup EXIT
        echo 0 > "$T/tracing_on"; : > "$T/trace"; : > "$T/kprobe_events"
        for e in 'p:online cpufreq_policy_online cpu=$arg2:u32' \
                 'r:online_ret cpufreq_policy_online ret=$retval:s32' \
                 'r:validate cpufreq_table_validate_and_sort ret=$retval:s32' \
                 'r:opp_table dev_pm_opp_init_cpufreq_table ret=$retval:s32' \
                 'r:ft_cpuinfo cpufreq_frequency_table_cpuinfo ret=$retval:s32' \
                 'r:qos_add freq_qos_add_request ret=$retval:s32'; do
            echo "$e" >> "$T/kprobe_events" 2>/dev/null || warn "probe failed: $e"
        done
        echo 1 > "$T/events/kprobes/enable"; echo 1 > "$T/tracing_on"
        reload
        echo 0 > "$T/tracing_on"
        echo "trace (a non zero ret on validate or ft_cpuinfo for cpu4 and cpu8, zero for cpu0, names it)"
        sed 's/^ *//' "$T/trace" | grep -v '^#' | awk '{ line=""; for (i=4; i<=NF; i++) line = line $i " "; print "  " line }'
        echo; policies; exit 0 ;;
esac

echo "before:"; policies
echo
say "loading scmi-cpufreq"
modprobe scmi-cpufreq
sleep 2
echo "after:"; policies
echo "cooling devices:"
for c in /sys/class/thermal/cooling_device*/; do
    t=$(cat "$c/type" 2>/dev/null); [[ $t == *cpu* ]] && echo "  $t"
done
if [[ ${1:-} == --persist ]]; then
    echo scmi-cpufreq > "$CONF"
    ok "wrote $CONF"
fi
