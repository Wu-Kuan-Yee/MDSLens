# Download, Install, and First Launch

This guide is for people installing a packaged MDSLens build. To compile or
publish packages, see [BUILDING.md](BUILDING.md).

Only download artifacts from a release or build that you trust. A security
warning is not proof that an application is malicious, but it must not be
bypassed for a file whose source and integrity are uncertain. Do not disable an
operating system's security protections globally just to run MDSLens.

## Choose the Correct Artifact

| Platform | Recommended artifact | Notes |
|---|---|---|
| Windows | Installer EXE/MSI, unsigned MSIX, or ZIP | Match x64 or ARM64 to Windows |
| macOS | Unsigned DMG/ZIP for arm64, x64, or Universal | Universal supports both Intel and Apple silicon |
| Linux | Native package, AppImage, Flatpak, Snap, or ZIP | Match x64 or ARM64 |
| Android | Universal APK, or a matching armv7/arm64/x64 APK | AAB files are for stores and cannot be installed directly |
| iOS/iPadOS | Download the unsigned IPA and re-sign it, or install from source with Xcode | Unsigned IPA cannot be installed directly |
| Web / PWA | Open the deployment's HTTPS URL | No local runtime or manual setup; the browser may offer Install App/Add to Home Screen |

### Where each package is installed

An installer and a portable archive deliberately behave differently. The
release workflow checks these destinations and archive roots before publishing
an artifact:

| Package | Installation destination |
|---|---|
| Windows setup EXE or MSI | `%ProgramFiles%\MDSLens` by default; an update preserves the existing installation directory |
| Windows MSIX/MSIXBundle | A Windows-managed private `WindowsApps` location; do not move its files manually |
| Windows ZIP/7z/tar archives | Wherever the complete `mdslens-windows-<arch>` directory is extracted; these are portable and do not install themselves |
| macOS PKG | Exactly `/Applications/MDSLens.app`; the package is non-relocatable and cannot silently target another copy elsewhere |
| macOS DMG | The user drags `MDSLens.app` to the included `/Applications` shortcut |
| macOS app/ZIP/7z/tar archives | Wherever `MDSLens.app` is extracted or moved; move it to `/Applications` for a normal installation |
| Linux DEB/RPM/Arch package | Program files under `/usr/lib/mdslens`, launcher at `/usr/bin/mdslens`, and desktop integration under `/usr/share` |
| Linux Flatpak or Snap | A package-manager-owned location selected by Flatpak or Snap |
| Linux AppImage or ZIP/7z/tar archives | The downloaded file or extracted directory remains the application; no system installation is performed |
| Android APK | Android-managed private application storage for `com.mdslens.app` |
| Android AAB/APKS | Store or bundletool input; an AAB is not directly installable and APKS installs device-selected split APKs |
| iOS/iPadOS signed IPA | iOS/iPadOS-managed private application storage; public artifacts must first be re-signed |
| Web/PWA | Browser-managed storage and cache; there is no conventional executable installation directory |

Directory bundles such as `.app` and portable distributions must stay intact.
Copying only the inner executable does not create a valid installation.

## In-app updates

Automatic update checks are enabled by default. After startup initialization,
MDSLens checks the latest tagged release in the background. A failed automatic
check is silent; it never interrupts startup with an error dialog. When an
update is available, the prompt offers **View Details**, the platform's direct
update action, and **Not Now**. Disable or re-enable this behavior with
**Settings > Check for updates automatically**.

For an immediate check, open **Settings > About MDSLens > Update**. A failed
manual check is reported because it was explicitly requested. When a newer
tagged release has a machine-readable update manifest, MDSLens offers both
**View Details** and a platform action:

| Platform | Update action |
|---|---|
| Windows | Installer builds update silently in place; marked portable bundles atomically replace the complete directory, verify the restarted process, and roll back on failure |
| macOS | Detects the running `.app`, verifies the matching ZIP, atomically replaces the same bundle, and restarts it |
| Linux | Atomically updates AppImage and marked portable bundles; DEB/RPM/Arch packages update through the native package manager; Flatpak and Snap remain system-managed |
| Android | Downloads and verifies a matching APK, preserves a pending handoff across process recreation, and opens Android's package installer |
| iOS/iPadOS | Opens the release workflow because the unsigned IPA must be re-signed outside the running application |
| Web/PWA | Reloads the page so the browser can activate the latest deployed Web bundle |

