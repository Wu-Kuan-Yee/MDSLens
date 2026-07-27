#!/usr/bin/env python3
"""Validate every native application icon without third-party packages."""

from __future__ import annotations

import json
import struct
import sys
import xml.etree.ElementTree as ElementTree
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def check(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def png_info(path: Path) -> tuple[int, int, int]:
    data = path.read_bytes()
    check(data.startswith(b"\x89PNG\r\n\x1a\n"), f"not a PNG: {path}")
    width, height, _bit_depth, color_type = struct.unpack(">IIBB", data[16:26])
    return width, height, color_type


def verify_asset_catalog(relative: str, allow_alpha: bool) -> int:
    directory = ROOT / relative
    catalog = json.loads((directory / "Contents.json").read_text(encoding="utf-8"))
    checked: set[str] = set()
    for image in catalog["images"]:
        filename = image.get("filename")
        check(bool(filename), f"unassigned icon slot in {relative}: {image}")
        path = directory / filename
        check(path.is_file(), f"missing catalog icon: {path}")
        points = float(image["size"].split("x", 1)[0])
        scale_text = image["scale"]
        check(scale_text.endswith("x"), f"invalid icon scale: {scale_text}")
        scale = float(scale_text[:-1])
        expected = round(points * scale)
        width, height, color_type = png_info(path)
        check((width, height) == (expected, expected), f"wrong icon size: {path} is {width}x{height}, expected {expected}")
        if not allow_alpha:
            data = path.read_bytes()
            check(color_type not in {4, 6} and b"tRNS" not in data, f"iOS icon has an alpha channel: {path}")
        checked.add(filename)
    return len(checked)


def verify_android() -> int:
    resources = ROOT / "android/app/src/main/res"
    densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    count = 0
    for density, scale in densities.items():
        for relative, base_size in (
            (f"mipmap-{density}/ic_launcher.png", 48),
            (f"drawable-{density}/ic_launcher_foreground.png", 108),
            (f"drawable-{density}/ic_launcher_monochrome.png", 108),
        ):
            path = resources / relative
            check(path.is_file(), f"missing Android icon: {path}")
            expected = round(base_size * scale)
            width, height, _ = png_info(path)
            check((width, height) == (expected, expected), f"wrong Android icon size: {path}")
            count += 1
    for api in (26, 33):
        for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
            path = resources / f"mipmap-anydpi-v{api}/{name}"
            text = path.read_text(encoding="utf-8")
            check("ic_launcher_foreground" in text and "ic_launcher_background" in text, f"invalid adaptive icon: {path}")
            if api >= 33:
                check("ic_launcher_monochrome" in text, f"missing themed Android icon: {path}")
            count += 1
    return count


def verify_windows() -> int:
    path = ROOT / "windows/runner/resources/app_icon.ico"
    data = path.read_bytes()
    reserved, image_type, count = struct.unpack_from("<HHH", data)
    check((reserved, image_type) == (0, 1), f"invalid Windows ICO header: {path}")
    sizes = {
        (data[6 + index * 16] or 256, data[7 + index * 16] or 256)
        for index in range(count)
    }
    required = {(size, size) for size in (16, 24, 32, 48, 64, 128, 256)}
    check(required <= sizes, f"Windows ICO is missing layers: {sorted(required - sizes)}")
    for name, size in (
        ("Square44x44Logo.png", 44),
        ("Square150x150Logo.png", 150),
        ("StoreLogo.png", 50),
    ):
        logo = ROOT / "windows/runner/resources/msix" / name
        check(png_info(logo)[:2] == (size, size), f"invalid MSIX logo: {logo}")
    return count + 3


def main() -> None:
    source = ROOT / "assets/app_icon.svg"
    check(source.is_file(), "missing source SVG")
    svg = ElementTree.parse(source).getroot()
    view_box = [float(value) for value in svg.attrib.get("viewBox", "").split()]
    check(len(view_box) == 4 and view_box[2] > 0 and view_box[2] == view_box[3], "source SVG must have a square viewBox")
    ios = verify_asset_catalog("ios/Runner/Assets.xcassets/AppIcon.appiconset", allow_alpha=False)
    macos = verify_asset_catalog("macos/Runner/Assets.xcassets/AppIcon.appiconset", allow_alpha=True)
    android = verify_android()
    windows = verify_windows()
    linux = ROOT / "linux/runner/app_icon.png"
    check(png_info(linux)[:2] == (512, 512), "Linux icon must be 512x512")
    desktop = (ROOT / "packaging/linux/com.mdslens.app.desktop").read_text(encoding="utf-8")
    check(
        "Icon=com.mdslens.app" in desktop
        and "StartupWMClass=com.mdslens.app" in desktop
        and "Exec=mdslens %U" in desktop
        and "x-scheme-handler/mdslens" in desktop,
        "invalid Linux desktop integration metadata",
    )
    print(f"Verified native icons: iOS {ios}, macOS {macos}, Android {android}, Windows {windows}, Linux 1")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"Icon verification failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
