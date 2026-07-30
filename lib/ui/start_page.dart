import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

import '../session/project_session.dart';
import '../theme/app_colors.dart';
import '../widgets/menu_item_tile.dart';

const _kBannerHeight = 56.0;
const _kLogoAsset = 'assets/logo-horizontal.webp';
const _kBackgroundAsset = 'assets/background.webp';

/// Material pink 700 — primary actions on the start page.
const _kStartPageActionColor = Color(0xFFC2185B);

/// Darker rose for button hover / pressed states.
const _kStartPageActionHoverColor = Color(0xFFAD1457);

const _kStartPageCardRadius = 10.0;

/// Natural pixel size of [assets/background.webp].
const _kBackgroundAspectRatio = 2394 / 1247;

/// Landing screen shown before a project is opened.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StartPageBanner(),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              const _StartPageBackground(),
              _StartPageContent(
                session: session,
                onNewProject: onNewProject,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StartPageBanner extends StatelessWidget {
  const _StartPageBanner();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: SizedBox(
        height: _kBannerHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Image.asset(
              _kLogoAsset,
              height: 28,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ),
    );
  }
}

class _StartPageBackground extends StatelessWidget {
  const _StartPageBackground();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final width = constraints.maxWidth;
        final naturalWidth = height * _kBackgroundAspectRatio;

        if (naturalWidth < width) {
          return Image.asset(
            _kBackgroundAsset,
            width: width,
            height: height,
            fit: BoxFit.fill,
            alignment: Alignment.center,
            filterQuality: FilterQuality.medium,
          );
        }

        return ClipRect(
          child: Align(
            alignment: Alignment.center,
            child: Image.asset(
              _kBackgroundAsset,
              height: height,
              fit: BoxFit.fitHeight,
              filterQuality: FilterQuality.medium,
            ),
          ),
        );
      },
    );
  }
}

class _StartPageContent extends StatelessWidget {
  const _StartPageContent({required this.session, required this.onNewProject});

  final ProjectSession session;
  final VoidCallback onNewProject;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final isDark = theme.brightness == Brightness.dark;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (session.error != null) ...[
                Text(
                  session.error!,
                  textAlign: TextAlign.center,
                  style: textTheme.small.copyWith(
                    color: isDark
                        ? AppColors.errorTextDark
                        : AppColors.errorText,
                  ),
                ),
                const SizedBox(height: 24),
              ],
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_kStartPageCardRadius),
                  border: Border.all(color: scheme.border),
                  color: scheme.card,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Expanded(
                            child: _StartPageActionButton(
                              onPressed: onNewProject,
                              leading: const Icon(LucideIcons.plus, size: 16),
                              label: 'New Project',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _StartPageActionButton(
                              onPressed: session.openProjectPicker,
                              leading:
                                  const Icon(LucideIcons.arrowUpRight, size: 16),
                              label: 'Open Project',
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (session.recents.isNotEmpty) ...[
                      Divider(height: 1, color: scheme.border),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                        child: Row(
                          children: [
                            Text(
                              'Recent',
                              style: textTheme.small.copyWith(
                                fontWeight: FontWeight.w500,
                                color: scheme.mutedForeground,
                              ),
                            ),
                            const Spacer(),
                            ShadButton.ghost(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 0,
                              ),
                              height: 20,
                              foregroundColor: scheme.mutedForeground,
                              hoverForegroundColor: scheme.mutedForeground,
                              textStyle: textTheme.small.copyWith(
                                fontWeight: FontWeight.w500,
                                color: scheme.mutedForeground,
                                fontSize: 11,
                              ),
                              onPressed: session.clearRecents,
                              child: const Text('Clear recents'),
                            ),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: scheme.border),
                      Column(
                        children: [
                          for (var i = 0; i < session.recents.length; i++) ...[
                            if (i > 0)
                              Divider(height: 1, color: scheme.border),
                            MenuItemTile(
                              icon: LucideIcons.folder,
                              label: p.basename(session.recents[i]),
                              subtitle: session.recents[i],
                              onTap: () => session.openPath(session.recents[i]),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StartPageActionButton extends StatelessWidget {
  const _StartPageActionButton({
    required this.onPressed,
    required this.leading,
    required this.label,
  });

  final VoidCallback? onPressed;
  final Widget leading;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ShadButton(
      onPressed: onPressed,
      size: ShadButtonSize.sm,
      width: double.infinity,
      backgroundColor: _kStartPageActionColor,
      hoverBackgroundColor: _kStartPageActionHoverColor,
      pressedBackgroundColor: _kStartPageActionHoverColor,
      foregroundColor: Colors.white,
      hoverForegroundColor: Colors.white,
      leading: leading,
      child: Text(label),
    );
  }
}
