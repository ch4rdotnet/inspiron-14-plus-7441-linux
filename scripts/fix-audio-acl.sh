#!/usr/bin/env bash
# give the logged in user the /dev/snd acl when the card appeared during gdm startup
#
#   sudo fix-audio-acl.sh              grant now, for this boot
#   sudo fix-audio-acl.sh --permanent  also add the user to the audio group
#   sudo fix-audio-acl.sh --undo       remove from the audio group
#
# the card only appears once the adsp has booted, which can land mid way through
# gdm starting. logind's uaccess rule hands the acl to whoever is the active
# session at that instant (gdm-greeter) and doesn't re-apply it when the real
# user logs in a second later. pipewire then has no local sinks while
# /proc/asound/cards shows the card. seen once, has not recurred.

set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_root
u=$(real_user)
[[ $u != root ]] || die "run with sudo from your user session"

case ${1:-} in
    --undo)
        gpasswd -d "$u" audio 2>/dev/null || true
        ok "removed $u from the audio group, log out and back in"; exit 0 ;;
    -h|--help) usage ;;
esac

echo "acl before:"; getfacl -p /dev/snd/controlC0 2>/dev/null | grep '^user' | sed 's/^/  /'
setfacl -m "u:$u:rw" /dev/snd/* 2>/dev/null || true
ok "$u has rw on /dev/snd/* for this boot"

if [[ ${1:-} == --permanent ]]; then
    usermod -aG audio "$u"
    ok "$u added to the audio group, takes effect at next login"
fi

echo
echo "now restart the audio stack as $u:"
echo "    systemctl --user restart wireplumber pipewire pipewire-pulse && wpctl status"
