#!/usr/bin/env bash
# turn the three patch based diagnostic modules into buildable trees
#
#   tools/camera/prepare.sh LINUX_TARBALL     e.g. build/kernel/linux-7.1.13.tar.xz
#
# camssdiag, ccidiag and ov02diag are kept as patches against the v7.1.13
# drivers rather than as copies. this extracts the pristine sources from the
# kernel tarball, applies the patches, and leaves each directory ready for
# make. a much newer kernel may need the patches re-derived by hand.

set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/../../scripts/lib.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && usage
tar=${1:?usage: $0 LINUX_TARBALL}
[[ -f $tar ]] || die "no such file: $tar"
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

say "extracting sources from $(basename "$tar")"
tar -xJf "$tar" -C "$tmp" --wildcards --strip-components=1 \
    '*/drivers/media/platform/qcom/camss/*' \
    '*/drivers/i2c/busses/i2c-qcom-cci.c' \
    '*/drivers/media/i2c/ov02e10.c'

# camss is a whole directory, the others are one file each
cp "$tmp"/drivers/media/platform/qcom/camss/*.[ch] "$here/camssdiag/"
cp "$tmp/drivers/i2c/busses/i2c-qcom-cci.c" "$here/ccidiag/ccidiag.c"
cp "$tmp/drivers/media/i2c/ov02e10.c" "$here/ov02diag/ov02diag.c"

for m in camssdiag ccidiag ov02diag; do
    (cd "$here/$m" && patch -p1 --no-backup-if-mismatch < "$m.patch") || die "$m.patch did not apply"
    ok "$m ready, build with: make -C tools/camera/$m"
done
