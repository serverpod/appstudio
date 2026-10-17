#ifndef RUNNER_WINSPARKLE_UPDATER_H_
#define RUNNER_WINSPARKLE_UPDATER_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>

// Bridges WinSparkle to Dart over dev.serverpod.appstudio/updates — the
// Windows counterpart of macos/Runner/SparkleUpdater.swift, with the same
// methods (lib/update/update_controller.dart):
//
//   getState, checkForUpdates, setAutomaticallyChecks, setSessionBusy
//   and, native to Dart, prepareForRelaunch.
//
// WinSparkle owns the update UI, as Sparkle does on macOS. Updates are
// configured only in a release build whose windows/release.json names an
// appcast and an EdDSA public key; anything else reports updates as
// unavailable, so Check for Updates greys out with a reason.
//
// One difference from Sparkle: WinSparkle cannot veto a scheduled check, so
// setSessionBusy is accepted and remembered but changes nothing. Installing
// an update still tears the session down first (prepareForRelaunch).
class WinSparkleUpdater {
 public:
  // Posted to the window by WinSparkle's shutdown request, which arrives on
  // one of its own threads.
  static constexpr UINT kRelaunchMessage = WM_APP + 0x51;

  WinSparkleUpdater(flutter::BinaryMessenger* messenger, HWND window);
  ~WinSparkleUpdater();

  // Starts WinSparkle, once the window is on screen.
  void Start();

  // The window's messages this owns. True when handled.
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  flutter::EncodableMap State() const;
  void PrepareForRelaunch();
  void CloseForUpdate();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  bool configured_ = false;
  bool started_ = false;
  bool session_busy_ = false;
  bool closing_ = false;
  std::string error_;
  std::string version_;
  std::string build_;
};

#endif  // RUNNER_WINSPARKLE_UPDATER_H_
