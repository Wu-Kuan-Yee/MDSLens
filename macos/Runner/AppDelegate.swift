import Cocoa
import FlutterMacOS
import Darwin

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
      if call.method == "requestLocalNetworkAccess" {
        self.triggerLocalNetworkPrivacyAlert()
        result(true)
        return
      }
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

  // Apple TN3179 recommends connecting UDP sockets to selected link-local
  // addresses. connect() triggers the privacy alert without sending traffic.
  private func triggerLocalNetworkPrivacyAlert() {
    for var address in selectedLinkLocalIPv6Addresses() {
      let socketDescriptor = socket(AF_INET6, SOCK_DGRAM, 0)
      guard socketDescriptor >= 0 else { continue }
      withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
          _ = connect(
            socketDescriptor,
            socketAddress,
            socklen_t(socketAddress.pointee.sa_len)
          )
        }
      }
      close(socketDescriptor)
    }
  }

  private func selectedLinkLocalIPv6Addresses() -> [sockaddr_in6] {
    let firstHost = (0..<8).map { _ in UInt8.random(in: 0...255) }
    let secondHost = (0..<8).map { _ in UInt8.random(in: 0...255) }
    return Array(
      ipv6AddressesOfBroadcastCapableInterfaces()
        .filter(isIPv6AddressLinkLocal)
        .map { address in
          var result = address
          result.sin6_port = UInt16(9).bigEndian
          return result
        }
        .map {
          [
            setIPv6LocalAddressHostPart(of: $0, to: firstHost),
            setIPv6LocalAddressHostPart(of: $0, to: secondHost),
          ]
        }
        .joined()
    )
  }

  private func setIPv6LocalAddressHostPart(
    of address: sockaddr_in6,
    to hostPart: [UInt8]
  ) -> sockaddr_in6 {
    var result = address
    withUnsafeMutableBytes(of: &result.sin6_addr) { buffer in
      buffer[8...].copyBytes(from: hostPart)
    }
    return result
  }

  private func isIPv6AddressLinkLocal(_ address: sockaddr_in6) -> Bool {
    address.sin6_addr.__u6_addr.__u6_addr8.0 == 0xfe &&
      (address.sin6_addr.__u6_addr.__u6_addr8.1 & 0xc0) == 0x80
  }

  private func ipv6AddressesOfBroadcastCapableInterfaces() -> [sockaddr_in6] {
    var addressList: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addressList) == 0, let start = addressList else {
      return []
    }
    defer { freeifaddrs(start) }
    return sequence(first: start, next: { $0.pointee.ifa_next }).compactMap {
      interface -> sockaddr_in6? in
      guard
        (interface.pointee.ifa_flags & UInt32(bitPattern: IFF_BROADCAST)) != 0,
        let socketAddress = interface.pointee.ifa_addr,
        socketAddress.pointee.sa_family == AF_INET6,
        socketAddress.pointee.sa_len >= MemoryLayout<sockaddr_in6>.size
      else {
        return nil
      }
      return UnsafeRawPointer(socketAddress).load(as: sockaddr_in6.self)
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
