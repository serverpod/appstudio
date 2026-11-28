import 'package:xml/xml.dart';

import '../../platform/linux/app_version.dart';

/// The Sparkle namespace the appcast's enclosure attributes live in.
const kSparkleNamespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle';

/// The `sparkle:os` value of a Linux AppImage in the feed.
const kLinuxAppcastOs = 'linux-x86_64';

/// Whether [url] may carry an update: https, or plain http to this machine
/// (`localhost`, `127/8`, `::1`) or a private IPv4 network (`10/8`,
/// `172.16/12`, `192.168/16`), which only a development build's local feed
/// uses. `tool/linux/build_appimage.sh` and `appcast.sh` apply the same
/// rule. The signature covers the file, not the feed: over plain http
/// on a real network, anyone between could serve an older signed build as
/// a newer one.
bool isSecureUpdateUrl(Uri url) {
  if (url.scheme == 'https') return url.host.isNotEmpty;
  if (url.scheme != 'http') return false;
  final host = url.host;
  if (host == 'localhost' || host == '::1') return true;
  // Dotted decimal only: a leading zero (`0127.0.0.1`) means octal to the
  // resolver, which would make it a public address this check never saw.
  final octet = r'(0|[1-9][0-9]{0,2})';
  if (!RegExp('^$octet(\\.$octet){3}\$').hasMatch(host)) return false;
  final parts = host.split('.').map(int.parse).toList();
  if (parts.any((n) => n > 255)) return false;
  final [a, b, _, _] = parts;
  return a == 127 ||
      a == 10 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168);
}

/// One release in the appcast: where to download it and how to check it.
class AppcastItem {
  const AppcastItem({
    required this.version,
    required this.url,
    required this.length,
    required this.signature,
  });

  /// `sparkle:shortVersionString` and `sparkle:version` (the build number).
  final AppVersion version;
  final Uri url;

  /// The file's size in bytes, checked before the signature.
  final int length;

  /// `sparkle:edSignature`: Ed25519 over the whole file, base64.
  final String signature;
}

/// The newest Linux release in [feed] with a build above [current], or null
/// when there is none. An item that is not for Linux, or that lacks anything
/// a download needs, is skipped: a feed may carry items this build cannot
/// read. Throws [FormatException] when [feed] is not an appcast at all.
AppcastItem? newestUpdate(String feed, {required int current}) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(feed);
  } on XmlException catch (e) {
    throw FormatException('The update feed is not valid XML: ${e.message}');
  }
  final channel = document.findAllElements('channel').firstOrNull;
  if (channel == null) {
    throw const FormatException('The update feed has no <channel>.');
  }
  AppcastItem? newest;
  for (final item in channel.findElements('item')) {
    final parsed = _parse(item);
    if (parsed == null || parsed.version.build <= current) continue;
    if (newest == null || parsed.version.build > newest.version.build) {
      newest = parsed;
    }
  }
  return newest;
}

/// What a version may look like: `0.4.2`, `1.0.0-beta.1`. The feed is not
/// signed, only the file is, and the version is written into the app menu's
/// entry, so anything else (a newline above all) is refused rather than
/// escaped.
final _versionPattern = RegExp(r'^[0-9A-Za-z][0-9A-Za-z.+-]{0,63}$');

AppcastItem? _parse(XmlElement item) {
  final enclosure = item.findElements('enclosure').firstOrNull;
  if (enclosure == null) return null;
  String? sparkle(String name) =>
      enclosure.getAttribute(name, namespaceUri: kSparkleNamespace) ??
      // Older feeds put them on the item as elements.
      item
          .findElements(name, namespaceUri: kSparkleNamespace)
          .firstOrNull
          ?.innerText;

  if (sparkle('os') != kLinuxAppcastOs) return null;
  final build = int.tryParse(sparkle('version') ?? '');
  final version = sparkle('shortVersionString');
  final url = Uri.tryParse(enclosure.getAttribute('url') ?? '');
  final length = int.tryParse(enclosure.getAttribute('length') ?? '');
  final signature = sparkle('edSignature');
  if (build == null ||
      version == null ||
      !_versionPattern.hasMatch(version) ||
      url == null ||
      !url.hasScheme ||
      length == null ||
      length <= 0 ||
      signature == null ||
      signature.isEmpty) {
    return null;
  }
  return AppcastItem(
    version: AppVersion(version, build),
    url: url,
    length: length,
    signature: signature,
  );
}
