import 'package:appstudio/update/update_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// [UpdateState] is parsed from a MethodChannel reply, so it has to survive
/// anything Swift might send — including nothing at all. A throw here would
/// happen during `main()`, before the UI exists to report it.
void main() {
  test('parses a full reply', () {
    final state = UpdateState.fromMap({
      'configured': true,
      'currentVersion': '1.2.3',
      'currentBuild': '8',
      'automaticallyChecks': true,
      'translocated': false,
      'lastCheck': 1700000000000,
    });

    expect(state.configured, isTrue);
    expect(state.currentVersion, '1.2.3');
    expect(state.currentBuild, '8');
    expect(state.automaticallyChecks, isTrue);
    expect(state.lastCheck, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(state.error, isNull);
    expect(state.canCheck, isTrue);
  });

  test('an empty reply is unavailable, not a crash', () {
    final state = UpdateState.fromMap(const {});
    expect(state.configured, isFalse);
    expect(state.canCheck, isFalse);
    expect(state.currentVersion, isEmpty);
    expect(state.lastCheck, isNull);
  });

  test('wrong types fall back rather than throwing', () {
    final state = UpdateState.fromMap(const {
      'configured': 'yes',
      'currentVersion': 42,
      'lastCheck': 'never',
      'translocated': 1,
    });
    expect(state.configured, isFalse);
    expect(state.currentVersion, isEmpty);
    expect(state.lastCheck, isNull);
    expect(state.translocated, isFalse);
  });

  test('a translocated app cannot check, however well configured', () {
    // Running from ~/Downloads under Gatekeeper path randomization: the bundle
    // is on a read-only mount, so there is nothing for the installer to
    // replace. Offering a check would download an update that cannot install.
    final state = UpdateState.fromMap(const {
      'configured': true,
      'translocated': true,
    });
    expect(state.configured, isTrue);
    expect(state.canCheck, isFalse);
  });

  test('carries an error message through', () {
    final state = UpdateState.fromMap(const {
      'configured': false,
      'error': 'This build has no update feed.',
    });
    expect(state.error, 'This build has no update feed.');
    expect(state.canCheck, isFalse);
  });

  group('versionLabel', () {
    test('includes the build number when there is one', () {
      expect(
        UpdateState.fromMap(const {
          'currentVersion': '1.2.3',
          'currentBuild': '8',
        }).versionLabel,
        'Version 1.2.3 (build 8)',
      );
    });

    test('degrades without one', () {
      expect(
        UpdateState.fromMap(const {'currentVersion': '1.2.3'}).versionLabel,
        'Version 1.2.3',
      );
      expect(UpdateState.fromMap(const {}).versionLabel, 'Unknown version');
    });
  });

  test('equality covers every field, so notifyListeners is not spurious', () {
    const a = UpdateState(configured: true, currentVersion: '1.0.0');
    const b = UpdateState(configured: true, currentVersion: '1.0.0');
    const c = UpdateState(configured: true, currentVersion: '1.0.1');
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(c));
  });

  group('unavailableReason', () {
    test('is null when a check can actually run', () {
      expect(
        UpdateState.fromMap(const {'configured': true}).unavailableReason,
        isNull,
      );
    });

    test('translocation wins, because it is the one the user can fix', () {
      // Both conditions hold here; the actionable message must be the one
      // shown. "unavailable in this build" would send someone rebuilding when
      // all they need to do is drag the app to /Applications.
      expect(
        UpdateState.fromMap(const {
          'configured': false,
          'translocated': true,
        }).unavailableReason,
        'move to Applications first',
      );
    });

    test('an unconfigured build says so', () {
      expect(
        UpdateState.fromMap(const {'configured': false}).unavailableReason,
        'unavailable in this build',
      );
    });
  });
}
