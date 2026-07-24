# Build, Package, and Sign MdsScope

The supported entry point is `build_app.py`. It builds the Flutter application,
automatically builds the Rust bridge, checks the host toolchain, and packages
the result in `build/dist/`. It uses only the Python standard library; a Python
virtual environment is optional.

## Tested Baseline

| Component | Version / requirement |
|---|---|
| Python | 3.10 or newer |
| Flutter | 3.44.7 stable |
| Rust | rustup; `rust-toolchain.toml` selects 1.92.0 |
| Android | JDK 17+, SDK Platform 36, NDK 27.0.12077973 |
| Windows | Visual Studio 2022 or newer with Desktop development with C++ |
| Apple | A current Xcode supported by Flutter 3.44.7 |
| Linux | Clang, CMake, Ninja, pkg-config, GTK 3 development files |

`pubspec.lock` and `Cargo.lock` are committed. CI selects the Flutter and Rust
versions above. A local Flutter SDK is not downloaded by this repository, so
pass its path to the script or put it on `PATH`.

Before building, run the platform-aware diagnostic:

```sh
python build_app.py --doctor
```

Use `python3` or `./build_app.py` on systems where that is the normal spelling.
Run `python build_app.py --help` for every target, format, option, and example.

## Windows

Install:

- Python 3.10 or newer (CPython, UV-managed Python, and a UV virtual
  environment are all valid);
- Flutter 3.44.7 with Windows desktop support enabled;
- rustup;
- Visual Studio with **Desktop development with C++**, MSVC, CMake tools, and a
  Windows 10/11 SDK;
- Strawberry Perl, which supplies Perl and NASM needed by the vendored OpenSSL
  build. A separate Perl and NASM installation is also valid;
- optionally Inno Setup 6 for `exe`, and WiX Toolset 3 for `msi`.

This exact form does not require activating the virtual environment or editing
the permanent user `PATH`:

```powershell
& C:\Users\gywu\Git\Wu-Kuan-Yee\MdsScope\.venv\Scripts\python.exe `
  .\build_app.py --doctor -p windows -a x64 -f zip `
  --flutter-sdk C:\Users\gywu\Packages\flutter\3.44.7 `
  --cargo-home C:\Users\gywu\.cargo

& C:\Users\gywu\Git\Wu-Kuan-Yee\MdsScope\.venv\Scripts\python.exe `
  .\build_app.py -p windows -a x64 -f zip `
  --flutter-sdk C:\Users\gywu\Packages\flutter\3.44.7 `
  --cargo-home C:\Users\gywu\.cargo
```

After activating the environment and putting Flutter/Cargo on `PATH`, the
short form is:

```powershell
python .\build_app.py -p windows -a x64 -f zip
flutter run --release -d Windows
```

The first cold build compiles vendored OpenSSL and can take several minutes.
Do not interrupt it merely because `nmake` is quiet. If OpenSSL reports an
`openssl-sys` custom-build failure, run `--doctor`: the common causes are
missing Visual Studio C++ tools, Perl, or NASM. After changing those tools, use
`--clean` once.

Windows x64 and ARM64 packages must be built on native x64 and ARM64 hosts.
The portable output is a complete directory archive containing the executable,
Flutter DLLs, plugins, and data; `mdsscope.exe` alone is not portable.

## macOS

Install Flutter, rustup, Python, and Xcode with its command-line tools. Accept
the Xcode license and select the intended Xcode installation. This project uses
Flutter's Swift Package Manager integration and has no CocoaPods `Podfile`.

```sh
python3 build_app.py --doctor -p macos
python3 build_app.py -p macos -f app dmg pkg zip
```

The Rust bridge and Flutter application are built as x64 + arm64 Universal
binaries. Public distribution requires Developer ID signing and notarization;
creating an unsigned local `.app`, ZIP, DMG, or PKG does not provide that trust.

## Linux

For Ubuntu/Debian:

