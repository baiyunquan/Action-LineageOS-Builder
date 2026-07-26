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
#   75 hit the internal time limit -- partial progress is in ccache, re-run
#   *  real build failure

set -uo pipefail

WORKDIR="${WORKDIR:-/work/workspace}"
CCACHE_DIR_HOST="${CCACHE_DIR:-/work/ccache}"
LUNCH_TARGET="${LUNCH_TARGET:-lineage_alice-userdebug}"
JOBS="${JOBS:-$(nproc)}"
# Leave headroom under the GitHub Actions 6h job ceiling so the ccache save and
# artifact upload steps still get to run.
BUILD_TIMEOUT="${BUILD_TIMEOUT:-290m}"
CCACHE_SIZE="${CCACHE_SIZE:-8G}"

echo "==> Installing build dependencies (bionic)"
export DEBIAN_FRONTEND=noninteractive

# 18.04 is still under ESM, so bionic packages remain on archive.ubuntu.com.
# They are NOT on old-releases -- that mirror 404s for dists/bionic/Release, and
# rewriting the sources to point at it breaks an otherwise working config.
# Only fall back if the default mirror ever stops serving bionic.
if ! apt-get update -qq; then
    echo "   default mirror failed, retrying against old-releases"
    sed -i -e 's|archive.ubuntu.com|old-releases.ubuntu.com|g' \
           -e 's|security.ubuntu.com|old-releases.ubuntu.com|g' /etc/apt/sources.list
    apt-get update -qq || { echo "!! apt-get update failed" >&2; exit 1; }
fi

apt-get install -y -qq --no-install-recommends \
    openjdk-8-jdk \
    bc bison build-essential ccache curl flex g++-multilib gcc-multilib git \
    gnupg gperf imagemagick lib32ncurses5-dev lib32readline-dev lib32z1-dev \
    liblz4-tool libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev \
    libwxgtk3.0-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool \
    squashfs-tools xsltproc zip zlib1g-dev unzip python python-minimal \
    > /dev/null || { echo "!! dependency install failed" >&2; exit 1; }

export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export PATH="${JAVA_HOME}/bin:${PATH}"

# Fail here rather than 40 minutes later inside the build. A missing python2 in
# particular shows up as a confusing "roomservice.py: No such file or directory"
# (the shebang interpreter is what is actually missing).
for tool in java python curl git; do
    command -v "${tool}" >/dev/null || { echo "!! ${tool} not installed" >&2; exit 1; }
done
echo "   java:   $(java -version 2>&1 | head -1)"
echo "   python: $(python --version 2>&1)"

cd "${WORKDIR}"

# ccache is what makes a resumed run finish inside the time limit; a warm cache
# typically takes the second or third run from ~6h down to well under two.
export USE_CCACHE=1
export CCACHE_DIR="${CCACHE_DIR_HOST}"
export CCACHE_COMPRESS=1
mkdir -p "${CCACHE_DIR}"
if [ -x prebuilts/misc/linux-x86/ccache/ccache ]; then
    prebuilts/misc/linux-x86/ccache/ccache -M "${CCACHE_SIZE}" >/dev/null
    prebuilts/misc/linux-x86/ccache/ccache -s | sed 's/^/   /'
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

if [ -x prebuilts/misc/linux-x86/ccache/ccache ]; then
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
