import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'platform_key.dart';
import 'tool_status.dart';
import 'tool_version.dart';

/// Bumped only for breaking shape changes. A manifest declaring a newer schema
/// is ignored rather than half-parsed.
const kManifestSchemaVersion = 1;

const kBakedManifestAsset = 'assets/toolchain_manifest.json';

/// Mutable object at the bucket root — the live pin App Studio fetches on setup.
const kPublishedManifestObject = 'manifest.json';

/// Key into a tool's `platforms` map.


class ToolArtifact {
  const ToolArtifact({
    required this.path,
    required this.sha256,
    required this.downloadBytes,
    required this.installedBytes,
    required this.format,
    required this.stripComponents,
  });

  /// Relative to the manifest's `baseUrl`.
  final String path;
  final String sha256;
  final int downloadBytes;
  final int installedBytes;
  final String format;
  final int stripComponents;

  ToolArtifact copyWith({int? downloadBytes}) => ToolArtifact(
        path: path,
        sha256: sha256,
        downloadBytes: downloadBytes ?? this.downloadBytes,
        installedBytes: installedBytes,
        format: format,
        stripComponents: stripComponents,
      );

  static ToolArtifact? tryParse(Map<String, dynamic> json) {
    final path = json['path'] as String?;
    final sha = json['sha256'] as String?;
    if (path == null || path.isEmpty || sha == null || sha.isEmpty) return null;
    return ToolArtifact(
      path: path,
      sha256: sha.toLowerCase(),
      downloadBytes: _asInt(json['downloadBytes']),
      installedBytes: _asInt(json['installedBytes']),
      format: json['format'] as String? ?? 'tar.gz',
      stripComponents: _asInt(json['stripComponents']),
    );
  }
}

class ToolSpec {
  const ToolSpec({
    required this.id,
    required this.displayName,
    required this.description,
    required this.version,
    required this.build,
    required this.hostAccepts,
    required this.required,
    required this.installDir,
    required this.platforms,
    required this.entrypoints,
    required this.metadata,
  });

  final ToolId id;
  final String displayName;
  final String description;

  /// The version we install.
  final ToolVersion version;

  /// Repack counter — lets us republish the same upstream version.
  final int build;

  /// What a *host* install must satisfy to be reused instead.
  final VersionRange hostAccepts;

  final bool required;

  /// Relative to the managed toolchain root, e.g. `flutter/3.44.2`.
  final String installDir;
  final Map<String, ToolArtifact> platforms;

  /// Paths inside the install dir that must exist for it to count as complete.
  final Map<String, String> entrypoints;
  final Map<String, dynamic> metadata;

  ToolArtifact? get artifactForCurrentPlatform => platforms[currentPlatformKey()];

  ToolSpec copyWith({Map<String, ToolArtifact>? platforms}) => ToolSpec(
        id: id,
        displayName: displayName,
        description: description,
        version: version,
        build: build,
        hostAccepts: hostAccepts,
        required: required,
        installDir: installDir,
        platforms: platforms ?? this.platforms,
        entrypoints: entrypoints,
        metadata: metadata,
      );

  static ToolSpec? tryParse(Map<String, dynamic> json) {
    final rawId = json['id'] as String?;
    if (rawId == null) return null;
    final id = ToolId.fromManifestId(rawId);
    if (id == null) return null;

    final version = ToolVersion.tryParse(json['version'] as String?);
    if (version == null) return null;

    // A malformed range is a manifest bug — refuse the tool rather than
    // defaulting to something permissive.
    final hostAccepts = VersionRange.tryParse(json['hostAccepts'] as String?);
    if (hostAccepts == null) return null;

    final platforms = <String, ToolArtifact>{};
    final rawPlatforms = json['platforms'];
    if (rawPlatforms is Map) {
      for (final entry in rawPlatforms.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final artifact = ToolArtifact.tryParse(
          value.map((k, v) => MapEntry(k.toString(), v)),
        );
        if (artifact != null) platforms[entry.key.toString()] = artifact;
      }
    }

    return ToolSpec(
      id: id,
      displayName: json['displayName'] as String? ?? id.displayName,
      description: json['description'] as String? ?? '',
      version: version,
      build: _asInt(json['build']),
      hostAccepts: hostAccepts,
      required: json['required'] as bool? ?? true,
      installDir: json['installDir'] as String? ??
          '${id.manifestId}/$version',
      platforms: Map.unmodifiable(platforms),
      entrypoints: Map.unmodifiable(_asStringMap(json['entrypoints'])),
      metadata: Map.unmodifiable(_asMap(json['metadata'])),
    );
  }
}

class ToolManifest {
  const ToolManifest({
    required this.manifestId,
    required this.baseUrl,
    required this.tools,
  });

  /// Monotonic id used to decide whether a fetched manifest supersedes the
  /// baked one, and to re-prompt after a pin changes.
  final String manifestId;
  final Uri baseUrl;
  final Map<ToolId, ToolSpec> tools;

  ToolSpec? operator [](ToolId id) => tools[id];

  Uri get publishedManifestUrl => baseUrl.resolve(kPublishedManifestObject);