Downloads are streamed to a temporary file, can be cancelled, and are not
opened unless the byte count and SHA-256 digest match the release manifest.
Windows updates use the installer's silent mode after verification. The
current executable directory is supplied as the destination instead of
silently reverting to a default path. A writable per-user installation remains
per-user; a protected installation requests normal UAC authorization and
remains per-machine. MSI fallback is explicitly launched through the Windows
elevation prompt. Wizard pages and installer message boxes are suppressed, and
the detached Windows update helper waits for the old process to exit before it
installs and reopens MDSLens from the same path. MDSLens exits only after the
helper confirms that it has taken ownership of the update; if the helper cannot
start, the running application and installed files remain unchanged. The latest
helper and installer diagnostics are retained in
`%LOCALAPPDATA%\MDSLens\updates\latest-update.log` and the adjacent
`.installer.log`. Windows elevation, antivirus policy, and SmartScreen remain
in control; a normal application must not bypass those protections.

ZIP, 7z, and tar Windows portable downloads contain an update-channel marker.
A running marked bundle downloads the canonical ZIP update, extracts and
validates the complete replacement before exiting, then swaps sibling
directories without converting the portable copy into an installed program.
If the portable bundle's parent directory is protected, Windows displays the
standard UAC prompt. The elevated helper re-verifies the archive and performs
only the transactional file replacement; the replacement application is
started separately with the original user's privileges. The helper is launched
through the system Windows PowerShell executable rather than relying on PATH,
and MDSLens allows a 30-second helper-handoff window for Windows startup and
security scanning before reporting that the helper could not take ownership.
The replacement then receives a nonce-bound health handshake from the new
process. The helper waits up to 120 seconds for Flutter and local startup to
report healthy; this is a safety limit, not a fixed delay. If the replacement
exits before that signal, the helper restores and launches the old directory.
After the signal, one owned previous bundle is retained for a 60-second
stability window and is then removed. If the helper or machine stops during
that window, the next launch resumes the cleanup. An unrelated directory with
the same name is never removed.

On macOS, self-update is attempted only when MDSLens is running from a real
`.app` bundle. The downloaded bundle must retain the expected
`com.mdslens.app` identifier and pass strict code-signature validation before
it is staged. Replacement happens at the existing bundle path after the old
process exits, uses a same-directory atomic rename, keeps a rollback copy until
the replacement reports healthy startup, retains it for the same 60-second
stability window, and then removes it. If the bundle's parent directory
is not writable, macOS displays its standard administrator authorization
dialog; cancelling it leaves the running installation unchanged.

A running Linux AppImage follows the same-path replacement and rollback model.
If its directory is protected, MDSLens asks PolicyKit (`pkexec`) to display the
desktop's administrator authorization dialog. If PolicyKit or a graphical
authentication agent is unavailable, the verified package is handed to the
normal system package workflow instead. Privileged file replacement never
launches the graphical application as root: a helper in the signed-in user's
session starts the new AppImage and waits for its nonce-bound health signal;
the privileged helper retains the old file through the same 60-second
stability window. Android's package installer
updates the same application ID and presents any per-source installation
permission it requires. The verified pending APK path survives activity and
process recreation while the user grants permission, but Android still requires
the user to approve installation and may prohibit automatic foreground launch.

MSIX/MSIXBundle, Flatpak, Snap, AAB/APKS, iOS/iPadOS IPA, and Web Gateway
deployments remain owned by their operating system, store, signing, or server
deployment channel. MDSLens checks for releases and presents the appropriate
system or release action, but does not bypass those security boundaries or
claim that a handoff is a completed installation.

Extracted Linux portable bundles are replaced as a complete directory. The
restarted process explicitly changes into the new directory before launch, so
it never inherits a working directory that is about to be retired. The previous
complete bundle is retained beside the installation as
`<directory>.mdslens-previous` while the replacement is checked. The new
process receives a nonce-bound health handshake; after it reports healthy and
remains alive for a conservative 60-second stability window, the updater
removes that owned rollback copy automatically. If the new process exits before
the health signal, the updater restores the old bundle. If it exits during the
stability window, the rollback copy is kept and the next launch resumes cleanup.
Update paths are resolved and checked as sibling directories before any rename
or removal is allowed. Unique staging
and backup names skip every existing file, directory, or symbolic link, are
checked again immediately before the swap, and use exact-target renames that
cannot merge into a pre-existing directory.

The installation identity must also match the installed copy. In particular,
Android updates require every release to use the same release keystore.
Older repository releases made before the persistent Android release key was
configured used independent temporary test identities. Those builds cannot
upgrade to one another or to the stable signing line in place. Export any
configuration you need, uninstall the old test-signed copy once, and install a
current release APK. That uninstall normally removes the application's private
data. Releases on the stable signing line can then update in place.

