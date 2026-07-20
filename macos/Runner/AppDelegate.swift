import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  var themeChannel: FlutterMethodChannel?

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
    DistributedNotificationCenter.default.addObserver(
      forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
      object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, let ch = self.themeChannel else { return }
      ch.invokeMethod("themeChanged", arguments: self.isDarkMode())
    }
  }

  func isDarkMode() -> Bool {
    let name = NSApp.effectiveAppearance.name
    if name == .darkAqua || name == .vibrantDark { return true }
    return name.rawValue.lowercased().contains("dark")
  }
}
