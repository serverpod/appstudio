import 'package:appstudio/agent/agent_controller.dart';
import 'package:appstudio/platform/macos_app_menu.dart';
import 'package:appstudio/process/serverpod_process.dart';
import 'package:appstudio/runner/runner_protocol.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/theme/theme_controller.dart';
import 'package:appstudio/ui/server_log/log_view_controller.dart';
import 'package:appstudio/ui/server_log/server_log_view.dart';
import 'package:flutter/services.dart';
import 'package:mac_menu_bar/mac_menu_bar_method_channel.dart';
import 'package:mac_menu_bar/mac_menu_bar_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/toolchain_support.dart';

/// The menu bar through its channel: every call `mac_menu_bar` makes is
/// recorded, and a click arrives the way AppKit sends one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mac_menu_bar');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late LogViewController logView;
  late ServerpodProcessController process;
  late MacAppMenu menu;
  var migrations = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    migrations = 0;
    // Tests run as Android, where the plugin picks its no-op implementation.
    MacMenuBarPlatform.instance = MethodChannelMacMenuBar();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final toolchains = await emptyToolchainController();
    final session = ProjectSession();
    process = ServerpodProcessController(
      toolchains: toolchains,
      session: session,
      dependencies: (_, _, _) async {},
    );
    logView = LogViewController();
    menu = MacAppMenu(
      session: session,
      process: process,
      agent: AgentController(
        toolchains: toolchains,
        session: session,
        process: process,
      ),
      themeController: ThemeController(),
      onNewProject: () {},
      onCheckForUpdates: () {},
      onUninstall: () {},
      canCheckForUpdates: () => false,
      updatesUnavailableReason: () => null,
      onSetAutomaticUpdates: (_) {},
      automaticUpdatesEnabled: () => false,
      canOpenProjects: () => true,
      onCreateAndApplyMigrations: () => migrations++,
      onCreateRepairMigration: () {},
      logView: logView,
    );
    await menu.install();
  });

  tearDown(() {
    menu.dispose();
    process.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> click(String itemId) async {
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        MethodCall('onMenuItemSelected', {'itemId': itemId}),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  Map<Object?, Object?> added(String itemId) => calls
      .where((c) => c.method == 'addMenuItem' || c.method == 'addSubmenu')
      .map((c) => c.arguments as Map<Object?, Object?>)
      .firstWhere(
        (a) => a['itemId'] == itemId || a['submenuId'] == itemId,
        orElse: () => fail('$itemId was never added'),
      );

  test('Server and Logs sit between View and Window', () {
    expect(added('server')['title'], 'Server');
    expect(added('server')['index'], 4);
    expect(added('logs')['title'], 'Logs');
    expect(added('logs')['index'], 5);
  });

  test('the restarts and migrations carry their shortcuts', () {
    String describe(String id) {
      final args = added(id);
      final mods = [...args['keyModifiers']! as List]..sort();
      return '$mods ${args['keyEquivalent']}';
    }

    expect(describe('server_hot_restart'), '[command] r');
    expect(describe('server_full_restart'), '[command, shift] r');
    expect(describe('server_migrate'), '[command] m');
    expect(describe('logs_toggle'), '[command] l');
    expect(added('server_migrate')['title'], 'Create and Apply Migrations');
  });

  test('Create and Apply Migrations is routed to its command', () async {
    await click('server_migrate');
    expect(migrations, 1);
  });

  test('the level items set the level, named as the levels are', () async {
    expect(
      [
        for (final level in LogLevelFilter.values)
          added('logs_level_${level.name}')['title'],
      ],
      ['Debug', 'Info', 'Warning', 'Error'],
    );

    await click('logs_level_warning');

    expect(logView.level, LogLevelFilter.warning);
  });

  test('a Flutter app gets an item, and picking it shows its log', () async {
    process.log.applySnapshot(
      const RunnerSnapshot(
        stage: RunnerStage.running,
        flutterApps: [FlutterAppConfig(id: 'demo', name: 'Demo app')],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(added('logs_source_app_0')['title'], 'Demo app');

    logView.visible = false;
    await click('logs_source_app_0');

    expect(logView.tab, const LogTab(AppLogSource('demo')));
    expect(logView.visible, isTrue, reason: 'picking a log opens the panel');

    await click('logs_source_server');
    expect(logView.tab, LeftPaneTab.server);
  });

  test('Show/Hide Logs needs a project to show the logs of', () async {
    expect(logView.visible, isFalse, reason: 'the panel starts hidden');
    await click('logs_toggle');
    expect(logView.visible, isFalse);
  });
}
