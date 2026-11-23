# SPDX-License-Identifier: AGPL-3.0-only
"""Never publish incomplete UI translations as completed xcstrings entries."""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("metinler-katalog.py")


class CatalogMissingValuesTests(unittest.TestCase):
    def run_catalog(self, en, tr):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            script = root / "scripts/metinler-katalog.py"
            script.parent.mkdir()
            shutil.copy2(SCRIPT, script)
            doc = root / "design/yeni-arayuz/METINLER.md"
            doc.parent.mkdir(parents=True)
            doc.write_text(
                "| EN | TR |\n| --- | --- |\n"
                + f"| {en} | {tr} |\n", encoding="utf-8")
            catalog = root / "mac/CouchSubs/Resources/Localizable.xcstrings"
            catalog.parent.mkdir(parents=True)
            original = '{\n  "strings": {\n  },\n  "version": "1.0"\n}\n'
            catalog.write_text(original, encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, "-B", str(script)], cwd=root,
                capture_output=True, text=True, encoding="utf-8", errors="replace")
            return proc, original, catalog.read_text(encoding="utf-8")

    def test_missing_turkish_does_not_create_translated_empty_catalog_entry(self):
        proc, original, actual = self.run_catalog("Start game", " ")
        self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(actual, original, "incomplete translation must preserve previous catalog")

    def test_missing_english_does_not_create_blank_localization_key(self):
        proc, original, actual = self.run_catalog(" ", "Oyunu baslat")
        self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(actual, original, "blank source key must never enter xcstrings")

    def test_complete_pair_still_creates_valid_translation(self):
        proc, _, actual = self.run_catalog("Start game", "Oyunu baslat")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(json.loads(actual)["strings"]["Start game"]["localizations"]["tr"]
                         ["stringUnit"]["value"], "Oyunu baslat")


if __name__ == "__main__":
    unittest.main()
