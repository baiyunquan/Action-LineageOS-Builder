#!/usr/bin/env bash
#
# The compile step, nothing else. Assumes the source is already synced/patched
# and the build dependencies are present -- either inside the
# lineageos-15.1-builder image, or on a host old enough to build AOSP 8.1.
#
# This is the LOCAL counterpart to build-in-container.sh. The host driver keeps
# the container and periodically commits its writable layer. The source tree,
# out/ and ccache are bind mounts, so they remain the real incremental state and
# are available even when the container itself has to be recreated.

set -uo pipefail

WORKDIR="${WORKDIR:?WORKDIR must be set}"
LUNCH_TARGET="${LUNCH_TARGET:-lineage_alice-userdebug}"
JOBS="${JOBS:-$(nproc)}"
CCACHE_SIZE="${CCACHE_SIZE:-50G}"
BUILD_TARGET="${BUILD_TARGET:-bacon}"
CHECKPOINT_DIR="${CHECKPOINT_DIR:-${WORKDIR}/../checkpoints}"

checkpoint_stage() {
    local stage="$1"
    mkdir -p "${CHECKPOINT_DIR}"
    printf '%s\n' "${stage}" > "${CHECKPOINT_DIR}/current-stage"
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${stage}" \
        >> "${CHECKPOINT_DIR}/history.log"
}

checkpoint_stage "container-start"

cd "${WORKDIR}"

export USE_CCACHE=1
export CCACHE_DIR="${CCACHE_DIR:-${WORKDIR}/../ccache}"
export CCACHE_COMPRESS=1
mkdir -p "${CCACHE_DIR}"
if [ -x prebuilts/misc/linux-x86/ccache/ccache ]; then
    prebuilts/misc/linux-x86/ccache/ccache -M "${CCACHE_SIZE}" >/dev/null
fi

export LC_ALL=C
export ALLOW_MISSING_DEPENDENCIES=true

# See docker/Dockerfile for why Jack is off. Set here too so the --native path
# gets it as well.
export ANDROID_COMPILE_WITH_JACK=false

echo "==> envsetup + lunch ${LUNCH_TARGET}"
# -u must stay OFF from here on: envsetup.sh, lunch and the build all read unset
# variables. Re-enabling it aborts lunch with "TOP: unbound variable".
set +u
source build/envsetup.sh
lunch "${LUNCH_TARGET}"

# lunch prints errors but does not reliably exit non-zero, so verify the product
# actually got selected rather than trusting its status.
if [ "${TARGET_PRODUCT:-}" != "lineage_alice" ]; then
    echo "!! lunch did not select lineage_alice (TARGET_PRODUCT='${TARGET_PRODUCT:-unset}')" >&2
    exit 1
fi
echo "   TARGET_PRODUCT=${TARGET_PRODUCT} TARGET_BUILD_VARIANT=${TARGET_BUILD_VARIANT:-?}"
checkpoint_stage "after-lunch"

echo "==> make -j${JOBS} ${BUILD_TARGET}"
checkpoint_stage "make-start"
# make, not mka: mka is a shell function from envsetup.sh. It works in an
# interactive shell but not when something needs to exec it as a command, and
# using make everywhere keeps the local and CI paths identical. lunch has
# already exported what make needs and WORKDIR is the top of the tree.
make -j"${JOBS}" "${BUILD_TARGET}"
rc=$?

if [ -x prebuilts/misc/linux-x86/ccache/ccache ]; then
    echo "==> ccache"
    prebuilts/misc/linux-x86/ccache/ccache -s | sed 's/^/   /'
fi

if [ "${rc}" -ne 0 ]; then
    checkpoint_stage "build-failed-${rc}"
    echo "!! build failed with exit ${rc}" >&2
    exit "${rc}"
fi

checkpoint_stage "build-finished"
echo "==> Build finished"
ls -lh out/target/product/alice/lineage-15.1-*.zip \
       out/target/product/alice/boot.img \
       out/target/product/alice/system.img 2>/dev/null || true
