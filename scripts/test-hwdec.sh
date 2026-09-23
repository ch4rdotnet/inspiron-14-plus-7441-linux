#!/usr/bin/env bash
# work out whether a video file will hardware decode, and why not
#
#   test-hwdec.sh FILE
#
# the iris decoder takes h264, hevc, vp9 and av1 in and only puts NV12 or Q08C
# out, so 10 bit content can never hardware decode (gstreamer fails caps
# negotiation with not-negotiated -4). check pix_fmt before blaming anything
# else. gstreamer's v4l2 decoders are ranked 257 against 256 for software, so
# they should be picked on their own.

[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
set -uo pipefail
F=${1:?usage: $0 FILE}
[[ -r $F ]] || { echo "cannot read $F" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "need ffprobe (dnf install -y ffmpeg)" >&2; exit 1; }

echo "1. what the file is"
ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,profile,level,width,height,pix_fmt \
    -show_entries format=format_name,duration -of default=noprint_wrappers=1 "$F" | sed 's/^/   /'

pixfmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$F" 2>/dev/null)
case $pixfmt in
    *10le|*10be|*12le|*12be|*p010*)
        echo
        echo "   $pixfmt is more than 8 bit. this decoder only outputs NV12/Q08C, so"
        echo "   hardware decode cannot work for this file. test with 8 bit content." ;;
esac

echo
echo "2. does it decode in software at all (30 frames)"
if errs=$(ffmpeg -v error -i "$F" -frames:v 30 -f null - 2>&1 | head -5) && [[ -n $errs ]]; then
    echo "   software decode errors, the file itself is suspect:"; sed 's/^/     /' <<<"$errs"
else
    echo "   fine"
fi

echo
echo "3. which decoder gstreamer picks on its own"
GST_DEBUG=GST_ELEMENT_FACTORY:4 timeout 20 gst-launch-1.0 -q filesrc location="$F" ! decodebin3 ! fakesink 2>&1 \
    | grep -oE 'dec[a-z0-9_]*' | grep -iE 'v4l2|dav1d|avdec|openh264|libde265' | sort -u | sed 's/^/   /' \
    || echo "   (nothing captured)"

echo
echo "4. forcing the hardware decoder"
codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$F" 2>/dev/null)
case $codec in
    h264)      hw=v4l2h264dec ;;
    hevc|h265) hw=v4l2h265dec ;;
    vp9)       hw=v4l2vp9dec ;;
    av1)       hw=v4l2av1dec ;;
    *)         hw="" ;;
esac
if [[ -n $hw ]]; then
    echo "   gst-launch-1.0 filesrc location=$F ! parsebin ! $hw ! fakesink"
    timeout 25 gst-launch-1.0 -q filesrc location="$F" ! parsebin ! "$hw" ! fakesink 2>&1 | head -8 | sed 's/^/     /'
    echo "   (no output above means it worked)"
else
    echo "   codec '$codec' has no v4l2 decoder"
fi

cat <<'EOF2'

5. to force gstreamer players onto the hardware decoders for a session:
   GST_PLUGIN_FEATURE_RANK=v4l2av1dec:MAX,v4l2h264dec:MAX,v4l2h265dec:MAX,v4l2vp9dec:MAX
   (put it in ~/.config/environment.d/gst.conf to keep it)
EOF2
