#!/usr/bin/env bash
# Build a temporary flashable package for the dual-rild HIDL ownership fix.
set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTDIR="$(cd "${SCRIPTDIR}/../.." && pwd)"
OUTPUT_ZIP="$(realpath -m "${1:?usage: $0 OUTPUT_ZIP}")"
BASE_PACKAGE="${ROOTDIR}/lineage-15.1-20260824-rilfix_temp.zip"
RILD_SOURCE="${ROOTDIR}/references/android_vendor_huawei_alice/proprietary/vendor/bin/hw/rild"
LIBRIL_SOURCE="${ROOTDIR}/references/android_vendor_huawei_alice/proprietary/lib64/libril.so"
PATCHER="${SCRIPTDIR}/patch-ril-hidl-registration.py"
UPDATE_BINARY="META-INF/com/google/android/update-binary"

[[ -f "${BASE_PACKAGE}" && -f "${RILD_SOURCE}" && -f "${LIBRIL_SOURCE}" && -f "${PATCHER}" ]] || {
    echo "!! missing base package, pinned blobs, or HIDL patcher" >&2
    exit 1
}
[[ ! -e "${OUTPUT_ZIP}" ]] || { echo "!! refusing to overwrite ${OUTPUT_ZIP}" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cam-ril-hidl.XXXXXX")"
trap 'find "${WORKDIR}" -depth -delete' EXIT
mkdir -p "${WORKDIR}/META-INF/com/google/android" "${WORKDIR}/payload" "${WORKDIR}/docs"

unzip -p "${BASE_PACKAGE}" "${UPDATE_BINARY}" >"${WORKDIR}/${UPDATE_BINARY}"
cp "${RILD_SOURCE}" "${WORKDIR}/payload/rild"
cp "${LIBRIL_SOURCE}" "${WORKDIR}/payload/libril.so"
python3 "${PATCHER}" "${WORKDIR}/payload/rild" "${WORKDIR}/payload/libril.so"

rild_sha="$(sha256sum "${WORKDIR}/payload/rild" | awk '{print $1}')"
libril_sha="$(sha256sum "${WORKDIR}/payload/libril.so" | awk '{print $1}')"
[[ "${rild_sha}" == "7593482cf739e5bbcac182e02acdfc422577e0b7aa15cd1dbf69a66b75d8a88b" ]] || exit 1
[[ "${libril_sha}" == "58f323ee6b0a24d0cc3c75da77b6ff2d99fa6a3fc88884f73d4d5f49ad3094b9" ]] || exit 1

printf '%s  payload/rild\n%s  payload/libril.so\n' "${rild_sha}" "${libril_sha}" >"${WORKDIR}/payload/SHA256SUMS"

cat >"${WORKDIR}/META-INF/com/google/android/updater-script" <<'EOF'
ui_print("CAM-TL00 dual RIL/HIDL slot ownership repair");
ui_print("modem0 -> slot1; modem1 -> slot2");
ui_print("SIMSLOT and persist.radio.sim_slot_cfg are unchanged");
ifelse(is_mounted("/system"), unmount("/system"));
mount("ext4", "EMMC", "/dev/block/mmcblk0p38", "/system", "");
package_extract_file("payload/rild", "/system/vendor/bin/hw/rild");
package_extract_file("payload/libril.so", "/system/lib64/libril.so");
package_extract_file("payload/libril.so", "/system/vendor/lib64/libril.so");
set_metadata("/system/vendor/bin/hw/rild", "uid", 0, "gid", 2000, "mode", 0755, "selabel", "u:object_r:rild_exec:s0");
set_metadata("/system/lib64/libril.so", "uid", 0, "gid", 0, "mode", 0644, "selabel", "u:object_r:system_file:s0");
set_metadata("/system/vendor/lib64/libril.so", "uid", 0, "gid", 0, "mode", 0644, "selabel", "u:object_r:vendor_file:s0");
unmount("/system");
ui_print("HIDL registration repair complete; reboot now");
EOF

cat >"${WORKDIR}/docs/README.txt" <<EOF
CAM-TL00 dual RIL/HIDL registration temporary repair
=====================================================
Installed files:
  /system/vendor/bin/hw/rild
  /system/lib64/libril.so
  /system/vendor/lib64/libril.so

SHA-256:
  rild:      ${rild_sha}
  libril.so: ${libril_sha}

This package changes only HIDL service ownership. It does not modify
libbalong-ril.so, SIMSLOT commands, or persist.radio.sim_slot_cfg (which must
remain 0,1). Make a boot/system backup before installing.
EOF

mkdir -p "$(dirname "${OUTPUT_ZIP}")"
(cd "${WORKDIR}" && zip -q -r -X "${OUTPUT_ZIP}" META-INF payload docs)
unzip -tq "${OUTPUT_ZIP}"
sha256sum "${OUTPUT_ZIP}"
echo "package=${OUTPUT_ZIP}"
