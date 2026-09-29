import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'analytics_transport.dart';
import 'analytics_user_id.dart';

export 'analytics_transport.dart';

/// The PostHog project the Serverpod CLIs report to — one key, one project,
/// so App Studio's events land beside `cli.*` and the cloud CLI's rather than
/// in a dashboard of their own.
const kPostHogProjectApiKey = 'phc_xGBPHgcrTrDuWGtyNX3UJODXgnR684rzRPZjWRlqVxf';

/// Set in the environment to send events from a debug build, which otherwise
/// sends nothing — see [AppAnalytics.create].
const kAnalyticsForceEnvVar = 'APPSTUDIO_ANALYTICS';

/// Facts stamped onto every event, gathered once at launch.
@immutable
class AnalyticsContext {
  const AnalyticsContext({
    required this.appVersion,
    required this.appBuild,
    required this.platform,
    required this.osVersion,
    required this.dartVersion,
    required this.isDebug,
  });

  /// Reads everything from the running process. [appVersion] and [appBuild]
  /// come from `Info.plist` via the updater, which already has them.
  factory AnalyticsContext.current({
    required String appVersion,
    required String appBuild,
  }) => AnalyticsContext(
    appVersion: appVersion,
    appBuild: appBuild,
    platform: _platformString(),
    osVersion: Platform.operatingSystemVersion,
    dartVersion: Platform.version,
    isDebug: !kReleaseMode,
  );

  final String appVersion;
  final String appBuild;

  /// `MacOS` / `Windows` / `Linux` — the same spelling `cli_tools` uses, so
  /// one PostHog filter covers the CLIs and the app.
  final String platform;
  final String osVersion;
  final String dartVersion;
  final bool isDebug;

  Map<String, Object?> toProperties() => {
    r'$lib': 'app_studio',
    r'$lib_version': appVersion,
    'app_version': appVersion,
    'app_build': appBuild,
    'platform': platform,
    'os_version': osVersion,
    'dart_version': dartVersion,
    'is_debug': isDebug,
  };

  static String _platformString() {
    if (Platform.isMacOS) return 'MacOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    return 'Unknown';
  }
}

/// Product analytics for App Studio, sent to PostHog as `app_studio.*` events.
///
/// Fire-and-forget: [capture] returns immediately, every send is swallowed on
/// failure, and nothing here is ever awaited on a user-visible path. Sends in
/// flight are tracked so a test can [flush] them; the app never does — a quit
/// must not wait on a network call.
///
/// Call sites reach it through [appAnalytics], which is a no-op until `main()`
/// installs the real one, the same shape the CLI's `cliAnalytics` takes. That
/// keeps `ProjectCreator` and friends free of an analytics parameter, and keeps
/// tests that construct them from ever sending anything.
class AppAnalytics {
  AppAnalytics({
    required this._transport,
    required this._context,
    required String? distinctId,
    this.enabled = true,
  }) // The CLIs also fall back to 'unknown' rather than dropping the event.
  : _distinctId = distinctId ?? 'unknown';

  /// Never sends anything. What [appAnalytics] is before installation.
  AppAnalytics.disabled()
    : _transport = _NoopTransport(),
      _context = const AnalyticsContext(
        appVersion: '',
        appBuild: '',
        platform: '',
        osVersion: '',
        dartVersion: '',
        isDebug: true,
      ),
      _distinctId = 'unknown',
      enabled = false;

  /// The production instance.
  ///
  /// Disabled in debug and profile builds so `make start` runs do not pollute
  /// the project — the CLI gates on `productionMode` for the same reason.
  /// Setting `APPSTUDIO_ANALYTICS=1` in the environment overrides that, which
  /// is how a change here is verified end to end.
  factory AppAnalytics.create({
    required String appVersion,
    required String appBuild,
  }) {
    final forced = Platform.environment[kAnalyticsForceEnvVar] == '1';
    return AppAnalytics(
      transport: PostHogTransport(projectApiKey: kPostHogProjectApiKey),
      context: AnalyticsContext.current(
        appVersion: appVersion,
        appBuild: appBuild,
      ),
      distinctId: readOrCreateAnalyticsUserId(),
      enabled: kReleaseMode || forced,
    );
  }

  final AnalyticsTransport _transport;
  final AnalyticsContext _context;
  final String _distinctId;
  final bool enabled;

  final _pending = <Future<void>>{};

  /// The id every event is sent under. Exposed for tests and diagnostics.
  String get distinctId => _distinctId;

  /// Queues [event] with [properties] on top of the launch-time context.
  ///
  /// Event-specific properties win over the context's on a key clash.
  void capture(String event, {Map<String, Object?> properties = const {}}) {
    if (!enabled) return;
    final payload = <String, Object?>{
      'event': event,
      'distinct_id': _distinctId,
      'properties': {..._context.toProperties(), ...properties},
    };
    late final Future<void> send;
    send = _transport
        .send(payload)
        .catchError((Object _) {})
        .whenComplete(() => _pending.remove(send));
    _pending.add(send);
  }

  /// Completes once every queued send has finished or failed.
  Future<void> flush() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }

  void close() => _transport.close();

  // ---- The events. One method each, so the property set is written once. --

  /// The app launched. [toolSources] is source by tool id — what proportion of
  /// users run on the managed toolchain versus tools already on the Mac.
  void appOpened({
    required bool toolchainSetupRequired,
    required Map<String, String> toolSources,
    required int recentProjectCount,
  }) => capture(
    'app_studio.app_opened',
    properties: {
      'toolchain_setup_required': toolchainSetupRequired,
      'tool_sources': toolSources,
      'recent_project_count': recentProjectCount,
    },
  );

  /// `serverpod create` ran from the New Project screen, successfully or not.
  /// [failureStage] is null on success.
  void projectCreated({
    required List<String> ides,
    required bool success,
    required Duration duration,
    String? failureStage,
  }) => capture(
    'app_studio.project_created',
    properties: {
      'ides': ides,
      'success': success,
      'duration_ms': duration.inMilliseconds,
      'failure_stage': failureStage,
    },
  );

  /// A project became the open one — from the picker, Open Recent, or right
  /// after being created.
  void projectOpened() => capture('app_studio.project_opened');
}

class _NoopTransport extends AnalyticsTransport {
  @override
  Future<void> send(Map<String, Object?> payload) async {}
}

AppAnalytics _appAnalytics = AppAnalytics.disabled();

/// The process-wide sink. Safe to call from anywhere at any time: it is a
/// no-op until [installAppAnalytics] runs.
AppAnalytics get appAnalytics => _appAnalytics;

/// Replaces the process-wide sink. `main()` installs the real one; tests
/// install a recording one and put the disabled one back after.
void installAppAnalytics(AppAnalytics analytics) {
  _appAnalytics = analytics;
}
