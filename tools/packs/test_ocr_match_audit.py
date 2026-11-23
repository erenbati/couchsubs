# SPDX-License-Identifier: AGPL-3.0-only
"""Offline GTA-style OCR key audit: only metadata, never copyrighted source text."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("ocr_match_audit.py")


class OcrMatchAuditTests(unittest.TestCase):
    def run_audit(self, rows, pool, output=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sources = root / "local-rows.jsonl"
            sources.write_text(
                "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows),
                encoding="utf-8")
            export = root / "local-pool.json"
            export.write_text(json.dumps(pool), encoding="utf-8")
            dest = root / "report.json"
            if output:
                dest.write_text('{"last_good": 1}\n', encoding="utf-8")
            args = [sys.executable, "-B", str(SCRIPT), str(sources), str(export)]
            if output:
                args += ["--out", str(dest)]
            result = subprocess.run(
                args, cwd=root, capture_output=True, text=True,
                encoding="utf-8", errors="replace")
            return result, (dest.read_text(encoding="utf-8") if output else result.stdout)

    def test_flags_icon_placeholders_separately_from_real_exact_hits(self):
        rows = [
            {"id": "u1", "category": "tutorial", "text": "Press ~INPUT_AIM~ to continue.",
             "sents": ["Press ~INPUT_AIM~ to continue."]},
            {"id": "u2", "category": "dialogue", "text": "Move quickly.", "sents": ["Move quickly."]},
            {"id": "u3", "category": "tutorial", "text": "Hold ~1~ to aim.",
             "sents": ["Hold ~1~ to aim."]},
        ]
        pool = {"lines": [{"text": "Press to continue."},
                          {"text": "Move quickly!"},
                          {"text": "Hold 5 to aim."},
                          {"text": "Another mission."}]}
        proc, raw = self.run_audit(rows, pool)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        info = json.loads(raw)
        self.assertEqual(info["source_rows"], 3)
        self.assertEqual(info["source_rows_with_input_icons"], 1)
        self.assertEqual(info["source_rows_with_dynamic_fields"], 1)
        self.assertEqual(info["source_by_category"], {"dialogue": 1, "tutorial": 2})
        self.assertEqual(info["ocr_lines"], 4)
        self.assertEqual(info["exact_key_candidates"], 1)
        self.assertEqual(info["input_icon_only_candidates"], 1)
        self.assertEqual(info["unmatched"], 2)
        self.assertNotIn("Press", raw)
        self.assertNotIn("Move quickly", raw)
        self.assertNotIn("u1", raw)
        self.assertEqual(info["runtime_coverage_estimated"], False)

    def test_report_does_not_echo_untrusted_source_category_strings(self):
        rows = [{"text": "Keep moving now.", "category": "Secret mission title"}]
        proc, raw = self.run_audit(rows, {"lines": []})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("Secret mission title", raw)
        self.assertEqual(json.loads(raw)["source_by_category"], {"other": 1})

    def test_d1_export_and_speaker_label_are_supported(self):
        rows = [{"text": "Keep moving now.", "category": "dialogue",
                 "sents": ["Keep moving now."]}]
        pool = [{"success": True, "results": [{"text": "Jason: Keep moving now."}]}]
        proc, raw = self.run_audit(rows, pool)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(json.loads(raw)["exact_key_candidates"], 1)

    def test_incomplete_input_preserves_previous_report(self):
        rows = [{"text": "Short example."}]
        pool = {"lines": [{"text": None}]}
        proc, raw = self.run_audit(rows, pool, output=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(raw, '{"last_good": 1}\n')

    def test_valid_output_replaces_report_with_counts_only(self):
        rows = [{"text": "Keep moving now."}]
        pool = {"lines": [{"text": "Keep moving now."}]}
        proc, raw = self.run_audit(rows, pool, output=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(json.loads(raw)["exact_key_candidates"], 1)
        self.assertNotIn("Keep moving", raw)


if __name__ == "__main__":
    unittest.main()
