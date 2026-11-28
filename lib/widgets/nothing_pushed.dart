import 'package:flutter/widgets.dart';

/// Whether [navigator] shows its first route alone, with nothing pushed over
/// it: no dialog, no full-screen route such as New Project. True before the
/// navigator exists, since nothing can be pushed over it yet.
bool nothingPushedOver(GlobalKey<NavigatorState> navigator) =>
    !(navigator.currentState?.canPop() ?? false);
