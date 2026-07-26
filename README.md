# MdsScope

MdsScope is an MDSplus experimental signal waveform viewer, comparison, and
configuration tool for desktop, tablet, and mobile devices.

## Features

- Open, edit, save, and restore TOML or WebScope waveform layouts.
- Log in directly or through an SSH tunnel, obtain the latest shot, and load
  multiple panels without blocking the interface.
- Thin, Medium, and Full data modes, including the 0.1 ms EAST Thin path and
  full-resolution detail when zooming.
- Zoom/Move and synchronized Point modes for mouse, touch, trackpad, and stylus.
- Per-signal Tree, Signal, legend, server, color, visibility, and data controls.
- Responsive layouts, configurable fonts and themes, internal web bookmarks,
  shot history management, and native system file/link integration.

Point readouts use the horizontal coordinate name reported by MDSplus. Many
MDSplus dimensions are anonymous arrays rather than named nodes; in that case
MdsScope displays the actual coordinate expression, such as `dim_of(\IP)`,
instead of inventing a variable name.

## Quick Start

Prerequisites:

- Python 3.8 or newer (the build script uses only the standard library);
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
# macOS arm64, x64, and Universal unsigned distributions
./build_app.py -p macos -a universal \
  -f app dmg pkg xcarchive zip 7z tar.gz tar.xz tar.bz2

# Android
./build_app.py -p android -f apk aab apks

# Windows (run on Windows)
python build_app.py -p windows -a x64 -f exe msi msix zip 7z

# Linux (run on the matching architecture)
./build_app.py -p linux -a x64 \
  -f deb rpm pkg.tar.zst AppImage flatpak snap zip 7z

# iOS/iPadOS unsigned packages for user re-signing
./build_app.py -p ios -p ipados \
  -f unsigned-ipa unsigned-app xcarchive zip 7z
```

Output lands in `build/dist/` with filenames following `mdsscope-<platform>-<arch>.<format>`. Pushing a `v*` tag triggers GitHub Actions to build the release matrix on each native system in parallel.
The complete output list and unsupported-target boundary are documented in
[Release Artifact Matrix](docs/RELEASE_ARTIFACTS.md).

On Windows, the portable distribution must be a complete ZIP/tar archive containing the EXE, Flutter DLLs, plugins, and data directory; copying `mdsscope.exe` alone is not sufficient. On macOS, `.app` is likewise a directory-based application bundle.

## Verification

```sh
flutter analyze
flutter test
cargo test --manifest-path rust/Cargo.toml --workspace --locked
python3 scripts/verify_icons.py
```

The icon check validates the Apple Asset Catalog, iOS opaque background, Android adaptive/round/monochrome icons, Windows multi-size ICO, and Linux desktop icon metadata.

## Application Data and Configuration

Desktop builds keep their private state under `~/.mdsscope/`:

```text
~/.mdsscope/
├── settings.json
├── configurations/
└── cache/
```

Open and Save dialogs default to `configurations/`, but users may select any
accessible location. Android, iOS, and iPadOS use the same `.mdsscope` layout
inside the application-support sandbox. MdsScope does not read or overwrite the
separate `~/.config/mdsscope/` data used by other installations. Files in that
legacy directory are intentionally not imported, including when selected
manually; copy a file elsewhere first if it must be inspected independently.

When importing a configuration, its shot is ignored by default unless the user
chooses to apply it. Imported values are initial state: later changes in the
interface, a new shot, or a new Rate take precedence. Passwords and session
tokens are not written to `settings.json`; they use Apple Keychain, Android
Keystore-backed encryption, Windows protected credential storage, or Linux
Secret Service. No plaintext fallback is used when a secure vault is
unavailable.

## Documentation

- [Download, Installation & First Launch](docs/INSTALLING.md)
- [Build & Signing Guide](docs/BUILDING.md)
- [Platforms, Architectures & Static Linking Boundaries](docs/PLATFORM_SUPPORT.md)
- [Performance, Dependencies & Size Audit](docs/PERFORMANCE_AUDIT.md)
