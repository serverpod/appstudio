import 'dart:convert';
import 'dart:io';

import 'tool_status.dart';
import 'tool_version.dart';
import 'toolchain_manifest.dart';

/// Per-tool version requirements the user can raise from the Tools Manager.
///
/// The manifest supplies the defaults this app build was tested against; this
/// file lets a user demand something newer. It can only ever *raise* the bar —
/// lowering it below what the app requires would let an untested Serverpod
/// through and produce failures nobody could explain.
class ToolchainRequirements {
  const ToolchainRequirements(this._userMinimums);

  static const _schemaVersion = 1;

  final Map<ToolId, ToolVersion> _userMinimums;

  static const empty = ToolchainRequirements({});

  ToolVersion? userMinimumFor(ToolId id) => _userMinimums[id];

  /// The minimum a candidate must meet: the manifest's own floor, raised by
  /// any user override.
  ToolVersion? effectiveMinimum(ToolSpec spec) {
    final fromManifest = spec.hostAccepts.minimum;
    final fromUser = _userMinimums[spec.id];
    if (fromManifest == null) return fromUser;
    if (fromUser == null) return fromManifest;
    return fromUser > fromManifest ? fromUser : fromManifest;
  }

  /// Whether [version] satisfies both the manifest range and the user's floor.
  bool accepts(ToolSpec spec, ToolVersion? version) {
    if (version == null) return false;
    if (!spec.hostAccepts.allows(version)) return false;
    final min = _userMinimums[spec.id];
    return min == null || version >= min;
  }

  /// Human-readable requirement for the Tools Manager, e.g.
  /// `">=4.0.0-beta.1 <4.1.0"` or `">=4.0.0-beta.2 <4.1.0"` once raised.
  String describe(ToolSpec spec) {
    final min = effectiveMinimum(spec);
    final manifestMin = spec.hostAccepts.minimum;
    if (min == null || min == manifestMin) return spec.hostAccepts.toString();
    return spec.hostAccepts.toString().replaceFirst('>=$manifestMin', '>=$min');
  }

  ToolchainRequirements withMinimum(ToolId id, ToolVersion? version) {
    final next = Map<ToolId, ToolVersion>.from(_userMinimums);
    if (version == null) {
      next.remove(id);
    } else {
      next[id] = version;
    }
    return ToolchainRequirements(next);
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': _schemaVersion,
        'tools': {
          for (final entry in _userMinimums.entries)
            entry.key.manifestId: {'minVersion': entry.value.toString()},
        },
      };

  static ToolchainRequirements fromJson(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (_) {
      return empty;
    }
    if (decoded is! Map) return empty;
    if (decoded['schemaVersion'] != _schemaVersion) return empty;

    final tools = decoded['tools'];
    if (tools is! Map) return empty;

    final minimums = <ToolId, ToolVersion>{};
    for (final entry in tools.entries) {
      final id = ToolId.fromManifestId(entry.key.toString());
      if (id == null) continue;
      final value = entry.value;
      if (value is! Map) continue;
      final version = ToolVersion.tryParse(value['minVersion'] as String?);
      if (version != null) minimums[id] = version;
    }
    return ToolchainRequirements(minimums);
  }

  /// Reads the user's overrides, tolerating a missing or corrupt file — a bad
  /// requirements file must never stop the app from starting.
  static Future<ToolchainRequirements> load(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return empty;
      return fromJson(await file.readAsString());
    } catch (_) {
      return empty;
    }
  }

  Future<void> save(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
  }
}
