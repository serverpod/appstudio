import 'package:appstudio/platform/linux/app_version.dart';
import 'package:appstudio/update/linux/appcast.dart';
import 'package:flutter_test/flutter_test.dart';

/// A feed with [items] in its channel.
String feed(String items, {String prefix = 'sparkle'}) =>
    '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:$prefix="$kSparkleNamespace">
  <channel>
    <title>App Studio</title>
    $items
  </channel>
</rss>
''';

String item({
  int build = 26,
  String version = '0.4.2',
  String os = 'linux-x86_64',
  String? length = '100',
  String? signature = 'c2ln',
  String url = 'https://example.com/AppStudio-0.4.2-x86_64.AppImage',
  String prefix = 'sparkle',
}) =>
    '''
<item>
  <enclosure url="$url"
    $prefix:version="$build"
    $prefix:shortVersionString="$version"
    $prefix:os="$os"
    ${signature == null ? '' : '$prefix:edSignature="$signature"'}
    ${length == null ? '' : 'length="$length"'}
    type="application/octet-stream" />
</item>''';

void main() {
  test('picks the newest Linux item above the running build', () {
    final update = newestUpdate(
      feed(
        item(build: 26, version: '0.4.2') +
            item(build: 28, version: '0.4.4') +
            item(build: 27, version: '0.4.3'),
      ),
      current: 25,
    )!;

    expect(update.version.version, '0.4.4');
    expect(update.version.build, 28);
    expect(update.length, 100);
    expect(update.signature, 'c2ln');
    expect(update.url.host, 'example.com');
  });

  test('says nothing when the running build is the newest', () {
    expect(newestUpdate(feed(item(build: 25)), current: 25), isNull);
    expect(newestUpdate(feed(item(build: 24)), current: 25), isNull);
    expect(newestUpdate(feed(''), current: 25), isNull);
  });

  test('leaves out items for other systems', () {
    expect(
      newestUpdate(
        feed(item(build: 30, os: 'windows-x64') + item(build: 31, os: 'macos')),
        current: 25,
      ),
      isNull,
    );
  });

  test('leaves out items it could not download or check', () {
    final update = newestUpdate(
      feed(
        item(build: 30, signature: null) +
            item(build: 31, length: null) +
            item(build: 32, length: '0') +
            item(build: 33, url: 'not a url') +
            item(build: 26),
      ),
      current: 25,
    );
    expect(update!.version.build, 26);
  });

  test('leaves out an item whose version is not a version', () {
    // The feed is not signed and the version ends up in the app menu's
    // entry, where a line break would start a key of its own.
    final update = newestUpdate(
      feed(
        item(build: 30, version: '0.4.3&#10;Exec=/tmp/x') +
            item(build: 31, version: '') +
            item(build: 32, version: '0.4.5 beta') +
            item(build: 26, version: '0.4.2-beta.1'),
      ),
      current: 25,
    );
    expect(update!.version, const AppVersion('0.4.2-beta.1', 26));
  });

  test('reads the namespace, not the prefix', () {
    final update = newestUpdate(
      feed(item(prefix: 'sp'), prefix: 'sp'),
      current: 25,
    );
    expect(update!.version.build, 26);
  });

  test('only https carries an update, or http to a local address', () {
    for (final ok in [
      'https://asdl.serverpod.dev/appcast/linux/appcast.xml',
      'http://localhost:8000/appcast.xml',
      'http://127.0.0.1/a',
      'http://192.168.122.1:8000/a',
      'http://10.0.0.2/a',
      'http://172.20.1.1/a',
      'http://[::1]:8000/a',
      'HTTPS://asdl.serverpod.dev/a',
    ]) {
      expect(isSecureUpdateUrl(Uri.parse(ok)), isTrue, reason: ok);
    }
    for (final bad in [
      'http://asdl.serverpod.dev/appcast.xml',
      'http://172.32.0.1/a',
      'http://8.8.8.8/a',
      'ftp://example.com/a',
      'file:///home/alex/a',
      'https:///nohost',
      // Octal to the resolver: 87.0.0.1, a public address.
      'http://0127.0.0.1/a',
      'http://169.254.1.1/a',
      'http://[fe80::1]/a',
    ]) {
      expect(isSecureUpdateUrl(Uri.parse(bad)), isFalse, reason: bad);
    }
  });

  test('a feed that is not an appcast is an error', () {
    expect(
      () => newestUpdate('<html>', current: 25),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => newestUpdate('<rss></rss>', current: 25),
      throwsA(isA<FormatException>()),
    );
  });
}
