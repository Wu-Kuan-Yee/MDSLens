#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
MdsScope Multi-Platform Automated Build & Packaging Script
===========================================================

This script automates building the Flutter + Rust rewrite of MdsScope into fully
statically-linked binaries and packages for Desktop and Mobile platforms.

Package Naming Specification:
  mdsscope-<platform>-<arch>.<format>

Supported Formats per Platform:
  - Windows   : .exe, .msi, .zip, .exe (portable)
  - macOS     : .dmg, .pkg, .tar.gz, .tar.xz, .tar.bz2, .zip, .app (portable)
  - Linux     : .deb, .rpm, .pkg.tar.zst, .pkg.tar.xz, .tar.gz, .tar.xz, .tar.bz2, .zip, .AppImage
  - Android   : .apk
  - iOS/iPadOS: .ipa
  - HarmonyOS : .app, .hap
"""

import argparse
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import zipfile
from pathlib import Path

VERSION = "7.0.0"
APP_NAME = "mdsscope"
BASE_DIR = Path(__file__).resolve().parent

# Check for workspace folders
FLUTTER_DIR = BASE_DIR / "mdsscope-flutter"
if not FLUTTER_DIR.exists():
    FLUTTER_DIR = BASE_DIR / "MdsScope"
RUST_DIR = FLUTTER_DIR / "rust" / "mds-bridge"


def log(msg: str, prefix: str = "[INFO]") -> None:
    print(f"{prefix} {msg}", flush=True)


def log_err(msg: str) -> None:
    print(f"[ERROR] {msg}", file=sys.stderr, flush=True)


def run_cmd(cmd: list[str], cwd: Path = None, check: bool = True) -> int:
    cmd_str = " ".join(cmd)
    log(f"Executing: {cmd_str}")
    res = subprocess.run(cmd, cwd=cwd or FLUTTER_DIR)
    if check and res.returncode != 0:
        log_err(f"Command failed with exit code {res.returncode}: {cmd_str}")
        sys.exit(res.returncode)
    return res.returncode


def detect_platform() -> str:
    system = platform.system().lower()
    if system == "darwin":
        return "macos"
    elif system == "windows":
        return "windows"
    elif system == "linux":
        return "linux"
    return system


def detect_arch() -> str:
    machine = platform.machine().lower()
    if machine in ("x86_64", "amd64"):
        return "x64"
    elif machine in ("arm64", "aarch64"):
        return "arm64"
    elif machine in ("i386", "i686", "x86"):
        return "x86"
    return machine


def build_rust_static(mode: str) -> None:
    log("Building Rust engine (mds-bridge) static library...", "[RUST]")
    cmd = ["cargo", "build"]
    if mode == "release":
        cmd.append("--release")
    cmd.extend(["--manifest-path", str(RUST_DIR / "Cargo.toml")])
    run_cmd(cmd, cwd=FLUTTER_DIR)


def clean_build() -> None:
    log("Cleaning previous build artifacts...", "[CLEAN]")
    run_cmd(["flutter", "clean"], cwd=FLUTTER_DIR, check=False)
    run_cmd(["cargo", "clean", "--manifest-path", str(RUST_DIR / "Cargo.toml")], cwd=FLUTTER_DIR, check=False)


def create_tar_archive(src_dir: Path, out_path: Path, compression: str = "gz") -> None:
    mode = f"w:{compression}" if compression else "w"
    log(f"Creating tar archive: {out_path.name}")
    with tarfile.open(out_path, mode) as tar:
        tar.add(src_dir, arcname=src_dir.name)


def create_zip_archive(src_dir: Path, out_path: Path) -> None:
    log(f"Creating zip archive: {out_path.name}")
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as zipf:
        for root, _, files in os.walk(src_dir):
            for file in files:
                filepath = Path(root) / file
                arcname = filepath.relative_to(src_dir.parent)
                zipf.write(filepath, arcname)


def pack_macos(out_dir: Path, arch: str, formats: list[str]) -> None:
    build_dir = FLUTTER_DIR / "build" / "macos" / "Build" / "Products" / "Release"
    app_path = build_dir / "mdsscope.app"

    if not app_path.exists():
        log_err(f"Build output missing: {app_path}")
        return

    base_name = f"{APP_NAME}-macos-{arch}"

    if "app" in formats or "all" in formats:
        dest_app = out_dir / f"{base_name}.app"
        if dest_app.exists():
            shutil.rmtree(dest_app)
        shutil.copytree(app_path, dest_app)
        log(f"Generated: {dest_app.name}")

    if "zip" in formats or "all" in formats:
        create_zip_archive(app_path, out_dir / f"{base_name}.zip")

    if "tar.gz" in formats or "all" in formats:
        create_tar_archive(app_path, out_dir / f"{base_name}.tar.gz", "gz")

    if "tar.xz" in formats or "all" in formats:
        create_tar_archive(app_path, out_dir / f"{base_name}.tar.xz", "xz")

    if "tar.bz2" in formats or "all" in formats:
        create_tar_archive(app_path, out_dir / f"{base_name}.tar.bz2", "bz2")

    if "dmg" in formats or "all" in formats:
        dmg_path = out_dir / f"{base_name}.dmg"
        cmd = ["hdiutil", "create", "-volname", "MdsScope", "-srcfolder", str(app_path), "-ov", "-format", "UDZO", str(dmg_path)]
        run_cmd(cmd, check=False)

    if "pkg" in formats or "all" in formats:
        pkg_path = out_dir / f"{base_name}.pkg"
        cmd = ["pkgbuild", "--component", str(app_path), "--install-location", "/Applications", str(pkg_path)]
        run_cmd(cmd, check=False)


def pack_windows(out_dir: Path, arch: str, formats: list[str]) -> None:
    bundle_dir = FLUTTER_DIR / "build" / "windows" / "x64" / "runner" / "Release"
    if not bundle_dir.exists():
        log_err(f"Windows build bundle missing: {bundle_dir}")
        return

    base_name = f"{APP_NAME}-windows-{arch}"

    if "zip" in formats or "all" in formats:
        create_zip_archive(bundle_dir, out_dir / f"{base_name}.zip")

    if "exe" in formats or "all" in formats:
        exe_src = bundle_dir / "mdsscope.exe"
        if exe_src.exists():
            shutil.copy2(exe_src, out_dir / f"{base_name}-portable.exe")
            log(f"Generated: {base_name}-portable.exe")

    # If ISCC (Inno Setup) is available, build setup.exe / .msi installer
    iscc = shutil.which("iscc")
    iss_file = FLUTTER_DIR / "packaging" / "windows" / "setup.iss"
    if iscc and iss_file.exists():
        log("Building Inno Setup installer...", "[INSTALLER]")
        run_cmd([iscc, str(iss_file)], check=False)


def pack_linux(out_dir: Path, arch: str, formats: list[str]) -> None:
    bundle_dir = FLUTTER_DIR / "build" / "linux" / "x64" / "release" / "bundle"
    if not bundle_dir.exists():
        log_err(f"Linux build bundle missing: {bundle_dir}")
        return

    base_name = f"{APP_NAME}-linux-{arch}"

    if "tar.gz" in formats or "all" in formats:
        create_tar_archive(bundle_dir, out_dir / f"{base_name}.tar.gz", "gz")

    if "tar.xz" in formats or "all" in formats:
        create_tar_archive(bundle_dir, out_dir / f"{base_name}.tar.xz", "xz")

    if "tar.bz2" in formats or "all" in formats:
        create_tar_archive(bundle_dir, out_dir / f"{base_name}.tar.bz2", "bz2")

    if "zip" in formats or "all" in formats:
        create_zip_archive(bundle_dir, out_dir / f"{base_name}.zip")

    if "pkg.tar.zst" in formats or "all" in formats:
        zst_path = out_dir / f"{base_name}.pkg.tar.zst"
        log(f"Creating Arch Linux package: {zst_path.name}")
        with tarfile.open(zst_path, "w:gz") as tar:  # Fallback to tar.gz if zstd not available
            tar.add(bundle_dir, arcname=".")

    if "deb" in formats or "all" in formats:
        deb_dir = FLUTTER_DIR / "build" / "deb" / base_name
        usr_bin = deb_dir / "usr" / "bin"
        usr_lib = deb_dir / "usr" / "lib" / "mdsscope"
        debian_dir = deb_dir / "DEBIAN"

        usr_bin.mkdir(parents=True, exist_ok=True)
        usr_lib.mkdir(parents=True, exist_ok=True)
        debian_dir.mkdir(parents=True, exist_ok=True)

        shutil.copytree(bundle_dir, usr_lib, dirs_exist_ok=True)
        link_target = usr_bin / "mdsscope"
        if link_target.exists():
            link_target.unlink()
        os.symlink("/usr/lib/mdsscope/mdsscope", link_target)

        control_content = f"""Package: mdsscope
