import Cocoa
import FlutterMacOS

class SystemThemeHandler {
  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(name: "mdsscope/theme", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { (call, result) in
      if call.method == "isDark" {
        let dark = NSApp.effectiveAppearance.name == .darkAqua
          || NSApp.effectiveAppearance.name == .vibrantDark
          || NSApp.effectiveAppearance.name.rawValue.lowercased().contains("dark")
        result(dark)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // Listen for theme changes
    DistributedNotificationCenter.default.addObserver(
      forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
      object: nil, queue: .main
    ) { _ in
      let dark = NSApp.effectiveAppearance.name == .darkAqua
        || NSApp.effectiveAppearance.name == .vibrantDark
        || NSApp.effectiveAppearance.name.rawValue.lowercased().contains("dark")
      channel.invokeMethod("themeChanged", arguments: dark)
    }
  }
}
