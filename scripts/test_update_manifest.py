#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import tempfile
import unittest
from pathlib import Path

from scripts import generate_update_manifest


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
                "mdslens-windows-x64.zip": b"ignored",
            }
            for name, contents in files.items():
                (root / name).write_bytes(contents)

            manifest = generate_update_manifest.generate_manifest(root, "v1.2.3")

        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["version"], "1.2.3")
        assets = {asset["name"]: asset for asset in manifest["assets"]}
        self.assertNotIn("mdslens-windows-x64.zip", assets)
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


if __name__ == "__main__":
    unittest.main()
