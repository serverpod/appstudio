import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../util/home_dir.dart';

/// The `distinct_id` sent with every analytics event, shared with the CLIs.
///
/// Read from `~/.serverpod/uuid` — the same file `serverpod_cli` and
/// `serverpod_cloud_cli` keep theirs in — and created there when absent, in
/// the same v4 format. One person then shows up as one user across all three
/// tools in PostHog rather than as three unrelated ids. The uninstaller removes
/// `~/.serverpod`, so a fresh install gets a fresh id, which is also what the
/// CLIs do.
///
/// Returns null when the id cannot be read *or* written, so the caller can
/// still send events anonymously rather than send nothing. A read-only home
/// directory must not take analytics down with it.
String? readOrCreateAnalyticsUserId({String? home}) {
  final root = home ?? homeDirectory();
  if (root == null) return null;
  final file = File(p.join(root, '.serverpod', 'uuid'));

  try {
    final existing = file.readAsStringSync().trim();
    if (existing.isNotEmpty) return existing;
  } on FileSystemException {
    // Not created yet, or unreadable — either way, fall through to writing.
  }

  final id = generateUuidV4();
  try {
    file.createSync(recursive: true);
    file.writeAsStringSync(id);
  } on FileSystemException {
    return null;
  }
  return id;
}

/// A random RFC 4122 version-4 UUID in the lowercase hyphenated form the
/// `uuid` package writes, which is what the CLIs' `uuid` file holds.
String generateUuidV4({Random? random}) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