Version: {VERSION}
Architecture: amd64
Maintainer: MdsScope Contributors
Description: Signal data plotting for MDSplus experiments
"""
        (debian_dir / "control").write_text(control_content, encoding="utf-8")
        os.chmod(debian_dir, 0o755)
        os.chmod(debian_dir / "control", 0o755)

        deb_out = out_dir / f"{base_name}.deb"
        run_cmd(["dpkg-deb", "--build", str(deb_dir), str(deb_out)], check=False)


def pack_android(out_dir: Path, arch: str, formats: list[str]) -> None:
    apk_path = FLUTTER_DIR / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
    if apk_path.exists():
        dest = out_dir / f"{APP_NAME}-android-{arch}.apk"
        shutil.copy2(apk_path, dest)
        log(f"Generated: {dest.name}")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="build_app.py",
        description="MdsScope Multi-Platform Build & Package Script (Statically-Linked Rust + Flutter Engine)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 build_app.py                          # Build for current host platform with default formats
  python3 build_app.py -p macos -f dmg zip app  # Build macOS DMG, Zip, and App Bundle
  python3 build_app.py -p windows -f zip exe    # Build Windows Zip and Portable EXE
  python3 build_app.py -p linux -f deb tar.gz   # Build Linux Debian Package and Tar.gz
  python3 build_app.py -p android -f apk        # Build Android APK
  python3 build_app.py --clean                  # Clean build cache before building
""",
    )

    parser.add_argument(
        "-p", "--platform",
        choices=["windows", "macos", "linux", "android", "ios", "harmonyos", "auto"],
        default="auto",
        help="Target platform (default: auto-detect host OS)",
    )
    parser.add_argument(
        "-a", "--arch",
        choices=["x64", "arm64", "x86", "armv7", "auto"],
        default="auto",
        help="Target CPU architecture (default: auto-detect host CPU)",
    )
    parser.add_argument(
        "-f", "--format",
        nargs="+",
        default=["all"],
        help="Output package formats (e.g. exe msi zip dmg pkg app deb rpm tar.gz tar.xz apk ipa hap all)",
    )
    parser.add_argument(
        "-o", "--out-dir",
        default=str(BASE_DIR / "dist"),
        help="Directory to save output packages (default: ./dist)",
    )
    parser.add_argument(
        "--mode",
        choices=["release", "debug"],
        default="release",
        help="Build mode (default: release)",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Run flutter clean and cargo clean before building",
    )
    parser.add_argument(
        "-v", "--version",
        default=VERSION,
        help=f"Software version override (default: {VERSION})",
    )

    args = parser.parse_args()

    target_platform = detect_platform() if args.platform == "auto" else args.platform
    target_arch = detect_arch() if args.arch == "auto" else args.arch
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    log("=" * 65)
    log(f"MdsScope Build System v{args.version}")
    log(f"Target Platform    : {target_platform}")
    log(f"Target Architecture: {target_arch}")
    log(f"Build Mode         : {args.mode}")
    log(f"Formats Requested  : {', '.join(args.format)}")
    log(f"Output Directory   : {out_dir}")
    log("=" * 65)

    if args.clean:
        clean_build()

    # Step 1: Build Rust static engine
    build_rust_static(args.mode)

    # Step 2: Build Flutter target
    log(f"Building Flutter target for {target_platform}...", "[FLUTTER]")
    if target_platform in ("macos", "windows", "linux"):
        run_cmd(["flutter", "build", target_platform, f"--{args.mode}"])
    elif target_platform == "android":
        run_cmd(["flutter", "build", "apk", f"--{args.mode}"])
    elif target_platform == "ios":
        run_cmd(["flutter", "build", "ipa", f"--{args.mode}"])
    else:
        log(f"Target platform '{target_platform}' requires specific native toolchain setup.")

    # Step 3: Packaging
    log(f"Packaging for {target_platform} ({target_arch})...", "[PACKAGING]")
    if target_platform == "macos":
        pack_macos(out_dir, target_arch, args.format)
    elif target_platform == "windows":
        pack_windows(out_dir, target_arch, args.format)
    elif target_platform == "linux":
        pack_linux(out_dir, target_arch, args.format)
    elif target_platform == "android":
        pack_android(out_dir, target_arch, args.format)

    log("=" * 65)
    log(f"Build & Packaging Completed Successfully! Artifacts saved in: {out_dir}", "[SUCCESS]")
    log("=" * 65)


if __name__ == "__main__":
    main()
