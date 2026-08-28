#!/usr/bin/env python3
"""Regression checks for the manual boot-repack local kernel build flow."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT.parent / "references/android_kernel_huawei_alice/scripts/build-boot-local.sh"


class KernelLocalBuildScriptTest(unittest.TestCase):
    def test_exports_image_without_magiskboot(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("magiskboot", text.lower())
        self.assertNotIn("MAGISKBOOT", text)
        self.assertIn('cp "$KERNEL_OUT/arch/$KERNEL_ARCH/boot/$KERNEL_IMAGE" /out/Image', text)
        self.assertIn("Image.sha256", text)


if __name__ == "__main__":
    unittest.main()
