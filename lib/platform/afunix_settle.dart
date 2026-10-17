import 'dart:async';

import 'host.dart';

/// How long Windows gets to finish closing AF_UNIX sockets before the process
/// ends.
const kAfUnixSettle = Duration(milliseconds: 500);

/// Waits, on Windows only, for sockets already closed in Dart to be closed in
/// the kernel too.
///
/// A process that exits while it still holds a connected AF_UNIX socket can
/// stop Windows with a bugcheck in `afunix.sys` (specs/
/// windows_afunix_bsod_report.md). It has happened on the dev laptop and on
/// GitHub's Windows runners. Destroying a Dart socket does not close it at
/// once: with a read pending, the handle is closed only after the cancelled
/// read completes on the I/O thread. Call this after closing every runner
/// connection, right before the process exits. Nothing to wait for elsewhere.
Future<void> settleAfUnixSockets({Duration settle = kAfUnixSettle}) async {
  if (!currentHost.isWindows) return;
  await Future<void>.delayed(settle);
}
