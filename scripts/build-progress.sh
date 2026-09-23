#!/usr/bin/env bash
# progress of a kernel build started by build-kernel.sh
#
#   build-progress.sh       one snapshot
#   build-progress.sh -w    refresh every 30s until the build ends

[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"
kb=$BUILD_DIR
tree=$(ls -d "$kb"/rpmbuild/BUILD/kernel-*/kernel-*/linux-*.aarch64 2>/dev/null | head -1)

snapshot() {
    if ! pgrep -f 'rpmbuild.*kernel.spec' >/dev/null; then
        echo "build is not running"
        if find "$kb/rpmbuild/RPMS" -name 'kernel-core-*.rpm' 2>/dev/null | grep -q .; then
            echo "  rpms present:"; find "$kb/rpmbuild/RPMS" -name '*.rpm' | sed 's/^/    /'
        else
            echo "  no rpms, last errors from build.log:"
            grep -iE '^error|Error [0-9]|failed' "$kb/build.log" 2>/dev/null | tail -5 | sed 's/^/    /'
        fi
        return 1
    fi

    # the spec logs "kernel.spec:NNNN: <step>" markers, far better than guessing from the make target
    local phase; phase=$(grep -oE 'kernel\.spec:[0-9]+: .*' "$kb/build.log" 2>/dev/null | tail -1 | cut -d' ' -f2-)
    grep -q '^Processing files:' "$kb/build.log" 2>/dev/null \
        && phase="packaging rpms ($(grep -c '^Processing files:' "$kb/build.log") done)"

    # elapsed from the process, build.log is reused across runs
    local bpid elapsed; bpid=$(pgrep -f 'rpmbuild.*kernel.spec' | head -1)
    elapsed=$(ps -o etimes= -p "$bpid" 2>/dev/null | tr -d ' '); elapsed=${elapsed:-0}

    local o ko cc hot target pct=""
    o=$(find "$tree" -name '*.o' 2>/dev/null | wc -l)
    ko=$(find "$tree" -name '*.ko' 2>/dev/null | wc -l)
    cc=$(pgrep -c cc1 2>/dev/null || echo 0)
    hot=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -rn | head -1)
    # the running kernel shares the config, so its module count is the target
    target=$(find "/lib/modules/$(uname -r)" -name '*.ko*' 2>/dev/null | wc -l)
    (( target > 0 && ko > 0 )) && pct=$(awk -v a="$ko" -v b="$target" 'BEGIN{printf " (%.0f%%)", (a>b?b:a)*100/b}')

    printf '%s  elapsed %dm%02ds\n' "$(date +%H:%M:%S)" $((elapsed / 60)) $((elapsed % 60))
    printf '   step      %s\n' "${phase:-?}"
    printf '   objects   %-7s modules %s/%s%s   compilers %s   load %s   hottest %s c\n' \
        "$o" "$ko" "$target" "$pct" "$cc" "$(cut -d' ' -f1 /proc/loadavg)" "$(( ${hot:-0} / 1000 ))"
    command -v ccache >/dev/null && printf '   ccache    %s\n' \
        "$(ccache -s 2>/dev/null | grep -iE '^ *(hits|misses)' | tr -s ' \n' ' ')"
    printf '   last      %s\n' "$(tail -1 "$kb/build.log" 2>/dev/null | cut -c1-100)"
}

if [[ ${1:-} == -w ]]; then
    prev=0
    while snapshot; do
        o=$(find "$tree" -name '*.o' 2>/dev/null | wc -l)
        (( prev > 0 )) && printf '   rate      %+d objects in 30s\n' $((o - prev))
        prev=$o; echo; sleep 30
    done
else
    snapshot
fi
