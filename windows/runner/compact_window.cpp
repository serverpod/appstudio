#include "compact_window.h"

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <string>

namespace {

constexpr char kChannelName[] = "dev.serverpod.appstudio/window";

// Posted to start a move or a resize once the method call has been answered:
// both are modal loops that run until the mouse is released.
constexpr UINT kStartMoveMessage = WM_APP + 0x60;
constexpr UINT kStartSizeMessage = WM_APP + 0x61;

// Windows 11's rounded corners for a borderless window. Older Windows
// ignores the attribute.
constexpr DWORD kWindowCornerPreference = 33;  // DWMWA_WINDOW_CORNER_PREFERENCE
constexpr DWORD kCornerDefault = 0;            // DWMWCP_DEFAULT
constexpr DWORD kCornerRound = 2;              // DWMWCP_ROUND

double ReadDouble(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return 0;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
  if (const auto* l = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*l);
  }
  return 0;
}

// The sizing border a corner name (UI terms, top-left origin) stands for.
// Windows' coordinates are top-left origin too, so nothing flips.
LRESULT HitTestFor(const std::string& corner) {
  if (corner == "topLeft") return HTTOPLEFT;
  if (corner == "topRight") return HTTOPRIGHT;
  if (corner == "bottomLeft") return HTBOTTOMLEFT;
  return HTBOTTOMRIGHT;
}

RECT WorkAreaOf(HWND window) {
  MONITORINFO info{sizeof(MONITORINFO)};
  ::GetMonitorInfo(::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                   &info);
  return info.rcWork;
}

}  // namespace

CompactWindow::CompactWindow(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleCall(call, std::move(result));
  });
}

std::optional<CompactWindow::Geometry> CompactWindow::ParseGeometry(
    const flutter::EncodableValue* arguments) {
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) return std::nullopt;
  Geometry g{ReadDouble(*map, "aspectWidth"), ReadDouble(*map, "aspectHeight"),
             ReadDouble(*map, "chromeWidth"), ReadDouble(*map, "chromeHeight"),
             ReadDouble(*map, "minWidth")};
  if (g.aspect_width <= 0 || g.aspect_height <= 0 || g.min_width <= 0) {
    return std::nullopt;
  }
  return g;
}

void CompactWindow::HandleCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& method = call.method_name();
  if (method == "enterCompact" || method == "updateCompactGeometry") {
    auto geometry = ParseGeometry(call.arguments());
    if (!geometry) {
      result->Error("bad_arguments", "Incomplete compact window geometry.");
      return;
    }
    if (method == "enterCompact") {
      EnterCompact(*geometry);
    } else {
      UpdateGeometry(*geometry);
    }
    result->Success();
  } else if (method == "exitCompact") {
    ExitCompact();
    result->Success();
  } else if (method == "startDrag") {
    result->Success();
    if (is_compact()) ::PostMessage(window_, kStartMoveMessage, 0, 0);
  } else if (method == "startResize") {
    std::string corner;
    if (const auto* map = std::get_if<flutter::EncodableMap>(call.arguments())) {
      auto it = map->find(flutter::EncodableValue("corner"));
      if (it != map->end()) {
        if (const auto* s = std::get_if<std::string>(&it->second)) corner = *s;
      }
    }
    result->Success();
    if (is_compact()) {
      ::PostMessage(window_, kStartSizeMessage,
                    static_cast<WPARAM>(HitTestFor(corner)), 0);
    }
  } else if (method == "showResizeCursor") {
    // Flutter's Windows embedder has the diagonal cursors, so the corner's
    // MouseRegion asks for one itself (lib/ui/preview_pane.dart).
    result->Success();
  } else {
    result->NotImplemented();
  }
}

double CompactWindow::DpiScale() const {
  return ::GetDpiForWindow(window_) / 96.0;
}

double CompactWindow::CurrentScale() const {
  RECT frame;
  ::GetWindowRect(window_, &frame);
  const double height = (frame.bottom - frame.top) / DpiScale();
  return (height - geometry_->chrome_height) / geometry_->aspect_height;
}

void CompactWindow::EnterCompact(const Geometry& geometry) {
  // Re-entry (Dart exits before re-entering, but be safe) re-applies the
  // geometry at the current scale.
  if (is_compact()) {
    const double scale = CurrentScale();
    geometry_ = geometry;
    ApplyGeometry(scale);
    return;
  }

  SavedState saved{};
  saved.placement.length = sizeof(WINDOWPLACEMENT);
  ::GetWindowPlacement(window_, &saved.placement);
  saved.style = ::GetWindowLongPtr(window_, GWL_STYLE);
  saved.ex_style = ::GetWindowLongPtr(window_, GWL_EXSTYLE);
  saved_ = saved;
  geometry_ = geometry;

  // A maximized window would keep its maximized size through the style
  // change.
  if (::IsZoomed(window_)) ::ShowWindow(window_, SW_RESTORE);

  // Borderless, but still a sizable window, so Windows' own sizing loop
  // works from the corners; WM_NCCALCSIZE hides the sizing border.
  LONG_PTR style = saved.style;
  style &= ~(WS_CAPTION | WS_MAXIMIZEBOX);
  style |= WS_POPUP | WS_THICKFRAME;
  ::SetWindowLongPtr(window_, GWL_STYLE, style);
  ::DwmSetWindowAttribute(window_, kWindowCornerPreference, &kCornerRound,
                          sizeof(kCornerRound));

  RECT frame;
  ::GetWindowRect(window_, &frame);
  const RECT work = WorkAreaOf(window_);
  const double dpi = DpiScale();
  const double height = std::min<double>(frame.bottom - frame.top,
                                         (work.bottom - work.top) * 0.8) /
                        dpi;
  ApplyGeometry((height - geometry.chrome_height) / geometry.aspect_height);
}

