#!/usr/bin/env bash
#
# Build LineageOS 15.1 for Huawei CAM-TL00 on a local x86_64 Linux machine.
#
# This is the alternative to the GitHub Actions path. Locally there is no 6h
# ceiling and out/ persists, so the build runs to completion in one go and
# re-runs are genuinely incremental -- which makes it the better option for
# iterating on the device tree.
#
#   ./scripts/build-local.sh                    full build, in Docker
#   ./scripts/build-local.sh --skip-sync        rebuild without re-syncing
#   ./scripts/build-local.sh --native           build directly on the host
#   ./scripts/build-local.sh --shell            drop into the build container
#
# NOTE: this script has not been run end to end. It is written from the four
# failures the CI path hit (see LOCAL_BUILD.md), but the local path itself is
# unverified.

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPODIR="$(cd "${SCRIPTDIR}/.." && pwd)"

BUILDROOT="${BUILDROOT:-${REPODIR}/build-local}"
WORKDIR="${BUILDROOT}/workspace"
CCACHE_DIR="${BUILDROOT}/ccache"
IMAGE="${IMAGE:-lineageos-15.1-builder}"
LUNCH_TARGET="${LUNCH_TARGET:-lineage_alice-userdebug}"
BUILD_TARGET="${BUILD_TARGET:-bacon}"
JOBS="${JOBS:-$(nproc)}"
CCACHE_SIZE="${CCACHE_SIZE:-50G}"

MODE=docker
DO_SYNC=1
DO_SHELL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --workdir)     BUILDROOT="$2"; WORKDIR="$2/workspace"; CCACHE_DIR="$2/ccache"; shift 2 ;;
        --jobs)        JOBS="$2"; shift 2 ;;
        --ccache-size) CCACHE_SIZE="$2"; shift 2 ;;
        --target)      BUILD_TARGET="$2"; shift 2 ;;
        --native)      MODE=native; shift ;;
        --skip-sync)   DO_SYNC=0; shift ;;
        --shell)       DO_SHELL=1; shift ;;
        -h|--help)     sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)             echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- preflight --

echo "==> Preflight"

arch="$(uname -m)"
if [ "${arch}" != "x86_64" ]; then
    cat >&2 <<EOF
!! This host is ${arch}; AOSP 8.1 can only be built on x86_64.
   Every prebuilt toolchain in the tree (clang, gcc, and the host JDK) ships as
   an x86_64 ELF binary, so an arm64 machine such as a Raspberry Pi cannot run
   them regardless of how much disk or RAM it has.
EOF
    exit 1
fi

mkdir -p "${BUILDROOT}"

avail_kb="$(df -Pk "${BUILDROOT}" | awk 'NR==2 {print $4}')"
avail_gb=$(( avail_kb / 1024 / 1024 ))
echo "   disk free at ${BUILDROOT}: ${avail_gb} GB"
if [ "${avail_gb}" -lt 300 ]; then
    echo "   !! want >= 300 GB (source ~30, out ~60, ccache ${CCACHE_SIZE})" >&2
    [ "${avail_gb}" -lt 150 ] && { echo "!! under 150 GB, refusing to start" >&2; exit 1; }
    echo "   continuing anyway, but the build may run out of space"
fi

ram_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
echo "   RAM: ${ram_gb} GB, jobs: ${JOBS}"
if [ "${ram_gb}" -lt 16 ]; then
    echo "   !! under 16 GB; if the build gets OOM-killed, lower --jobs or add swap"
fi

for t in git curl python3; do
    command -v "${t}" >/dev/null || { echo "!! ${t} is required on the host" >&2; exit 1; }
done

if [ "${MODE}" = docker ]; then
    command -v docker >/dev/null || {
        echo "!! docker not found; install it or use --native" >&2; exit 1; }
    docker info >/dev/null 2>&1 || {
        echo "!! cannot talk to the docker daemon (is your user in the docker group?)" >&2
        exit 1; }
fi

