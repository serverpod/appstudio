import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shad/shad.dart';

import '../session/project_session.dart';
import '../theme/app_theme.dart';
import 'landing_scaffold.dart';

/// Most recent projects offered on the start page.
///
/// [ProjectSession] already keeps no more than this, so the take below is a
/// guard rather than the rule — the list is a shortcut, not a history.
const _kMaxRecentsShown = 5;

/// Landing screen shown once the toolchain is in place and no project is open.
///
/// The branded backdrop lives in [LandingScaffold] because first-run setup shows
/// the same one, and so does the fixed dark theme this screen is drawn in —
/// there is nothing here that reads the system brightness.
class StartPage extends StatelessWidget {
  const StartPage({
    super.key,
    required this.session,
    required this.onNewProject,
  });

  final ProjectSession session;
  final VoidCallback onNewProject;

  @override
  Widget build(BuildContext context) {
    return LandingScaffold(
      child: _StartPageContent(session: session, onNewProject: onNewProject),
    );
  }
}

class _StartPageContent extends StatelessWidget {
  const _StartPageContent({required this.session, required this.onNewProject});

  final ProjectSession session;
  final VoidCallback onNewProject;

  @override
  Widget build(BuildContext context) {
    final recents = session.recents.take(_kMaxRecentsShown).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                // The hero is centred in whatever the recents list leaves, and
                // scrolls rather than overflowing if that is nothing: five
                // recents at the minimum window size clears by about 30px, and
                // a `session.error` above the buttons can eat that.
                child: Center(
                  child: SingleChildScrollView(
                    child: _Hero(
                      error: session.error,
                      onNewProject: onNewProject,
                      onOpenProject: session.openProjectPicker,
                    ),
                  ),
                ),
              ),
              if (recents.isNotEmpty)
                _RecentProjects(
                  recents: recents,
                  onOpen: session.openPath,
                  onClear: session.clearRecents,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Title, subtitle and the two things that can be done from here.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.error,
    required this.onNewProject,
    required this.onOpenProject,
  });

  final String? error;
  final VoidCallback onNewProject;
  final VoidCallback onOpenProject;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Build your full-stack app',
          textAlign: TextAlign.center,
          style: textTheme.h1Large.copyWith(color: scheme.foreground),
        ),
        const SizedBox(height: 14),
        Text(
          'Create a new project or pick up where you left off.',
          textAlign: TextAlign.center,
          style: textTheme.lead.copyWith(color: scheme.mutedForeground),
        ),
        if (error != null) ...[
          const SizedBox(height: 20),
          Text(
            error!,
            textAlign: TextAlign.center,
            style: textTheme.muted.copyWith(color: scheme.destructive),
          ),
        ],
        const SizedBox(height: 36),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PrimaryAction(
              onPressed: onNewProject,
              icon: LucideIcons.plus,
              label: 'Create Project',
            ),
            const SizedBox(width: 16),
            _PrimaryAction(
              onPressed: onOpenProject,
              icon: LucideIcons.arrowUpRight,
              label: 'Open Project',
            ),
          ],
        ),
      ],
    );
  }
}

/// One of the two headline actions, inset in its own pane of glass.
///
/// The card is what makes a button this large sit on the backdrop instead of
/// floating over it; both are built here so the pair cannot drift apart in
/// size the way two separately styled buttons would. They are the same colour
/// on purpose — creating and opening are the two ways in, not a choice with a
/// recommended answer.
class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String label;

  static const _cardPadding = 8.0;
  static const _buttonHeight = 52.0;

  /// Width comes from the label plus this, never from a fixed number: a button
  /// pinned wide enough for these two labels today clips the moment either one
  /// changes or the text scales.
  static const _buttonPadding = EdgeInsets.symmetric(horizontal: 28);

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return ShadCard(
      padding: const EdgeInsets.all(_cardPadding),
      radius: concentricRadius(theme.radius, _cardPadding),
      child: ShadButton(
        onPressed: onPressed,
        size: ShadButtonSize.lg,
        height: _buttonHeight,
        padding: _buttonPadding,
        leading: Icon(icon, size: 18),
        textStyle: theme.textTheme.large.copyWith(
          color: theme.colorScheme.primaryForeground,
        ),
        child: Text(label),
      ),
    );
  }
}

