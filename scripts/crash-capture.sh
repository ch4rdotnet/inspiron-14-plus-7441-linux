#!/usr/bin/env bash
# make the next hard hang leave evidence behind
#
#   sudo crash-capture.sh                       1s journal sync only, no behaviour change
#   sudo crash-capture.sh --netconsole HOST     also stream kmsg over udp to HOST:6666
#   sudo crash-capture.sh --panic               also panic and reboot on a lockup
#   sudo crash-capture.sh --pm-debug            also log every device's suspend and resume callback
#   sudo crash-capture.sh --undo                revert everything
#
# journald's SyncIntervalSec defaults to 5 minutes with a persistent journal, so
# kernel messages sit in memory that long and a hard hang throws away exactly
# the window that matters. there is no pstore or ramoops on this platform
# either. netconsole is the only thing that survives a truly hard hang.
# --pm-debug is for the hang at suspend entry (docs/hangs.md), it turns on
# pm_debug_messages so the last device to suspend before the freeze is named.

set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_root

JCONF=/etc/systemd/journald.conf.d/99-crash-capture.conf
SCONF=/etc/sysctl.d/99-crash-capture.conf
NCONF=/etc/modprobe.d/99-netconsole.conf
NMOD=/etc/modules-load.d/99-netconsole.conf
TCONF=/etc/tmpfiles.d/99-crash-capture.conf

if [[ ${1:-} == --undo ]]; then
    rm -f "$JCONF" "$SCONF" "$NCONF" "$NMOD" "$TCONF"
    echo 0 > /sys/power/pm_debug_messages 2>/dev/null || true
    systemctl restart systemd-journald
    ok "reverted (sysctl values persist until reboot)"
    exit 0
fi

want_panic=0; want_pm=0; target=""
while (( $# )); do
    case $1 in
        --panic) want_panic=1; shift ;;
        --pm-debug) want_pm=1; shift ;;
        --netconsole) target=${2:?need a host}; shift 2 ;;
        -h|--help) usage ;;
        *) die "unknown argument: $1" ;;
    esac
done

install -d "$(dirname "$JCONF")"
printf '%s\n' '[Journal]' '# default is 5m, which loses the whole crash window on a hard hang' 'SyncIntervalSec=1s' > "$JCONF"
systemctl restart systemd-journald
ok "journald SyncIntervalSec=1s"

if (( want_panic )); then
    printf '%s\n' 'kernel.panic = 20' 'kernel.panic_on_oops = 1' \
                  'kernel.softlockup_panic = 1' 'kernel.hardlockup_panic = 1' > "$SCONF"
    sysctl -q -p "$SCONF"
    ok "panic on oops and lockups, reboot after 20s"
fi

if (( want_pm )); then
    # /sys/power isn't sysctl, a tmpfiles line is how to set it at every boot
    echo 'w /sys/power/pm_debug_messages - - - - 1' > "$TCONF"
    echo 1 > /sys/power/pm_debug_messages
    ok "pm_debug_messages on, each suspend logs every device callback and its timing"
fi

if [[ -n $target ]]; then
    # the interface that actually routes to the target, and its mac
    read -r dev src <<<"$(ip -o route get "$target" | awk '{for(i=1;i<=NF;i++){if($i=="dev")d=$(i+1); if($i=="src")s=$(i+1)} print d, s}')"
    [[ -n $dev && -n $src ]] || die "no route to $target"
    ping -c1 -W2 "$target" >/dev/null 2>&1 || true
    mac=$(ip neigh show "$target" dev "$dev" | awk '{print $5; exit}')
    [[ -n $mac ]] || die "could not resolve the mac for $target"
    echo "options netconsole netconsole=6665@$src/$dev,6666@$target/$mac" > "$NCONF"
    echo netconsole > "$NMOD"
    modprobe -r netconsole 2>/dev/null || true
    modprobe netconsole
    ok "netconsole $src/$dev -> $target:6666 ($mac)"
    echo "  on $target:  nc -u -l 6666 | tee kmsg.log"
    echo "  the target mac is pinned, re-run this if that host's address changes"
fi

echo
echo "after the next hang and reboot:  journalctl -k -b -1 --no-pager | tail -60"
