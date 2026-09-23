#!/usr/bin/env bash
# build the fedora kernel with this project's patches and config
#
#   build-kernel.sh                      fetch dist-git and sources, apply, build
#   build-kernel.sh --prepare            fetch and apply only, no build
#   sudo build-kernel.sh --install [ID]  install the rpms for buildid ID and rebuild the initramfs
#   build-kernel.sh --list               show the releases already built
#   build-kernel.sh --camera [...]       also fold in patches/camera, with buildid .dellcam
#
# the camera patches are opt in. the sensor probes but no frames arrive, and
# they're the least tested thing on the machine (docs/camera.md, docs/hangs.md).
# the different buildid keeps a camera kernel from replacing the normal one.
#
# environment:
#   BUILDID=.dellfix       release suffix, so the build sits next to the stock kernel
#   KERNEL_TAG=...         dist-git tag to build from, default matches the running kernel
#   DISTGIT_BRANCH=fNN     fallback branch if the tag isn't found, default from os-release
#   PATCHES='...'          which patches to fold in, overrides the default and --camera
#
# the spec applies linux-kernel-test.patch as Patch999999 and merges kernel-local
# over the generated config, so no spec edits are needed. only the base flavour
# is built, no debug, debuginfo, perf or tools, which is ~20 min cold and ~3 min
# with a warm ccache.

set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

CAMERA=0
[[ ${1:-} == --camera ]] && { CAMERA=1; shift; }

# the patches as sent upstream, kept 1:1 in patches/out. 0000 is the cover letter
SENT="$ROOT/patches/out/scmi/000[1-9]*.patch $ROOT/patches/out/dts/000[1-9]*.patch"

if (( CAMERA )); then
    BUILDID=${BUILDID:-.dellcam}
    PATCHES=${PATCHES:-$SENT $ROOT/patches/camera/*.patch}
else
    BUILDID=${BUILDID:-.dellfix}
    PATCHES=${PATCHES:-$SENT}
fi
DISTGIT=${DISTGIT:-https://src.fedoraproject.org/rpms/kernel.git}
LOOKASIDE=${LOOKASIDE:-https://src.fedoraproject.org/repo/pkgs/rpms/kernel}
KERNEL_TAG=${KERNEL_TAG:-kernel-$(stock_kernel_release)}
DISTGIT_BRANCH=${DISTGIT_BRANCH:-f$(fedora_version)}
kb=$BUILD_DIR

spec_ver()  { sed -n 's/^%define specrpmversion \(.*\)/\1/p' "$kb/kernel.spec"; }
spec_rel()  { sed -n 's/^%define pkgrelease \(.*\)/\1/p' "$kb/kernel.spec"; }
dist_tag()  { rpm --eval '%{?dist}'; }

fetch_distgit() {
    [[ -f $kb/kernel.spec ]] && { ok "dist-git already in $kb"; return; }
    need_cmd git git-core
    mkdir -p "$(dirname "$kb")"
    say "cloning fedora dist-git at $KERNEL_TAG"
    if ! git clone --depth 1 --branch "$KERNEL_TAG" "$DISTGIT" "$kb" 2>/dev/null; then
        warn "no tag $KERNEL_TAG, falling back to branch $DISTGIT_BRANCH"
        git clone --depth 1 --branch "$DISTGIT_BRANCH" "$DISTGIT" "$kb"
    fi
    ok "spec is kernel $(spec_ver)-$(spec_rel)"
}

hash_ok() {  # file algorithm hash
    [[ -s $1 ]] || return 1
    [[ $("${2,,}sum" "$1" | cut -d' ' -f1) == "$3" ]]
}

# the sources file names every tarball and its hash, so fetch straight from the
# lookaside cache. fedpkg needs working git metadata and gets the package name
# from the checkout directory, which is not called "kernel" here
fetch_sources() {
    local alg file hash url
    while read -r alg file hash; do
        if hash_ok "$kb/$file" "$alg" "$hash"; then
            ok "$file present"; continue
        fi
        url="$LOOKASIDE/$file/${alg,,}/$hash/$file"
        say "downloading $file"
        curl -fL --retry 3 --progress-bar -o "$kb/$file.part" "$url" || die "download failed: $url"
        hash_ok "$kb/$file.part" "$alg" "$hash" || die "$file does not match its hash"
        mv -f "$kb/$file.part" "$kb/$file"
    done < <(sed -n 's/^\([A-Za-z0-9]*\) (\(.*\)) = \([0-9a-fA-F]*\)$/\1 \2 \3/p' "$kb/sources")
}

apply_overrides() {
    local n=0
    # dist-git ships this file empty, it is the hook the spec applies
    : > "$kb/linux-kernel-test.patch"
    for p in $PATCHES; do
        [[ -f $p ]] || die "no such patch: $p"
        cat "$p" >> "$kb/linux-kernel-test.patch"
        n=$((n + 1))
    done
    (( n )) || die "no patches matched $PATCHES"
    grep -q '^diff --git' "$kb/linux-kernel-test.patch" || die "the patch file has no diffs"
    cp "$ROOT/config/kernel-local" "$kb/kernel-local"
    ok "$n patches and kernel-local staged"
    grep -q 'CONFIG_ARM_SCMI_CPUFREQ=y' "$kb/kernel-local" \
        || warn "kernel-local lacks CONFIG_ARM_SCMI_CPUFREQ=y, cpufreq will not load by itself"
}

prepare() {
    fetch_distgit
    fetch_sources
    apply_overrides
    if [[ $(spec_ver) != $(uname -r | cut -d- -f1) ]]; then
        warn "building $(spec_ver) on a $(uname -r) host, that's fine, just not identical"
    fi
}

# the spec has no ccache support, so put the shim dir ahead of gcc on PATH.
# the build dir name embeds the release string, so hashing the cwd would miss
# on every buildid change, hence NOHASHDIR and BASEDIR
setup_ccache() {
    command -v ccache >/dev/null || { warn "no ccache, every build will be a cold one"; return; }
    [[ -d /usr/lib64/ccache ]] || return
    export PATH="/usr/lib64/ccache:$PATH"
    export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
    export CCACHE_BASEDIR="$kb/rpmbuild/BUILD"
    export CCACHE_NOHASHDIR=1
    export CCACHE_SLOPPINESS=locale,time_macros,include_file_mtime,include_file_ctime
    # a full build caches to ~1 gb, 25 gb leaves room for several
    ccache -M 25G >/dev/null 2>&1 || true
    ccache -z >/dev/null 2>&1 || true
    ok "ccache in $CCACHE_DIR"
}

build() {
    need_user
    prepare
    setup_ccache
    local ver rel; ver=$(spec_ver); rel=$(spec_rel)
    say "building kernel-$ver-$rel$BUILDID$(dist_tag), log in $kb/build.log"
    cd "$kb"
    time rpmbuild \
        --define "_topdir $kb/rpmbuild" \
        --define "_sourcedir $kb" \
        --define "_specdir $kb" \
        --define "_builddir $kb/rpmbuild/BUILD" \
        --define "_srcrpmdir $kb/rpmbuild/SRPMS" \
        --define "_rpmdir $kb/rpmbuild/RPMS" \
        --define "buildid $BUILDID" \
        --target aarch64 \
        --with baseonly \
        --without debug --without debuginfo \
        --without perf --without libperf --without tools --without bpftool \
        --without doc --without headers --without cross_headers \
        --without selftests --without kabichk \
        -bb kernel.spec 2>&1 | tee build.log \
        | grep -E '^(Executing|Processing|Wrote|error|Error|ERROR|make.*Error)' || true

    command -v ccache >/dev/null && ccache -s 2>/dev/null | grep -iE 'hits|misses' | sed 's/^/  /'
    if find "$kb/rpmbuild/RPMS" -name "kernel-core-$ver-$rel$BUILDID*.rpm" | grep -q .; then
        ok "built:"; find "$kb/rpmbuild/RPMS" -name "*$BUILDID*.rpm" | sed 's/^/    /'
        echo; echo "install with:  sudo $0 --install $BUILDID"
    else
        err "build failed, last errors from build.log:"
        grep -iE 'error|failed' "$kb/build.log" | tail -20 | sed 's/^/    /'
        if grep -q 'Failed build dependencies' "$kb/build.log"; then
            echo; echo "missing build dependencies, install them with:  sudo dnf builddep -y $kb/kernel.spec"
        elif grep -qE 'Hunk #[0-9]+ FAILED|\(%prep\)' "$kb/build.log"; then
            echo; echo "a patch didn't apply to $(spec_ver)-$(spec_rel), INSTALL.md has what to do"
        fi
        exit 1
    fi
}

list_builds() {
    ls "$kb"/rpmbuild/RPMS/*/kernel-core-*.rpm 2>/dev/null \
        | sed 's|.*/kernel-core-||; s|\.aarch64\.rpm||' || echo "  nothing built yet"
}

