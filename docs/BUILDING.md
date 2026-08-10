# Build, Package, and Sign MDSLens

The supported entry point is `build_app.py`. It builds the Flutter application,
automatically builds the Rust bridge, checks the host toolchain, and packages
the result in `build/dist/`. It uses only the Python standard library; a Python
virtual environment is optional.

For end-user installation, Gatekeeper/SmartScreen recovery, Android APK
sideloading, and iOS/iPadOS self-signing with a personal Apple Account, see
[INSTALLING.md](INSTALLING.md).

## Tested Baseline

| Component | Version / requirement |
|---|---|
| Python | 3.8 or newer |
| Flutter | 3.44.7 stable |
| Rust | rustup; `rust-toolchain.toml` selects 1.92.0 |
| Android | JDK 17+, SDK Platform 36, NDK 28.2.13676358 |
| Windows | Visual Studio 2022+ with Desktop development with C++ and ATL |
| Apple | A current Xcode supported by Flutter 3.44.7 |
| Linux | Clang, CMake, Ninja, pkg-config, GTK 3 development files |

`pubspec.lock` and `Cargo.lock` are committed. CI selects the Flutter and Rust
versions above. A local Flutter SDK is not downloaded by this repository, so
pass its path to the script or put it on `PATH`.

The table below distinguishes tools required to compile the application from
tools needed only for particular package formats:

| Target | Required build dependencies | Optional packaging/signing dependencies |
|---|---|---|
| Windows | Python, Flutter, rustup, Visual Studio C++/ATL and Windows SDK, Perl, NASM | Inno Setup 6 for installer EXE; WiX Toolset 3 for MSI; MakeAppx for MSIX/MSIXBundle; 7-Zip |
| macOS | Python, Flutter, rustup, Xcode and command-line tools | 7-Zip; users provide their own identity if they want to re-sign the unsigned output |
| Linux | Python, Flutter, rustup, compiler/build tools, GTK 3 and libsecret development files, `patchelf`, Perl, NASM | `dpkg-deb`, `rpmbuild`, `zstd`, `xz`, `appimagetool`, Flatpak, `mksquashfs`, or 7-Zip according to requested formats |
| Android | Python, Flutter, rustup, JDK 17+, Android SDK Platform 36 and NDK 28.2.13676358, Bash, Perl | Android release keystore; bundletool 1.18.3 for APKS; Platform Tools/ADB for device installation |
| iOS/iPadOS | Python, Flutter, rustup, Xcode and command-line tools | 7-Zip; Apple Account/team, certificate and provisioning profile are needed by the user who re-signs for installation |
| Web / PWA | Flutter, rustup, C/C++ build tools, CMake, Perl, NASM and curl | HTTPS reverse proxy and a Linux x64 or ARM64 server for deployment |

Git and network access are normally needed for the first dependency download.
They are not application runtime dependencies.

## Web / PWA

Build the browser application and same-origin gateway together:

```sh
./scripts/build_web.sh
```

The output is a self-contained
`build/dist/mdslens-web-<platform>-<arch>.tar.gz` (tagged releases provide
Linux x64 and ARM64 server packages). The Flutter build includes the
WASM/JavaScript fallback, local CanvasKit/Skwasm and fallback fonts; it does not
fetch rendering resources from a public CDN at runtime. See
[WEB_DEPLOYMENT.md](WEB_DEPLOYMENT.md) for localhost testing, HTTPS reverse
proxy settings, outbound host allowlisting, browser storage and security.

Before building, run the platform-aware diagnostic:

```sh
python build_app.py --doctor
```

Use `python3` or `./build_app.py` on systems where that is the normal spelling.
Run `python build_app.py --help` for every target, format, option, and example.

## Windows

Install:

- Python 3.8 or newer (CPython, UV-managed Python, and a UV virtual
  environment are all valid);
- Flutter 3.44.7 with Windows desktop support enabled;
- rustup;
- Visual Studio with **Desktop development with C++**, MSVC, CMake tools, and a
  Windows 10/11 SDK;
- Strawberry Perl, which supplies Perl and NASM needed by the vendored OpenSSL
  build. A separate Perl and NASM installation is also valid;
- optionally Inno Setup 6 for `exe`, WiX Toolset 3 for `msi`, the Windows SDK
  MakeAppx tool for `msix`, and 7-Zip for `7z`.

This form does not require activating the virtual environment or editing the
permanent user `PATH` (replace the example locations with local SDK paths):

```powershell
& C:\path\to\venv\Scripts\python.exe `
  .\build_app.py --doctor -p windows -a x64 -f zip `
  --flutter-sdk C:\path\to\flutter `
  --cargo-home C:\path\to\.cargo

& C:\path\to\venv\Scripts\python.exe `
  .\build_app.py -p windows -a x64 -f zip `
  --flutter-sdk C:\path\to\flutter `
  --cargo-home C:\path\to\.cargo
```

