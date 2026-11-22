# SPDX-License-Identifier: AGPL-3.0-only
"""The bundle version gate should parse source versions independently of formatting."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).with_name("check-tv-packages.py")
spec = importlib.util.spec_from_file_location("check_tv_packages", SOURCE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class TVPackageVersionTests(unittest.TestCase):
    def sources(self, tizen_attrs, android):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "tv-webos").mkdir()
            (root / "tv-tizen").mkdir()
            (root / "tv-android/app").mkdir(parents=True)
            (root / "tv-webos/appinfo.json").write_text(json.dumps({"version": "0.9.77"}), encoding="utf-8")
            (root / "tv-tizen/config.xml").write_text(
                f'<widget xmlns="http://www.w3.org/ns/widgets" {tizen_attrs}></widget>', encoding="utf-8")
            (root / "tv-android/app/build.gradle").write_text(
                'android { defaultConfig { ' + android + ' } }', encoding="utf-8")
            return mod.source_versions(root)

    def test_tizen_version_is_found_when_attribute_order_changes(self):
        self.assertEqual(self.sources('viewmodes="fullscreen" version="0.9.77"', "versionName '0.9.77'"),
                         {"ipk": "0.9.77", "wgt": "0.9.77", "apk": "0.9.77"})

    def test_gradle_double_quoted_version_is_recognized(self):
        self.assertEqual(self.sources('version="0.9.77" viewmodes="fullscreen"', 'versionName "0.9.77"'),
                         {"ipk": "0.9.77", "wgt": "0.9.77", "apk": "0.9.77"})

    def test_current_single_quoted_sources_still_work(self):
        self.assertEqual(self.sources('version="0.9.77" viewmodes="fullscreen"', "versionName '0.9.77'"),
                         {"ipk": "0.9.77", "wgt": "0.9.77", "apk": "0.9.77"})


if __name__ == "__main__":
    unittest.main()
