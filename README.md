# MDSLens

MDSLens is an MDSplus experimental signal waveform viewer, comparison, and
configuration tool for desktop, tablet, and mobile devices. It is a
cross-platform rewrite of the original
[MdsScope project](https://github.com/wwktz/MdsScope), written with Flutter
and Rust.

Source code, releases, and update checks are hosted in the
[Wu-Kuan-Yee/MDSLens repository](https://github.com/Wu-Kuan-Yee/MDSLens).

## Features

- Open, edit, save, and restore TOML or WebScope waveform layouts, including
  WebScope-compatible export.
- Drop a `.toml` or `.webscp` file directly onto the waveform area, with a
  highlighted valid drop target and confirmation before the layout changes.
- Log in directly or through an SSH tunnel, obtain the latest shot, and load
  multiple panels without blocking the interface.
- Thin, Medium, and Full data modes, including the 0.1 ms EAST Thin path and
  full-resolution detail when zooming.
- Zoom/Move and synchronized Point modes for mouse, touch, trackpad, and stylus.
- Per-signal Tree, Signal, legend, server, color, visibility, and data controls.
- Single- and multi-panel export in text, CSV, TSV, or JSON, using all data,
  the current view, or a custom X range. Each panel is written to an
  independent file; mobile platforms package multi-panel results in one ZIP
  while preserving those separate files.
- Responsive layouts, configurable fonts, icon sizes and themes, internal web
  bookmarks, shot history management, and native system file/link integration.
- Default-on, configurable startup update checks, plus manual checks,
  platform/architecture selection, cancellable streaming downloads, SHA-256
  verification, same-location replacement, and operating-system authorization
  where the platform permits it.
- Installable WebAssembly PWA support. Users open one HTTPS URL; browser-native
  pickers, drag-and-drop and downloads preserve the desktop file workflow,
  while a same-origin Rust gateway provides authenticated MDSip and SSH access
  without exposing API tokens to page JavaScript.

Point readouts use the horizontal coordinate name reported by MDSplus. Many
MDSplus dimensions are anonymous arrays rather than named nodes; in that case
MDSLens displays the actual coordinate expression, such as `dim_of(\IP)`,
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

# Self-contained WebAssembly/PWA plus Linux Web Gateway
./scripts/build_web.sh
```

Output lands in `build/dist/` with filenames following `mdslens-<platform>-<arch>.<format>`. Pushing a `v*` tag triggers GitHub Actions to build the release matrix on each native system in parallel.
Use a numeric release tag such as `v0.0.2`. The application derives
`MDSLens Version` from that tag without the leading `v`, while `Git Version`
is generated as `<version>.r<commits-after-tag>.g<commit>`. Build-only labels
such as `v0.0.1-build.1` are deliberately ignored as public versions.
The same tag is propagated into the native package version and into a
monotonically increasing Android build number, so a newer release is recognized
as an upgrade by the operating system.
The complete output list and unsupported-target boundary are documented in
[Release Artifact Matrix](docs/RELEASE_ARTIFACTS.md).
Web deployment is documented in
[MDSLens Web / PWA Deployment](docs/WEB_DEPLOYMENT.md). For a public UI with
private-network-only Login, SSH and MDS access on any suitable internal server,
use the
[private Gateway deployment](docs/PRIVATE_GATEWAY_DEPLOYMENT.md). A
[Synology-specific example](docs/SYNOLOGY_WEB_DEPLOYMENT.md) is also available.

On Windows, the portable distribution must be a complete ZIP/tar archive containing the EXE, Flutter DLLs, plugins, and data directory; copying `mdslens.exe` alone is not sufficient. On macOS, `.app` is likewise a directory-based application bundle.

## Verification

```sh
flutter analyze
flutter test
cargo test --manifest-path rust/Cargo.toml --workspace --locked
python3 scripts/verify_icons.py
```

The icon check validates the Apple Asset Catalog, iOS opaque background, Android adaptive/round/monochrome icons, Windows multi-size ICO, and Linux desktop icon metadata.

## Application Data and Configuration

Desktop builds keep their private state under `~/.mdslens/`:

```text
~/.mdslens/
├── settings.json
├── configurations/
└── cache/
```

Open and Save dialogs default to `configurations/`, but users may select any
accessible location. Android, iOS, and iPadOS use the same `.mdslens` layout
inside the application-support sandbox. MDSLens does not read or overwrite the
separate `~/.mdsscope/` and `~/.config/mdsscope/` data used by MdsScope installations. Files in that
legacy directory are intentionally not imported, including when selected
manually; copy a file elsewhere first if it must be inspected independently.

When importing a configuration, its shot is ignored by default unless the user
chooses to apply it. Imported values are initial state: later changes in the
interface, a new shot, or a new Rate take precedence. Passwords and session
tokens are not written to `settings.json`; they use Apple Keychain, Android
Keystore-backed encryption, Windows protected credential storage, or Linux
Secret Service. No plaintext fallback is used when a secure vault is
unavailable.

## License

MDSLens is licensed under [GPL-3.0-or-later](LICENSE).

## Documentation

- [Download, Installation & First Launch](docs/INSTALLING.md)
- [Build & Signing Guide](docs/BUILDING.md)
- [Platforms, Architectures & Static Linking Boundaries](docs/PLATFORM_SUPPORT.md)
- [Performance, Dependencies & Size Audit](docs/PERFORMANCE_AUDIT.md)
- [Web / PWA Build and Deployment](docs/WEB_DEPLOYMENT.md)
