import Flutter
import UIKit
import Darwin
import CoreTelephony

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate,
  UIPencilInteractionDelegate, UIDropInteractionDelegate
{
  private var permissionsChannel: FlutterMethodChannel?
  private var stylusChannel: FlutterMethodChannel?
  private var systemInfoChannel: FlutterMethodChannel?
  private var systemFontsChannel: FlutterMethodChannel?
  private var userDataChannel: FlutterMethodChannel?
  private var openRequestsChannel: FlutterMethodChannel?
  private var dropChannel: FlutterMethodChannel?
  private var pencilInteraction: UIPencilInteraction?
  private var dropInteraction: UIDropInteraction?
  private var pencilUsesEraser = false
  private var cellularDataMonitor: CTCellularData?
  private var networkProbeSession: URLSession?
  private var networkProbeResult: FlutterResult?
  private var networkProbeTimeout: DispatchWorkItem?
  private var cellularStateBeforeProbe: CTCellularDataRestrictedState =
    .restrictedStateUnknown
  private var pendingOpenRequests: [String] = []

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
      name: "mdslens/permissions",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    permissionsChannel = channel
    channel.setMethodCallHandler { call, result in
      if call.method == "requestLocalNetworkAccess" {
        self.triggerLocalNetworkPrivacyAlert()
        result(true)
        return
      }
      if call.method == "prepareNetworkAccess" {
        self.prepareNetworkAccess(call, result: result)
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
      name: "mdslens/stylus",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    stylusChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "getMode" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self?.pencilUsesEraser ?? false)
    }
    systemInfoChannel = FlutterMethodChannel(
      name: "mdslens/system_info",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    systemInfoChannel?.setMethodCallHandler { call, result in
      guard call.method == "get" else {
        result(FlutterMethodNotImplemented)
        return
      }
      #if arch(arm64)
        let architecture = "arm64"
      #elseif arch(x86_64)
        let architecture = "x86_64"
      #else
        let architecture = "unknown"
      #endif
      result([
        "name": UIDevice.current.systemName,
        "version": UIDevice.current.systemVersion,
        "architecture": architecture,
      ])
    }
    systemFontsChannel = FlutterMethodChannel(
      name: "mdslens/system_fonts",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    systemFontsChannel?.setMethodCallHandler { call, result in
      guard call.method == "listFamilies" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(UIFont.familyNames.sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
      })
    }
    userDataChannel = FlutterMethodChannel(
      name: "mdslens/user_data",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    userDataChannel?.setMethodCallHandler { call, result in
      guard call.method == "supportDirectory" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let directory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
      result(directory?.path)
    }
    openRequestsChannel = FlutterMethodChannel(
      name: "mdslens/open_requests",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    openRequestsChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "takePending" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let pending = self?.pendingOpenRequests ?? []
      self?.pendingOpenRequests.removeAll()
      result(pending)
    }
    dropChannel = FlutterMethodChannel(
      name: "desktop_drop",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    DispatchQueue.main.async { [weak self] in
      self?.installPencilInteraction(on: self?.activeRootView)
      self?.installConfigurationDropInteraction(on: self?.activeRootView)
    }
  }

  func queueOpenURL(_ url: URL) {
    let request: String
    if url.isFileURL {
      let scoped = url.startAccessingSecurityScopedResource()
      defer {
        if scoped { url.stopAccessingSecurityScopedResource() }
      }
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mdslens-open", isDirectory: true)
      try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let destination = directory.appendingPathComponent(
        "\(UUID().uuidString)-\(url.lastPathComponent)"
      )
      do {
        try FileManager.default.copyItem(at: url, to: destination)
        request = destination.path
      } catch {
        request = url.path
      }
    } else {
      request = url.absoluteString
    }
    pendingOpenRequests.append(request)
    openRequestsChannel?.invokeMethod("openRequest", arguments: request)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    queueOpenURL(url)
    return true
  }

  private func prepareNetworkAccess(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let arguments = call.arguments as? [String: Any],
      let rawURL = arguments["url"] as? String,
      let url = URL(string: rawURL),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      result("unknown")
      return
    }

    finishNetworkAccessPreparation(with: "unknown")
    let monitor = CTCellularData()
    cellularDataMonitor = monitor
    cellularStateBeforeProbe = monitor.restrictedState
    networkProbeResult = result

    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = true
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 20
    let session = URLSession(configuration: configuration)
    networkProbeSession = session

    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    session.dataTask(with: request) { [weak self, weak monitor] _, response, error in
      DispatchQueue.main.async {
        guard let self, let monitor else { return }
        if monitor.restrictedState == .restricted {
          self.finishDeniedNetworkAccessPreparation()
        } else if monitor.restrictedState == .notRestricted ||
          response != nil || error == nil
        {
          self.finishNetworkAccessPreparation(with: "ready")
        }
      }
    }.resume()

    monitor.cellularDataRestrictionDidUpdateNotifier = {
      [weak self, weak monitor] state in
      DispatchQueue.main.async {
        guard let self, monitor === self.cellularDataMonitor else { return }
        switch state {
        case .restricted:
          self.finishDeniedNetworkAccessPreparation()
        case .notRestricted:
          self.finishNetworkAccessPreparation(with: "ready")
        case .restrictedStateUnknown:
          break
        @unknown default:
          break
        }
      }
    }

    let timeout = DispatchWorkItem { [weak self] in
      self?.finishNetworkAccessPreparation(with: "unknown")
    }
    networkProbeTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
  }

  private func finishDeniedNetworkAccessPreparation() {
    let state = cellularStateBeforeProbe == .restricted
      ? "deniedPreviously"
      : "deniedDuringRequest"
    finishNetworkAccessPreparation(with: state)
  }

  private func finishNetworkAccessPreparation(with state: String) {
    guard let result = networkProbeResult else { return }
    networkProbeResult = nil
    networkProbeTimeout?.cancel()
    networkProbeTimeout = nil
    cellularDataMonitor?.cellularDataRestrictionDidUpdateNotifier = nil
    cellularDataMonitor = nil
    networkProbeSession?.invalidateAndCancel()
    networkProbeSession = nil
    result(state)
  }

  private var activeRootView: UIView? {
    let activeWindow = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }
    return activeWindow?.rootViewController?.view
      ?? window?.rootViewController?.view
  }

  func installPencilInteraction(on rootView: UIView?) {
    guard let rootView else { return }
    if pencilInteraction?.view === rootView {
      pencilInteraction?.isEnabled = true
      return
    }
    if let previousInteraction = pencilInteraction,
      let previousView = previousInteraction.view
    {
      previousView.removeInteraction(previousInteraction)
    }
    let interaction = UIPencilInteraction()
    interaction.delegate = self
    interaction.isEnabled = true
    rootView.addInteraction(interaction)
    pencilInteraction = interaction
  }

  func installConfigurationDropInteraction(on rootView: UIView?) {
    guard let rootView else { return }
    if dropInteraction?.view === rootView {
      return
    }
    if let previousInteraction = dropInteraction,
      let previousView = previousInteraction.view
    {
      previousView.removeInteraction(previousInteraction)
    }
    let interaction = UIDropInteraction(delegate: self)
    rootView.addInteraction(interaction)
    dropInteraction = interaction
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    canHandle session: UIDropSession
  ) -> Bool {
    session.items.count == 1 && session.hasItemsConforming(
      toTypeIdentifiers: ["public.data", "public.content", "public.text"]
    )
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidEnter session: UIDropSession
  ) {
    sendDropLocation("entered", session: session, interaction: interaction)
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidUpdate session: UIDropSession
  ) -> UIDropProposal {
    sendDropLocation("updated", session: session, interaction: interaction)
    return UIDropProposal(operation: .copy)
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidExit session: UIDropSession
  ) {
    dropChannel?.invokeMethod("exited", arguments: nil)
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    performDrop session: UIDropSession
  ) {
    guard let provider = session.items.first?.itemProvider,
      let view = interaction.view
    else { return }
    let location = session.location(in: view)
    let suggestedName = provider.suggestedName ?? "configuration"
    guard let typeIdentifier = provider.registeredTypeIdentifiers.first else {
      dropChannel?.invokeMethod("exited", arguments: nil)
      return
    }
    provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) {
      [weak self] sourceURL, error in
      guard let self, let sourceURL, error == nil else {
        DispatchQueue.main.async {
          self?.dropChannel?.invokeMethod("exited", arguments: nil)
        }
        return
      }
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mdslens-drop-\(UUID().uuidString)", isDirectory: true)
      do {
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true
        )
        let suggestedNameLower = suggestedName.lowercased()
        let destinationName =
          suggestedNameLower.hasSuffix(".toml") ||
          suggestedNameLower.hasSuffix(".webscp")
          ? suggestedName
          : sourceURL.lastPathComponent
        let destination = directory.appendingPathComponent(destinationName)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        DispatchQueue.main.async {
          self.dropChannel?.invokeMethod(
            "entered",
            arguments: [location.x, location.y]
          )
          self.dropChannel?.invokeMethod(
            "performOperation",
            arguments: [destination.path]
          )
        }
      } catch {
        try? FileManager.default.removeItem(at: directory)
        DispatchQueue.main.async {
          self.dropChannel?.invokeMethod("exited", arguments: nil)
        }
      }
    }
  }

  private func sendDropLocation(
    _ method: String,
    session: UIDropSession,
    interaction: UIDropInteraction
  ) {
    guard let view = interaction.view else { return }
    let location = session.location(in: view)
    dropChannel?.invokeMethod(
      method,
      arguments: [location.x, location.y]
    )
  }

  func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
    togglePencilTool()
  }

  @available(iOS 17.5, *)
  func pencilInteraction(
    _ interaction: UIPencilInteraction,
    didReceiveTap tap: UIPencilInteraction.Tap
  ) {
    togglePencilTool()
  }

  @available(iOS 17.5, *)
  func pencilInteraction(
    _ interaction: UIPencilInteraction,
    didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
  ) {
    guard squeeze.phase == .ended else { return }
    togglePencilTool()
  }

  private func togglePencilTool() {
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
