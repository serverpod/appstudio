import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'tool_status.dart';

/// One line App Studio added to a shell config, recorded exactly so uninstall
/// can remove exactly that and nothing else.
class RecordedPathLine {
  const RecordedPathLine({required this.file, required this.line});

  final String file;
  final String line;

  Map<String, dynamic> toJson() => {'file': file, 'line': line};

  static RecordedPathLine? fromJson(Object? json) {
    if (json is! Map) return null;
    final file = json['file'];
    final line = json['line'];
    if (file is! String || line is! String) return null;
    return RecordedPathLine(file: file, line: line);
  }

  @override
  bool operator ==(Object other) =>
      other is RecordedPathLine && other.file == file && other.line == line;

  @override
  int get hashCode => Object.hash(file, line);
}

/// A tool App Studio installed.
class RecordedInstall {
  const RecordedInstall({
    required this.id,
    required this.installedAt,
    this.path,
    this.version,
    this.pathLines = const [],
  });

  final ToolId id;

  /// The install directory (Flutter) or executable (Serverpod). The Command
  /// Line Tools have none of their own — `xcode-select -p` says where they are.
  final String? path;
  final String? version;
  final DateTime installedAt;
  final List<RecordedPathLine> pathLines;

  RecordedInstall copyWith({
    String? version,
    List<RecordedPathLine>? pathLines,
  }) =>
      RecordedInstall(
        id: id,
        installedAt: installedAt,
        path: path,
        version: version ?? this.version,
        pathLines: pathLines ?? this.pathLines,
      );

  Map<String, dynamic> toJson() => {
        if (path != null) 'path': path,
        if (version != null) 'version': version,
        'installedAt': installedAt.toUtc().toIso8601String(),
        if (pathLines.isNotEmpty)
          'pathLines': [for (final line in pathLines) line.toJson()],
      };

  static RecordedInstall? fromJson(ToolId id, Object? json) {
    if (json is! Map) return null;
    final installedAt =
        DateTime.tryParse(json['installedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final lines = json['pathLines'];
    return RecordedInstall(
      id: id,
      installedAt: installedAt,
      path: json['path'] as String?,
      version: json['version'] as String?,
      pathLines: [
        if (lines is List)
          for (final raw in lines) ?RecordedPathLine.fromJson(raw),
      ],
    );
  }
}

/// What App Studio put on this Mac.
///
/// Lives in `~/.serverpod/app_studio_installs.json`. It is what lets uninstall
/// offer *our* installs — prefilled — and leave the user's own alone, and what
/// lets setup update a Flutter it installed rather than asking the user to.
///
/// Immutable; every change returns a new record for the caller to [save].
class InstallRecord {
  const InstallRecord([this.tools = const {}]);

  static const _schemaVersion = 1;

  static const empty = InstallRecord();

  final Map<ToolId, RecordedInstall> tools;

  RecordedInstall? operator [](ToolId id) => tools[id];

  bool get isEmpty => tools.isEmpty;

  /// Whether [path] is the copy of [id] App Studio installed. With no [path],
  /// whether App Studio installed [id] at all.
  bool owns(ToolId id, {String? path}) {
    final entry = tools[id];
    if (entry == null) return false;
    if (path == null || entry.path == null) return true;
    return p.equals(p.normalize(entry.path!), p.normalize(path));
  }

  InstallRecord withTool(RecordedInstall install) =>
      InstallRecord(Map.unmodifiable({...tools, install.id: install}));

  InstallRecord without(ToolId id) => InstallRecord(
        Map.unmodifiable({
          for (final e in tools.entries)
            if (e.key != id) e.key: e.value,
        }),
      );

  String encode() => const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': _schemaVersion,
        'installedBy': 'App Studio',
        'tools': {
          for (final e in tools.entries) e.key.manifestId: e.value.toJson(),
        },
      });

  static InstallRecord decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (_) {
      return empty;
    }
    if (decoded is! Map || decoded['schemaVersion'] != _schemaVersion) {
      return empty;
    }
    final raw = decoded['tools'];
    if (raw is! Map) return empty;
    final tools = <ToolId, RecordedInstall>{};
    for (final entry in raw.entries) {
      final id = ToolId.fromManifestId('${entry.key}');
      if (id == null) continue;
      final install = RecordedInstall.fromJson(id, entry.value);
      if (install != null) tools[id] = install;
    }
    return InstallRecord(Map.unmodifiable(tools));
  }

  /// Never throws: a missing or corrupt record reads as "nothing installed by
  /// App Studio", which only costs the prefill.
  static Future<InstallRecord> load(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return empty;
      return decode(await file.readAsString());
    } catch (_) {
      return empty;
    }
  }

  /// Writes the record, or deletes the file once nothing is left in it — an
  /// empty record says nothing a missing one does not.
  Future<void> save(String path) async {
    final file = File(path);
    if (isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    final temp = File('$path.tmp');
    await temp.writeAsString(encode(), flush: true);
    await temp.rename(path);
  }
}
