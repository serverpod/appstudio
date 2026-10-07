import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../runner/server_status.dart';
import '../theme/app_theme.dart';

/// The server's state at the left of the toolbar: a green dot while it runs, a
/// red square while it is stopped, a spinner while it is coming up or doing
/// something — beside the latest thing it said.
///
/// It took the place of the project's name and path. The runner's own words
/// ("Compiling server", "Launching Demo app") answer the question a user has
/// during a two-minute cold start, which the path never did.
///
/// With [showMessage] off it is the mark alone, for the compact window's
/// control bar, where there is no room for a line of text; the message moves
/// to its tooltip.
class ServerStatusIndicator extends StatefulWidget {
  const ServerStatusIndicator({
    super.key,
    required this.status,
    this.showMessage = true,
  });

  final ServerStatusView status;
  final bool showMessage;

  @override
  State<ServerStatusIndicator> createState() => _ServerStatusIndicatorState();
}

class _ServerStatusIndicatorState extends State<ServerStatusIndicator> {
  Timer? _recheck;

  @override
  void initState() {
    super.initState();
    widget.status.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant ServerStatusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      oldWidget.status.removeListener(_changed);
      widget.status.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _recheck?.cancel();
    widget.status.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status.serverStatus;

    // An operation too young to show is looked at again once it is not.
    _recheck?.cancel();
    if (status.settlesIn case final wait?) {
      _recheck = Timer(wait + const Duration(milliseconds: 20), _changed);
    }

    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final mark = switch (status.kind) {
      ServerStatusKind.running => Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: scheme.success,
            shape: BoxShape.circle,
          ),
        ),
      ServerStatusKind.stopped => Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: scheme.destructive,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ServerStatusKind.busy => const ShadSpinner(size: 12),
    };

    final markBox = SizedBox(width: 14, height: 14, child: Center(child: mark));
    final Widget content = widget.showMessage
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              markBox,
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  status.message,
                  key: const ValueKey('server-status-message'),
                  style: theme.textTheme.small.medium,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          )
        : markBox;

    // The tooltip carries whatever the line does not: the reason behind a
    // failure, and — mark only — the message itself.
    final tooltip = [
      if (!widget.showMessage) status.message,
      ?status.detail,
    ].join('\n');
    return Semantics(
      label: 'Server: ${status.message}',
      child: tooltip.isEmpty
          ? content
          : ShadTooltip(
              builder: (context) => ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(tooltip),
              ),
              child: ShadGestureDetector(child: content),
            ),
    );
  }
}
