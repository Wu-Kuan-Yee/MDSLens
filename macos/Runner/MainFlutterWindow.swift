import Cocoa
import FlutterMacOS
import Metal

class MainFlutterWindow: NSWindow {
  private static let interactionActivationEvents: Set<NSEvent.EventType> = [
    .leftMouseDown,
    .rightMouseDown,
    .otherMouseDown,
    .scrollWheel,
    .beginGesture,
    .magnify,
    .rotate,
    .swipe,
  ]

  override func awakeFromNib() {
    guard let metalDevice = MTLCreateSystemDefaultDevice(),
          metalDevice.makeCommandQueue() != nil else {
      showUnsupportedGraphicsMessage()
      super.awakeFromNib()
      return
    }

    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 920), display: true)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  private func showUnsupportedGraphicsMessage() {
    let message = NSTextField(wrappingLabelWithString:
      "MDSLens could not start its Flutter interface because this Mac does not " +
      "provide a usable Metal graphics device. If macOS is running in a virtual " +
      "machine, enable supported 3D/Metal acceleration or run MDSLens on a " +
      "physical Mac with Metal support."
    )
    message.alignment = .center
    message.font = NSFont.systemFont(ofSize: 16)
    message.maximumNumberOfLines = 0

    let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 360))
    container.addSubview(message)
    message.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      message.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 48),
      message.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -48),
      message.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])

    let controller = NSViewController()
    controller.view = container
    contentViewController = controller
    setFrame(NSRect(x: 0, y: 0, width: 720, height: 360), display: true)
    center()
    NSLog("MDSLens cannot initialize Flutter: no usable Metal device or command queue.")
  }

  override func sendEvent(_ event: NSEvent) {
    // AppKit normally consumes parts of the first trackpad gesture while a
    // window is inactive. Activate before Flutter sees the initiating event
    // so the same gesture can begin Point tracking, pan, or magnification
    // without requiring a separate click first.
    if !isKeyWindow &&
       MainFlutterWindow.interactionActivationEvents.contains(event.type)
    {
      NSApp.activate(ignoringOtherApps: true)
      makeKey()
    }
    super.sendEvent(event)
  }
}
