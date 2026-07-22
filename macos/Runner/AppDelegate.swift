import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  var themeChannel: FlutterMethodChannel?
  var permissionsChannel: FlutterMethodChannel?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(name: "mdsscope/theme", binaryMessenger: controller.engine.binaryMessenger)
    themeChannel = channel
    channel.setMethodCallHandler { [weak self] (call, result) in
      if call.method == "isDark" {
        result(self?.isDarkMode() ?? false)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    let permissionChannel = FlutterMethodChannel(
      name: "mdsscope/permissions",
      binaryMessenger: controller.engine.binaryMessenger
    )
    permissionsChannel = permissionChannel
    permissionChannel.setMethodCallHandler { call, result in
      guard call.method == "openAppSettings" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let localNetworkSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
      )
      let systemSettings = URL(fileURLWithPath: "/System/Applications/System Settings.app")
      if let localNetworkSettings, NSWorkspace.shared.open(localNetworkSettings) {
        result(true)
      } else {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(
          at: systemSettings,
          configuration: configuration
        ) { _, error in
          result(error == nil)
        }
      }
    }
    DistributedNotificationCenter.default.addObserver(
      forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
      object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, let ch = self.themeChannel else { return }
      ch.invokeMethod("themeChanged", arguments: self.isDarkMode())
    }
  }

  func isDarkMode() -> Bool {
    if #available(macOS 10.14, *) {
      let appearance = NSApp.effectiveAppearance
      if let match = appearance.bestMatch(from: [.aqua, .darkAqua]), match == .darkAqua {
        return true
      }
    }
    if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle"), style.caseInsensitiveCompare("dark") == .orderedSame {
      return true
    }
    return false
  }
}
