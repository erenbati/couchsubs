# SPDX-License-Identifier: AGPL-3.0-only
"""Restoration batches must not inject subtitles belonging to a different batch."""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


class PoolfixChunkTests(unittest.TestCase):
    def test_second_batch_cannot_inject_first_batch_id(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ("poolfix.py", "common.py"):
                shutil.copy2(HERE / name, root / name)
            (root / "llm.py").write_text(
                "def call(system, user, schema, tag, max_tokens):\n"
                "    if '60\\t' in user:\n"
                "        return {'items': [\n"
                "            {'id': 0, 'keep': True, 'english': 'WRONG PREVIOUS BATCH', 'speaker': 'Peter'},\n"
                "            {'id': 60, 'keep': True, 'english': 'Correct last line.', 'speaker': 'Miles'}]}\n"
                "    return {'items': [{'id': 0, 'keep': True, 'english': 'Correct first line.', 'speaker': 'Peter'}]}\n"
                "def spent(): return 0.0\n",
                encoding="utf-8",
            )
            pool = root / "pool.json"
            pool.write_text(json.dumps({"lines": [
                {"text": f"Spider-Man: Hold the shield near marker {i} now.", "installs": 2}
                for i in range(61)
            ]}), encoding="utf-8")
            rows = root / "known.jsonl"
            rows.write_text("", encoding="utf-8")
            output = root / "restored.jsonl"
            result = subprocess.run(
                [sys.executable, "-B", str(root / "poolfix.py"), str(pool), str(rows), str(output)],
                cwd=root, capture_output=True, text=True, encoding="utf-8", errors="replace",
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            restored = [json.loads(line) for line in output.read_text(encoding="utf-8").splitlines()]
            self.assertEqual([item["text"] for item in restored],
                             ["Correct first line.", "Correct last line."])
            self.assertEqual([item["raw"] for item in restored],
                             ["Hold the shield near marker 0 now.", "Hold the shield near marker 60 now."])


if __name__ == "__main__":
    unittest.main()
