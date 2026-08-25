#!/usr/bin/env bash
#
# Build LineageOS 15.1 for hi6210sft inside an ubuntu:18.04 container.
#
# Why a container: AOSP 8.1 builds its *host* tools with the system compiler.
# gcc-11/12 on ubuntu-22.04 rejects a lot of 2017-era C++, and the runner has no
# python2 or openjdk-8. bionic has all three natively, so the build works
# unmodified instead of needing a pile of upstream backports.
#
# Exit codes:
#   0  ROM built
#   75 hit the internal time limit -- partial progress is in ccache when enabled
#   *  real build failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-/work/workspace}"
CCACHE_DIR_HOST="${CCACHE_DIR:-/work/ccache}"
LUNCH_TARGET="${LUNCH_TARGET:-lineage_alice-userdebug}"
JOBS="${JOBS:-$(nproc)}"
# Leave headroom under the GitHub Actions 6h job ceiling so the ccache save and
# artifact upload steps still get to run.
BUILD_TIMEOUT="${BUILD_TIMEOUT:-290m}"
CCACHE_SIZE="${CCACHE_SIZE:-8G}"
DISABLE_CCACHE="${DISABLE_CCACHE:-0}"

case "${DISABLE_CCACHE,,}" in
    1|true|yes|on) DISABLE_CCACHE=1 ;;
    *)             DISABLE_CCACHE=0 ;;
esac

if [ "${SKIP_APT_INSTALL:-0}" = 1 ]; then
    echo "==> Using dependencies preinstalled in the CCI builder image"
else
    echo "==> Installing build dependencies (bionic)"
    export DEBIAN_FRONTEND=noninteractive

    # GitHub-hosted runners are outside mainland China, so the CN mirrors can
    # be unreachable or return a proxy-generated TLS response.  Keep them
    # opt-in.  The default uses the official Ubuntu archives; set
    # USE_CN_MIRRORS=true to try Huawei Cloud and then Aliyun instead.
    use_cn_mirrors="${USE_CN_MIRRORS:-0}"
    case "${use_cn_mirrors,,}" in
        1|true|yes|on)
            APT_MIRROR_PRIMARY="${APT_MIRROR_PRIMARY:-http://repo.huaweicloud.com/ubuntu}"
            APT_MIRROR_FALLBACK="${APT_MIRROR_FALLBACK:-http://mirrors.aliyun.com/ubuntu}"
            APT_MIRROR_LABEL="Huawei Cloud/Aliyun"
            ;;
        *)
            APT_MIRROR_PRIMARY="${APT_MIRROR_PRIMARY:-http://archive.ubuntu.com/ubuntu}"
            APT_MIRROR_FALLBACK="${APT_MIRROR_FALLBACK:-http://security.ubuntu.com/ubuntu}"
            APT_MIRROR_LABEL="official Ubuntu"
            ;;
    esac
    echo "   apt mirror mode: ${APT_MIRROR_LABEL} (USE_CN_MIRRORS=${use_cn_mirrors})"

    # Keep this source list private to this invocation so we do not mutate the
    # base image's apt configuration.  HTTP is intentional here: the minimal
    # ubuntu:18.04 image has no CA bundle until ca-certificates is installed.
    apt_source_list="$(mktemp /tmp/lineage-apt-sources.XXXXXX)"
    apt_get=(apt-get -o "Dir::Etc::sourcelist=${apt_source_list}" \
        -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0)
    write_bionic_sources() {
        local mirror="${1%/}"
        printf '%s\n' \
            "deb ${mirror} bionic main restricted universe multiverse" \
            "deb ${mirror} bionic-updates main restricted universe multiverse" \
            "deb ${mirror} bionic-security main restricted universe multiverse" \
            >"${apt_source_list}"
    }
    apt_mirror=""
    for candidate in "${APT_MIRROR_PRIMARY}" "${APT_MIRROR_FALLBACK}"; do
        write_bionic_sources "${candidate}"
        if "${apt_get[@]}" update -qq; then
            apt_mirror="${candidate}"
            echo "   apt mirror: ${candidate}"
            break
        fi
        echo "   apt mirror failed: ${candidate}" >&2
    done
    [[ -n "${apt_mirror}" ]] || {
        echo "!! ${APT_MIRROR_LABEL} apt mirrors are unavailable" >&2
        exit 1
    }

    "${apt_get[@]}" install -y -qq --no-install-recommends \
        ca-certificates openjdk-8-jdk \
        bc bison build-essential ccache curl flex g++-multilib gcc-multilib git \
        gnupg gperf imagemagick lib32ncurses5-dev lib32readline-dev lib32z1-dev \
        liblz4-tool libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev \
        libwxgtk3.0-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool \
        squashfs-tools xsltproc zip zlib1g-dev unzip python python-minimal git-lfs \
        > /dev/null || { echo "!! dependency install failed" >&2; exit 1; }
    rm -f "${apt_source_list}"
