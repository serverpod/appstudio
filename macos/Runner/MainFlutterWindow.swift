import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow {
  private var notificationsChannel: FlutterMethodChannel?
  // Held for the window's lifetime: Sparkle's updater stops scheduling checks
  // the moment its controller is deallocated.
  private let sparkleUpdater = SparkleUpdater()

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
    sparkleUpdater.start(flutterViewController)

    super.awakeFromNib()
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
