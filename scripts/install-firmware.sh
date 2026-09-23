#!/usr/bin/env bash
# install the dell signed qualcomm firmware for the inspiron 14 plus 7441
#
#   sudo install-firmware.sh                 install from firmware/ (or --from DIR)
#   sudo install-firmware.sh --extract PACK  pull the 11 files out of the latitude
#                                            7455 driver pack first, then install
#   install-firmware.sh --verify             check firmware/ against config/firmware.sha256
#   sudo install-firmware.sh --undo          remove everything it installed
#
# the 7441 and the latitude 7455 are the same board ("thena"), one shared dtsi
# upstream and linux-firmware symlinks the 7455 audio topology to the 7441's. the
# 7455 blobs authenticate on the 7441, so no windows install is needed.
#
# installs under /lib/firmware/updates/, which wins over /lib/firmware/ and
# survives linux-firmware upgrades. the adsp and cdsp images also have to be in
# the initramfs, rebuild-initramfs.sh does that.

set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

src=$FW_SRC
pack=""
mode=install
while (( $# )); do
    case $1 in
        --from)    src=${2:?}; shift 2 ;;
        --extract) pack=${2:?}; shift 2 ;;
        --verify)  mode=verify; shift ;;
        --undo)    mode=undo; shift ;;
        -h|--help) usage ;;
        *) die "unknown argument: $1" ;;
    esac
done

extract() {
    need_cmd 7z 7zip
    [[ -f $pack ]] || die "no such file: $pack"
    say "extracting from $(basename "$pack")"
    mkdir -p "$src"
    local args=()
    for f in "${FW_PACK_PATHS[@]}"; do args+=("Latitude-7455/Win11/arm64/$f"); done
    7z e -y -o"$src" "$pack" "${args[@]}" >/dev/null || die "7z extraction failed"
    ok "extracted to $src"
}

verify() {
    local sums="$ROOT/config/firmware.sha256" missing=0
    for f in "${FW_FILES[@]}"; do
        [[ -f $src/$f ]] || { err "missing $src/$f"; missing=1; }
    done
    if (( missing )); then
        # the usual cause is a first run without --extract, so say how to get the pack
        cat >&2 <<MSG

  not all 11 files are in $src. extract them from the latitude 7455 driver pack:

    $FW_PACK_NAME   (633 mb)
    dell support -> latitude 7455 -> "dell command | deploy driver pack"
    -> windows 11 arm64, put it in $FW_SRC/

    sudo $0 --extract $FW_SRC/$FW_PACK_NAME
MSG
        exit 1
    fi
    if (cd "$src" && sha256sum -c --quiet "$sums"); then
        ok "all 11 files match config/firmware.sha256"
    else
        # a newer driver pack revision would differ, that's not necessarily wrong
        warn "checksums differ from the recorded set (a different driver pack revision?)"
    fi
}

case $mode in
    verify) verify; exit 0 ;;
    undo)
        need_root
        rm -rf "$FW_DEST"
        ok "removed $FW_DEST, reboot to return to the previous state"
        exit 0 ;;
esac

need_root
[[ -n $pack ]] && extract
check_model || true
verify

say "installing to $FW_DEST"
# a stale symlink farm from an earlier generic firmware experiment would shadow the real blobs
rm -f "$FW_DEST"/*.xz 2>/dev/null || true
install -d -m 0755 "$FW_DEST"
for f in "${FW_FILES[@]}"; do
    install -m 0644 "$src/$f" "$FW_DEST/$f"
done
# firmware loading is selinux mediated
command -v restorecon >/dev/null && restorecon -RF "$FW_DEST"
ok "$(ls "$FW_DEST" | wc -l) files installed"

# a live start of the dsps works, a reboot is more reliable. the gpu is left
# alone on purpose, unbinding a live adreno tears down the drm vm under the
# compositor and crashes it, msm picks the zap shader up at next boot anyway
say "starting the dsps"
for rp in /sys/class/remoteproc/*/; do
    name=$(cat "$rp/name"); state=$(cat "$rp/state")
    [[ $name == adsp || $name == cdsp ]] || continue
    if [[ $state == running ]]; then
        ok "$name already running"; continue
    fi
    if echo start > "$rp/state" 2>/dev/null; then
        sleep 3; ok "$name: $(cat "$rp/state")"
    else
        warn "$name did not start, check dmesg"
    fi
done

cat <<MSG

next, and not optional: put the adsp and cdsp images in the initramfs, then reboot

    sudo $ROOT/scripts/rebuild-initramfs.sh --all
    sudo reboot

undo with: sudo $0 --undo
MSG
