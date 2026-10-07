import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shad/shad.dart';

import '../../runner/runner_log.dart';
import '../../runner/runner_protocol.dart';
import '../../theme/app_theme.dart';
import 'log_view_controller.dart';

/// Font size for log text. Every column is measured in characters of it, and
/// [serverLogMinWidth] follows a change here automatically.
const kServerLogFontSize = 11.5;

/// How wide a log line is allowed to get before the panel stops shrinking.
const _kMinLogColumns = 80;

const _kRowPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 1.5);

/// The level column, in characters: `debug`, `info`, `warn`, `error`, `fatal`.
const _kLevelColumns = 5;

/// The time column, in characters: `HH:mm:ss.SSS`.
const _kTimeColumns = 12;

double? _cachedCharWidth;

/// The advance of one character of the log font. Menlo is monospaced, so the
/// columns are character counts times this — the way the TUI lays them out.
double _charWidth() => _cachedCharWidth ??= () {
      final painter = TextPainter(
        text: const TextSpan(
          text: 'M',
          style: TextStyle(
            fontFamily: kMacMonoFont,
            fontSize: kServerLogFontSize,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }();

double get _levelWidth => _kLevelColumns * _charWidth();
double get _timeWidth => _kTimeColumns * _charWidth();
double get _gap => _charWidth();

/// Where a message starts: after the level, the time and a gap after each.
double get _messageIndent => _levelWidth + _gap + _timeWidth + _gap;

/// Minimum width for the panel that keeps an 80-column message visible, the
/// level and time columns and padding included.
double serverLogMinWidth() =>
    _kMinLogColumns * _charWidth() + _messageIndent + _kRowPadding.horizontal;

/// The lowest level the server log shows, named as the levels themselves are.
enum LogLevelFilter {
  debug('Debug', RunnerLogLevel.debug),
  info('Info', RunnerLogLevel.info),
  warning('Warning', RunnerLogLevel.warning),
  error('Error', RunnerLogLevel.error);

  const LogLevelFilter(this.label, this.minimum);

  final String label;
  final RunnerLogLevel minimum;
}

/// What the log shows: the server, or one Flutter app.
sealed class LogSource {
  const LogSource();
}

final class ServerLogSource extends LogSource {
  const ServerLogSource();

  @override
  bool operator ==(Object other) => other is ServerLogSource;

  @override
  int get hashCode => 0;
}

final class AppLogSource extends LogSource {
  const AppLogSource(this.appId);

  final String appId;

  @override
  bool operator ==(Object other) =>
      other is AppLogSource && other.appId == appId;

  @override
  int get hashCode => appId.hashCode;
}

/// The colours a log is drawn in: the TUI's palette — grey debug, blue info,
/// yellow warnings, red errors, green successes — taken from the app's own
/// tokens, so it follows the theme like everything else.
class _LogPalette {
  _LogPalette(ShadColorScheme scheme)
      : text = scheme.foreground,
        dim = scheme.mutedForeground,
        rule = scheme.border,
        debug = scheme.mutedForeground,
        info = scheme.primary,
        warning = scheme.warning,
        error = scheme.destructive,
        success = scheme.success;

  final Color text;
  final Color dim;
  final Color rule;
  final Color debug;
  final Color info;
  final Color warning;
  final Color error;
  final Color success;

  Color level(RunnerLogLevel level) => switch (level) {
        RunnerLogLevel.debug => debug,
        RunnerLogLevel.info => info,
        RunnerLogLevel.warning => warning,
        RunnerLogLevel.error || RunnerLogLevel.fatal => error,
      };
}

/// The level as the TUI prints it.
String _levelLabel(RunnerLogLevel level) => switch (level) {
      RunnerLogLevel.debug => 'debug',
      RunnerLogLevel.info => 'info',
      RunnerLogLevel.warning => 'warn',
      RunnerLogLevel.error => 'error',
      RunnerLogLevel.fatal => 'fatal',
    };

/// What the runner logs, drawn natively rather than as a terminal — and laid
/// out the way the `serverpod start` TUI draws it, so the two read alike.
///
/// The server source is the runner's *structured* log: each record is its
/// level, its time and its message, with an error under the message and a
/// stack trace behind a disclosure. Finished operations — compiles, launches,
/// migrations — are ruled lines with their durations. What is still in flight
/// is not shown here: the toolbar's status names it. An app source is that
/// Flutter app's output, line by line.
///
/// **Output only, and it must stay that way for the keyboard.** A key Flutter
/// reports as handled never reaches the menu bar, so a log that swallowed keys
/// took ⌘W and every other menu shortcut with it. Selection is a
/// [SelectionArea], which answers ⌘C and ⌘A and nothing else.
class ServerLogView extends StatefulWidget {
  const ServerLogView({
    super.key,
    required this.log,
    required this.source,
    required this.view,
    this.emptyMessage,
  });

  final RunnerLog log;
  final LogSource source;

  /// Owns the level filter, which the Logs menu sets too.
  final LogViewController view;

  /// Shown on an empty server log, such as what the server is doing instead.
  final String? emptyMessage;

  @override
  State<ServerLogView> createState() => _ServerLogViewState();
}

class _ServerLogViewState extends State<ServerLogView> {
  final _searchController = TextEditingController();
  final _scroll = ScrollController();
  final _expanded = Set<RunnerLogRecord>.identity();

  LogLevelFilter get _level => widget.view.level;

  /// Following the newest line. Scrolling up lets go; scrolling back to the
  /// bottom — or the jump button — takes hold again.
  bool _following = true;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(covariant ServerLogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _following = true;
      _lastCount = 0;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final atBottom = position.pixels >= position.maxScrollExtent - 24;
    if (atBottom != _following) setState(() => _following = atBottom);
  }

  void _followAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_following || !_scroll.hasClients) return;
      final position = _scroll.position;
      if (position.pixels < position.maxScrollExtent) {
        _scroll.jumpTo(position.maxScrollExtent);
        // Rows are measured as they are built, so the extent can still grow
        // once the jump has laid out the last of them.
        _followAfterFrame();
      }
    });
  }

  void _jumpToLatest() {
    setState(() => _following = true);
    _followAfterFrame();
  }

  String get _query => _searchController.text.trim().toLowerCase();

  List<Object> _rows() {
    final query = _query;
    switch (widget.source) {
      case ServerLogSource():
        final minimum = _level.minimum;
        return [
          for (final item in widget.log.serverItems)
            if (_serverItemVisible(item, minimum, query)) item,
        ];
      case AppLogSource(:final appId):
        final lines = widget.log.app(appId)?.lines ?? const [];
        return [
          for (final line in lines)
            if (query.isEmpty || line.toLowerCase().contains(query)) line,
        ];
    }
  }

  static bool _serverItemVisible(
    ServerLogItem item,
    RunnerLogLevel minimum,
    String query,
  ) {
    switch (item) {
      case RunnerLogRecord():
        if (!item.level.isAtLeast(minimum)) return false;
        if (query.isEmpty) return true;
        return item.message.toLowerCase().contains(query) ||
            (item.scope?.toLowerCase().contains(query) ?? false) ||
            (item.error?.toLowerCase().contains(query) ?? false);
      case RunnerOperation():
        // A failed operation is an error as far as the filter goes; a
        // successful one is progress, and stays with the info level.
        final level =
            item.success ? RunnerLogLevel.info : RunnerLogLevel.error;
        if (!level.isAtLeast(minimum)) return false;
        return query.isEmpty || item.label.toLowerCase().contains(query);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListenableBuilder(
          listenable: widget.view,
          builder: (context, _) => _FilterBar(
            searchController: _searchController,
            level: widget.source is ServerLogSource ? _level : null,
            onLevelChanged: (level) => widget.view.level = level,
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: scheme.background,
            child: ListenableBuilder(
              listenable: Listenable.merge([widget.log, widget.view]),
              builder: (context, _) => _buildBody(context),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final rows = _rows();
    if (rows.length != _lastCount) {
      _lastCount = rows.length;
      if (_following) _followAfterFrame();
    }
    final palette = _LogPalette(ShadTheme.of(context).colorScheme);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Stack(
            children: [
              if (rows.isEmpty)
                _EmptyLog(message: _emptyMessage())
              else
                SelectionArea(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: rows.length,
                    itemBuilder: (context, index) =>
                        _buildRow(rows[index], palette),
                  ),
                ),
              if (!_following && rows.isNotEmpty)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: ShadButton.secondary(
                    size: ShadButtonSize.sm,
                    onPressed: _jumpToLatest,
                    leading: const Icon(LucideIcons.arrowDownToLine, size: 14),
                    child: const Text('Latest'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _emptyMessage() {
    if (_query.isNotEmpty) return 'Nothing matches “${_searchController.text}”.';
    switch (widget.source) {
      case ServerLogSource():
        if (_level != LogLevelFilter.debug &&
            widget.log.serverItems.isNotEmpty) {
          return 'Nothing at ${_level.label.toLowerCase()} level or above yet.';
        }
        return widget.emptyMessage ?? 'Nothing logged yet.';
      case AppLogSource(:final appId):
        final name = widget.log.app(appId)?.name ?? 'The app';
        return '$name has not printed anything yet.';
    }
  }

  Widget _buildRow(Object row, _LogPalette palette) => switch (row) {
        RunnerLogRecord() => _RecordRow(
            record: row,
            palette: palette,
            expanded: _expanded.contains(row),
            onToggle: () => setState(() {
              if (!_expanded.remove(row)) _expanded.add(row);
            }),
          ),
        RunnerOperation() => _OperationRow(operation: row, palette: palette),
        final String line => _LineRow(line: line, palette: palette),
        _ => const SizedBox.shrink(),
      };
}

TextStyle _mono(Color color) => TextStyle(
      fontFamily: kMacMonoFont,
      fontSize: kServerLogFontSize,
      height: 1.45,
      color: color,
    );

String _clock(DateTime time) {
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final millis = local.millisecond.toString().padLeft(3, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}.$millis';
}

String formatLogDuration(Duration duration) {
  if (duration.inMilliseconds < 1000) return '${duration.inMilliseconds}ms';
  if (duration.inSeconds < 60) {
    return '${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '${duration.inMinutes}m ${seconds}s';
}

/// The level and time columns every server row starts with.
class _Gutter extends StatelessWidget {
  const _Gutter({required this.lead, required this.time, required this.dim});

  final Widget lead;
  final DateTime time;
  final Color dim;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: _levelWidth, child: lead),
          SizedBox(width: _gap),
          SizedBox(
            width: _timeWidth,
            child: Text(_clock(time), style: _mono(dim)),
          ),
          SizedBox(width: _gap),
        ],
      );
}

/// One structured log record: `level  time  message`, then its error and a
/// stack trace behind a disclosure.
class _RecordRow extends StatelessWidget {
  const _RecordRow({
    required this.record,
    required this.palette,
    required this.expanded,
    required this.onToggle,
  });

  final RunnerLogRecord record;
  final _LogPalette palette;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final level = record.level;
    final levelColor = palette.level(level);
    // App Studio's own records — pub get, starting the runner — recede, so
    // what the server said stands out.
    final messageColor = record.source == RunnerLogSource.appStudio
        ? palette.dim
        : palette.text;
    final error = record.error;
    final stack = record.stackTrace?.trimRight();

    return Padding(
      padding: _kRowPadding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Gutter(
            lead: Text(
              _levelLabel(level),
              style: _mono(levelColor).copyWith(
                // Menlo is not variable: `fontWeight` is the lever here.
                fontWeight: level.isAtLeast(RunnerLogLevel.error)
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
            time: record.time,
            dim: palette.dim,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: record.message),
                      if (record.scope case final scope?)
                        TextSpan(
                          text: '  $scope',
                          style: _mono(palette.dim),
                        ),
                    ],
                  ),
                  style: _mono(messageColor),
                ),
                if (error != null && error.isNotEmpty)
                  Text(error, style: _mono(palette.error)),
                if (stack != null && stack.isNotEmpty) ...[
                  _StackTraceToggle(
                    lines: stack.split('\n').length,
                    expanded: expanded,
                    color: palette.dim,
                    onPressed: onToggle,
                  ),
                  if (expanded)
                    Padding(
                      padding: EdgeInsets.only(left: _charWidth() * 2),
                      child: Text(
                        stack,
                        style: _mono(palette.dim)
                            .copyWith(fontSize: kServerLogFontSize - 1),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `▸ 12-line stack trace`, as the TUI writes it. A click toggles; selection
/// skips it, so copying an error does not copy the affordance.
class _StackTraceToggle extends StatefulWidget {
  const _StackTraceToggle({
    required this.lines,
    required this.expanded,
    required this.color,
    required this.onPressed,
  });

  final int lines;
  final bool expanded;
  final Color color;
  final VoidCallback onPressed;

  @override
  State<_StackTraceToggle> createState() => _StackTraceToggleState();
}

class _StackTraceToggleState extends State<_StackTraceToggle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final label = '${widget.expanded ? '▾' : '▸'} ${widget.lines}-line stack '
        'trace';
    return SelectionContainer.disabled(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Text(
            label,
            style: _mono(widget.color).copyWith(
              decoration:
                  _hovered ? TextDecoration.underline : TextDecoration.none,
              decorationColor: widget.color,
            ),
          ),
        ),
      ),
    );
  }
}

/// A finished operation: `✓  time  label (duration)` and a rule to the edge,
/// in the success or failure colour — the TUI's section marker.
class _OperationRow extends StatelessWidget {
  const _OperationRow({required this.operation, required this.palette});

  final RunnerOperation operation;
  final _LogPalette palette;

  @override
  Widget build(BuildContext context) {
    final color = operation.success ? palette.success : palette.error;
    final label = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: operation.label),
          TextSpan(
            text: ' (${formatLogDuration(operation.duration)})',
            style: _mono(palette.dim),
          ),
        ],
      ),
      style: _mono(color).copyWith(fontWeight: FontWeight.w600),
    );
    return Padding(
      padding: _kRowPadding.add(const EdgeInsets.symmetric(vertical: 2)),
      child: Row(
        children: [
          _Gutter(
            lead: Center(
              child: Icon(
                operation.success ? LucideIcons.check : LucideIcons.x,
                size: kServerLogFontSize + 1,
                color: color,
              ),
            ),
            time: operation.completedAt,
            dim: palette.dim,
          ),
          // The label takes what it needs and the rule takes *all* the rest,
          // out to the row's right padding. A `Flexible` label beside an
          // `Expanded` rule would split the leftover space between them
          // instead, and the rule would stop halfway across.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final minRule = _charWidth() * 2;
                return Row(
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: (constraints.maxWidth - _gap - minRule)
                            .clamp(0, double.infinity),
                      ),
                      child: label,
                    ),
                    SizedBox(width: _gap),
                    Expanded(child: Container(height: 1, color: palette.rule)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// One line of a Flutter app's output.
class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.palette});

  final String line;
  final _LogPalette palette;

  @override
  Widget build(BuildContext context) => Padding(
        padding: _kRowPadding,
        child: Text(line, style: _mono(palette.text)),
      );
}

class _EmptyLog extends StatelessWidget {
  const _EmptyLog({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final textTheme = ShadTheme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: textTheme.muted,
        ),
      ),
    );
  }
}

/// Search, and the level filter on the server log.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.searchController,
    required this.level,
    required this.onLevelChanged,
  });

  final TextEditingController searchController;

  /// Null hides the filter — an app's output has no levels.
  final LogLevelFilter? level;
  final ValueChanged<LogLevelFilter> onLevelChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final level = this.level;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.background,
        border: Border(bottom: paneBorderSide(scheme.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Shortcuts(
              // Escape clears the search rather than leaving it applied and
              // invisible once focus has moved on.
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.escape): _ClearIntent(),
              },
              child: Actions(
                actions: {
                  _ClearIntent: CallbackAction<_ClearIntent>(
                    onInvoke: (_) {
                      searchController.clear();
                      return null;
                    },
                  ),
                },
                child: ShadInput(
                  controller: searchController,
                  placeholder: const Text('Search the log'),
                  leading: Icon(
                    LucideIcons.search,
                    size: 14,
                    color: scheme.mutedForeground,
                  ),
                  trailing: searchController.text.isEmpty
                      ? null
                      : ShadIconButton.ghost(
                          width: 20,
                          height: 20,
                          padding: EdgeInsets.zero,
                          onPressed: searchController.clear,
                          icon: const Icon(LucideIcons.x, size: 12),
                        ),
                ),
              ),
            ),
          ),
          if (level != null) ...[
            const SizedBox(width: 6),
            ShadTooltip(
              builder: (context) =>
                  const Text('Show this level and everything above it'),
              child: ShadSelect<LogLevelFilter>(
                // Keyed on the value: the Logs menu sets the level too, and
                // `initialValue` is only read once.
                key: ValueKey(level),
                initialValue: level,
                minWidth: 120,
                onChanged: (value) {
                  if (value != null) onLevelChanged(value);
                },
                options: [
                  for (final option in LogLevelFilter.values)
                    ShadOption(value: option, child: Text(option.label)),
                ],
                selectedOptionBuilder: (context, value) => Text(value.label),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ClearIntent extends Intent {
  const _ClearIntent();
}
