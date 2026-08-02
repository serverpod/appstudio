import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Bold caption above a form field.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Text(
      text,
      style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600),
    );
  }
}
