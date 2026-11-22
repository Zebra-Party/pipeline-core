"""Exercise real upload-result/retry code with fake altool; no keys or network.

Credential setup is deliberately excluded. Tests run each script's upload
section unchanged, intercepting xcrun and sleep through an isolated PATH.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
REJECTION = "ERROR: [altool] A required agreement is missing or has expired. (403)"


class UploadResults(unittest.TestCase):
    def upload(self, platform, responses):
        source = (ROOT / "scripts" / f"upload_{platform}.sh").read_text()
        marker = "attempt=1" if platform != "macos" else 'echo "::group::altool upload (macOS)"'
        section = source[source.index(marker):]
        with tempfile.TemporaryDirectory() as directory:
            task_dir = Path(directory)
            binary = task_dir / "bin"
            binary.mkdir()
            fake = binary / "xcrun"
            fake.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
counter = Path(os.environ["UPLOAD_TEST_COUNTER"])
count = int(counter.read_text()) if counter.exists() else 0
counter.write_text(str(count + 1))
responses = json.loads(os.environ["UPLOAD_TEST_RESPONSES"])
message, code = responses[min(count, len(responses) - 1)]
print(message)
sys.exit(code)
""")
            fake.chmod(0o755)
            sleeper = binary / "sleep"
            sleeper.write_text("#!/bin/sh\nexit 0\n")
            sleeper.chmod(0o755)
            environment = dict(os.environ)
            environment.update({
                "PATH": str(binary) + os.pathsep + os.environ["PATH"],
                "ALTOOL_LOG": str(task_dir / "output.log"),
                "UPLOAD_TEST_COUNTER": str(task_dir / "count"),
                "UPLOAD_TEST_RESPONSES": json.dumps(responses),
                "IPA_PATH": "test.ipa", "PKG_PATH": "test.pkg",
                "APP_STORE_CONNECT_KEY_ID": "test-key",
                "APP_STORE_CONNECT_ISSUER_ID": "test-issuer",
            })
            result = subprocess.run(["bash", "-c", "set -euo pipefail\n" + section],
                                    env=environment, capture_output=True, text=True, timeout=10)
            attempts = int((task_dir / "count").read_text())
            return result, attempts

    def test_zero_exit_apple_error_is_not_success(self):
        for platform in ["ios", "tvos", "macos"]:
            with self.subTest(platform=platform):
                result, count = self.upload(platform, [(REJECTION, 0)])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(count, 1)
                self.assertNotIn("upload succeeded", result.stdout)

    def test_genuine_success(self):
        for platform in ["ios", "tvos", "macos"]:
            with self.subTest(platform=platform):
                result, count = self.upload(platform, [("No errors uploading package. UPLOAD SUCCEEDED", 0)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(count, 1)

    def test_upload_failed_validation_fails_fast(self):
        for platform in ["ios", "tvos", "macos"]:
            with self.subTest(platform=platform):
                result, count = self.upload(platform, [("UPLOAD FAILED with 1 error: Invalid asset", 0)])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(count, 1)

    def test_transient_error_retries_even_with_zero_exit(self):
        for platform in ["ios", "tvos"]:
            with self.subTest(platform=platform):
                result, count = self.upload(platform, [
                    ("ERROR: The network connection was lost. -1005", 0),
                    ("UPLOAD SUCCEEDED", 0),
                ])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(count, 2)

    def test_retry_limit(self):
        for platform in ["ios", "tvos"]:
            with self.subTest(platform=platform):
                result, count = self.upload(platform, [("ERROR: The request timed out", 1)])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(count, 3)

    def test_nonzero_exit_is_failure_without_error_text(self):
        for platform in ["ios", "tvos", "macos"]:
            with self.subTest(platform=platform):
                result, count = self.upload(platform, [("Connection closed", 1)])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(count, 1)


if __name__ == "__main__":
    unittest.main()
