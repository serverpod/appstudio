import 'package:appstudio/toolchain/tool_version.dart';
import 'package:flutter_test/flutter_test.dart';

ToolVersion v(String s) => ToolVersion.tryParse(s)!;

void main() {
  group('parse', () {
    test('reads the versions this project actually pins', () {
      expect(v('3.44.2').toString(), '3.44.2');
      expect(v('4.0.0-beta.1').toString(), '4.0.0-beta.1');
      expect(v('2.53.0-3').toString(), '2.53.0-3');
      expect(v('1.18.4').toString(), '1.18.4');
    });

    test('fills in missing components and tolerates a leading v', () {
      expect(v('20.1').toString(), '20.1.0');
      expect(v('v2.53.0').toString(), '2.53.0');
    });

    test('ignores build metadata', () {
      expect(v('3.44.2+7'), v('3.44.2'));
    });

    test('returns null rather than throwing on garbage', () {
      for (final bad in [null, '', 'unknown', 'git version', 'x.y.z', '..']) {
        expect(ToolVersion.tryParse(bad), isNull, reason: 'input: $bad');
      }
    });
  });

  group('ordering', () {
    test('compares major, minor, then patch', () {
      expect(v('3.44.2') < v('3.45.0'), isTrue);
      expect(v('3.44.2') > v('3.44.1'), isTrue);
      expect(v('4.0.0') > v('3.99.99'), isTrue);
    });

    test('a prerelease is older than its release', () {
      expect(v('4.0.0-beta.1') < v('4.0.0'), isTrue);
      expect(v('4.0.0-beta.1') < v('4.0.0-beta.2'), isTrue);
      expect(v('4.0.0-alpha.9') < v('4.0.0-beta.1'), isTrue);
      expect(v('4.0.0-beta.1') < v('4.0.0-beta.1.1'), isTrue);
    });

    test('a numeric-only suffix is a packaging revision, so it is newer', () {
      // dugite: 2.53.0-3 is the third packaging of git 2.53.0. Treating it as a
      // semver prerelease would make `>=2.53.0` reject the artifact we ship.
      expect(v('2.53.0-3') > v('2.53.0'), isTrue);
      expect(v('2.53.0-3') < v('2.53.0-10'), isTrue);
      expect(v('2.53.0-3') < v('2.54.0'), isTrue);
    });

    test('a packaging revision outranks a prerelease of the same core', () {
      expect(v('2.53.0-3') > v('2.53.0-beta.1'), isTrue);
    });

    test('equality ignores representation', () {
      expect(v('3.44.2') == v('3.44.2'), isTrue);
      expect(v('3.44') == v('3.44.0'), isTrue);
      expect(v('3.44.2').hashCode, v('3.44.2').hashCode);
    });
  });

  group('VersionRange', () {
    test('accepts within a half-open window', () {
      final range = VersionRange.tryParse('>=3.44.0 <3.45.0')!;
      expect(range.allows(v('3.44.0')), isTrue);
      expect(range.allows(v('3.44.2')), isTrue);
      expect(range.allows(v('3.45.0')), isFalse);
      expect(range.allows(v('3.43.9')), isFalse);
    });

    test('the Serverpod minimum accepts the pin and rejects the host 3.5', () {
      final range = VersionRange.tryParse('>=4.0.0-beta.1 <4.1.0')!;
      expect(range.allows(v('4.0.0-beta.1')), isTrue);
      expect(range.allows(v('4.0.0')), isTrue);
      // What is actually installed on this machine today.
      expect(range.allows(v('3.5.0-beta.7')), isFalse);
      expect(range.allows(v('4.0.0-beta.0')), isFalse);
    });

    test('the loose git minimum accepts a dugite packaging revision', () {
      final range = VersionRange.tryParse('>=2.30.0')!;
      expect(range.allows(v('2.53.0')), isTrue);
      expect(range.allows(v('2.53.0-3')), isTrue);
      expect(range.allows(v('2.29.0')), isFalse);
    });

    test('an unknown version never satisfies a range', () {
      expect(VersionRange.tryParse('>=1.0.0')!.allows(null), isFalse);
    });

    test('empty and * accept anything', () {
      expect(VersionRange.tryParse('')!.allows(v('0.0.1')), isTrue);
      expect(VersionRange.tryParse('*')!.allows(v('99.0.0')), isTrue);
    });

    test('a malformed constraint is rejected, not silently permissive', () {
      // A typo in the manifest must fail loudly rather than accept everything.
      expect(VersionRange.tryParse('>=not.a.version'), isNull);
      expect(VersionRange.tryParse('>='), isNull);
    });

    test('exposes its minimum for UI copy', () {
      expect(
        VersionRange.tryParse('>=4.0.0-beta.1 <4.1.0')!.minimum.toString(),
        '4.0.0-beta.1',
      );
      expect(VersionRange.tryParse('<5.0.0')!.minimum, isNull);
    });

    test('round-trips its source text for display', () {
      expect(VersionRange.tryParse('>=3.44.0 <3.45.0').toString(),
          '>=3.44.0 <3.45.0');
    });
  });
}
