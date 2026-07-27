#!/usr/bin/env python3
"""Unit tests for build_app.py's platform and format validation."""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_app  # noqa: E402
from scripts import build_msixbundle, verify_linux_portable  # noqa: E402


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
        with mock.patch.object(
            build_app, "host_platform", return_value="linux"
        ):
            with mock.patch.object(
                build_app, "host_arch", return_value="arm64"
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
        with mock.patch.dict(build_app.os.environ, {}, clear=True):
            with mock.patch.object(build_app, "run") as run:
                build_app.prepare_macos_application(Path("/tmp/MDSLens.app"))
        self.assertEqual(
            run.call_args_list,
            [
                mock.call(
                    "codesign", "--force", "--deep", "--sign", "-",
                    "/tmp/MDSLens.app",
                ),
                mock.call(
                    "codesign", "--verify", "--deep", "--strict",
                    "/tmp/MDSLens.app",
                ),
            ],
        )

    def test_windows_msix_manifest_matches_requested_architecture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "bundle"
            bundle.mkdir()
            (bundle / "mdslens.exe").write_bytes(b"MZ")
            with mock.patch.object(build_app, "project_version", return_value="7.0"):
                build_app.stage_windows_msix(bundle, root / "stage", "arm64")
            manifest = (root / "stage/AppxManifest.xml").read_text()
            self.assertIn('ProcessorArchitecture="arm64"', manifest)
            self.assertIn('Version="7.0.0.0"', manifest)
            self.assertIn('Executable="mdslens.exe"', manifest)

    def test_msixbundle_finds_versioned_windows_sdk_makeappx(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            program_files = Path(temporary) / "Program Files (x86)"
            older = program_files / "Windows Kits/10/bin/10.0.22000.0/x64/makeappx.exe"
            newest = program_files / "Windows Kits/10/bin/10.0.26100.0/x64/makeappx.exe"
            older.parent.mkdir(parents=True)
            newest.parent.mkdir(parents=True)
            older.touch()
            newest.touch()
            with mock.patch.dict(
                build_msixbundle.os.environ,
                {
                    "ProgramFiles(x86)": str(program_files),
                    "ProgramFiles": str(Path(temporary) / "Program Files"),
                },
                clear=True,
            ):
                with mock.patch.object(
                    build_msixbundle.shutil, "which", return_value=None
                ):
                    self.assertEqual(
                        build_msixbundle.find_makeappx("makeappx"),
                        str(newest),
                    )

    def test_android_apks_are_generated_from_the_app_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "build/app/outputs/bundle/release/app-release.aab"
            bundle.parent.mkdir(parents=True)
            bundle.write_bytes(b"bundle")
            tool = root / "bundletool.jar"
            tool.write_bytes(b"jar")
            dist = root / "dist"
            dist.mkdir()
            with mock.patch.object(build_app, "ROOT", root):
                with mock.patch.object(build_app, "DIST", dist):
                    with mock.patch.dict(
                        build_app.os.environ,
                        {"BUNDLETOOL_JAR": str(tool)},
                        clear=True,
                    ):
                        with mock.patch.object(build_app, "run") as run:
                            build_app.package_android({"apks"}, no_build=True)
            command = run.call_args.args
            self.assertIn("build-apks", command)
            self.assertIn(f"--bundle={bundle}", command)
            self.assertIn(f"--output={dist / 'mdslens-android.apks'}", command)

    def test_linux_portable_keeps_base_and_display_abis_on_target_system(
        self,
    ) -> None:
        for name in (
            "ld-linux-x86-64.so.2",
            "libc.so.6",
            "libm.so.6",
            "libm-2.31.so",
            "libc-2.31.so",
            "libpthread.so.0",
            "libnss_files.so.2",
            "libnss_files-2.31.so",
            "ld-2.31.so",
            "libstdc++.so.6",
            "libgcc_s.so.1",
            "libgcc_s-16-20260515.so.1",
            "libX11.so.6",
            "libxcb-render.so.0",
            "libwayland-client.so.0",
            "libxkbcommon-x11.so.0",
            "libepoxy.so.0",
            "libEGL.so.1",
            "libGLX.so.0",
            "libdrm_amdgpu.so.1",
            "libgtk-3.so.0",
            "libgdk-3.so.0",
            "libglib-2.0.so.0",
            "libgdk_pixbuf-2.0.so.0",
            "libsecret-1.so.0",
        ):
            self.assertTrue(build_app.is_linux_system_runtime(name), name)
            self.assertIsNotNone(
                verify_linux_portable.SYSTEM_RUNTIME.fullmatch(name),
                name,
            )
        for name in ("libapp.so", "libmds_bridge.so", "libicuuc.so.66"):
            self.assertFalse(build_app.is_linux_system_runtime(name), name)
            self.assertIsNone(
                verify_linux_portable.SYSTEM_RUNTIME.fullmatch(name),
                name,
            )
        self.assertFalse(build_app.is_linux_system_runtime("libffi.so.7"))
        self.assertIsNone(
            verify_linux_portable.SYSTEM_RUNTIME.fullmatch("libffi.so.8")
        )

    def test_linux_ldd_parser_finds_both_dependency_styles(self) -> None:
        self.assertEqual(
            build_app.parse_linux_ldd(
                """
                libgtk-3.so.0 => /usr/lib/libgtk-3.so.0 (0x1234)
                /lib64/ld-linux-x86-64.so.2 (0x5678)
                linux-vdso.so.1 (0x9999)
                """,
                Path("/tmp/mdslens"),
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
                Path("/tmp/mdslens"),
            )

    def test_linux_needed_parser_only_returns_direct_dependencies(self) -> None:
        self.assertEqual(
            build_app.parse_linux_needed(
                """
                 0x0000000000000001 (NEEDED) Shared library: [libgtk-3.so.0]
                 0x000000000000001d (RUNPATH) Library runpath: [$ORIGIN/lib]
                 0x0000000000000001 (NEEDED) Shared library: [libapp.so]
                """
            ),
            ["libgtk-3.so.0", "libapp.so"],
        )

    def test_linux_runtime_paths_are_relative_to_each_elf(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executable = root / "mdslens"
            plugin = root / "lib/plugins/plugin.so"
            plugin.parent.mkdir(parents=True)
            executable.write_bytes(b"\x7fELF")
            plugin.write_bytes(b"\x7fELF")
            with mock.patch.object(build_app.shutil, "which", return_value="/usr/bin/patchelf"):
                with mock.patch.object(build_app, "run") as run:
                    build_app.patch_linux_runtime_paths(root)
            self.assertEqual(
                run.call_args_list,
                [
                    mock.call(
                        "/usr/bin/patchelf",
                        "--set-rpath",
                        "$ORIGIN/lib",
                        str(executable),
                    ),
                    mock.call(
                        "/usr/bin/patchelf",
                        "--set-rpath",
                        "$ORIGIN/..",
                        str(plugin),
                    ),
                ],
            )

    def test_flatpak_exports_png_icon_without_optional_svg_loader(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "mdslens-linux-x64.flatpak"
            with mock.patch.object(
                build_app, "format_tool", return_value="/usr/bin/flatpak"
            ):
                with mock.patch.object(build_app, "replace_tree"):
                    with mock.patch.object(build_app.shutil, "copy2") as copy:
                        with mock.patch.object(build_app, "run"):
                            build_app.package_linux_flatpak(
                                root / "portable", output, "x64", {"flatpak"}
                            )
        icon_calls = [
            call for call in copy.call_args_list
            if Path(call.args[0]).name == "app_icon.png"
        ]
        self.assertEqual(len(icon_calls), 1)
        self.assertEqual(
            Path(icon_calls[0].args[1]).name,
            "com.mdslens.app.png",
        )
        self.assertIn(
            "hicolor/256x256/apps",
            Path(icon_calls[0].args[1]).as_posix(),
        )

    def test_portable_zip_extraction_restores_unix_executable_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "mdslens-linux-x64"
            bundle.mkdir()
            executable = bundle / "mdslens"
            executable.write_bytes(b"\x7fELF")
            executable.chmod(0o755)
            archive = Path(
                shutil.make_archive(
                    str(root / "mdslens-linux-x64"),
                    "zip",
                    root_dir=root,
                    base_dir=bundle.name,
                )
            )

            extracted = verify_linux_portable.extract(archive, root / "output")

            self.assertTrue(os.access(extracted / "mdslens", os.X_OK))


if __name__ == "__main__":
    unittest.main()
