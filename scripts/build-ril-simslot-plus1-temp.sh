#!/usr/bin/env bash
# Build a narrow temporary package for the Android 25 CAM-TL00 RIL:
#   * keep the Android 8.1 (API 27/Android 25) vendor RIL provenance;
#   * patch all verified SIMSLOT command paths to modem numbering;
#   * restore the Android/framework property to zero-based 0,1.

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTDIR="$(cd "${SCRIPTDIR}/../.." && pwd)"
OUTPUT_ZIP_ARG="${1:?usage: $0 OUTPUT_ZIP}"
OUTPUT_ZIP="$(realpath -m "${OUTPUT_ZIP_ARG}")"
RIL_PACKAGE="${ROOTDIR}/lineage-15.1-20260824-rilfix_temp.zip"
PATCHER="${SCRIPTDIR}/patch-ril-simslot.py"
UPDATE_BINARY="META-INF/com/google/android/update-binary"
EXPECTED_ORIGINAL_RIL_SHA256="dcbb46ec581013a6f13c36dfa3cdb3c769211168e5614cc0cb7c0f321e01aaf4"
EXPECTED_PATCHED_RIL_SHA256="5dd2fa7b0ca370e28b705a3433136a392260cbd071b4e5d0167edc019c11dba5"

[ -f "${RIL_PACKAGE}" ] || {
    echo "!! original Android 8.1 RIL package not found: ${RIL_PACKAGE}" >&2
    exit 1
}
[ -f "${PATCHER}" ] || {
    echo "!! SIMSLOT patcher not found: ${PATCHER}" >&2
    exit 1
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cam-ril-plus1.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT
mkdir -p "${WORKDIR}/META-INF/com/google/android" "${WORKDIR}/payload" "${WORKDIR}/docs"

unzip -p "${RIL_PACKAGE}" "${UPDATE_BINARY}" >"${WORKDIR}/${UPDATE_BINARY}"
unzip -p "${RIL_PACKAGE}" payload/libbalong-ril.so >"${WORKDIR}/payload/libbalong-ril.so"

original_ril_sha256="$(sha256sum "${WORKDIR}/payload/libbalong-ril.so" | awk '{print $1}')"
if [[ "${original_ril_sha256}" != "${EXPECTED_ORIGINAL_RIL_SHA256}" ]]; then
    echo "!! unexpected original RIL SHA-256: ${original_ril_sha256}" >&2
    exit 1
fi

python3 "${PATCHER}" "${WORKDIR}/payload/libbalong-ril.so"
patched_ril_sha256="$(sha256sum "${WORKDIR}/payload/libbalong-ril.so" | awk '{print $1}')"
if [[ "${patched_ril_sha256}" != "${EXPECTED_PATCHED_RIL_SHA256}" ]]; then
    echo "!! unexpected patched RIL SHA-256: ${patched_ril_sha256}" >&2
    exit 1
fi

# Android's property service stores only the value bytes in this file.  No
# newline is allowed: 0,1 is the framework's zero-based convention.
printf '0,1' >"${WORKDIR}/payload/persist.radio.sim_slot_cfg"
printf '%s  payload/libbalong-ril.so\n' "${patched_ril_sha256}" >"${WORKDIR}/payload/SHA256SUMS"
printf '%s  payload/persist.radio.sim_slot_cfg\n' \
    "$(sha256sum "${WORKDIR}/payload/persist.radio.sim_slot_cfg" | awk '{print $1}')" \
    >>"${WORKDIR}/payload/SHA256SUMS"

cat >"${WORKDIR}/META-INF/com/google/android/updater-script" <<'EOF'
# CAM-TL00 Android 25 SIMSLOT +1 repair
# Framework property remains 0,1; modem-facing AT commands use 1,2.

ui_print("CAM-TL00 Android 25 SIMSLOT repair");
ui_print("Keeping framework persist.radio.sim_slot_cfg=0,1");

ifelse(is_mounted("/system"), unmount("/system"));
mount("ext4", "EMMC", "/dev/block/mmcblk0p38", "/system", "");

package_extract_file("payload/libbalong-ril.so", "/system/lib64/libbalong-ril.so");
package_extract_file("payload/libbalong-ril.so", "/system/vendor/lib64/libbalong-ril.so");

set_metadata("/system/lib64/libbalong-ril.so",
             "uid", 0, "gid", 0, "mode", 0644,
             "selabel", "u:object_r:system_file:s0");
set_metadata("/system/vendor/lib64/libbalong-ril.so",
             "uid", 0, "gid", 0, "mode", 0644,
             "selabel", "u:object_r:vendor_file:s0");
unmount("/system");

# userdata must be mounted/decrypted so the old 1,2 value cannot survive.
if is_mounted("/data") then
  ui_print("/data already mounted; restoring framework SIM slot property");
  package_extract_file("payload/persist.radio.sim_slot_cfg", "/data/property/persist.radio.sim_slot_cfg");
  set_metadata("/data/property/persist.radio.sim_slot_cfg",
               "uid", 0, "gid", 0, "mode", 0600,
               "selabel", "u:object_r:property_data_file:s0");
else
  ui_print("Mounting userdata to restore framework SIM slot property");
  mount("ext4", "EMMC", "/dev/block/mmcblk0p40", "/data", "");
  package_extract_file("payload/persist.radio.sim_slot_cfg", "/data/property/persist.radio.sim_slot_cfg");
  set_metadata("/data/property/persist.radio.sim_slot_cfg",
               "uid", 0, "gid", 0, "mode", 0600,
               "selabel", "u:object_r:property_data_file:s0");
  unmount("/data");
endif;

ui_print("Android 25 RIL SIMSLOT +1 repair complete");
EOF

cat >"${WORKDIR}/docs/README.txt" <<EOF
CAM-TL00 Android 25 SIMSLOT +1 temporary repair
=================================================

The payload is the pinned Android 8.1/Android 25 libbalong-ril.so with only
the verified SIMSLOT instruction changes.  It is installed at both paths:
  /system/lib64/libbalong-ril.so
  /system/vendor/lib64/libbalong-ril.so

Patched RIL SHA-256:
  ${patched_ril_sha256}

The framework property is explicitly restored as:
  /data/property/persist.radio.sim_slot_cfg = 0,1

The RIL converts the modem-facing SIMSLOT commands to one-based numbering:
  framework property: 0,1
  modem AT command:   1,2

This package does not change modem firmware, 09B95 capability selection,
boot/dtimage, build.prop, or unrelated RIL requests.  Install from TWRP with
/system writable and /data decrypted/mounted.  Make a boot/system/data backup.

Post-boot checks:
  getprop persist.radio.sim_slot_cfg       # expected: 0,1
  sha256sum /system/lib64/libbalong-ril.so # expected: ${patched_ril_sha256}
  sha256sum /vendor/lib64/libbalong-ril.so # expected: ${patched_ril_sha256}
  getprop gsm.sim.state
  dumpsys isub
EOF

mkdir -p "$(dirname "${OUTPUT_ZIP}")"
if [[ -e "${OUTPUT_ZIP}" ]]; then
    echo "!! refusing to overwrite existing package: ${OUTPUT_ZIP}" >&2
    exit 1
fi
(cd "${WORKDIR}" && zip -q -r -X "${OUTPUT_ZIP}" META-INF payload docs)

echo "package=${OUTPUT_ZIP}"
sha256sum "${OUTPUT_ZIP}"
unzip -tq "${OUTPUT_ZIP}"
