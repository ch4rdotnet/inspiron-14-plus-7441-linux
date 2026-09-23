#!/usr/bin/env bash
# install the pipewire drop-ins that fix the muffled speakers
#
#   sudo install-audio-config.sh          install the upmix and crossover drop-ins
#   sudo install-audio-config.sh --undo   remove them
#
# the tweeters sit on the rear channels and pipewire's default stereo upmix
# leaves them silent, see docs/audio.md. restart the audio stack as your user
# afterwards, the script prints the command.

set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_root

UPMIX=51-tweeter-upmix.conf
XOVER=52-speaker-crossover.conf
# two copies of the upmix because pulse clients (firefox) don't read client.conf
UPMIX_DIRS=(/etc/pipewire/client.conf.d /etc/pipewire/pipewire-pulse.conf.d)
XOVER_DIR=/etc/pipewire/pipewire.conf.d

case ${1:-} in
    --undo)
        for d in "${UPMIX_DIRS[@]}"; do rm -f "$d/$UPMIX"; done
        rm -f "$XOVER_DIR/$XOVER"
        ok "removed the drop-ins" ;;
    "")
        for d in "${UPMIX_DIRS[@]}"; do
            install -Dm 0644 "$ROOT/config/pipewire/$UPMIX" "$d/$UPMIX"
        done
        install -Dm 0644 "$ROOT/config/pipewire/$XOVER" "$XOVER_DIR/$XOVER"
        ok "speaker upmix and crossover installed" ;;
    *) die "unknown argument: $1" ;;
esac

echo
echo "restart the audio stack as $(real_user) (not root):"
echo "    systemctl --user restart pipewire pipewire-pulse wireplumber"
