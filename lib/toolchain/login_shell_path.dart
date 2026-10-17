/// The `PATH` a GUI launch cannot see.
///
/// An app opened from Finder inherits launchd's environment, where `PATH` is
/// `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else. A Flutter SDK outside the
/// hardcoded candidate list, or a `dart install`ed Serverpod CLI, is therefore
/// invisible — and App Studio offers to download 662 MB of tools the Mac
/// already has. The *same build* launched from a terminal inherits the shell's
/// `PATH` and finds them; that difference is the whole of the bug.
///
/// The shell runs **interactive** (`-i`) as well as login (`-l`). On macOS
/// `.zshrc` is the interactive rc, and it is where both users and installers
/// put their `PATH` lines; a login-only shell reads `.zprofile` and misses
/// them. Terminal.app runs login+interactive, so this reproduces exactly what
/// the user sees when they type `flutter` themselves — which is the only
/// defensible definition of "already installed".
///
/// **Discovery only.** Every path found this way is still executed by absolute
/// path with the probe's own controlled environment, so nothing in the user's
/// shell can sway what a tool reports about its own version.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/host.dart';
import '../platform/windows/win32_system.dart';
import '../platform/windows/windows_system.dart';

/// Wraps the value so rc noise — banners, version-manager chatter, a
/// `compinit` warning — cannot be mistaken for the answer.
const _marker = '__APP_STUDIO_PATH__';

const _defaultTimeout = Duration(seconds: 5);

/// Injection point for [ToolProbe]; the default is [captureLoginShellPath].
typedef LoginShellPathReader = Future<String?> Function();

/// Runs the user's login shell and returns the `PATH` it sets up, or null when
/// that cannot be determined.
///
/// Never throws: a shell that is missing, wedged or hostile must degrade to
/// "no extra PATH", not take the probe down with it.
///
/// Windows has no login shell. Its counterpart is the `Path` in the registry,
/// which a running App Studio may predate: see [registryPath].
Future<String?> captureLoginShellPath({
  String? shellOverride,
  Duration timeout = _defaultTimeout,
  HostPlatform? host,
  WindowsSystem? windows,
}) async {
  if ((host ?? currentHost).isWindows) {
    try {
      return registryPath(windows ?? Win32System());
    } catch (_) {
      return null;
    }
  }
  final shell = shellOverride ?? Platform.environment['SHELL'] ?? '/bin/zsh';

  final Process process;
  try {
    process = await Process.start(
      shell,
      ['-l', '-i', '-c', shellPathScript(shell)],
      // Home, not the project: a directory hook (direnv, a `chpwd` function)
      // should not get a say in what the user's PATH is.
      workingDirectory: Platform.environment['HOME'],
      environment: {
        ...Platform.environment,
        // So an rc can skip work it does not want run on a probe.
        'APP_STUDIO_SHELL_PROBE': '1',
      },
      runInShell: false,
    );
  } catch (_) {
    return null;
  }

  // An rc that reads stdin would wait forever, and an unread stderr pipe fills
  // and deadlocks a chatty one. Neither is hypothetical in a `.zshrc`.
  try {
    process.stdin.close().ignore();
  } catch (_) {
    // Already closed; nothing to do.
  }
  process.stderr.drain<void>().ignore();

  // Read incrementally and finish on the closing marker rather than on EOF.
  //
  // Waiting for the stream to end waits for *every* writer to let the pipe go,
  // and the shell's own children inherit it: an rc that backgrounds a daemon —
  // or simply a shell we had to kill, whose `sleep` outlived it — holds stdout
  // open long after the answer has been written. That is a hang on the happy
  // path and a timeout that does not fire on the unhappy one.
  final buffer = StringBuffer();
  final result = Completer<String?>();
  void finish(String? value) {
    if (!result.isCompleted) result.complete(value);
  }

  final subscription = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen(
    (chunk) {
      buffer.write(chunk);
      final path = extractMarkedPath(buffer.toString());
      if (path != null) finish(path);
    },
    onDone: () => finish(extractMarkedPath(buffer.toString())),
    onError: (_) => finish(null),
    cancelOnError: true,
  );

  final timer = Timer(timeout, () => finish(null));
  try {
    return await result.future;
  } finally {
    timer.cancel();
    await subscription.cancel();
    // Unconditional: the shell has already told us everything we wanted, and a
    // `-c` shell that is still alive at this point is one we do not want to
    // leave behind. A no-op for the usual case, where it has already exited.
    process.kill(ProcessSignal.sigkill);
  }
}

/// The one-liner handed to the shell.
///
/// `${PATH}` is braced deliberately: unbraced, `$PATH__APP_STUDIO_PATH__` is a
/// *different* variable name to the shell, which expands to nothing and yields
/// an empty answer that looks like a clean failure.
String shellPathScript(String shell) {
  // fish keeps PATH as a list and has no `${…}` form.
  if (p.basename(shell) == 'fish') {
    return 'printf %s%s%s "$_marker" (string join : \$PATH) "$_marker"';
  }
  return 'printf %s%s%s "$_marker" "\${PATH}" "$_marker"';
}

/// Pulls the value out from between the markers, or null when the output does
/// not carry a complete pair (a killed shell, or one that never ran the line).
String? extractMarkedPath(String output) {
  final start = output.indexOf(_marker);
  if (start < 0) return null;
  final from = start + _marker.length;
  final end = output.indexOf(_marker, from);
  if (end < 0) return null;
  final path = output.substring(from, end).trim();
  return path.isEmpty ? null : path;
}
