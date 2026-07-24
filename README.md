# MdsScope

MdsScope is an MDSplus experimental signal waveform viewer, comparison, and configuration tool rebuilt with Flutter and Rust. The interface targets desktop, tablet, and mobile; a native Rust bridge handles login, MDSplus network access, and SSH tunneling.

## Quick Start

Prerequisites:

- Python 3.10 or newer (the build script uses only the standard library);
- Flutter 3.44.7;
- rustup (the repository auto-selects Rust 1.92.0);
- Platform SDKs: Xcode, Android SDK/NDK, Visual Studio, or Linux GTK development packages.

```sh
python3 build_app.py --doctor
flutter pub get
flutter run
```

Android, iOS, macOS, Windows, and Linux native projects all integrate automatic Rust builds. Standard `flutter run` / `flutter build` requires no manual Cargo invocation or manual copying of the `mds_bridge` library.

## Building Packages

One-command build entry point for the current system:

```sh
./build_app.py
```

The script performs a platform-specific dependency preflight and accepts
`--flutter-sdk`, `--cargo-home`, and `--android-sdk`, so SDK paths do not need
to be configured globally. `python build_app.py --help` contains the complete
format table and examples; [the build guide](docs/BUILDING.md) lists every host
dependency, signing requirement, and troubleshooting step.

Platform and format can be specified:

```sh
# macOS
./build_app.py -p macos -f app dmg pkg zip tar.gz tar.xz tar.bz2

# Android
./build_app.py -p android -f apk aab

# Windows (run on Windows)
python build_app.py -p windows -a x64 -f exe msi zip

# Linux (run on the matching architecture)
./build_app.py -p linux -a x64 -f deb rpm pkg.tar.zst zip

# iOS/iPadOS unsigned verification bundle
./build_app.py -p ios -p ipados -f unsigned-zip

# Signed IPA with Xcode signing configured
./build_app.py -p ios -p ipados -f ipa
```

Output lands in `build/dist/` with filenames following `mdsscope-<platform>-<arch>.<format>`. Pushing a `v*` tag triggers GitHub Actions to build the release matrix on each native system in parallel.

On Windows, the portable distribution must be a complete ZIP/tar archive containing the EXE, Flutter DLLs, plugins, and data directory; copying `mdsscope.exe` alone is not sufficient. On macOS, `.app` is likewise a directory-based application bundle.

## Verification

```sh
flutter analyze
flutter test
cargo test --manifest-path rust/Cargo.toml --workspace --locked
python3 scripts/verify_icons.py
```

The icon check validates the Apple Asset Catalog, iOS opaque background, Android adaptive/round/monochrome icons, Windows multi-size ICO, and Linux desktop icon metadata.

## Documentation

- [Build & Signing Guide](docs/BUILDING.md)
- [Platforms, Architectures & Static Linking Boundaries](docs/PLATFORM_SUPPORT.md)
- [Performance, Dependencies & Size Audit](docs/PERFORMANCE_AUDIT.md)