/// The recent projects list, anchored to the bottom of the screen.
///
/// The heading and its Clear action sit above the panel rather than on it, so
/// they are the one piece of text here with nothing but the backdrop behind
/// them. Both are set in full white rather than the muted grade a label this
/// quiet would normally take, because they have no glass under them to lift
/// them off the gradient.
class _RecentProjects extends StatelessWidget {
  const _RecentProjects({
    required this.recents,
    required this.onOpen,
    required this.onClear,
  });

  final List<String> recents;
  final ValueChanged<String> onOpen;
  final VoidCallback onClear;

  static const _headingInset = 8.0;

  /// Row divider, drawn in the panel's own edge colour so a rule between two
  /// rows and the panel's outline are the same line rather than two weights.
  static const _separator = ShadSeparator.horizontal(
    thickness: kDividerWidth,
    margin: EdgeInsets.zero,
    color: kLandingPanelBorder,
  );

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          // Left inset matches the Clear button's own horizontal padding, so
          // the heading and the action are optically inset by the same amount
          // over the panel's corners.
          padding: const EdgeInsets.fromLTRB(_headingInset, 0, 0, 6),
          child: Row(
            children: [
              Text(
                'RECENT PROJECTS',
                style: textTheme.small
                    .copyWith(
                      color: scheme.foreground,
                      fontSize: 11,
                      letterSpacing: 0.8,
                    )
                    .semibold,
              ),
              const Spacer(),
              ShadButton.ghost(
                onPressed: onClear,
                size: ShadButtonSize.sm,
                padding: const EdgeInsets.symmetric(
                  horizontal: _headingInset,
                ),
                foregroundColor: scheme.foreground,
                hoverForegroundColor: scheme.foreground,
                textStyle: textTheme.small.copyWith(fontSize: 12).medium,
                child: const Text('Clear recents'),
              ),
            ],
          ),
        ),
        ShadCard(
          padding: EdgeInsets.zero,
          backgroundColor: kLandingPanelSurface,
          border: ShadBorder.all(
            color: kLandingPanelBorder,
            width: kDividerWidth,
          ),
          child: Column(
            children: [
              for (var i = 0; i < recents.length; i++) ...[
                if (i > 0) _separator,
                _RecentProjectTile(
                  path: recents[i],
                  onTap: () => onOpen(recents[i]),
                  isFirst: i == 0,
                  isLast: i == recents.length - 1,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _RecentProjectTile extends StatefulWidget {
  const _RecentProjectTile({
    required this.path,
    required this.onTap,
    required this.isFirst,
    required this.isLast,
  });

  final String path;
  final VoidCallback onTap;

  /// Which corners to round, so a hover fill cannot square off the panel it
  /// sits inside.
  final bool isFirst;
  final bool isLast;

  @override
  State<_RecentProjectTile> createState() => _RecentProjectTileState();
}

class _RecentProjectTileState extends State<_RecentProjectTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final radius = theme.radii.lg;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _hovered ? scheme.accent : Colors.transparent,
            borderRadius: BorderRadius.only(
              topLeft: widget.isFirst ? radius.topLeft : Radius.zero,
              topRight: widget.isFirst ? radius.topRight : Radius.zero,
              bottomLeft: widget.isLast ? radius.bottomLeft : Radius.zero,
              bottomRight: widget.isLast ? radius.bottomRight : Radius.zero,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: scheme.card,
                    borderRadius: theme.radii.md,
                    border: Border.all(color: scheme.border),
                  ),
                  child: Icon(
                    LucideIcons.folder,
                    size: 16,
                    color: scheme.mutedForeground,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.basename(widget.path),
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.small
                            .copyWith(color: scheme.foreground)
                            .semibold,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.path,
                        overflow: TextOverflow.ellipsis,
                        // Coloured explicitly, like every other string here.
                        // A role with no colour of its own falls through to
                        // the `DefaultTextStyle` that `ShadApp` set from the
                        // *app* theme, which is the one thing on this screen
                        // that still follows the system's light/dark setting —
                        // so the path, alone, went black in light mode.
                        style: textTheme.muted.copyWith(
                          fontSize: 12,
                          color: kLandingSubduedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
