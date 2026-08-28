#!/usr/bin/env bash
# Build a targeted CAM-TL00 temporary package:
#   * keep the already verified SIMSLOT-patched Android 8.1 RIL;
#   * skip only ro.config.hisi_cdma_supported=false in the boot init.

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTDIR="$(cd "${SCRIPTDIR}/../.." && pwd)"
INPUT_BOOT="${1:?usage: $0 CURRENT_BOOT_IMG OUTPUT_ZIP}"
OUTPUT_ZIP_ARG="${2:?usage: $0 CURRENT_BOOT_IMG OUTPUT_ZIP}"
OUTPUT_ZIP="$(realpath -m "${OUTPUT_ZIP_ARG}")"
RIL_PACKAGE="${ROOTDIR}/lineage-15.1-20260824-ril-simslot_temp.zip"
PATCHER="${SCRIPTDIR}/patch-boot-init-hisi.py"
UPDATE_BINARY="META-INF/com/google/android/update-binary"

[ -f "${INPUT_BOOT}" ] || { echo "!! boot image not found: ${INPUT_BOOT}" >&2; exit 1; }
[ -f "${RIL_PACKAGE}" ] || { echo "!! SIMSLOT RIL package not found: ${RIL_PACKAGE}" >&2; exit 1; }
[ -f "${PATCHER}" ] || { echo "!! boot init patcher not found: ${PATCHER}" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cam-ril-no-hisi.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT
mkdir -p "${WORKDIR}/META-INF/com/google/android" "${WORKDIR}/payload" "${WORKDIR}/docs"

PATCHED_BOOT="${WORKDIR}/payload/boot.img"
PATCHED_BOOT_RAW="${WORKDIR}/boot.img.raw"
python3 "${PATCHER}" "${INPUT_BOOT}" "${PATCHED_BOOT_RAW}"

# mmcblk0p27 is a 25 MiB boot partition on this CAM-TL00.  Padding the valid
# Android image to the partition size makes block-device extraction explicit;
# the boot header ignores the trailing zeroes.
mv "${PATCHED_BOOT_RAW}" "${PATCHED_BOOT}"
truncate -s 25165824 "${PATCHED_BOOT}"

unzip -p "${RIL_PACKAGE}" "${UPDATE_BINARY}" >"${WORKDIR}/${UPDATE_BINARY}"
unzip -p "${RIL_PACKAGE}" payload/libbalong-ril.so >"${WORKDIR}/payload/libbalong-ril.so"

# Record the source init hash for the package documentation.
source_hash="$(python3 - "${INPUT_BOOT}" <<'PY'
import gzip, hashlib, struct, sys
from pathlib import Path
sys.path.insert(0, str(Path.cwd()))
from tools.bootimg_alice import read_boot_image, parse_cpio_newc
_, _, ramdisk, _, _ = read_boot_image(sys.argv[1])
for _fields, name, payload in parse_cpio_newc(gzip.decompress(ramdisk)):
    if name == '.backup/init':
        print(hashlib.sha256(payload).hexdigest())
        break
else:
    raise SystemExit('missing .backup/init')
PY
)"

python3 - "${WORKDIR}" "${source_hash}" <<'PY'
from pathlib import Path
import sys

work = Path(sys.argv[1])
source_hash = sys.argv[2]
update = '''ui_print("CAM-TL00 SIMSLOT + init property diagnostic repair");
ui_print("Keeping Android 8.1 SIMSLOT RIL patch");
ui_print("Removing only ro.config.hisi_cdma_supported=false setter");

ifelse(is_mounted("/system"), unmount("/system"));

package_extract_file("payload/boot.img", "/dev/block/mmcblk0p27");

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
ui_print("Diagnostic repair complete");
'''
doc = f'''CAM-TL00 Android 8.1 diagnostic temporary repair
=================================================

This package is deliberately a one-variable test.  It keeps the verified
Android 8.1 libbalong-ril.so carrying the SIMSLOT fix (framework property
persist.radio.sim_slot_cfg remains 0,1 and the modem command uses 1,2), and
changes only the boot init branch that called property_override for
ro.config.hisi_cdma_supported=false.

Unchanged:
  ro.config.modem_number=2
  ro.config.client_number=2
  SIMSLOT RIL patch and both libbalong-ril.so install paths

The boot payload is the current CAM-TL00 boot partition image with the
Magisk-preserved .backup/init patched.  It is padded to the 25 MiB boot
partition; the Android boot header and kernel are unchanged.  The updater
script has no device assert and writes boot mmcblk0p27 plus the two RIL paths
on system mmcblk0p38.

Back up boot/system in TWRP before installing.  After reboot, collect:
  getprop gsm.sim.state
  dumpsys isub
  logcat -b radio -d | grep -E 'COPS|CGREG|SYSINFOEX|ICCID|CPIN'

Expected init hashes:
  before: {source_hash}
  after:  fa59b898dba767014fc888399fa982fe50f83c38902afdef2cafd6232396884b
'''
(work / 'META-INF/com/google/android/updater-script').write_text(update)
(work / 'docs/README.txt').write_text(doc)
PY

sha256sum "${WORKDIR}/payload/boot.img" "${WORKDIR}/payload/libbalong-ril.so" \
    | sed "s#${WORKDIR}/payload/##" >"${WORKDIR}/payload/SHA256SUMS"

mkdir -p "$(dirname "${OUTPUT_ZIP}")"
rm -f "${OUTPUT_ZIP}"
(cd "${WORKDIR}" && zip -q -r -X "${OUTPUT_ZIP}" META-INF payload docs)
echo "package=${OUTPUT_ZIP}"
sha256sum "${OUTPUT_ZIP}"
unzip -tq "${OUTPUT_ZIP}"
