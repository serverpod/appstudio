import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../theme/app_theme.dart';

/// Bold caption above a form field.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Text(text, style: theme.textTheme.small.semibold);
  }
}
