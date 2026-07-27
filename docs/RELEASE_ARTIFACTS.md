# Release Artifact Matrix

Pushing a `v*` tag builds the following real application/package formats.
Architecture names describe the executable code inside the package, not merely
the filename.

Public releases should use numeric tags such as `v0.0.1`, `v0.0.2`, or `v0.1.0`.
The displayed application version and Git version are derived automatically
from the tag, so no source-file version edit is required before releasing.

## Windows

For both `x64` and `arm64`:

- `mdslens-windows-<arch>-setup.exe`
- `mdslens-windows-<arch>.msi`
- `mdslens-windows-<arch>.msix` (unsigned)
- `mdslens-windows-<arch>.zip`
- `mdslens-windows-<arch>.7z`
- `mdslens-windows-<arch>.tar.gz`
- `mdslens-windows-<arch>.tar.xz`
- `mdslens-windows-<arch>.tar.bz2`

The workflow also combines both MSIX files into the unsigned
`mdslens-windows.msixbundle`. Windows x86-32 is not an upstream Flutter
desktop target. A portable Windows application is the complete archived
directory; `mdslens.exe` alone is not a self-contained artifact.

## macOS

For `arm64`, `x64`, and `universal`:

- `mdslens-macos-<arch>-unsigned.app` (local directory bundle)
- `mdslens-macos-<arch>-unsigned.dmg`
- `mdslens-macos-<arch>-unsigned.pkg`
- `mdslens-macos-<arch>-unsigned.xcarchive` (local directory bundle)
- `mdslens-macos-<arch>-unsigned.xcarchive.zip`
- `mdslens-macos-<arch>-unsigned.zip`
- `mdslens-macos-<arch>-unsigned.7z`
- `mdslens-macos-<arch>-unsigned.tar.gz`
- `mdslens-macos-<arch>-unsigned.tar.xz`
- `mdslens-macos-<arch>-unsigned.tar.bz2`

GitHub Releases accepts files rather than directory bundles, so the `.app` is
carried by the normal compressed archives and `.xcarchive` has an explicit
`.xcarchive.zip` counterpart. The application itself has only an ad-hoc
integrity signature; it is not Developer ID signed or notarized.

## Linux

For both `x64` and `arm64`:

- `mdslens-linux-<arch>.deb`
- `mdslens-linux-<arch>.rpm`
- `mdslens-linux-<arch>.pkg.tar.zst`
- `mdslens-linux-<arch>.pkg.tar.xz`
- `mdslens-linux-<arch>.AppImage`
- `mdslens-linux-<arch>.flatpak`
- `mdslens-linux-<arch>.snap`
- `mdslens-linux-<arch>.zip`
- `mdslens-linux-<arch>.7z`
- `mdslens-linux-<arch>.tar.gz`
- `mdslens-linux-<arch>.tar.xz`
- `mdslens-linux-<arch>.tar.bz2`

Linux x86-32, LoongArch64 and RISC-V are not upstream Flutter Linux desktop
targets. A differently named archive cannot add an absent Flutter engine.

## Android

- `mdslens-android-armv7.apk`
- `mdslens-android-arm64.apk`
- `mdslens-android-x64.apk`
- `mdslens-android-universal.apk`
- `mdslens-android-universal.aab`
- `mdslens-android.apks`

The AAB contains all supported ABIs and is not duplicated under misleading
per-ABI names. The APKS archive is generated from that AAB with bundletool.
MDSLens has no OBB payload, so an XAPK would add no capability and is not
generated.

## iOS and iPadOS

For each `ios` and `ipados` filename alias:

- `mdslens-<platform>-arm64-unsigned.ipa`
- `mdslens-<platform>-arm64-unsigned.app` (local directory bundle)
- `mdslens-<platform>-arm64-unsigned.xcarchive` (local directory bundle)
- `mdslens-<platform>-arm64-unsigned.xcarchive.zip`
- `mdslens-<platform>-arm64-unsigned.zip`
- `mdslens-<platform>-arm64-unsigned.7z`
- `mdslens-<platform>-arm64-unsigned.tar.gz`
- `mdslens-<platform>-arm64-unsigned.tar.xz`
- `mdslens-<platform>-arm64-unsigned.tar.bz2`

The iOS and iPadOS aliases contain the same universal mobile application.
Every IPA has the standard `Payload/MDSLens.app` layout and must be re-signed
by the user before installation.

## Unsupported targets

No HarmonyOS NEXT HAP/APP/HAR/HSP is generated. The repository has no
HarmonyOS application project or upstream Flutter target, and an Android APK
cannot be converted by changing its extension.
