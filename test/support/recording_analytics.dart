import 'package:appstudio/analytics/app_analytics.dart';

/// Keeps every payload handed to it, in order.
class RecordingTransport extends AnalyticsTransport {
  final payloads = <Map<String, Object?>>[];

  @override
  Future<void> send(Map<String, Object?> payload) async =>
      payloads.add(payload);

  /// Event names in the order they were captured.
  List<String> get events => [for (final p in payloads) p['event'] as String];

  Map<String, Object?> propertiesOf(int index) =>
      payloads[index]['properties'] as Map<String, Object?>;
}

const testAnalyticsContext = AnalyticsContext(
  appVersion: '1.2.3',
  appBuild: '45',
  platform: 'MacOS',
  osVersion: 'Version 15.5 (Build 24F74)',
  dartVersion: '3.12.0',
  isDebug: false,
);

/// A live [AppAnalytics] wired to a [RecordingTransport].
({AppAnalytics analytics, RecordingTransport transport}) recordingAnalytics({
  String? distinctId = 'user-1',
  bool enabled = true,
}) {
  final transport = RecordingTransport();
  return (
    analytics: AppAnalytics(
      transport: transport,
      context: testAnalyticsContext,
      distinctId: distinctId,
      enabled: enabled,
    ),
    transport: transport,
  );
}

/// Installs a recording sink as [appAnalytics] for one test and restores the
/// no-op one after, so nothing leaks between tests.
RecordingTransport installRecordingAnalytics({
  required void Function(void Function()) addTearDown,
}) {
  final (:analytics, :transport) = recordingAnalytics();
  installAppAnalytics(analytics);
  addTearDown(() => installAppAnalytics(AppAnalytics.disabled()));
  return transport;
}
