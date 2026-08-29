#!/usr/bin/env bash
#
# Adapt the upstream `alice` (P8 Lite) LineageOS 15.1 device tree for CAM-TL00.
#
# Only three values need to change -- everything else in BoardConfig.mk was
# verified byte-for-byte against the CAM-TL00 backup (boot load addresses,
# system/boot/recovery/cache partition sizes, the 15 hardcoded mmcblk0pNN
# entries in rootdir/fstab.hi6210sft, WiFi, shims, sepolicy).
#
# Rewrites whole lines, so it is idempotent: safe to re-run on a resumed CI job.

set -euo pipefail

DEVICE_TREE="${1:-device/huawei/alice}"
BOARD_CONFIG="${DEVICE_TREE}/BoardConfig.mk"
ROOTDIR="$(cd "${DEVICE_TREE}/../../.." && pwd)"
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHDIR="$(cd "${SCRIPTDIR}/../patches" && pwd)"

[ -f "${BOARD_CONFIG}" ] || { echo "!! ${BOARD_CONFIG} not found" >&2; exit 1; }

# Apply source-level fixes that cannot be expressed as BoardConfig values.
# These are kept as patches in the builder repository so a fresh repo sync and
# a resumed local build produce the same device/vendor trees.
apply_source_patch() {
    local repo="$1" patch_file="$2" name repo_dir check_log
    name="$(basename "${patch_file}")"
    repo_dir="${ROOTDIR}/${repo}"

    [ -d "${repo_dir}" ] || { echo "!! source repo missing: ${repo_dir}" >&2; return 1; }
    [ -f "${patch_file}" ] || { echo "!! source patch missing: ${patch_file}" >&2; return 1; }

    # Keep the failed check output.  The old implementation discarded it,
    # leaving Actions with only "cannot apply" and making a binary blob
    # mismatch indistinguishable from a wrong source revision.
    check_log="$(mktemp)"
    if git -c "safe.directory=${repo_dir}" -C "${repo_dir}" \
            apply -R --check -p1 "${patch_file}" >"${check_log}" 2>&1; then
        rm -f "${check_log}"
        echo "   skip ${repo}: ${name} (already applied)"
        return 0
    fi

    if git -c "safe.directory=${repo_dir}" -C "${repo_dir}" \
            apply --check -p1 "${patch_file}" >"${check_log}" 2>&1; then
        git -c "safe.directory=${repo_dir}" -C "${repo_dir}" \
            apply -p1 "${patch_file}"
        rm -f "${check_log}"
        echo "   ok   ${repo}: ${name}"
        return 0
    fi

    echo "!! cannot apply ${repo}: ${name}" >&2
    sed 's/^/        /' "${check_log}" >&2
    rm -f "${check_log}"
    return 1
}

apply_source_patch device/huawei/alice \
    "${PATCHDIR}/device-huawei-alice/0001-wifi-ril-compat.patch"
apply_source_patch device/huawei/alice \
    "${PATCHDIR}/device-huawei-alice/0002-disable-unsupported-hi1101-ht.patch"
apply_source_patch kernel/huawei/alice \
    "${PATCHDIR}/kernel-huawei-alice/0001-enable-tcpmss-for-hisi-tethering.patch"
apply_source_patch kernel/huawei/alice \
    "${PATCHDIR}/kernel-huawei-alice/0002-hi1101-export-assoc-req-ies.patch"
apply_source_patch kernel/huawei/alice \
    "${PATCHDIR}/kernel-huawei-alice/0003-hi1101-ap-init-readiness.patch"
apply_source_patch kernel/huawei/alice \
    "${PATCHDIR}/kernel-huawei-alice/0004-hi1101-assoc-req-before-stats.patch"
apply_source_patch kernel/huawei/alice \
    "${PATCHDIR}/kernel-huawei-alice/0005-hi1101-assoc-req-debug.patch"
apply_source_patch vendor/huawei/alice \
    "${PATCHDIR}/vendor-huawei-alice/0001-hi1101-b302-firmware.patch"

# The framework property is intentionally left at its Android convention
# (`persist.radio.sim_slot_cfg=0,1`).  The pinned Android 8.1 RIL's
# sync_sim_slot_cfg branch used that string verbatim as AT^SIMSLOT=0,1, while
# the modem and the original EMUI RIL use the one-based AT pair 1,2.  Patch
# all verified SIMSLOT command paths after the vendor checkout is present; the
# script verifies the exact RIL SHA and instruction bytes before changing it.
for ril_blob in \
    "${ROOTDIR}/vendor/huawei/alice/proprietary/lib64/libbalong-ril.so" \
    "${ROOTDIR}/vendor/huawei/alice/proprietary/vendor/lib64/libbalong-ril.so"; do
    python3 "${SCRIPTDIR}/patch-ril-simslot.py" "${ril_blob}"
done

