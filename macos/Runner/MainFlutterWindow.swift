import Cocoa
import FlutterMacOS

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
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 920), display: true)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
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