Current public macOS artifacts remain ad-hoc signed and unnotarized. The updater
therefore verifies the release hash, bundle identifier, and ad-hoc
code-signature integrity itself; it does not claim that the package has a
trusted Developer ID or Apple notarization ticket.

Flatpak and Snap installations deliberately do not show the direct-install
action. Those package systems own their installed files and should deliver the
update through their configured remote or store.

## Runtime Dependency Summary

The packaged application includes the Flutter engine, MDSLens assets and
plugins, and the Rust bridge. OpenSSL, libssh2, and zlib are linked into the
bridge, so users must not install MDSplus, OpenSSL, libssh2, Rust, Flutter, or a
JDK merely to run MDSLens.

The remaining system or optional installation dependencies are:

| Platform | Normally required | May need to be installed manually |
|---|---|---|
| Windows | Supported Windows 10/11 system libraries and graphics driver | Microsoft Visual C++ v14 Redistributable if `VCRUNTIME`/`MSVCP` DLLs are reported missing |
| macOS | A supported macOS release and Apple system frameworks | No runtime package; unsigned releases require a per-app Gatekeeper override or user re-signing |
| Linux | glibc, GTK 3, GLib/GIO, libsecret, C++ runtime, X11/Wayland and EGL/OpenGL/Mesa stack | One of `zenity`, `kdialog`, or `qarma` for Open/Save/Export dialogs; a Secret Service provider for persistent credentials; PolicyKit with a graphical agent for updating a protected AppImage in place |
| Android | A supported Android system | Nothing for direct APK installation; Android SDK Platform Tools only for `adb` installation |
| iOS/iPadOS | A supported iOS/iPadOS system and valid application signature | Xcode for self-signing; Apple Configurator is optional for installing an already signed IPA |
| Web / PWA | A current browser with WebAssembly; JavaScript fallback is included | Nothing on the user's device; the deployment administrator runs the gateway |

These are runtime requirements. Developers compiling packages need the
additional toolchains listed in [BUILDING.md](BUILDING.md).

## Web / PWA

Open the HTTPS address supplied by the deployment administrator. The full
interface runs in the browser and uses native file pickers, drag-and-drop and
downloads for configuration and export workflows. On browsers that expose an
install action, choose **Install App** or **Add to Home Screen** to launch
MDSLens like an installed application; installation is optional.

No Flutter, Rust, MDSplus, SSH client, extension or companion application is
needed on the user's device. Rendering and local editing remain in the
browser. Loading new server data requires the deployment's gateway because
browser security does not allow direct MDSip or SSH sockets.

## macOS

### Normal installation

1. Open the DMG and drag `MDSLens.app` to its **Applications** shortcut. A PKG
   installs the non-relocatable bundle directly as `/Applications/MDSLens.app`.
   For a ZIP, 7z, or tar archive, extract the complete app bundle first and
   then move it to `/Applications`.
2. Open MDSLens from Applications.
3. Repository releases are not Developer ID signed or notarized, so continue
   with the per-application Gatekeeper procedure below.

An `.app` is a directory bundle. Do not copy only the executable inside
`MDSLens.app/Contents/MacOS/`.

### If Gatekeeper blocks an ad-hoc-signed local build

Local packages produced without the project's Developer ID variables have an
ad-hoc signature. If you trust the exact download:

1. Try to open MDSLens once so macOS records the block.
2. Open **System Settings > Privacy & Security**.
3. Find the MDSLens message under Security and select **Open Anyway**.
4. Confirm **Open** when macOS asks again.