```sh
sudo apt-get update
sudo apt-get install -y python3 clang cmake ninja-build pkg-config \
  libgtk-3-dev libstdc++-12-dev perl nasm
python3 build_app.py --doctor -p linux
python3 build_app.py -p linux -a x64 -f deb zip
```

Additional formats need their native tools: `rpm` needs `rpmbuild`,
`pkg.tar.zst` needs `zstd`, `pkg.tar.xz` needs `xz`, and `AppImage` needs
`appimagetool`. When `-f all` is used, unavailable optional formats are skipped;
when a format is named explicitly, its missing tool is an error.

Build Linux x64 and ARM64 on matching native hosts. Flutter desktop builds are
not general cross-compilation targets.

## Android

Install Flutter, rustup, Python, JDK 17 or newer, Android SDK command-line
tools, SDK Platform 36, and NDK 27.0.12077973. The vendored OpenSSL build also
needs Bash and Perl; on Windows, Git for Windows supplies Bash and Strawberry
Perl supplies Perl/NASM.

Point the script at an SDK and let it install the exact platform and NDK:

```sh
python build_app.py -p android --android-sdk /path/to/Android/Sdk \
  --install-android-sdk-components --doctor
python build_app.py -p android -f apk aab --android-sdk /path/to/Android/Sdk
```

The output includes armv7, arm64, x64, and universal APKs plus an AAB. Without
release signing variables, local packaging uses the local Android debug
keystore and is suitable for testing, not store publication.

For production signing, set:

```sh
export MDSSCOPE_ANDROID_KEYSTORE=/absolute/path/release.jks
export MDSSCOPE_ANDROID_STORE_PASSWORD='...'
export MDSSCOPE_ANDROID_KEY_ALIAS='...'
export MDSSCOPE_ANDROID_KEY_PASSWORD='...'
python build_app.py -p android -f apk aab
```

CI uses corresponding encrypted GitHub secrets; private keys are not stored in
the repository.

## iOS and iPadOS

These targets require macOS and Xcode. An unsigned verification bundle can be
built in one command without an Apple signing identity:

```sh
python3 build_app.py -p ios -p ipados -f unsigned-zip
```

The ZIP cannot be installed on a normal device or submitted to the App Store.
For a signed IPA, select a Team and signing identity for the Runner target in
Xcode, then run:

```sh
python3 build_app.py -p ios -p ipados -f ipa
```

One universal Apple mobile binary supports both iPhone and iPad device
families. The script publishes iOS and iPadOS filename aliases.

## Build-Script Behavior

Useful options:

- `--doctor`: detailed preflight plus `flutter doctor -v` and `rustup show`;
- `--flutter-sdk`, `--cargo-home`, `--android-sdk`: explicit SDK roots;
- `--clean`: clean stale Flutter/CMake output before building;
- `--no-build`: package an already-built release without rebuilding;
- `--skip-preflight`: intended for controlled CI only;
- `--dist`: choose another artifact directory.

The script fails early for impossible host/target combinations and unsupported
formats. It removes Python tracebacks for ordinary tool failures and reports the
failed command, exit code, and next diagnostic action.

Generated Flutter registrants, plugin metadata, native build products, and
package output are ignored by Git. A successful build must leave `git status`
clean when it started clean.

## Verification

```sh
python3 -m py_compile build_app.py
python3 build_app.py --help
python3 -m unittest scripts/test_build_app.py
flutter analyze
flutter test
cargo test --manifest-path rust/Cargo.toml --workspace --locked
python3 scripts/verify_icons.py
```

CI additionally performs real builds for Windows x64/ARM64, Linux x64/ARM64,
macOS Universal, Android armv7/arm64/x64, and unsigned iOS/iPadOS.

## Platform Boundary

HarmonyOS NEXT is not an upstream Flutter target. This repository contains no
ArkUI/ArkTS project, OpenHarmony Flutter fork, HAP signing configuration, or
HarmonyOS Rust toolchain, so neither Flutter nor this script can honestly
produce a working HAP. See `PLATFORM_SUPPORT.md` for the engineering work needed
to add it.
