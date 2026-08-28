#!/usr/bin/env python3
"""Regression test for removing only the forced Hisi CDMA init property."""

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PATCHER = ROOT / "scripts/patch-boot-init-hisi.py"


def load_patcher():
    spec = importlib.util.spec_from_file_location("patch_boot_init_hisi", PATCHER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PatchBootInitHisiTest(unittest.TestCase):
    def test_skips_only_hisi_cdma_setter_and_is_idempotent(self):
        patcher = load_patcher()
        marker = b"ro.config.hisi_cdma_supported\0"
        # adrp/add/mov + b 0x422f48: the exact setter call site in the
        # pinned CAM-TL00 init.  The patched branch goes to 0x422f4c, past
        # the shared property_override call.
        sequence = bytes.fromhex("60080090007c2d91e10315aa05000014")
        patched_sequence = bytes.fromhex("60080090007c2d91e10315aa06000014")
        fixture = bytearray(512)
        fixture[96 : 96 + len(marker)] = marker
        fixture[256 : 256 + len(sequence)] = sequence

        patched, changes = patcher.patch_init_blob(bytes(fixture), strict=False)
        self.assertEqual(changes, 1)
        self.assertEqual(patched[256 : 256 + len(sequence)], patched_sequence)
        self.assertEqual(patched[96 : 96 + len(marker)], marker)

        again, changes = patcher.patch_init_blob(patched, strict=False)
        self.assertEqual(changes, 0)
        self.assertEqual(again, patched)


if __name__ == "__main__":
    unittest.main()
