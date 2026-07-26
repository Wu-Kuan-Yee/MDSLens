# Download, Install, and First Launch

This guide is for people installing a packaged MdsScope build. To compile or
publish packages, see [BUILDING.md](BUILDING.md).

Only download artifacts from a release or build that you trust. A security
warning is not proof that an application is malicious, but it must not be
bypassed for a file whose source and integrity are uncertain. Do not disable an
operating system's security protections globally just to run MdsScope.

## Choose the Correct Artifact

| Platform | Recommended artifact | Notes |
|---|---|---|
| Windows | Installer EXE/MSI or ZIP | Match x64 or ARM64 to Windows |
| macOS | DMG or ZIP containing the Universal APP | The same bundle supports Intel and Apple silicon |
| Linux | ZIP/AppImage for the CPU architecture | Requires a normal GTK 3 desktop runtime |
| Android | Universal APK, or a matching armv7/arm64/x64 APK | AAB files are for stores and cannot be installed directly |
| iOS/iPadOS | IPA signed for the device, or source installed by Xcode | An unsigned ZIP is verification-only |

## macOS

### Normal installation

1. Open the DMG and drag `MdsScope.app` to `/Applications`. For a ZIP, extract
   the complete app bundle first and then move it to `/Applications`.
2. Open MdsScope from Applications.
3. A Developer ID-signed and Apple-notarized release should open after the
   normal downloaded-application confirmation.

An `.app` is a directory bundle. Do not copy only the executable inside
`MdsScope.app/Contents/MacOS/`.

### If Gatekeeper blocks an ad-hoc-signed local build

Local packages produced without the project's Developer ID variables have an
ad-hoc signature. If you trust the exact download:

1. Try to open MdsScope once so macOS records the block.
2. Open **System Settings > Privacy & Security**.
3. Find the MdsScope message under Security and select **Open Anyway**.
4. Confirm **Open** when macOS asks again.