fi

export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export PATH="${JAVA_HOME}/bin:${PATH}"

# Fail here rather than 40 minutes later inside the build. A missing python2 in
# particular shows up as a confusing "roomservice.py: No such file or directory"
# (the shebang interpreter is what is actually missing). `repo` is only used by
# the host-side sync step, and `obsutil` is only needed by the CCI entrypoint;
# neither is required inside the GitHub compile container.
for tool in java python python3 curl git git-lfs; do
    command -v "${tool}" >/dev/null || { echo "!! ${tool} not installed" >&2; exit 1; }
done
echo "   java:   $(java -version 2>&1 | head -1)"
echo "   python: $(python --version 2>&1)"

cd "${WORKDIR}"

# Some LineageOS 15.1 projects keep large prebuilts in Git LFS.  A repo sync
# can leave the LFS pointer in the worktree when the host has no LFS filter;
# that is exactly how the 134-byte chromium-webview pointer reached the old
# GitHub run.  Hydrate the affected project inside the build container, then
# fail before compilation if any pointer remains.
echo "==> Hydrating Git LFS prebuilts"
git lfs install --system >/dev/null 2>&1 || true

# The LineageOS manifest does not create one repository at
# external/chromium-webview.  It creates separate repositories for patches and
# each ABI under external/chromium-webview/prebuilt/*, so running `git lfs pull`
# in the parent directory is a no-op.  Pull each manifest project explicitly;
# the child projects' .lfsconfig files point at the LineageOS Gerrit LFS store,
# which contains the large WebView objects that are not hosted by GitHub LFS.
# Do not run `git lfs install --local` here: repo-managed projects use a .git
# file that points into .repo, and the old bionic Git LFS package can fail while
# trying to install a per-repository pre-push hook even though LFS downloads
# themselves work. The system-level filters installed above are sufficient for
# `lfs pull`; passing the endpoint explicitly also works with older Git LFS
# versions that do not consistently honor .lfsconfig.
lfs_failed=0
hydrate_lfs_repo() {
    local repo="$1"
    [ -d "${repo}" ] || return 0

    echo "   LFS repo: ${repo}"
    if ! git -C "${repo}" lfs env >/dev/null 2>&1; then
        echo "!! git lfs is not usable in ${repo}" >&2
        lfs_failed=1
        return 0
    fi
    lfs_endpoint="$(git -C "${repo}" config --file=.lfsconfig --get lfs.url 2>/dev/null || true)"
    if [ -n "${lfs_endpoint}" ]; then
        echo "   LFS endpoint: ${lfs_endpoint}"
        lfs_pull=(git -C "${repo}" -c "lfs.url=${lfs_endpoint}" lfs pull)
    else
        lfs_pull=(git -C "${repo}" lfs pull)
    fi
    if ! "${lfs_pull[@]}"; then
        echo "!! git lfs pull failed for ${repo}" >&2
        lfs_failed=1
        return 0
    fi
    if ! git -C "${repo}" lfs checkout; then
        echo "!! git lfs checkout failed for ${repo}" >&2
        lfs_failed=1
    fi
}

for lfs_repo in \
    external/chromium-webview/patches \
    external/chromium-webview/prebuilt/arm \
    external/chromium-webview/prebuilt/arm64 \
    external/chromium-webview/prebuilt/x86 \
    external/chromium-webview/prebuilt/x86_64; do
    hydrate_lfs_repo "${lfs_repo}"
done

if [ "${lfs_failed}" -ne 0 ]; then
    echo "!! one or more Git LFS projects could not be hydrated; refusing to build" >&2
    exit 1
fi

pointer_count=0
while IFS= read -r -d '' candidate; do
    if head -n1 "${candidate}" | grep -qx 'version https://git-lfs.github.com/spec/v1'; then
        echo "!! unresolved Git LFS pointer: ${candidate}" >&2
        pointer_count=$((pointer_count + 1))
    fi
done < <(find . -type f -size -1024c -print0)
if [ "${pointer_count}" -ne 0 ]; then
    echo "!! ${pointer_count} unresolved Git LFS pointer(s); refusing to build" >&2
    exit 1
fi

