import 'dart:convert';

import 'tool_status.dart';
import 'tool_version.dart';

/// Bumped only for breaking shape changes. A file declaring another schema is
/// refused rather than half-read.
///
/// Schema 1 carried download artifacts from App Studio's own bucket; schema 2
/// is only the ranges, because every tool now comes from its official source.
const kManifestSchemaVersion = 2;

const kBakedManifestAsset = 'assets/toolchain_manifest.json';

/// One tool App Studio needs, and which versions of it will do.
class ToolSpec {
  const ToolSpec({
    required this.id,
    required this.displayName,
    required this.description,
    required this.accepts,
  });

  final ToolId id;
  final String displayName;
  final String description;

  /// The versions this build of App Studio works with. A copy outside it is
  /// updated; a fresh install picks the newest release inside it.
  final VersionRange accepts;

  static ToolSpec? tryParse(Map<String, dynamic> json) {
    final rawId = json['id'] as String?;
    if (rawId == null) return null;
    final id = ToolId.fromManifestId(rawId);
    if (id == null) return null;

    // A malformed range is a manifest bug — refuse the tool rather than
    // defaulting to something permissive.
    final accepts = VersionRange.tryParse(json['accepts'] as String? ?? '*');
    if (accepts == null) return null;

    return ToolSpec(
      id: id,
      displayName: json['displayName'] as String? ?? id.displayName,
      description: json['description'] as String? ?? '',
      accepts: accepts,
    );
  }
}

/// The version ranges compiled into the app — the one source of truth for
/// what this build works with.
class ToolManifest {
  const ToolManifest({required this.tools});

  final Map<ToolId, ToolSpec> tools;

  ToolSpec? operator [](ToolId id) => tools[id];

  static ToolManifest? tryParse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    if (decoded['schemaVersion'] != kManifestSchemaVersion) return null;

    final tools = <ToolId, ToolSpec>{};
    final rawTools = decoded['tools'];
    if (rawTools is List) {
      for (final entry in rawTools) {
        if (entry is! Map) continue;
        final spec = ToolSpec.tryParse(
          entry.map((k, v) => MapEntry(k.toString(), v)),
        );
        if (spec != null) tools[spec.id] = spec;
      }
    }
    // Every tool is required; a file missing one is not a manifest this build
    // can run on.
    if (!ToolId.values.every(tools.containsKey)) return null;

    return ToolManifest(tools: Map.unmodifiable(tools));
  }

  /// [loadAsset] is injected (normally `rootBundle.loadString`) so this library
  /// stays free of Flutter and can run in a plain Dart test.
  static Future<ToolManifest> loadBaked(
    Future<String> Function(String key) loadAsset,
  ) async {
    final source = await loadAsset(kBakedManifestAsset);
    final manifest = tryParse(source);
    if (manifest == null) {
      throw StateError('Bundled $kBakedManifestAsset is not a valid manifest');
    }
    return manifest;
  }
}