  /// Whether [other] is an older publish than this one.
  ///
  /// [manifestId] is a UTC timestamp (`YYYY.MM.DD.HHMM`) assigned at publish
  /// time, so lexicographic order matches chronological order.
  bool isNewerThan(ToolManifest other) =>
      manifestId.compareTo(other.manifestId) > 0;

  /// Reads a cached copy written by [fetchPublished].
  static Future<ToolManifest?> loadCached(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return tryParse(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Downloads the live manifest from [baseUrl].
  ///
  /// Returns null on any network, HTTP or parse failure. When [cacheFile] is
  /// set and the fetch succeeds, the raw JSON is written there for offline
  /// reuse on the next launch.
  static Future<ToolManifest?> fetchPublished(
    Uri baseUrl, {
    http.Client? client,
    String? cacheFile,
  }) async {
    final ownClient = client == null;
    final c = client ?? http.Client();
    try {
      final uri = baseUrl.resolve(kPublishedManifestObject).replace(
        queryParameters: {
          '_': DateTime.now().millisecondsSinceEpoch.toString(),
        },
      );
      final response = await c.get(uri).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;
      final manifest = tryParse(response.body);
      if (manifest == null) return null;
      if (cacheFile != null) {
        final file = File(cacheFile);
        await file.parent.create(recursive: true);
        await file.writeAsString(response.body);
      }
      return manifest;
    } catch (_) {
      return null;
    } finally {
      if (ownClient) c.close();
    }
  }

  Uri urlFor(ToolArtifact artifact) => baseUrl.resolve(artifact.path);

  /// Replaces [ToolArtifact.downloadBytes] with the object size reported by
  /// the bucket (`Content-Length` on a HEAD request).
  ///
  /// [installedBytes] stays manifest-only — that is the on-disk footprint
  /// after extraction, which GCS does not know. Failures are silent: the
  /// manifest value is kept when a HEAD misses or errors.
  Future<ToolManifest> withLiveDownloadBytes({http.Client? client}) async {
    final ownClient = client == null;
    final c = client ?? http.Client();
    try {
      var changed = false;
      final platform = currentPlatformKey();
      final tools = <ToolId, ToolSpec>{};

      for (final entry in this.tools.entries) {
        final spec = entry.value;
        final artifact = spec.platforms[platform];
        if (artifact == null) {
          tools[entry.key] = spec;
          continue;
        }
        final live = await _headDownloadBytes(c, urlFor(artifact));
        if (live != null && live != artifact.downloadBytes) {
          changed = true;
          final platforms = Map<String, ToolArtifact>.from(spec.platforms);
          platforms[platform] = artifact.copyWith(downloadBytes: live);
          tools[entry.key] = spec.copyWith(platforms: Map.unmodifiable(platforms));
        } else {
          tools[entry.key] = spec;
        }
      }

      if (!changed) return this;
      return ToolManifest(
        manifestId: manifestId,
        baseUrl: baseUrl,
        tools: Map.unmodifiable(tools),
      );
    } finally {
      if (ownClient) c.close();
    }
  }

  static ToolManifest? tryParse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final json = decoded.map((k, v) => MapEntry(k.toString(), v));

    // Forward compatibility: a newer schema is ignored, not half-read.
    if (_asInt(json['schemaVersion']) != kManifestSchemaVersion) return null;

    final baseUrl = Uri.tryParse(json['baseUrl'] as String? ?? '');
    if (baseUrl == null || !baseUrl.hasScheme) return null;

    final tools = <ToolId, ToolSpec>{};
    final rawTools = json['tools'];
    if (rawTools is List) {
      for (final entry in rawTools) {
        if (entry is! Map) continue;
        final spec = ToolSpec.tryParse(
          entry.map((k, v) => MapEntry(k.toString(), v)),
        );
        if (spec != null) tools[spec.id] = spec;
      }
    }
    if (tools.isEmpty) return null;

    return ToolManifest(
      manifestId: json['manifestId'] as String? ?? '0',
      baseUrl: baseUrl,
      tools: Map.unmodifiable(tools),
    );
  }

  /// The manifest compiled into the app — the source of truth for what this
  /// build requires, and the offline fallback.
  ///
  /// [loadAsset] is injected (normally `rootBundle.loadString`) so this library
  /// stays free of Flutter and can run in a plain Dart script or unit test.
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

int _asInt(Object? value) => switch (value) {
      int() => value,
      double() => value.round(),
      String() => int.tryParse(value) ?? 0,
      _ => 0,
    };

Map<String, dynamic> _asMap(Object? value) => value is Map
    ? value.map((k, v) => MapEntry(k.toString(), v))
    : const <String, dynamic>{};

Map<String, String> _asStringMap(Object? value) => value is Map
    ? {for (final e in value.entries) e.key.toString(): e.value.toString()}
    : const <String, String>{};

Future<int?> _headDownloadBytes(http.Client client, Uri url) async {
  try {
    final response = await client.head(url).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final length = response.contentLength;
    if (length != null && length > 0) return length;
    final header = response.headers['content-length'];
    if (header == null) return null;
    return int.tryParse(header);
  } catch (_) {
    return null;
  }
}
