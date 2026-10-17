#include "flutter_window.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "compact_window.h"
#include "toast_notifications.h"
#include "winsparkle_updater.h"

namespace {

constexpr int kMinWindowWidth = 670;
constexpr int kMinWindowHeight = 720;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  lifecycle_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "dev.serverpod.appstudio/lifecycle",
          &flutter::StandardMethodCodec::GetInstance());

  updater_ = std::make_unique<WinSparkleUpdater>(
      flutter_controller_->engine()->messenger(), GetHandle());
  notifications_ = std::make_unique<ToastNotifications>(
      flutter_controller_->engine()->messenger(), GetHandle());
  compact_window_ = std::make_unique<CompactWindow>(
      flutter_controller_->engine()->messenger(), GetHandle());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
    // WinSparkle wants the main window on screen before it checks.
    if (updater_) updater_->Start();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Before the engine whose messenger it uses.
  lifecycle_channel_ = nullptr;
  updater_ = nullptr;
  notifications_ = nullptr;
  compact_window_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Closing the window asks Dart first, so App Studio's exit teardown — the
  // runner it started, CEF, child processes — runs as it does on macOS. The
  // engine only asks the framework itself when this is the process's last
  // top-level window, and CEF keeps hidden windows of its own. Dart answers
  // by exiting through the engine; if it cannot answer, close as before.
  if (message == WM_CLOSE && lifecycle_channel_) {
    auto close_anyway = [hwnd]() { ::DestroyWindow(hwnd); };
    lifecycle_channel_->InvokeMethod(
        "requestExit", nullptr,
        std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
            nullptr,
            [close_anyway](const std::string&, const std::string&,
                           const flutter::EncodableValue*) { close_anyway(); },
            close_anyway));
    return 0;
  }

  if (updater_ && updater_->HandleMessage(message, wparam, lparam)) {
    return 0;
  }

  // The compact preview's borderless frame, aspect lock and minimum size, ahead
  // of the full window's own minimum below.
  LRESULT compact_result = 0;
  if (compact_window_ && compact_window_->HandleMessage(
                             message, wparam, lparam, &compact_result)) {
    return compact_result;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_GETMINMAXINFO: {
      // The same minimum as macOS (MainFlutterWindow.swift) and
      // kMinAppWindowSize in widgetbook/host.dart, in logical pixels.
      const double scale = ::GetDpiForWindow(hwnd) / 96.0;
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = static_cast<LONG>(kMinWindowWidth * scale);
      info->ptMinTrackSize.y = static_cast<LONG>(kMinWindowHeight * scale);
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