# A pointer is only 134 bytes and is not a ZIP archive.  Validate the target
# APK explicitly so a future Git LFS/filter regression fails here, before
# Android's package signer reports the much less useful ZipException.
webview_apk_count=0
webview_apks=(external/chromium-webview/prebuilt/*/webview.apk)
for webview_apk in "${webview_apks[@]}"; do
    [ -f "${webview_apk}" ] || continue
    webview_apk_count=$((webview_apk_count + 1))
    webview_size="$(stat -c '%s' "${webview_apk}")"
    if [ "${webview_size}" -lt 1048576 ]; then
        echo "!! WebView APK is unexpectedly small (${webview_size} bytes): ${webview_apk}" >&2
        exit 1
    fi
    if ! unzip -tq "${webview_apk}" >/dev/null 2>&1; then
        echo "!! WebView APK is not a valid ZIP: ${webview_apk}" >&2
        exit 1
    fi
    echo "   WebView APK verified: ${webview_apk} (${webview_size} bytes)"
done
if [ "${webview_apk_count}" -eq 0 ] || [ ! -f external/chromium-webview/prebuilt/arm64/webview.apk ]; then
    echo "!! required arm64 WebView APK is missing" >&2
    exit 1
fi

# ccache is what makes a resumed run finish inside the time limit; a warm cache
# typically takes the second or third run from ~6h down to well under two.  The
# disable switch is deliberately handled before creating CCACHE_DIR, so a
# no-cache run does not reserve or populate a large cache directory.
if [ "${DISABLE_CCACHE}" -eq 1 ]; then
    # AOSP's make logic treats any non-empty USE_CCACHE as enabled on some
    # 15.1 branches, so unset it instead of assigning a false-looking value.
    unset USE_CCACHE CCACHE_DIR CCACHE_COMPRESS
    echo "==> ccache disabled (DISABLE_CCACHE=${DISABLE_CCACHE})"
else
    export USE_CCACHE=1
    export CCACHE_DIR="${CCACHE_DIR_HOST}"
    export CCACHE_COMPRESS=1
    mkdir -p "${CCACHE_DIR}"
    if [ -x prebuilts/misc/linux-x86/ccache/ccache ]; then
        prebuilts/misc/linux-x86/ccache/ccache -M "${CCACHE_SIZE}" >/dev/null
        prebuilts/misc/linux-x86/ccache/ccache -s | sed 's/^/   /'
    fi
fi

export LC_ALL=C
export ALLOW_MISSING_DEPENDENCIES=true

# Build Java with javac/d8 instead of Jack. Jack talks to a background server
# over a local TLS socket whose certificates are generated on first run; inside a
# container that fails with "SSL error when connecting to the Jack server" and
# takes the whole build down at setup-jack-server. Jack was already deprecated in
# Android 8.0, and 8.1 builds fine on the javac path.
export ANDROID_COMPILE_WITH_JACK=false

echo "==> envsetup + lunch ${LUNCH_TARGET}"
# -u must stay OFF from here on: envsetup.sh, lunch and mka all read unset
# variables (TOP, version, ...). Re-enabling it after the source aborts lunch
# with "TOP: unbound variable".
set +u
source build/envsetup.sh
lunch "${LUNCH_TARGET}"

# lunch prints its errors but does not reliably exit non-zero, so check that it
# actually selected the product instead of trusting its status.
if [ "${TARGET_PRODUCT:-}" != "lineage_alice" ]; then
    echo "!! lunch did not select lineage_alice (TARGET_PRODUCT='${TARGET_PRODUCT:-unset}')" >&2
    exit 1
fi
echo "   TARGET_PRODUCT=${TARGET_PRODUCT} TARGET_BUILD_VARIANT=${TARGET_BUILD_VARIANT:-?}"

echo "==> Building (limit ${BUILD_TIMEOUT}, -j${JOBS})"
# `timeout` rather than letting Actions kill the job: a hard kill would skip the
# ccache save step and throw away every bit of progress this run made.
#
# Invoke make directly rather than mka: mka is a shell function from
# envsetup.sh, and timeout can only exec a real binary ("failed to run command
# 'mka': No such file or directory"). lunch has already exported everything make
# needs, WORKDIR is the top of the tree, and `bacon` is a genuine make target
# from vendor/lineage/build/tasks -- so this is equivalent.
timeout "${BUILD_TIMEOUT}" make -j"${JOBS}" bacon
rc=$?

if [ "${DISABLE_CCACHE}" -eq 0 ] && [ -x prebuilts/misc/linux-x86/ccache/ccache ]; then
    echo "==> ccache after build"
    prebuilts/misc/linux-x86/ccache/ccache -s | sed 's/^/   /'
fi

if [ "${rc}" -eq 124 ]; then
    echo ""
    echo "=================================================================="
    echo " Hit the ${BUILD_TIMEOUT} limit before the ROM finished."
    echo " This is expected on the first run or two. ccache has been saved;"
    echo " re-run this workflow and it will pick up where it left off."
    echo "=================================================================="
    exit 75
fi

if [ "${rc}" -ne 0 ]; then
    echo "!! build failed with exit ${rc}" >&2
    exit "${rc}"
fi

echo "==> Build finished"
ls -lh out/target/product/alice/*.zip out/target/product/alice/boot.img \
       out/target/product/alice/system.img 2>/dev/null || true

echo "==> Verifying pinned vendor blobs in final system.img"
python3 "${SCRIPT_DIR}/verify-vendor-blobs.py" \
    --source-root "${WORKDIR}" \
    --system-image "${WORKDIR}/out/target/product/alice/system.img"
