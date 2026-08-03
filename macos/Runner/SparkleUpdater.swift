import Cocoa
import FlutterMacOS
import Sparkle

/// Bridges Sparkle to Dart over `dev.serverpod.appstudio/updates`.
///
/// Sparkle owns the update UI rather than Flutter. The installer has to keep
/// showing progress after our process has already terminated, which a Flutter
/// dialog cannot do — it dies with the engine. What Dart gets instead is state
/// (configured, current version, an update found) and control over the two
/// moments where a running Serverpod server matters:
///
///   1. Scheduled checks are vetoed while a session is live, so a background
///      update never interrupts someone mid-session. A user-initiated check is
///      always allowed.
///   2. Before Sparkle relaunches, Dart gets to tear the session down, so the
///      update does not orphan `serverpod`, `opencode` or CEF processes.
///
/// Note on (1): Sparkle asks synchronously, on the main thread. Calling back
/// into Dart and waiting would deadlock the very thread the engine needs to
/// answer on, so Dart *pushes* its busy state with `setSessionBusy` whenever it
/// changes and this class answers from the cached value.
final class SparkleUpdater: NSObject {
  /// Matches `lib/update/update_channel.dart`.
  private static let channelName = "dev.serverpod.appstudio/updates"

  /// How long Dart gets to shut a session down before we relaunch anyway. A
  /// wedged `serverpod` must not strand the user on an old build.
  private static let relaunchTimeout: TimeInterval = 20

  private var channel: FlutterMethodChannel?
  private var controller: SPUStandardUpdaterController?

  /// Set by Dart. Read on the main thread from Sparkle's delegate callback.
  private var isSessionBusy = false

  /// Nil until `start(_:)` succeeds. Kept so Dart can say "updates are
  /// unavailable, here's why" rather than surfacing errors it cannot act on.
  private var startupError: String?

  private var updater: SPUUpdater? { controller?.updater }

  /// True when the bundle carries a feed URL. Debug builds deliberately do
  /// not, so the menu item greys out instead of failing on use.
  private var isConfigured: Bool {
    guard
      let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    else { return false }
    // The xcconfig substitutes an empty string when SPARKLE_FEED_URL is unset,
    // which Sparkle would otherwise treat as a malformed URL at check time.
    return !feed.trimmingCharacters(in: .whitespaces).isEmpty
  }

  func start(_ flutterController: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: flutterController.engine.binaryMessenger
    )
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    guard isConfigured else {
      startupError = "This build has no update feed."
      return
    }

    // startingUpdater: false — started explicitly below so a bad feed or a
    // missing public key surfaces as a message we can show, rather than as an
    // NSAlert thrown in the user's face during launch.
    let updaterController = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: self,
      userDriverDelegate: nil
    )
    self.controller = updaterController

    do {
      try updaterController.updater.start()
    } catch {
      startupError = error.localizedDescription
      self.controller = nil
    }
  }

  // MARK: - Dart -> Swift

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "getState":
      result(state())

    case "setSessionBusy":
      isSessionBusy = args["busy"] as? Bool ?? false
      result(nil)

    case "checkForUpdates":
      guard let updater else {
        result(
          FlutterError(
            code: "unavailable",
            message: startupError ?? "Updates are not available in this build.",
            details: nil
          )
        )
        return
      }
      // Always the user-initiated path: it shows Sparkle's UI even when the app
      // is already current, which is what someone who clicked a menu item
      // expects to see.
      updater.checkForUpdates()
      result(nil)

    case "setAutomaticallyChecks":
      guard let updater else {
        result(FlutterError(code: "unavailable", message: nil, details: nil))
        return
      }
      updater.automaticallyChecksForUpdates = args["enabled"] as? Bool ?? true
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func state() -> [String: Any] {
    let info = Bundle.main.infoDictionary ?? [:]
    var state: [String: Any] = [
      "configured": controller != nil,
      "currentVersion": info["CFBundleShortVersionString"] as? String ?? "",
      "currentBuild": info["CFBundleVersion"] as? String ?? "",
      // A translocated app cannot update itself: macOS runs it from a
      // read-only mount, so the installer has nothing to replace. Sparkle says
      // so at check time; Dart can warn earlier and more usefully.
      "translocated": Self.isTranslocated,
    ]
    if let error = startupError {
      state["error"] = error
    }
    if let updater {
      state["automaticallyChecks"] = updater.automaticallyChecksForUpdates
      if let last = updater.lastUpdateCheckDate {
        state["lastCheck"] = Int(last.timeIntervalSince1970 * 1000)
      }
    }
    return state
  }

  /// Gatekeeper path randomization runs the bundle from a private mount whose
  /// path contains `/AppTranslocation/`.
  private static var isTranslocated: Bool {
    Bundle.main.bundlePath.contains("/AppTranslocation/")
  }
}

// MARK: - SPUUpdaterDelegate

extension SparkleUpdater: SPUUpdaterDelegate {
  /// Vetoes scheduled checks while a session is live.
  ///
  /// Only `.updatesInBackground` is blocked. A user who picked "Check for
  /// Updates…" is entitled to an answer no matter what is running.
  func updater(
    _ updater: SPUUpdater,
    mayPerform updateCheck: SPUUpdateCheck
  ) throws {
    guard updateCheck == .updatesInBackground, isSessionBusy else { return }
    throw NSError(
      domain: "dev.serverpod.appstudio.updates",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Skipped: a Serverpod server or agent session is running."
      ]
    )
  }

  /// Sparkle is about to swap the bundle and relaunch. Let Dart stop the
  /// server, the CEF preview and the agent first, so the update does not leave
  /// orphaned processes behind.
  func updater(
    _ updater: SPUUpdater,
    shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool {
    guard let channel else { return false }

    // Exactly once, whichever comes first: Dart finishing, or the timeout.
    // Invoking the handler twice would relaunch a half-installed app.
    var resumed = false
    let resume = {
      guard !resumed else { return }
      resumed = true
      installHandler()
    }

    channel.invokeMethod("prepareForRelaunch", arguments: nil) { _ in
      resume()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.relaunchTimeout) {
      resume()
    }
    return true
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    // Let Sparkle read SUFeedURL from Info.plist. Not duplicating it here keeps
    // the signed bundle the single source of truth for where updates come from.
    nil
  }
}
