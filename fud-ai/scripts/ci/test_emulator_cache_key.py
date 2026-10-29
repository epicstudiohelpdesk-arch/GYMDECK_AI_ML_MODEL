#!/usr/bin/env python3
"""Offline tests for emulator_cache_key.py (the Android emulator snapshot cache key).

The fixture is trimmed from real `sdkmanager --list --channel=0` output. Run:
    python3 -m unittest scripts/ci/test_emulator_cache_key.py
"""
from __future__ import annotations

import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import emulator_cache_key as key  # noqa: E402

IMAGE = "system-images;android-36;google_apis;x86_64"
LISTING = """\
Loading package information...                                                  Loading local repository...
Installed packages:
  Path                                        | Version | Description                     | Location
  -------                                     | ------- | -------                         | -------
  emulator                                    | 36.6.11 | Android Emulator                | emulator
  system-images;android-36;google_apis;x86_64 | 6       | Google APIs Intel x86_64 Atom   | system-images/android-36/google_apis/x86_64

Available Packages:
  Path                                              | Version | Description
  -------                                           | ------- | -------
  emulator                                          | 37.2.12 | Android Emulator
  system-images;android-36;google_apis;arm64-v8a    | 7       | Google APIs ARM 64 v8a System Image
  system-images;android-36;google_apis;x86_64       | 7       | Google APIs Intel x86_64 Atom System Image
  system-images;android-36;google_apis_ps16k;x86_64 | 9       | 16 KB Page Size Google APIs Intel x86_64

Available Updates:
  ID       | Installed | Available
  -------  | -------   | -------
  emulator | 36.6.11   | 37.2.12
"""


class SnapshotVersionTests(unittest.TestCase):
    def test_reads_the_versions_that_will_be_installed(self) -> None:
        # The latest available versions, not what the runner image already has.
        self.assertEqual(
            key.snapshot_versions(LISTING, IMAGE), {"emulator": "37.2.12", "system_image": "7"}
        )

    def test_matches_the_exact_image_path(self) -> None:
        packages = key.available_packages(LISTING)
        self.assertEqual(packages["system-images;android-36;google_apis_ps16k;x86_64"], "9")
        self.assertNotIn("Path", packages)
        self.assertNotIn("-------", packages)

    def test_missing_or_odd_versions_fail(self) -> None:
        for listing in (
            LISTING.replace("  emulator                                          | 37.2.12", "  other | 1"),
            LISTING.replace("Available Packages:", "Something else:"),
            LISTING.replace("| 37.2.12 |", "| latest |"),
            "",
        ):
            with self.subTest(listing=listing[:40]), self.assertRaises(SystemExit):
                key.snapshot_versions(listing, IMAGE)
        with self.assertRaises(SystemExit):
            key.snapshot_versions(LISTING, "system-images;android-99;google_apis;x86_64")

    def test_writes_github_outputs(self) -> None:
        with tempfile.NamedTemporaryFile("r", suffix=".out") as out, \
                mock.patch.dict(os.environ, {"GITHUB_OUTPUT": out.name}), \
                mock.patch.object(sys, "stdin", io.StringIO(LISTING)), redirect_stdout(io.StringIO()):
            key.main(["--image", IMAGE])
            self.assertEqual(Path(out.name).read_text(), "emulator=37.2.12\nsystem_image=7\n")


if __name__ == "__main__":
    unittest.main()
