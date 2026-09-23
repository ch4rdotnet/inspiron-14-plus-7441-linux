#!/usr/bin/env bash
# stop systemd waiting 90 seconds per boot for a tpm that has no driver
#
#   sudo disable-tpm-wait.sh          mask the tpm device units, in userspace and in the initrd
#   sudo disable-tpm-wait.sh --undo   put it back
#
# the machine has a firmware tpm in trustzone, but nothing upstream drives it on
# a dt boot (tpm_crb is acpi only, tpm_ftpm_tee is op-tee not qsee), so
# dev-tpm0.device never appears and tpm2.target waits out a 45s timeout twice,
# once in the initrd and once in userspace. nothing here is enrolled against it.
# if a driver ever lands, undo this. see docs/boot-time.md

set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
need_root

UNITS=(dev-tpm0.device dev-tpmrm0.device)
ARGS="rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device"
CONF=$DRACUT_DIR/99-no-tpm.conf

if [[ ${1:-} == --undo ]]; then
    systemctl unmask "${UNITS[@]}"
    rm -f "$CONF"
    grubby --update-kernel=ALL --remove-args="$ARGS"
    ok "tpm units unmasked, takes effect next boot (rebuild the initramfs to drop the dracut change)"
    exit 0
fi

if [[ -e /dev/tpm0 ]]; then
    warn "/dev/tpm0 exists, a driver bound, leaving the units alone"
    exit 0
fi

systemctl mask "${UNITS[@]}" >/dev/null
install -d "$DRACUT_DIR"
install -m 0644 "$ROOT/config/dracut/99-no-tpm.conf" "$CONF"
# masking in /etc/systemd/system doesn't reach the initramfs, the kernel
# command line does. fedora is bls, so grubby rather than /etc/default/grub
if grep -q 'rd.systemd.mask=dev-tpm0.device' /proc/cmdline; then
    ok "already masked on the kernel command line"
else
    grubby --update-kernel=ALL --args="$ARGS"
    ok "masked in userspace and on the kernel command line, takes effect next boot"
fi
