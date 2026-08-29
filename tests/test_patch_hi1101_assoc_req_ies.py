#!/usr/bin/env python3
"""Regression checks for packaging the HI1101 AP WPA kernel fix."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "patches/kernel-huawei-alice/0002-hi1101-export-assoc-req-ies.patch"
ORDER_PATCH = ROOT / "patches/kernel-huawei-alice/0004-hi1101-assoc-req-before-stats.patch"
DEBUG_PATCH = ROOT / "patches/kernel-huawei-alice/0005-hi1101-assoc-req-debug.patch"
JOIN_PATCH = ROOT / "patches/kernel-huawei-alice/0006-hi1101-export-assoc-req-on-new-sta.patch"
APPLIER = ROOT / "scripts/apply-device-patches.sh"
KERNEL_SOURCE = ROOT.parent / "references/android_kernel_huawei_alice/drivers/huawei_platform/connectivity/hisi/hisiwifi/cfg_event_rx.c"


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

    def test_assoc_ie_debug_trace_is_packaged(self):
        self.assertTrue(DEBUG_PATCH.is_file(), DEBUG_PATCH)
        text = DEBUG_PATCH.read_text(encoding="utf-8")
        for marker in (
            "get_station enter",
            "get_station IS_AP",
            "find_by_mac",
            "assoc_req.ie_len",
            "sinfo->filled",
            "get_stats_struct",
            "get_station return",
        ):
            self.assertIn(marker, text)

    def test_assoc_ies_are_attached_to_new_station_event(self):
        self.assertTrue(JOIN_PATCH.is_file(), JOIN_PATCH)
        patch_text = JOIN_PATCH.read_text(encoding="utf-8")
        source = KERNEL_SOURCE.read_text(encoding="latin-1")
        self.assertIn("0006-hi1101-export-assoc-req-on-new-sta.patch", APPLIER.read_text())
        for text in (patch_text, source):
            self.assertIn("sinfo.filled |= STATION_INFO_ASSOC_REQ_IES", text)
            self.assertIn("sinfo.assoc_req_ies = sta->assoc_req.ie", text)
            self.assertIn("sinfo.assoc_req_ies_len = sta->assoc_req.ie_len", text)

        join = source[source.index("STATIC void  hwifi_sta_join"):source.index("STATIC void  hwifi_sta_leave")]
        self.assertLess(
            join.index("sinfo.assoc_req_ies_len"),
            join.index("cfg80211_new_sta"),
        )


if __name__ == "__main__":
    unittest.main()
