import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:appstudio/analytics/app_analytics.dart';

import '../support/recording_analytics.dart';

void main() {
  group('AppAnalytics.capture', () {
    test(
      'sends the event under the distinct id with the context stamped on',
      () async {
        final (:analytics, :transport) = recordingAnalytics();
        analytics.capture('app_studio.test', properties: {'answer': 42});
        await analytics.flush();

        expect(transport.payloads, hasLength(1));
        final payload = transport.payloads.single;
        expect(payload['event'], 'app_studio.test');
        expect(payload['distinct_id'], 'user-1');
        expect(transport.propertiesOf(0), {
          r'$lib': 'app_studio',
          r'$lib_version': '1.2.3',
          'app_version': '1.2.3',
          'app_build': '45',
          'platform': 'MacOS',
          'os_version': 'Version 15.5 (Build 24F74)',
          'dart_version': '3.12.0',
          'is_debug': false,
          'answer': 42,
        });
      },
    );

    test('event properties win over the context on a clash', () async {
      final (:analytics, :transport) = recordingAnalytics();
      analytics.capture('e', properties: {'platform': 'Other'});
      await analytics.flush();
      expect(transport.propertiesOf(0)['platform'], 'Other');
    });

    test('falls back to "unknown" when no user id could be stored', () async {
      final (:analytics, :transport) = recordingAnalytics(distinctId: null);
      analytics.capture('e');
      await analytics.flush();
      expect(transport.payloads.single['distinct_id'], 'unknown');
    });

    test('sends nothing while disabled', () async {
      final (:analytics, :transport) = recordingAnalytics(enabled: false);
      analytics.capture('e');
      analytics.appOpened(
        toolchainSetupRequired: false,
        toolSources: const {},
        recentProjectCount: 0,
      );
      await analytics.flush();
      expect(transport.payloads, isEmpty);
    });

    test(
      'a failing transport is swallowed and does not stop later sends',
      () async {
        final transport = _FlakyTransport();
        final analytics = AppAnalytics(
          transport: transport,
          context: testAnalyticsContext,
          distinctId: 'u',
        );
        analytics.capture('first'); // throws inside the transport
        analytics.capture('second');
        await analytics.flush();
        expect(transport.attempted, ['first', 'second']);
      },
    );

    test('the default sink is disabled until one is installed', () async {
      expect(appAnalytics.enabled, isFalse);
      final transport = installRecordingAnalytics(addTearDown: addTearDown);
      appAnalytics.projectOpened();
      await appAnalytics.flush();
      expect(transport.events, ['app_studio.project_opened']);
    });
  });

  group('event methods', () {
    test('appOpened carries the launch facts', () async {
      final (:analytics, :transport) = recordingAnalytics();
      analytics.appOpened(
        toolchainSetupRequired: true,
        toolSources: const {'flutter': 'managed', 'git': 'host'},
        recentProjectCount: 3,
      );
      await analytics.flush();
      expect(transport.events, ['app_studio.app_opened']);
      final props = transport.propertiesOf(0);
      expect(props['toolchain_setup_required'], isTrue);
      expect(props['tool_sources'], {'flutter': 'managed', 'git': 'host'});
      expect(props['recent_project_count'], 3);
    });

    test('projectCreated reports the stage only on failure', () async {
      final (:analytics, :transport) = recordingAnalytics();
      analytics.projectCreated(
        ides: const ['cursor', 'vscode'],
        success: true,
        duration: const Duration(seconds: 90),
      );
      analytics.projectCreated(
        ides: const [],
        success: false,
        duration: const Duration(milliseconds: 10),
        failureStage: 'cli',
      );
      await analytics.flush();
      expect(transport.events, [
        'app_studio.project_created',
        'app_studio.project_created',
      ]);
      expect(transport.propertiesOf(0), containsPair('success', true));
      expect(transport.propertiesOf(0), containsPair('failure_stage', null));
      expect(transport.propertiesOf(0), containsPair('duration_ms', 90000));
      expect(
        transport.propertiesOf(0),
        containsPair('ides', ['cursor', 'vscode']),
      );
      expect(transport.propertiesOf(1), containsPair('success', false));
      expect(transport.propertiesOf(1), containsPair('failure_stage', 'cli'));
    });
  });

  group('PostHogTransport', () {
    test('posts the CLI-shaped body to /capture/ on the EU host', () async {
      http.Request? seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response('{"status":1}', 200);
      });
      final transport = PostHogTransport(
        projectApiKey: 'phc_test',
        client: client,
      );
      await transport.send({
        'event': 'e',
        'distinct_id': 'u',
        'properties': {'a': 1},
      });

      expect(seen, isNotNull);
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://eu.i.posthog.com/capture/');
      expect(seen!.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(seen!.body), {
        'api_key': 'phc_test',
        'event': 'e',
        'distinct_id': 'u',
        'properties': {'a': 1},
      });
    });

    test('gives up after the timeout', () async {
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return http.Response('', 200);
      });
      final transport = PostHogTransport(
        projectApiKey: 'k',
        client: client,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        transport.send({'event': 'e'}),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}

class _FlakyTransport extends AnalyticsTransport {
  final attempted = <String>[];

  @override
  Future<void> send(Map<String, Object?> payload) async {
    attempted.add(payload['event'] as String);
    if (payload['event'] == 'first') throw StateError('network down');
  }
}
