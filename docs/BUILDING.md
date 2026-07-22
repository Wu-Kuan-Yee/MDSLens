# Build & Release

## Reproducible Build Baseline

The repository pins Flutter 3.44.3, Rust 1.92.0, and Android NDK 27.0.12077973, and commits `pubspec.lock` along with `Cargo.lock`. Rust target architectures are installed automatically by each platform's build scripts; native libraries are auto-generated and bundled by Gradle, Xcode, or CMake.

First, check the local environment:

```sh
flutter doctor -v
rustup show
```

"Clone-and-build in one step" means that on a machine with the official SDKs installed, there is no need to manually compile or copy the bridge library. Xcode, Visual Studio, Android SDK, and similar tools are large and bound by their own license terms, so they cannot reasonably be replicated into this repository.

## Android

Install a test build on a device:

```sh
./build_app.py -p android -f apk
adb install -r build/dist/mdsscope-android-arm64.apk
```

Without formal Android signing configuration, the script falls back to the local debug keystore so the APK can be installed directly. This signature is not suitable for store publication, and a package built on another machine may not install over the previous one.

Before a production release, configure:

```sh
export MDSSCOPE_ANDROID_KEYSTORE=/absolute/path/release.jks
export MDSSCOPE_ANDROID_STORE_PASSWORD='...'
export MDSSCOPE_ANDROID_KEY_ALIAS='...'
export MDSSCOPE_ANDROID_KEY_PASSWORD='...'
./build_app.py -p android -f apk aab
```

GitHub Actions uses the corresponding `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD` secrets. Private keys are never stored in the repository.

The project targets API 36, meeting the current Google Play target API requirements for standard Android apps. See [Google Play target API requirements](https://developer.android.com/google/play/requirements/target-sdk).

## iOS & iPadOS

Builds only on macOS with Xcode installed. First, select your Team and signing identity for the `Runner` target in `ios/Runner.xcworkspace`, then:

```sh
./build_app.py -p ios -p ipados -f ipa
```

A single universal IPA covers both iPhone and iPad device families. The script publishes two identically-content entry points: `mdsscope-ios-arm64.ipa` and `mdsscope-ipados-arm64.ipa`.

CI generates installable IPAs only when the following secrets are set:

- `APPLE_CERTIFICATE_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_PROVISIONING_PROFILE_BASE64`
- `APPLE_KEYCHAIN_PASSWORD`

Without certificates, CI produces verification ZIPs marked `-unsigned`, which cannot be installed on devices or submitted to the store. See [Flutter iOS deployment docs](https://docs.flutter.dev/deployment/ios).

## macOS

```sh
./build_app.py -p macos -f app dmg pkg zip tar.gz tar.xz tar.bz2
```

The Rust bridge is built as a x86_64 + arm64 universal dylib, and the Flutter executable also produces a Universal binary. Public distribution still requires an Apple Developer ID to sign and notarize the `.app`/`.pkg`; ad-hoc or development signatures only verify package structure integrity and do not replace notarization.

## Windows

Requires Visual Studio with the C++ Desktop workload and ARM64 build tools, Inno Setup 6, and WiX Toolset 3.14.

```powershell
python build_app.py -p windows -a x64 -f exe msi zip tar.gz tar.xz tar.bz2
python build_app.py -p windows -a arm64 -f exe msi zip
```

`.exe` is the Inno Setup installer; `.msi` is the WiX installer. The portable distribution is a complete ZIP/tar directory — no misleading "single portable EXE" is produced. Production releases should be signed with a trusted code-signing certificate for both the installer and the main executable. See [Flutter Windows deployment docs](https://docs.flutter.dev/deployment/windows).

## Linux

Example Ubuntu/Debian build dependencies:

```sh
sudo apt-get install libgtk-3-dev ninja-build pkg-config rpm zstd xz-utils
./build_app.py -p linux -a x64 -f deb rpm pkg.tar.zst pkg.tar.xz zip tar.gz tar.xz tar.bz2
```

arm64 packages should be built natively on an arm64 Linux machine. AppImage requires a separate installation of the official `appimagetool`, then explicitly pass `-f AppImage`. Snap, Flatpak, and distribution-specific repository publishing each require their own manifests, reviews, and runtime policies; do not rename a plain tar archive to mimic these formats. See [Flutter Linux deployment docs](https://docs.flutter.dev/deployment/linux).

## Automated Releases

`.github/workflows/release.yml` builds:

- Windows x64 / arm64;
- macOS Universal;
- Linux x64 / arm64;
- Android armv7 / arm64 / x64 / universal APK and AAB;
- iOS/iPadOS IPA when signing secrets are present, otherwise unsigned verification packages only.

Manually triggering the workflow saves Actions artifacts; pushing a `v*` tag also creates or updates the corresponding GitHub Release.

Increment the build number after the `+` in `pubspec.yaml` for each release to satisfy Android and Apple store version-bump requirements.
