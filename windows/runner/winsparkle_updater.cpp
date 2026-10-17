#include "winsparkle_updater.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <winsparkle.h>

#include <ctime>

namespace {

constexpr char kChannelName[] = "dev.serverpod.appstudio/updates";

// How long Dart gets to shut a session down before the update goes ahead
// anyway, as on macOS: a wedged server must not strand the user on an old
// build.
constexpr UINT kRelaunchTimeoutMs = 20000;
constexpr UINT_PTR kRelaunchTimer = 0x5150;

// From windows/release.json, through CMake. Empty in a build with no feed.
#ifndef APPSTUDIO_APPCAST_URL
#define APPSTUDIO_APPCAST_URL ""
#endif
#ifndef APPSTUDIO_EDDSA_PUBLIC_KEY
#define APPSTUDIO_EDDSA_PUBLIC_KEY ""
#endif

// WinSparkle's callbacks are plain functions called on its own threads; this
// is where they find the window to post to.
HWND g_window = nullptr;

int __cdecl CanShutdown() {
  // The session is torn down in prepareForRelaunch, so there is never a
  // reason to refuse.
  return TRUE;
}

void __cdecl ShutdownRequested() {
  if (g_window != nullptr) {
    ::PostMessage(g_window, WinSparkleUpdater::kRelaunchMessage, 0, 0);
  }
}

std::wstring Widen(const std::string& ascii) {
  return std::wstring(ascii.begin(), ascii.end());
}

}  // namespace

WinSparkleUpdater::WinSparkleUpdater(flutter::BinaryMessenger* messenger,
                                     HWND window)
    : window_(window) {
  // pubspec's version as CMake passes it: "0.2.3+22" is version 0.2.3, build
  // 22. Release builds set the build to the Windows counter
  // (tool/windows/build_release.ps1), which is what the appcast compares.
  const std::string full = FLUTTER_VERSION;
  const size_t plus = full.find('+');
  version_ = full.substr(0, plus);
  build_ = plus == std::string::npos ? "" : full.substr(plus + 1);

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleCall(call, std::move(result));
      });

#ifdef NDEBUG
  const std::string url = APPSTUDIO_APPCAST_URL;
  const std::string key = APPSTUDIO_EDDSA_PUBLIC_KEY;
  if (url.empty()) {
    error_ = "This build has no update feed.";
  } else if (key.empty() ||
             win_sparkle_set_eddsa_public_key(key.c_str()) == 0) {
    error_ = "This build has no valid update signing key.";
  } else {
    win_sparkle_set_appcast_url(url.c_str());
    // Also where WinSparkle keeps its settings:
    // HKCU\Software\Serverpod\App Studio\WinSparkle.
    win_sparkle_set_app_details(L"Serverpod", L"App Studio",
                                Widen(version_).c_str());
    win_sparkle_set_app_build_version(Widen(build_).c_str());
    win_sparkle_set_can_shutdown_callback(CanShutdown);
    win_sparkle_set_shutdown_request_callback(ShutdownRequested);
    configured_ = true;
  }
#else
  // Debug builds deliberately have no feed, as on macOS.
  error_ = "This build has no update feed.";
#endif
}

WinSparkleUpdater::~WinSparkleUpdater() {
  if (started_) win_sparkle_cleanup();
  g_window = nullptr;
}

void WinSparkleUpdater::Start() {
  if (!configured_ || started_) return;
  g_window = window_;
  started_ = true;
  win_sparkle_init();
}

bool WinSparkleUpdater::HandleMessage(UINT message, WPARAM wparam,
                                      LPARAM lparam) {
  if (message == kRelaunchMessage) {
    PrepareForRelaunch();
    return true;
  }
  if (message == WM_TIMER && wparam == kRelaunchTimer) {
    CloseForUpdate();
    return true;
  }
  return false;
}

void WinSparkleUpdater::HandleCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& method = call.method_name();
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  auto arg = [args](const char* name) -> bool {
    if (args == nullptr) return false;
    auto it = args->find(flutter::EncodableValue(name));
    if (it == args->end()) return false;
    const bool* value = std::get_if<bool>(&it->second);
    return value != nullptr && *value;
  };

  if (method == "getState") {
    result->Success(flutter::EncodableValue(State()));
  } else if (method == "setSessionBusy") {
    session_busy_ = arg("busy");
    result->Success();
  } else if (method == "checkForUpdates") {
    if (!started_) {
      result->Error("unavailable", error_.empty()
                                       ? "Updates are not available in this "
                                         "build."
                                       : error_);
      return;
    }
    // Always the user-initiated path: it says "up to date" too.
    win_sparkle_check_update_with_ui();
    result->Success();
  } else if (method == "setAutomaticallyChecks") {
    if (!started_) {
      result->Error("unavailable");
      return;
    }
    win_sparkle_set_automatic_check_for_updates(arg("enabled") ? 1 : 0);
    result->Success();
  } else {
    result->NotImplemented();
  }
}

flutter::EncodableMap WinSparkleUpdater::State() const {
  flutter::EncodableMap state{
      {flutter::EncodableValue("configured"),
       flutter::EncodableValue(configured_)},
      {flutter::EncodableValue("currentVersion"),
       flutter::EncodableValue(version_)},
      {flutter::EncodableValue("currentBuild"),
       flutter::EncodableValue(build_)},
      // macOS's App Translocation has no Windows counterpart.
      {flutter::EncodableValue("translocated"), flutter::EncodableValue(false)},
  };
  if (!error_.empty()) {
    state[flutter::EncodableValue("error")] = flutter::EncodableValue(error_);
  }
  if (started_) {
    state[flutter::EncodableValue("automaticallyChecks")] =
        flutter::EncodableValue(
            win_sparkle_get_automatic_check_for_updates() != 0);
    const time_t last = win_sparkle_get_last_check_time();
    if (last > 0) {
      state[flutter::EncodableValue("lastCheck")] =
          flutter::EncodableValue(static_cast<int64_t>(last) * 1000);
    }
  }
  return state;
}

void WinSparkleUpdater::PrepareForRelaunch() {
  if (closing_) return;
  // Exactly once, whichever comes first: Dart finishing, or the timeout.
  ::SetTimer(window_, kRelaunchTimer, kRelaunchTimeoutMs, nullptr);
  channel_->InvokeMethod(
      "prepareForRelaunch", nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*) { CloseForUpdate(); },
          [this](const std::string&, const std::string&,
                 const flutter::EncodableValue*) { CloseForUpdate(); },
          [this]() { CloseForUpdate(); }));
}

void WinSparkleUpdater::CloseForUpdate() {
  if (closing_) return;
  closing_ = true;
  ::KillTimer(window_, kRelaunchTimer);
  // The installer is already running and waits on the app's mutex
  // (windows/installer/app_studio.iss), which goes with the process.
  ::DestroyWindow(window_);
}
