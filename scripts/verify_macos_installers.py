#!/usr/bin/env python3
"""Verify that macOS release artifacts retain their intended install layout."""

from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as etree
from pathlib import Path


class VerificationError(RuntimeError):
    """Raised when a release artifact cannot be installed as documented."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def command(*arguments: str) -> str:
    result = subprocess.run(
        arguments,
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


def _version_tuple(value: str) -> tuple[int, ...]:
    try:
        parts = tuple(int(part) for part in value.split("."))
    except ValueError as error:
        raise VerificationError(f"Invalid macOS version in Mach-O load command: {value}") from error
    require(parts, f"Invalid empty macOS version in Mach-O load command: {value}")
    return parts


def _macho_architectures(path: Path) -> list[str]:
    result = subprocess.run(
        ("lipo", "-archs", str(path)),
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        return []
    return result.stdout.split()


def _macho_minimum_versions(path: Path, architecture: str) -> list[str]:
    output = command("otool", "-arch", architecture, "-l", str(path))
    versions: list[str] = []
    load_command = ""
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("cmd "):
            load_command = stripped
        elif load_command == "cmd LC_BUILD_VERSION" and stripped.startswith("minos "):
            versions.append(stripped.split(maxsplit=1)[1])
        elif load_command == "cmd LC_VERSION_MIN_MACOSX" and stripped.startswith("version "):
            versions.append(stripped.split(maxsplit=1)[1])
    return versions


def verify_macos_runtime_compatibility(app: Path) -> None:
    """Reject embedded Mach-O slices that cannot launch on a supported Mac.

    Flutter's arm64 macOS engine requires macOS 11, while the x86_64 build is
    intentionally kept compatible with Catalina 10.15.  Checking each slice
    catches native assets that silently raise the minimum for the whole x64
    bundle (the objective_c native asset did exactly that in Flutter 3.44).
    """

    maximum_by_architecture = {"x86_64": (10, 15), "arm64": (11, 0)}
    inspected = 0
    for path in sorted(app.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        architectures = _macho_architectures(path)
        if not architectures:
            continue
        inspected += 1
        for architecture in architectures:
            maximum = maximum_by_architecture.get(architecture)
            if maximum is None:
                continue
            versions = _macho_minimum_versions(path, architecture)
            require(
                versions,
                f"Could not determine the macOS minimum for {path.relative_to(app)} "
                f"({architecture})",
            )
            for version in versions:
                require(
                    _version_tuple(version) <= maximum,
                    f"{path.relative_to(app)} ({architecture}) requires macOS {version}; "
                    f"the supported maximum is {'.'.join(map(str, maximum))}",
                )
    require(inspected > 0, f"No Mach-O binaries were found in {app}")


def verify_flutter_runtime_settings(app: Path) -> None:
    """Keep the packaged Flutter engine on Catalina's stable thread model."""

    info_path = app / "Contents/Info.plist"
    require(info_path.is_file(), f"Missing application Info.plist: {info_path}")
    try:
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise VerificationError(f"Could not read {info_path}: {error}") from error
    require(
        info.get("FLTEnableMergedPlatformUIThread") is False,
        "MDSLens.app must explicitly disable Flutter's experimental merged "
        "macOS UI/platform thread for Catalina compatibility",
    )


def verify_application(app: Path) -> None:
    executable = app / "Contents/MacOS/MDSLens"
    require(app.is_dir(), f"Missing app bundle: {app}")
    require(executable.is_file(), f"Missing application executable: {executable}")
    verify_flutter_runtime_settings(app)
    verify_macos_runtime_compatibility(app)


def verify_pkg(package: Path) -> None:
    require(package.is_file(), f"Missing PKG: {package}")
    with tempfile.TemporaryDirectory(prefix="mdslens-pkg-verify-") as temporary:
        expanded = Path(temporary) / "expanded"
        command("pkgutil", "--expand", str(package), str(expanded))
        infos = list(expanded.rglob("PackageInfo"))
        require(len(infos) == 1, f"Expected one PackageInfo in {package}")
        root = etree.parse(infos[0]).getroot()
        require(
            root.attrib.get("install-location") == "/Applications",
            f"{package.name} does not install into /Applications",
        )
        require(
            root.attrib.get("relocatable") == "false",
            f"{package.name} permits bundle relocation",
        )
        relocated = root.findall("./relocate/bundle")
        require(
            not relocated,
            f"{package.name} can relocate MDSLens.app away from /Applications",
        )
        bundle = root.find("bundle")
        require(
            bundle is not None and bundle.attrib.get("path") == "./MDSLens.app",
            f"{package.name} has no top-level MDSLens.app payload",
        )
        bom = infos[0].with_name("Bom")
        require(bom.is_file(), f"{package.name} has no payload BOM")
        payload_paths = set(command("lsbom", "-s", str(bom)).splitlines())
        require(
            "./MDSLens.app" in payload_paths,
            f"{package.name} does not install MDSLens.app at its package root",
        )


