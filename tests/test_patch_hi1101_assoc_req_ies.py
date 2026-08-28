#!/usr/bin/env python3
"""Regression checks for packaging the HI1101 AP WPA kernel fix."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "patches/kernel-huawei-alice/0002-hi1101-export-assoc-req-ies.patch"
ORDER_PATCH = ROOT / "patches/kernel-huawei-alice/0004-hi1101-assoc-req-before-stats.patch"
APPLIER = ROOT / "scripts/apply-device-patches.sh"


class Hi1101AssocReqPatchTest(unittest.TestCase):
    def test_kernel_patch_is_packaged_and_wired_into_source_applier(self):
        self.assertTrue(PATCH.is_file(), PATCH)
        patch_text = PATCH.read_text(encoding="utf-8")
        self.assertIn("STATION_INFO_ASSOC_REQ_IES", patch_text)
        self.assertIn("sinfo->assoc_req_ies = sta->assoc_req.ie", patch_text)
        self.assertIn("0002-hi1101-export-assoc-req-ies.patch", APPLIER.read_text())

    def test_assoc_ie_export_precedes_stats_lookup(self):
        text = ORDER_PATCH.read_text(encoding="utf-8")
        added = "\n".join(
            line[1:] for line in text.splitlines() if line.startswith("+")
        )
        self.assertLess(
            added.index("Export HI1101 association IEs before stats lookup"),
            added.index("stats = get_stats_struct"),
        )


if __name__ == "__main__":
    unittest.main()
