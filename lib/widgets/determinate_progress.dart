import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../util/byte_format.dart';

/// Progress bar with an optional caption underneath.
///
/// Falls back to the indeterminate bar when [fraction] is null, so a caller
/// that cannot compute a ratio yet (verifying, extracting) needs no branch.
class DeterminateProgress extends StatelessWidget {
  const DeterminateProgress({
    super.key,
    required this.fraction,
    this.caption,
  });

  /// 0..1, or null while the total is unknown.
  final double? fraction;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final value = fraction?.clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ShadProgress(value: value, minHeight: 3),
        if (caption != null && caption!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              caption!,
              style: theme.textTheme.muted.copyWith(fontSize: 11),
            ),
          ),
        ],
      ],
    );
  }
}

/// `"412 MB of 980 MB · 2 min left"`, dropping any part that is unknown.
String formatTransferCaption({
  required int received,
  required int total,
  Duration? eta,
}) {
  final parts = <String>[
    if (total > 0)
      '${formatBytes(received)} of ${formatBytes(total)}'
    else
      formatBytes(received),
    if (eta != null) '${formatDuration(eta)} left',
  ];
  return parts.join(' · ');
}

/// Coarse remaining-time label — seconds below a minute, then whole minutes.
String formatDuration(Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds < 60) return '${seconds < 1 ? 1 : seconds} sec';
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '$minutes min';
  final hours = duration.inHours;
  final remainder = minutes - hours * 60;
  return remainder == 0 ? '$hours hr' : '$hours hr $remainder min';
}
