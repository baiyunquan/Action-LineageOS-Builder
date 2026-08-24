#!/usr/bin/env bash
# Package a completed repo sync as a multi-part, multi-threaded zstd archive.
# This script deliberately refuses to run while repo sync is active.

set -Eeuo pipefail

SRC="${SRC:-/mnt/usb/lineage15.1-source}"
OUT="${OUT:-/mnt/usb/lineage15.1-transfer}"
PART_SIZE="${PART_SIZE:-2G}"
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"

die() { printf '!! %s\n' "$*" >&2; exit 1; }

[[ -d "${SRC}/.repo" ]] || die "not a repo checkout: ${SRC}"
if pgrep -af -- "${SRC}/.repo/repo/main.py" | grep -q '[[:space:]]sync'; then
    die "repo sync is still running; wait for it to finish before packaging"
fi
command -v tar >/dev/null || die "tar is required"
command -v zstd >/dev/null || die "zstd is required (apt install zstd)"
command -v split >/dev/null || die "split is required"
command -v sha256sum >/dev/null || die "sha256sum is required"

mkdir -p "${OUT}"
if compgen -G "${OUT}/lineage15.1-source.tar.zst.part-*" >/dev/null; then
    die "output already contains archive parts: ${OUT} (choose another OUT or remove old output)"
fi

name="$(basename "${SRC}")"
base="$(dirname "${SRC}")"
archive_prefix="${OUT}/${name}.tar.zst.part-"

printf '%s\n' "==> source: ${SRC}" "==> output: ${OUT}" \
    "==> part size: ${PART_SIZE}; zstd threads: all; level: ${ZSTD_LEVEL}"
printf '%s\n' '==> creating archive (no build is run)'

# Keep .repo, Git metadata, local manifests, and LFS objects: the destination
# ECS must be able to resume/use the checkout without another repo sync.
set -o pipefail
tar --sort=name --numeric-owner --xattrs --acls \
    -C "${base}" -cf - "${name}" \
    | zstd -T0 -"${ZSTD_LEVEL}" -q \
    | split --numeric-suffixes=0 -d -a 5 -b "${PART_SIZE}" - "${archive_prefix}"

(
    cd "${OUT}"
    sha256sum "${name}".tar.zst.part-* > SHA256SUMS
    printf 'source=%s\n' "${SRC}" > SOURCE-METADATA
    printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> SOURCE-METADATA
    printf 'part_size=%s\n' "${PART_SIZE}" >> SOURCE-METADATA
    printf 'zstd_level=%s\n' "${ZSTD_LEVEL}" >> SOURCE-METADATA
)

printf '%s\n' '==> testing concatenated zstd stream'
cat "${OUT}"/"${name}.tar.zst.part-"* | zstd -t -q
printf '%s\n' '==> package ready'
du -sh "${OUT}"
printf '%s\n' "checksum: ${OUT}/SHA256SUMS"