After activating the environment and putting Flutter/Cargo on `PATH`, the
short form is:

```powershell
python .\build_app.py -p windows -a x64 -f zip
flutter run --release -d windows
```

The first cold build compiles vendored OpenSSL and can take several minutes.
Do not interrupt it merely because `nmake` is quiet. If OpenSSL reports an
`openssl-sys` custom-build failure, run `--doctor`: the common causes are
missing Visual Studio C++ tools, Perl, or NASM. After changing those tools, use
`--clean` once.

Windows x64 and ARM64 packages must be built on native x64 and ARM64 hosts.
The portable output is a complete directory archive containing the executable,
Flutter DLLs, plugins, and data; `mdslens.exe` alone is not portable.

## macOS

Install Flutter, rustup, Python, and Xcode with its command-line tools. Accept
the Xcode license and select the intended Xcode installation. This project uses
Flutter's Swift Package Manager integration and has no CocoaPods `Podfile`.

```sh
python3 build_app.py --doctor -p macos
python3 build_app.py -p macos -a universal \
  -f app dmg pkg xcarchive zip 7z tar.gz tar.xz tar.bz2
```

The universal build is verified to contain x64 and arm64 slices in every
Mach-O component. The packager then produces arm64-only, x64-only, and
Universal variants. Release files use the `-unsigned` suffix. Each application
has only an ad-hoc integrity signature, not a Developer ID identity or Apple
notarization. Users may use **Open Anyway**, remove quarantine for that one
trusted application, or re-sign it with their own identity as described in
[INSTALLING.md](INSTALLING.md).

`.app` and `.xcarchive` are directory bundles. Local builds retain those
directories; the corresponding `.zip`/`.xcarchive.zip` files are what GitHub
Releases can upload.

## Linux

For Ubuntu/Debian:

```sh
sudo apt-get update
sudo apt-get install -y python3 build-essential clang cmake ninja-build \
  pkg-config libgtk-3-dev libsecret-1-dev patchelf perl nasm
python3 build_app.py --doctor -p linux
python3 build_app.py -p linux -a x64 -f deb zip
```

Equivalent common development package sets are:

```sh
# Fedora / CentOS Stream / Enterprise Linux
sudo dnf install gcc-c++ clang cmake ninja-build pkgconf-pkg-config \
  gtk3-devel libsecret-devel patchelf perl nasm

# Arch Linux
sudo pacman -S base-devel clang cmake ninja pkgconf gtk3 libsecret \
  patchelf perl nasm
```

