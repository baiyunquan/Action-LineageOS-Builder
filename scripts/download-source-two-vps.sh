#!/usr/bin/env bash
# Download two source volumes concurrently from two VPSs, verify each one,
# concatenate them in order, and extract the zstd tar stream.

set -Eeuo pipefail

PART0_URL="${PART0_URL:-https://extra.liaic.cyou/lineage-source/lineage15.1-source.tar.zst.part-0}"
PART1_URL="${PART1_URL:-https://liaic.cyou/lineage-source/lineage15.1-source.tar.zst.part-1}"
DEST="${DEST:-/work}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/work/lineage-transfer}"
PART_PREFIX="${PART_PREFIX:-lineage15.1-source.tar.zst.part-}"
SOURCE_NAME="${SOURCE_NAME:-lineage15.1-source}"
CURL_RETRY="${CURL_RETRY:-3}"
KEEP_PARTS="${KEEP_PARTS:-1}"

die() { printf '!! %s\n' "$*" >&2; exit 1; }
command -v curl >/dev/null || die 'curl is required'
command -v zstd >/dev/null || die 'zstd is required'
command -v tar >/dev/null || die 'tar is required'

mkdir -p -- "${DOWNLOAD_DIR}" "${DEST}"
part0="${DOWNLOAD_DIR}/${PART_PREFIX}0"
part1="${DOWNLOAD_DIR}/${PART_PREFIX}1"

download_one() {
    local url="$1" output="$2"
    local status=0
    curl --fail --location --retry "${CURL_RETRY}" --connect-timeout 20 \
        --continue-at - --show-error --output "${output}" "${url}" || status=$?
    # A complete local file can make an HTTP server answer 416 to the final
    # range request; treat that as complete and let extraction validate it.
    (( status == 0 || status == 33 )) || return "${status}"
}

printf '%s\n' '==> downloading both volumes concurrently'
download_one "${PART0_URL}" "${part0}" &
pid0=$!
download_one "${PART1_URL}" "${part1}" &
pid1=$!
status=0
wait "${pid0}" || status=1
wait "${pid1}" || status=1
(( status == 0 )) || die 'one or more volume downloads failed'

[[ -s "${part0}" && -s "${part1}" ]] || die 'downloaded volume is empty'
[[ ! -e "${DEST}/${SOURCE_NAME}" ]] || die \
    "destination already exists: ${DEST}/${SOURCE_NAME} (choose another DEST or remove it)"

printf '%s\n' '==> concatenating volume 0 then volume 1 and extracting'
set -o pipefail
cat "${part0}" "${part1}" | zstd -T0 -d -q | tar --xattrs --acls -xpf - -C "${DEST}"

printf '%s\n' "extracted: ${DEST}/${SOURCE_NAME}"
if [[ "${KEEP_PARTS}" != 0 ]]; then
    printf '%s\n' "download volumes retained in: ${DOWNLOAD_DIR}"
else
    rm -f -- "${part0}" "${part1}"
    printf '%s\n' "download volumes removed from: ${DOWNLOAD_DIR}"
fi
