#ifndef RUNNER_TOAST_NOTIFICATIONS_H_
#define RUNNER_TOAST_NOTIFICATIONS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// dev.serverpod.appstudio/notifications on Windows: `show` posts a toast,
// skipped while App Studio is the foreground window unless `force` is set —
// the same rule as macOS (lib/platform/studio_notifications.dart).
//
// Windows shows toasts only for an app with a Start menu shortcut carrying
// its AppUserModelID, which the installer creates
// (windows/installer/app_studio.iss). A build run from the build folder has
// none, so its toasts quietly go nowhere.
class ToastNotifications {
 public:
  ToastNotifications(flutter::BinaryMessenger* messenger, HWND window);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
};

#endif  // RUNNER_TOAST_NOTIFICATIONS_H_
