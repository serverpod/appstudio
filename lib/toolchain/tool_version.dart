/// Version comparison for toolchain tools.
///
/// Semver, with one deliberate accommodation: a prerelease made up **only of
/// numbers** is treated as a *post*-release revision rather than a prerelease.
/// That is what dugite means by `2.53.0-3` — the third packaging of git 2.53.0,
/// which is newer than 2.53.0, not older. Without this, a requirement of
/// `>=2.53.0` would reject the very artifact we ship.
///
/// Mixed prereleases keep standard semver ordering, so `4.0.0-beta.1 < 4.0.0`.
library;

final _versionPattern = RegExp(
  r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$',
);

class ToolVersion implements Comparable<ToolVersion> {
  ToolVersion(
    this.major,
    this.minor,
    this.patch, {
    List<String> pre = const [],
  }) : pre = List.unmodifiable(pre);

  final int major;
  final int minor;
  final int patch;

  /// Dot-separated prerelease identifiers, empty for a plain release.
  final List<String> pre;

  /// Returns null for anything unparseable — callers surface "unknown version"
  /// rather than crashing on a tool that printed something unexpected.
  static ToolVersion? tryParse(String? input) {
    if (input == null) return null;
    final match = _versionPattern.firstMatch(input.trim());
    if (match == null) return null;
    return ToolVersion(
      int.parse(match.group(1)!),
      int.tryParse(match.group(2) ?? '') ?? 0,
      int.tryParse(match.group(3) ?? '') ?? 0,
      pre: match.group(4)?.split('.') ?? const [],
    );
  }

  bool get isPrerelease => pre.isNotEmpty && !_preIsAllNumeric;

  /// A purely numeric suffix is a packaging revision (dugite), not a prerelease.
  bool get _preIsAllNumeric =>
      pre.isNotEmpty && pre.every((p) => int.tryParse(p) != null);

  @override
  int compareTo(ToolVersion other) {
    final core = major.compareTo(other.major) != 0
        ? major.compareTo(other.major)
        : minor.compareTo(other.minor) != 0
            ? minor.compareTo(other.minor)
            : patch.compareTo(other.patch);
    if (core != 0) return core;

    if (pre.isEmpty && other.pre.isEmpty) return 0;
    // Against a plain release: a numeric revision is newer, a prerelease older.
    if (pre.isEmpty) return other._preIsAllNumeric ? -1 : 1;
    if (other.pre.isEmpty) return _preIsAllNumeric ? 1 : -1;
    if (_preIsAllNumeric != other._preIsAllNumeric) {
      return _preIsAllNumeric ? 1 : -1;
    }
    return _comparePre(pre, other.pre);
  }

  static int _comparePre(List<String> a, List<String> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      final an = int.tryParse(a[i]);
      final bn = int.tryParse(b[i]);
      final int result;
      if (an != null && bn != null) {
        result = an.compareTo(bn);
      } else if (an != null) {
        result = -1; // numeric identifiers rank below alphanumeric (semver)
      } else if (bn != null) {
        result = 1;
      } else {
        result = a[i].compareTo(b[i]);
      }
      if (result != 0) return result;
    }
    // All shared identifiers equal — more identifiers wins.
    return a.length.compareTo(b.length);
  }

  bool operator <(ToolVersion other) => compareTo(other) < 0;
  bool operator <=(ToolVersion other) => compareTo(other) <= 0;
  bool operator >(ToolVersion other) => compareTo(other) > 0;
  bool operator >=(ToolVersion other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is ToolVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, Object.hashAll(pre));

  @override
  String toString() {
    final core = '$major.$minor.$patch';
    return pre.isEmpty ? core : '$core-${pre.join('.')}';
  }
}

enum _Op { gte, gt, lte, lt, eq }

class _Constraint {
  const _Constraint(this.op, this.version);

  final _Op op;
  final ToolVersion version;

  bool allows(ToolVersion v) {
    final c = v.compareTo(version);
    return switch (op) {
      _Op.gte => c >= 0,
      _Op.gt => c > 0,
      _Op.lte => c <= 0,
      _Op.lt => c < 0,
      _Op.eq => c == 0,
    };
  }

  @override
  String toString() {
    final prefix = switch (op) {
      _Op.gte => '>=',
      _Op.gt => '>',
      _Op.lte => '<=',
      _Op.lt => '<',
      _Op.eq => '',
    };
    return '$prefix$version';
  }
}

/// Space-separated constraints, all of which must hold: `'>=3.44.0 <3.45.0'`.
class VersionRange {
  const VersionRange(this._constraints, this._source);

  final List<_Constraint> _constraints;
  final String _source;

  /// An empty or `*` range accepts anything. Returns null if any constraint is
  /// malformed, so a typo in the manifest fails loudly instead of silently
  /// accepting every version.
  static VersionRange? tryParse(String? input) {
    final source = input?.trim() ?? '';
    if (source.isEmpty || source == '*' || source == 'any') {
      return VersionRange(const [], source.isEmpty ? '*' : source);
    }

    final constraints = <_Constraint>[];
    for (final part in source.split(RegExp(r'[\s,]+'))) {
      if (part.isEmpty) continue;
      final (op, rest) = switch (part) {
        _ when part.startsWith('>=') => (_Op.gte, part.substring(2)),
        _ when part.startsWith('<=') => (_Op.lte, part.substring(2)),
        _ when part.startsWith('>') => (_Op.gt, part.substring(1)),
        _ when part.startsWith('<') => (_Op.lt, part.substring(1)),
        _ when part.startsWith('==') => (_Op.eq, part.substring(2)),
        _ when part.startsWith('=') => (_Op.eq, part.substring(1)),
        _ => (_Op.eq, part),
      };
      final version = ToolVersion.tryParse(rest);
      if (version == null) return null;
      constraints.add(_Constraint(op, version));
    }
    if (constraints.isEmpty) return null;
    return VersionRange(constraints, source);
  }

  bool allows(ToolVersion? version) {
    if (version == null) return false;
    return _constraints.every((c) => c.allows(version));
  }

  /// Lowest version this range accepts, when it states one — used to suggest
  /// "needs >=4.0.0-beta.1" in the UI.
  ToolVersion? get minimum {
    for (final c in _constraints) {
      if (c.op == _Op.gte || c.op == _Op.eq) return c.version;
    }
    return null;
  }

  @override
  String toString() => _source;
}
