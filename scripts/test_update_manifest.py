#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest import mock

from scripts import generate_update_manifest
from scripts import generate_latest_index


class UpdateManifestTests(unittest.TestCase):
    def test_manifest_classifies_installable_release_assets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = {
                "mdslens-windows-x64-setup.exe": b"windows",
                "mdslens-macos-universal-unsigned.zip": b"macos-zip",
                "mdslens-macos-universal-unsigned.dmg": b"macos",
                "mdslens-linux-arm64.AppImage": b"linux",
                "mdslens-linux-arm64.pkg.tar.zst": b"arch-linux",
                "mdslens-linux-arm64.tar.gz": b"portable-linux",
                "mdslens-android-universal.apk": b"android",
                "mdslens-ios-arm64-unsigned.ipa": b"ios",
                "mdslens-windows-x64.zip": b"portable-windows",
            }
            for name, contents in files.items():
                (root / name).write_bytes(contents)

            manifest = generate_update_manifest.generate_manifest(root, "v1.2.3")

        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["version"], "1.2.3")
        assets = {asset["name"]: asset for asset in manifest["assets"]}
        self.assertEqual(
            assets["mdslens-windows-x64.zip"]["strategy"],
            "self-replace",
        )
        self.assertEqual(
            assets["mdslens-windows-x64-setup.exe"]["strategy"],
            "launch-installer",
        )
        self.assertEqual(
            assets["mdslens-macos-universal-unsigned.dmg"]["architecture"],
            "universal",
        )
        self.assertEqual(
            assets["mdslens-macos-universal-unsigned.zip"]["strategy"],
            "self-replace",
        )
        self.assertEqual(
            assets["mdslens-linux-arm64.AppImage"]["format"],
            "AppImage",
        )
        self.assertEqual(
            assets["mdslens-linux-arm64.pkg.tar.zst"]["format"],
            "pkg.tar.zst",
        )
        self.assertEqual(
            assets["mdslens-linux-arm64.tar.gz"]["strategy"],
            "self-replace",
        )
        self.assertEqual(
            assets["mdslens-android-universal.apk"]["platform"],
            "android",
        )
        self.assertEqual(
            assets["mdslens-ios-arm64-unsigned.ipa"]["strategy"],
            "manual",
        )
        self.assertEqual(
            assets["mdslens-windows-x64-setup.exe"]["sha256"],
            hashlib.sha256(b"windows").hexdigest(),
        )

    def test_manifest_rejects_invalid_versions_and_empty_directories(self) -> None:
        with self.assertRaisesRegex(ValueError, "version"):
            generate_update_manifest.normalized_version("main")
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "no supported"):
                generate_update_manifest.generate_manifest(
                    Path(temporary),
                    "v1.0.0",
                )

    def test_serialized_manifest_is_valid_toml(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "mdslens-windows-x64.zip").write_bytes(b"portable")
            manifest = generate_update_manifest.generate_manifest(root, "v1.2.3")

        decoded = tomllib.loads(
            generate_update_manifest.serialize_manifest(manifest)
        )
        self.assertEqual(decoded, manifest)

    def test_cli_can_emit_a_legacy_client_compatibility_copy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            (artifacts / "mdslens-windows-x64.zip").write_bytes(b"portable")
            toml_output = root / "update-manifest.toml"
            legacy_output = root / "update-manifest.json"
            with mock.patch(
                "sys.argv",
                [
                    "generate_update_manifest.py",
                    "--artifacts",
                    str(artifacts),
                    "--version",
                    "v1.2.3",
                    "--output",
                    str(toml_output),
                    "--legacy-json-output",
                    str(legacy_output),
                ],
            ):
                generate_update_manifest.main()

            self.assertEqual(
                tomllib.loads(toml_output.read_text(encoding="utf-8")),
                json.loads(legacy_output.read_text(encoding="utf-8")),
            )

    def test_latest_index_selects_highest_stable_release_and_downloads(self) -> None:
        releases = [
            {
                "tag_name": "v1.2.0",
                "html_url": (
                    "https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v1.2.0"
                ),
                "draft": False,
                "prerelease": False,
                "assets": [
                    {
                        "name": "update-manifest.toml",
                        "browser_download_url": (
                            "https://github.com/Wu-Kuan-Yee/MDSLens/releases/"
                            "download/v1.2.0/update-manifest.toml"
                        ),
                        "size": 20,
                    },
                    {
                        "name": "mdslens-windows-x64.zip",
                        "browser_download_url": (
                            "https://github.com/Wu-Kuan-Yee/MDSLens/releases/"
                            "download/v1.2.0/mdslens-windows-x64.zip"
                        ),
                        "size": 123,
                        "digest": "sha256:" + "a" * 64,
                    },
                    {
                        "name": "notes.txt",
                        "browser_download_url": (
                            "https://github.com/Wu-Kuan-Yee/MDSLens/releases/"
                            "download/v1.2.0/notes.txt"
                        ),
                        "size": 2,
                    },
                ],
            },
            {
                "tag_name": "v9.0.0-beta",
                "html_url": "https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v9.0.0-beta",
                "draft": False,
                "prerelease": True,
                "assets": [],
            },
            {
                "tag_name": "v1.1.9",
                "html_url": "https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v1.1.9",
                "draft": False,
                "prerelease": False,
                "assets": [],
            },
        ]

        index = generate_latest_index.generate_index(releases)

        self.assertEqual(index["version"], "1.2.0")
        self.assertEqual(index["tag"], "v1.2.0")
        self.assertEqual(
            [asset["name"] for asset in index["assets"]],
            ["update-manifest.toml", "mdslens-windows-x64.zip"],
        )
        self.assertEqual(
            index["assets"][1]["sha256"],
            "a" * 64,
        )

    def test_latest_index_accepts_paginated_slurp_payload(self) -> None:
        release = {
            "tag_name": "v2.0.0",
            "html_url": "https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v2.0.0",
            "draft": False,
            "prerelease": False,
            "assets": [
                {
                    "name": "update-manifest.toml",
                    "browser_download_url": (
                        "https://github.com/Wu-Kuan-Yee/MDSLens/releases/"
                        "download/v2.0.0/update-manifest.toml"
                    ),
                    "size": 1,
                }
            ],
        }
        index = generate_latest_index.generate_index([[release], []])
        self.assertEqual(index["version"], "2.0.0")


if __name__ == "__main__":
    unittest.main()
