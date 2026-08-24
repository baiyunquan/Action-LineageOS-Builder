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
#   ./scripts/build-local.sh --resume           reuse the last container/image checkpoint
#   ./scripts/build-local.sh --checkpoint-interval 15m
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
CHECKPOINT_ENABLE="${CHECKPOINT_ENABLE:-1}"
CHECKPOINT_INTERVAL="${CHECKPOINT_INTERVAL:-15m}"
CHECKPOINT_IMAGE="${CHECKPOINT_IMAGE:-}"
CONTAINER_NAME="${CONTAINER_NAME:-lineageos-15.1-build}"
RESUME=0

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
        --resume)      RESUME=1; shift ;;
        --checkpoint-interval) CHECKPOINT_INTERVAL="$2"; shift 2 ;;
        --checkpoint-image) CHECKPOINT_IMAGE="$2"; shift 2 ;;
        --container-name) CONTAINER_NAME="$2"; shift 2 ;;
        --no-checkpoint) CHECKPOINT_ENABLE=0; shift ;;
        -h|--help)     sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)             echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

CHECKPOINT_DIR="${CHECKPOINT_DIR:-${BUILDROOT}/checkpoints}"
CHECKPOINT_IMAGE="${CHECKPOINT_IMAGE:-${IMAGE}:checkpoint}"

if [ "${CHECKPOINT_ENABLE}" -eq 1 ] && [ -z "${CHECKPOINT_INTERVAL}" ]; then
    echo "!! --checkpoint-interval must not be empty" >&2
    exit 2
fi

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

mkdir -p "${BUILDROOT}" "${CHECKPOINT_DIR}"
printf '%s\n' 'driver-start' >"${CHECKPOINT_DIR}/current-stage"

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

    # mihomo listens on the host loopback. Use the host network namespace so
    # 127.0.0.1:7890 inside the build container resolves to that proxy rather
    # than to the container itself. Pass both proxy spellings because apt,
    # curl, git, and other tools do not all consult the same one.
    proxy_env=()
    for proxy_name in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
        http_proxy https_proxy all_proxy no_proxy; do
        proxy_value="${!proxy_name:-}"
        [ -n "${proxy_value}" ] && proxy_env+=( -e "${proxy_name}=${proxy_value}" )
    done
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
    BUILD_TARGET="${BUILD_TARGET}" CHECKPOINT_DIR="${CHECKPOINT_DIR}" \
        bash "${SCRIPTDIR}/build-inner.sh"
