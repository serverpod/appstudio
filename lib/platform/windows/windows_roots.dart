/// HTTPS on a fresh Windows.
///
/// Dart's TLS trusts the certificates in Windows' stores as they are when a
/// `SecurityContext` is made, and nothing more. Windows itself ships with few
/// roots and downloads the others it trusts the first time its own TLS needs
/// one. So on a fresh install Dart cannot reach GitHub — its root, USERTrust
/// ECC, is trusted but not downloaded yet — and setup fails at its first
/// step. Nor can the Dart tools App Studio starts: the Serverpod runner
/// downloads its Postgres from GitHub too.
///
/// The way round: when a handshake fails, hand the certificate to Windows to
/// build a chain for, which downloads the missing root into the store, then
/// connect again with a context made afterwards. Dart still does the
/// verifying; Windows only fills in a root it already trusts.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../host_platform.dart';
import 'win32_system.dart';
import 'windows_system.dart';

/// What App Studio and the tools it starts reach over HTTPS: GitHub for Git
/// for Windows and Postgres, Google for Flutter and pub, Maven for Postgres
/// on some versions.
const kWindowsRootHosts = [
  'api.github.com',
  'github.com',
  'release-assets.githubusercontent.com',
  'objects.githubusercontent.com',
  'storage.googleapis.com',
  'pub.dev',
  'repo1.maven.org',
];

const _connectTimeout = Duration(seconds: 15);

/// Has Windows download the root [host]'s certificate leads to, when it has
/// not yet. True when it was missing and Windows now trusts the chain; false
/// when Dart already trusted it, or the host could not be reached.
Future<bool> fetchWindowsRootFor(
  String host,
  WindowsSystem windows, {
  int port = 443,
}) async {
  X509Certificate? rejected;
  try {
    final socket = await SecureSocket.connect(
      host,
      port,
      // A fresh context: the default one read the store once, at first use.
      context: SecurityContext(withTrustedRoots: true),
      onBadCertificate: (cert) {
        rejected = cert;
        return false;
      },
      timeout: _connectTimeout,
    ).timeout(_connectTimeout);
    socket.destroy();
    return false;
  } on HandshakeException {
    // Below.
  } catch (_) {
    // Offline, or the host is down: nothing to learn about its root.
    return false;
  }
  final cert = rejected;
  if (cert == null) return false;
  final trusted = await windows.buildCertificateChain(cert.der);
  debugPrint('windows_roots: $host was untrusted; Windows '
      '${trusted ? 'fetched its root' : 'does not trust it either'}.');
  return trusted;
}

/// [fetchWindowsRootFor] for every host in [hosts], at once.
Future<bool> fetchWindowsRoots(
  WindowsSystem windows, [
  Iterable<String> hosts = kWindowsRootHosts,
]) async {
  final fetched = await Future.wait(
    hosts.map((host) => fetchWindowsRootFor(host, windows)),
  );
  return fetched.contains(true);
}

/// The client for App Studio's own lookups and downloads.
http.Client studioHttpClient(HostPlatform host) =>
    host.isWindows ? WindowsRootsClient() : http.Client();

/// An [http.Client] that gets past a root Windows has not downloaded yet: on
/// a failed handshake it has Windows fetch the roots, then sends the request
/// once more on a context made afterwards.
///
/// It resends whatever the fetch found. A root may have arrived since this
/// client's context was made — from the startup fetch in `main.dart`, which
/// runs alongside the first requests — and then the fetch finds nothing
/// missing, yet only a new context can see it. A certificate Windows does
/// not trust either simply fails again.
///
/// The failing host is not always the request's — a GitHub download
/// redirects to another host — so it fetches the roots for the known hosts
/// as well as the request's.
class WindowsRootsClient extends http.BaseClient {
  WindowsRootsClient({
    WindowsSystem? windows,
    @visibleForTesting Future<void> Function(Iterable<String> hosts)? fetchRoots,
    @visibleForTesting http.Client Function()? newClient,
  })  : _fetchRoots = fetchRoots ??
            ((hosts) => fetchWindowsRoots(windows ?? Win32System(), hosts)),
        _newClient = newClient ?? _ioClient;

  static http.Client _ioClient() =>
      IOClient(HttpClient(context: SecurityContext(withTrustedRoots: true)));

  final Future<void> Function(Iterable<String> hosts) _fetchRoots;
  final http.Client Function() _newClient;

  /// Made on first use, not with this client: the context reads the store
  /// then, and the later that is, the more of the roots it sees.
  http.Client? _client;
  http.Client get _inner => _client ??= _newClient();

  /// Replaced clients, closed with this one: a download may still be
  /// streaming through one.
  final _retired = <http.Client>[];

  /// Each host gets one go, so a host Windows cannot help with fails as it
  /// would have.
  final _tried = <String>{};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // A streamed body cannot be sent twice; every request here is a plain one.
    final again = request is http.Request ? _copy(request) : null;
    try {
      return await _inner.send(request);
    } on HandshakeException {
      final host = request.url.host;
      if (again == null || !_tried.add(host)) rethrow;
      await _fetchRoots({host, ...kWindowsRootHosts});
      _retired.add(_inner);
      _client = _newClient();
      return _inner.send(again);
    }
  }

  static http.Request _copy(http.Request request) =>
      http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..persistentConnection = request.persistentConnection
        ..bodyBytes = request.bodyBytes;

  @override
  void close() {
    for (final client in _retired) {
      client.close();
    }
    _client?.close();
  }
}
