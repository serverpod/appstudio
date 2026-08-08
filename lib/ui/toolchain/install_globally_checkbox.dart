import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../theme/app_theme.dart';

/// The "put the tools on your PATH" opt-in, shared by first-run setup and
/// Settings → Tools.
///
/// One widget rather than the same two strings written twice: setup offers it
/// as an intent applied after the download, Settings binds it to the state of
/// the shell config, and only the wiring differs.
class InstallGloballyCheckbox extends StatelessWidget {
  const InstallGloballyCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final bool value;

  /// Null while a write is in flight.
  final ValueChanged<bool>? onChanged;

  /// False greys it out. Passed as well as a null [onChanged], never instead:
  /// shad dims from this flag alone, so a null handler by itself leaves a
  /// control that is inert but still looks live.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ShadCheckbox(
      value: value,
      enabled: enabled,
      onChanged: enabled ? onChanged : null,
      label: Text('Install tools globally', style: kWeightMedium),
      sublabel: const Text(
        'You need to install the tools globally to use external AI agents '
        'together with App Studio.',
      ),
    );
  }
}
