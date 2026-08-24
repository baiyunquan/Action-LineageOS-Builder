#!/usr/bin/env bash
# Download and extract a published multi-part archive on Huawei ECS.

set -Eeuo pipefail

BASE_URL="${BASE_URL:-https://extra.liaic.cyou/lineage-source}"
DEST="${DEST:-/work}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-${DEST}/lineage-transfer}"
DOWNLOAD_JOBS="${DOWNLOAD_JOBS:-8}"

die() { printf '!! %s\n' "$*" >&2; exit 1; }
command -v curl >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"
command -v zstd >/dev/null || die "zstd is required (apt install zstd)"
command -v tar >/dev/null || die "tar is required"
mkdir -p "${DOWNLOAD_DIR}" "${DEST}"
cd "${DOWNLOAD_DIR}"

curl -fL --retry 5 --retry-all-errors -O "${BASE_URL}/SHA256SUMS"
mapfile -t parts < <(awk '{print $2}' SHA256SUMS | sort -V)
(( ${#parts[@]} > 0 )) || die 'SHA256SUMS contains no parts'

printf '%s\n' "==> downloading ${#parts[@]} parts with ${DOWNLOAD_JOBS} parallel jobs"
export BASE_URL DOWNLOAD_DIR
printf '%s\0' "${parts[@]}" \
    | xargs -0 -r -n1 -P"${DOWNLOAD_JOBS}" bash -c '
        part="$1"
        curl -fL --retry 5 --retry-all-errors -o "$DOWNLOAD_DIR/$part" "$BASE_URL/$part"
    ' _

printf '%s\n' '==> verifying parts'
sha256sum -c SHA256SUMS

printf '%s\n' "==> extracting into ${DEST}"
cat "${DOWNLOAD_DIR}"/lineage15.1-source.tar.zst.part-* \
    | zstd -d -q \
    | tar --xattrs --acls -xpf - -C "${DEST}"
printf '%s\n' "Source extracted at ${DEST}/lineage15.1-source"
