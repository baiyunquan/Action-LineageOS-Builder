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
# 18.04 is EOL; its packages only live on old-releases now.
sed -i -e 's|archive.ubuntu.com|old-releases.ubuntu.com|g' \
       -e 's|security.ubuntu.com|old-releases.ubuntu.com|g' \
       -e 's|ports.ubuntu.com|old-releases.ubuntu.com|g' /etc/apt/sources.list

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    openjdk-8-jdk \
    bc bison build-essential ccache curl flex g++-multilib gcc-multilib git \
    gnupg gperf imagemagick lib32ncurses5-dev lib32readline-dev lib32z1-dev \
    liblz4-tool libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev \
    libwxgtk3.0-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool \
    squashfs-tools xsltproc zip zlib1g-dev unzip python python-minimal \
    > /dev/null

export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export PATH="${JAVA_HOME}/bin:${PATH}"
echo "   java: $(java -version 2>&1 | head -1)"
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

echo "==> envsetup + lunch ${LUNCH_TARGET}"
set +u
source build/envsetup.sh
set -u
lunch "${LUNCH_TARGET}" || { echo "!! lunch failed" >&2; exit 1; }

echo "==> Building (limit ${BUILD_TIMEOUT}, -j${JOBS})"
# `timeout` rather than letting Actions kill the job: a hard kill would skip the
# ccache save step and throw away every bit of progress this run made.
timeout "${BUILD_TIMEOUT}" mka bacon -j"${JOBS}"
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
