#!/usr/bin/env bash
#
# Sync the LineageOS 15.1 tree and prepare it for a CAM-TL00 build.
#
# Runs on the GitHub Actions HOST (ubuntu-22.04), not inside the build
# container: repo needs a modern python3, while the compiler needs an old
# userland. Splitting them avoids fighting repo on python3.6.
#
# Safe to re-run -- resumed CI jobs call this again before continuing the build.

set -euo pipefail

WORKDIR="${WORKDIR:-${PWD}/workspace}"
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPODIR="$(cd "${SCRIPTDIR}/.." && pwd)"
MANIFEST_BRANCH="${MANIFEST_BRANCH:-lineage-15.1}"
JOBS="${JOBS:-$(nproc)}"

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# LineageOS 15.1-era manifests still reference git:// URLs. GitHub turned off the
# git protocol in 2022, so without this rewrite repo sync fails outright.
git config --global url."https://github.com/".insteadOf "git://github.com/"
git config --global url."https://".insteadOf "git://"
git config --global user.name  "${GIT_NAME:-CAM-TL00 builder}"
git config --global user.email "${GIT_EMAIL:-builder@localhost}"
git config --global color.ui false
git config --global advice.detachedHead false

if [ ! -d .repo ]; then
    echo "==> repo init (${MANIFEST_BRANCH})"
    repo init --depth=1 --no-repo-verify \
        -u https://github.com/LineageOS/android.git -b "${MANIFEST_BRANCH}"
else
    echo "==> .repo already present, reusing"
fi

echo "==> Installing local manifest"
mkdir -p .repo/local_manifests
cp "${REPODIR}/local_manifests/alice.xml" .repo/local_manifests/alice.xml

echo "==> repo sync (this is the long part on a cold run)"
repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune \
    --force-sync -j"${JOBS}"

# Fail early and loudly rather than 40 minutes into a compile.
echo "==> Checking required projects"
missing=0
for d in device/huawei/alice vendor/huawei/alice kernel/huawei/alice alice_patcher \
         frameworks/base frameworks/native frameworks/opt/telephony \
         packages/apps/Camera2 packages/services/Telephony vendor/lineage; do
    if [ -d "${d}" ]; then
        echo "   ok   ${d}"
    else
        echo "   MISSING ${d}" >&2
        missing=1
    fi
done
[ "${missing}" -eq 0 ] || { echo "!! repo sync incomplete" >&2; exit 1; }

# The kernel must be the 15.1 branch. The copy under ../references/ is cm-14.1
# and would silently produce a Nougat-era kernel inside an 8.1 ROM.
echo "==> Kernel branch check"
kver="$(grep -m1 '^SUBLEVEL' kernel/huawei/alice/Makefile | tr -dc '0-9')"
echo "   kernel 3.10.${kver}"

bash "${SCRIPTDIR}/apply-device-patches.sh" device/huawei/alice
bash "${SCRIPTDIR}/apply-alice-patcher.sh" "${WORKDIR}"

echo "==> Source tree ready at ${WORKDIR}"
