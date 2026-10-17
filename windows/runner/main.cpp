#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shlobj.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"
#include "webview_cef/webview_cef_plugin_c_api.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // CEF relaunches this executable for its renderer, GPU and utility
  // processes. Those must branch off here, before anything else runs.
  int cef_exit_code = initCEFProcesses(instance);
  if (cef_exit_code >= 0) {
    return cef_exit_code;
  }

  // One App Studio at a time, as macOS gives one instance per app: a second
  // would fight the first over CEF's cache lock and the projects' runners. A
  // second launch brings the first window forward instead. The installer's
  // AppMutex names the same mutex, so it waits for App Studio to close.
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, FALSE, L"Serverpod.AppStudio.Running");
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    if (HWND existing =
            ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"App Studio")) {
      if (::IsIconic(existing)) ::ShowWindow(existing, SW_RESTORE);
      ::SetForegroundWindow(existing);
    }
    return EXIT_SUCCESS;
  }

  // Taskbar grouping, pinning and toast notifications go by this id. The
  // installer gives the Start menu shortcut the same one.
  ::SetCurrentProcessExplicitAppUserModelID(L"Serverpod.AppStudio");

  // CEF's own data, including its process singleton lock, in a directory of
  // ours: %LOCALAPPDATA%\App Studio\CEF. Left unset, CEF shares one default
  // directory with every other CEF app that also left it unset.
  // macOS does the same from CefWrapper.mm.
  PWSTR local_app_data = nullptr;
  if (SUCCEEDED(::SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                       &local_app_data))) {
    std::wstring cache_path(local_app_data);
    cache_path += L"\\App Studio\\CEF";
    setCEFRootCachePath(cache_path.c_str());
  }
  ::CoTaskMemFree(local_app_data);

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 800);
  if (!window.Create(L"App Studio", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    // A key for the focused preview goes to the page alone, so the app's
    // shortcuts do not fire while the user types there.
    if (routeKeyForCEF(msg.hwnd, msg.message, msg.wParam, msg.lParam)) {
      continue;
    }
    ::DispatchMessage(&msg);
    // CEF's posts back onto the Flutter engine thread.
    handleWndProcForCEF(msg.hwnd, msg.message, msg.wParam, msg.lParam);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
