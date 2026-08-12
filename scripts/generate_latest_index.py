#!/usr/bin/env python3
"""Generate the small public update index used by MDSLens clients."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from urllib.parse import urlparse

from scripts.generate_update_manifest import (
    classify_asset,
    normalized_version,
    toml_string,
)


REPOSITORY = "Wu-Kuan-Yee/MDSLens"
DOWNLOAD_PATH_PREFIX = f"/Wu-Kuan-Yee/MDSLens/releases/download/"
RELEASE_PATH_PREFIX = f"/Wu-Kuan-Yee/MDSLens/releases/"


def _version_key(value: str) -> tuple[int, int, int]:
    normalized = normalized_version(value)
    parts = [int(part) for part in normalized.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))[:3]


def _is_trusted_download(value: str, tag: str) -> bool:
    parsed = urlparse(value)
    return (
        parsed.scheme == "https"
        and parsed.netloc.lower() == "github.com"
        and parsed.path.startswith(f"{DOWNLOAD_PATH_PREFIX}{tag}/")
        and parsed.query == ""
        and parsed.fragment == ""
    )


def _is_trusted_release(value: str) -> bool:
    parsed = urlparse(value)
    return (
        parsed.scheme == "https"
        and parsed.netloc.lower() == "github.com"
        and parsed.path.startswith(RELEASE_PATH_PREFIX)
        and parsed.query == ""
        and parsed.fragment == ""
    )


def _flatten_releases(value: object) -> list[dict[str, object]]:
    """Accept both a single API page and gh --paginate --slurp output."""
    if not isinstance(value, list):
        raise ValueError("GitHub release response must be a JSON array")
    if not value:
        return []
    if all(isinstance(item, dict) for item in value):
        return [item for item in value if isinstance(item, dict)]
    flattened: list[dict[str, object]] = []
    for page in value:
        if not isinstance(page, list):
            raise ValueError("GitHub release pages must be JSON arrays")
        flattened.extend(item for item in page if isinstance(item, dict))
    return flattened


def _candidate_releases(
    releases: list[dict[str, object]],
) -> list[tuple[tuple[int, int, int], dict[str, object], str, str]]:
    candidates: list[tuple[tuple[int, int, int], dict[str, object], str, str]] = []
    for release in releases:
        if release.get("draft") is True or release.get("prerelease") is True:
            continue
        tag = str(release.get("tag_name") or "").strip()
        try:
            version = normalized_version(tag)
            key = _version_key(tag)
        except ValueError:
            continue
        release_url = str(release.get("html_url") or "").strip()
        if not _is_trusted_release(release_url):
            release_url = f"https://github.com/{REPOSITORY}/releases/tag/v{version}"
        candidates.append((key, release, tag, release_url))
    candidates.sort(key=lambda item: item[0], reverse=True)
    return candidates


def _asset_entry(asset: dict[str, object], tag: str) -> dict[str, object] | None:
    name = str(asset.get("name") or "").strip()
    url = str(asset.get("browser_download_url") or "").strip()
    size = asset.get("size")
    if not name or not _is_trusted_download(url, tag):
        return None
    if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
        return None
    if name != "update-manifest.toml" and classify_asset(name) is None:
        return None
    entry: dict[str, object] = {
        "name": name,
        "url": url,
        "size": size,
    }
    classification = classify_asset(name)
    if classification is not None:
        entry.update(classification)
    digest = str(asset.get("digest") or "").strip().lower()
    if re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        entry["sha256"] = digest.removeprefix("sha256:")
    return entry


def generate_index(releases: object, repository: str = REPOSITORY) -> dict[str, object]:
    if repository != REPOSITORY:
        raise ValueError(f"unsupported repository: {repository}")
    candidates = _candidate_releases(_flatten_releases(releases))
    if not candidates:
        raise ValueError("no stable semantic release was found")
    _, release, tag, release_url = candidates[0]
    raw_assets = release.get("assets")
    if not isinstance(raw_assets, list):
        raise ValueError("latest release has no asset list")
    assets = [
        entry
        for raw_asset in raw_assets
        if isinstance(raw_asset, dict)
        for entry in [_asset_entry(raw_asset, tag)]
        if entry is not None
    ]
    if not any(asset["name"] == "update-manifest.toml" for asset in assets):
        raise ValueError("latest release has no update-manifest.toml")
    return {
        "schema_version": 1,
        "version": normalized_version(tag),
        "tag": tag,
        "release_url": release_url,
        "assets": assets,
    }


def serialize_index(index: dict[str, object]) -> str:
    """Serialize the public index as TOML, matching release manifests."""
    lines = [
        f"schema_version = {index['schema_version']}",
        f"version = {toml_string(str(index['version']))}",
        f"tag = {toml_string(str(index['tag']))}",
        f"release_url = {toml_string(str(index['release_url']))}",
    ]
    for asset in index["assets"]:
        if not isinstance(asset, dict):
            raise TypeError("latest index asset must be a table")
        lines.extend(
            [
                "",
                "[[assets]]",
                f"name = {toml_string(str(asset['name']))}",
                f"url = {toml_string(str(asset['url']))}",
                f"size = {asset['size']}",
            ]
        )
        for key in ("platform", "architecture", "format", "strategy", "sha256"):
            if key in asset:
                lines.append(f"{key} = {toml_string(str(asset[key]))}")
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--releases-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repository", default=REPOSITORY)
    args = parser.parse_args()
    releases = json.loads(args.releases_json.read_text(encoding="utf-8"))
    index = generate_index(releases, repository=args.repository)
    args.output.write_text(serialize_index(index), encoding="utf-8")


if __name__ == "__main__":
    main()
