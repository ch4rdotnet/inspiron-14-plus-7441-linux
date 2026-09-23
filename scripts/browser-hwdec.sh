#!/usr/bin/env bash
# turn on chromium's v4l2 decode path for the installed chromium family browsers
#
#   browser-hwdec.sh          write ~/.local/share/applications overrides with the flags
#   browser-hwdec.sh --undo   remove the overrides
#
# chromium has two hardware decode paths on linux. vaapi is a dead end here (no
# vaapi driver for this hardware), but V4L2VideoDecoder talks to /dev/video0
# directly. it's a chromeos path and off by default on desktop linux, it works.
# firefox only does vaapi so it cannot be fixed this way.
# check chrome://gpu says "Video Decode: Hardware accelerated". 10 bit content
# still falls back to software, the decoder is 8 bit only.

set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"
need_user

FLAGS='--enable-features=V4L2VideoDecoder,AcceleratedVideoDecodeLinuxGL --ignore-gpu-blocklist --enable-accelerated-video-decode'
APPS=(helium chromium chromium-browser chrome google-chrome brave-browser)
dest=~/.local/share/applications

[[ ${1:-} == -h || ${1:-} == --help ]] && usage

found=0
for app in "${APPS[@]}"; do
    src=/usr/share/applications/$app.desktop
    [[ -f $src ]] || continue
    found=1
    if [[ ${1:-} == --undo ]]; then
        rm -f "$dest/$app.desktop"; ok "removed override for $app"; continue
    fi
    mkdir -p "$dest"
    # every Exec= line, so the new window and incognito actions get the flags too
    sed "s|^Exec=$app|Exec=$app $FLAGS|" "$src" > "$dest/$app.desktop"
    ok "flags added for $app"
done
(( found )) || warn "no chromium family browser found"
