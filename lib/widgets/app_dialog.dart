import 'package:flutter/widgets.dart';
import 'package:shad/shad.dart';

/// `showShadDialog` on the nearest navigator — the one every dialog in App
/// Studio goes through.
///
/// shad defaults to the *root* navigator. In the app the two are the same,
/// since there is only the one `ShadApp` navigator. In Widgetbook they are not:
/// each screen is hosted under its own navigator inside Widgetbook's, so a
/// root push lands on Widgetbook itself — covering its controls, and outliving
/// the screen that opened it when the use case changes.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  double? barrierBlurSigma,
}) =>
    showShadDialog<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      barrierBlurSigma: barrierBlurSigma,
      useRootNavigator: false,
    );
