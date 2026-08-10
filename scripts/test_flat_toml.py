#!/usr/bin/env python3

from __future__ import annotations

import unittest

from scripts.flat_toml import encode_flat_toml, parse_flat_toml


class FlatTomlTests(unittest.TestCase):
    def test_portable_metadata_round_trips(self) -> None:
        metadata = {
            "schema_version": 1,
            "product": "com.mdslens.app",
            "platform": "windows",
            "version": "0.3.43",
            "architecture": "x64",
            "executable": "mdslens.exe",
        }
        self.assertEqual(parse_flat_toml(encode_flat_toml(metadata)), metadata)

    def test_parser_rejects_non_flat_or_duplicate_metadata(self) -> None:
        with self.assertRaisesRegex(ValueError, "invalid"):
            parse_flat_toml("[nested]\nvalue = 1\n")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            parse_flat_toml("value = 1\nvalue = 2\n")


if __name__ == "__main__":
    unittest.main()
