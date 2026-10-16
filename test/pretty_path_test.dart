import 'package:appstudio/util/pretty_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('a macOS home', () {
    const home = '/Users/viktor';

    test('folds the home directory to ~', () {
      expect(prettyPath(home, home: home), '~');
      expect(prettyPath('$home/Projects/app', home: home), '~/Projects/app');
    });

    test('leaves paths outside home alone', () {
      expect(
        prettyPath('/usr/local/bin/dart', home: home),
        '/usr/local/bin/dart',
      );
    });

    test('does not fold a sibling directory that merely shares the prefix', () {
      // "/Users/viktor-backup" must not become "~-backup".
      expect(
        prettyPath('$home-backup/thing', home: home),
        '$home-backup/thing',
      );
    });

    test('is case-sensitive, as the path is', () {
      expect(
        prettyPath('/users/viktor/Projects', home: home),
        '/users/viktor/Projects',
      );
    });
  });

  group('a Windows home', () {
    const home = r'C:\Users\viktor';

    test('folds the home directory with its own separator', () {
      expect(prettyPath(home, home: home), '~');
      expect(
        prettyPath(r'C:\Users\viktor\Projects\app', home: home),
        r'~\Projects\app',
      );
    });

    test('matches regardless of case, as Windows does', () {
      expect(
        prettyPath(r'c:\users\VIKTOR\Projects', home: home),
        r'~\Projects',
      );
    });

    test('does not fold a sibling directory that merely shares the prefix', () {
      expect(
        prettyPath(r'C:\Users\viktor-backup\x', home: home),
        r'C:\Users\viktor-backup\x',
      );
    });
  });
}
