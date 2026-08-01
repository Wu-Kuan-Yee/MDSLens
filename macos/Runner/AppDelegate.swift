import Cocoa
import FlutterMacOS
import Darwin
import Security

@main
class AppDelegate: FlutterAppDelegate {
  var themeChannel: FlutterMethodChannel?
  var permissionsChannel: FlutterMethodChannel?
  var identityFileChannel: FlutterMethodChannel?
  var systemInfoChannel: FlutterMethodChannel?
  var systemFontsChannel: FlutterMethodChannel?
  var openRequestsChannel: FlutterMethodChannel?
  var activeIdentityFileURLs: [URL] = []
  private var pendingOpenRequests: [String] = []

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  // Keep FlutterAppDelegate's applicationShouldTerminate implementation. It
  // forwards the close request to Dart first, allowing AppState.prepareForExit
  // to cancel an in-flight Rust/MDS read before AppKit terminates the process.

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      mainFlutterWindow?.makeKeyAndOrderFront(nil)
    }
    return true
  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    filenames.forEach(queueOpenRequest)
    sender.reply(toOpenOrPrint: .success)
  }

  override func application(
    _ application: NSApplication,
    open urls: [URL]
  ) {
    urls.forEach { queueOpenRequest($0.absoluteString) }
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Finder can launch an unsigned/ad-hoc distributed bundle without making
    // its restored window key.  The process is then alive (and prevents the
    // bundle from being moved to Trash), but it looks as though the double
    // click did nothing.  Always surface the primary window for a normal GUI
    // launch; `open` already performs this activation implicitly.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)

    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(name: "mdslens/theme", binaryMessenger: controller.engine.binaryMessenger)
    themeChannel = channel
    channel.setMethodCallHandler { [weak self] (call, result) in
      if call.method == "isDark" {
        result(self?.isDarkMode() ?? false)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    let systemChannel = FlutterMethodChannel(
      name: "mdslens/system_info",
      binaryMessenger: controller.engine.binaryMessenger
    )
    systemInfoChannel = systemChannel
    systemChannel.setMethodCallHandler { call, result in
      guard call.method == "get" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let version = ProcessInfo.processInfo.operatingSystemVersion
      let versionText = "\(version.majorVersion).\(version.minorVersion)"
        + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
      #if arch(arm64)
        let architecture = "arm64"
      #elseif arch(x86_64)
        let architecture = "x86_64"
      #else
        let architecture = "unknown"
      #endif
      result([
        "name": "macOS",
        "version": versionText,
        "architecture": architecture,
      ])
    }
    let fontsChannel = FlutterMethodChannel(
      name: "mdslens/system_fonts",
      binaryMessenger: controller.engine.binaryMessenger
    )
    systemFontsChannel = fontsChannel
    fontsChannel.setMethodCallHandler { call, result in
      guard call.method == "listFamilies" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(NSFontManager.shared.availableFontFamilies.sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
      })
    }
    let openChannel = FlutterMethodChannel(
      name: "mdslens/open_requests",
      binaryMessenger: controller.engine.binaryMessenger
    )
    openRequestsChannel = openChannel
    openChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "takePending" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let pending = self?.pendingOpenRequests ?? []
      self?.pendingOpenRequests.removeAll()
      result(pending)
    }
    let identityChannel = FlutterMethodChannel(
      name: "mdslens/identity_file_access",
      binaryMessenger: controller.engine.binaryMessenger
    )
    identityFileChannel = identityChannel
    identityChannel.setMethodCallHandler { [weak self] call, result in
      guard
        call.method == "authorizeIdentityFile",
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.authorizeIdentityFile(
        path: path,
        promptIfNeeded: arguments["promptIfNeeded"] as? Bool ?? true,
        result: result
      )
    }
    restoreIdentityFileBookmarks()
    let permissionChannel = FlutterMethodChannel(
      name: "mdslens/permissions",
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

  private func queueOpenRequest(_ request: String) {
    guard !request.isEmpty else { return }
    pendingOpenRequests.append(request)
    openRequestsChannel?.invokeMethod("openRequest", arguments: request)
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

  private var identityFileBookmarks: [String: Data] {
    get {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.mdslens.app.identity-bookmarks",
        kSecAttrAccount as String: "bookmarks",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: CFTypeRef?
      if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
         let data = result as? Data,
         let propertyList = try? PropertyListSerialization.propertyList(
           from: data,
           options: [],
           format: nil
         ),
         let decoded = propertyList as? [String: Data]
      {
        return decoded
      }

      // One-time migration from the former plaintext UserDefaults entry.
      let legacy = UserDefaults.standard.dictionary(
        forKey: "MDSLensIdentityFileBookmarks"
      ) as? [String: Data] ?? [:]
      if !legacy.isEmpty {
        self.identityFileBookmarks = legacy
      }
      UserDefaults.standard.removeObject(
        forKey: "MDSLensIdentityFileBookmarks"
      )
      return legacy
    }
    set {
      guard let data = try? PropertyListSerialization.data(
        fromPropertyList: newValue,
        format: .binary,
        options: 0
      ) else {
        return
      }
      let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.mdslens.app.identity-bookmarks",
        kSecAttrAccount as String: "bookmarks",
      ]
      SecItemDelete(identity as CFDictionary)
      var item = identity
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] =
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      SecItemAdd(item as CFDictionary, nil)
      UserDefaults.standard.removeObject(
        forKey: "MDSLensIdentityFileBookmarks"
      )
    }
  }

  private func restoreIdentityFileBookmarks() {
    for (_, bookmark) in identityFileBookmarks {
      var stale = false
      guard let url = try? URL(
        resolvingBookmarkData: bookmark,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      ) else {
        continue
      }
      _ = beginIdentityFileAccess(url)
      if stale {
        persistIdentityFileBookmark(url, originalPath: url.path)
      }
    }
  }

  private func authorizeIdentityFile(
    path: String,
    promptIfNeeded: Bool,
    result: @escaping FlutterResult
  ) {
    let expandedPath = NSString(string: path).expandingTildeInPath
    let requestedURL = URL(fileURLWithPath: expandedPath).standardizedFileURL

    if let bookmark = identityFileBookmarks[path] {
      var stale = false
      if let bookmarkedURL = try? URL(
        resolvingBookmarkData: bookmark,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      ), beginIdentityFileAccess(bookmarkedURL) {
        if stale {
          persistIdentityFileBookmark(bookmarkedURL, originalPath: path)
        }
        result(bookmarkedURL.path)
        return
      }
    }

    if FileManager.default.isReadableFile(atPath: requestedURL.path) {
      _ = beginIdentityFileAccess(requestedURL)
      persistIdentityFileBookmark(requestedURL, originalPath: path)
      result(requestedURL.path)
      return
    }

    guard promptIfNeeded else {
      result(path)
      return
    }

    let panel = NSOpenPanel()
    panel.title = "Authorize SSH Identity File"
    panel.message = "MDSLens needs permission to read this private key."
    panel.prompt = "Authorize"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = requestedURL.deletingLastPathComponent()
    panel.nameFieldStringValue = requestedURL.lastPathComponent
    panel.begin { [weak self] response in
      guard response == .OK, let selectedURL = panel.url else {
        result(FlutterError(
          code: "IDENTITY_FILE_ACCESS_DENIED",
          message: "Permission to read the SSH identity file was not granted.",
          details: requestedURL.path
        ))
        return
      }
      guard self?.beginIdentityFileAccess(selectedURL) == true else {
        result(FlutterError(
          code: "IDENTITY_FILE_UNREADABLE",
          message: "The selected SSH identity file is not readable.",
          details: selectedURL.path
        ))
        return
      }
      self?.persistIdentityFileBookmark(selectedURL, originalPath: path)
      result(selectedURL.path)
    }
  }

  private func beginIdentityFileAccess(_ url: URL) -> Bool {
    if activeIdentityFileURLs.contains(where: {
      $0.standardizedFileURL.path == url.standardizedFileURL.path
    }) {
      return FileManager.default.isReadableFile(atPath: url.path)
    }
    if url.startAccessingSecurityScopedResource() {
      activeIdentityFileURLs.append(url)
    }
    return FileManager.default.isReadableFile(atPath: url.path)
  }

  private func persistIdentityFileBookmark(_ url: URL, originalPath: String) {
    guard let data = try? url.bookmarkData(
      options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    ) else {
      return
    }
    var bookmarks = identityFileBookmarks
    bookmarks[originalPath] = data
    bookmarks[url.path] = data
    identityFileBookmarks = bookmarks
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