def verify_dmg(image: Path) -> None:
    require(image.is_file(), f"Missing DMG: {image}")
    with tempfile.TemporaryDirectory(prefix="mdslens-dmg-verify-") as temporary:
        mount = Path(temporary) / "mount"
        mount.mkdir()
        mounted = False
        try:
            attached = subprocess.run(
                [
                    "hdiutil",
                    "attach",
                    "-readonly",
                    "-nobrowse",
                    "-plist",
                    "-mountpoint",
                    str(mount),
                    str(image),
                ],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if attached.returncode != 0:
                raise VerificationError(
                    f"Could not mount {image}:\n"
                    f"{attached.stderr.decode(errors='replace')}"
                )
            mounted = True
            metadata = plistlib.loads(attached.stdout)
            entities = metadata.get("system-entities", [])
            require(
                any(
                    Path(entity["mount-point"]).resolve() == mount.resolve()
                    for entity in entities
                    if entity.get("mount-point")
                ),
                f"{image.name} did not mount at its requested verification path",
            )
            verify_application(mount / "MDSLens.app")
            applications = mount / "Applications"
            require(
                applications.is_symlink()
                and os.readlink(applications) == "/Applications",
                f"{image.name} is missing its /Applications drag target",
            )
        finally:
            if mounted:
                command("hdiutil", "detach", str(mount))


def extractor_for_7z() -> str:
    for candidate in ("7zz", "7z", "7za"):
        if shutil.which(candidate):
            return candidate
    raise VerificationError("A 7-Zip extractor is required for the 7z artifact check")


def extract_archive(archive: Path, destination: Path) -> None:
    try:
        shutil.unpack_archive(archive, destination)
    except (shutil.ReadError, ValueError) as error:
        raise VerificationError(f"Could not extract {archive}: {error}") from error


def verify_7z_app_archive(archive: Path) -> None:
    """Test and inspect 7z without restoring macOS framework symlink chains.

    7-Zip 26 correctly refuses to materialize a link through another link by
    default. Apple framework bundles intentionally use Version/Current chains,
    so extraction is the wrong validation primitive even though the archive is
    intact. Testing compressed data and validating every recorded path retains
    the security check without weakening 7-Zip's link policy.
    """
    tool = extractor_for_7z()
    command(tool, "t", str(archive))
    listing = command(tool, "l", "-slt", str(archive))
    separator = listing.find("----------")
    require(separator >= 0, f"Could not parse the 7z listing for {archive.name}")
    paths = [
        line[len("Path = ") :]
        for line in listing[separator:].splitlines()
        if line.startswith("Path = ")
    ]
    require(paths, f"{archive.name} contains no archived paths")
    require(
        all(path == "MDSLens.app" or path.startswith("MDSLens.app/") for path in paths),
        f"{archive.name} contains a path outside MDSLens.app",
    )
    require(
        "MDSLens.app/Contents/MacOS/MDSLens" in paths,
        f"{archive.name} is missing the application executable",
    )


def verify_app_archive(archive: Path) -> None:
    require(archive.is_file(), f"Missing archive: {archive}")
    if archive.name.endswith(".7z"):
        verify_7z_app_archive(archive)
        return
    with tempfile.TemporaryDirectory(prefix="mdslens-macos-archive-") as temporary:
        extracted = Path(temporary)
        extract_archive(archive, extracted)
        roots = list(extracted.iterdir())
        require(
            len(roots) == 1 and roots[0].name == "MDSLens.app",
            f"{archive.name} must extract exactly one MDSLens.app bundle",
        )
        verify_application(roots[0])


def verify_xcarchive(archive: Path) -> None:
    require(archive.is_dir(), f"Missing xcarchive: {archive}")
    verify_application(archive / "Products/Applications/MDSLens.app")


def verify_xcarchive_archive(archive: Path) -> None:
    require(archive.is_file(), f"Missing archive: {archive}")
    with tempfile.TemporaryDirectory(prefix="mdslens-macos-xcarchive-") as temporary:
        extracted = Path(temporary)
        extract_archive(archive, extracted)
        roots = list(extracted.iterdir())
        expected_name = archive.name.removesuffix(".zip")
        require(
            len(roots) == 1 and roots[0].name == expected_name,
            f"{archive.name} must extract exactly one {expected_name} bundle",
        )
        verify_xcarchive(roots[0])


def verify_release_directory(directory: Path, architectures: list[str]) -> None:
    for architecture in architectures:
        base = f"mdslens-macos-{architecture}-unsigned"
        verify_application(directory / f"{base}.app")
        verify_pkg(directory / f"{base}.pkg")
        verify_dmg(directory / f"{base}.dmg")
        for suffix in ("zip", "7z", "tar.gz", "tar.xz", "tar.bz2"):
            verify_app_archive(directory / f"{base}.{suffix}")
        xcarchive = directory / f"{base}.xcarchive"
        verify_xcarchive(xcarchive)
        verify_xcarchive_archive(directory / f"{xcarchive.name}.zip")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pkg", type=Path, action="append", default=[])
    parser.add_argument("--dmg", type=Path, action="append", default=[])
    parser.add_argument("--archive", type=Path, action="append", default=[])
    parser.add_argument("--release-directory", type=Path)
    parser.add_argument("--architecture", action="append", default=[])
    args = parser.parse_args()

    if args.release_directory is not None:
        require(args.architecture, "--release-directory requires --architecture")
        verify_release_directory(args.release_directory, args.architecture)
    else:
        require(
            args.pkg or args.dmg or args.archive,
            "Pass --release-directory or at least one artifact to verify",
        )
        for package in args.pkg:
            verify_pkg(package)
        for image in args.dmg:
            verify_dmg(image)
        for archive in args.archive:
            verify_app_archive(archive)

    print("Verified macOS installer and archive layouts.")


if __name__ == "__main__":
    try:
        main()
    except VerificationError as error:
        raise SystemExit(f"MDSLens macOS package verification failed: {error}")
