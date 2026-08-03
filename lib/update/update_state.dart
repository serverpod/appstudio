import 'package:flutter/foundation.dart';

/// What the Swift side knows about updates, as a plain value.
///
/// Kept free of plugin imports so it can be unit-tested without a binding, and
/// parsed defensively: this crosses a MethodChannel, and a malformed reply must
/// degrade to "updates unavailable" rather than throw during startup.
@immutable
class UpdateState {
  const UpdateState({
    this.configured = false,
    this.currentVersion = '',
    this.currentBuild = '',
    this.automaticallyChecks = false,
    this.translocated = false,
    this.lastCheck,
    this.error,
  });

  /// False in debug builds (no feed URL) and whenever Sparkle failed to start.
  /// The menu item should be disabled, not hidden — "why is this missing?" is a
  /// worse question than a greyed-out item with a reason.
  final bool configured;

  final String currentVersion;
  final String currentBuild;
  final bool automaticallyChecks;

  /// The app is running from Gatekeeper's read-only translocation mount, so it
  /// physically cannot replace itself. Almost always means "still in
  /// ~/Downloads"; the fix is to move it to /Applications.
  final bool translocated;

  final DateTime? lastCheck;

  /// Why updates are unavailable, when they are.
  final String? error;

  /// True when a check can actually be performed right now.
  bool get canCheck => configured && !translocated;

  /// Short reason a check is unavailable, or null when it is available.
  ///
  /// Short because it goes in a menu item's title. Translocation comes first:
  /// it is the only case the user can fix, and the fix is not obvious.
  String? get unavailableReason {
    if (canCheck) return null;
    if (translocated) return 'move to Applications first';
    // Debug builds have no feed by design, which is the case a developer hits.
    return 'unavailable in this build';
  }

  static const unavailable = UpdateState();

  factory UpdateState.fromMap(Map<Object?, Object?> map) {
    T? read<T>(String key) {
      final value = map[key];
      return value is T ? value : null;
    }

    final lastCheckMs = read<int>('lastCheck');
    return UpdateState(
      configured: read<bool>('configured') ?? false,
      currentVersion: read<String>('currentVersion') ?? '',
      currentBuild: read<String>('currentBuild') ?? '',
      automaticallyChecks: read<bool>('automaticallyChecks') ?? false,
      translocated: read<bool>('translocated') ?? false,
      lastCheck: lastCheckMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastCheckMs),
      error: read<String>('error'),
    );
  }

  UpdateState copyWith({bool? automaticallyChecks}) => UpdateState(
        configured: configured,
        currentVersion: currentVersion,
        currentBuild: currentBuild,
        automaticallyChecks: automaticallyChecks ?? this.automaticallyChecks,
        translocated: translocated,
        lastCheck: lastCheck,
        error: error,
      );

  /// A short line for the settings pane, e.g. "Version 1.2.3 (build 8)".
  String get versionLabel {
    if (currentVersion.isEmpty) return 'Unknown version';
    if (currentBuild.isEmpty) return 'Version $currentVersion';
    return 'Version $currentVersion (build $currentBuild)';
  }

  @override
  bool operator ==(Object other) =>
      other is UpdateState &&
      other.configured == configured &&
      other.currentVersion == currentVersion &&
      other.currentBuild == currentBuild &&
      other.automaticallyChecks == automaticallyChecks &&
      other.translocated == translocated &&
      other.lastCheck == lastCheck &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
        configured,
        currentVersion,
        currentBuild,
        automaticallyChecks,
        translocated,
        lastCheck,
        error,
      );
}
