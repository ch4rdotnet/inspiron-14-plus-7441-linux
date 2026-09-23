#!/usr/bin/env bash
# configure the camss pipeline and try to grab frames from the ov02e10
#
#   capture-camera.sh [frames] [csiphy]     default 5 frames through csiphy0
#
# writes frame.raw (packed mipi raw10) and frame.png in the current directory.
# as of docs/camera.md no frames arrive, the sensor streams but the csiphy
# never locks, so expect "got 0 bytes". the second argument re-points the
# downstream links at another csiphy, the sensor's own link is immutable.

set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../../scripts/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_cmd media-ctl v4l-utils

FRAMES=${1:-5}
PHY=${2:-0}
MEDIA=/dev/media0
W=1928; H=1088; FMT=SGRBG10_1X10

[[ -e $MEDIA ]] || die "$MEDIA missing, did camss probe"
graph=$(media-ctl -d $MEDIA -p 2>/dev/null)
grep -q ov02e10 <<<"$graph" || die "ov02e10 is not in the media graph, check dmesg"
sensor=$(grep -oE 'ov02e10 [0-9]+-[0-9a-f]+' <<<"$graph" | head -1)

say "pipeline: $sensor -> csiphy$PHY -> csid$PHY -> vfe0_rdi0"
media-ctl -d $MEDIA -l "\"msm_csiphy$PHY\":1 -> \"msm_csid$PHY\":0 [1]" 2>/dev/null
media-ctl -d $MEDIA -l "\"msm_csid$PHY\":1 -> \"msm_vfe0_rdi0\":0 [1]" 2>/dev/null
for pad in "\"$sensor\":0" "\"msm_csiphy$PHY\":0" "\"msm_csiphy$PHY\":1" \
           "\"msm_csid$PHY\":0" "\"msm_csid$PHY\":1" "\"msm_vfe0_rdi0\":0" "\"msm_vfe0_rdi0\":1"; do
    media-ctl -d $MEDIA -V "$pad [fmt:$FMT/${W}x${H}]" 2>/dev/null
done

# the video node fed by vfe0_rdi0, rather than assuming a number
video=$(awk '/entity .*msm_vfe0_video0/,/pad0/' <<<"$graph" | grep -o '/dev/video[0-9]*' | head -1)
video=${video:-/dev/video2}
say "capturing $FRAMES frames from $video"
v4l2-ctl -d "$video" --set-fmt-video=width=$W,height=$H,pixelformat=pgAA >/dev/null 2>&1
rm -f frame.raw
timeout 25 v4l2-ctl -d "$video" --stream-mmap --stream-count="$FRAMES" --stream-to=frame.raw 2>&1 | tail -3

sz=$(stat -c %s frame.raw 2>/dev/null || echo 0)
echo "got $sz bytes"
if (( sz == 0 )); then
    err "no frames, recent kernel messages:"
    sudo dmesg | tail -15 >&2
    exit 1
fi
python3 "$ROOT/tools/camera/raw10-to-png.py" frame.raw frame.png $W $H && ok "wrote frame.png"
