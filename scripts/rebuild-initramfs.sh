#!/usr/bin/env bash
# install the dracut drop-ins this machine needs and rebuild the initramfs
#
#   sudo rebuild-initramfs.sh          current kernel
#   sudo rebuild-initramfs.sh --all    every installed kernel
#   sudo rebuild-initramfs.sh --undo   remove the drop-ins and rebuild
#
# two drop-ins from config/dracut go in:
#   99-x1e80100-qcom-firmware.conf   adsp/cdsp images. qcom_q6v5_pas probes in
#                                    the initramfs and remoteproc never retries a
#                                    failed request_firmware(), so without this
#                                    the adsp is offline all boot, no battery, no
#                                    audio. the gpu zap shader and video firmware
#                                    don't need this, msm and iris retry lazily.
#   99-x1e80100-backlight.conf       leds-qcom-lpg and pwm_bl, so the panel lights
#                                    inside the initrd and the luks prompt is
#                                    visible. only matters once patch 0002 is in.
#
# run this again after every kernel install, a fresh initramfs has neither.

set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_root

CONFS=(99-x1e80100-qcom-firmware.conf 99-x1e80100-backlight.conf)

all=0; undo=0
while (( $# )); do
    case $1 in
        --all)  all=1; shift ;;
        --undo) undo=1; shift ;;
        -h|--help) usage ;;
        *) die "unknown argument: $1" ;;
    esac
done

if (( undo )); then
    for c in "${CONFS[@]}"; do rm -f "$DRACUT_DIR/$c"; done
    ok "removed the drop-ins"
else
    for f in "${FW_INITRD[@]}"; do
        [[ -f $FW_DEST/$f ]] || die "missing $FW_DEST/$f, run install-firmware.sh first"
    done
    install -d "$DRACUT_DIR"
    for c in "${CONFS[@]}"; do
        install -m 0644 "$ROOT/config/dracut/$c" "$DRACUT_DIR/$c"
    done
    ok "installed ${CONFS[*]}"
fi

if (( all )); then
    kvers=$(ls /lib/modules)
else
    kvers=$(uname -r)
fi

for k in $kvers; do
    [[ -d /lib/modules/$k/kernel ]] || continue
    img=/boot/initramfs-$k.img
    say "rebuilding $img"
    dracut -f --kver "$k"
    (( undo )) && continue
    n=$(lsinitrd "$img" 2>/dev/null | grep -cE 'qcadsp8380|qccdsp8380|adsp_dtbs|cdsp_dtbs' || true)
    m=$(lsinitrd "$img" 2>/dev/null | grep -cE 'leds-qcom-lpg|pwm_bl' || true)
    (( n >= 4 )) && ok "firmware: $n/4 files" || err "firmware: only $n/4 files in the image"
    (( m >= 2 )) && ok "backlight: $m/2 modules" || warn "backlight: $m/2 modules (fine on a kernel without patch 0002)"
done

(( undo )) || cat <<'MSG'

reboot, then check:
    cat /sys/class/remoteproc/remoteproc0/state    # running
    cat /proc/asound/cards
    ./scripts/verify.sh
MSG
