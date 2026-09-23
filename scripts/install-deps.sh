#!/usr/bin/env bash
# install the packages the other scripts need
#
#   sudo install-deps.sh           what the install steps need (firmware extraction, kernel build)
#   sudo install-deps.sh --tools   also the diagnostic tools the docs reach for
#
# the kernel's own build requirements aren't here, they come from its spec once
# build-kernel.sh --prepare has fetched it (dnf builddep, see INSTALL.md)

set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_root

# 7zip not p7zip, only 7zip's 7z reads the driver pack
PKGS=(7zip rpm-build ccache git-core curl dracut acl grubby)
TOOLS=(v4l-utils i2c-tools alsa-utils pipewire-utils mesa-demos
       acpica-tools libgpiod-utils python3-numpy python3-pillow)

case ${1:-} in
    --tools) PKGS+=("${TOOLS[@]}") ;;
    "") ;;
    *) die "unknown argument: $1" ;;
esac

say "installing ${#PKGS[@]} packages"
dnf install -y "${PKGS[@]}"
command -v 7z >/dev/null || die "7z still missing, install the 7zip package (not p7zip)"
ok "packages installed"
