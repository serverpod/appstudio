#include "toast_notifications.h"

#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.h>

#include <string>

namespace {

constexpr char kChannelName[] = "dev.serverpod.appstudio/notifications";

// The id the app sets for itself (main.cpp) and the installer gives its
// Start menu shortcut.
constexpr wchar_t kAppUserModelId[] = L"Serverpod.AppStudio";

std::string StringArg(const flutter::EncodableMap& args, const char* name) {
  auto it = args.find(flutter::EncodableValue(name));
  if (it == args.end()) return {};
  const auto* value = std::get_if<std::string>(&it->second);
  return value == nullptr ? std::string() : *value;
}

bool BoolArg(const flutter::EncodableMap& args, const char* name) {
  auto it = args.find(flutter::EncodableValue(name));
  if (it == args.end()) return false;
  const auto* value = std::get_if<bool>(&it->second);
  return value != nullptr && *value;
}

// Best effort: no shortcut, notifications turned off, Focus Assist — none of
// it is App Studio's to report.
void ShowToast(const std::string& title, const std::string& body) {
  using namespace winrt::Windows::Data::Xml::Dom;
  using namespace winrt::Windows::UI::Notifications;
  try {
    XmlDocument doc;
    doc.LoadXml(
        L"<toast><visual><binding template=\"ToastGeneric\">"
        L"<text></text><text></text>"
        L"</binding></visual></toast>");
    // Text nodes, not string building: titles and summaries are not XML.
    auto texts = doc.GetElementsByTagName(L"text");
    texts.Item(0).AppendChild(doc.CreateTextNode(winrt::to_hstring(title)));
    texts.Item(1).AppendChild(doc.CreateTextNode(winrt::to_hstring(body)));
    ToastNotificationManager::CreateToastNotifier(kAppUserModelId)
        .Show(ToastNotification(doc));
  } catch (const winrt::hresult_error&) {
  }
}

}  // namespace

ToastNotifications::ToastNotifications(flutter::BinaryMessenger* messenger,
                                       HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "show") {
      result->NotImplemented();
      return;
    }
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args == nullptr) {
      result->Error("bad_arguments", "Expected a map.");
      return;
    }
    // The user is looking at App Studio already.
    const bool frontmost = ::GetForegroundWindow() == window_;
    if (!frontmost || BoolArg(*args, "force")) {
      ShowToast(StringArg(*args, "title"), StringArg(*args, "body"));
    }
    result->Success();
  });
}
