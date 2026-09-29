import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/theme/theme_controller.dart';
import 'package:appstudio/toolchain/toolchain.dart';

import 'support/toolchain_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('ThemeController cycles modes', () async {
    final controller = ThemeController();
    expect(controller.mode.name, 'system');
    await controller.cycle();
    expect(controller.mode.name, 'light');
    await controller.cycle();
    expect(controller.mode.name, 'dark');
    await controller.cycle();
    expect(controller.mode.name, 'system');
  });

  test('ProjectSession preview URI is fixed', () {
    expect(ProjectSession.previewUri.port, 9998);
  });

  test('Toolchain badge label is never empty', () async {
    final toolchain = await Toolchain.resolve(manifest: await loadTestManifest());
    expect(toolchain.badgeLabel, isNotEmpty);
  });
}