These commands install build dependencies, not the separate runtime dialog
helper used by `file_picker`. Install one of `zenity`, `kdialog`, or `qarma`
when Open/Save/Export must work on the build or target machine; see
[INSTALLING.md](INSTALLING.md#linux).

Additional formats need their native tools: `rpm` needs `rpmbuild`,
`pkg.tar.zst` needs `zstd`, `pkg.tar.xz` needs `xz`, AppImage needs
`appimagetool`, Flatpak needs `flatpak` plus GNOME Platform/SDK 48, Snap needs
`mksquashfs`, and `7z` needs 7-Zip. When `-f all` is used, unavailable optional formats are skipped;
when a format is named explicitly, its missing tool is an error.

Build Linux x64 and ARM64 on matching native hosts. Flutter desktop builds are
not general cross-compilation targets.

ZIP and TAR outputs are portable application bundles, not copies of the raw
Flutter build directory. They carry the Flutter engine, plugins, Rust bridge,
application data and other application-owned libraries. Extract the archive
and run `./mdslens-linux-<arch>/mdslens`. This file is the native ELF
executable itself; packaging writes relocatable `$ORIGIN` runpaths into it and
the bundled libraries, so no launcher script or fixed extraction path is
needed. The AppImage is assembled from the same runtime.

GTK 3, GLib/GIO, libsecret, their settings schemas and image/input modules,
glibc, compiler ABI libraries, the X11/Wayland and EGL/OpenGL stacks, the Linux
kernel and graphics drivers deliberately remain provided by the target system.
Keeping the entire desktop stack together prevents an older bundled GTK from
crashing against newer GNOME settings schemas and prevents older X11/EGL
libraries from being mixed with newer Mesa drivers. Install the normal GTK 3,
libsecret and graphics-runtime packages for the distribution. The file dialog
helper (`zenity`, `kdialog`, or `qarma`) is also intentionally system-provided.
Release
automation tests the same archive on newer Debian/Ubuntu, Fedora and Enterprise
Linux environments. This gives one application bundle per CPU architecture; it
does not make a Linux GUI executable independent of the operating-system
desktop runtime.
Ubuntu and Fedora CI containers perform a real GUI smoke launch with their
native EGL/Mesa software-rendering stack. Enterprise Linux 10 no longer ships
Xvfb in its standard repositories, so its x64 and ARM64 jobs verify the complete
ELF dependency closure and glibc ABI without claiming a headless GUI launch.
The same ABI/dependency/startup check can be run locally with:

```sh
python3 scripts/verify_linux_portable.py \
  build/dist/mdslens-linux-x64.zip --max-glibc 2.31 --launch
```

## Android

Install Flutter, rustup, Python, JDK 17 or newer, Android SDK command-line
tools, SDK Platform 36, and NDK 28.2.13676358. The vendored OpenSSL build also
needs Bash and Perl; on Windows, Git for Windows supplies Bash and Strawberry
Perl supplies Perl/NASM.

Point the script at an SDK and let it install the exact platform and NDK:

```sh
python build_app.py -p android --android-sdk /path/to/Android/Sdk \
  --install-android-sdk-components --doctor
python build_app.py -p android -f apk aab apks --android-sdk /path/to/Android/Sdk
```

Set `BUNDLETOOL_JAR` to the pinned `bundletool-all-1.18.3.jar` when requesting
APKS. The output includes armv7, arm64, x64, and universal APKs, one
multi-architecture AAB, and an APKS archive containing the device-specific
split APK set. AAB is deliberately not duplicated under per-ABI filenames.
Without
release signing variables, local packaging uses the local Android debug
keystore and is suitable for testing, not store publication.

For production signing, set:

```sh
export MDSLENS_ANDROID_KEYSTORE=/absolute/path/release.jks
export MDSLENS_ANDROID_STORE_PASSWORD='...'
export MDSLENS_ANDROID_KEY_ALIAS='...'
export MDSLENS_ANDROID_KEY_PASSWORD='...'
python build_app.py -p android -f apk aab apks
```

CI uses corresponding encrypted GitHub secrets; private keys are not stored in
the repository. Tagged releases fail instead of falling back to a temporary
test key when any signing secret is absent. The public certificate fingerprint
in `android/release-signing-certificate.sha256` is checked against every
generated APK and every APK inside the APKS archive. Keep the same release
keystore for the lifetime of the Android application. Android will reject an
in-place update signed by a different key.

## Release versions and update metadata

For a build made exactly at a numeric `v*` tag, `build_app.py` propagates that
tag into the Flutter build name and every native package version. It derives
the positive build number as:

```text
MAJOR * 1,000,000 + MINOR * 1,000 + PATCH
```

This keeps Android `versionCode` and the equivalent Apple build number
monotonic for normal semantic-version releases. Major versions must remain at
or below 2147, and minor/patch components at or below 999. A non-tagged local
build falls back to the version in `pubspec.yaml`; `MDSLENS_VERSION` can
explicitly override it for a controlled packaging run.

The tagged release workflow runs `scripts/generate_update_manifest.py` after
all native artifacts have been collected. It publishes
`update-manifest.toml` and `SHA256SUMS` beside the packages. Do not hand-edit
the manifest: its names, sizes, and hashes must describe the exact uploaded
files.

## iOS and iPadOS

These targets require macOS and Xcode. All repository release outputs are
unsigned and can be built without an Apple signing identity:

```sh
python3 build_app.py -p ios -p ipados \
  -f unsigned-ipa unsigned-app xcarchive zip 7z tar.gz tar.xz tar.bz2
```

One universal Apple mobile binary supports both iPhone and iPad device
families. The script publishes iOS and iPadOS filename aliases. The unsigned
IPA has the standard `Payload/MDSLens.app` structure, but a normal Apple
mobile device still requires the user to re-sign it with a certificate,
provisioning profile, matching bundle identifier and entitlements. Follow the
self-signing workflow in [INSTALLING.md](INSTALLING.md).

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

## Runtime Data Locations

On Windows, macOS, and Linux, private application state is stored below the
user's home directory:

```text
~/.mdslens/settings.toml
~/.mdslens/configurations/
~/.mdslens/cache/
~/.mdslens/languages/
```

Windows resolves `~` through `USERPROFILE`. Android, iOS, and iPadOS place the
same `.mdslens` structure in the application-support sandbox. Open/Save dialogs
use `configurations/` as their desktop default. MDSLens does not automatically
read settings from `~/.mdsscope/` or `~/.config/mdsscope/`; those legacy
MdsScope directories are also rejected as configuration import locations.

Passwords and session tokens are stored only in the operating system's secure
credential vault: Apple Keychain, Android Keystore-backed encrypted storage,
Windows protected credential storage, or Linux Secret Service. Plaintext
values left by an earlier build are migrated once and erased. macOS
security-scoped bookmarks that authorize an SSH private key are also kept in
Keychain. If a Linux desktop has no usable Secret Service provider, credentials
are kept only for the current process and must be entered again; they are never
written to a plaintext fallback.

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