void CompactWindow::UpdateGeometry(const Geometry& geometry) {
  // An orientation flip carries the frame's scale over, never the window's
  // height: carried over, a tall portrait window became a landscape one wider
  // than the screen.
  const bool compact = is_compact();
  const double scale = compact && geometry_ ? CurrentScale() : 0;
  geometry_ = geometry;
  if (compact) ApplyGeometry(scale);
}

void CompactWindow::ApplyGeometry(double scale) {
  const Geometry& g = *geometry_;
  const RECT work = WorkAreaOf(window_);
  const double dpi = DpiScale();
  const double work_width = (work.right - work.left) / dpi;
  const double work_height = (work.bottom - work.top) / dpi;

  const double min_scale = (g.min_width - g.chrome_width) / g.aspect_width;
  const double max_scale =
      std::min((work_width - g.chrome_width) / g.aspect_width,
               (work_height - g.chrome_height) / g.aspect_height);
  scale = std::max(min_scale, std::min(scale, max_scale));

  const int width =
      static_cast<int>((g.chrome_width + scale * g.aspect_width) * dpi + 0.5);
  const int height =
      static_cast<int>((g.chrome_height + scale * g.aspect_height) * dpi + 0.5);

  // Centered where the window was, then kept on the visible screen.
  RECT frame;
  ::GetWindowRect(window_, &frame);
  int left = (frame.left + frame.right) / 2 - width / 2;
  int top = (frame.top + frame.bottom) / 2 - height / 2;
  left = std::max<int>(work.left, std::min<int>(left, work.right - width));
  top = std::max<int>(work.top, std::min<int>(top, work.bottom - height));

  ::SetWindowPos(window_, nullptr, left, top, width, height,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

void CompactWindow::ExitCompact() {
  if (!is_compact()) return;
  const SavedState saved = *saved_;
  saved_.reset();
  ::SetWindowLongPtr(window_, GWL_STYLE, saved.style);
  ::SetWindowLongPtr(window_, GWL_EXSTYLE, saved.ex_style);
  ::DwmSetWindowAttribute(window_, kWindowCornerPreference, &kCornerDefault,
                          sizeof(kCornerDefault));
  ::SetWindowPos(window_, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  ::SetWindowPlacement(window_, &saved.placement);
}

void CompactWindow::LockAspect(WPARAM edge, RECT* rect) const {
  const Geometry& g = *geometry_;
  const double dpi = DpiScale();
  double width = std::max((rect->right - rect->left) / dpi, g.min_width);
  double height = (rect->bottom - rect->top) / dpi;
  // A top or bottom edge drives the height; everything else, the width.
  if (edge == WMSZ_TOP || edge == WMSZ_BOTTOM) {
    width = std::max(g.WidthForHeight(height), g.min_width);
  }
  height = g.HeightForWidth(width);
  const int w = static_cast<int>(width * dpi + 0.5);
  const int h = static_cast<int>(height * dpi + 0.5);

  // Grow or shrink away from the corner that stays put.
  const bool moves_left = edge == WMSZ_LEFT || edge == WMSZ_TOPLEFT ||
                          edge == WMSZ_BOTTOMLEFT;
  const bool moves_top = edge == WMSZ_TOP || edge == WMSZ_TOPLEFT ||
                         edge == WMSZ_TOPRIGHT;
  if (moves_left) {
    rect->left = rect->right - w;
  } else {
    rect->right = rect->left + w;
  }
  if (moves_top) {
    rect->top = rect->bottom - h;
  } else {
    rect->bottom = rect->top + h;
  }
}

bool CompactWindow::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                                  LRESULT* result) {
  if (!is_compact() || !geometry_) return false;
  switch (message) {
    case WM_NCCALCSIZE:
      // The whole window is client area: no caption, no visible border.
      if (wparam == TRUE) {
        *result = 0;
        return true;
      }
      return false;
    case WM_SIZING:
      LockAspect(wparam, reinterpret_cast<RECT*>(lparam));
      *result = TRUE;
      return true;
    case WM_GETMINMAXINFO: {
      const Geometry& g = *geometry_;
      const double dpi = DpiScale();
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = static_cast<LONG>(g.min_width * dpi);
      info->ptMinTrackSize.y =
          static_cast<LONG>(g.HeightForWidth(g.min_width) * dpi);
      *result = 0;
      return true;
    }
    case kStartMoveMessage:
      // As if the user had pressed on a caption: Windows runs the move.
      ::ReleaseCapture();
      ::SendMessage(window_, WM_NCLBUTTONDOWN, HTCAPTION, 0);
      *result = 0;
      return true;
    case kStartSizeMessage:
      // As if on that corner's sizing border: Windows runs the resize, and
      // WM_SIZING above holds the aspect.
      ::ReleaseCapture();
      ::SendMessage(window_, WM_NCLBUTTONDOWN, wparam, 0);
      *result = 0;
      return true;
  }
  return false;
}
