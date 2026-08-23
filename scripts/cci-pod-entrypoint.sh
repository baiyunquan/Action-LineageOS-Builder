#!/usr/bin/env bash
# Entrypoint for the short-lived CCI2 build Pod.
# The Pod is intentionally self-contained: it clones the public GitHub builder,
# keeps all state under /workspace, and uploads durable state to private OBS
# before it exits. No source or credential is baked into the SWR image.

set -Eeuo pipefail

: "${GITHUB_REPO:?GITHUB_REPO is required}"
: "${GITHUB_REF:=main}"
: "${OBS_BUCKET:?OBS_BUCKET is required}"
: "${OBS_ACCESS_KEY:?OBS_ACCESS_KEY is required}"
: "${OBS_SECRET_KEY:?OBS_SECRET_KEY is required}"
: "${OBS_SECURITY_TOKEN:?OBS_SECURITY_TOKEN is required}"

RUN_ID="${RUN_ID:-cci-$(date -u +%Y%m%dT%H%M%SZ)}"
WORK_ROOT="${WORK_ROOT:-/workspace}"
SOURCE_DIR="${SOURCE_DIR:-${WORK_ROOT}/source}"
BUILDER_DIR="${BUILDER_DIR:-${WORK_ROOT}/builder}"
CCACHE_DIR="${CCACHE_DIR:-${WORK_ROOT}/ccache}"
OBS_ENDPOINT="${OBS_ENDPOINT:-https://obs.cn-southwest-2.myhuaweicloud.com}"
OBSUTIL_URL="${OBSUTIL_URL:-https://obs-community-intl.obs.ap-southeast-1.myhuaweicloud.com/obsutil/current/obsutil_linux_amd64.tar.gz}"
OBS_CONFIG="${WORK_ROOT}/.obsutilconfig"
LOG_FILE="${WORK_ROOT}/cci-build.log"

mkdir -p "${WORK_ROOT}" "${CCACHE_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

obs_upload() {
    local source="$1" destination="$2"
    "${WORK_ROOT}/obsutil" cp "${source}" "obs://${OBS_BUCKET}/${destination}" \
        -config="${OBS_CONFIG}" -u -f || echo "!! OBS upload failed: ${destination}" >&2
}

finish() {
    local rc=$?
    set +e
    echo "==> Uploading run state (exit ${rc})"
    if [ -x "${WORK_ROOT}/obsutil" ]; then
        obs_upload "${LOG_FILE}" "runs/${RUN_ID}/cci-build.log"
        if [ -d "${CCACHE_DIR}" ]; then
            "${WORK_ROOT}/obsutil" cp "${CCACHE_DIR}" \
                "obs://${OBS_BUCKET}/cache/${GITHUB_REPO}/" -r -u -f \
                -config="${OBS_CONFIG}" || true
        fi
        if [ "${rc}" -eq 0 ] && [ -d "${SOURCE_DIR}/out/target/product/alice" ]; then
            for artifact in \
                "${SOURCE_DIR}"/out/target/product/alice/lineage-15.1-*.zip \
                "${SOURCE_DIR}"/out/target/product/alice/boot.img \
                "${SOURCE_DIR}"/out/target/product/alice/recovery.img; do
                [ -f "${artifact}" ] || continue
                obs_upload "${artifact}" "runs/${RUN_ID}/artifacts/$(basename "${artifact}")"
            done
        fi
    fi
    rm -f "${OBS_CONFIG}"
    exit "${rc}"
}
trap finish EXIT

export DEBIAN_FRONTEND=noninteractive
echo "==> Installing CCI build bootstrap dependencies"
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl git git-lfs python3 \
    tar gzip rsync >/dev/null

echo "==> Installing obsutil"
curl -fsSL "${OBSUTIL_URL}" -o "${WORK_ROOT}/obsutil.tar.gz"
tar -xzf "${WORK_ROOT}/obsutil.tar.gz" -C "${WORK_ROOT}"
obsutil_binary="$(find "${WORK_ROOT}" -type f -name obsutil -perm -u+x -print -quit)"
[ -n "${obsutil_binary}" ] || { echo "!! obsutil binary not found" >&2; exit 1; }
cp "${obsutil_binary}" "${WORK_ROOT}/obsutil"
chmod 700 "${WORK_ROOT}/obsutil"
"${WORK_ROOT}/obsutil" config -config="${OBS_CONFIG}" -e="${OBS_ENDPOINT}" \
    -i="${OBS_ACCESS_KEY}" -k="${OBS_SECRET_KEY}" -t="${OBS_SECURITY_TOKEN}"
rm -f "${WORK_ROOT}/obsutil.tar.gz"

echo "==> Installing repo tool"
mkdir -p /usr/local/bin
curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
    -o /usr/local/bin/repo
chmod 755 /usr/local/bin/repo

echo "==> Cloning ${GITHUB_REPO}@${GITHUB_REF}"
rm -rf "${BUILDER_DIR}"
git clone --depth=1 --branch "${GITHUB_REF}" \
    "https://github.com/${GITHUB_REPO}.git" "${BUILDER_DIR}"

echo "==> Syncing LineageOS source"
export WORKDIR="${SOURCE_DIR}"
export GIT_NAME="${GIT_NAME:-CCI builder}"
export GIT_EMAIL="${GIT_EMAIL:-cci-builder@localhost}"
export JOBS="${JOBS:-$(nproc)}"
bash "${BUILDER_DIR}/scripts/sync-source.sh"

echo "==> Restoring ccache from OBS"
"${WORK_ROOT}/obsutil" cp "obs://${OBS_BUCKET}/cache/${GITHUB_REPO}/" \
    "${CCACHE_DIR}" -r -u -f -config="${OBS_CONFIG}" || true

echo "==> Building LineageOS inside the CCI Pod"
set +e
WORKDIR="${SOURCE_DIR}" CCACHE_DIR="${CCACHE_DIR}" \
    bash "${BUILDER_DIR}/scripts/build-in-container.sh"
build_rc=$?
set -e

if [ "${build_rc}" -eq 0 ]; then
    zip_file="$(find "${SOURCE_DIR}/out/target/product/alice" -maxdepth 1 \
        -type f -name 'lineage-15.1-*.zip' -print -quit)"
    if [ -z "${zip_file}" ]; then
        echo "!! build returned success but no ROM zip was found" >&2
        build_rc=1
    else
        python3 "${BUILDER_DIR}/scripts/verify-rom.py" \
            --product-out "${SOURCE_DIR}/out/target/product/alice" --zip "${zip_file}" || build_rc=$?
    fi
fi

echo "==> CCI build exit ${build_rc}"
exit "${build_rc}"
