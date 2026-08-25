#!/usr/bin/env bash
# Apply all local CAM-TL00/Lineage compatibility patches to a synced tree.
#
# This is intentionally separate from sync-source.sh. The CI workflow caches
# the pristine repo checkout before this script runs, then restores that cache
# and applies the patches again on the next build.

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${1:-${WORKDIR:-}}"
[ -n "${WORKDIR}" ] || { echo "!! usage: $0 WORKDIR" >&2; exit 2; }
WORKDIR="$(cd "${WORKDIR}" && pwd)"

[ -d "${WORKDIR}/.repo" ] || {
    echo "!! ${WORKDIR} is not a repo checkout; run sync-source.sh first" >&2
    exit 1
}

echo "==> Applying CAM-TL00 device/kernel/vendor patches"
bash "${SCRIPTDIR}/apply-device-patches.sh" "${WORKDIR}/device/huawei/alice"

echo "==> Applying alice_patcher compatibility patches"
bash "${SCRIPTDIR}/apply-alice-patcher.sh" "${WORKDIR}"

# Verify the post-patch source that PRODUCT_COPY_FILES will actually consume.
# In particular this rejects the historical Android 6 stock RIL replacement and
# confirms the hi1101 B302 firmware patch is present.
python3 "${SCRIPTDIR}/verify-vendor-blobs.py" --source-root "${WORKDIR}"

echo "==> Patched source tree ready at ${WORKDIR}"
