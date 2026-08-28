#!/usr/bin/env python3
"""Offline regression test for the CAM slot-sync RIL patch."""

import hashlib
import shutil
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RIL = ROOT.parent / "references/android_vendor_huawei_alice/proprietary/lib64/libbalong-ril.so"
PATCHER = ROOT / "scripts/patch-ril-simslot.py"

ORIGINAL_SHA256 = "dcbb46ec581013a6f13c36dfa3cdb3c769211168e5614cc0cb7c0f321e01aaf4"
PATCHED_SHA256 = "5dd2fa7b0ca370e28b705a3433136a392260cbd071b4e5d0167edc019c11dba5"
MODEM_SLOT_LITERAL_OFFSET = 0x971DA
MODEM_SLOT_LITERAL = b"1,2\0"
# File offsets for the normalized comparison/recovery paths and the explicit
# two-value SET command in the pinned Android 25 RIL.
CODE = {
    0x67B2C: bytes.fromhex("88264029"),  # ldp w8,w9,[x20]
    0x67B30: bytes.fromhex("1f050071"),  # cmp w8,#1
    0x67B34: bytes.fromhex("2009427a"),  # ccmp w9,#2,#0,eq
    0x67B38: bytes.fromhex("40060054"),  # b.eq 0x81c00
    0x67B64: bytes.fromhex("a2b31750"),  # adr x2, 0xb11da ("1,2")
    0x67B90: bytes.fromhex("42680791"),  # add x2, x2, #0x1da ("1,2")
    0x67BE8: bytes.fromhex("42680791"),  # add x2, x2, #0x1da ("1,2")
    0x67400: bytes.fromhex("e203082a"),  # mov w2, w8 (AT argument)
    0x67404: bytes.fromhex("e303092a"),  # mov w3, w9 (AT argument)
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PatchRilSimslotTest(unittest.TestCase):
    def test_translates_slot_pair_without_changing_property(self):
        self.assertTrue(RIL.is_file(), RIL)
        self.assertTrue(PATCHER.is_file(), PATCHER)
        self.assertEqual(sha256(RIL), ORIGINAL_SHA256)

        work = Path(__file__).resolve().parent / ".tmp-ril-simslot-test"
        if work.exists():
            shutil.rmtree(work)
        work.mkdir()
        try:
            target = work / "libbalong-ril.so"
            shutil.copy2(RIL, target)
            subprocess.run([sys.executable, str(PATCHER), str(target)], check=True)

            original = RIL.read_bytes()
            patched = target.read_bytes()
            self.assertEqual(sha256(target), PATCHED_SHA256)
            self.assertEqual(
                patched[MODEM_SLOT_LITERAL_OFFSET : MODEM_SLOT_LITERAL_OFFSET + len(MODEM_SLOT_LITERAL)],
                MODEM_SLOT_LITERAL,
            )
            for offset, expected in CODE.items():
                self.assertEqual(patched[offset : offset + len(expected)], expected, hex(offset))

            changed = {index for index, (before, after) in enumerate(zip(original, patched))
                       if before != after}
            expected_changed = {
                index
                for offset in CODE
                for index in range(offset, offset + 4)
            }
            self.assertTrue(changed <= expected_changed)

            # Applying the same reproducible patch twice must be a no-op.
            digest = sha256(target)
            subprocess.run([sys.executable, str(PATCHER), str(target)], check=True)
            self.assertEqual(sha256(target), digest)
        finally:
            shutil.rmtree(work)


if __name__ == "__main__":
    unittest.main()
