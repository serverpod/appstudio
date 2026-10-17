#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "compact_window.h"
#include "toast_notifications.h"
#include "win32_window.h"
#include "winsparkle_updater.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Asks Dart to run the exit teardown when Windows signs out or shuts down,
  // and waits for it (up to 5 s) with the message loop running.
  void RunEndSessionTeardown(HWND hwnd);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // dev.serverpod.appstudio/lifecycle: asks Dart to run its exit teardown
  // when the window is closed (lib/platform/window_close.dart).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      lifecycle_channel_;

  // dev.serverpod.appstudio/updates, through WinSparkle.
  std::unique_ptr<WinSparkleUpdater> updater_;

  // dev.serverpod.appstudio/notifications, as toasts.
  std::unique_ptr<ToastNotifications> notifications_;

  // dev.serverpod.appstudio/window: the compact preview window.
  std::unique_ptr<CompactWindow> compact_window_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
