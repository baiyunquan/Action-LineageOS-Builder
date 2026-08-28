#!/usr/bin/env bash
# Build a targeted CAM-TL00 temporary package:
#   * restore the pinned, unpatched Android 8.1 libbalong-ril.so;
#   * persist Android's framework-side SIM slot property as 1,2.
#
# This deliberately does not modify boot, modem, system build properties, or
# any other RIL request path.  The modem-facing numbering is therefore left
# to the restored Android 8.1 RIL, while the persistent Android property is
# changed explicitly in /data/property.

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTDIR="$(cd "${SCRIPTDIR}/../.." && pwd)"
OUTPUT_ZIP_ARG="${1:?usage: $0 OUTPUT_ZIP}"
OUTPUT_ZIP="$(realpath -m "${OUTPUT_ZIP_ARG}")"
RIL_PACKAGE="${ROOTDIR}/lineage-15.1-20260824-rilfix_temp.zip"
UPDATE_BINARY="META-INF/com/google/android/update-binary"
EXPECTED_RIL_SHA256="dcbb46ec581013a6f13c36dfa3cdb3c769211168e5614cc0cb7c0f321e01aaf4"

[ -f "${RIL_PACKAGE}" ] || {
    echo "!! original Android 8.1 RIL package not found: ${RIL_PACKAGE}" >&2
    exit 1
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cam-ril-framework-12.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT
mkdir -p "${WORKDIR}/META-INF/com/google/android" "${WORKDIR}/payload" "${WORKDIR}/docs"

unzip -p "${RIL_PACKAGE}" "${UPDATE_BINARY}" >"${WORKDIR}/${UPDATE_BINARY}"
unzip -p "${RIL_PACKAGE}" payload/libbalong-ril.so >"${WORKDIR}/payload/libbalong-ril.so"

actual_ril_sha256="$(sha256sum "${WORKDIR}/payload/libbalong-ril.so" | awk '{print $1}')"
if [[ "${actual_ril_sha256}" != "${EXPECTED_RIL_SHA256}" ]]; then
    echo "!! unexpected RIL SHA-256: ${actual_ril_sha256}" >&2
    exit 1
fi

# Android's property service stores persist.* values as the value bytes in
# /data/property/<name>.  Do not add a newline: this matches the AOSP writer
# and avoids an invisible character becoming part of the property value.
printf '1,2' >"${WORKDIR}/payload/persist.radio.sim_slot_cfg"
printf '%s  payload/libbalong-ril.so\n' "${actual_ril_sha256}" >"${WORKDIR}/payload/SHA256SUMS"
printf '%s  payload/persist.radio.sim_slot_cfg\n' \
    "$(sha256sum "${WORKDIR}/payload/persist.radio.sim_slot_cfg" | awk '{print $1}')" \
    >>"${WORKDIR}/payload/SHA256SUMS"

cat >"${WORKDIR}/META-INF/com/google/android/updater-script" <<'EOF'
# CAM-TL00 Android 8.1 framework SIM slot repair
#
# Restores the pinned, unpatched Android 8.1 Balong RIL at both locations and
# persists the framework-side property as 1,2.  No device assert is used.

ui_print("CAM-TL00 Android 8.1 RIL restore");
ui_print("Setting framework persist.radio.sim_slot_cfg=1,2");

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

# userdata is encrypted on some recoveries.  Refuse to continue unless it is
# already mounted or can be mounted, so a successful-looking partial flash
# cannot leave the old 0,1 property behind.
if is_mounted("/data") then
  ui_print("/data already mounted; writing persistent property");
  package_extract_file("payload/persist.radio.sim_slot_cfg", "/data/property/persist.radio.sim_slot_cfg");
  set_metadata("/data/property/persist.radio.sim_slot_cfg",
               "uid", 0, "gid", 0, "mode", 0600,
               "selabel", "u:object_r:property_data_file:s0");
else
  ui_print("Mounting userdata to write persistent property");
  mount("ext4", "EMMC", "/dev/block/mmcblk0p40", "/data", "");
  package_extract_file("payload/persist.radio.sim_slot_cfg", "/data/property/persist.radio.sim_slot_cfg");
  set_metadata("/data/property/persist.radio.sim_slot_cfg",
               "uid", 0, "gid", 0, "mode", 0600,
               "selabel", "u:object_r:property_data_file:s0");
  unmount("/data");
endif;

ui_print("RIL restore and framework property update complete");
EOF

cat >"${WORKDIR}/docs/README.txt" <<EOF
CAM-TL00 Android 8.1 framework SIM slot repair
================================================

This is a deliberately narrow rollback package.  It restores the original
Android 8.1 Balong RIL from the verified rilfix package (the binary has no
SIMSLOT patch) to both paths:
  /system/lib64/libbalong-ril.so
  /system/vendor/lib64/libbalong-ril.so

Expected RIL SHA-256:
  ${EXPECTED_RIL_SHA256}

It also writes the Android persistent property file:
  /data/property/persist.radio.sim_slot_cfg = 1,2

The property is intentionally changed on the Android/framework side.  This
package does not change modem firmware, boot, dtimage, build.prop, or the
RIL's other request handlers.  The package must be installed from TWRP with
/system writable and /data decrypted/mounted.  Make a boot/system/data backup
first.  If /data cannot be mounted, installation aborts instead of silently
leaving the previous 0,1 value.

After reboot, verify:
  getprop persist.radio.sim_slot_cfg       # expected: 1,2
  sha256sum /system/lib64/libbalong-ril.so # expected: ${EXPECTED_RIL_SHA256}
  sha256sum /vendor/lib64/libbalong-ril.so # expected: ${EXPECTED_RIL_SHA256}
  getprop gsm.sim.state
  dumpsys isub
EOF

mkdir -p "$(dirname "${OUTPUT_ZIP}")"
rm -f "${OUTPUT_ZIP}"
(cd "${WORKDIR}" && zip -q -r -X "${OUTPUT_ZIP}" META-INF payload docs)

echo "package=${OUTPUT_ZIP}"
sha256sum "${OUTPUT_ZIP}"
unzip -tq "${OUTPUT_ZIP}"
