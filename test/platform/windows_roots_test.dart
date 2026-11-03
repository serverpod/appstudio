import 'dart:io';

import 'package:appstudio/platform/windows/windows_roots.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('WindowsRootsClient', () {
    late List<Iterable<String>> fetched;
    late List<http.Request> sent;
    late int made;

    /// Each new inner client fails its handshakes while [failing] says so.
    WindowsRootsClient client({required bool Function(int clientIndex) failing}) {
      fetched = [];
      sent = [];
      made = 0;
      return WindowsRootsClient(
        fetchRoots: (hosts) async => fetched.add(hosts),
        newClient: () {
          final index = made++;
          return MockClient((request) async {
            sent.add(request);
            if (failing(index)) {
              throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
            }
            return http.Response('ok $index', 200);
          });
        },
      );
    }

    test('passes a request straight through when the handshake works',
        () async {
      final c = client(failing: (_) => false);
      final response = await c.get(Uri.parse('https://api.github.com/x'));
      expect(response.body, 'ok 0');
      expect(fetched, isEmpty);
    });

    test('makes its context on first use, not when it is made', () async {
      final c = client(failing: (_) => false);
      expect(made, 0);
      await c.get(Uri.parse('https://api.github.com/x'));
      expect(made, 1);
    });

    test('fetches the roots and resends on a fresh client', () async {
      final c = client(failing: (index) => index == 0);
      final response = await c.post(
        Uri.parse('https://api.github.com/x'),
        headers: {'Accept': 'application/vnd.github+json'},
        body: 'payload',
      );
      expect(response.body, 'ok 1');
      expect(fetched.single, containsAll(['api.github.com', 'github.com']));
      expect(sent, hasLength(2));
      expect(sent.last.headers['Accept'], 'application/vnd.github+json');
      expect(sent.last.body, 'payload');
    });

    test('resends when the root arrived before the fetch looked', () async {
      // The startup fetch got there first: this fetch finds nothing missing,
      // but the old context still cannot see the root.
      final c = WindowsRootsClient(
        fetchRoots: (_) async {},
        newClient: () {
          final index = made++;
          return MockClient((request) async {
            if (index == 0) {
              throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
            }
            return http.Response('ok $index', 200);
          });
        },
      );
      made = 0;
      final response = await c.get(Uri.parse('https://github.com/x'));
      expect(response.body, 'ok 1');
    });

    test('also fetches for the hosts a redirect may lead to', () async {
      final c = client(failing: (index) => index == 0);
      await c.get(Uri.parse('https://example.com/'));
      expect(fetched.single, contains('example.com'));
      expect(fetched.single,
          contains('release-assets.githubusercontent.com'));
    });

    test('rethrows when the fresh client fails too', () async {
      final c = client(failing: (_) => true);
      await expectLater(
        c.get(Uri.parse('https://api.github.com/x')),
        throwsA(isA<HandshakeException>()),
      );
      expect(sent, hasLength(2));
    });

    test('gives each host one go', () async {
      final c = client(failing: (_) => true);
      await expectLater(c.get(Uri.parse('https://api.github.com/x')),
          throwsA(isA<HandshakeException>()));
      await expectLater(c.get(Uri.parse('https://api.github.com/y')),
          throwsA(isA<HandshakeException>()));
      expect(fetched, hasLength(1));
      // The first request, its one resend, and the second request.
      expect(sent, hasLength(3));
    });
  });
}
