#!/usr/bin/env python3
"""Verify install roots and portable layouts of Linux release artifacts."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path


class VerificationError(RuntimeError):
    """Raised when a package would not install with the documented layout."""


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


def normalized_paths(lines: str) -> set[str]:
    paths: set[str] = set()
    for line in lines.splitlines():
        path = line.strip()
        if not path:
            continue
        if path.startswith("./"):
            path = path[2:]
        paths.add(path.rstrip("/"))
    return paths


def require_paths(paths: set[str], package: Path) -> None:
    prefix = "usr/"
    required = {
        f"{prefix}lib/mdslens/mdslens",
        f"{prefix}share/applications/com.mdslens.app.desktop",
        f"{prefix}share/icons/hicolor/512x512/apps/com.mdslens.app.png",
        f"{prefix}share/mime/packages/com.mdslens.configuration.xml",
    }
    required.add("usr/bin/mdslens")
    missing = sorted(required - paths)
    require(
        not missing,
        f"{package.name} is missing required installed path(s): {', '.join(missing)}",
    )


def verify_deb(package: Path, architecture: str) -> None:
    require(package.is_file(), f"Missing DEB: {package}")
    package_name = output(
        "dpkg-deb", "--field", str(package), "Package"
    ).strip()
    package_architecture = output(
        "dpkg-deb", "--field", str(package), "Architecture"
    ).strip()
    require(
        package_name == "mdslens"
        and package_architecture
        == {"x64": "amd64", "arm64": "arm64"}[architecture],
        f"{package.name} has unexpected DEB metadata: "
        f"package={package_name!r}, architecture={package_architecture!r}",
    )
    listing = output("dpkg-deb", "--contents", str(package))
    for expected in (
        "./usr/lib/mdslens/mdslens",
        "./usr/bin/mdslens",
        "./usr/share/applications/com.mdslens.app.desktop",
        "./usr/share/icons/hicolor/512x512/apps/com.mdslens.app.png",
        "./usr/share/mime/packages/com.mdslens.configuration.xml",
    ):
        require(expected in listing, f"{package.name} is missing {expected}")


def verify_rpm(package: Path, architecture: str) -> None:
    require(package.is_file(), f"Missing RPM: {package}")
    expected_arch = {"x64": "x86_64", "arm64": "aarch64"}[architecture]
    metadata = output("rpm", "-qp", "--qf", "%{NAME}\n%{ARCH}\n", str(package))
    require(
        metadata.splitlines() == ["mdslens", expected_arch],
        f"{package.name} has unexpected RPM metadata: {metadata!r}",
    )
    paths = {path.lstrip("/") for path in output("rpm", "-qlp", str(package)).splitlines()}
    require_paths(paths, package)


def verify_arch(package: Path) -> None:
    require(package.is_file(), f"Missing Arch package: {package}")
    paths = normalized_paths(output("tar", "-tf", str(package)))
    require_paths(paths, package)
    metadata = output("tar", "-xOf", str(package), "./.PKGINFO")
    require("pkgname = mdslens" in metadata, f"{package.name} has no MDSLens PKGINFO")


def verify_appimage(image: Path) -> None:
    require(image.is_file(), f"Missing AppImage: {image}")
    image = image.resolve()
    with tempfile.TemporaryDirectory(prefix="mdslens-appimage-verify-") as temporary:
        extracted = Path(temporary)
        output(str(image), "--appimage-extract", cwd=extracted)
        root = extracted / "squashfs-root"
        require(root.is_dir(), f"{image.name} did not create squashfs-root")
        require((root / "AppRun").exists(), f"{image.name} is missing AppRun")
        paths = {
            path.relative_to(root).as_posix()
            for path in root.rglob("*")
            if path.is_file() or path.is_symlink()
        }
        required = {
            "AppRun",
            "com.mdslens.app.desktop",
            "com.mdslens.app.png",
            "usr/lib/mdslens/mdslens",
            "usr/lib/mdslens/.mdslens-portable.json",
            "usr/lib/mdslens/share/applications/com.mdslens.app.desktop",
            "usr/lib/mdslens/share/icons/hicolor/512x512/apps/com.mdslens.app.png",
            "usr/lib/mdslens/share/mime/packages/com.mdslens.configuration.xml",
        }
        missing = sorted(required - paths)
        require(
            not missing,
            f"{image.name} is missing required AppImage path(s): {', '.join(missing)}",
        )


def verify_flatpak(bundle: Path, architecture: str) -> None:
    require(bundle.is_file(), f"Missing Flatpak bundle: {bundle}")
    bundle = bundle.resolve()
    expected_arch = {"x64": "x86_64", "arm64": "aarch64"}[architecture]
    with tempfile.TemporaryDirectory(prefix="mdslens-flatpak-verify-") as temporary:
        repository = Path(temporary) / "repo"
        output(
            "ostree",
            f"--repo={repository}",
            "init",
            "--mode=archive-z2",
        )
        output("flatpak", "build-import-bundle", str(repository), str(bundle))
        description = output(
            "flatpak",
            "remote-ls",
            "--columns=application,arch,branch",
            repository.resolve().as_uri(),
        )
        rows = [line.split() for line in description.splitlines()]
        require(
            any(
                "com.mdslens.app" in row
                and expected_arch in row
                and "stable" in row
                for row in rows
            ),
            f"{bundle.name} is not a com.mdslens.app {expected_arch} "
            f"stable Flatpak bundle: {description!r}",
        )


def verify_snap(package: Path, architecture: str) -> None:
    require(package.is_file(), f"Missing Snap: {package}")
    with tempfile.TemporaryDirectory(prefix="mdslens-snap-verify-") as temporary:
        destination = Path(temporary) / "root"
        output(
            "unsquashfs",
            "-d",
            str(destination),
            "-no-progress",
            str(package),
            "meta/snap.yaml",
        )
        metadata_path = destination / "meta/snap.yaml"
        require(
            metadata_path.is_file(),
            f"{package.name} is missing meta/snap.yaml",
        )
        metadata = metadata_path.read_text(encoding="utf-8")
    expected_arch = {"x64": "amd64", "arm64": "arm64"}[architecture]
    require("name: mdslens" in metadata, f"{package.name} has no MDSLens Snap metadata")
    require(expected_arch in metadata, f"{package.name} has wrong Snap architecture")
    require(
        "command: lib/mdslens/mdslens" in metadata,
        f"{package.name} does not launch its packaged MDSLens executable",
    )
    listing = output("unsquashfs", "-ll", str(package))
    for expected in (
        "lib/mdslens/mdslens",
        "meta/gui/com.mdslens.app.desktop",
        "meta/snap.yaml",
    ):
        require(expected in listing, f"{package.name} is missing {expected}")


def extract_portable(archive: Path, destination: Path) -> None:
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as source:
            source.extractall(destination)
        return
    if archive.name.endswith(".7z"):
        tool = next(
            (candidate for candidate in ("7zz", "7z", "7za") if shutil.which(candidate)),
            None,
        )
        require(tool is not None, "7-Zip is required to verify the 7z package")
        output(tool, "x", "-y", str(archive), f"-o{destination}")
        return
    try:
        shutil.unpack_archive(archive, destination)
    except (shutil.ReadError, ValueError) as error:
        raise VerificationError(f"Could not extract {archive}: {error}") from error


def verify_portable(archive: Path, architecture: str) -> None:
    require(archive.is_file(), f"Missing portable archive: {archive}")
    expected_root = f"mdslens-linux-{architecture}"
    with tempfile.TemporaryDirectory(prefix="mdslens-portable-layout-") as temporary:
        extracted = Path(temporary)
        extract_portable(archive, extracted)
        roots = [path for path in extracted.iterdir() if path.is_dir()]
        require(
            len(roots) == 1 and roots[0].name == expected_root,
            f"{archive.name} must extract exactly one {expected_root} directory",
        )
        root = roots[0]
        metadata_path = root / ".mdslens-portable.json"
        require(metadata_path.is_file(), f"{archive.name} has no portable metadata")
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        require(
            metadata.get("product") == "com.mdslens.app"
            and metadata.get("architecture") == architecture
            and metadata.get("executable") == "mdslens",
            f"{archive.name} has invalid portable metadata",
        )
        require((root / "mdslens").is_file(), f"{archive.name} is missing mdslens")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--architecture", choices=("x64", "arm64"), required=True)
    parser.add_argument("--deb", type=Path, action="append", default=[])
    parser.add_argument("--rpm", type=Path, action="append", default=[])
    parser.add_argument("--arch-package", type=Path, action="append", default=[])
    parser.add_argument("--appimage", type=Path, action="append", default=[])
    parser.add_argument("--flatpak", type=Path, action="append", default=[])
    parser.add_argument("--snap", type=Path, action="append", default=[])
    parser.add_argument("--portable", type=Path, action="append", default=[])
    args = parser.parse_args()

    inputs = (
        args.deb
        + args.rpm
        + args.arch_package
        + args.appimage
        + args.flatpak
        + args.snap
        + args.portable
    )
    require(inputs, "Pass at least one package to verify")
    for package in args.deb:
        verify_deb(package, args.architecture)
    for package in args.rpm:
        verify_rpm(package, args.architecture)
    for package in args.arch_package:
        verify_arch(package)
    for image in args.appimage:
        verify_appimage(image)
    for bundle in args.flatpak:
        verify_flatpak(bundle, args.architecture)
    for package in args.snap:
        verify_snap(package, args.architecture)
    for archive in args.portable:
        verify_portable(archive, args.architecture)
    print("Verified Linux package installation and portable layouts.")


if __name__ == "__main__":
    try:
        main()
    except VerificationError as error:
        raise SystemExit(f"MDSLens Linux package verification failed: {error}")