macOS then records an exception for that application. Apple documents this
per-application recovery in
[Open apps safely on your Mac](https://support.apple.com/102445). A managed Mac
may prohibit the override; contact its administrator instead of disabling
security controls.

For a trusted local development bundle when the graphical override is
unavailable, inspect it before changing anything:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/MDSLens.app
spctl --assess --type execute --verbose=4 /Applications/MDSLens.app
```

If an archive tool damaged or removed the local ad-hoc signature, recreate only
that bundle's ad-hoc signature and remove only that bundle's download
quarantine:

```sh
codesign --force --deep --sign - /Applications/MDSLens.app
xattr -dr com.apple.quarantine /Applications/MDSLens.app
open /Applications/MDSLens.app
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
There is no supported "bypass signing" switch. The repository publishes
standard `mdslens-ios-arm64-unsigned.ipa` and
`mdslens-ipados-arm64-unsigned.ipa` archives with
`Payload/MDSLens.app`; they are intended for user re-signing but cannot be
installed before that step.

Use one of these supported routes:

- App Store or TestFlight;
- an IPA signed by a development, Ad Hoc, enterprise, or other Apple-supported
  distribution profile that includes or authorizes the device;
- install from source with Xcode using your own Apple Account.

No Flutter, Rust, OpenSSL, MDSplus, or other third-party runtime needs to be
installed on the iPhone or iPad.

### Re-sign a downloaded unsigned IPA

The simplest supported route remains the Xcode source workflow below because
Xcode creates a matching certificate, App ID, provisioning profile and
entitlements together. Users who already have those four items can instead
re-sign the downloaded IPA on macOS:

1. Extract the IPA and confirm that it contains `Payload/MDSLens.app`.
2. Change `CFBundleIdentifier` in the application `Info.plist` if the
   provisioning profile uses a different App ID.
3. Copy the profile to `Payload/MDSLens.app/embedded.mobileprovision`.
4. Decode the profile's `Entitlements` dictionary.
5. Sign every nested framework/dylib first, then sign `MDSLens.app` with the
   decoded entitlements.
6. Recreate the IPA with `Payload` as its top-level directory.

For example, after replacing the profile path and identity with values
belonging to the same Apple team:

```sh
work=$(mktemp -d)
ditto -x -k mdslens-ios-arm64-unsigned.ipa "$work"
cp /absolute/path/profile.mobileprovision \
  "$work/Payload/MDSLens.app/embedded.mobileprovision"
security cms -D -i /absolute/path/profile.mobileprovision > "$work/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' \
  "$work/profile.plist" > "$work/entitlements.plist"

find "$work/Payload/MDSLens.app/Frameworks" \
  \( -name '*.framework' -o -name '*.dylib' \) -print0 |
  while IFS= read -r -d '' item; do
    codesign --force --sign 'Apple Development: Your Name (TEAMID)' "$item"
  done

codesign --force --sign 'Apple Development: Your Name (TEAMID)' \
  --entitlements "$work/entitlements.plist" "$work/Payload/MDSLens.app"
ditto -c -k --keepParent "$work/Payload" mdslens-ios-arm64-resigned.ipa
```

The profile's App ID, certificate/team, device UDID and entitlements must
match. Apple Configurator installs an already validly signed IPA; it does not
repair or create the signature. Third-party sideloading utilities may automate
re-signing, but they are independent tools and are not required or endorsed by
this project.

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
   to another team, replace `com.mdslens.app` with a unique reverse-domain
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

No Flutter, Rust, JDK, Android SDK, OpenSSL, MDSplus, or other third-party
runtime needs to be installed on the Android device. The SDK Platform Tools are
needed on the computer only when using ADB.

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
adb install -r /absolute/path/mdslens-android-universal.apk
```

An APKS archive contains split APKs for all supported device configurations.
Install it with the same pinned bundletool used to create it:

```sh
java -jar bundletool-all-1.18.3.jar install-apks \
  --apks=/absolute/path/mdslens-android.apks
```

When several devices are connected, add `-s <device-id>`. See the official
[ADB installation documentation](https://developer.android.com/tools/adb).

If Android reports `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, the installed copy was
signed with a different key. Prefer installing an update signed with the same
key. Uninstalling the old copy before reinstalling normally erases its local
application data.

## Windows

Use the installer EXE/MSI, or extract the complete portable ZIP before running
`mdslens.exe`. Do not copy the EXE away from its DLL and `data` directories.
The setup EXE and MSI use `%ProgramFiles%\MDSLens` as their clean-install
destination. Portable archives never write there: they run from the directory
chosen during extraction.

The release MSIX and MSIXBundle are unsigned store/sideloading source
packages. Windows will not install them until they are signed with a
certificate whose subject matches the manifest publisher (`CN=MDSLens`) and
that certificate is trusted on the device. Organizations can sign with
SignTool and deploy through their normal certificate/MDM policy. Ordinary
users should prefer the installer EXE, MSI, or portable archive.

Windows normally already provides the required operating-system components. If
startup reports a missing `VCRUNTIME140*.dll` or `MSVCP140*.dll`, install the
latest Microsoft Visual C++ v14 Redistributable matching the package
architecture:

- [x64 Visual C++ Redistributable](https://aka.ms/vc14/vc_redist.x64.exe)
- [ARM64 Visual C++ Redistributable](https://aka.ms/vc14/vc_redist.arm64.exe)

Microsoft requires a Redistributable at least as recent as the MSVC toolset
used to compile an application; see
[Latest supported Visual C++ Redistributable](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist).
Do not download individual runtime DLLs from third-party DLL sites.

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

Linux has the largest manual dependency surface because desktop libraries are
supplied by each distribution rather than embedded as a second, potentially
incompatible desktop stack.

The application itself requires:

- glibc and the standard C/C++ runtime;
- GTK 3, GLib/GIO and their settings schemas, themes, image loaders and input
  modules;
- `libsecret`;
- X11 or Wayland plus a functioning EGL/OpenGL/Mesa or vendor graphics stack.

Open configuration, Save configuration, Export Data, and identity-file Browse
use the Linux implementation of `file_picker`. It searches `PATH`, in order,
for `qarma`, `kdialog`, and `zenity`. At least one must be installed; `zenity`
is the recommended desktop-neutral default. If none is present, these actions
fail with `Couldn't find the executable zenity in the path`.

Persistent passwords and tokens additionally need a running Secret Service
provider, commonly GNOME Keyring, KWallet with Secret Service support, or
KeePassXC with Secret Service integration. Without one, MDSLens keeps
credentials only for the current process and asks for them again after restart.

Typical runtime installations are:

```sh
# Debian and Ubuntu releases that provide libgtk-3-0
sudo apt-get update
sudo apt-get install libgtk-3-0 libsecret-1-0 libegl1 libgl1 \
  gsettings-desktop-schemas zenity gnome-keyring

# Ubuntu releases that provide the time64 GTK package instead
sudo apt-get install libgtk-3-0t64 libsecret-1-0 libegl1 libgl1 \
  gsettings-desktop-schemas zenity gnome-keyring

# Fedora
sudo dnf install gtk3 libsecret libglvnd-egl mesa-dri-drivers \
  gsettings-desktop-schemas zenity gnome-keyring

# CentOS Stream 10 / Enterprise Linux 10, including ARM64
sudo dnf install gtk3 libsecret libepoxy libglvnd-egl \
  gsettings-desktop-schemas zenity gnome-keyring

# Arch Linux
sudo pacman -S gtk3 libsecret libglvnd mesa zenity gnome-keyring
```

Package names can change between distribution releases. A KDE user may install
`kdialog` instead of `zenity`; installing all three dialog tools is unnecessary.
CentOS Stream supplies additional desktop applications such as `zenity`
through AppStream, so that repository must be enabled. A headless server also
needs a real graphical session; installing `zenity` alone does not create a
display server.

For a portable archive:

```sh
unzip mdslens-linux-x64.zip
cd mdslens-linux-x64
chmod +x mdslens
./mdslens
```

Use the ARM64 archive on ARM64. The `mdslens` file is the native executable,
not a launcher script. Keep its adjacent `lib` and `data` directories.

For AppImage:

```sh
chmod +x mdslens-linux-x64.AppImage
./mdslens-linux-x64.AppImage
```

For Flatpak or Snap sideloading:

```sh
flatpak install --user ./mdslens-linux-x64.flatpak
flatpak run com.mdslens.app

sudo snap install ./mdslens-linux-x64.snap --dangerous --classic
mdslens
```

`--dangerous` means the locally downloaded Snap has no Snap Store assertion;
it does not disable the rest of the operating system's security policy.

DEB, RPM, and Arch packages should be installed with the distribution's package
manager so dependencies and desktop-menu integration are handled normally.
They install the application under `/usr/lib/mdslens`, expose
`/usr/bin/mdslens`, and place desktop, icon, and MIME metadata under
`/usr/share`. AppImage and archive builds remain exactly where the user puts
them. Flatpak and Snap intentionally keep their internal path under package
manager control.
Portable builds still require the system GTK 3, GLib/GIO, libsecret, graphics
stack, and a glibc version compatible with the release baseline. See the Linux
section of [BUILDING.md](BUILDING.md) for the exact boundary and verification
command.

## First-Launch Checklist

After MDSLens opens:

1. Grant the network permissions requested by the operating system.
2. Open the account panel and sign in.
3. Configure and test SSH Tunnel only when the server requires it. Selecting
   **Disable** actively stops using the tunnel.
4. Load a known shot and confirm that waveform data appears.

If the program starts but a feature fails, report the platform, operating
system version, CPU architecture, artifact filename, exact error text, and
whether the artifact was signed/notarized or locally self-signed.
