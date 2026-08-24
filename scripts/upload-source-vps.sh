#!/usr/bin/env bash
# Upload package parts to the US VPS. The VPS user only receives a staging
# copy; a one-time root step publishes it through Nginx.

set -Eeuo pipefail

PKG_DIR="${PKG_DIR:-/mnt/usb/lineage15.1-transfer}"
VPS_HOST="${VPS_HOST:-153.75.235.35}"
VPS_PORT="${VPS_PORT:-50922}"
VPS_USER="${VPS_USER:-liaic}"
VPS_STAGE_DIR="${VPS_STAGE_DIR:-/home/liaic/lineage-upload}"
UPLOAD_JOBS="${UPLOAD_JOBS:-4}"

die() { printf '!! %s\n' "$*" >&2; exit 1; }
command -v ssh >/dev/null || die "ssh is required"
command -v scp >/dev/null || die "scp is required"
[[ -f "${PKG_DIR}/SHA256SUMS" ]] || die "missing ${PKG_DIR}/SHA256SUMS"
mapfile -t parts < <(awk '{print $2}' "${PKG_DIR}/SHA256SUMS" | sort -V)
(( ${#parts[@]} > 0 )) || die "SHA256SUMS contains no archive parts"

ssh_opts=(-p "${VPS_PORT}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
target="${VPS_USER}@${VPS_HOST}"

printf '%s\n' "==> preparing ${target}:${VPS_STAGE_DIR}"
ssh "${ssh_opts[@]}" "${target}" "mkdir -p -- '${VPS_STAGE_DIR}'"

printf '%s\n' "==> uploading ${#parts[@]} parts with ${UPLOAD_JOBS} parallel jobs"
export PKG_DIR VPS_HOST VPS_PORT VPS_USER VPS_STAGE_DIR
printf '%s\0' "${parts[@]}" \
    | xargs -0 -r -n1 -P"${UPLOAD_JOBS}" bash -c '
        file="$1"
        scp -q -o BatchMode=yes -o StrictHostKeyChecking=accept-new -P "$VPS_PORT" \
            "$PKG_DIR/$file" "$VPS_USER@$VPS_HOST:$VPS_STAGE_DIR/$file"
    ' _

scp "${ssh_opts[@]}" "${PKG_DIR}/SHA256SUMS" "${target}:${VPS_STAGE_DIR}/SHA256SUMS"
[[ ! -f "${PKG_DIR}/SOURCE-METADATA" ]] || \
    scp "${ssh_opts[@]}" "${PKG_DIR}/SOURCE-METADATA" "${target}:${VPS_STAGE_DIR}/SOURCE-METADATA"

printf '%s\n' '==> remote checksum verification'
ssh "${ssh_opts[@]}" "${target}" \
    "cd '${VPS_STAGE_DIR}' && sha256sum -c SHA256SUMS"
printf '%s\n' 'Upload complete. Run install-vps-download-location.sh as root on the VPS.'
