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

    def test_macos_application_is_ad_hoc_signed_without_credentials(self) -> None:
        with (
            mock.patch.dict(build_app.os.environ, {}, clear=True),
            mock.patch.object(build_app, "run") as run,
        ):
            build_app.prepare_macos_application(Path("/tmp/MdsScope.app"))
        self.assertEqual(
            run.call_args_list,
            [
                mock.call(
                    "codesign", "--force", "--deep", "--sign", "-",
                    "/tmp/MdsScope.app",
                ),
                mock.call(
                    "codesign", "--verify", "--deep", "--strict",
                    "/tmp/MdsScope.app",
                ),
            ],
        )

    def test_linux_portable_keeps_glibc_on_target_system(self) -> None:
        for name in (
            "ld-linux-x86-64.so.2",
            "libc.so.6",
            "libm.so.6",
            "libpthread.so.0",
            "libnss_files.so.2",
        ):
            self.assertTrue(build_app.is_linux_system_runtime(name), name)
        for name in ("libgtk-3.so.0", "libstdc++.so.6", "libX11.so.6"):
            self.assertFalse(build_app.is_linux_system_runtime(name), name)

    def test_linux_ldd_parser_finds_both_dependency_styles(self) -> None:
        self.assertEqual(
            build_app.parse_linux_ldd(
                """
                libgtk-3.so.0 => /usr/lib/libgtk-3.so.0 (0x1234)
                /lib64/ld-linux-x86-64.so.2 (0x5678)
                linux-vdso.so.1 (0x9999)
                """,
                Path("/tmp/mdsscope"),
            ),
            [
                Path("/usr/lib/libgtk-3.so.0"),
                Path("/lib64/ld-linux-x86-64.so.2"),
            ],
        )

    def test_linux_ldd_parser_rejects_missing_dependencies(self) -> None:
        with self.assertRaisesRegex(SystemExit, "Unresolved Linux dependency"):
            build_app.parse_linux_ldd(
                "libmissing.so => not found",
                Path("/tmp/mdsscope"),
            )


if __name__ == "__main__":
    unittest.main()
