#!/usr/bin/env python3
"""Build and package MdsScope on the current native build host.

Flutter desktop targets must be built on their native operating system. Android
can be built on every Flutter host; Apple targets require macOS and Xcode. The
GitHub release workflow runs this entry point on each required host.
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
DIST = ROOT / "build" / "dist"
APP = "mdsscope"


def log(message: str) -> None:
    print(f"[MdsScope] {message}", flush=True)


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"[MdsScope] ERROR: {message}")


def run(*command: str, cwd: Path = ROOT, check: bool = True) -> subprocess.CompletedProcess[str]:
    log("Running: " + " ".join(command))
    return subprocess.run(command, cwd=cwd, check=check, text=True)


def tool(name: str) -> str | None:
    return shutil.which(name)


def format_tool(name: str, formats: set[str], package_format: str) -> str | None:
    found = tool(name)
    if found is not None:
        return found
    if "all" in formats:
        log(f"Skipping {package_format}: optional tool '{name}' is not installed")
        return None
    fail(f"'{name}' is required for {package_format}")


def host_platform() -> str:
    return {"Darwin": "macos", "Windows": "windows", "Linux": "linux"}.get(
        platform.system(), platform.system().lower()
    )


def host_arch() -> str:
    machine = platform.machine().lower()
    if machine in {"x86_64", "amd64"}:
        return "x64"
    if machine in {"arm64", "aarch64"}:
        return "arm64"
    return machine


def project_version() -> str:
    match = re.search(
        r"^version:\s*([^+\s]+)",
        (ROOT / "pubspec.yaml").read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if match is None:
        fail("pubspec.yaml has no version")
    return match.group(1)


def replace_tree(source: Path, destination: Path) -> None:
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True)


def make_tar(source: Path, output: Path, arcname: str, mode: str) -> None:
    with tarfile.open(output, mode, dereference=False) as archive:
        archive.add(source, arcname=arcname, recursive=True)
    log(f"Created {output.name}")


def make_zip(source: Path, output: Path, arcname: str) -> None:
    if host_platform() == "macos" and source.suffix == ".app":
        # ditto preserves macOS resource forks, permissions and framework links.
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(source), str(output))
    else:
        with tempfile.TemporaryDirectory(prefix="mdsscope-zip-") as temporary:
            staged = Path(temporary) / arcname
            replace_tree(source, staged)
            archive_base = output.with_suffix("")
            made = Path(shutil.make_archive(str(archive_base), "zip", temporary))
            if made != output:
                made.replace(output)
    log(f"Created {output.name}")


def selected(formats: set[str], name: str) -> bool:
    return "all" in formats or name in formats


def flutter_build(target: str, *arguments: str) -> None:
    run("flutter", "pub", "get")
    run("flutter", "build", target, "--release", *arguments)


def package_macos(formats: set[str], no_build: bool) -> None:
    if host_platform() != "macos":
        fail("macOS packages can only be built on macOS")
    if not no_build:
        flutter_build("macos")

    app = ROOT / "build/macos/Build/Products/Release/MdsScope.app"
    if not app.is_dir():
        fail(f"macOS application bundle not found: {app}")
    base = "mdsscope-macos-universal"

    if selected(formats, "app"):
        replace_tree(app, DIST / f"{base}.app")
        log(f"Created {base}.app")
    if selected(formats, "zip"):
        make_zip(app, DIST / f"{base}.zip", app.name)
    if selected(formats, "tar.gz"):
        make_tar(app, DIST / f"{base}.tar.gz", app.name, "w:gz")
    if selected(formats, "tar.xz"):
        make_tar(app, DIST / f"{base}.tar.xz", app.name, "w:xz")
    if selected(formats, "tar.bz2"):
        make_tar(app, DIST / f"{base}.tar.bz2", app.name, "w:bz2")
    if selected(formats, "dmg"):
        run(
            "hdiutil", "create", "-quiet", "-volname", "MdsScope",
            "-srcfolder", str(app), "-ov", "-format", "UDZO", str(DIST / f"{base}.dmg"),
        )
    if selected(formats, "pkg"):
        run(
            "pkgbuild", "--component", str(app), "--install-location", "/Applications",
            str(DIST / f"{base}.pkg"),
        )


def windows_bundle(arch: str) -> Path:
    return ROOT / f"build/windows/{arch}/runner/Release"


def package_windows(formats: set[str], no_build: bool, arch: str) -> None:
    if host_platform() != "windows":
        fail("Windows packages can only be built on Windows")
    if arch not in {"x64", "arm64"}:
        fail("Flutter supports Windows x64 and arm64, not " + arch)
    if not no_build:
        flutter_build("windows", "--target-platform", f"windows-{arch}")

    bundle = windows_bundle(arch)
    if not (bundle / "mdsscope.exe").is_file():
        fail(f"Windows application bundle not found: {bundle}")
    base = f"mdsscope-windows-{arch}"

    if selected(formats, "zip"):
        make_zip(bundle, DIST / f"{base}.zip", base)
    if selected(formats, "tar.gz"):
        make_tar(bundle, DIST / f"{base}.tar.gz", base, "w:gz")
    if selected(formats, "tar.xz"):
        make_tar(bundle, DIST / f"{base}.tar.xz", base, "w:xz")
    if selected(formats, "tar.bz2"):
        make_tar(bundle, DIST / f"{base}.tar.bz2", base, "w:bz2")
    if selected(formats, "exe"):
        iscc = format_tool("ISCC", formats, "exe")
        if iscc is not None:
            run(
                iscc,
                f"/DBundleDir={bundle}",
                f"/DOutputDir={DIST}",
                f"/DOutputBase={base}",
                f"/DAppVersion={project_version()}",
                str(ROOT / "packaging/windows/mdsscope.iss"),
            )
    if "msi" in formats:
        fail("MSI generation needs a separately maintained WiX installer definition; use the signed EXE installer")


def linux_bundle(arch: str) -> Path:
    return ROOT / f"build/linux/{arch}/release/bundle"


def stage_linux_root(bundle: Path, root: Path) -> None:
    app_dir = root / "usr/lib/mdsscope"
    replace_tree(bundle, app_dir)
    bin_dir = root / "usr/bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    os.symlink("../lib/mdsscope/mdsscope", bin_dir / "mdsscope")
    applications = root / "usr/share/applications"
    applications.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "packaging/linux/com.mdsscope.app.desktop", applications)
    icons = root / "usr/share/icons/hicolor/scalable/apps"
    icons.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "assets/app_icon.svg", icons / "com.mdsscope.app.svg")


def package_linux(formats: set[str], no_build: bool, arch: str, version: str) -> None:
    if host_platform() != "linux":
        fail("Linux packages can only be built on Linux")
    if arch not in {"x64", "arm64"}:
        fail("Flutter supports Linux x64 and arm64, not " + arch)
    if arch != host_arch():
        fail("Linux packages must be built on a matching native host architecture")
    if not no_build:
        flutter_build("linux")

    bundle = linux_bundle(arch)
    if not (bundle / "mdsscope").is_file():
        fail(f"Linux application bundle not found: {bundle}")
    base = f"mdsscope-linux-{arch}"
    if selected(formats, "zip"):
        make_zip(bundle, DIST / f"{base}.zip", base)
    if selected(formats, "tar.gz"):
        make_tar(bundle, DIST / f"{base}.tar.gz", base, "w:gz")
    if selected(formats, "tar.xz"):
        make_tar(bundle, DIST / f"{base}.tar.xz", base, "w:xz")
    if selected(formats, "tar.bz2"):
        make_tar(bundle, DIST / f"{base}.tar.bz2", base, "w:bz2")

    with tempfile.TemporaryDirectory(prefix="mdsscope-linux-") as temporary:
        staging = Path(temporary) / "root"
        stage_linux_root(bundle, staging)
        deb_arch = {"x64": "amd64", "arm64": "arm64"}[arch]
        rpm_arch = {"x64": "x86_64", "arm64": "aarch64"}[arch]

        if selected(formats, "deb"):
            dpkg_deb = format_tool("dpkg-deb", formats, "deb")
            if dpkg_deb is not None:
                control = staging / "DEBIAN"
                control.mkdir()
                (control / "control").write_text(
                    "\n".join([
                        "Package: mdsscope", f"Version: {version}", f"Architecture: {deb_arch}",
                        "Maintainer: MdsScope Contributors",
                        "Depends: libc6, libgtk-3-0, libstdc++6",
                        "Section: science", "Priority: optional",
                        "Description: MDSplus signal waveform viewer", "",
                    ]),
                    encoding="utf-8",
                )
                run(dpkg_deb, "--root-owner-group", "--build", str(staging), str(DIST / f"{base}.deb"))
                shutil.rmtree(control)

        for package_format, compression in (("pkg.tar.zst", "--zstd"), ("pkg.tar.xz", "-J")):
            if selected(formats, package_format):
                package_info = staging / ".PKGINFO"
                installed_size = sum(path.stat().st_size for path in staging.rglob("*") if path.is_file())
                package_info.write_text(
                    f"pkgname = mdsscope\npkgver = {version}-1\npkgdesc = MDSplus signal waveform viewer\n"
                    f"arch = {rpm_arch}\nsize = {installed_size}\ndepend = gtk3\n",
                    encoding="utf-8",
                )
                run("tar", "-C", str(staging), compression, "-cf", str(DIST / f"{base}.{package_format}"), ".")
                package_info.unlink()

        if selected(formats, "rpm"):
            rpmbuild = format_tool("rpmbuild", formats, "rpm")
            if rpmbuild is not None:
                top = Path(temporary) / "rpmbuild"
                for directory in ("BUILD", "BUILDROOT", "RPMS", "SOURCES", "SPECS", "SRPMS"):
                    (top / directory).mkdir(parents=True)
                source_root = top / "SOURCES/root"
                replace_tree(staging, source_root)
                run(
                    rpmbuild, "-bb", "--define", f"_topdir {top}", "--define", f"mdsscope_version {version}",
                    "--define", f"mdsscope_arch {rpm_arch}", str(ROOT / "packaging/linux/mdsscope.spec"),
                )
                rpms = list((top / "RPMS").rglob("*.rpm"))
                if len(rpms) != 1:
                    fail("rpmbuild did not produce exactly one RPM")
                shutil.copy2(rpms[0], DIST / f"{base}.rpm")

        if selected(formats, "AppImage"):
            appimagetool = format_tool("appimagetool", formats, "AppImage")
            if appimagetool is not None:
                app_dir = Path(temporary) / "MdsScope.AppDir"
                stage_linux_root(bundle, app_dir)
                os.symlink("usr/lib/mdsscope/mdsscope", app_dir / "AppRun")
                shutil.copy2(ROOT / "packaging/linux/com.mdsscope.app.desktop", app_dir)
                shutil.copy2(ROOT / "assets/app_icon.svg", app_dir / "com.mdsscope.app.svg")
                environment = dict(os.environ)
                environment["ARCH"] = rpm_arch
                log(f"Running: {appimagetool} {app_dir} {DIST / (base + '.AppImage')}")
                subprocess.run([appimagetool, str(app_dir), str(DIST / f"{base}.AppImage")], check=True, env=environment)


def package_android(formats: set[str], no_build: bool) -> None:
    apk_dir = ROOT / "build/app/outputs/flutter-apk"
    bundle_dir = ROOT / "build/app/outputs/bundle/release"
    if not no_build:
        run("flutter", "pub", "get")
        if selected(formats, "apk"):
            run(
                "flutter", "build", "apk", "--release", "--split-per-abi",
                "--target-platform", "android-arm,android-arm64,android-x64",
            )
            run(
                "flutter", "build", "apk", "--release",
                "--target-platform", "android-arm,android-arm64,android-x64",
            )
        if selected(formats, "aab"):
            run(
                "flutter", "build", "appbundle", "--release",
                "--target-platform", "android-arm,android-arm64,android-x64",
            )

    if selected(formats, "apk"):
        outputs = {
            "app-armeabi-v7a-release.apk": "mdsscope-android-armv7.apk",
            "app-arm64-v8a-release.apk": "mdsscope-android-arm64.apk",
            "app-x86_64-release.apk": "mdsscope-android-x64.apk",
            "app-release.apk": "mdsscope-android-universal.apk",
        }
        for source, destination in outputs.items():
            path = apk_dir / source
            if not path.is_file():
                fail(f"Android APK not found: {path}")
            shutil.copy2(path, DIST / destination)
    if selected(formats, "aab"):
        source = bundle_dir / "app-release.aab"
        if not source.is_file():
            fail(f"Android App Bundle not found: {source}")
        shutil.copy2(source, DIST / "mdsscope-android-universal.aab")


def package_ios(formats: set[str], no_build: bool) -> None:
    if host_platform() != "macos":
        fail("iOS/iPadOS packages can only be built on macOS")
    if not selected(formats, "ipa"):
        return
    if not no_build:
        flutter_build("ipa")
    ipas = sorted((ROOT / "build/ios/ipa").glob("*.ipa"))
    if len(ipas) != 1:
        fail("A signed IPA was not produced. Configure Apple signing in Xcode first.")
    # One universal Apple mobile binary supports both iPhone and iPad. Both
    # names are published as aliases so platform-filtered release clients find it.
    shutil.copy2(ipas[0], DIST / "mdsscope-ios-arm64.ipa")
    shutil.copy2(ipas[0], DIST / "mdsscope-ipados-arm64.ipa")


def main() -> None:
    global DIST

    parser = argparse.ArgumentParser(description="Build real, installable MdsScope release packages")
    parser.add_argument(
        "-p", "--platform", action="append",
        choices=["auto", "windows", "macos", "linux", "android", "ios", "ipados", "harmonyos"],
        help="target platform; repeat to build several (default: native desktop)",
    )
    parser.add_argument("-a", "--arch", choices=["auto", "x64", "arm64"], default="auto")
    parser.add_argument(
        "-f", "--format", nargs="+", default=["all"],
        help="package formats; 'all' builds every format whose tool is installed",
    )
    parser.add_argument("--no-build", action="store_true", help="package existing release outputs")
    parser.add_argument("--clean", action="store_true", help="run flutter clean first")
    parser.add_argument("--dist", type=Path, default=DIST, help="artifact output directory")
    args = parser.parse_args()

    DIST = args.dist.resolve()
    DIST.mkdir(parents=True, exist_ok=True)
    if args.clean:
        run("flutter", "clean")

    platforms = args.platform or ["auto"]
    platforms = [host_platform() if target == "auto" else target for target in platforms]
    arch = host_arch() if args.arch == "auto" else args.arch
    formats = set(args.format)
    version = project_version()

    if "harmonyos" in platforms:
        fail("HarmonyOS NEXT is not an upstream Flutter target; no valid HAP can be generated from this project")
    if "ipados" in platforms and "ios" not in platforms:
        platforms.append("ios")
    for target in dict.fromkeys(platforms):
        log(f"Building {target} ({arch}), version {version}")
        if target == "macos":
            package_macos(formats, args.no_build)
        elif target == "windows":
            package_windows(formats, args.no_build, arch)
        elif target == "linux":
            package_linux(formats, args.no_build, arch, version)
        elif target == "android":
            package_android(formats, args.no_build)
        elif target == "ios":
            package_ios(formats, args.no_build)
        elif target != "ipados":
            fail(f"Unsupported platform: {target}")
    log(f"Finished. Artifacts: {DIST}")


if __name__ == "__main__":
    main()
