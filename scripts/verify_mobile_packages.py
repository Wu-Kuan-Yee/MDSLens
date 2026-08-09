#!/usr/bin/env python3
"""Verify Android and unsigned Apple mobile release artifact layouts."""

from __future__ import annotations

import argparse
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path


class VerificationError(RuntimeError):
    """Raised when a mobile artifact cannot be handed to its package manager."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def output(*arguments: str, cwd: Path | None = None) -> str:
    result = subprocess.run(
        arguments,
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        raise VerificationError(
            f"{' '.join(arguments)} failed ({result.returncode}):\n{result.stdout}"
        )
    return result.stdout


def verify_apk(apk: Path, aapt: Path, expected_abis: set[str]) -> None:
    require(apk.is_file(), f"Missing APK: {apk}")
    badging = output(str(aapt), "dump", "badging", str(apk))
    require(
        "package: name='com.mdslens.app'" in badging,
        f"{apk.name} has the wrong Android application id",
    )
    native_line = next(
        (line for line in badging.splitlines() if line.startswith("native-code:")),
        "",
    )
    actual_abis = {
        part.strip("'") for part in native_line.removeprefix("native-code:").split()
    }
    require(
        actual_abis == expected_abis,
        f"{apk.name} contains ABIs {sorted(actual_abis)}, expected {sorted(expected_abis)}",
    )


def verify_android(directory: Path, aapt: Path, bundletool: Path) -> None:
    require(aapt.is_file(), f"aapt was not found: {aapt}")
    require(bundletool.is_file(), f"bundletool was not found: {bundletool}")
    expected = {
        "mdslens-android-armv7.apk": {"armeabi-v7a"},
        "mdslens-android-arm64.apk": {"arm64-v8a"},
        "mdslens-android-x64.apk": {"x86_64"},
        "mdslens-android-universal.apk": {
            "armeabi-v7a",
            "arm64-v8a",
            "x86_64",
        },
    }
    for name, abis in expected.items():
        verify_apk(directory / name, aapt, abis)

    bundle = directory / "mdslens-android-universal.aab"
    require(bundle.is_file(), f"Missing Android App Bundle: {bundle}")
    output("java", "-jar", str(bundletool), "validate", f"--bundle={bundle}")

    archive = directory / "mdslens-android.apks"
    require(archive.is_file(), f"Missing Android APK set: {archive}")
    with tempfile.TemporaryDirectory(prefix="mdslens-apks-layout-") as temporary:
        root = Path(temporary)
        with zipfile.ZipFile(archive) as source:
            source.extractall(root)
        apks = sorted(root.rglob("*.apk"))
        require(apks, f"{archive.name} contains no APKs")
        for apk in apks:
            badging = output(str(aapt), "dump", "badging", str(apk))
            require(
                "package: name='com.mdslens.app'" in badging,
                f"{archive.name} contains an APK with the wrong application id: {apk.name}",
            )


def app_info(app: Path) -> dict[str, object]:
    info = app / "Info.plist"
    require(info.is_file(), f"{app} has no Info.plist")
    with info.open("rb") as stream:
        return plistlib.load(stream)


def verify_unsigned_apple_app(app: Path) -> None:
    require(app.is_dir(), f"Missing Apple application bundle: {app}")
    info = app_info(app)
    require(
        info.get("CFBundleIdentifier") == "com.mdslens.app",
        f"{app} has the wrong bundle identifier",
    )
    families = {int(value) for value in info.get("UIDeviceFamily", [])}
    require(
        families == {1, 2},
        f"{app} must support both iPhone and iPad; UIDeviceFamily={sorted(families)}",
    )
    executable_name = str(info.get("CFBundleExecutable", "Runner"))
    executable = app / executable_name
    require(executable.is_file(), f"{app} is missing its executable: {executable_name}")
    architectures = set(output("lipo", "-archs", str(executable)).split())
    require(
        architectures == {"arm64"},
        f"{app} has architectures {sorted(architectures)}, expected arm64",
    )
    require(
        not any(app.rglob("_CodeSignature")),
        f"{app} unexpectedly contains code-signing material",
    )
    require(
        not any(app.rglob("embedded.mobileprovision")),
        f"{app} unexpectedly contains a provisioning profile",
    )


def seven_zip() -> str:
    tool = next(
        (candidate for candidate in ("7zz", "7z", "7za") if shutil.which(candidate)),
        None,
    )
    require(tool is not None, "7-Zip is required to verify the 7z package")
    return str(tool)


def extract_archive(archive: Path, destination: Path) -> None:
    if archive.suffix == ".zip" or archive.suffix == ".ipa":
        with zipfile.ZipFile(archive) as source:
            source.extractall(destination)
        return
    if archive.suffix == ".7z":
        output(seven_zip(), "x", "-y", str(archive), f"-o{destination}")
        return
    try:
        shutil.unpack_archive(archive, destination)
    except (shutil.ReadError, ValueError) as error:
        raise VerificationError(f"Could not extract {archive}: {error}") from error


def verify_ipa(ipa: Path) -> None:
    require(ipa.is_file(), f"Missing IPA: {ipa}")
    with tempfile.TemporaryDirectory(prefix="mdslens-ipa-layout-") as temporary:
        root = Path(temporary)
        extract_archive(ipa, root)
        top_level = list(root.iterdir())
        require(
            len(top_level) == 1 and top_level[0].name == "Payload",
            f"{ipa.name} must contain exactly one Payload directory",
        )
        apps = list(top_level[0].glob("*.app"))
        require(
            len(apps) == 1 and apps[0].name == "MDSLens.app",
            f"{ipa.name} must contain Payload/MDSLens.app",
        )
        verify_unsigned_apple_app(apps[0])


def verify_apple_archive(archive: Path) -> None:
    require(archive.is_file(), f"Missing Apple archive: {archive}")
    with tempfile.TemporaryDirectory(prefix="mdslens-apple-layout-") as temporary:
        root = Path(temporary)
        extract_archive(archive, root)
        top_level = list(root.iterdir())
        require(
            len(top_level) == 1
            and top_level[0].name == "MDSLens.app"
            and top_level[0].is_dir(),
            f"{archive.name} must extract exactly one MDSLens.app",
        )
        verify_unsigned_apple_app(top_level[0])


def verify_apple_xcarchive_archive(archive: Path) -> None:
    require(archive.is_file(), f"Missing Apple xcarchive ZIP: {archive}")
    with tempfile.TemporaryDirectory(
        prefix="mdslens-apple-xcarchive-layout-"
    ) as temporary:
        root = Path(temporary)
        extract_archive(archive, root)
        top_level = list(root.iterdir())
        expected_name = archive.name.removesuffix(".zip")
        require(
            len(top_level) == 1
            and top_level[0].name == expected_name
            and top_level[0].is_dir(),
            f"{archive.name} must extract exactly one {expected_name}",
        )
        verify_unsigned_apple_app(
            top_level[0] / "Products/Applications/MDSLens.app"
        )


def verify_apple(directory: Path) -> None:
    for platform in ("ios", "ipados"):
        base = f"mdslens-{platform}-arm64-unsigned"
        verify_unsigned_apple_app(directory / f"{base}.app")
        verify_ipa(directory / f"{base}.ipa")
        for extension in ("zip", "7z", "tar.gz", "tar.xz", "tar.bz2"):
            verify_apple_archive(directory / f"{base}.{extension}")
        archive = directory / f"{base}.xcarchive"
        verify_unsigned_apple_app(archive / "Products/Applications/MDSLens.app")
        verify_apple_xcarchive_archive(directory / f"{base}.xcarchive.zip")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--android", type=Path)
    parser.add_argument("--aapt", type=Path)
    parser.add_argument("--bundletool", type=Path)
    parser.add_argument("--apple", type=Path)
    args = parser.parse_args()
    require(args.android or args.apple, "Pass --android or --apple")
    if args.android:
        require(args.aapt is not None, "--android requires --aapt")
        require(args.bundletool is not None, "--android requires --bundletool")
        verify_android(args.android, args.aapt, args.bundletool)
        print("Verified Android application identity, ABIs, and package layouts.")
    if args.apple:
        verify_apple(args.apple)
        print("Verified unsigned iOS/iPadOS identities, architectures, and layouts.")


if __name__ == "__main__":
    try:
        main()
    except VerificationError as error:
        raise SystemExit(f"MDSLens mobile package verification failed: {error}")