# The two Android 8.1 rild processes must own different HIDL instances.  The
# pinned Huawei daemon hard-codes slot1 and the matching libril registers all
# seven Huawei service names from every process; patch the exact binaries back
# to the AOSP multi-rild contract (modem0 -> slot1, modem1 -> slot2).
python3 "${SCRIPTDIR}/patch-ril-hidl-registration.py" \
    "${ROOTDIR}/vendor/huawei/alice/proprietary/vendor/bin/hw/rild" \
    "${ROOTDIR}/vendor/huawei/alice/proprietary/lib64/libril.so"
python3 "${SCRIPTDIR}/patch-ril-hidl-registration.py" \
    "${ROOTDIR}/vendor/huawei/alice/proprietary/vendor/bin/hw/rild" \
    "${ROOTDIR}/vendor/huawei/alice/proprietary/vendor/lib64/libril.so"

# Do not apply 0002-cam-stock-balong-ril.patch.  Binary inspection shows that
# its replacement is the Android 6/23 562,024-byte stock RIL (Build ID
# 8b2334c081fa158d3618093ba656d9eb).  The pinned Android 8.1 vendor tree uses
# the 904,496-byte Android 25 RIL (Build ID
# 12178d97f65ab857783dab599d9272e3), and verify-vendor-blobs.py enforces its
# SHA-256 in both collision paths.  Applying 0002 would therefore reintroduce
# the old RIL and fail the provenance gate after a seemingly successful patch.
# The patch remains recoverable from the previous Git commit, but is not part
# of the build graph.

# Replace the whole assignment line, or append if the key is absent.
set_mk_var() {
    local file="$1" key="$2" value="$3"
    if grep -qE "^[[:space:]]*${key}[[:space:]]*:?=" "${file}"; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]*:?=.*|${key} := ${value}|" "${file}"
    else
        printf '\n%s := %s\n' "${key}" "${value}" >> "${file}"
    fi
    echo "   ${key} := ${value}"
}

echo "==> Patching ${BOARD_CONFIG} for CAM-TL00"


# 1) OTA assert.
#    The alice-based TWRP reports ro.product.device=hi6210sft, which is what let
#    the verified LineageOS 14.1 package install on this phone. The CAM strings
#    are added so CAM-specific and CHC-U03 recoveries also pass.
set_mk_var "${BOARD_CONFIG}" TARGET_OTA_ASSERT_DEVICE \
    "hi6210sft,alice,cam,carmel,CAM-TL00,HWCAM-H,CHC-U03"

# 2) userdata size.
#    CAM-TL00 mmcblk0p40 = 11204608 KiB = 11473518592 bytes.
#    Upstream alice declares 11605639168 (126 MiB larger) which would overflow.
set_mk_var "${BOARD_CONFIG}" BOARD_USERDATAIMAGE_PARTITION_SIZE \
    "11473518592"

# 3) dexpreopt off.
#    system is exactly 2684354560 bytes with no headroom, and the GitHub Actions
#    job has a hard 6h ceiling. Disabling dexpreopt buys both space and time;
#    the cost is a slower first boot.
set_mk_var "${BOARD_CONFIG}" WITH_DEXPREOPT "false"

echo "==> Verifying"
fail=0
check() {
    if grep -qE "^${1}[[:space:]]*:=[[:space:]]*${2}$" "${BOARD_CONFIG}"; then
        echo "   ok   ${1}"
    else
        echo "   FAIL ${1} -- got: $(grep -E "^${1}" "${BOARD_CONFIG}" || echo '<missing>')" >&2
        fail=1
    fi
}
check TARGET_OTA_ASSERT_DEVICE           "hi6210sft,alice,cam,carmel,CAM-TL00,HWCAM-H,CHC-U03"
check BOARD_USERDATAIMAGE_PARTITION_SIZE "11473518592"
check WITH_DEXPREOPT                     "false"

# These must NOT drift -- they are what makes the image bootable on CAM-TL00.
echo "==> Asserting CAM-TL00-critical values are untouched"
declare -A MUST_KEEP=(
    [BOARD_KERNEL_BASE]="0x07478000"
    [BOARD_KERNEL_PAGESIZE]="2048"
    [BOARD_SYSTEMIMAGE_PARTITION_SIZE]="2684354560"
    [BOARD_BOOTIMAGE_PARTITION_SIZE]="25165824"
    [BOARD_RECOVERYIMAGE_PARTITION_SIZE]="67108864"
    [BOARD_CACHEIMAGE_PARTITION_SIZE]="268435456"
)
for key in "${!MUST_KEEP[@]}"; do
    want="${MUST_KEEP[$key]}"
    if grep -qE "^${key}[[:space:]]*:=[[:space:]]*${want}$" "${BOARD_CONFIG}"; then
        echo "   ok   ${key} = ${want}"
    else
        echo "   FAIL ${key} expected ${want}" >&2
        fail=1
    fi
done

[ "${fail}" -eq 0 ] || { echo "!! device tree patching failed" >&2; exit 1; }
echo "==> Device tree ready for CAM-TL00"
