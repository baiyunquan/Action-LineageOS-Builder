#!/usr/bin/env bash
# Stream a completed source tree directly to two VPSs as two nearly equal
# zstd volumes. No archive or volume is written to the local disk.
# shellcheck disable=SC2029  # remote command paths intentionally expand locally

set -Eeuo pipefail

SRC="${SRC:-/mnt/usb/lineage15.1-source}"
VPS1_HOST="${VPS1_HOST:-153.75.235.35}"
VPS1_DOMAIN="${VPS1_DOMAIN:-extra.liaic.cyou}"
VPS2_HOST="${VPS2_HOST:-74.50.72.148}"
VPS2_DOMAIN="${VPS2_DOMAIN:-liaic.cyou}"
VPS_PORT="${VPS_PORT:-50922}"
VPS_USER="${VPS_USER:-liaic}"
VPS1_STAGE_DIR="${VPS1_STAGE_DIR:-/home/liaic/lineage-upload}"
VPS2_STAGE_DIR="${VPS2_STAGE_DIR:-/home/liaic/lineage-upload}"
PART_PREFIX="${PART_PREFIX:-lineage15.1-source.tar.zst.part-}"
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"
RESERVE_GIB="${RESERVE_GIB:-2}"

die() { printf '!! %s\n' "$*" >&2; exit 1; }
command -v tar >/dev/null || die 'tar is required'
command -v zstd >/dev/null || die 'zstd is required (apt install zstd)'
command -v ssh >/dev/null || die 'ssh is required'
command -v split >/dev/null || die 'split is required'

[[ -d "${SRC}/.repo" ]] || die "not a repo checkout: ${SRC}"
if pgrep -af -- "${SRC}/.repo/repo/main.py" | grep -q '[[:space:]]sync'; then
    die 'repo sync is still running; wait before streaming the source'
fi

name="$(basename "${SRC}")"
base="$(dirname "${SRC}")"
ssh_opts=(-p "${VPS_PORT}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
target1="${VPS_USER}@${VPS1_HOST}"
target2="${VPS_USER}@${VPS2_HOST}"

remote_free_kib() {
    local target="$1"
    ssh "${ssh_opts[@]}" "${target}" \
        'command -v split >/dev/null &&
         df -Pk "$HOME" | awk "NR==2 {print \$4}"'
}

prepare_remote() {
    local target="$1" stage="$2"
    ssh "${ssh_opts[@]}" "${target}" \
        "mkdir -p -- '${stage}' &&
         if compgen -G '${stage}/${PART_PREFIX}*' >/dev/null; then
             echo 'remote stage already contains volume files' >&2; exit 2;
         fi"
}

printf '%s\n' '==> checking both remote VPSs'
free1_kib="$(remote_free_kib "${target1}")"
free2_kib="$(remote_free_kib "${target2}")"
[[ "${free1_kib}" =~ ^[0-9]+$ ]] || die "could not read free space on ${target1}"
[[ "${free2_kib}" =~ ^[0-9]+$ ]] || die "could not read free space on ${target2}"
prepare_remote "${target1}" "${VPS1_STAGE_DIR}"
prepare_remote "${target2}" "${VPS2_STAGE_DIR}"

printf '%s\n' '==> pass 1/2: measuring compressed stream (no local archive written)'
set -o pipefail
total_bytes="$(
    tar --sort=name --numeric-owner --xattrs --acls \
        -C "${base}" -cf - "${name}" \
        | zstd -T0 -"${ZSTD_LEVEL}" -q \
        | wc -c
)"
total_bytes="${total_bytes//[[:space:]]/}"
[[ "${total_bytes}" =~ ^[0-9]+$ && "${total_bytes}" -gt 0 ]] ||
    die 'compressed size measurement failed'

half_bytes=$(( (total_bytes + 1) / 2 ))
reserve_bytes=$(( RESERVE_GIB * 1024 * 1024 * 1024 ))
free1_bytes=$(( free1_kib * 1024 ))
free2_bytes=$(( free2_kib * 1024 ))
printf 'compressed_bytes=%s\nvolume0_max_bytes=%s\nvolume1_max_bytes=%s\n' \
    "${total_bytes}" "${half_bytes}" "${half_bytes}"
printf 'vps1_free_bytes=%s\nvps2_free_bytes=%s\n' \
    "${free1_bytes}" "${free2_bytes}"
(( free1_bytes >= half_bytes + reserve_bytes )) || die \
    "${target1} lacks space for volume 0 plus ${RESERVE_GIB} GiB reserve"
(( free2_bytes >= half_bytes + reserve_bytes )) || die \
    "${target2} lacks space for volume 1 plus ${RESERVE_GIB} GiB reserve"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lineage-two-volumes.XXXXXX")"
ssh1_pid=''
ssh2_pid=''
cleanup() {
    for pid in "${ssh1_pid}" "${ssh2_pid}"; do
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}" 2>/dev/null || true
        fi
    done
    [[ -z "${ssh1_pid}" ]] || wait "${ssh1_pid}" 2>/dev/null || true
    [[ -z "${ssh2_pid}" ]] || wait "${ssh2_pid}" 2>/dev/null || true
    find "${tmp_dir}" -mindepth 1 -maxdepth 1 -delete 2>/dev/null || true
    rmdir "${tmp_dir}" 2>/dev/null || true
}
trap cleanup EXIT
mkfifo "${tmp_dir}/part0" "${tmp_dir}/part1"

printf '%s\n' '==> pass 2/2: streaming volume 0 and volume 1 concurrently over SSH'
ssh "${ssh_opts[@]}" "${target1}" \
    "cat > '${VPS1_STAGE_DIR}/${PART_PREFIX}0'" < "${tmp_dir}/part0" &
ssh1_pid=$!
ssh "${ssh_opts[@]}" "${target2}" \
    "cat > '${VPS2_STAGE_DIR}/${PART_PREFIX}1'" < "${tmp_dir}/part1" &
ssh2_pid=$!

if ! tar --sort=name --numeric-owner --xattrs --acls \
    -C "${base}" -cf - "${name}" \
    | zstd -T0 -"${ZSTD_LEVEL}" -q \
    | split -b "${half_bytes}" -d -a 1 - "${tmp_dir}/part"; then
    wait "${ssh1_pid}" || true
    wait "${ssh2_pid}" || true
    die 'streaming pipeline failed'
fi
wait "${ssh1_pid}" || die "upload to ${target1} failed"
wait "${ssh2_pid}" || die "upload to ${target2} failed"

printf '%s\n' '==> two-volume stream transfer complete (SHA checks skipped)'
printf '%s\n' "VPS 1 stage: ${VPS1_STAGE_DIR}/${PART_PREFIX}0"
printf '%s\n' "VPS 2 stage: ${VPS2_STAGE_DIR}/${PART_PREFIX}1"
printf '%s\n' "After Nginx setup: https://${VPS1_DOMAIN}/lineage-source/${PART_PREFIX}0"
printf '%s\n' "After Nginx setup: https://${VPS2_DOMAIN}/lineage-source/${PART_PREFIX}1"
