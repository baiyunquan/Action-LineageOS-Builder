#!/usr/bin/env bash
#
# Idempotent replacement for alice_patcher/patches.sh.
#
# Upstream patches.sh cannot be re-run: it uses bare `patch -p1` (which prompts
# "Assume -R?" interactively once a patch is already applied) and a
# `git cherry-pick` of a third-party commit. A GitHub Actions build of
# LineageOS 15.1 will almost certainly need 2-3 resumed runs, so every step here
# detects the already-applied state and skips instead of failing.
#
# It applies the same set of changes as upstream, from the same patch files.

set -euo pipefail

ROOTDIR="${1:-$PWD}"
PATCHDIR="${ROOTDIR}/alice_patcher/patches"

cd "${ROOTDIR}"
[ -d "${PATCHDIR}" ] || { echo "!! ${PATCHDIR} not found -- is alice_patcher synced?" >&2; exit 1; }

# Stamps survive across resumed CI runs and are the authoritative record of what
# has already been applied. They matter because the patch(1) fallback below runs
# with fuzz: a patch that only applies fuzzily may NOT reverse-check cleanly, so
# without a stamp a resumed run could re-apply it at a shifted offset and
# silently duplicate the change.
STAMPDIR="${ROOTDIR}/.alice_patches_applied"
mkdir -p "${STAMPDIR}"

applied=0; skipped=0; failed=0

# Apply one patch into one git repo, tolerating the already-applied case.
apply_patch() {
    local repo="$1" patch="$2"
    local name; name="$(basename "${patch}")"
    local stamp="${STAMPDIR}/$(echo "${repo}" | tr '/' '_')__${name}"

    if [ -f "${stamp}" ]; then
        echo "   skip ${repo}: ${name} (stamped)"
        skipped=$((skipped+1)); return
    fi
    if [ ! -d "${ROOTDIR}/${repo}" ]; then
        echo "   FAIL ${repo} -- repo missing" >&2; failed=$((failed+1)); return
    fi
    if [ ! -f "${patch}" ]; then
        echo "   FAIL ${name} -- patch file missing" >&2; failed=$((failed+1)); return
    fi

    cd "${ROOTDIR}/${repo}"

    # Already applied? (patch reverses cleanly => it is in the tree)
    if git apply -R --check -p1 "${patch}" 2>/dev/null; then
        echo "   skip ${repo}: ${name} (already applied)"
        touch "${stamp}"; skipped=$((skipped+1)); cd "${ROOTDIR}"; return
    fi

    # Strict apply first.
    if git apply --check -p1 "${patch}" 2>/dev/null; then
        git apply -p1 "${patch}"
        echo "   ok   ${repo}: ${name}"
        touch "${stamp}"; applied=$((applied+1)); cd "${ROOTDIR}"; return
    fi

    # Fall back to patch(1), which tolerates offsets/fuzz that git apply rejects.
    # --forward makes an already-applied patch a skip rather than a prompt.
    if patch -p1 --forward --batch --reject-file=- --no-backup-if-mismatch \
             < "${patch}" >/tmp/patch.log 2>&1; then
        echo "   ok   ${repo}: ${name} (fuzzy)"
        touch "${stamp}"; applied=$((applied+1))
    elif grep -qiE "previously applied|Reversed .*patch detected" /tmp/patch.log; then
        echo "   skip ${repo}: ${name} (already applied)"
        touch "${stamp}"; skipped=$((skipped+1))
    else
        echo "   FAIL ${repo}: ${name}" >&2
        sed 's/^/        /' /tmp/patch.log >&2
        failed=$((failed+1))
    fi
    cd "${ROOTDIR}"
}

echo "==> Applying alice_patcher patches"
apply_patch frameworks/base              "${PATCHDIR}/frameworks/base/0001-Disable-vendor-mismatch-warning.patch"
apply_patch frameworks/native            "${PATCHDIR}/frameworks/native/0001-surfaceflinger-Fix-deep-sleep-issue.patch"
apply_patch frameworks/opt/telephony     "${PATCHDIR}/frameworks/opt/telephony/0001-telephony-fix-2g-2g-4g-switch.patch"
apply_patch frameworks/opt/telephony     "${PATCHDIR}/frameworks/opt/telephony/0002-Telephony-Don-not-call-onUssdRelease-for-Huawei-RIL.patch"
apply_patch frameworks/opt/telephony     "${PATCHDIR}/frameworks/opt/telephony/0003-Make-better-signal-levels-on-Huawei-devices.patch"
apply_patch packages/apps/Camera2        "${PATCHDIR}/packages/apps/Camera2/0001-Fix-flashlight-delay.patch"
apply_patch packages/services/Telephony  "${PATCHDIR}/packages/services/Telephony/0001-Telephony-Support-muting-by-RIL-command.patch"

# Upstream cherry-picks DarkJoker360/android_vendor_lineage ffaaece ("prebuilt:
# Drop lineage-radio.rc"), which only deletes one file. Doing the deletion
# directly is idempotent and avoids fetching a third-party repo at build time.
# The file stops radio services that should stay running on Huawei RIL --
# telephony is a confirmed-working feature on this phone's LineageOS 14.1, so
# this must not be skipped.
echo "==> Dropping vendor/lineage lineage-radio.rc"
RADIO_RC="${ROOTDIR}/vendor/lineage/prebuilt/common/etc/init/lineage-radio.rc"
if [ -f "${RADIO_RC}" ]; then
    rm -f "${RADIO_RC}"
    echo "   ok   removed lineage-radio.rc"
    applied=$((applied+1))
else
    echo "   skip lineage-radio.rc (already gone)"
    skipped=$((skipped+1))
fi

echo "==> Patch summary: ${applied} applied, ${skipped} skipped, ${failed} failed"
[ "${failed}" -eq 0 ] || { echo "!! patching failed -- do not trust this build" >&2; exit 1; }
