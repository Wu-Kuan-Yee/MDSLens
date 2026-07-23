import Flutter
import UIKit
import Darwin

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate,
  UIPencilInteractionDelegate
{
  private var permissionsChannel: FlutterMethodChannel?
  private var stylusChannel: FlutterMethodChannel?
  private var pencilInteraction: UIPencilInteraction?
  private var pencilUsesEraser = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    _ = mds_free_string
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "mdsscope/permissions",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    permissionsChannel = channel
    channel.setMethodCallHandler { call, result in
      if call.method == "requestLocalNetworkAccess" {
        self.triggerLocalNetworkPrivacyAlert()
        result(true)
        return
      }
      guard call.method == "openAppSettings" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let url = URL(string: UIApplication.openSettingsURLString) else {
        result(false)
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in
        result(opened)
      }
    }

    stylusChannel = FlutterMethodChannel(
      name: "mdsscope/stylus",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    DispatchQueue.main.async { [weak self] in
      self?.installPencilInteraction()
    }
  }

  private func installPencilInteraction() {
    guard pencilInteraction == nil,
      let rootView = window?.rootViewController?.view
    else {
      return
    }
    let interaction = UIPencilInteraction()
    interaction.delegate = self
    rootView.addInteraction(interaction)
    pencilInteraction = interaction
  }

  func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
    let preferredAction = UIPencilInteraction.preferredTapAction
    guard preferredAction == .switchEraser || preferredAction == .switchPrevious
    else {
      return
    }
    pencilUsesEraser.toggle()
    stylusChannel?.invokeMethod(
      "stylusModeChanged",
      arguments: pencilUsesEraser
    )
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
            setIPv6LinkLocalAddressHostPart(of: $0, to: firstHost),
            setIPv6LinkLocalAddressHostPart(of: $0, to: secondHost),
          ]
        }
        .joined()
    )
  }

  private func setIPv6LinkLocalAddressHostPart(
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
}
