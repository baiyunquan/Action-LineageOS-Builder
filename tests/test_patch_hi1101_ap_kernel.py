import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "patches/kernel-huawei-alice/0003-hi1101-ap-init-readiness.patch"
APPLIER = ROOT / "scripts/apply-device-patches.sh"


class Hi1101ApKernelPatchTest(unittest.TestCase):
    def test_ap_readiness_patch_is_packaged_and_wired(self):
        self.assertTrue(PATCH.is_file(), PATCH)
        text = PATCH.read_text(encoding="utf-8")
        self.assertIn("hwifi_wlan_open(ndev)", text)
        self.assertIn("NL80211_IFTYPE_AP", text)
        self.assertIn("0003-hi1101-ap-init-readiness.patch", APPLIER.read_text())


if __name__ == "__main__":
    unittest.main()
