#!/usr/bin/env python3
"""Integration tests for the iOS build's bundled TV release cache."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ios-tv-packages.sh"


def posix_path(path: Path) -> str:
    value = str(path.resolve()).replace("\\", "/")
    if len(value) >= 2 and value[1] == ":":
        return "/" + value[0].lower() + value[2:]
    return value


def bash_executable() -> str:
    if os.name == "nt":
        candidates = [
            Path(r"C:\Program Files\Git\bin\bash.exe"),
            Path(shutil.which("bash") or ""),
        ]
        for candidate in candidates:
            if candidate.is_file() and "\\System32\\" not in str(candidate):
                return str(candidate)
        raise RuntimeError("Git Bash is required to run this integration test on Windows")
    return shutil.which("bash") or "/bin/sh"


class IosTvPackageCacheTests(unittest.TestCase):
    def run_build(self, failure: str | None = None) -> tuple[Path, Path, subprocess.CompletedProcess[str]]:
        temp_dir = tempfile.TemporaryDirectory(prefix="couchsubs-ios-tv-cache-")
        self.addCleanup(temp_dir.cleanup)
        temp = Path(temp_dir.name)
        home = temp / "home"
        cache = home / "Library" / "Caches" / "CouchSubs" / "ios-tv-release"
        output = temp / "output"
        mock = temp / "python-mock"
        cache.mkdir(parents=True)
        mock.mkdir()
        output.mkdir()

        (cache / "couchsubs-androidtv.apk").write_bytes(b"previous-apk")
        (cache / "couchsubs-lg.ipk").write_bytes(b"previous-ipk")
        (cache / "release.properties").write_text(
            "release=v1.0.0\n"
            "couchsubs-androidtv.apk=CouchSubs-androidtv-v1.apk\n"
            "couchsubs-lg.ipk=com.couchsubs.tv_1.0.0_all.ipk\n",
            encoding="utf-8",
        )

        (mock / "sitecustomize.py").write_text(
            '''import hashlib, io, json, os, urllib.error, urllib.request, zipfile
apk_file = io.BytesIO()
with zipfile.ZipFile(apk_file, "w") as archive:
    archive.writestr("AndroidManifest.xml", b"")
apk = apk_file.getvalue()
ipk = b"new-ipk-v2"
release = {"tag_name": "v2.0.0", "assets": [
    {"name": "SHA256SUMS.txt", "browser_download_url": "https://fixture/sums"},
    {"name": "CouchSubs-androidtv.apk", "browser_download_url": "https://fixture/android.apk"},
    {"name": "com.couchsubs.tv_2.0.0_all.ipk", "browser_download_url": "https://fixture/lg.ipk"},
]}
sums = (hashlib.sha256(apk).hexdigest() + "  CouchSubs-androidtv.apk\\n" +
        hashlib.sha256(ipk).hexdigest() + "  com.couchsubs.tv_2.0.0_all.ipk\\n").encode()
class Response:
    def __init__(self, data): self.data = data
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self): return self.data
def fixture(request, timeout=60):
    url = request.full_url
    if url.endswith("/releases/latest"): return Response(json.dumps(release).encode())
    if url.endswith("/sums"): return Response(sums)
    if url.endswith("/android.apk"): return Response(apk)
    if url.endswith("/lg.ipk"):
        if os.environ.get("IOS_TV_FAILURE") == "download":
            raise urllib.error.URLError("simulated IPK download failure")
        if os.environ.get("IOS_TV_FAILURE") == "checksum":
            return Response(b"corrupt-ipk")
        return Response(ipk)
    raise AssertionError(url)
urllib.request.urlopen = fixture
''',
            encoding="utf-8",
        )

        env = os.environ.copy()
        env["HOME"] = posix_path(home)
        env["PYTHONPATH"] = posix_path(mock)
        env.pop("COUCHSUBS_REQUIRE_TV_PACKAGES", None)
        if failure:
            env["IOS_TV_FAILURE"] = failure
        else:
            env.pop("IOS_TV_FAILURE", None)
        result = subprocess.run(
            [bash_executable(), posix_path(SCRIPT), posix_path(output)],
            cwd=str(ROOT),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        return cache, output / "tv", result

    def assert_previous_release(self, cache: Path, output: Path) -> None:
        expected_properties = (
            "release=v1.0.0\n"
            "couchsubs-androidtv.apk=CouchSubs-androidtv-v1.apk\n"
            "couchsubs-lg.ipk=com.couchsubs.tv_1.0.0_all.ipk\n"
        )
        self.assertEqual((cache / "couchsubs-androidtv.apk").read_bytes(), b"previous-apk")
        self.assertEqual((cache / "couchsubs-lg.ipk").read_bytes(), b"previous-ipk")
        self.assertEqual((cache / "release.properties").read_text(encoding="utf-8"), expected_properties)
        self.assertEqual((output / "couchsubs-androidtv.apk").read_bytes(), b"previous-apk")
        self.assertEqual((output / "couchsubs-lg.ipk").read_bytes(), b"previous-ipk")
        output_properties = (output / "tv-packages.properties").read_text(encoding="utf-8")
        self.assertIn(expected_properties, output_properties)

    def test_ipk_download_failure_keeps_previous_release_pair(self) -> None:
        cache, output, result = self.run_build("download")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_previous_release(cache, output)

    def test_ipk_checksum_failure_keeps_previous_release_pair(self) -> None:
        cache, output, result = self.run_build("checksum")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_previous_release(cache, output)

    def test_successful_download_replaces_the_release_pair(self) -> None:
        cache, output, result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual((cache / "couchsubs-androidtv.apk").read_bytes(), b"previous-apk")
        self.assertEqual((cache / "couchsubs-lg.ipk").read_bytes(), b"new-ipk-v2")
        cache_properties = (cache / "release.properties").read_text(encoding="utf-8")
        self.assertIn("release=v2.0.0\n", cache_properties)
        self.assertIn("com.couchsubs.tv_2.0.0_all.ipk", cache_properties)
        self.assertEqual((output / "couchsubs-lg.ipk").read_bytes(), b"new-ipk-v2")


if __name__ == "__main__":
    unittest.main()