install_rpms() {
    need_root
    local id=${1:-$BUILDID} ver rel
    ver=$(spec_ver); rel="$(spec_rel)$id"
    # grub boots the vmlinuz that kernel-uki-dtbloader ships, so kernel-core isn't needed
    # several builds can share RPMS/, so select by release rather than globbing
    mapfile -t rpms < <(find "$kb/rpmbuild/RPMS" -name "kernel*-$ver-$rel.*.rpm" 2>/dev/null \
        | grep -E "/kernel-($ver|modules-$ver|modules-core-|modules-extra-$ver|uki-dtbloader-)" \
        | grep -vE 'internal|uki-virt|devel|matched|debug' | sort -u)
    (( ${#rpms[@]} )) || { err "no rpms for $ver-$rel, built releases:"; list_builds; exit 1; }

    local nevra; nevra=$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "${rpms[0]}")
    say "installing ${#rpms[@]} rpms for $nevra"
    if rpm -q "$nevra" >/dev/null 2>&1; then
        # same nevra replaces the installed one rather than adding a boot entry,
        # rpm --replacepkgs still runs the scriptlets that copy the uki to the esp
        warn "$nevra is already installed, replacing it in place"
        rpm -Uvh --replacepkgs --replacefiles "${rpms[@]}"
    else
        dnf install -y "${rpms[@]}"
    fi
    # a fresh initramfs has no adsp firmware and no backlight modules
    "$ROOT/scripts/rebuild-initramfs.sh" --all
    ok "installed, reboot and pick $ver-$rel at the boot menu"
}

case ${1:-} in
    --prepare) prepare ;;
    --install) install_rpms "${2:-}" ;;
    --list)    list_builds ;;
    -h|--help) usage ;;
    "")        build ;;
    *)         die "unknown argument: $1" ;;
esac
