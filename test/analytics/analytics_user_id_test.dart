import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:appstudio/analytics/analytics_user_id.dart';

final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('appstudio_uuid_');
  });

  tearDown(() async {
    await home.delete(recursive: true);
  });

  File uuidFile() => File(p.join(home.path, '.serverpod', 'uuid'));

  test('creates ~/.serverpod/uuid with a v4 id and reads it back', () {
    final created = readOrCreateAnalyticsUserId(home: home.path);
    expect(created, matches(_uuidV4));
    expect(uuidFile().readAsStringSync(), created);

    expect(readOrCreateAnalyticsUserId(home: home.path), created);
  });

  test('reuses an id the CLI wrote, ignoring surrounding whitespace', () {
    uuidFile().createSync(recursive: true);
    uuidFile().writeAsStringSync('4f2a0a1c-1d2e-4f3a-8b4c-5d6e7f8a9b0c\n');
    expect(
      readOrCreateAnalyticsUserId(home: home.path),
      '4f2a0a1c-1d2e-4f3a-8b4c-5d6e7f8a9b0c',
    );
  });

  test('returns null when the id cannot be written', () {
    // A *file* where the directory should be makes the create fail.
    File(p.join(home.path, '.serverpod')).writeAsStringSync('');
    expect(readOrCreateAnalyticsUserId(home: home.path), isNull);
  });

  test('generateUuidV4 sets the version and variant bits', () {
    final rng = Random(1);
    for (var i = 0; i < 50; i++) {
      expect(generateUuidV4(random: rng), matches(_uuidV4));
    }
  });
}
