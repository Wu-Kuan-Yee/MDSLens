# Platforms, Architectures & Package Support

Package support does not imply that an unsigned download can bypass platform
security. See [INSTALLING.md](INSTALLING.md) for installation, first-launch,
Gatekeeper/SmartScreen, Android sideloading, and Apple self-signing procedures.

## Official Flutter Target Scope

With Flutter 3.44 as the baseline, the upstream Flutter deployment targets used by this project are:

| Platform | Architecture | Project Formats | Build Host |
|---|---|---|---|
| Windows | x64, arm64 | Installer EXE, MSI, ZIP, tar.gz/xz/bz2 | Same-arch Windows |
| macOS | x64 + arm64 Universal | APP, DMG, PKG, ZIP, tar.gz/xz/bz2 | macOS |
| Linux | x64, arm64 | One portable runtime per architecture (AppImage, ZIP, tar.gz/xz/bz2); optional native DEB/RPM/pkg.tar packages | Same-arch Linux |
| Android | armv7, arm64, x64 | APK, AAB | Windows/macOS/Linux |
| iOS / iPadOS | arm64 device | IPA | macOS |

Sources: [Flutter supported platforms](https://docs.flutter.dev/reference/supported-platforms) and [multi-platform build host restrictions](https://docs.flutter.dev/platform-integration).

Upstream Flutter does not currently support Windows x86, Linux 32-bit, or iOS 32-bit deployment. The 32-bit Android target is armv7; the current official table no longer lists Android x86 32-bit. An architecture being producible by the Rust compiler does not imply the Flutter UI also supports that architecture.

Flutter 3.44 no longer exposes a Windows `--target-platform` build option.
Windows x64 and ARM64 packages are therefore built on native x64 and ARM64
hosts respectively. CI uses the matching GitHub-hosted runner for each one.

## Icon Coverage

A single source asset at `assets/app_icon.svg` feeds `scripts/generate_icons.sh`, which produces:

- Windows 16/24/32/48/64/128/256-pixel multi-layer ICO for EXE, taskbar, shortcuts, and Start Menu;
- macOS 16–1024-pixel Asset Catalog for APP, Dock, Finder, and application menus;
- iPhone/iPad 20–1024-pixel all required slots, with transparency removed;
- Android legacy, round, adaptive, and Android 13+ monochrome themed icons;
- Linux 512-pixel window icon, scalable SVG, and `com.mdsscope.app.desktop` menu metadata.

`scripts/verify_icons.py` automatically validates all slots and dimensions and runs on every CI commit. It proves resource structure completeness, but "visually identical on every third-party launcher, Linux theme, and vendor ROM" cannot be statically guaranteed by a single project; different systems may recompose icons with their own masks, corner radii, drop shadows, or theme colors. Android follows [Adaptive icons](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive); Apple icons follow [App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons/).

## The Real Boundaries of Static Linking

The entire Flutter application cannot become a single "fully static, zero-runtime-dependency" file on these platforms:

- Windows Flutter apps need `flutter_windows.dll`, plugin DLLs, ICU/data, and AOT data;
- macOS/iOS use the Flutter Framework, Apple system frameworks, Swift/Objective-C runtime, and are constrained by code-signing rules;
- Linux Flutter runners depend on glibc, GTK, and the system graphics stack;
- Android/iOS apps are inherently package formats containing multi-architecture native libraries and resources.

This project statically links OpenSSL, libssh2, and zlib into the Rust bridge where practical; the macOS bridge has no external references beyond Apple system libraries. The desktop Flutter engine and operating system base libraries remain dynamically linked per platform conventions. Claiming they are "fully static" is both inaccurate and often breaks plugins, signing, or system compatibility.

For Linux, the portable archives close the practical gap by bundling every
application-owned dependency while leaving GTK/GLib/GIO, libsecret, settings
schemas, image/input modules, the glibc family/ELF loader, compiler ABI,
X11/Wayland clients, EGL/OpenGL dispatch, and graphics drivers aligned with the
target system. The archives are built against glibc 2.31 and are intended to
run unchanged on newer mainstream distributions of the same architecture with
GTK 3 and libsecret installed. A package cannot promise literally every Linux
system: older glibc, non-glibc systems (such as Alpine/musl), obsolete kernels
and missing/incompatible desktop or graphics runtimes require a different
runtime baseline.

## HarmonyOS NEXT

HarmonyOS NEXT is not an official upstream Flutter deployment target. This repository has no ArkUI/ArkTS project, DevEco Studio project, OpenHarmony Flutter fork integration, HAP signing configuration, or Rust target matching HarmonyOS, and therefore cannot currently produce a real `.hap`/`.app`.

An Android APK cannot be renamed and used as a HarmonyOS NEXT package either. Supporting this platform would require a separate project: selecting and pinning a maintained OpenHarmony Flutter fork or rewriting the frontend in ArkUI, porting plugins such as file picker, settings storage, and URL launcher, providing an OpenHarmony libc/networking/SSH toolchain for the Rust bridge, and completing HAP signing, device testing, and store review. See the [HarmonyOS NEXT developer portal](https://developer.huawei.com/consumer/en/harmonyos/develop/).

## Package Format Trade-offs

More compression extensions do not equal better platform support. The release matrix retains the install formats actually used by each ecosystem plus three common portable compression formats. Snap, Flatpak, Homebrew, Winget, Microsoft Store, Mac App Store, Google Play, and App Store are all independent distribution channels that require accounts, signing, manifests, and review and cannot be "perfectly automated" by a single credential-less script.

## Apple distribution signing

Local macOS packages always receive a consistent ad-hoc signature. Official
Developer ID distribution is enabled through environment variables:

- `MDSSCOPE_MACOS_SIGN_IDENTITY`: Developer ID Application identity.
- `MDSSCOPE_MACOS_INSTALLER_IDENTITY`: Developer ID Installer identity.
- `MDSSCOPE_NOTARY_PROFILE`: `notarytool` keychain profile.

When configured, `build_app.py` enables the hardened runtime, submits the
application and disk/package artifacts to Apple, waits for the notarization
result, and staples the tickets. iOS/iPadOS IPA signing uses the provisioning
team configured in Xcode because Apple requires account-specific profiles.
Unsigned iOS/iPadOS verification bundles cannot be installed on normal devices;
the supported installation routes and Personal Team limits are documented in
[INSTALLING.md](INSTALLING.md).
