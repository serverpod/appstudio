#ifndef RUNNER_COMPACT_WINDOW_H_
#define RUNNER_COMPACT_WINDOW_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>

// dev.serverpod.appstudio/window on Windows: the compact (minimized phone)
// preview window, the counterpart of the compact code in
// macos/Runner/MainFlutterWindow.swift. The Dart side is
// lib/platform/compact_window.dart.
//
// The same contract, one difference. The window goes borderless, keeps the
// phone frame's aspect through every resize (the chrome around the frame is
// fixed-size, so the ratio holds on the content), stays on the visible screen,
// and comes back exactly as it was. But it stays opaque: Flutter's Windows
// embedder draws to a swap chain DWM cannot blend per pixel, so the margin
// around the frame shows the app's background instead of the desktop.
//
// Moving and resizing are Windows' own modal loops, started as if the user
// had pressed on a caption or a sizing border, so Windows tracks the mouse
// and snaps the way users expect. WM_SIZING holds the aspect.
class CompactWindow {
 public:
  CompactWindow(flutter::BinaryMessenger* messenger, HWND window);

  // The window's messages this owns while compact. Sets `result` and returns
  // true when handled.
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                     LRESULT* result);

  bool is_compact() const { return saved_.has_value(); }

 private:
  // Logical pixels, as Dart sends them.
  struct Geometry {
    double aspect_width;
    double aspect_height;
    double chrome_width;
    double chrome_height;
    double min_width;

    double HeightForWidth(double width) const {
      return chrome_height + (width - chrome_width) * aspect_height /
                                 aspect_width;
    }
    double WidthForHeight(double height) const {
      return chrome_width + (height - chrome_height) * aspect_width /
                                aspect_height;
    }
  };

  struct SavedState {
    WINDOWPLACEMENT placement;
    LONG_PTR style;
    LONG_PTR ex_style;
  };

  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  static std::optional<Geometry> ParseGeometry(
      const flutter::EncodableValue* arguments);

  void EnterCompact(const Geometry& geometry);
  void UpdateGeometry(const Geometry& geometry);
  void ExitCompact();
  // The frame scale the window implies: 1.0 is the phone frame at its
  // natural logical size.
  double CurrentScale() const;
  void ApplyGeometry(double scale);
  double DpiScale() const;
  void LockAspect(WPARAM edge, RECT* rect) const;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  std::optional<Geometry> geometry_;
  std::optional<SavedState> saved_;
};

#endif  // RUNNER_COMPACT_WINDOW_H_
