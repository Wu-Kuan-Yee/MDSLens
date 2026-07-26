# Release Artifact Matrix

Pushing a `v*` tag builds the following real application/package formats.
Architecture names describe the executable code inside the package, not merely
the filename.

## Windows

For both `x64` and `arm64`:

- `mdsscope-windows-<arch>-setup.exe`
- `mdsscope-windows-<arch>.msi`
- `mdsscope-windows-<arch>.msix` (unsigned)
- `mdsscope-windows-<arch>.zip`
- `mdsscope-windows-<arch>.7z`
- `mdsscope-windows-<arch>.tar.gz`
- `mdsscope-windows-<arch>.tar.xz`
- `mdsscope-windows-<arch>.tar.bz2`

The workflow also combines both MSIX files into the unsigned
`mdsscope-windows.msixbundle`. Windows x86-32 is not an upstream Flutter
desktop target. A portable Windows application is the complete archived
directory; `mdsscope.exe` alone is not a self-contained artifact.

## macOS

For `arm64`, `x64`, and `universal`:

- `mdsscope-macos-<arch>-unsigned.app` (local directory bundle)
- `mdsscope-macos-<arch>-unsigned.dmg`
- `mdsscope-macos-<arch>-unsigned.pkg`
- `mdsscope-macos-<arch>-unsigned.xcarchive` (local directory bundle)
- `mdsscope-macos-<arch>-unsigned.xcarchive.zip`
- `mdsscope-macos-<arch>-unsigned.zip`
- `mdsscope-macos-<arch>-unsigned.7z`
- `mdsscope-macos-<arch>-unsigned.tar.gz`
- `mdsscope-macos-<arch>-unsigned.tar.xz`
- `mdsscope-macos-<arch>-unsigned.tar.bz2`

GitHub Releases accepts files rather than directory bundles, so the `.app` is
carried by the normal compressed archives and `.xcarchive` has an explicit
`.xcarchive.zip` counterpart. The application itself has only an ad-hoc
integrity signature; it is not Developer ID signed or notarized.

## Linux

For both `x64` and `arm64`:

- `mdsscope-linux-<arch>.deb`
- `mdsscope-linux-<arch>.rpm`
- `mdsscope-linux-<arch>.pkg.tar.zst`
- `mdsscope-linux-<arch>.pkg.tar.xz`
- `mdsscope-linux-<arch>.AppImage`
- `mdsscope-linux-<arch>.flatpak`
- `mdsscope-linux-<arch>.snap`
- `mdsscope-linux-<arch>.zip`
- `mdsscope-linux-<arch>.7z`
- `mdsscope-linux-<arch>.tar.gz`
- `mdsscope-linux-<arch>.tar.xz`
- `mdsscope-linux-<arch>.tar.bz2`

Linux x86-32, LoongArch64 and RISC-V are not upstream Flutter Linux desktop
targets. A differently named archive cannot add an absent Flutter engine.

## Android

- `mdsscope-android-armv7.apk`
- `mdsscope-android-arm64.apk`
- `mdsscope-android-x64.apk`
- `mdsscope-android-universal.apk`
- `mdsscope-android-universal.aab`
- `mdsscope-android.apks`

The AAB contains all supported ABIs and is not duplicated under misleading
per-ABI names. The APKS archive is generated from that AAB with bundletool.
MdsScope has no OBB payload, so an XAPK would add no capability and is not
generated.

## iOS and iPadOS

For each `ios` and `ipados` filename alias:

- `mdsscope-<platform>-arm64-unsigned.ipa`
- `mdsscope-<platform>-arm64-unsigned.app` (local directory bundle)
- `mdsscope-<platform>-arm64-unsigned.xcarchive` (local directory bundle)
- `mdsscope-<platform>-arm64-unsigned.xcarchive.zip`
- `mdsscope-<platform>-arm64-unsigned.zip`
- `mdsscope-<platform>-arm64-unsigned.7z`
- `mdsscope-<platform>-arm64-unsigned.tar.gz`
- `mdsscope-<platform>-arm64-unsigned.tar.xz`
- `mdsscope-<platform>-arm64-unsigned.tar.bz2`

The iOS and iPadOS aliases contain the same universal mobile application.
Every IPA has the standard `Payload/MdsScope.app` layout and must be re-signed
by the user before installation.

## Unsupported targets

No HarmonyOS NEXT HAP/APP/HAR/HSP is generated. The repository has no
HarmonyOS application project or upstream Flutter target, and an Android APK
cannot be converted by changing its extension.

