#!/usr/bin/env python3
"""Generate the machine-readable update manifest for a GitHub release."""

from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path


REPOSITORY = "Wu-Kuan-Yee/MDSLens"


def normalized_version(value: str) -> str:
    match = re.fullmatch(
        r"v?(\d+)\.(\d+)(?:\.(\d+))?",
        value.strip(),
        re.IGNORECASE,
    )
    if match is None:
        raise ValueError("version must be vMAJOR.MINOR[.PATCH]")
    return ".".join(group for group in match.groups() if group is not None)


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def classify_asset(name: str) -> dict[str, str] | None:
    patterns: tuple[
        tuple[re.Pattern[str], str, str],
        ...,
    ] = (
        (
            re.compile(r"^mdslens-windows-(x64|arm64)-setup\.exe$"),
            "windows",
            "launch-installer",
        ),
        (
            re.compile(r"^mdslens-windows-(x64|arm64)\.msi$"),
            "windows",
            "launch-installer",
        ),
        (
            re.compile(r"^mdslens-windows-(x64|arm64)\.zip$"),
            "windows",
            "self-replace",
        ),
        (
            re.compile(r"^mdslens-macos-(arm64|x64|universal)-unsigned\.zip$"),
            "macos",
            "self-replace",
        ),
        (
            re.compile(r"^mdslens-macos-(arm64|x64|universal)-unsigned\.dmg$"),
            "macos",
            "open-package",
        ),
        (
            re.compile(
                r"^mdslens-linux-(x64|arm64)\."
                r"(AppImage|deb|rpm|pkg\.tar\.zst|pkg\.tar\.xz)$"
            ),
            "linux",
            "open-package",
        ),
        (
            re.compile(r"^mdslens-linux-(x64|arm64)\.(tar\.gz)$"),
            "linux",
            "self-replace",
        ),
        (
            re.compile(r"^mdslens-android-(universal|armv7|arm64|x64)\.apk$"),
            "android",
            "system-installer",
        ),
        (
            re.compile(r"^mdslens-(ios|ipados)-arm64-unsigned\.ipa$"),
            "apple-mobile",
            "manual",
        ),
    )
    for pattern, platform, strategy in patterns:
        match = pattern.fullmatch(name)
        if match is None:
            continue
        architecture = match.group(1)
        package_format = Path(name).suffix.removeprefix(".").lower()
        if platform == "linux":
            package_format = match.group(2)
        if platform == "apple-mobile":
            platform = match.group(1)
            architecture = "arm64"
        return {
            "platform": platform,
            "architecture": architecture,
            "format": package_format,
            "strategy": strategy,
        }
    return None


def generate_manifest(artifacts: Path, version: str) -> dict[str, object]:
    normalized = normalized_version(version)
    tag = f"v{normalized}"
    assets: list[dict[str, object]] = []
    for path in sorted(artifacts.iterdir()):
        if not path.is_file():
            continue
        classification = classify_asset(path.name)
        if classification is None:
            continue
        assets.append(
            {
                "name": path.name,
                **classification,
                "size": path.stat().st_size,
                "sha256": digest(path),
            }
        )
    if not assets:
        raise ValueError("no supported update assets were found")
    return {
        "schema_version": 1,
        "version": normalized,
        "tag": tag,
        "release_url": f"https://github.com/{REPOSITORY}/releases/tag/{tag}",
        "assets": assets,
    }


def toml_string(value: str) -> str:
    """Return a basic TOML string without depending on a writer package."""
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\b", "\\b")
        .replace("\t", "\\t")
        .replace("\n", "\\n")
        .replace("\f", "\\f")
        .replace("\r", "\\r")
    )
    return f'"{escaped}"'


def serialize_manifest(manifest: dict[str, object]) -> str:
    lines = [
        f"schema_version = {manifest['schema_version']}",
        f"version = {toml_string(str(manifest['version']))}",
        f"tag = {toml_string(str(manifest['tag']))}",
        f"release_url = {toml_string(str(manifest['release_url']))}",
    ]
    for asset in manifest["assets"]:
        if not isinstance(asset, dict):
            raise TypeError("manifest asset must be a table")
        lines.extend(
            [
                "",
                "[[assets]]",
                f"name = {toml_string(str(asset['name']))}",
                f"platform = {toml_string(str(asset['platform']))}",
                f"architecture = {toml_string(str(asset['architecture']))}",
                f"format = {toml_string(str(asset['format']))}",
                f"strategy = {toml_string(str(asset['strategy']))}",
                f"size = {asset['size']}",
                f"sha256 = {toml_string(str(asset['sha256']))}",
            ]
        )
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = generate_manifest(args.artifacts, args.version)
    args.output.write_text(serialize_manifest(manifest), encoding="utf-8")


if __name__ == "__main__":
    main()
