/// What an install would fetch, worked out from the tools' official sources.
///
/// Free of `dart:io` — plain data the setup dialog renders versions and sizes
/// from, which Widgetbook's fakes build by hand.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'tool_status.dart';
import 'tool_version.dart';

/// Flutter's own release feed for macOS — the list its install page reads.
final kFlutterReleasesUrl = Uri.parse(
  'https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json',
);

/// pub.dev's version listing for the Serverpod CLI.
final kServerpodVersionsUrl =
    Uri.parse('https://pub.dev/api/packages/serverpod_cli');

const _timeout = Duration(seconds: 20);

/// One Flutter SDK archive from the official feed.
class FlutterRelease {
  const FlutterRelease({
    required this.version,
    required this.archiveUrl,
    required this.sha256,
    this.downloadBytes,
  });

  final ToolVersion version;
  final Uri archiveUrl;
  final String sha256;

  /// From a HEAD request; the feed does not carry sizes.
  final int? downloadBytes;

  FlutterRelease withDownloadBytes(int? bytes) => FlutterRelease(
        version: version,
        archiveUrl: archiveUrl,
        sha256: sha256,
        downloadBytes: bytes,
      );
}

/// What will be installed for one tool.
class PlannedTool {
  const PlannedTool({required this.id, this.version, this.flutterRelease});

  final ToolId id;

  /// Null where the version is not ours to choose — Apple's installer picks
  /// the Command Line Tools, and `flutter upgrade` picks its own.
  final ToolVersion? version;

  /// Only for a fresh Flutter install.
  final FlutterRelease? flutterRelease;

  int? get downloadBytes => flutterRelease?.downloadBytes;
}

class InstallPlan {
  const InstallPlan([this.tools = const {}]);

  static const empty = InstallPlan();

  final Map<ToolId, PlannedTool> tools;

  PlannedTool? operator [](ToolId id) => tools[id];

  bool covers(Iterable<ToolId> ids) => ids.every(tools.containsKey);

  /// Only what is known; the Command Line Tools come from Apple and say
  /// nothing about their size until their own installer runs.
  int get downloadBytes =>
      tools.values.fold(0, (sum, t) => sum + (t.downloadBytes ?? 0));
}

class PlanException implements Exception {
  const PlanException(this.message);

  final String message;

  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// Pure picking — fed the raw responses.
// ---------------------------------------------------------------------------

/// The newest stable release for [arch] (`arm64` or `x64`) inside [accepts].
FlutterRelease? pickFlutterRelease(
  String feed, {
  required VersionRange accepts,
  required String arch,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(feed);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final base = decoded['base_url'];
  final releases = decoded['releases'];
  if (base is! String || releases is! List) return null;

  FlutterRelease? best;
  for (final raw in releases) {
    if (raw is! Map) continue;
    if (raw['channel'] != 'stable') continue;
    // Older entries predate per-arch archives and are all x64.
    if ((raw['dart_sdk_arch'] ?? 'x64') != arch) continue;
    final version = ToolVersion.tryParse(raw['version'] as String?);
    final archive = raw['archive'];
    final sha = raw['sha256'];
    if (version == null || archive is! String || sha is! String) continue;
    if (!accepts.allows(version)) continue;
    if (best != null && best.version >= version) continue;
    best = FlutterRelease(
      version: version,
      archiveUrl: Uri.parse('$base/$archive'),
      sha256: sha.toLowerCase(),
    );
  }
  return best;
}

/// The newest version of a pub package inside [accepts], preferring stable
/// releases — pub's own rule, so this is what `dart install` would pick too.
ToolVersion? pickPubVersion(String listing, VersionRange accepts) {
  final Object? decoded;
  try {
    decoded = jsonDecode(listing);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final versions = decoded['versions'];
  if (versions is! List) return null;

  ToolVersion? stable;
  ToolVersion? any;
  for (final raw in versions) {
    if (raw is! Map || raw['retracted'] == true) continue;
    final version = ToolVersion.tryParse(raw['version'] as String?);
    if (version == null || !accepts.allows(version)) continue;
    if (any == null || version > any) any = version;
    if (!version.isPrerelease && (stable == null || version > stable)) {
      stable = version;
    }
  }
  return stable ?? any;
}

// ---------------------------------------------------------------------------
// Fetching
// ---------------------------------------------------------------------------

Future<FlutterRelease> fetchFlutterRelease(
  http.Client client, {
  required VersionRange accepts,
  required String arch,
}) async {
  final String feed;
  try {
    final response = await client.get(kFlutterReleasesUrl).timeout(_timeout);
    if (response.statusCode != 200) throw 'HTTP ${response.statusCode}';
    feed = response.body;
  } catch (_) {
    throw const PlanException(
      'Could not reach flutter.dev to look up the latest Flutter release.',
    );
  }
  final release = pickFlutterRelease(feed, accepts: accepts, arch: arch);
  if (release == null) {
    throw PlanException(
      'No stable Flutter release for this Mac matches $accepts.',
    );
  }
  return release.withDownloadBytes(
    await _contentLength(client, release.archiveUrl),
  );
}

Future<ToolVersion> fetchServerpodVersion(
  http.Client client, {
  required VersionRange accepts,
}) async {
  final String listing;
  try {
    final response = await client.get(
      kServerpodVersionsUrl,
      headers: const {'Accept': 'application/vnd.pub.v2+json'},
    ).timeout(_timeout);
    if (response.statusCode != 200) throw 'HTTP ${response.statusCode}';
    listing = response.body;
  } catch (_) {
    throw const PlanException(
      'Could not reach pub.dev to look up the latest Serverpod.',
    );
  }
  final version = pickPubVersion(listing, accepts);
  if (version == null) {
    throw PlanException('No Serverpod release matches $accepts.');
  }
  return version;
}

/// Size is a nicety for the plan; a HEAD that fails leaves it unknown.
Future<int?> _contentLength(http.Client client, Uri url) async {
  try {
    final response = await client.head(url).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    return response.contentLength ??
        int.tryParse(response.headers['content-length'] ?? '');
  } catch (_) {
    return null;
  }
}
