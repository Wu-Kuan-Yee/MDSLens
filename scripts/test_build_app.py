#!/usr/bin/env python3
"""Unit tests for build_app.py's platform and format validation."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_app  # noqa: E402


class BuildAppTests(unittest.TestCase):
    def test_format_names_are_validated_per_platform(self) -> None:
        self.assertEqual(
            build_app.normalize_formats(["windows"], ["zip", "tar.xz"]),
            {"zip", "tar.xz"},
        )
        with self.assertRaisesRegex(SystemExit, "Unsupported format"):
            build_app.normalize_formats(["windows"], ["apk"])

    def test_appimage_spelling_is_case_insensitive(self) -> None:
        self.assertEqual(
            build_app.normalize_formats(["linux"], ["appimage"]),
            {"AppImage"},
        )

    def test_all_cannot_be_mixed_with_explicit_formats(self) -> None:
        with self.assertRaisesRegex(SystemExit, "cannot be combined"):
            build_app.normalize_formats(["linux"], ["all", "zip"])

    def test_each_selected_platform_needs_an_output_format(self) -> None:
        with self.assertRaisesRegex(SystemExit, "No requested format applies to: android"):
            build_app.normalize_formats(["windows", "android"], ["zip"])
        self.assertEqual(
            build_app.normalize_formats(["windows", "android"], ["zip", "apk"]),
            {"zip", "apk"},
        )

    def test_impossible_cross_host_desktop_build_is_rejected(self) -> None:
        with mock.patch.object(build_app, "host_platform", return_value="linux"):
            with self.assertRaisesRegex(SystemExit, "windows host"):
                build_app.validate_platforms(["windows"], "x64")

    def test_matching_native_target_is_accepted(self) -> None:
        with (
            mock.patch.object(build_app, "host_platform", return_value="linux"),
            mock.patch.object(build_app, "host_arch", return_value="arm64"),
        ):
            build_app.validate_platforms(["linux", "android"], "arm64")

    def test_sdkmanager_is_found_in_modern_android_sdk_layout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            executable = "sdkmanager.bat" if build_app.host_platform() == "windows" else "sdkmanager"
            manager = Path(temporary) / "cmdline-tools" / "latest" / "bin" / executable
            manager.parent.mkdir(parents=True)
            manager.touch()
            self.assertEqual(build_app.find_sdkmanager(Path(temporary)), manager)


if __name__ == "__main__":
    unittest.main()