if ! command -v repo >/dev/null; then
    echo "   installing repo into ${BUILDROOT}/bin"
    mkdir -p "${BUILDROOT}/bin"
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
        > "${BUILDROOT}/bin/repo"
    chmod a+x "${BUILDROOT}/bin/repo"
    export PATH="${BUILDROOT}/bin:${PATH}"
fi

# --------------------------------------------------------------------- sync --

if [ "${DO_SYNC}" -eq 1 ]; then
    echo "==> Syncing source (first run pulls ~30 GB)"
    WORKDIR="${WORKDIR}" JOBS="${JOBS}" bash "${SCRIPTDIR}/sync-source.sh"
else
    echo "==> Skipping sync"
    [ -d "${WORKDIR}/.repo" ] || { echo "!! no tree at ${WORKDIR}" >&2; exit 1; }
    # Patches are idempotent, so re-apply in case a manual repo sync reverted them.
    bash "${SCRIPTDIR}/apply-device-patches.sh" "${WORKDIR}/device/huawei/alice"
    bash "${SCRIPTDIR}/apply-alice-patcher.sh" "${WORKDIR}"
fi

# -------------------------------------------------------------------- build --

mkdir -p "${CCACHE_DIR}" "${BUILDROOT}/home"

if [ "${MODE}" = native ]; then
    echo "==> Building natively (host must have openjdk-8 and python2)"
    [ "${DO_SHELL}" -eq 1 ] && exec bash
    WORKDIR="${WORKDIR}" LUNCH_TARGET="${LUNCH_TARGET}" JOBS="${JOBS}" \
    CCACHE_DIR="${CCACHE_DIR}" CCACHE_SIZE="${CCACHE_SIZE}" \
    BUILD_TARGET="${BUILD_TARGET}" \
        bash "${SCRIPTDIR}/build-inner.sh"
else
    if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
        echo "==> Building ${IMAGE} (one time, a few minutes)"
        docker build -t "${IMAGE}" "${REPODIR}/docker"
    fi

    # Run as the invoking user so out/ and ccache do not end up root-owned.
    # HOME must be supplied explicitly because that uid has no passwd entry.
    docker_args=(
        --rm
        -v "${BUILDROOT}:${BUILDROOT}"
        -v "${REPODIR}:${REPODIR}:ro"
        -u "$(id -u):$(id -g)"
        -e HOME="${BUILDROOT}/home"
        -e WORKDIR="${WORKDIR}"
        -e CCACHE_DIR="${CCACHE_DIR}"
        -e CCACHE_SIZE="${CCACHE_SIZE}"
        -e LUNCH_TARGET="${LUNCH_TARGET}"
        -e BUILD_TARGET="${BUILD_TARGET}"
        -e JOBS="${JOBS}"
        -w "${WORKDIR}"
    )

    if [ "${DO_SHELL}" -eq 1 ]; then
        echo "==> Shell in ${IMAGE}"
        exec docker run -it "${docker_args[@]}" "${IMAGE}" bash
    fi

    echo "==> Building in ${IMAGE} (-j${JOBS})"
    docker run "${docker_args[@]}" "${IMAGE}" \
        bash "${SCRIPTDIR}/build-inner.sh"
fi

# ------------------------------------------------------------------- verify --

echo "==> Verifying against CAM-TL00 geometry"
zip="$(ls "${WORKDIR}"/out/target/product/alice/lineage-15.1-*.zip 2>/dev/null | head -1 || true)"
if [ -n "${zip}" ]; then
    python3 "${SCRIPTDIR}/verify-rom.py" \
        --product-out "${WORKDIR}/out/target/product/alice" --zip "${zip}"
    echo
    echo "ROM: ${zip}"
    echo "Flash with the alice TWRP (it reports ro.product.device=hi6210sft)."
    echo "Back up boot and recovery first; use Wipe -> Format Data from EMUI 6."
else
    python3 "${SCRIPTDIR}/verify-rom.py" \
        --product-out "${WORKDIR}/out/target/product/alice"
    echo "!! no ROM zip found" >&2
    exit 1
fi
