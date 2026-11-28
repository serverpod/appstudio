#include <webview_cef/webview_cef_plugin.h>

#include <unistd.h>

#include <cstdio>

#include "my_application.h"

int main(int argc, char** argv) {
  // CEF starts its helper processes (renderer, GPU, utility) from this same
  // executable. Each of them must run CEF's own entry point and return here,
  // before GTK or Flutter start; otherwise every helper boots a full copy of
  // App Studio. The plugin's own script that was meant to add this patches
  // linux/main.cc, which current Flutter no longer generates.
  int exit_code = initCEFProcesses(argc, argv);
  if (exit_code >= 0) {
    return exit_code;
  }

  // CEF's own folder, inside App Studio's ($XDG_DATA_HOME/
  // dev.serverpod.appstudio, ToolchainPaths.appSupportRoot), so a crashed
  // run's singleton lock cannot block another CEF app, or the next start.
  // GLib reads XDG_DATA_HOME the way the Dart side does.
  g_autofree gchar* cef_root = g_build_filename(
      g_get_user_data_dir(), APPLICATION_ID, "CEF", nullptr);
  setCEFRootCachePath(cef_root);

  g_autoptr(MyApplication) app = my_application_new();
  const int status = g_application_run(G_APPLICATION(app), argc, argv);

  // Flutter's quit (quit_application in fl_platform_handler.cc) stops the
  // main loop but leaves the window, and the Flutter engine inside, alive:
  // nothing shuts the engine down, and its raster thread may still be drawing
  // the preview's last frame. exit() then ran Mesa's teardown underneath it,
  // and App Studio crashed on quit, after its own teardown had stopped the
  // server. Flutter only quits once the Dart side has answered the exit
  // request, so that teardown is done by now: end the process without the
  // exit handlers, and let the kernel take the threads.
  fflush(nullptr);
  _exit(status);
}
