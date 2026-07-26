#!/usr/bin/env python3
"""Build and package MdsScope on the current native build host.

Flutter desktop targets must be built on their native operating system. Android
can be built on every Flutter host; Apple targets require macOS and Xcode. The
GitHub release workflow runs this entry point on each required host.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap
from pathlib import Path
from typing import NoReturn


ROOT = Path(__file__).resolve().parent
DIST = ROOT / "build" / "dist"
APP = "mdsscope"
FLUTTER_BASELINE = "3.44.7"
RUST_BASELINE = "1.92.0"
ANDROID_API = "36"
ANDROID_NDK = "28.2.13676358"

PLATFORM_FORMATS = {
    "windows": {"exe", "msi", "zip", "tar.gz", "tar.xz", "tar.bz2"},
    "macos": {"app", "dmg", "pkg", "zip", "tar.gz", "tar.xz", "tar.bz2"},
    "linux": {
        "deb", "rpm", "pkg.tar.zst", "pkg.tar.xz", "AppImage",
        "zip", "tar.gz", "tar.xz", "tar.bz2",
    },
    "android": {"apk", "aab"},
    "ios": {"ipa", "unsigned-zip"},
    "ipados": {"ipa", "unsigned-zip"},
}


def log(message: str) -> None:
    print(f"[MdsScope] {message}", flush=True)


def fail(message: str) -> NoReturn:
    raise SystemExit(f"[MdsScope] ERROR: {message}")


def display_command(command: tuple[str, ...] | list[str]) -> str:
    if host_platform() == "windows":
        return subprocess.list2cmdline(command)
    return shlex.join(command)


def run(*command: str, cwd: Path = ROOT, check: bool = True) -> subprocess.CompletedProcess[str]:
    log("Running: " + display_command(command))
    executable = shutil.which(command[0])
    if executable is None:
        fail(
            f"Required command '{command[0]}' was not found on PATH. "
            "Run build_app.py --doctor for platform-specific installation guidance."
        )
    if host_platform() == "windows" and executable is not None:
        if Path(executable).suffix.lower() in {".bat", ".cmd"}:
            command = (os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", executable, *command[1:])
        else:
            command = (executable, *command[1:])
    try:
        return subprocess.run(command, cwd=cwd, check=check, text=True)
    except OSError as error:
        fail(f"Could not start '{command[0]}': {error}")


def prepend_path(directory: Path) -> None:
    resolved = str(directory.resolve())
    entries = os.environ.get("PATH", "").split(os.pathsep)
    if resolved.lower() not in {entry.lower() for entry in entries if entry}:
        os.environ["PATH"] = resolved + os.pathsep + os.environ.get("PATH", "")


def configure_sdk_paths(
    flutter_sdk: Path | None,
    cargo_home: Path | None,
    android_sdk: Path | None,
) -> None:
    if flutter_sdk is not None:
        sdk = flutter_sdk.expanduser().resolve()
        flutter = sdk / "bin" / ("flutter.bat" if host_platform() == "windows" else "flutter")
        if not flutter.is_file():
            fail(f"--flutter-sdk does not contain bin/{flutter.name}: {sdk}")
        os.environ["FLUTTER_ROOT"] = str(sdk)
        prepend_path(sdk / "bin")

    if cargo_home is not None:
        home = cargo_home.expanduser().resolve()
        cargo = home / "bin" / ("cargo.exe" if host_platform() == "windows" else "cargo")
        if not cargo.is_file():
            fail(f"--cargo-home does not contain bin/{cargo.name}: {home}")
        os.environ["CARGO_HOME"] = str(home)
        prepend_path(home / "bin")

    if android_sdk is not None:
        sdk = android_sdk.expanduser().resolve()
        if not sdk.is_dir():
            fail(f"--android-sdk is not a directory: {sdk}")
        os.environ["ANDROID_HOME"] = str(sdk)
        os.environ["ANDROID_SDK_ROOT"] = str(sdk)


def windows_tool_candidates() -> dict[str, list[Path]]:
    program_files = Path(os.environ.get("ProgramFiles", "C:/Program Files"))
    program_files_x86 = Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)"))
    wix = Path(os.environ.get("WIX", str(program_files_x86 / "WiX Toolset v3.14")))
    return {
        "ISCC": [program_files_x86 / "Inno Setup 6/ISCC.exe"],
        "heat": [wix / "bin/heat.exe"],
        "candle": [wix / "bin/candle.exe"],
        "light": [wix / "bin/light.exe"],
        "perl": [
            Path("C:/Strawberry/perl/bin/perl.exe"),
            program_files / "Git/usr/bin/perl.exe",
        ],
        "nasm": [
            Path("C:/Strawberry/c/bin/nasm.exe"),
            program_files / "NASM/nasm.exe",
            program_files_x86 / "NASM/nasm.exe",
        ],
        "bash": [
            program_files / "Git/bin/bash.exe",
            program_files / "Git/usr/bin/bash.exe",
        ],
        "vswhere": [program_files_x86 / "Microsoft Visual Studio/Installer/vswhere.exe"],
    }


def tool(name: str) -> str | None:
    found = shutil.which(name)
    if found is not None or host_platform() != "windows":
        return found
    return next(
        (str(path) for path in windows_tool_candidates().get(name, []) if path.is_file()),
        None,
    )


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


def capture(*command: str) -> tuple[int, str]:
    executable = shutil.which(command[0])
    if executable is None:
        return 127, ""
    resolved: tuple[str, ...]
    if host_platform() == "windows" and Path(executable).suffix.lower() in {".bat", ".cmd"}:
        resolved = (os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", executable, *command[1:])
    else:
        resolved = (executable, *command[1:])
    try:
        result = subprocess.run(
            resolved,
            cwd=ROOT,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        return result.returncode, result.stdout.strip()
    except OSError:
        return 126, ""


def parse_local_properties() -> dict[str, str]:
    properties: dict[str, str] = {}
    path = ROOT / "android/local.properties"
    if not path.is_file():
        return properties
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        properties[key.strip()] = value.strip().replace("\\\\", "\\")
    return properties


def find_android_sdk() -> Path | None:
    configured = (
        os.environ.get("ANDROID_HOME")
        or os.environ.get("ANDROID_SDK_ROOT")
        or parse_local_properties().get("sdk.dir")
    )
    if configured:
        path = Path(configured).expanduser()
        if path.is_dir():
            return path.resolve()
    return None


def find_sdkmanager(sdk: Path) -> Path | None:
    names = ["sdkmanager.bat", "sdkmanager"] if host_platform() == "windows" else ["sdkmanager"]
    for relative in (
        "cmdline-tools/latest/bin",
        "cmdline-tools/bin",
        "tools/bin",
    ):
        for name in names:
            candidate = sdk / relative / name
            if candidate.is_file():
                return candidate
    return None


def install_android_components(sdk: Path) -> None:
    manager = find_sdkmanager(sdk)
    if manager is None:
        fail(
            "Android SDK command-line tools are missing; could not find sdkmanager "
            f"under {sdk / 'cmdline-tools'}."
        )
    log(f"Installing Android platform {ANDROID_API} and NDK {ANDROID_NDK}")
    run(
        str(manager),
        f"platforms;android-{ANDROID_API}",
        f"ndk;{ANDROID_NDK}",
    )


def configure_platform_paths(platforms: list[str]) -> None:
    if host_platform() == "windows" and "android" in platforms and shutil.which("bash") is None:
        bash = tool("bash")
        if bash is not None:
            prepend_path(Path(bash).parent)


def validate_platforms(platforms: list[str], arch: str) -> None:
    host = host_platform()
    for target in platforms:
        if target == "harmonyos":
            fail(
                "HarmonyOS NEXT is not an upstream Flutter target and this repository "
                "does not contain an ArkUI/OpenHarmony project; no valid HAP can be built."
            )
        if target in {"windows", "macos", "linux"} and target != host:
            fail(f"{target} desktop packages must be built on a {target} host, not {host}.")
        if target in {"ios", "ipados"} and host != "macos":
            fail("iOS/iPadOS packages require macOS, Xcode, and Apple signing tools.")
        if target in {"windows", "linux"} and arch != host_arch():
            fail(
                f"{target} {arch} must be built on a native {arch} host; "
                f"this host is {host_arch()}."
            )


def normalize_formats(platforms: list[str], requested: list[str]) -> set[str]:
    formats = {"AppImage" if value.lower() == "appimage" else value for value in requested}
    if "all" in formats and len(formats) != 1:
        fail("'all' cannot be combined with individual package formats.")
    if formats == {"all"}:
        return formats
    supported = set().union(*(PLATFORM_FORMATS.get(target, set()) for target in platforms))
    unknown = sorted(formats - supported)
    if unknown:
        choices = ", ".join(sorted(supported))
        fail(f"Unsupported format(s): {', '.join(unknown)}. Valid for this selection: {choices}")
    missing_targets = [
        target
        for target in platforms
        if not formats.intersection(PLATFORM_FORMATS.get(target, set()))
    ]
    if missing_targets:
        fail(
            "No requested format applies to: "
            + ", ".join(missing_targets)
            + ". Use 'all' or add a format for every selected platform."
        )
    return formats


def preflight(
    platforms: list[str],
    formats: set[str],
    arch: str,
    *,
    detailed: bool,
    build_required: bool = True,
) -> None:
    checks: list[tuple[str, bool, str, bool]] = []

    def add(name: str, path: str | None, hint: str, required: bool = True) -> None:
        checks.append((name, path is not None, path or hint, required))

    add(
        "Python >= 3.8",
        sys.executable if sys.version_info >= (3, 8) else None,
        "Install Python 3.8 or newer.",
    )
    if build_required:
        add("Flutter", shutil.which("flutter"), f"Install Flutter {FLUTTER_BASELINE} or pass --flutter-sdk.")
        add("rustup", shutil.which("rustup"), "Install rustup from https://rustup.rs/.")
        add("Cargo", shutil.which("cargo"), "Install Rust or pass --cargo-home.")
        add("rustc", shutil.which("rustc"), "Install Rust or pass --cargo-home.")

    host = host_platform()
    if build_required and "windows" in platforms:
        vswhere = tool("vswhere")
        visual_studio = None
        if vswhere is not None:
            required_components = [
                "Microsoft.VisualStudio.Component.VC.Tools.ARM64"
                if arch == "arm64"
                else "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                "Microsoft.VisualStudio.Component.VC.ATL.ARM64"
                if arch == "arm64"
                else "Microsoft.VisualStudio.Component.VC.ATL",
            ]
            code, output = capture(
                vswhere,
                "-latest",
                "-products",
                "*",
                "-requires",
                *required_components,
                "-property",
                "installationPath",
            )
            visual_studio = output.splitlines()[-1] if code == 0 and output else None
        add(
            "Visual Studio C++",
            visual_studio,
            "Install Visual Studio 2022+ with Desktop development with C++ and ATL.",
        )
        add("PowerShell", shutil.which("pwsh") or shutil.which("powershell"), "Install Windows PowerShell.")
        add("Perl", tool("perl"), "Install Strawberry Perl or Git for Windows with Perl.")
        if arch == "x64":
            add("NASM", tool("nasm"), "Install NASM or Strawberry Perl.")
    if build_required and (
        "macos" in platforms or "ios" in platforms or "ipados" in platforms
    ):
        add("Xcode", shutil.which("xcodebuild"), "Install Xcode and select it with xcode-select.")
        add("Xcode tools", shutil.which("xcrun"), "Run xcode-select --install.")
        add("lipo", shutil.which("lipo"), "Install Xcode command-line tools.")
    if build_required and "linux" in platforms:
        for name, hint in (
            ("clang", "Install clang."),
            ("cmake", "Install cmake."),
            ("ninja", "Install ninja-build."),
            ("pkg-config", "Install pkg-config."),
            ("perl", "Install perl for vendored OpenSSL."),
        ):
            add(name, shutil.which(name), hint)
        gtk_ok = capture("pkg-config", "--exists", "gtk+-3.0")[0] == 0
        checks.append(("GTK 3 development files", gtk_ok, "Install libgtk-3-dev.", True))
        secret_ok = capture("pkg-config", "--exists", "libsecret-1")[0] == 0
        checks.append(
            (
                "Secret Service development files",
                secret_ok,
                "Install libsecret-1-dev (Debian/Ubuntu) or libsecret-devel.",
                True,
            )
        )
    if build_required and "android" in platforms:
        java = shutil.which("java")
        java_ok = False
        if java is not None:
            code, output = capture("java", "-version")
            match = re.search(r'version "(?:1\.)?(\d+)', output)
            java_ok = code == 0 and match is not None and int(match.group(1)) >= 17
        add("Java 17+", java if java_ok else None, "Install a JDK 17 or newer.")
        add("Bash", shutil.which("bash"), "Install Bash; on Windows install Git for Windows.")
        add("Perl", tool("perl"), "Install Perl for vendored OpenSSL.")
        sdk = find_android_sdk()
        checks.append(("Android SDK", sdk is not None, str(sdk) if sdk else "Pass --android-sdk.", True))
        if sdk is not None:
            platform_dir = sdk / f"platforms/android-{ANDROID_API}"
            ndk_dir = sdk / f"ndk/{ANDROID_NDK}"
            checks.append((
                f"Android platform {ANDROID_API}",
                platform_dir.is_dir(),
                str(platform_dir) if platform_dir.is_dir() else "Use --install-android-sdk-components.",
                True,
            ))
            checks.append((
                f"Android NDK {ANDROID_NDK}",
                ndk_dir.is_dir(),
                str(ndk_dir) if ndk_dir.is_dir() else "Use --install-android-sdk-components.",
                True,
            ))

    explicitly_required = formats != {"all"}
    if "windows" in platforms:
        if selected(formats, "exe"):
            add("Inno Setup 6", tool("ISCC"), "Install Inno Setup 6.", explicitly_required)
        if selected(formats, "msi"):
            for name in ("heat", "candle", "light"):
                add(f"WiX {name}", tool(name), "Install WiX Toolset 3.14.", explicitly_required)
    if "linux" in platforms:
        optional_tools = {
            "deb": "dpkg-deb",
            "rpm": "rpmbuild",
            "pkg.tar.zst": "zstd",
            "pkg.tar.xz": "xz",
            "AppImage": "appimagetool",
        }
        for package_format, name in optional_tools.items():
            if selected(formats, package_format):
                add(name, shutil.which(name), f"Install {name}.", explicitly_required)

    failures = 0
    log(f"Preflight for {', '.join(platforms)} on {host}/{host_arch()}")
    for name, ok, detail, required in checks:
        if ok:
            if detailed:
                print(f"  [OK]      {name}: {detail}")
        elif required:
            failures += 1
            print(f"  [MISSING] {name}: {detail}")
        elif detailed:
            print(f"  [OPTIONAL] {name}: {detail}")

    if detailed and shutil.which("flutter"):
        code, output = capture("flutter", "--version", "--machine")
        if code == 0:
            try:
                data = json.loads(output)
                print(
                    "  [INFO]    Flutter: "
                    f"{data.get('frameworkVersion', 'unknown')} "
                    f"({data.get('channel', 'unknown')})"
                )
            except json.JSONDecodeError:
                print(f"  [INFO]    Flutter: {output.splitlines()[0] if output else 'unknown'}")
        code, output = capture("rustc", "--version")
        if code == 0:
            print(f"  [INFO]    Rust: {output}")
        print(f"  [INFO]    Expected baseline: Flutter {FLUTTER_BASELINE}, Rust {RUST_BASELINE}")

    if failures:
        fail(f"Preflight found {failures} missing required component(s).")
    log("Preflight passed")


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
    run("flutter", "build", target, "--release", "--no-pub", *arguments)


def prepare_macos_application(app: Path) -> None:
    identity = os.environ.get("MDSSCOPE_MACOS_SIGN_IDENTITY", "").strip()
    if identity:
        run(
            "codesign", "--force", "--deep", "--options", "runtime",
            "--timestamp", "--sign", identity, str(app),
        )
    else:
        # Keep portable bundles internally consistent without pretending that
        # an ad-hoc signature replaces Developer ID distribution.
        run("codesign", "--force", "--deep", "--sign", "-", str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))

    notary_profile = os.environ.get("MDSSCOPE_NOTARY_PROFILE", "").strip()
    if identity and notary_profile:
        with tempfile.TemporaryDirectory(prefix="mdsscope-notary-") as temporary:
            submission = Path(temporary) / "MdsScope.zip"
            run(
                "ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                str(app), str(submission),
            )
            run(
                "xcrun", "notarytool", "submit", str(submission),
                "--keychain-profile", notary_profile, "--wait",
            )
        run("xcrun", "stapler", "staple", str(app))


def sign_and_notarize_macos_artifact(path: Path) -> None:
    identity = os.environ.get("MDSSCOPE_MACOS_SIGN_IDENTITY", "").strip()
    notary_profile = os.environ.get("MDSSCOPE_NOTARY_PROFILE", "").strip()
    if identity and path.suffix == ".dmg":
        run(
            "codesign", "--force", "--timestamp", "--sign", identity,
            str(path),
        )
    if identity and notary_profile:
        run(
            "xcrun", "notarytool", "submit", str(path),
            "--keychain-profile", notary_profile, "--wait",
        )
        run("xcrun", "stapler", "staple", str(path))


def package_macos(formats: set[str], no_build: bool) -> None:
    if host_platform() != "macos":
        fail("macOS packages can only be built on macOS")
    if not no_build:
        flutter_build("macos")

    app = ROOT / "build/macos/Build/Products/Release/MdsScope.app"
    if not app.is_dir():
        fail(f"macOS application bundle not found: {app}")
    prepare_macos_application(app)
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
        dmg = DIST / f"{base}.dmg"
        run(
            "hdiutil", "create", "-quiet", "-volname", "MdsScope",
            "-srcfolder", str(app), "-ov", "-format", "UDZO", str(dmg),
        )
        sign_and_notarize_macos_artifact(dmg)
    if selected(formats, "pkg"):
        package = DIST / f"{base}.pkg"
        installer_identity = os.environ.get(
            "MDSSCOPE_MACOS_INSTALLER_IDENTITY", ""
        ).strip()
        command = [
            "pkgbuild", "--component", str(app),
            "--install-location", "/Applications",
        ]
        if installer_identity:
            command.extend(["--sign", installer_identity])
        command.append(str(package))
        run(*command)
        sign_and_notarize_macos_artifact(package)


def windows_bundle(arch: str) -> Path:
    return ROOT / f"build/windows/{arch}/runner/Release"


def package_windows(formats: set[str], no_build: bool, arch: str) -> None:
    if host_platform() != "windows":
        fail("Windows packages can only be built on Windows")
    if arch not in {"x64", "arm64"}:
        fail("Flutter supports Windows x64 and arm64, not " + arch)
    if arch != host_arch():
        fail(
            "Flutter 3.44 builds Windows for the native host architecture; "
            f"requested {arch} on a {host_arch()} host"
        )
    if not no_build:
        flutter_build("windows")

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
    if selected(formats, "msi"):
        heat = format_tool("heat", formats, "msi")
        candle = format_tool("candle", formats, "msi")
        light = format_tool("light", formats, "msi")
        if heat is not None and candle is not None and light is not None:
            with tempfile.TemporaryDirectory(prefix="mdsscope-wix-") as temporary:
                wix = Path(temporary)
                harvested = wix / "bundle.wxs"
                run(
                    heat, "dir", str(bundle), "-nologo", "-cg", "AppFiles", "-dr", "INSTALLFOLDER",
                    "-gg", "-scom", "-sreg", "-sfrag", "-srd", "-var", "var.BundleDir",
                    "-out", str(harvested),
                )
                wix_arch = {"x64": "x64", "arm64": "arm64"}[arch]
                run(
                    candle, "-nologo", "-arch", wix_arch,
                    f"-dBundleDir={bundle}", f"-dAppVersion={project_version()}",
                    f"-dIconPath={ROOT / 'windows/runner/resources/app_icon.ico'}",
                    "-out", str(wix) + os.sep,
                    str(ROOT / "packaging/windows/mdsscope.wxs"), str(harvested),
                )
                run(
                    light, "-nologo", "-ext", "WixUIExtension",
                    "-out", str(DIST / f"{base}.msi"),
                    str(wix / "mdsscope.wixobj"), str(wix / "bundle.wixobj"),
                )


def linux_bundle(arch: str) -> Path:
    return ROOT / f"build/linux/{arch}/release/bundle"


def is_linux_system_runtime(name: str) -> bool:
    """Return libraries that must come from the target Linux base system.

    Bundling glibc or its loader makes a package less portable and can break
    NSS, DNS and thread-local runtime behavior. Everything above this small
    ABI floor is carried in the portable archives.
    """
    return bool(re.fullmatch(
        r"(?:ld-linux[^/]*|libc|libdl|libm|libpthread|libresolv|librt|"
        r"libutil|libanl|libnss_[^.]+)\.so(?:\..*)?",
        name,
    ))


def parse_linux_ldd(output: str, binary: Path) -> list[Path]:
    dependencies: list[Path] = []
    for line in output.splitlines():
        if "=> not found" in line:
            fail(f"Unresolved Linux dependency for {binary}: {line.strip()}")
        match = re.search(r"=>\s+(/[^\s]+)", line)
        if match is None:
            match = re.match(r"\s*(/[^\s]+)\s+\(", line)
        if match is not None:
            dependencies.append(Path(match.group(1)))
    return dependencies


def is_elf(path: Path) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    try:
        with path.open("rb") as stream:
            return stream.read(4) == b"\x7fELF"
    except OSError:
        return False


def linux_module_files(package: str, subdirectory: str) -> list[Path]:
    code, libdir = capture("pkg-config", "--variable=libdir", package)
    if code != 0 or not libdir:
        return []
    return sorted(Path(libdir).glob(f"{subdirectory}/*.so"))


def copy_linux_portable_dependencies(portable: Path) -> None:
    """Copy the non-glibc dependency closure and dynamically loaded GTK bits."""
    library_dir = portable / "lib"
    library_dir.mkdir(parents=True, exist_ok=True)
    module_groups = {
        "gdk-pixbuf-loaders": linux_module_files(
            "gdk-pixbuf-2.0", "gdk-pixbuf-2.0/*/loaders"
        ),
        "gtk-immodules": linux_module_files(
            "gtk+-3.0", "gtk-3.0/*/immodules"
        ),
        # Keep the directory present and isolated even when no optional GIO
        # modules are required. The launcher forces the local VFS.
        "gio-modules": [],
    }
    for group, modules in module_groups.items():
        destination = library_dir / group
        destination.mkdir(parents=True, exist_ok=True)
        for module in modules:
            shutil.copy2(module.resolve(), destination / module.name)

    libexec = portable / "libexec"
    libexec.mkdir(parents=True, exist_ok=True)
    for executable in ("gdk-pixbuf-query-loaders", "gtk-query-immodules-3.0"):
        path = shutil.which(executable)
        if path is not None:
            shutil.copy2(Path(path).resolve(), libexec / executable)

    queue = [path for path in portable.rglob("*") if is_elf(path)]
    known = {path.name: path for path in library_dir.iterdir() if is_elf(path)}
    index = 0
    environment = dict(os.environ)
    environment["LD_LIBRARY_PATH"] = str(library_dir)
    while index < len(queue):
        binary = queue[index]
        index += 1
        result = subprocess.run(
            ["ldd", str(binary)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=environment,
        )
        if result.returncode != 0:
            fail(f"Could not inspect Linux dependencies for {binary}:\n{result.stdout}")
        for dependency in parse_linux_ldd(result.stdout, binary):
            name = dependency.name
            if is_linux_system_runtime(name) or name in known:
                continue
            destination = library_dir / name
            shutil.copy2(dependency.resolve(), destination)
            known[name] = destination
            queue.append(destination)


def stage_linux_portable(bundle: Path, portable: Path) -> None:
    replace_tree(bundle, portable)
    executable = portable / "mdsscope"
    executable.rename(portable / "mdsscope.bin")
    shutil.copy2(ROOT / "packaging/linux/mdsscope-portable", executable)
    executable.chmod(0o755)
    applications = portable / "share/applications"
    applications.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "packaging/linux/com.mdsscope.app.desktop", applications)
    icons = portable / "share/icons/hicolor/scalable/apps"
    icons.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "assets/app_icon.svg", icons / "com.mdsscope.app.svg")
    mime_packages = portable / "share/mime/packages"
    mime_packages.mkdir(parents=True, exist_ok=True)
    shutil.copy2(
        ROOT / "packaging/linux/com.mdsscope.configuration.xml",
        mime_packages,
    )
    copy_linux_portable_dependencies(portable)


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
    mime_packages = root / "usr/share/mime/packages"
    mime_packages.mkdir(parents=True, exist_ok=True)
    shutil.copy2(
        ROOT / "packaging/linux/com.mdsscope.configuration.xml",
        mime_packages,
    )


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

    with tempfile.TemporaryDirectory(prefix="mdsscope-linux-") as temporary:
        portable = Path(temporary) / base
        stage_linux_portable(bundle, portable)
        if selected(formats, "zip"):
            make_zip(portable, DIST / f"{base}.zip", base)
        if selected(formats, "tar.gz"):
            make_tar(portable, DIST / f"{base}.tar.gz", base, "w:gz")
        if selected(formats, "tar.xz"):
            make_tar(portable, DIST / f"{base}.tar.xz", base, "w:xz")
        if selected(formats, "tar.bz2"):
            make_tar(portable, DIST / f"{base}.tar.bz2", base, "w:bz2")

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
                        "Depends: libc6, libgtk-3-0, libsecret-1-0, libstdc++6",
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
                    f"arch = {rpm_arch}\nsize = {installed_size}\n"
                    "depend = gtk3\ndepend = libsecret\n",
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
                app_bundle = app_dir / "usr/lib/mdsscope"
                replace_tree(portable, app_bundle)
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
                "flutter", "build", "apk", "--release", "--no-pub", "--split-per-abi",
                "--target-platform", "android-arm,android-arm64,android-x64",
            )
            run(
                "flutter", "build", "apk", "--release", "--no-pub",
                "--target-platform", "android-arm,android-arm64,android-x64",
            )
        if selected(formats, "aab"):
            run(
                "flutter", "build", "appbundle", "--release", "--no-pub",
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
    # One universal Apple mobile binary supports both iPhone and iPad. Both
    # names are published as aliases so platform-filtered release clients find it.
    if selected(formats, "unsigned-zip"):
        if not no_build:
            flutter_build("ios", "--no-codesign")
        app = ROOT / "build/ios/iphoneos/Runner.app"
        if not app.is_dir():
            fail(f"Unsigned iOS application bundle not found: {app}")
        make_zip(app, DIST / "mdsscope-ios-arm64-unsigned.zip", app.name)
        shutil.copy2(
            DIST / "mdsscope-ios-arm64-unsigned.zip",
            DIST / "mdsscope-ipados-arm64-unsigned.zip",
        )
    if selected(formats, "ipa"):
        if not no_build:
            flutter_build("ipa")
        ipas = sorted((ROOT / "build/ios/ipa").glob("*.ipa"))
        if len(ipas) != 1:
            fail("A signed IPA was not produced. Configure Apple signing in Xcode first.")
        shutil.copy2(ipas[0], DIST / "mdsscope-ios-arm64.ipa")
        shutil.copy2(ipas[0], DIST / "mdsscope-ipados-arm64.ipa")


class HelpFormatter(argparse.RawDescriptionHelpFormatter):
    pass


def create_parser() -> argparse.ArgumentParser:
    formats = "\n".join(
        f"  {platform_name:8} {', '.join(sorted(values))}"
        for platform_name, values in PLATFORM_FORMATS.items()
        if platform_name != "ipados"
    )
    epilog = "Package formats:\n" + formats + "\n\n" + textwrap.dedent(
        f"""\
        'all' builds the platform's default formats and every optional package
        whose packaging tool is installed. Explicitly requested formats are
        strict: a missing packaging tool is an error.

        Examples:
          python build_app.py --doctor -p windows
          python build_app.py -p windows -a x64 -f zip
          python build_app.py -p android -f apk aab --install-android-sdk-components
          ./build_app.py -p macos -f app dmg zip
          ./build_app.py -p ios -f unsigned-zip
          ./build_app.py -p ios -p ipados -f ipa
          ./build_app.py -p linux -a arm64 -f deb zip

        SDK paths may be passed explicitly, so modifying the parent shell's
        PATH is optional:
          python build_app.py -p windows -f zip \\
            --flutter-sdk C:\\SDKs\\flutter\\{FLUTTER_BASELINE} \\
            --cargo-home C:\\Users\\me\\.cargo

        A first native build compiles vendored OpenSSL and may take several
        minutes. IPA output requires Xcode signing; unsigned-zip does not.
        HarmonyOS NEXT is reported as unsupported because upstream Flutter
        cannot produce a HAP and this repository has no ArkUI project.
        See docs/BUILDING.md for complete host prerequisites and signing.
        """
    )
    return argparse.ArgumentParser(
        description=(
            "Build and package MdsScope, including its native Rust bridge.\n"
            "Desktop and Apple builds must run on a native host; Android builds "
            "run on Windows, macOS, or Linux."
        ),
        epilog=epilog,
        formatter_class=HelpFormatter,
    )


def main() -> None:
    global DIST

    parser = create_parser()
    parser.add_argument(
        "-p", "--platform", action="append",
        choices=["auto", "windows", "macos", "linux", "android", "ios", "ipados", "harmonyos"],
        help="target platform; repeat for several targets (default: native desktop)",
    )
    parser.add_argument(
        "-a", "--arch", choices=["auto", "x64", "arm64"], default="auto",
        help="desktop output architecture; Windows/Linux require a matching native host (default: auto)",
    )
    parser.add_argument(
        "-f", "--format", nargs="+", default=["all"],
        help="one or more formats from the table below (default: all)",
    )
    parser.add_argument(
        "--no-build", action="store_true",
        help="only package existing release output; fail if it is absent",
    )
    parser.add_argument(
        "--clean", action="store_true",
        help="run 'flutter clean' before the build (cannot be combined with --no-build)",
    )
    parser.add_argument(
        "--skip-preflight", action="store_true",
        help="skip dependency checks (intended only for controlled CI environments)",
    )
    parser.add_argument(
        "--doctor", action="store_true",
        help="show detailed dependency diagnostics and exit without building",
    )
    parser.add_argument(
        "--install-android-sdk-components", action="store_true",
        help=f"install Android platform {ANDROID_API} and NDK {ANDROID_NDK} with sdkmanager",
    )
    parser.add_argument(
        "--flutter-sdk", type=Path,
        help=f"Flutter SDK root containing bin/flutter (tested baseline: {FLUTTER_BASELINE})",
    )
    parser.add_argument(
        "--cargo-home", type=Path,
        help="Cargo home containing bin/cargo (the repository pins Rust 1.92.0)",
    )
    parser.add_argument(
        "--android-sdk", type=Path,
        help="Android SDK root; overrides ANDROID_HOME/ANDROID_SDK_ROOT",
    )
    parser.add_argument(
        "--dist", type=Path, default=DIST,
        help="artifact output directory (default: build/dist)",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=(
            f"MdsScope {project_version()} build script "
            f"(Flutter {FLUTTER_BASELINE}, Rust {RUST_BASELINE})"
        ),
    )
    args = parser.parse_args()

    configure_sdk_paths(args.flutter_sdk, args.cargo_home, args.android_sdk)

    platforms = args.platform or ["auto"]
    platforms = [host_platform() if target == "auto" else target for target in platforms]
    arch = host_arch() if args.arch == "auto" else args.arch
    if "ipados" in platforms and "ios" not in platforms:
        platforms.append("ios")
    platforms = list(dict.fromkeys(platforms))
    configure_platform_paths(platforms)
    validate_platforms(platforms, arch)
    formats = normalize_formats(platforms, args.format)

    if args.clean and args.no_build:
        fail("--clean and --no-build cannot be combined.")
    if args.install_android_sdk_components:
        if "android" not in platforms:
            fail("--install-android-sdk-components requires '-p android'.")
        sdk = find_android_sdk()
        if sdk is None:
            fail("Android SDK was not found; pass --android-sdk.")
        install_android_components(sdk)
    if not args.skip_preflight:
        preflight(
            platforms,
            formats,
            arch,
            detailed=args.doctor,
            build_required=not args.no_build or args.doctor,
        )
    if args.doctor:
        run("flutter", "doctor", "-v", check=False)
        run("rustup", "show", check=False)
        log("Doctor completed; no build was started.")
        return

    DIST = args.dist.resolve()
    DIST.mkdir(parents=True, exist_ok=True)
    if args.clean:
        run("flutter", "clean")

    version = project_version()

    for target in platforms:
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
    try:
        main()
    except subprocess.CalledProcessError as error:
        command = error.cmd if isinstance(error.cmd, (list, tuple)) else [str(error.cmd)]
        fail(
            f"Command failed with exit code {error.returncode}: {display_command(command)}\n"
            "Run this script again with --doctor for dependency diagnostics. "
            "Use --clean if the SDK/toolchain changed since the last build."
        )
    except KeyboardInterrupt:
        fail("Interrupted by user.")
