import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../theme/app_theme.dart';

/// Wraps a preview in the app's real theme.
///
/// Previews render outside `main.dart`, so without this they would show
/// Material defaults and tell you nothing useful about spacing or colour.
Widget previewShell(Widget child, {bool dark = false}) => ShadApp(
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(body: Center(child: child)),
    );
