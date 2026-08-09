#!/usr/bin/env python3
"""Build and package MDSLens on the current native build host.

Flutter desktop targets must be built on their native operating system. Android
can be built on every Flutter host; Apple targets require macOS and Xcode. The
GitHub release workflow runs this entry point on each required host.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import time
from pathlib import Path
from typing import NoReturn


ROOT = Path(__file__).resolve().parent
DIST = ROOT / "build" / "dist"
APP = "mdslens"
FLUTTER_BASELINE = "3.44.7"
RUST_BASELINE = "1.92.0"
ANDROID_API = "36"
ANDROID_NDK = "28.2.13676358"
APPLE_FLUTTER_BUILD_RETRIES = 4
APPLE_FLUTTER_RETRY_DELAY_SECONDS = 15

PLATFORM_FORMATS = {
    "windows": {"exe", "msi", "msix", "zip", "7z", "tar.gz", "tar.xz", "tar.bz2"},
    "macos": {
        "app", "dmg", "pkg", "xcarchive",
        "zip", "7z", "tar.gz", "tar.xz", "tar.bz2",
    },
    "linux": {
        "deb", "rpm", "pkg.tar.zst", "pkg.tar.xz", "AppImage",
        "flatpak", "snap", "zip", "7z", "tar.gz", "tar.xz", "tar.bz2",
    },
    "android": {"apk", "aab", "apks"},
    "ios": {
        "unsigned-ipa", "unsigned-app", "xcarchive",
        "zip", "7z", "tar.gz", "tar.xz", "tar.bz2",
    },
    "ipados": {
        "unsigned-ipa", "unsigned-app", "xcarchive",
        "zip", "7z", "tar.gz", "tar.xz", "tar.bz2",
    },
}


def log(message: str) -> None:
    print(f"[MDSLens] {message}", flush=True)


def fail(message: str) -> NoReturn:
    raise SystemExit(f"[MDSLens] ERROR: {message}")


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
        "7z": [program_files / "7-Zip/7z.exe"],
        "makeappx": sorted(
            (program_files_x86 / "Windows Kits/10/bin").glob("*/x64/makeappx.exe"),
            reverse=True,
        ),
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


def seven_zip_tool(formats: set[str]) -> str | None:
    found = tool("7z") or tool("7zz") or tool("7za")
    if found is not None:
        return found
    if "all" in formats:
        log("Skipping 7z: optional tool '7z/7zz/7za' is not installed")
        return None
    fail("'7z', '7zz', or '7za' is required for 7z")


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


def find_bundletool() -> Path | None:
    configured = os.environ.get("BUNDLETOOL_JAR", "").strip()
    if configured:
        path = Path(configured).expanduser().resolve()
        return path if path.is_file() else None
    candidates = sorted((ROOT / "tools").glob("bundletool-all-*.jar"), reverse=True)
    return candidates[0] if candidates else None


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
            fail("iOS/iPadOS packages require macOS and Xcode command-line tools.")
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
    explicitly_required = formats != {"all"}
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
            ("patchelf", "Install patchelf."),
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
        if selected(formats, "apks"):
            bundletool = find_bundletool()
            checks.append(
                (
                    "bundletool",
                    bundletool is not None,
                    str(bundletool) if bundletool else "Set BUNDLETOOL_JAR.",
                    explicitly_required,
                )
            )
    if "windows" in platforms:
        if selected(formats, "exe"):
            add("Inno Setup 6", tool("ISCC"), "Install Inno Setup 6.", explicitly_required)
        if selected(formats, "msi"):
            for name in ("heat", "candle", "light"):
                add(f"WiX {name}", tool(name), "Install WiX Toolset 3.14.", explicitly_required)
        if selected(formats, "msix"):
            add(
                "MakeAppx",
                tool("makeappx"),
                "Install the Windows 10/11 SDK.",
                explicitly_required,
            )
    if "linux" in platforms:
        optional_tools = {
            "deb": "dpkg-deb",
            "rpm": "rpmbuild",
            "pkg.tar.zst": "zstd",
            "pkg.tar.xz": "xz",
            "AppImage": "appimagetool",
            "flatpak": "flatpak",
            "snap": "mksquashfs",
        }
        for package_format, name in optional_tools.items():
            if selected(formats, package_format):
                add(name, shutil.which(name), f"Install {name}.", explicitly_required)
    if selected(formats, "7z"):
        add(
            "7-Zip",
            tool("7z") or tool("7zz") or tool("7za"),
            "Install 7-Zip.",
            explicitly_required,
        )

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
    configured = os.environ.get("MDSLENS_VERSION", "").strip()
    if configured:
        return normalize_release_version(configured)

    code, exact_tag = capture(
        "git", "describe", "--tags", "--match", "v[0-9]*", "--exact-match"
    )
    if code == 0 and exact_tag:
        return normalize_release_version(exact_tag)

    match = re.search(
        r"^version:\s*([^+\s]+)",
        (ROOT / "pubspec.yaml").read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if match is None:
        fail("pubspec.yaml has no version")
    return normalize_release_version(match.group(1))


def normalize_release_version(value: str) -> str:
    match = re.fullmatch(
        r"v?(\d+)\.(\d+)(?:\.(\d+))?(?:\+\d+)?",
        value.strip(),
        re.IGNORECASE,
    )
    if match is None:
        fail(
            f"Invalid release version '{value}'. Expected vMAJOR.MINOR[.PATCH]."
        )
    patch = match.group(3)
    return ".".join([match.group(1), match.group(2), *([patch] if patch else [])])


def release_build_number(version: str) -> int:
    parts = [int(part) for part in normalize_release_version(version).split(".")]
    parts.extend([0] * (3 - len(parts)))
    major, minor, patch = parts
    if major > 2_147 or minor > 999 or patch > 999:
        fail(
            "Release versions must keep MAJOR <= 2147 and MINOR/PATCH <= 999 "
            "so every platform receives a valid monotonic build number."
        )
    build_number = major * 1_000_000 + minor * 1_000 + patch
    if build_number == 0:
        fail("Release version 0.0.0 cannot produce a valid platform build number.")
    return build_number


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
        with tempfile.TemporaryDirectory(prefix="mdslens-zip-") as temporary:
            staged = Path(temporary) / arcname
            replace_tree(source, staged)
            archive_base = output.with_suffix("")
            made = Path(shutil.make_archive(str(archive_base), "zip", temporary))
            if made != output:
                made.replace(output)
    log(f"Created {output.name}")


def make_7z(source: Path, output: Path, arcname: str, formats: set[str]) -> None:
    seven_zip = seven_zip_tool(formats)
    if seven_zip is None:
        return
    staged_source = source
    with tempfile.TemporaryDirectory(prefix="mdslens-7z-") as temporary:
        if source.name != arcname:
            staged_source = Path(temporary) / arcname
            replace_tree(source, staged_source)
        run(
            seven_zip, "a", "-t7z", "-mx=9", "-snl", str(output),
            staged_source.name, cwd=staged_source.parent,
        )
    log(f"Created {output.name}")


def selected(formats: set[str], name: str) -> bool:
    return "all" in formats or name in formats


def clear_flutter_package_checkout(target: str) -> None:
    """Remove an incomplete Xcode Swift Package checkout before retrying.

    Xcode stores source packages under Flutter's build directory.  A network
    failure during `git clone` can leave a bare repository that makes the next
    invocation fail immediately instead of retrying the download.  This only
    touches generated build output; the checked-in Package.resolved files are
    never changed.
    """

    package_dir = ROOT / "build" / target / "SourcePackages"
    if package_dir.is_symlink() or not package_dir.exists():
        return
    if package_dir.is_dir():
        log(f"Removing incomplete {target} Swift Package checkout before retry")
        shutil.rmtree(package_dir)


def flutter_build(target: str, *arguments: str) -> None:
    version = project_version()
    run("flutter", "pub", "get")
    command = (
        "flutter",
        "build",
        target,
        "--release",
        "--no-pub",
        "--build-name",
        version,
        "--build-number",
        str(release_build_number(version)),
        *arguments,
    )
    attempts = APPLE_FLUTTER_BUILD_RETRIES if target in {"ios", "macos"} else 1
    for attempt in range(1, attempts + 1):
        try:
            run(*command)
            return
        except subprocess.CalledProcessError:
            if attempt == attempts:
                raise
            clear_flutter_package_checkout(target)
            delay = APPLE_FLUTTER_RETRY_DELAY_SECONDS * attempt
            log(
                f"{target} build failed while resolving native packages; "
                f"retrying in {delay}s ({attempt + 1}/{attempts})"
            )
            time.sleep(delay)


def prepare_macos_application(app: Path) -> None:
    # Apple Silicon requires code-signature integrity even when an application
    # is distributed without a Developer ID identity.  An ad-hoc signature
    # keeps the bundle launchable after thinning while remaining unsigned for
    # trust/Gatekeeper purposes and suitable for user re-signing.
    run("codesign", "--force", "--deep", "--sign", "-", str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))

def macos_binary_architectures(path: Path) -> set[str]:
    if not path.is_file() or path.is_symlink():
        return set()
    code, output = capture("lipo", "-archs", str(path))
    if code != 0:
        return set()
    return set(output.split())


def prepare_macos_architecture(source: Path, destination: Path, arch: str) -> None:
    replace_tree(source, destination)
    expected = {"arm64", "x86_64"} if arch == "universal" else {
        "arm64" if arch == "arm64" else "x86_64"
    }
    inspected = 0
    for path in sorted(destination.rglob("*")):
        architectures = macos_binary_architectures(path)
        if not architectures:
            continue
        inspected += 1
        if not expected.issubset(architectures):
            fail(
                f"{path.relative_to(destination)} lacks the required {arch} "
                f"architecture (contains: {', '.join(sorted(architectures))})"
            )
        if arch != "universal" and len(architectures) > 1:
            run("lipo", str(path), "-thin", next(iter(expected)), "-output", str(path))
    if inspected == 0:
        fail(f"No Mach-O binaries were found in {source}")
    prepare_macos_application(destination)


def create_xcarchive(app: Path, output: Path, *, name: str) -> None:
    if output.exists():
        shutil.rmtree(output)
    archived_app = output / "Products/Applications" / app.name
    archived_app.parent.mkdir(parents=True)
    replace_tree(app, archived_app)
    version = project_version()
    with (output / "Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "ArchiveVersion": 2,
                "Name": name,
                "SchemeName": "Runner",
                "ApplicationProperties": {
                    "ApplicationPath": f"Applications/{app.name}",
                    "CFBundleIdentifier": "com.mdslens.app",
                    "CFBundleShortVersionString": version,
                },
            },
            stream,
        )
    log(f"Created {output.name}")
    # GitHub Releases accepts files, while .xcarchive is a directory bundle.
    # Publish a lossless ZIP alongside the local directory representation.
    make_zip(output, output.with_name(output.name + ".zip"), output.name)


def stage_macos_dmg(app: Path, destination: Path) -> None:
    """Stage the conventional drag-to-Applications disk-image layout."""
    replace_tree(app, destination / app.name)
    applications = destination / "Applications"
    if applications.exists() or applications.is_symlink():
        applications.unlink()
    applications.symlink_to("/Applications", target_is_directory=True)


def stage_macos_pkg_payload(app: Path, destination: Path) -> Path:
    """Stage a fixed-location payload instead of a relocatable app component.

    ``pkgbuild --component`` creates a bundle relocation rule.  That rule can
    make Installer update a matching MDSLens.app beside the downloaded PKG
    rather than install the release into /Applications.  A destination-root
    payload, paired with an explicit non-relocatable component plist, gives
    Installer exactly one valid destination.
    """
    payload_app = destination / app.name
    replace_tree(app, payload_app)
    return payload_app


def write_macos_pkg_component_plist(path: Path, app_name: str) -> None:
    """Describe MDSLens.app as a non-relocatable atomic replacement."""
    with path.open("wb") as stream:
        plistlib.dump(
            [
                {
                    "RootRelativeBundlePath": app_name,
                    "BundleIsRelocatable": False,
                    "BundleIsVersionChecked": True,
                    "BundleHasStrictIdentifier": True,
                    "BundleOverwriteAction": "upgrade",
                }
            ],
            stream,
        )


def build_macos_pkg(app: Path, output: Path, version: str, staging: Path) -> None:
    """Build an installer that always writes MDSLens.app to /Applications."""
    payload_root = staging / "payload"
    stage_macos_pkg_payload(app, payload_root)
    component_plist = staging / "components.plist"
    write_macos_pkg_component_plist(component_plist, app.name)
    run(
        "pkgbuild",
        "--root",
        str(payload_root),
        "--component-plist",
        str(component_plist),
        "--identifier",
        "com.mdslens.app",
        "--version",
        version,
        "--install-location",
        "/Applications",
        "--ownership",
        "recommended",
        str(output),
    )


def package_macos(formats: set[str], no_build: bool, requested_arch: str) -> None:
    if host_platform() != "macos":
        fail("macOS packages can only be built on macOS")
    if not no_build:
        flutter_build("macos")

    source = ROOT / "build/macos/Build/Products/Release/MDSLens.app"
    if not source.is_dir():
        fail(f"macOS application bundle not found: {source}")
    architectures = (
        ["arm64", "x64", "universal"]
        if requested_arch == "universal"
        else [requested_arch]
    )
    with tempfile.TemporaryDirectory(prefix="mdslens-macos-") as temporary:
        for arch in architectures:
            app = Path(temporary) / arch / "MDSLens.app"
            prepare_macos_architecture(source, app, arch)
            base = f"mdslens-macos-{arch}-unsigned"

            if selected(formats, "app"):
                replace_tree(app, DIST / f"{base}.app")
                log(f"Created {base}.app")
            if selected(formats, "zip"):
                make_zip(app, DIST / f"{base}.zip", app.name)
            if selected(formats, "7z"):
                make_7z(app, DIST / f"{base}.7z", app.name, formats)
            if selected(formats, "tar.gz"):
                make_tar(app, DIST / f"{base}.tar.gz", app.name, "w:gz")
            if selected(formats, "tar.xz"):
                make_tar(app, DIST / f"{base}.tar.xz", app.name, "w:xz")
            if selected(formats, "tar.bz2"):
                make_tar(app, DIST / f"{base}.tar.bz2", app.name, "w:bz2")
            if selected(formats, "dmg"):
                dmg_stage = Path(temporary) / arch / "dmg"
                stage_macos_dmg(app, dmg_stage)
                run(
                    "hdiutil", "create", "-quiet", "-volname", "MDSLens",
                    "-srcfolder", str(dmg_stage), "-ov", "-format", "UDZO",
                    str(DIST / f"{base}.dmg"),
                )
            if selected(formats, "pkg"):
                build_macos_pkg(
                    app,
                    DIST / f"{base}.pkg",
                    project_version(),
                    Path(temporary) / arch / "pkg",
                )
            if selected(formats, "xcarchive"):
                create_xcarchive(
                    app, DIST / f"{base}.xcarchive", name="MDSLens"
                )


def windows_bundle(arch: str) -> Path:
    return ROOT / f"build/windows/{arch}/runner/Release"


def windows_msix_version() -> str:
    parts = [int(value) for value in re.findall(r"\d+", project_version())[:4]]
    return ".".join(str(value) for value in (parts + [0, 0, 0, 0])[:4])


def windows_installer_architecture(arch: str) -> str:
    return {"x64": "x64compatible", "arm64": "arm64"}[arch]


def stage_windows_msix(bundle: Path, staging: Path, arch: str) -> None:
    replace_tree(bundle, staging)
    assets = staging / "Assets"
    assets.mkdir()
    for name in ("Square44x44Logo.png", "Square150x150Logo.png", "StoreLogo.png"):
        shutil.copy2(ROOT / "windows/runner/resources/msix" / name, assets / name)
    architecture = {"x64": "x64", "arm64": "arm64"}[arch]
    (staging / "AppxManifest.xml").write_text(
        textwrap.dedent(
            f"""\
            <?xml version="1.0" encoding="utf-8"?>
            <Package
              xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
              xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
              xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
              IgnorableNamespaces="uap rescap">
              <Identity Name="MDSLens" Publisher="CN=MDSLens"
                Version="{windows_msix_version()}" ProcessorArchitecture="{architecture}" />
              <Properties>
                <DisplayName>MDSLens</DisplayName>
                <PublisherDisplayName>MDSLens Contributors</PublisherDisplayName>
                <Description>MDSplus signal waveform viewer</Description>
                <Logo>Assets\\StoreLogo.png</Logo>
              </Properties>
              <Resources><Resource Language="en-us" /></Resources>
              <Dependencies>
                <TargetDeviceFamily Name="Windows.Desktop"
                  MinVersion="10.0.17763.0" MaxVersionTested="10.0.26100.0" />
              </Dependencies>
              <Applications>
                <Application Id="MDSLens" Executable="mdslens.exe"
                  EntryPoint="Windows.FullTrustApplication">
                  <uap:VisualElements DisplayName="MDSLens"
                    Description="MDSplus signal waveform viewer"
                    BackgroundColor="transparent"
                    Square150x150Logo="Assets\\Square150x150Logo.png"
                    Square44x44Logo="Assets\\Square44x44Logo.png" />
                </Application>
              </Applications>
              <Capabilities>
                <rescap:Capability Name="runFullTrust" />
                <Capability Name="internetClient" />
                <Capability Name="privateNetworkClientServer" />
              </Capabilities>
            </Package>
            """
        ),
        encoding="utf-8",
    )


def stage_windows_portable(
    bundle: Path, portable: Path, version: str, arch: str
) -> None:
    replace_tree(bundle, portable)
    (portable / ".mdslens-portable.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "product": "com.mdslens.app",
                "platform": "windows",
                "version": version,
                "architecture": arch,
                "executable": "mdslens.exe",
            },
            indent=2,
            sort_keys=True,
        ) + "\n",
        encoding="utf-8",
    )


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
    if not (bundle / "mdslens.exe").is_file():
        fail(f"Windows application bundle not found: {bundle}")
    base = f"mdslens-windows-{arch}"
    with tempfile.TemporaryDirectory(prefix="mdslens-windows-portable-") as temporary:
        portable = Path(temporary) / base
        stage_windows_portable(bundle, portable, project_version(), arch)
        if selected(formats, "zip"):
            make_zip(portable, DIST / f"{base}.zip", base)
        if selected(formats, "7z"):
            make_7z(portable, DIST / f"{base}.7z", base, formats)
        if selected(formats, "tar.gz"):
            make_tar(portable, DIST / f"{base}.tar.gz", base, "w:gz")
        if selected(formats, "tar.xz"):
            make_tar(portable, DIST / f"{base}.tar.xz", base, "w:xz")
        if selected(formats, "tar.bz2"):
            make_tar(portable, DIST / f"{base}.tar.bz2", base, "w:bz2")
    if selected(formats, "exe"):
        iscc = format_tool("ISCC", formats, "exe")
        if iscc is not None:
            run(
                iscc,
                f"/DBundleDir={bundle}",
                f"/DOutputDir={DIST}",
                f"/DOutputBase={base}-setup",
                f"/DAppVersion={project_version()}",
                f"/DInstallerArchitecture={windows_installer_architecture(arch)}",
                str(ROOT / "packaging/windows/mdslens.iss"),
            )
    if selected(formats, "msi"):
        heat = format_tool("heat", formats, "msi")
        candle = format_tool("candle", formats, "msi")
        light = format_tool("light", formats, "msi")
        if heat is not None and candle is not None and light is not None:
            with tempfile.TemporaryDirectory(prefix="mdslens-wix-") as temporary:
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
                    str(ROOT / "packaging/windows/mdslens.wxs"), str(harvested),
                )
                run(
                    light, "-nologo", "-ext", "WixUIExtension",
                    "-out", str(DIST / f"{base}.msi"),
                    str(wix / "mdslens.wixobj"), str(wix / "bundle.wixobj"),
                )
    if selected(formats, "msix"):
        makeappx = format_tool("makeappx", formats, "msix")
        if makeappx is not None:
            with tempfile.TemporaryDirectory(prefix="mdslens-msix-") as temporary:
                staging = Path(temporary) / base
                stage_windows_msix(bundle, staging, arch)
                run(
                    makeappx, "pack", "/o", "/d", str(staging),
                    "/p", str(DIST / f"{base}.msix"),
                )


def linux_bundle(arch: str) -> Path:
    return ROOT / f"build/linux/{arch}/release/bundle"


def is_linux_system_runtime(name: str) -> bool:
    """Return libraries that must come from the target Linux base system.

    Bundling glibc or its loader makes a package less portable and can break
    NSS, DNS and thread-local runtime behavior. GTK/GLib, settings schemas,
    compiler and display runtimes must also stay aligned with the target
    desktop; mixing an older bundled stack with newer GNOME or Mesa components
    can abort Flutter before its first frame.
    """
    return bool(re.fullmatch(
        r"(?:"
        r"ld-linux[^/]*\.so(?:\..*)?|"
        r"ld-\d+(?:\.\d+)+\.so|"
        r"(?:libc|libdl|libm|libpthread|libresolv|librt|libutil|libanl|"
        r"libnss_[A-Za-z0-9_-]+)(?:\.so(?:\..*)?|-\d+(?:\.\d+)+\.so)|"
        r"(?:libstdc\+\+\.so(?:\..*)?|"
        r"libgcc_s(?:-\d[\d.-]*)?\.so(?:\..*)?)|"
        r"(?:libgtk-3|libgdk-3|libpangocairo-1\.0|libpango-1\.0|"
        r"libpangoft2-1\.0|libharfbuzz|libatk-1\.0|libatk-bridge-2\.0|"
        r"libatspi|libcairo-gobject|libcairo|libgdk_pixbuf-2\.0|"
        r"libgio-2\.0|libgmodule-2\.0|libgobject-2\.0|libglib-2\.0|"
        r"libepoxy|libfontconfig|libsecret-1)\.so(?:\..*)?|"
        r"(?:libX11|libXau|libXdmcp|libXext|libXi|libXcursor|libXfixes|"
        r"libXinerama|libXrandr|libXrender|libXcomposite|libXdamage|"
        r"libxcb(?:-[A-Za-z0-9_-]+)?|libwayland-(?:client|cursor|egl)|"
        r"libxkbcommon(?:-x11)?|libepoxy|libEGL|libGL|libGLX|libOpenGL|"
        r"libGLESv2|libGLdispatch|libglapi|libgbm|libdrm(?:_[A-Za-z0-9_-]+)?)"
        r"\.so(?:\..*)?"
        r")",
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


def parse_linux_needed(output: str) -> list[str]:
    return re.findall(r"\(NEEDED\).*Shared library: \[([^\]]+)\]", output)


def linux_needed_libraries(binary: Path) -> list[str]:
    result = subprocess.run(
        ["readelf", "-d", str(binary)],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        fail(f"Could not inspect direct Linux dependencies for {binary}:\n"
             f"{result.stdout}")
    return parse_linux_needed(result.stdout)


def is_elf(path: Path) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    try:
        with path.open("rb") as stream:
            return stream.read(4) == b"\x7fELF"
    except OSError:
        return False


def copy_linux_portable_dependencies(portable: Path) -> None:
    """Copy application dependencies while retaining the host desktop ABI."""
    library_dir = portable / "lib"
    library_dir.mkdir(parents=True, exist_ok=True)

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
        resolved = {
            dependency.name: dependency
            for dependency in parse_linux_ldd(result.stdout, binary)
        }
        for name in linux_needed_libraries(binary):
            if is_linux_system_runtime(name) or name in known:
                continue
            dependency = resolved.get(name)
            if dependency is None:
                fail(f"Could not resolve {name} required by {binary}")
            destination = library_dir / name
            shutil.copy2(dependency.resolve(), destination)
            known[name] = destination
            queue.append(destination)


def patch_linux_runtime_paths(root: Path) -> None:
    """Make every packaged ELF locate application libraries without a wrapper."""
    patchelf = shutil.which("patchelf")
    if patchelf is None:
        fail("patchelf is required to package Linux applications")
    library_dir = root / "lib"
    for binary in (path for path in root.rglob("*") if is_elf(path)):
        relative_library_dir = os.path.relpath(library_dir, binary.parent)
        runpath = "$ORIGIN"
        if relative_library_dir != ".":
            runpath += "/" + relative_library_dir
        run(patchelf, "--set-rpath", runpath, str(binary))


def stage_linux_portable(
    bundle: Path, portable: Path, version: str, architecture: str
) -> None:
    replace_tree(bundle, portable)
    (portable / ".mdslens-portable.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "product": "com.mdslens.app",
                "version": version,
                "architecture": architecture,
                "executable": "mdslens",
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    executable = portable / "mdslens"
    if not is_elf(executable):
        fail(f"Linux application executable is not ELF: {executable}")
    executable.chmod(0o755)
    applications = portable / "share/applications"
    applications.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "packaging/linux/com.mdslens.app.desktop", applications)
    icons = portable / "share/icons/hicolor/512x512/apps"
    icons.mkdir(parents=True, exist_ok=True)
    shutil.copy2(
        ROOT / "linux/runner/app_icon.png",
        icons / "com.mdslens.app.png",
    )
    mime_packages = portable / "share/mime/packages"
    mime_packages.mkdir(parents=True, exist_ok=True)
    shutil.copy2(
        ROOT / "packaging/linux/com.mdslens.configuration.xml",
        mime_packages,
    )
    copy_linux_portable_dependencies(portable)
    patch_linux_runtime_paths(portable)


def stage_linux_root(bundle: Path, root: Path) -> None:
    app_dir = root / "usr/lib/mdslens"
    replace_tree(bundle, app_dir)
    patch_linux_runtime_paths(app_dir)
    bin_dir = root / "usr/bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    os.symlink("../lib/mdslens/mdslens", bin_dir / "mdslens")
    applications = root / "usr/share/applications"
    applications.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "packaging/linux/com.mdslens.app.desktop", applications)
    icons = root / "usr/share/icons/hicolor/512x512/apps"
    icons.mkdir(parents=True, exist_ok=True)
    shutil.copy2(
        ROOT / "linux/runner/app_icon.png",
        icons / "com.mdslens.app.png",
    )
    mime_packages = root / "usr/share/mime/packages"
    mime_packages.mkdir(parents=True, exist_ok=True)
    shutil.copy2(
        ROOT / "packaging/linux/com.mdslens.configuration.xml",
        mime_packages,
    )


def package_linux_flatpak(
    portable: Path, output: Path, arch: str, formats: set[str]
) -> None:
    flatpak = format_tool("flatpak", formats, "flatpak")
    if flatpak is None:
        return
    flatpak_arch = {"x64": "x86_64", "arm64": "aarch64"}[arch]
    with tempfile.TemporaryDirectory(prefix="mdslens-flatpak-") as temporary:
        root = Path(temporary)
        build_dir = root / "build"
        repo = root / "repo"
        run(
            flatpak, "build-init", f"--arch={flatpak_arch}", str(build_dir),
            "com.mdslens.app", "org.gnome.Sdk", "org.gnome.Platform", "48",
        )
        app_dir = build_dir / "files/lib/mdslens"
        replace_tree(portable, app_dir)
        bin_dir = build_dir / "files/bin"
        bin_dir.mkdir(parents=True)
        os.symlink("../lib/mdslens/mdslens", bin_dir / "mdslens")
        applications = build_dir / "files/share/applications"
        applications.mkdir(parents=True)
        shutil.copy2(
            ROOT / "packaging/linux/com.mdslens.app.desktop", applications
        )
        # Flatpak validates exported icons with the image loaders installed on
        # the build host. A minimal runner may not provide the optional SVG
        # loader even though desktop systems do, so export the canonical PNG
        # asset and keep the bundle independent of that host plugin.
        icons = build_dir / "files/share/icons/hicolor/256x256/apps"
        icons.mkdir(parents=True)
        shutil.copy2(ROOT / "assets/app_icon.png", icons / "com.mdslens.app.png")
        run(
            flatpak, "build-finish",
            "--command=mdslens",
            "--share=network",
            "--share=ipc",
            "--socket=x11",
            "--socket=wayland",
            "--device=dri",
            "--filesystem=home",
            "--talk-name=org.freedesktop.secrets",
            str(build_dir),
        )
        run(flatpak, "build-export", str(repo), str(build_dir), "stable")
        run(
            flatpak, "build-bundle", f"--arch={flatpak_arch}",
            str(repo), str(output), "com.mdslens.app", "stable",
        )
    log(f"Created {output.name}")


def package_linux_snap(
    portable: Path, output: Path, arch: str, version: str, formats: set[str]
) -> None:
    mksquashfs = format_tool("mksquashfs", formats, "snap")
    if mksquashfs is None:
        return
    snap_arch = {"x64": "amd64", "arm64": "arm64"}[arch]
    with tempfile.TemporaryDirectory(prefix="mdslens-snap-") as temporary:
        root = Path(temporary)
        app_dir = root / "lib/mdslens"
        replace_tree(portable, app_dir)
        meta = root / "meta"
        (meta / "gui").mkdir(parents=True)
        shutil.copy2(
            ROOT / "packaging/linux/com.mdslens.app.desktop",
            meta / "gui/com.mdslens.app.desktop",
        )
        shutil.copy2(ROOT / "assets/app_icon.png", meta / "gui/icon.png")
        (meta / "snap.yaml").write_text(
            textwrap.dedent(
                f"""\
                name: mdslens
                version: '{version}'
                summary: MDSplus signal waveform viewer
                description: View and compare signal waveforms from MDSplus experiments.
                architectures:
                  - build-on: [{snap_arch}]
                    run-on: [{snap_arch}]
                grade: stable
                confinement: classic
                apps:
                  mdslens:
                    command: lib/mdslens/mdslens
                    desktop: meta/gui/com.mdslens.app.desktop
                """
            ),
            encoding="utf-8",
        )
        run(
            mksquashfs, str(root), str(output),
            "-noappend", "-comp", "xz", "-all-root",
        )
    log(f"Created {output.name}")


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
    if not (bundle / "mdslens").is_file():
        fail(f"Linux application bundle not found: {bundle}")
    base = f"mdslens-linux-{arch}"

    with tempfile.TemporaryDirectory(prefix="mdslens-linux-") as temporary:
        portable = Path(temporary) / base
        stage_linux_portable(bundle, portable, version, arch)
        if selected(formats, "zip"):
            make_zip(portable, DIST / f"{base}.zip", base)
        if selected(formats, "7z"):
            make_7z(portable, DIST / f"{base}.7z", base, formats)
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
                        "Package: mdslens", f"Version: {version}", f"Architecture: {deb_arch}",
                        "Maintainer: MDSLens Contributors",
                        "Depends: libc6, libegl1, libgles2, libgtk-3-0, "
                        "libsecret-1-0, libstdc++6",
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
                    f"pkgname = mdslens\npkgver = {version}-1\npkgdesc = MDSplus signal waveform viewer\n"
                    f"arch = {rpm_arch}\nsize = {installed_size}\n"
                    "depend = gtk3\ndepend = libglvnd\ndepend = libsecret\n",
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
                    rpmbuild, "-bb", "--define", f"_topdir {top}", "--define", f"mdslens_version {version}",
                    "--define", f"mdslens_arch {rpm_arch}", str(ROOT / "packaging/linux/mdslens.spec"),
                )
                rpms = list((top / "RPMS").rglob("*.rpm"))
                if len(rpms) != 1:
                    fail("rpmbuild did not produce exactly one RPM")
                shutil.copy2(rpms[0], DIST / f"{base}.rpm")

        if selected(formats, "AppImage"):
            appimagetool = format_tool("appimagetool", formats, "AppImage")
            if appimagetool is not None:
                app_dir = Path(temporary) / "MDSLens.AppDir"
                app_bundle = app_dir / "usr/lib/mdslens"
                replace_tree(portable, app_bundle)
                os.symlink("usr/lib/mdslens/mdslens", app_dir / "AppRun")
                shutil.copy2(ROOT / "packaging/linux/com.mdslens.app.desktop", app_dir)
                shutil.copy2(
                    ROOT / "linux/runner/app_icon.png",
                    app_dir / "com.mdslens.app.png",
                )
                environment = dict(os.environ)
                environment["ARCH"] = rpm_arch
                log(f"Running: {appimagetool} {app_dir} {DIST / (base + '.AppImage')}")
                subprocess.run([appimagetool, str(app_dir), str(DIST / f"{base}.AppImage")], check=True, env=environment)
        if selected(formats, "flatpak"):
            package_linux_flatpak(
                portable, DIST / f"{base}.flatpak", arch, formats
            )
        if selected(formats, "snap"):
            package_linux_snap(
                portable, DIST / f"{base}.snap", arch, version, formats
            )


def package_android(formats: set[str], no_build: bool) -> None:
    apk_dir = ROOT / "build/app/outputs/flutter-apk"
    bundle_dir = ROOT / "build/app/outputs/bundle/release"
    if not no_build:
        version = project_version()
        version_arguments = (
            "--build-name",
            version,
            "--build-number",
            str(release_build_number(version)),
        )
        run("flutter", "pub", "get")
        if selected(formats, "apk"):
            run(
                "flutter", "build", "apk", "--release", "--no-pub", "--split-per-abi",
                "--target-platform", "android-arm,android-arm64,android-x64",
                *version_arguments,
            )
            run(
                "flutter", "build", "apk", "--release", "--no-pub",
                "--target-platform", "android-arm,android-arm64,android-x64",
                *version_arguments,
            )
        if selected(formats, "aab") or selected(formats, "apks"):
            run(
                "flutter", "build", "appbundle", "--release", "--no-pub",
                "--target-platform", "android-arm,android-arm64,android-x64",
                *version_arguments,
            )

    if selected(formats, "apk"):
        outputs = {
            "app-armeabi-v7a-release.apk": "mdslens-android-armv7.apk",
            "app-arm64-v8a-release.apk": "mdslens-android-arm64.apk",
            "app-x86_64-release.apk": "mdslens-android-x64.apk",
            "app-release.apk": "mdslens-android-universal.apk",
        }
        for source, destination in outputs.items():
            path = apk_dir / source
            if not path.is_file():
                fail(f"Android APK not found: {path}")
            shutil.copy2(path, DIST / destination)
    if selected(formats, "aab") or selected(formats, "apks"):
        source = bundle_dir / "app-release.aab"
        if not source.is_file():
            fail(f"Android App Bundle not found: {source}")
        if selected(formats, "aab"):
            shutil.copy2(source, DIST / "mdslens-android-universal.aab")
        if selected(formats, "apks"):
            bundletool = find_bundletool()
            if bundletool is None:
                if "all" in formats:
                    log("Skipping apks: BUNDLETOOL_JAR is not configured")
                    return
                fail("Set BUNDLETOOL_JAR to bundletool-all-1.18.3.jar for apks")
            command = [
                "java", "-jar", str(bundletool), "build-apks",
                f"--bundle={source}",
                f"--output={DIST / 'mdslens-android.apks'}",
                "--overwrite",
            ]
            keystore = os.environ.get("MDSLENS_ANDROID_KEYSTORE", "").strip()
            alias = os.environ.get("MDSLENS_ANDROID_KEY_ALIAS", "").strip()
            if keystore and alias:
                store_password = os.environ.get(
                    "MDSLENS_ANDROID_STORE_PASSWORD", ""
                )
                key_password = os.environ.get(
                    "MDSLENS_ANDROID_KEY_PASSWORD", ""
                )
                if not store_password or not key_password:
                    fail(
                        "Android keystore and alias require both signing "
                        "password variables"
                    )
                with tempfile.TemporaryDirectory(
                    prefix="mdslens-bundletool-signing-"
                ) as temporary:
                    password_dir = Path(temporary)
                    store_password_file = password_dir / "store-password"
                    key_password_file = password_dir / "key-password"
                    store_password_file.write_text(
                        store_password, encoding="utf-8"
                    )
                    key_password_file.write_text(
                        key_password, encoding="utf-8"
                    )
                    store_password_file.chmod(0o600)
                    key_password_file.chmod(0o600)
                    command.extend([
                        f"--ks={keystore}",
                        f"--ks-key-alias={alias}",
                        f"--ks-pass=file:{store_password_file}",
                        f"--key-pass=file:{key_password_file}",
                    ])
                    run(*command)
            else:
                run(*command)


def remove_apple_signing_material(bundle: Path) -> None:
    for path in sorted(bundle.rglob("_CodeSignature"), reverse=True):
        if path.is_dir():
            shutil.rmtree(path)
    for path in bundle.rglob("embedded.mobileprovision"):
        path.unlink()
    for path in sorted(bundle.rglob("*")):
        if macos_binary_architectures(path):
            run("codesign", "--remove-signature", str(path), check=False)


def package_ios(formats: set[str], no_build: bool) -> None:
    if host_platform() != "macos":
        fail("iOS/iPadOS packages can only be built on macOS")
    if not no_build:
        flutter_build("ios", "--no-codesign")
    source = ROOT / "build/ios/iphoneos/Runner.app"
    if not source.is_dir():
        fail(f"Unsigned iOS application bundle not found: {source}")

    with tempfile.TemporaryDirectory(prefix="mdslens-ios-") as temporary:
        temporary_root = Path(temporary)
        app = temporary_root / "MDSLens.app"
        replace_tree(source, app)
        remove_apple_signing_material(app)

        # One application supports both iPhone and iPad. Publish aliases so
        # platform-filtered release clients can discover the same binary.
        for platform_name in ("ios", "ipados"):
            base = f"mdslens-{platform_name}-arm64-unsigned"
            if selected(formats, "unsigned-app"):
                replace_tree(app, DIST / f"{base}.app")
                log(f"Created {base}.app")
            if selected(formats, "unsigned-ipa"):
                payload = temporary_root / platform_name / "Payload"
                payload.mkdir(parents=True)
                replace_tree(app, payload / app.name)
                run(
                    "ditto", "-c", "-k", "--keepParent", str(payload),
                    str(DIST / f"{base}.ipa"),
                )
                log(f"Created {base}.ipa")
            if selected(formats, "zip"):
                make_zip(app, DIST / f"{base}.zip", app.name)
            if selected(formats, "7z"):
                make_7z(app, DIST / f"{base}.7z", app.name, formats)
            if selected(formats, "tar.gz"):
                make_tar(app, DIST / f"{base}.tar.gz", app.name, "w:gz")
            if selected(formats, "tar.xz"):
                make_tar(app, DIST / f"{base}.tar.xz", app.name, "w:xz")
            if selected(formats, "tar.bz2"):
                make_tar(app, DIST / f"{base}.tar.bz2", app.name, "w:bz2")
            if selected(formats, "xcarchive"):
                create_xcarchive(
                    app, DIST / f"{base}.xcarchive", name="MDSLens"
                )


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
          ./build_app.py -p ios -p ipados -f unsigned-ipa zip xcarchive
          ./build_app.py -p linux -a arm64 -f deb zip

        SDK paths may be passed explicitly, so modifying the parent shell's
        PATH is optional:
          python build_app.py -p windows -f zip \\
            --flutter-sdk C:\\SDKs\\flutter\\{FLUTTER_BASELINE} \\
            --cargo-home C:\\Users\\me\\.cargo

        A first native build compiles vendored OpenSSL and may take several
        minutes. Apple outputs are unsigned distributions. macOS applications
        carry only the ad-hoc integrity signature required for local launching;
        iOS/iPadOS IPAs must be re-signed by the user before installation.
        HarmonyOS NEXT is reported as unsupported because upstream Flutter
        cannot produce a HAP and this repository has no ArkUI project.
        See docs/BUILDING.md for complete host prerequisites and signing.
        """
    )
    return argparse.ArgumentParser(
        description=(
            "Build and package MDSLens, including its native Rust bridge.\n"
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
        "-a", "--arch", choices=["auto", "x64", "arm64", "universal"], default="auto",
        help=(
            "desktop output architecture; universal is macOS-only and emits "
            "arm64, x64, and universal packages (default: auto)"
        ),
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
            f"MDSLens {project_version()} build script "
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
            package_macos(formats, args.no_build, arch)
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