else
    if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
        echo "==> Building ${IMAGE} (one time, a few minutes)"
        docker_build_args=()
        for proxy_name in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
            http_proxy https_proxy all_proxy no_proxy; do
            proxy_value="${!proxy_name:-}"
            [ -n "${proxy_value}" ] && \
                docker_build_args+=( --build-arg "${proxy_name}=${proxy_value}" )
        done
        docker build --network host "${docker_build_args[@]}" \
            -t "${IMAGE}" "${REPODIR}/docker"
    fi

    # Docker 29 renamed the old --pause=false spelling to --no-pause.
    commit_help="$(docker commit --help 2>&1 || true)"
    if [[ "${commit_help}" == *'--no-pause'* ]]; then
        docker_commit_no_pause=(--no-pause)
    else
        docker_commit_no_pause=(--pause=false)
    fi

    checkpoint_pid=''
    checkpoint_active=0

    checkpoint_commit() {
        [ "${CHECKPOINT_ENABLE}" -eq 1 ] || return 0
        docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1 || return 0

        local stage='unknown'
        local timestamp
        if [ -r "${CHECKPOINT_DIR}/current-stage" ]; then
            stage="$(head -n 1 "${CHECKPOINT_DIR}/current-stage")"
        fi
        # Stage text is written into a Docker LABEL; keep it bounded and safe.
        stage="${stage//[^[:alnum:]_.-]/_}"
        stage="${stage:0:64}"
        timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

        echo "==> Committing Docker checkpoint (${stage}) as ${CHECKPOINT_IMAGE}"
        if docker commit "${docker_commit_no_pause[@]}" \
            --change "LABEL com.liaic.lineage.checkpoint=${stage}" \
            "${CONTAINER_NAME}" "${CHECKPOINT_IMAGE}" >/dev/null; then
            printf '%s\t%s\t%s\n' "${timestamp}" "${stage}" "${CHECKPOINT_IMAGE}" \
                >> "${CHECKPOINT_DIR}/commits.log"
        else
            echo "!! Docker checkpoint commit failed; bind-mounted build state is still on disk" >&2
            return 1
        fi
    }

    checkpoint_loop() {
        while :; do
            sleep "${CHECKPOINT_INTERVAL}" || return 0
            local running
            running="$(docker inspect --format '{{.State.Running}}' \
                "${CONTAINER_NAME}" 2>/dev/null || true)"
            [ "${running}" = true ] || return 0
            checkpoint_commit || true
        done
    }

    start_checkpoint_monitor() {
        [ "${CHECKPOINT_ENABLE}" -eq 1 ] || return 0
        checkpoint_loop &
        checkpoint_pid=$!
    }

    stop_checkpoint_monitor() {
        [ -n "${checkpoint_pid}" ] || return 0
        kill "${checkpoint_pid}" 2>/dev/null || true
        wait "${checkpoint_pid}" 2>/dev/null || true
        checkpoint_pid=''
    }

    checkpoint_cleanup() {
        stop_checkpoint_monitor
        if [ "${checkpoint_active}" -eq 1 ]; then
            checkpoint_commit || true
            checkpoint_active=0
        fi
    }

    trap checkpoint_cleanup EXIT

    container_exists=0
    container_running=false
    if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        container_exists=1
        container_running="$(docker inspect --format '{{.State.Running}}' \
            "${CONTAINER_NAME}")"
    fi
    if [ "${container_exists}" -eq 1 ] && [ "${RESUME}" -ne 1 ]; then
        echo "!! container ${CONTAINER_NAME} already exists; use --resume or remove it explicitly" >&2
        exit 2
    fi
    if [ "${container_running}" = true ]; then
        echo "!! container ${CONTAINER_NAME} is already running; stop/inspect it before resuming" >&2
        exit 2
    fi

    run_image="${IMAGE}"
    if [ "${RESUME}" -eq 1 ] && [ "${container_exists}" -eq 0 ] \
        && [ "${CHECKPOINT_ENABLE}" -eq 1 ] \
        && docker image inspect "${CHECKPOINT_IMAGE}" >/dev/null 2>&1; then
        run_image="${CHECKPOINT_IMAGE}"
        echo "==> Resuming from Docker image ${run_image}; mounted out/ and ccache remain on disk"
    fi

    # Docker 29 renamed the old --pause=false spelling to --no-pause.
    commit_help="$(docker commit --help 2>&1 || true)"
    if [[ "${commit_help}" == *'--no-pause'* ]]; then
        docker_commit_no_pause=(--no-pause)
    else
        docker_commit_no_pause=(--pause=false)
    fi

    checkpoint_pid=''
    checkpoint_active=0

    checkpoint_commit() {
        [ "${CHECKPOINT_ENABLE}" -eq 1 ] || return 0
        docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1 || return 0

        local stage='unknown'
        local timestamp
        if [ -r "${CHECKPOINT_DIR}/current-stage" ]; then
            stage="$(head -n 1 "${CHECKPOINT_DIR}/current-stage")"
        fi
        # Stage text is written into a Docker LABEL; keep it bounded and safe.
        stage="${stage//[^[:alnum:]_.-]/_}"
        stage="${stage:0:64}"
        timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

        echo "==> Committing Docker checkpoint (${stage}) as ${CHECKPOINT_IMAGE}"
        if docker commit "${docker_commit_no_pause[@]}" \
            --change "LABEL com.liaic.lineage.checkpoint=${stage}" \
            "${CONTAINER_NAME}" "${CHECKPOINT_IMAGE}" >/dev/null; then
            printf '%s\t%s\t%s\n' "${timestamp}" "${stage}" "${CHECKPOINT_IMAGE}" \
                >> "${CHECKPOINT_DIR}/commits.log"
        else
            echo "!! Docker checkpoint commit failed; bind-mounted build state is still on disk" >&2
            return 1
        fi
    }

    checkpoint_loop() {
        while :; do
            sleep "${CHECKPOINT_INTERVAL}" || return 0
            local running
            running="$(docker inspect --format '{{.State.Running}}' \
                "${CONTAINER_NAME}" 2>/dev/null || true)"
            [ "${running}" = true ] || return 0
            checkpoint_commit || true
        done
    }

    start_checkpoint_monitor() {
        [ "${CHECKPOINT_ENABLE}" -eq 1 ] || return 0
        checkpoint_loop &
        checkpoint_pid=$!
    }

    stop_checkpoint_monitor() {
        [ -n "${checkpoint_pid}" ] || return 0
        kill "${checkpoint_pid}" 2>/dev/null || true
        wait "${checkpoint_pid}" 2>/dev/null || true
        checkpoint_pid=''
    }

    checkpoint_cleanup() {
        stop_checkpoint_monitor
        if [ "${checkpoint_active}" -eq 1 ]; then
            checkpoint_commit || true
            checkpoint_active=0
        fi
    }

    trap checkpoint_cleanup EXIT

    container_exists=0
    container_running=false
    if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        container_exists=1
        container_running="$(docker inspect --format '{{.State.Running}}' \
            "${CONTAINER_NAME}")"
    fi
    if [ "${container_exists}" -eq 1 ] && [ "${RESUME}" -ne 1 ]; then
        echo "!! container ${CONTAINER_NAME} already exists; use --resume or remove it explicitly" >&2
        exit 2
    fi
    if [ "${container_running}" = true ]; then
        echo "!! container ${CONTAINER_NAME} is already running; stop/inspect it before resuming" >&2
        exit 2
    fi

    run_image="${IMAGE}"
    if [ "${RESUME}" -eq 1 ] && [ "${container_exists}" -eq 0 ] \
        && [ "${CHECKPOINT_ENABLE}" -eq 1 ] \
        && docker image inspect "${CHECKPOINT_IMAGE}" >/dev/null 2>&1; then
        run_image="${CHECKPOINT_IMAGE}"
        echo "==> Resuming from Docker image ${run_image}; mounted out/ and ccache remain on disk"
    fi

    # Run as the invoking user so out/ and ccache do not end up root-owned.
    # HOME must be supplied explicitly because that uid has no passwd entry.
    docker_args=(
        --name "${CONTAINER_NAME}"
        --label "com.liaic.lineage.build=15.1"
        --network host
        -v "${BUILDROOT}:${BUILDROOT}"
        -v "${REPODIR}:${REPODIR}:ro"
        -u "$(id -u):$(id -g)"
        -e HOME="${BUILDROOT}/home"
        -e WORKDIR="${WORKDIR}"
        -e CHECKPOINT_DIR="${CHECKPOINT_DIR}"
        -e CCACHE_DIR="${CCACHE_DIR}"
        -e CCACHE_SIZE="${CCACHE_SIZE}"
        -e LUNCH_TARGET="${LUNCH_TARGET}"
        -e BUILD_TARGET="${BUILD_TARGET}"
        -e JOBS="${JOBS}"
        -w "${WORKDIR}"
    )
    docker_args+=( "${proxy_env[@]}" )
    case "${CHECKPOINT_DIR}" in
        "${BUILDROOT}"/*) ;;
        *) docker_args+=( -v "${CHECKPOINT_DIR}:${CHECKPOINT_DIR}" ) ;;
    esac

    if [ "${DO_SHELL}" -eq 1 ]; then
        if [ "${container_exists}" -eq 1 ]; then
            echo "==> Resuming interactive shell in ${CONTAINER_NAME}"
            exec docker start -ai "${CONTAINER_NAME}"
        fi
        echo "==> Shell in ${run_image}"
        exec docker run -it "${docker_args[@]}" "${run_image}" bash
    fi

    build_rc=0
    if [ "${container_exists}" -eq 1 ]; then
        echo "==> Resuming stopped container ${CONTAINER_NAME}"
        checkpoint_active=1
        start_checkpoint_monitor
        set +e
        docker start -a "${CONTAINER_NAME}"
        build_rc=$?
        set -e
    else
        echo "==> Building in ${run_image} (-j${JOBS}); container is kept for resume"
        checkpoint_active=1
        start_checkpoint_monitor
        set +e
        docker run "${docker_args[@]}" "${run_image}" \
            bash "${SCRIPTDIR}/build-inner.sh"
        build_rc=$?
        set -e
    fi
    stop_checkpoint_monitor
    checkpoint_commit || true
    checkpoint_active=0

    if [ "${build_rc}" -ne 0 ]; then
        echo "!! build stopped with exit ${build_rc}; state was kept in ${CONTAINER_NAME}" >&2
        echo "   resume: $0 --workdir '${BUILDROOT}' --skip-sync --resume" >&2
        exit "${build_rc}"
    fi
fi

# ------------------------------------------------------------------- verify --

echo "==> Verifying against CAM-TL00 geometry"
zip="$(ls "${WORKDIR}"/out/target/product/alice/lineage-15.1-*.zip 2>/dev/null | head -1 || true)"
target_files="$(find "${WORKDIR}/out/target/product/alice/obj/PACKAGING/target_files_intermediates" \
    -maxdepth 1 -type f -name '*-target_files-*.zip' -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -1 | cut -d' ' -f2- || true)"
if [ -n "${zip}" ]; then
    verify_args=(
        --product-out "${WORKDIR}/out/target/product/alice"
        --zip "${zip}"
    )
    [ -n "${target_files}" ] && verify_args+=( --target-files "${target_files}" )
    python3 "${SCRIPTDIR}/verify-rom.py" "${verify_args[@]}"
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
