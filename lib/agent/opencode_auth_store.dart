import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Reads/writes OpenCode's native credential file.
///
/// Path: `~/.local/share/opencode/auth.json`
class OpenCodeAuthStore {
  OpenCodeAuthStore({String? authFilePath})
      : authFilePath = authFilePath ?? _defaultPath();

  final String authFilePath;

  static String _defaultPath() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.local', 'share', 'opencode', 'auth.json');
  }

  Future<Map<String, dynamic>> readAll() async {
    final file = File(authFilePath);
    if (!await file.exists()) return {};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return {};
  }

  Future<Set<String>> connectedProviderIds() async {
    final all = await readAll();
    return all.keys.toSet();
  }

  Future<void> setApiKey(String providerId, String key) async {
    final all = await readAll();
    all[providerId] = {'type': 'api', 'key': key};
    await _write(all);
  }

  Future<void> remove(String providerId) async {
    final all = await readAll();
    if (!all.containsKey(providerId)) return;
    all.remove(providerId);
    await _write(all);
  }

  Future<void> _write(Map<String, dynamic> data) async {
    final file = File(authFilePath);
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString('${encoder.convert(data)}\n');
  }
}
