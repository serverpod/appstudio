/// How every use case is put on screen: inside the app's own `ShadApp`, one
/// screen or one dialog at a time, all of it inside Widgetbook's canvas.
library;

import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/landing_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

final _lightTheme = buildLightTheme();
final _darkTheme = buildDarkTheme();

/// The app's theme and navigator around one use case.
///
/// A real `ShadApp` rather than a theme wrapper, so text styles, overlays and
/// `Navigator.of(context)` behave exactly as they do in App Studio. Widgetbook
/// keys this by the use case's URL, so switching use case or theme always
/// starts fresh.
///
/// The use case sits on a page of its own above a "closed" page. Cancel, Done
/// or Quit pop that page — as they would pop the dialog in the app — and leave
/// a **Show again** button behind, rather than an empty navigator.
class UseCaseHost extends StatelessWidget {
  const UseCaseHost({super.key, required this.brightness, required this.child});

  final Brightness brightness;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ShadApp(
      debugShowCheckedModeBanner: false,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: _PopGuard(child: child),
    );
  }
}

class _PopGuard extends StatefulWidget {
  const _PopGuard({required this.child});

  final Widget child;

  @override
  State<_PopGuard> createState() => _PopGuardState();
}

class _PopGuardState extends State<_PopGuard> {
  static const _useCaseKey = ValueKey('use-case');

  bool _open = true;

  @override
  Widget build(BuildContext context) {
    return Navigator(
      pages: [
        _InstantPage(
          key: const ValueKey('closed'),
          child: _Closed(onShowAgain: () => setState(() => _open = true)),
        ),
        if (_open)
          _InstantPage(
            key: _useCaseKey,
            child: Scaffold(body: SizedBox.expand(child: widget.child)),
          ),
      ],
      onDidRemovePage: (page) {
        if (page.key == _useCaseKey) setState(() => _open = false);
      },
    );
  }
}

class _Closed extends StatelessWidget {
  const _Closed({required this.onShowAgain});

  final VoidCallback onShowAgain;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ColoredBox(
      color: theme.colorScheme.background,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Closed.', style: theme.textTheme.muted),
            const SizedBox(height: 12),
            ShadButton.secondary(
              onPressed: onShowAgain,
              child: const Text('Show again'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A page with no transition: switching to a use case should show it, not
/// animate it in.
class _InstantPage extends Page<void> {
  const _InstantPage({required super.key, required this.child});

  final Widget child;

  @override
  Route<void> createRoute(BuildContext context) => _InstantRoute(this);
}

class _InstantRoute extends PageRoute<void> {
  _InstantRoute(_InstantPage page) : super(settings: page);

  _InstantPage get _page => settings as _InstantPage;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      _page.child;
}

/// The window size full-window screens are drawn at: a common laptop window,
/// comfortably above App Studio's 1024×720 minimum (`MainFlutterWindow`).
const kAppWindowSize = Size(1280, 800);

/// The smallest window App Studio allows — `test/widgetbook` builds the studio
/// window at this size to catch overflows a real user could hit.
const kMinAppWindowSize = Size(1024, 720);

/// A full-window screen, drawn at a real window size and scaled down to fit
/// the canvas.
///
/// Widgetbook's canvas is narrower than any window App Studio allows, so laid
/// out at canvas size the toolbar overflowed and truncated text that never
/// truncates in the app. Laid out at [kAppWindowSize] instead, the screen is
/// the real layout, only smaller — hover, tooltips and clicks still work
/// through the scaling.
class AppWindow extends StatelessWidget {
  const AppWindow({super.key, required this.child, this.size = kAppWindowSize});

  final Widget child;
  final Size size;

  @override
  Widget build(BuildContext context) {
    // Expanded first: Widgetbook hands a use case loose constraints, and a
    // FittedBox under those shrinks to its child and sits at the top-left.
    return SizedBox.expand(
      child: ColoredBox(
        color: ShadTheme.of(context).colorScheme.muted,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox.fromSize(
            size: size,
            // The size matters to more than layout: shad switches dialogs to
            // their phone layout — centred text, stacked full-width buttons —
            // below a 640-wide *screen*, read from MediaQuery. Widgetbook's
            // canvas is under that, which is how dialogs came out centred
            // here and nowhere in the app.
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(size: size),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// A full-window screen.
Widget screen(Widget child) => AppWindow(child: child);

/// One dialog, drawn in place over [backdrop] behind the app's own dialog
/// barrier colour.
///
/// Drawn rather than pushed: nothing is opened on top of Widgetbook, the
/// dialog stays put while Widgetbook's controls are used, and each use case is
/// exactly one dialog in one state. Its buttons behave as in the app — Cancel
/// pops, and the host's "closed" page takes over.
class DialogUseCase extends StatelessWidget {
  const DialogUseCase({
    super.key,
    required this.backdrop,
    required this.dialog,
  });

  final Widget backdrop;
  final Widget dialog;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    // Dialog and backdrop together, at window size: a dialog laid out at the
    // canvas's width takes shad's phone layout, which the app never shows.
    return AppWindow(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The backdrop is scenery: a click on it would open things the use
          // case is not about.
          IgnorePointer(child: backdrop),
          ColoredBox(
            color: theme.alertDialogTheme.barrierColor ??
                Colors.black.withValues(alpha: 0.1),
          ),
          Center(child: SingleChildScrollView(child: dialog)),
        ],
      ),
    );
  }
}

/// The branded backdrop first-run setup and the start page sit on.
const landingBackdrop = LandingScaffold(child: SizedBox.shrink());

/// A standalone widget on the app's background, with room around it.
class ComponentCanvas extends StatelessWidget {
  const ComponentCanvas({
    super.key,
    required this.child,
    this.width = 520,
    this.height,
  });

  final Widget child;

  /// Wide components (panes, tables) need a width to lay out against.
  final double? width;

  /// Panes that fill their parent — the server log — need a height too.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.background,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    );
  }
}
