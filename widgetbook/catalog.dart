import 'package:widgetbook/widgetbook.dart';

import 'use_cases/components.dart';
import 'use_cases/first_run.dart';
import 'use_cases/project.dart';
import 'use_cases/settings.dart';
import 'use_cases/start.dart';
import 'use_cases/uninstall.dart';

/// Every screen and dialog in App Studio, in the order a user meets them.
///
/// `test/widgetbook/catalog_test.dart` builds every use case in here, in both
/// themes, so one that no longer compiles or throws on build fails CI instead
/// of being found the next time someone opens Widgetbook.
final List<WidgetbookNode> catalog = [
  firstRunFolder,
  startFolder,
  projectFolder,
  settingsFolder,
  uninstallFolder,
  componentsFolder,
];
