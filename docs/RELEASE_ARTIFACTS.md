# Release Artifact Matrix

Pushing a `v*` tag builds the following real application/package formats.
Architecture names describe the executable code inside the package, not merely
the filename.

Public releases should use numeric tags such as `v0.0.1`, `v0.0.2`, or `v0.1.0`.
The displayed application version and Git version are derived automatically
from the tag, and the tag is also propagated into each platform package, so no
source-file version edit is required before releasing.

Every tagged release also contains:

- `update-manifest.toml`, which maps supported update packages to platform,
  architecture, format, byte size, SHA-256 digest, and installation strategy;
- `SHA256SUMS`, covering all uploaded files, including the update manifest.

MDSLens requires an exact platform and architecture match and verifies the
downloaded byte count and SHA-256 digest before asking the operating system to
open an update. Platform package signing remains a separate requirement:
Android releases need one persistent release keystore, and public Windows or
macOS packages should be Authenticode/Developer ID signed when those
credentials become available.

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
directory; `mdslens.exe` alone is not a self-contained artifact. All portable
archive formats include `.mdslens-portable.toml` and update transactionally
from the canonical ZIP asset without changing into an installed application.
The setup EXE and MSI are tested on native Windows runners and must place a
clean installation in `%ProgramFiles%\MDSLens`. MSIX/MSIXBundle uses a
Windows-managed private location. Portable archives extract exactly one
`mdslens-windows-<arch>` directory and remain wherever the user puts it.

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
The PKG payload is non-relocatable and installs exactly
`/Applications/MDSLens.app`. The DMG contains a real **Applications** shortcut.
All portable archives extract exactly one `MDSLens.app` bundle and do not
choose an installation directory for the user.

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

All five archive formats unpack to the same marked portable directory.
Automatic updates use the corresponding `tar.gz` release asset as the
canonical payload regardless of the archive format originally downloaded.
The updater verifies the release manifest and SHA-256, rejects unsafe archive
paths and links, stages the full directory on the destination filesystem,
keeps a rollback copy during restart, and preserves the original path.

Linux x86-32, LoongArch64 and RISC-V are not upstream Flutter Linux desktop
targets. A differently named archive cannot add an absent Flutter engine.
DEB, RPM, and Arch packages install files under `/usr/lib/mdslens`,
`/usr/bin/mdslens`, and `/usr/share`. Flatpak and Snap own their internal
locations. AppImage and archive packages are portable and stay at the path
selected by the user.

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
Android owns the final private installation path. Release validation checks
the `com.mdslens.app` identity, each APK ABI, the universal AAB, and every APK
inside the APKS set rather than assuming a public filesystem destination.

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
iOS/iPadOS owns the final private installation path. Release validation checks
the bundle identifier, arm64 executable, iPhone/iPad device families, absence
of signing material, and every published archive layout.

## Release-time destination validation

The release workflow fails before publication when an installer or archive
does not match its documented semantics. macOS packages are built, expanded,
and mounted on macOS; Windows setup EXE/MSI packages are actually installed to
and removed from a clean native runner; Linux native package manifests and
payload paths are inspected on Linux; mobile packages are inspected with the
native Android and Apple tools. Portable archives are extracted and checked
for one complete, correctly named application root on every desktop platform.

## Web / PWA

For Web hosting servers:

- `mdslens-web-linux-x64.tar.gz`
- `mdslens-web-linux-arm64.tar.gz`

Each archive contains the native Rust Web Gateway and the complete
self-hosted Flutter WebAssembly/PWA assets. It is a server deployment package,
not something each browser user installs. After an administrator deploys it
behind HTTPS, users open the resulting URL and the browser automatically
downloads and caches the application. See
[WEB_DEPLOYMENT.md](WEB_DEPLOYMENT.md).

## Unsupported targets

No HarmonyOS NEXT HAP/APP/HAR/HSP is generated. The repository has no
HarmonyOS application project or upstream Flutter target, and an Android APK
cannot be converted by changing its extension.
