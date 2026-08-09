#!/usr/bin/env python3
"""Unit tests for build_app.py's platform and format validation."""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_app  # noqa: E402
from scripts import (  # noqa: E402
    build_msixbundle,
    verify_icons,
    verify_linux_packages,
    verify_linux_portable,
    verify_macos_installers,
    verify_mobile_packages,
)


class BuildAppTests(unittest.TestCase):
    def test_windows_portable_stage_contains_update_channel_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "bundle"
            bundle.mkdir()
            (bundle / "mdslens.exe").write_bytes(b"application")
            portable = root / "mdslens-windows-x64"

            build_app.stage_windows_portable(bundle, portable, "0.3.2", "x64")

            metadata = json.loads(
                (portable / ".mdslens-portable.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(metadata["product"], "com.mdslens.app")
            self.assertEqual(metadata["platform"], "windows")
            self.assertEqual(metadata["architecture"], "x64")
            self.assertEqual(metadata["executable"], "mdslens.exe")

    def test_linux_portable_stage_contains_update_channel_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "bundle"
            bundle.mkdir()
            (bundle / "mdslens").write_bytes(b"ELF")
            portable = root / "mdslens-linux-x64"
            with mock.patch.object(build_app, "is_elf", return_value=True):
                with mock.patch.object(
                    build_app, "copy_linux_portable_dependencies"
                ):
                    with mock.patch.object(build_app, "patch_linux_runtime_paths"):
                        with mock.patch.object(build_app, "ROOT", root):
                            (root / "packaging/linux").mkdir(parents=True)
                            (root / "packaging/linux/com.mdslens.app.desktop").touch()
                            (
                                root
                                / "packaging/linux/com.mdslens.configuration.xml"
                            ).touch()
                            (root / "linux/runner").mkdir(parents=True)
                            (root / "linux/runner/app_icon.png").touch()
                            build_app.stage_linux_portable(
                                bundle,
                                portable,
                                "1.2.3",
                                "x64",
                            )
            marker = json.loads(
                (portable / ".mdslens-portable.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(marker["product"], "com.mdslens.app")
            self.assertEqual(marker["version"], "1.2.3")
            self.assertEqual(marker["architecture"], "x64")

    def test_linux_package_path_normalization(self) -> None:
        self.assertEqual(
            verify_linux_packages.normalized_paths(
                "./usr/lib/mdslens/mdslens\nusr/bin/mdslens/\n\n"
            ),
            {"usr/lib/mdslens/mdslens", "usr/bin/mdslens"},
        )

    def test_linux_portable_archive_has_a_single_named_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            portable = root / "mdslens-linux-x64"
            portable.mkdir()
            (portable / "mdslens").write_bytes(b"ELF")
            (portable / ".mdslens-portable.json").write_text(
                json.dumps(
                    {
                        "product": "com.mdslens.app",
                        "architecture": "x64",
                        "executable": "mdslens",
                    }
                ),
                encoding="utf-8",
            )
            archive = root / "mdslens-linux-x64.zip"
            with zipfile.ZipFile(archive, "w") as output:
                for path in portable.rglob("*"):
                    output.write(path, path.relative_to(root))

            verify_linux_packages.verify_portable(archive, "x64")

    def test_flatpak_bundle_is_imported_and_checked_as_a_local_remote(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "mdslens-linux-x64.flatpak"
            bundle.touch()
            with mock.patch.object(
                verify_linux_packages,
                "output",
                side_effect=["Imported", "com.mdslens.app\tx86_64\tstable\n"],
            ) as output:
                verify_linux_packages.verify_flatpak(bundle, "x64")

        self.assertEqual(
            output.call_args_list[0].args[:2],
            ("flatpak", "build-import-bundle"),
        )
        self.assertEqual(output.call_args_list[1].args[:2], ("flatpak", "remote-ls"))

    def test_macos_7z_validation_does_not_restore_framework_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "mdslens-macos-arm64-unsigned.7z"
            archive.touch()
            listing = """Header
----------
Path = MDSLens.app
Folder = +

Path = MDSLens.app/Contents/MacOS/MDSLens
Size = 1
"""
            with mock.patch.object(
                verify_macos_installers,
                "command",
                side_effect=["Everything is Ok", listing],
            ):
                with mock.patch.object(
                    verify_macos_installers,
                    "extractor_for_7z",
                    return_value="7zz",
                ):
                    verify_macos_installers.verify_app_archive(archive)

    def test_release_version_prefers_ci_value_then_exact_tag(self) -> None:
        with mock.patch.dict(
            build_app.os.environ, {"MDSLENS_VERSION": "v1.2.3"}, clear=True
        ):
            self.assertEqual(build_app.project_version(), "1.2.3")

        with mock.patch.dict(build_app.os.environ, {}, clear=True):
            with mock.patch.object(
                build_app, "capture", return_value=(0, "v2.4")
            ):
                self.assertEqual(build_app.project_version(), "2.4")

    def test_release_build_number_is_monotonic(self) -> None:
        self.assertEqual(build_app.release_build_number("v0.0.1"), 1)
        self.assertEqual(build_app.release_build_number("0.1.0"), 1000)
        self.assertEqual(build_app.release_build_number("1.2.3"), 1002003)
        with self.assertRaisesRegex(SystemExit, "MINOR/PATCH"):
            build_app.release_build_number("1.1000.0")

    def test_flutter_build_receives_release_version(self) -> None:
        with mock.patch.object(build_app, "project_version", return_value="1.2.3"):
            with mock.patch.object(build_app, "run") as run:
                build_app.flutter_build("macos")
        self.assertEqual(
            run.call_args_list[-1],
            mock.call(
                "flutter",
                "build",
                "macos",
                "--release",
                "--no-pub",
                "--build-name",
                "1.2.3",
                "--build-number",
                "1002003",
            ),
        )

    def test_apple_flutter_build_retries_native_package_resolution(self) -> None:
        failure = subprocess.CalledProcessError(1, ["flutter", "build", "ios"])
        with mock.patch.object(build_app, "project_version", return_value="1.2.3"):
            with mock.patch.object(build_app, "run", side_effect=[None, failure, None]) as run:
                with mock.patch.object(build_app, "clear_flutter_package_checkout") as clear:
                    with mock.patch.object(build_app.time, "sleep") as sleep:
                        build_app.flutter_build("ios")

        self.assertEqual(run.call_count, 3)
        clear.assert_called_once_with("ios")
        sleep.assert_called_once_with(build_app.APPLE_FLUTTER_RETRY_DELAY_SECONDS)

    def test_packaged_application_icon_checks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            windows_executable = root / "mdslens.exe"
            windows_executable.write_bytes(b"MZpackaged")
            verify_icons.verify_windows_executable(windows_executable)

            app = root / "MDSLens.app"
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "Resources").mkdir()
            (contents / "MacOS/MDSLens").write_bytes(b"Mach-O")
            (contents / "Resources/AppIcon.icns").write_bytes(b"icns")
            with (contents / "Info.plist").open("wb") as stream:
                plistlib.dump(
                    {
                        "CFBundleExecutable": "MDSLens",
                        "CFBundleIconName": "AppIcon",
                    },
                    stream,
                )
            verify_icons.verify_macos_application(app)

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

    def test_macos_dmg_stage_has_a_real_applications_shortcut(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "source/MDSLens.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/MDSLens").write_bytes(b"Mach-O")
            stage = root / "dmg"

            build_app.stage_macos_dmg(app, stage)

            self.assertTrue((stage / "MDSLens.app").is_dir())
            applications = stage / "Applications"
            self.assertTrue(applications.is_symlink())
            self.assertEqual(os.readlink(applications), "/Applications")

    def test_macos_pkg_payload_is_fixed_to_applications(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "source/MDSLens.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/MDSLens").write_bytes(b"Mach-O")
            output = root / "MDSLens.pkg"
            staging = root / "pkg"

            with mock.patch.object(build_app, "run") as run:
                build_app.build_macos_pkg(app, output, "0.3.39", staging)

            payload = staging / "payload"
            self.assertTrue((payload / "MDSLens.app").is_dir())
            component_plist = staging / "components.plist"
            with component_plist.open("rb") as stream:
                components = plistlib.load(stream)
            self.assertEqual(components[0]["RootRelativeBundlePath"], "MDSLens.app")
            self.assertFalse(components[0]["BundleIsRelocatable"])
            self.assertTrue(components[0]["BundleIsVersionChecked"])
            self.assertTrue(components[0]["BundleHasStrictIdentifier"])
            self.assertEqual(components[0]["BundleOverwriteAction"], "upgrade")
            self.assertEqual(
                run.call_args.args,
                (
                    "pkgbuild",
                    "--root",
                    str(payload),
                    "--component-plist",
                    str(component_plist),
                    "--identifier",
                    "com.mdslens.app",
                    "--version",
                    "0.3.39",
                    "--install-location",
                    "/Applications",
                    "--ownership",
                    "recommended",
                    str(output),
                ),
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

    def test_windows_installer_rejects_the_wrong_native_architecture(self) -> None:
        self.assertEqual(
            build_app.windows_installer_architecture("x64"),
            "x64compatible",
        )
        self.assertEqual(
            build_app.windows_installer_architecture("arm64"),
            "arm64",
        )

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

    def test_android_apks_use_password_files_for_release_signing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "build/app/outputs/bundle/release/app-release.aab"
            bundle.parent.mkdir(parents=True)
            bundle.write_bytes(b"bundle")
            tool = root / "bundletool.jar"
            tool.write_bytes(b"jar")
            keystore = root / "release.jks"
            keystore.write_bytes(b"keystore")
            dist = root / "dist"
            dist.mkdir()
            observed: dict[str, object] = {}

            def inspect_command(*command: str, **_: object) -> None:
                observed["command"] = command
                store_argument = next(
                    value for value in command if value.startswith("--ks-pass=")
                )
                key_argument = next(
                    value for value in command if value.startswith("--key-pass=")
                )
                store_file = Path(store_argument.removeprefix("--ks-pass=file:"))
                key_file = Path(key_argument.removeprefix("--key-pass=file:"))
                observed["store_password"] = store_file.read_text()
                observed["key_password"] = key_file.read_text()
                observed["store_mode"] = store_file.stat().st_mode & 0o777
                observed["key_mode"] = key_file.stat().st_mode & 0o777

            with mock.patch.object(build_app, "ROOT", root):
                with mock.patch.object(build_app, "DIST", dist):
                    with mock.patch.dict(
                        build_app.os.environ,
                        {
                            "BUNDLETOOL_JAR": str(tool),
                            "MDSLENS_ANDROID_KEYSTORE": str(keystore),
                            "MDSLENS_ANDROID_KEY_ALIAS": "mdslens",
                            "MDSLENS_ANDROID_STORE_PASSWORD": "store-secret",
                            "MDSLENS_ANDROID_KEY_PASSWORD": "key-secret",
                        },
                        clear=True,
                    ):
                        with mock.patch.object(
                            build_app, "run", side_effect=inspect_command
                        ):
                            build_app.package_android({"apks"}, no_build=True)

            command = observed["command"]
            self.assertIn(f"--ks={keystore}", command)
            self.assertIn("--ks-key-alias=mdslens", command)
            self.assertEqual(observed["store_password"], "store-secret")
            self.assertEqual(observed["key_password"], "key-secret")
            self.assertEqual(observed["store_mode"], 0o600)
            self.assertEqual(observed["key_mode"], 0o600)

    def test_unsigned_ipa_has_a_single_payload_application(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ipa = root / "mdslens-ios-arm64-unsigned.ipa"
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/MDSLens.app/Info.plist", b"plist")

            with mock.patch.object(
                verify_mobile_packages, "verify_unsigned_apple_app"
            ) as verify_app:
                verify_mobile_packages.verify_ipa(ipa)

            self.assertEqual(verify_app.call_count, 1)
            self.assertEqual(verify_app.call_args.args[0].name, "MDSLens.app")

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
