# shared helpers, sourced by everything in scripts/ and tools/
# usage from scripts/:  . "$(dirname "$(readlink -f "$0")")/lib.sh"
# usage from tools/:    . "$(dirname "$(readlink -f "$0")")/../scripts/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT

# where things live in the project
FW_SRC="$ROOT/firmware"                # extracted blobs (gitignored, not redistributable)
BUILD_DIR="$ROOT/build/kernel"         # fedora dist-git clone plus rpmbuild tree (gitignored)

# where things go on the machine
FW_DEST=/lib/firmware/updates/qcom/x1e80100/dell/inspiron-14-plus-7441
DRACUT_DIR=/etc/dracut.conf.d

# the eleven dell signed files, and the four that must also be in the initramfs
FW_FILES=(
    qcadsp8380.mbn adsp_dtbs.elf adspr.jsn adsps.jsn adspua.jsn battmgr.jsn
    qccdsp8380.mbn cdsp_dtbs.elf cdspr.jsn
    qcdxkmsuc8380.mbn
    qcvss8380.mbn
)
FW_INITRD=(qcadsp8380.mbn adsp_dtbs.elf qccdsp8380.mbn cdsp_dtbs.elf)

# paths inside the latitude 7455 driver pack, relative to Latitude-7455/Win11/arm64/
FW_PACK_PATHS=(
    chipset/83RG3_A00-00/qcsubsys_ext_adsp8380/qcadsp8380.mbn
    chipset/83RG3_A00-00/qcsubsys_ext_adsp8380/adsp_dtbs.elf
    chipset/83RG3_A00-00/qcsubsys_ext_adsp8380/adspr.jsn
    chipset/83RG3_A00-00/qcsubsys_ext_adsp8380/adsps.jsn
    chipset/83RG3_A00-00/qcsubsys_ext_adsp8380/adspua.jsn
    chipset/83RG3_A00-00/qcsubsys_ext_adsp8380/battmgr.jsn
    chipset/83RG3_A00-00/qcsubsys_ext_cdsp8380/qccdsp8380.mbn
    chipset/83RG3_A00-00/qcsubsys_ext_cdsp8380/cdsp_dtbs.elf
    chipset/83RG3_A00-00/qcsubsys_ext_cdsp8380/cdspr.jsn
    video/9F6PJ_A00-00/qcdx8380/qcdxkmsuc8380.mbn
    video/9F6PJ_A00-00/qcdx8380/qcvss8380.mbn
)
FW_PACK_NAME="Latitude-7455-71MMN_Win11_1.0_A00.exe"

MODEL_MATCH="Inspiron 14 Plus 7441"

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_BLD=""; C_RST=""
fi

say()  { printf '%s==>%s %s\n' "$C_BLD" "$C_RST" "$*"; }
ok()   { printf '  %sok%s   %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '  %swarn%s %s\n' "$C_YLW" "$C_RST" "$*"; }
err()  { printf '  %serr%s  %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$@"; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "run as root"; }
need_user() { [[ $EUID -ne 0 ]] || die "run as your user, it calls sudo where needed"; }
need_cmd()  { command -v "$1" >/dev/null 2>&1 || die "need $1${2:+ (dnf install -y $2)}"; }

# the user to act on behalf of when running under sudo
real_user() { echo "${SUDO_USER:-$USER}"; }

machine_model() {
    tr -d '\0' < /proc/device-tree/model 2>/dev/null \
        || cat /sys/class/dmi/id/product_name 2>/dev/null \
        || echo unknown
}

# warn rather than refuse, the firmware is shared with the latitude 7455 and
# the dt is x1e80100 wide, but nothing here has been tested elsewhere
check_model() {
    local m; m=$(machine_model)
    [[ $m == *"$MODEL_MATCH"* ]] && return 0
    warn "this machine reports '$m', not a $MODEL_MATCH"
    return 1
}

# stock kernel version string of the running kernel, with any buildid removed
# 7.1.13-200.dellfix.fc44.aarch64 -> 7.1.13-200.fc44
stock_kernel_release() {
    uname -r | sed -E 's/\.[a-z0-9_]+$//; s/-([0-9]+)\.[^.]+\.(fc[0-9]+)$/-\1.\2/'
}

fedora_version() {
    . /etc/os-release 2>/dev/null
    echo "${VERSION_ID:-}"
}

# usage text is the leading comment block of the calling script
usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}
