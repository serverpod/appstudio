import 'package:flutter/widgets.dart';
import 'package:shad/shad.dart';

/// Space between a dialog's last line of content and its buttons.
///
/// shadcn's dialog puts `gap-4` between its body and its footer. shad applies
/// a single `gap` between *every* part of a dialog instead — title,
/// description, content, buttons — and the nova preset sets it to 4, which is
/// right between a title and its description and far too tight above the
/// buttons.
const kDialogActionsSpacing = 16.0;

/// A dialog's content, with [kDialogActionsSpacing] before the buttons.
///
/// Every dialog passes its `child` through this — with no [child] at all when
/// it has only a title and a description — so the space above the buttons is
/// the same everywhere rather than whatever each dialog happened to add.
class DialogBody extends StatelessWidget {
  const DialogBody({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    // The dialog adds its own gap on each side of whatever it is given, so
    // that is subtracted to land on the same total either way.
    final gap = ShadTheme.of(context).alertDialogTheme.gap ?? 8;
    final child = this.child;
    if (child == null) {
      // Between description and buttons: gap, this, gap.
      return SizedBox(height: (kDialogActionsSpacing - 2 * gap).clamp(0, 99));
    }
    // Between content and buttons: this padding, then one gap.
    return Padding(
      padding: EdgeInsets.only(
        bottom: (kDialogActionsSpacing - gap).clamp(0, 99),
      ),
      child: child,
    );
  }
}
