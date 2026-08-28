#!/usr/bin/env python3
"""Regression tests for the dual-rild HIDL service ownership patch."""

import hashlib
import importlib.util
import shutil
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RILD = ROOT.parent / "references/android_vendor_huawei_alice/proprietary/vendor/bin/hw/rild"
LIBRIL = ROOT.parent / "references/android_vendor_huawei_alice/proprietary/lib64/libril.so"
PATCHER = ROOT / "scripts/patch-ril-hidl-registration.py"


def load_patcher():
    spec = importlib.util.spec_from_file_location("patch_ril_hidl_registration", PATCHER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PatchRilHidlRegistrationTest(unittest.TestCase):
    def test_patches_pinned_rild_and_libril_idempotently(self):
        self.assertTrue(RILD.is_file(), RILD)
        self.assertTrue(LIBRIL.is_file(), LIBRIL)
        self.assertTrue(PATCHER.is_file(), PATCHER)
        patcher = load_patcher()

        work = Path(__file__).resolve().parent / ".tmp-ril-hidl-registration-test"
        if work.exists():
            shutil.rmtree(work)
        work.mkdir()
        try:
            rild = work / "rild"
            libril = work / "libril.so"
            shutil.copy2(RILD, rild)
            shutil.copy2(LIBRIL, libril)
            subprocess.run([sys.executable, str(PATCHER), str(rild), str(libril)], check=True)

            self.assertEqual(
                patcher.sha256(rild.read_bytes()), patcher.PATCHED_RILD_SHA256,
            )
            self.assertEqual(
                patcher.sha256(libril.read_bytes()), patcher.PATCHED_LIBRIL_SHA256,
            )
            self.assertEqual(rild.read_bytes()[0x39A2 : 0x39A8], b"slot2\0")
            # Both service-name paths must compare the parsed client-id byte
            # (w1), not the service-name pointer (w0).
            self.assertEqual(rild.read_bytes()[0x3C60 : 0x3C64], bytes.fromhex("3fc40071"))
            self.assertEqual(rild.read_bytes()[0x3C88 : 0x3C8C], bytes.fromhex("3fc40071"))
            # The registration loop exits after the one selected dynamic slot.
            self.assertEqual(libril.read_bytes()[0x67750 : 0x67754], bytes.fromhex("01000014"))

            before = (patcher.sha256(rild.read_bytes()), patcher.sha256(libril.read_bytes()))
            subprocess.run([sys.executable, str(PATCHER), str(rild), str(libril)], check=True)
            self.assertEqual(
                before,
                (patcher.sha256(rild.read_bytes()), patcher.sha256(libril.read_bytes())),
            )
        finally:
            shutil.rmtree(work)


if __name__ == "__main__":
    unittest.main()
