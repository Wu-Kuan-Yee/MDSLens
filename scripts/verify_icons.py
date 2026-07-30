#!/usr/bin/env python3
"""Validate every native application icon without third-party packages."""

from __future__ import annotations

import argparse
import ctypes
import json
import plistlib
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


def verify_web_and_product_site() -> int:
    count = 0
    for relative, size in (
        ("web/favicon.png", 32),
        ("web/icons/Icon-192.png", 192),
        ("web/icons/Icon-512.png", 512),
        ("web/icons/Icon-maskable-192.png", 192),
        ("web/icons/Icon-maskable-512.png", 512),
        ("product-site/mdslens-icon.png", 256),
    ):
        path = ROOT / relative
        check(path.is_file(), f"missing Web/product-site icon: {path}")
        check(png_info(path)[:2] == (size, size), f"wrong icon size: {path}")
        count += 1
    return count


def verify_windows_executable(path: Path) -> None:
    check(path.is_file(), f"missing Windows executable: {path}")
    check(path.read_bytes()[:2] == b"MZ", f"not a Windows executable: {path}")
    if sys.platform != "win32":
        return
    count = ctypes.windll.shell32.ExtractIconExW(str(path), -1, None, None, 0)
    check(count > 0, f"Windows executable has no embedded icon: {path}")


def verify_macos_application(path: Path) -> None:
    contents = path / "Contents"
    info_path = contents / "Info.plist"
    check(info_path.is_file(), f"missing macOS application Info.plist: {path}")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    executable = contents / "MacOS" / str(info.get("CFBundleExecutable", ""))
    check(executable.is_file() and executable.stat().st_size > 0,
          f"missing macOS application executable: {executable}")
    icon_name = str(
        info.get("CFBundleIconName") or info.get("CFBundleIconFile") or ""
    ).removesuffix(".icns")
    check(bool(icon_name), f"macOS application has no configured icon: {path}")
    icon = contents / "Resources" / f"{icon_name}.icns"
    check(icon.is_file() and icon.stat().st_size > 0,
          f"missing compiled macOS application icon: {icon}")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description="Validate MDSLens source icons and packaged applications."
    )
    parser.add_argument("--windows-executable", type=Path)
    parser.add_argument("--macos-app", action="append", default=[], type=Path)
    args = parser.parse_args(argv)

    source = ROOT / "assets/app_icon_master.svg"
    check(source.is_file(), "missing source SVG")
    source_svg = ElementTree.parse(source).getroot()
    source_view_box = [
        float(value) for value in source_svg.attrib.get("viewBox", "").split()
    ]
    check(
        source_view_box == [0, 0, 1024, 1024],
        "source SVG must have a 1024x1024 viewBox",
    )
    svg_namespace = "{http://www.w3.org/2000/svg}"
    check(
        not list(source_svg.iter(f"{svg_namespace}image")),
        "source SVG must not embed raster images",
    )
    preview = ROOT / "assets/app_icon_master.png"
    check(preview.is_file(), "missing generated source preview")
    width, height, color_type = png_info(preview)
    check((width, height) == (1024, 1024), "source preview must be 1024x1024")
    check(
        color_type in {4, 6},
        "source preview must preserve transparent corners",
    )
    for relative in (
        "assets/app_icon_foreground.svg",
        "assets/app_icon_monochrome.svg",
    ):
        svg = ElementTree.parse(ROOT / relative).getroot()
        view_box = [
            float(value) for value in svg.attrib.get("viewBox", "").split()
        ]
        check(
            len(view_box) == 4
            and view_box[2] > 0
            and view_box[2] == view_box[3],
            f"{relative} must have a square viewBox",
        )
    ios = verify_asset_catalog("ios/Runner/Assets.xcassets/AppIcon.appiconset", allow_alpha=False)
    macos = verify_asset_catalog("macos/Runner/Assets.xcassets/AppIcon.appiconset", allow_alpha=True)
    android = verify_android()
    windows = verify_windows()
    web = verify_web_and_product_site()
    linux = ROOT / "linux/runner/app_icon.png"
    check(png_info(linux)[:2] == (512, 512), "Linux icon must be 512x512")
    desktop = (ROOT / "packaging/linux/com.mdslens.app.desktop").read_text(encoding="utf-8")
    rpm_spec = (ROOT / "packaging/linux/mdslens.spec").read_text(
        encoding="utf-8"
    )
    check(
        "Icon=com.mdslens.app" in desktop
        and "StartupWMClass=com.mdslens.app" in desktop
        and "Exec=mdslens %U" in desktop
        and "x-scheme-handler/mdslens" in desktop,
        "invalid Linux desktop integration metadata",
    )
    check(
        "/usr/share/icons/hicolor/512x512/apps/com.mdslens.app.png"
        in rpm_spec,
        "RPM package does not include the generated PNG icon",
    )
    if args.windows_executable is not None:
        verify_windows_executable(args.windows_executable)
    for app in args.macos_app:
        verify_macos_application(app)
    print(
        "Verified icons: "
        f"iOS {ios}, macOS {macos}, Android {android}, "
        f"Windows {windows}, Linux 1, Web/product site {web}"
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"Icon verification failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
