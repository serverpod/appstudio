import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where the Windows runner asks Dart what to do when the window's close
/// button (or Alt+F4) is used. macOS never calls it: AppKit already routes a
/// quit through `AppLifecycleListener.onExitRequested`.
const kWindowLifecycleChannel = 'dev.serverpod.appstudio/lifecycle';

bool _exiting = false;

/// Runs the exit teardown when Windows signs out or shuts down, which sends
/// no close: the runner calls `endSession` and waits for it (up to 5 s) before
/// Windows ends the process. Set by the app once its controllers exist.
Future<void> Function()? onWindowsEndSession;

/// Answers the Windows runner's `requestExit` with a cancelable exit, so the
/// same `onExitRequested` teardown macOS runs on ⌘Q runs here too.
///
/// The engine would normally do this itself on `WM_CLOSE`, but only for the
/// last top-level window of the process — and CEF keeps hidden windows of its
/// own, so with a preview open the close went straight past the framework and
/// the runner, CEF and child processes were never stopped. Going through
/// [ServicesBinding.exitApplication] does not depend on that check.
void installWindowCloseHandler() {
  const MethodChannel(kWindowLifecycleChannel).setMethodCallHandler(
    (call) async {
      if (call.method == 'endSession') {
        debugPrint('Windows is ending the session: running the exit teardown.');
        await onWindowsEndSession?.call();
        return null;
      }
      if (call.method != 'requestExit') {
        throw MissingPluginException('No handler for ${call.method}');
      }
      // A second click on the close button while the first teardown runs.
      if (_exiting) return null;
      _exiting = true;
      debugPrint('Window closed: running the exit teardown.');
      try {
        // Returns only if the exit was cancelled; otherwise the engine quits.
        await ServicesBinding.instance.exitApplication(AppExitType.cancelable);
      } finally {
        _exiting = false;
      }
      return null;
    },
  );
}
