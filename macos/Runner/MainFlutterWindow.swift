import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow {
  private var notificationsChannel: FlutterMethodChannel?
  private var windowChannel: FlutterMethodChannel?
  // Held for the window's lifetime: Sparkle's updater stops scheduling checks
  // the moment its controller is deallocated.
  private let sparkleUpdater = SparkleUpdater()

  // MARK: Compact preview window state

  /// Everything the compact (borderless, transparent) preview mode changes on
  /// the window, captured on entry so exit is a restore rather than a guess.
  private struct CompactSavedState {
    let frame: NSRect
    let styleMask: NSWindow.StyleMask
    let minSize: NSSize
    let isOpaque: Bool
    let backgroundColor: NSColor
    let hasShadow: Bool
    let viewBackgroundColor: NSColor?
  }

  /// The aspect contract from the Dart side: the phone frame keeps its ratio,
  /// the chrome around it (margins + control bar) is fixed, so
  /// `height = chromeHeight + (width - chromeWidth) * aspectHeight / aspectWidth`.
  private struct CompactGeometry {
    let aspectWidth: CGFloat
    let aspectHeight: CGFloat
    let chromeWidth: CGFloat
    let chromeHeight: CGFloat
    let minWidth: CGFloat

    init?(args: [String: Any]) {
      guard
        let aw = args["aspectWidth"] as? Double, aw > 0,
        let ah = args["aspectHeight"] as? Double, ah > 0,
        let cw = args["chromeWidth"] as? Double,
        let ch = args["chromeHeight"] as? Double,
        let mw = args["minWidth"] as? Double, mw > 0
      else { return nil }
      aspectWidth = aw
      aspectHeight = ah
      chromeWidth = cw
      chromeHeight = ch
      minWidth = mw
    }

    func height(forWidth width: CGFloat) -> CGFloat {
      chromeHeight + (width - chromeWidth) * aspectHeight / aspectWidth
    }

    func width(forHeight height: CGFloat) -> CGFloat {
      chromeWidth + (height - chromeHeight) * aspectWidth / aspectHeight
    }

    var minSize: NSSize {
      NSSize(width: minWidth, height: height(forWidth: minWidth))
    }
  }

  private var compactSaved: CompactSavedState?
  private var compactGeometry: CompactGeometry?
  private var compactResizeMonitor: Any?
  private var compactDragMonitor: Any?

  /// Borderless windows refuse key/main status by default, which would leave
  /// the compact preview unable to take keyboard input. Always-true is what a
  /// titled window answers anyway.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  /// AppKit stops a dragged window's top at the menu bar — but the compact
  /// window's top `kCompactFrameMargin` is transparent shadow room, so the
  /// *visible* frame stopped that far short of the top of the screen. While
  /// compact, allow exactly that margin past the visible top: the frame's
  /// bezel can reach the screen edge, and no further.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    guard compactSaved != nil, let geometry = compactGeometry else {
      return super.constrainFrameRect(frameRect, to: screen)
    }
    var rect = frameRect
    let margin = geometry.chromeWidth / 2
    if let visible = (screen ?? self.screen)?.visibleFrame {
      let maxTop = visible.maxY + margin
      if rect.maxY > maxTop {
        rect.origin.y = maxTop - rect.height
      }
    }
    return rect
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController

    // Fits a 13" display with dock/menu bar; keeps agent + preview usable.
    let minWidth: CGFloat = 1024
    let minHeight: CGFloat = 720
    self.minSize = NSSize(width: minWidth, height: minHeight)

    var frame = windowFrame
    if frame.size.width < minWidth {
      frame.size.width = minWidth
    }
    if frame.size.height < minHeight {
      frame.size.height = minHeight
    }
    self.setFrame(frame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerNotificationsChannel(flutterViewController)
    registerWindowChannel(flutterViewController)
    sparkleUpdater.start(flutterViewController)

    super.awakeFromNib()
  }

  // MARK: - Compact preview window

  private func registerWindowChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "dev.serverpod.appstudio/window",
      binaryMessenger: controller.engine.binaryMessenger
    )
    windowChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "enterCompact":
        self.enterCompact(args: args)
        result(nil)
      case "updateCompactGeometry":
        self.updateCompactGeometry(args: args)
        result(nil)
      case "exitCompact":
        self.exitCompact()
        result(nil)
      case "startDrag":
        self.startCompactDrag()
        result(nil)
      case "startResize":
        self.startCompactResize(corner: args["corner"] as? String ?? "bottomRight")
        result(nil)
      case "showResizeCursor":
        self.showResizeCursor(corner: args["corner"] as? String ?? "bottomRight")
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private var flutterViewController: FlutterViewController? {
    contentViewController as? FlutterViewController
  }

  /// The frame scale the current window implies under [geometry] — 1.0 means
  /// the phone frame is at its natural logical size.
  private func compactScale(of geometry: CompactGeometry) -> CGFloat {
    (frame.height - geometry.chromeHeight) / geometry.aspectHeight
  }

  private func enterCompact(args: [String: Any]) {
    guard let geometry = CompactGeometry(args: args) else { return }
    // Re-entry (should not happen — Dart exits before re-entering — but be
    // safe) just re-applies geometry at the current scale.
    if compactSaved != nil {
      let scale = compactGeometry.map(compactScale(of:))
      compactGeometry = geometry
      applyCompactGeometry(scale: scale)
      return
    }

    compactSaved = CompactSavedState(
      frame: frame,
      styleMask: styleMask,
      minSize: minSize,
      isOpaque: isOpaque,
      backgroundColor: backgroundColor,
      hasShadow: hasShadow,
      viewBackgroundColor: flutterViewController?.backgroundColor
    )
    compactGeometry = geometry

    styleMask = .borderless
    isOpaque = false
    backgroundColor = .clear
    // The phone frame paints its own drop shadow; the window shadow would
    // draw a second one hugging whatever pixels happen to be opaque.
    hasShadow = false
    // Both layers must be clear or the desktop never shows through — see the
    // transparency recipe in FlutterViewController.h.
    flutterViewController?.backgroundColor = .clear
    minSize = geometry.minSize

    let visible = (screen ?? NSScreen.main)?.visibleFrame ?? frame
    let targetHeight = min(frame.height, visible.height * 0.8)
    applyCompactGeometry(
      scale: (targetHeight - geometry.chromeHeight) / geometry.aspectHeight
    )
    // The style-mask change can drop key status.
    makeKeyAndOrderFront(nil)
  }

  /// Orientation flip while compact. The *frame scale* carries over, not the
  /// window height — carrying the height turned a tall portrait window into a
  /// landscape one wider than the screen, with its resize corners off it.
  private func updateCompactGeometry(args: [String: Any]) {
    guard let geometry = CompactGeometry(args: args) else { return }
    let scale = compactSaved != nil ? compactGeometry.map(compactScale(of:)) : nil
    compactGeometry = geometry
    guard compactSaved != nil else { return }
    minSize = geometry.minSize
    applyCompactGeometry(scale: scale)
  }

  /// Re-derives the frame from the current geometry at [scale] (falling back
  /// to the window's implied scale), clamped so the whole window — corners
  /// included — stays on the visible screen, centered where it was.
  private func applyCompactGeometry(scale: CGFloat?) {
    guard let geometry = compactGeometry else { return }
    let visible = (screen ?? NSScreen.main)?.visibleFrame ?? frame

    var target = scale ?? compactScale(of: geometry)
    let minScale =
      (geometry.minWidth - geometry.chromeWidth) / geometry.aspectWidth
    let maxScale = min(
      (visible.width - geometry.chromeWidth) / geometry.aspectWidth,
      (visible.height - geometry.chromeHeight) / geometry.aspectHeight
    )
    target = max(minScale, min(target, maxScale))

    let targetWidth = geometry.chromeWidth + target * geometry.aspectWidth
    let targetHeight = geometry.chromeHeight + target * geometry.aspectHeight
    let center = NSPoint(x: frame.midX, y: frame.midY)
    let targetFrame = clampToVisible(
      NSRect(
        x: center.x - targetWidth / 2,
        y: center.y - targetHeight / 2,
        width: targetWidth,
        height: targetHeight
      ),
      visible: visible
    )
    setFrame(targetFrame, display: true)
  }

  private func exitCompact() {
    endCompactResizeTracking()
    endCompactDragTracking()
    guard let saved = compactSaved else { return }
    compactSaved = nil
    compactGeometry = nil

    styleMask = saved.styleMask
    isOpaque = saved.isOpaque
    backgroundColor = saved.backgroundColor
    hasShadow = saved.hasShadow
    flutterViewController?.backgroundColor = saved.viewBackgroundColor
    minSize = saved.minSize
    setFrame(saved.frame, display: true)
    makeKeyAndOrderFront(nil)
  }

  /// Moves the window with a local event monitor, mirroring the resize.
  ///
  /// Not `performDrag(with:)`: that hands the move to the window server,
  /// which enforces the stop-at-the-menu-bar rule itself and never consults
  /// `constrainFrameRect` — so the transparent top margin kept the bezel from
  /// ever reaching the top of the screen, override or not. Tracking the move
  /// here, `setFrameOrigin` is unconstrained and the only clamp is our own:
  /// the bezel may touch the visible top, and the margin alone goes past it.
  private func startCompactDrag() {
    guard let geometry = compactGeometry else { return }
    endCompactDragTracking()

    let startOrigin = frame.origin
    let startMouse = NSEvent.mouseLocation
    let windowHeight = frame.height
    let margin = geometry.chromeWidth / 2

    compactDragMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDragged, .leftMouseUp]
    ) { [weak self] event in
      guard let self else { return event }
      if event.type == .leftMouseUp {
        self.endCompactDragTracking()
        return event
      }
      let mouse = NSEvent.mouseLocation
      var origin = NSPoint(
        x: startOrigin.x + (mouse.x - startMouse.x),
        y: startOrigin.y + (mouse.y - startMouse.y)
      )
      // Clamp against the display the mouse is on, so a drag onto a second
      // screen honours that screen's top.
      let screenUnderMouse = NSScreen.screens.first {
        NSMouseInRect(mouse, $0.frame, false)
      }
      if let visible = (screenUnderMouse ?? self.screen)?.visibleFrame {
        let maxTop = visible.maxY + margin
        if origin.y + windowHeight > maxTop {
          origin.y = maxTop - windowHeight
        }
      }
      self.setFrameOrigin(origin)
      // Swallow the drag: Flutter already handed this gesture over.
      return nil
    }
  }

  private func endCompactDragTracking() {
    if let monitor = compactDragMonitor {
      NSEvent.removeMonitor(monitor)
      compactDragMonitor = nil
    }
  }

  /// Aspect-locked resize from one corner, tracked with a local event monitor
  /// until the mouse is released. The corner names arrive in UI (top-left
  /// origin) terms; screen coordinates are bottom-left, so "top" fixes the
  /// screen-bottom edge and vice versa.
  ///
  /// The new width is the start width plus the mouse's travel — never the
  /// mouse-to-anchor distance. The grab lands somewhere inside the corner
  /// handle, tens of points in from the window edge, and anchor-distance
  /// sizing snapped the window smaller by exactly that inset on the first
  /// drag event.
  private func startCompactResize(corner: String) {
    guard let geometry = compactGeometry else { return }
    endCompactResizeTracking()

    let startFrame = frame
    let startMouse = NSEvent.mouseLocation
    let isLeft = corner.lowercased().contains("left")
    let isTop = corner.hasPrefix("top")
    let anchorX = isLeft ? startFrame.maxX : startFrame.minX
    let visible = (screen ?? NSScreen.main)?.visibleFrame ?? startFrame
    let maxWidth = geometry.chromeWidth + min(
      (visible.width - geometry.chromeWidth) / geometry.aspectWidth,
      (visible.height - geometry.chromeHeight) / geometry.aspectHeight
    ) * geometry.aspectWidth

    compactResizeMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDragged, .leftMouseUp]
    ) { [weak self] event in
      guard let self else { return event }
      if event.type == .leftMouseUp {
        self.endCompactResizeTracking()
        return event
      }
      let mouse = NSEvent.mouseLocation
      let travel = isLeft ? startMouse.x - mouse.x : mouse.x - startMouse.x
      var newWidth = startFrame.width + travel
      newWidth = min(max(geometry.minWidth, newWidth), maxWidth)
      let newHeight = geometry.height(forWidth: newWidth)
      let x = isLeft ? anchorX - newWidth : anchorX
      // Dragging a top corner grows the window upward: the bottom edge stays.
      let y = isTop ? startFrame.minY : startFrame.maxY - newHeight
      self.setFrame(
        NSRect(x: x, y: y, width: newWidth, height: newHeight),
        display: true
      )
      // Swallow the drag: Flutter already handed this gesture over.
      return nil
    }
  }

  /// AppKit's diagonal frame-resize cursor for a hovered corner — the Flutter
  /// macOS engine maps no diagonal cursors, so the Dart side asks for this
  /// one-shot after the framework has settled its own cursor for the pointer
  /// update. Nothing to undo: the next framework cursor change paints over it.
  private func showResizeCursor(corner: String) {
    guard compactGeometry != nil else { return }
    if #available(macOS 15.0, *) {
      let position: NSCursor.FrameResizePosition = switch corner {
      case "topLeft": .topLeft
      case "topRight": .topRight
      case "bottomLeft": .bottomLeft
      default: .bottomRight
      }
      NSCursor.frameResize(position: position, directions: .all).set()
    } else {
      // No public diagonal cursor before macOS 15; crosshair at least says
      // "this spot is special".
      NSCursor.crosshair.set()
    }
  }

  private func endCompactResizeTracking() {
    if let monitor = compactResizeMonitor {
      NSEvent.removeMonitor(monitor)
      compactResizeMonitor = nil
    }
  }

  private func clampToVisible(_ rect: NSRect, visible: NSRect) -> NSRect {
    var result = rect
    if result.maxX > visible.maxX { result.origin.x = visible.maxX - result.width }
    if result.minX < visible.minX { result.origin.x = visible.minX }
    if result.maxY > visible.maxY { result.origin.y = visible.maxY - result.height }
    if result.minY < visible.minY { result.origin.y = visible.minY }
    return result
  }

  private func registerNotificationsChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "dev.serverpod.appstudio/notifications",
      binaryMessenger: controller.engine.binaryMessenger
    )
    notificationsChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "show" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      let title = args["title"] as? String ?? "App Studio"
      let body = args["body"] as? String ?? ""
      let force = args["force"] as? Bool ?? false
      self?.showNotification(title: title, body: body, force: force, result: result)
    }
  }

  private func showNotification(
    title: String,
    body: String,
    force: Bool,
    result: @escaping FlutterResult
  ) {
    // Avoid noise while the user is actively in the app.
    if !force && NSApp.isActive {
      result(nil)
      return
    }

    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      if let error {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "auth_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
        return
      }
      guard granted else {
        DispatchQueue.main.async { result(nil) }
        return
      }

      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default

      let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
      )
      center.add(request) { addError in
        DispatchQueue.main.async {
          if let addError {
            result(
              FlutterError(
                code: "post_failed",
                message: addError.localizedDescription,
                details: nil
              )
            )
          } else {
            result(nil)
          }
        }
      }
    }
  }
}
