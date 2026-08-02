import 'dart:io';

import 'package:appstudio/util/pretty_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final home = Platform.environment['HOME'];

  test('folds the home directory to ~', () {
    if (home == null || home.isEmpty) return;
    expect(prettyPath(home), '~');
    expect(prettyPath('$home/Projects/app'), '~/Projects/app');
  });

  test('leaves paths outside home alone', () {
    expect(prettyPath('/usr/local/bin/dart'), '/usr/local/bin/dart');
  });

  test('does not fold a sibling directory that merely shares the prefix', () {
    if (home == null || home.isEmpty) return;
    // "/Users/viktor-backup" must not become "~-backup".
    expect(prettyPath('$home-backup/thing'), '$home-backup/thing');
  });
}
