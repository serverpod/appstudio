import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shad/shad.dart';

import '../theme/app_theme.dart';

/// Alert shown over the preview when the server logs a sign-up code.
///
/// Stays put until a new code arrives or the user dismisses it — signing up
/// means switching to the server log to read the code otherwise.
class RegistrationCodeToast extends StatefulWidget {
  const RegistrationCodeToast({
    super.key,
    required this.code,
    required this.onDismiss,
  });

  final String code;
  final VoidCallback onDismiss;

  @override
  State<RegistrationCodeToast> createState() => _RegistrationCodeToastState();
}

class _RegistrationCodeToastState extends State<RegistrationCodeToast> {
  static const _copiedFeedback = Duration(seconds: 2);

  bool _copied = false;
  Timer? _copiedTimer;

  @override
  void didUpdateWidget(covariant RegistrationCodeToast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code) {
      _copiedTimer?.cancel();
      _copied = false;
    }
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(_copiedFeedback, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    // The preview behind the toast is dark in both shell themes, so the default
    // border disappears there — outline it in white instead.
    final borderColor = theme.brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.65)
        : scheme.border;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.card,
          borderRadius: theme.radii.lg,
          border: Border.all(color: borderColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              Icon(
                LucideIcons.mail,
                size: 16,
                color: scheme.foreground,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: 'Registration code ',
                    children: [
                      TextSpan(
                        text: widget.code,
                        style: TextStyle(
                          fontFamily: kMacMonoFont,
                          fontWeight: FontWeight.w600,
                          color: scheme.foreground,
                        ),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.small.copyWith(
                    fontSize: 13,
                    color: scheme.foreground,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: _copy,
                leading: Icon(
                  _copied ? LucideIcons.check : LucideIcons.copy,
                  size: 14,
                ),
                child: Text(_copied ? 'Copied' : 'Copy'),
              ),
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: widget.onDismiss,
                child: const Icon(LucideIcons.x, size: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
