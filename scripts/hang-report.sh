#!/usr/bin/env bash
# find the boots that ended in a hang and show what the journal has for each
#
#   hang-report.sh [N]      look at the last N boots (default 10)
#
# a boot that ended cleanly has a shutdown target in its journal, one that
# didn't just stops. for each of those this prints the kernel, how long it ran,
# every suspend and resume, the last kernel line, and the last few lines that
# aren't background noise. remember journald only syncs every 5 minutes unless
# crash-capture.sh is on, so the real hang is up to 5 minutes after the last
# line. see docs/hangs.md

set -u
[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
n=${1:-10}
NOISE='irqbalance|binder|audit\[|audit:|wpa_supplicant|CTRL-EVENT|set-hw-addr|supplicant interface|callbacks suppressed'

mapfile -t boots < <(journalctl --list-boots --no-pager -o json 2>/dev/null \
    | python3 -c 'import sys,json
for b in json.load(sys.stdin): print(b["index"], b["boot_id"])' 2>/dev/null | tail -n "$n")
(( ${#boots[@]} )) || { echo "no boots listed, is the journal persistent"; exit 1; }

for entry in "${boots[@]}"; do
    idx=${entry%% *}
    (( idx == 0 )) && continue
    j() { journalctl -b "$idx" --no-pager -o short-iso "$@" 2>/dev/null; }
    # pid 1 reaching shutdown.target, or systemd-shutdown taking over. a user
    # session's shutdown.target and the initrd journald's "Journal stopped"
    # both look similar and mean nothing
    if j | grep -qE 'systemd\[1\]: Reached target (shutdown|reboot|poweroff)\.target|systemd-shutdown\[1\]:'; then
        continue
    fi
    first=$(j -k | grep -m1 -E 'Linux version' | grep -oE 'version [0-9][^ ]+' | head -1 | cut -d' ' -f2)
    start=$(j | grep -m1 -E 'systemd\[1\]: Startup finished|Started .*(gdm|display-manager)' | cut -c1-19)
    last=$(j | tail -1 | cut -c1-19)
    printf '\n%s boot %s, kernel %s, hung\n' "$(printf '=%.0s' {1..8})" "$idx" "${first:-?}"
    printf '  up from    %s\n  journal to %s  (the hang is between this and +5 min)\n' "${start:-?}" "$last"
    printf '  suspend cycles:\n'
    j -k | grep -E 'PM: suspend (entry|exit)' | sed 's/ fedora kernel:/ /' | cut -c1-60 | sed 's/^/    /' || true
    printf '  last kernel line:\n    %s\n' "$(j -k | tail -1 | cut -c1-150)"
    printf '  last lines (noise removed):\n'
    j | grep -vE "$NOISE" | tail -8 | cut -c1-150 | sed 's/^/    /'
done
echo
echo "kernel errors, all of the above boots:"
for entry in "${boots[@]}"; do
    idx=${entry%% *}; (( idx == 0 )) && continue
    journalctl -b "$idx" -k --no-pager -o short-iso 2>/dev/null \
        | grep -iE 'oops|panic|BUG:|lockup|Call trace|WARNING:|Unable to handle|gpu fault|Internal error' \
        | grep -vE 'drm panic|panic_on_oops' | head -3 | cut -c1-150 | sed "s/^/  [$idx] /"
done
echo "  (nothing above means none were logged)"
