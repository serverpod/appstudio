import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow {
  private var notificationsChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerNotificationsChannel(flutterViewController)

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