macOS then records an exception for that application. Apple documents this
per-application recovery in
[Open apps safely on your Mac](https://support.apple.com/102445). A managed Mac
may prohibit the override; contact its administrator instead of disabling
security controls.

For a trusted local development bundle when the graphical override is
unavailable, inspect it before changing anything:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/MdsScope.app
spctl --assess --type execute --verbose=4 /Applications/MdsScope.app
```

If an archive tool damaged or removed the local ad-hoc signature, recreate only
that bundle's ad-hoc signature and remove only that bundle's download
quarantine:

```sh
codesign --force --deep --sign - /Applications/MdsScope.app
xattr -dr com.apple.quarantine /Applications/MdsScope.app
open /Applications/MdsScope.app
```

This is a local self-signing workaround, not Apple notarization and not a safe
method for public distribution. Never use `spctl --master-disable`, disable
System Integrity Protection, or recursively remove quarantine from a broad
directory.

If macOS reports that the application is damaged even after a fresh download,
do not keep overriding the warning. Re-download it, verify that extraction
preserved the complete `.app`, and ask the publisher for a signed/notarized
artifact.

## iOS and iPadOS

### Important signing boundary

A normal, non-jailbroken iPhone or iPad does not run an unsigned application.
There is no supported "bypass signing" switch. The repository's
`mdsscope-ios-arm64-unsigned.zip` and `mdsscope-ipados-arm64-unsigned.zip` are
build-verification artifacts; they cannot be installed on a normal device.

Use one of these supported routes:

- App Store or TestFlight;
- an IPA signed by a development, Ad Hoc, enterprise, or other Apple-supported
  distribution profile that includes or authorizes the device;
- install from source with Xcode using your own Apple Account.

### Self-sign and install from source with Xcode

This is the simplest route for a developer or tester who does not have a
pre-signed IPA:

1. Install the Xcode version required by [BUILDING.md](BUILDING.md), open it
   once, accept the license, and install the requested platform support.
2. Connect the unlocked iPhone or iPad to the Mac. Select **Trust** if either
   side asks whether to trust the other device.
3. In **Xcode > Settings > Accounts**, add your Apple Account.
4. Open `ios/Runner.xcworkspace` in Xcode.
5. Select the **Runner** target, open **Signing & Capabilities**, enable
   **Automatically manage signing**, and select your own Team. A free account
   appears as a Personal Team. If the bundle identifier is already registered
   to another team, replace `com.mdsscope.app` with a unique reverse-domain
   identifier for this local installation.
6. Select the connected device as the run destination and run the Runner
   scheme once. Xcode registers the device and creates a development
   provisioning profile automatically.
7. If prompted on the device, open **Settings > Privacy & Security > Developer
   Mode**, enable it, restart, and confirm after restart.

The equivalent command after Xcode signing is configured is:

```sh
flutter devices
flutter run --release -d <device-id>
```

Apple's current instructions are
[Running your app on simulated or physical devices](https://developer.apple.com/documentation/Xcode/running-your-app-on-simulated-or-physical-devices)
and
[Enabling Developer Mode on a device](https://developer.apple.com/documentation/Xcode/enabling-developer-mode-on-a-device).

A free Personal Team is suitable for personal testing, but Apple currently
limits it to three devices, three installed apps per device, and provisioning
profiles that expire after seven days. Rebuild and reinstall when the profile
expires. See
[Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account).
A paid Apple Developer Program team has different certificate and provisioning
options but still requires a valid profile.

### Install an already signed IPA

An IPA can be installed only when its signature and provisioning profile
authorize the target device or distribution method. Installing someone else's
development-signed IPA does not re-sign it for your device.

For an appropriately signed IPA, connect the device to a Mac and use Apple
Configurator: select the device, choose **Add > Apps > Choose from my Mac**, and
select the IPA. Apple documents this workflow in
[Add apps to a device in Apple Configurator](https://support.apple.com/guide/apple-configurator-mac/cad4cd08c03/mac).

If installation succeeds but launch is refused, check:

- Developer Mode is enabled for a development-signed app;
- the provisioning profile has not expired and includes the device;
- the device can reach Apple's certificate-validation service when required;
- the IPA's bundle identifier and signing entitlements match its profile.

Do not install an untrusted enterprise profile. Organization-managed
distribution should use the organization's documented MDM and trust workflow.

## Android

### Install directly on the device

1. Download the universal APK, or the APK matching the device CPU.
2. Open it from the browser or Files application.
3. On Android 8 or newer, allow **Install unknown apps** for that specific
   browser or file-manager source when Android asks, then confirm installation.
4. Turn that source permission off again if it is no longer needed.

Android documents the per-source permission in
[Alternative distribution](https://developer.android.com/distribute/marketing-tools/alternative-distribution).
Do not try to install an AAB directly.

### Install with ADB

Install Android SDK Platform Tools, enable Developer options and USB debugging,
connect the unlocked device, and accept its computer-authorization prompt:

```sh
adb devices
adb install -r /absolute/path/mdsscope-android-universal.apk
```

When several devices are connected, add `-s <device-id>`. See the official
[ADB installation documentation](https://developer.android.com/tools/adb).

If Android reports `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, the installed copy was
signed with a different key. Prefer installing an update signed with the same
key. Uninstalling the old copy before reinstalling normally erases its local
application data.

## Windows

Use the installer EXE/MSI, or extract the complete portable ZIP before running
`mdsscope.exe`. Do not copy the EXE away from its DLL and `data` directories.

An unsigned or newly signed download may show **Windows protected your PC**:

1. Confirm that the file came from the expected release.
2. Select **More info** and inspect the application and publisher.
3. Select **Run anyway** only when the file is trusted.

For a ZIP or executable marked as downloaded, **Properties > General >
Unblock** may be available. Organizational policy, Windows S mode, or Smart App
Control can prohibit execution without offering an override; use a properly
signed build or contact the administrator rather than disabling protection.
Microsoft explains the reputation behavior in
[SmartScreen reputation for Windows apps](https://learn.microsoft.com/windows/apps/package-and-deploy/smartscreen-reputation).

## Linux

For a portable archive:

```sh
unzip mdsscope-linux-x64.zip
cd mdsscope-linux-x64
chmod +x mdsscope
./mdsscope
```

Use the ARM64 archive on ARM64. The `mdsscope` file is the native executable,
not a launcher script. Keep its adjacent `lib` and `data` directories.

For AppImage:

```sh
chmod +x mdsscope-linux-x64.AppImage
./mdsscope-linux-x64.AppImage
```

DEB, RPM, and Arch packages should be installed with the distribution's package
manager so dependencies and desktop-menu integration are handled normally.
Portable builds still require the system GTK 3, GLib/GIO, libsecret, graphics
stack, and a glibc version compatible with the release baseline. See the Linux
section of [BUILDING.md](BUILDING.md) for the exact boundary and verification
command.

## First-Launch Checklist

After MdsScope opens:

1. Grant the network permissions requested by the operating system.
2. Open the account panel and sign in.
3. Configure and test SSH Tunnel only when the server requires it. Selecting
   **Disable** actively stops using the tunnel.
4. Load a known shot and confirm that waveform data appears.

If the program starts but a feature fails, report the platform, operating
system version, CPU architecture, artifact filename, exact error text, and
whether the artifact was signed/notarized or locally self-signed.
