#!/usr/bin/env python3
"""Minimal standard-library TOML helpers for flat build metadata tables.

The application runtime uses a complete TOML implementation. Packaging tools
must continue to support Python 3.8 without adding a PyPI dependency, while the
portable marker contains only strings, integers, and booleans.
"""

from __future__ import annotations

import ast
import re
from pathlib import Path
from typing import Mapping


_KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
_INTEGER = re.compile(r"[+-]?[0-9](?:_?[0-9])*")


def encode_flat_toml(values: Mapping[str, object]) -> str:
    lines: list[str] = []
    for key, value in values.items():
        if _KEY.fullmatch(key) is None:
            raise ValueError(f"invalid TOML key: {key!r}")
        if isinstance(value, bool):
            encoded = "true" if value else "false"
        elif isinstance(value, int):
            encoded = str(value)
        elif isinstance(value, str):
            encoded = _encode_string(value)
        else:
            raise TypeError(f"unsupported flat TOML value for {key!r}")
        lines.append(f"{key} = {encoded}")
    return "\n".join(lines) + "\n"


def parse_flat_toml(source: str) -> dict[str, object]:
    values: dict[str, object] = {}
    for line_number, line in enumerate(source.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            raise ValueError(f"invalid TOML assignment on line {line_number}")
        key, raw = (part.strip() for part in stripped.split("=", 1))
        if _KEY.fullmatch(key) is None or key in values:
            raise ValueError(f"invalid or duplicate TOML key on line {line_number}")
        if raw in {"true", "false"}:
            value: object = raw == "true"
        elif _INTEGER.fullmatch(raw):
            value = int(raw.replace("_", ""))
        elif len(raw) >= 2 and raw.startswith('"') and raw.endswith('"'):
            value = ast.literal_eval(raw)
            if not isinstance(value, str):
                raise ValueError(f"invalid TOML string on line {line_number}")
        else:
            raise ValueError(f"unsupported TOML value on line {line_number}")
        values[key] = value
    return values


def read_flat_toml(path: Path) -> dict[str, object]:
    return parse_flat_toml(path.read_text(encoding="utf-8"))


def write_flat_toml(path: Path, values: Mapping[str, object]) -> None:
    path.write_text(encode_flat_toml(values), encoding="utf-8")


def _encode_string(value: str) -> str:
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
