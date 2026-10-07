import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shad/shad.dart';

import '../../runner/runner_actions_view.dart';
import '../../runner/runner_log.dart';
import '../../runner/runner_protocol.dart';
import '../../theme/app_theme.dart';
import 'migrations_menu.dart';

/// Font size for log text. [serverLogMinWidth] measures with it, so the
/// panel's minimum follows a change here automatically.
const kServerLogFontSize = 11.5;

/// How wide a log line is allowed to get before the panel stops shrinking.
const _kMinLogColumns = 80;

const _kRowPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 2);

/// The time column's width, wide enough for `00:00:00` in the log font.
const _kTimeColumnWidth = 70.0;

double? _cachedMinWidth;

/// Minimum width for the panel that keeps an 80-column log line visible,
/// padding and the time column included.
///
/// Measured from the log's own font rather than hardcoded, so it cannot drift
/// when [kServerLogFontSize] or [kMacMonoFont] moves. Cached — the metrics
/// cannot change at runtime.
double serverLogMinWidth() => _cachedMinWidth ??= _measureMinWidth();

double _measureMinWidth() {
  final painter = TextPainter(
    text: TextSpan(
      text: ''.padRight(_kMinLogColumns, 'M'),
      style: const TextStyle(
        fontFamily: kMacMonoFont,
        fontSize: kServerLogFontSize,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width + _kRowPadding.horizontal;
  painter.dispose();
  return width;
}

/// Which records the server log shows.
enum LogLevelFilter {
  all('All levels', RunnerLogLevel.debug),
  info('Info and above', RunnerLogLevel.info),
  warnings('Warnings and errors', RunnerLogLevel.warning),
  errors('Errors only', RunnerLogLevel.error);

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

/// What the runner logs, drawn natively rather than as a terminal.
///
/// The server source is the runner's *structured* log — the pod's entries and
/// the runner's own, each with a level, a time and, for a failure, the error
/// and stack trace behind a disclosure — interleaved with the operations it
/// finished (compiles, launches, migrations) and their durations. Operations
/// still in flight sit pinned at the bottom with a live timer. An app source
/// is that Flutter app's output, line by line.
///
/// **Output only, and it must stay that way for the keyboard.** A key Flutter
/// reports as handled never reaches the menu bar, so a log that swallowed keys
/// took ⌘W and every other menu shortcut with it. Selection is a
/// [SelectionArea], which answers ⌘C and ⌘A and nothing else.
class ServerLogView extends StatefulWidget {
  const ServerLogView({
    super.key,
    required this.log,
    required this.actions,
    required this.source,
    this.emptyMessage,
  });

  final RunnerLog log;
  final RunnerActionsView actions;
  final LogSource source;

  /// Shown on an empty server log, such as what the server is doing instead.
  final String? emptyMessage;

  @override
  State<ServerLogView> createState() => _ServerLogViewState();
}

class _ServerLogViewState extends State<ServerLogView> {
  final _searchController = TextEditingController();
  final _scroll = ScrollController();
  final _expanded = Set<RunnerLogRecord>.identity();
  LogLevelFilter _level = LogLevelFilter.all;

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
        _FilterBar(
          searchController: _searchController,
          level: widget.source is ServerLogSource ? _level : null,
          onLevelChanged: (level) => setState(() => _level = level),
          actions: widget.actions,
        ),
        Expanded(
          child: ColoredBox(
            color: scheme.background,
            child: ListenableBuilder(
              listenable: widget.log,
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
    final active = widget.source is ServerLogSource
        ? widget.log.activeOperations
        : const <ActiveOperation>[];

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
                        _buildRow(context, rows[index]),
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
        if (active.isNotEmpty) _ActiveOperations(operations: active),
      ],
    );
  }

  String _emptyMessage() {
    if (_query.isNotEmpty) return 'Nothing matches “${_searchController.text}”.';
    switch (widget.source) {
      case ServerLogSource():
        if (_level != LogLevelFilter.all &&
            widget.log.serverItems.isNotEmpty) {
          return 'Nothing at this level yet.';
        }
        return widget.emptyMessage ?? 'Nothing logged yet.';
      case AppLogSource(:final appId):
        final name = widget.log.app(appId)?.name ?? 'The app';
        return '$name has not printed anything yet.';
    }
  }

  Widget _buildRow(BuildContext context, Object row) => switch (row) {
        RunnerLogRecord() => _RecordRow(
            record: row,
            expanded: _expanded.contains(row),
            onToggle: () => setState(() {
              if (!_expanded.remove(row)) _expanded.add(row);
            }),
          ),
        RunnerOperation() => _OperationRow(operation: row),
        final String line => _LineRow(line: line),
        _ => const SizedBox.shrink(),
      };
}

TextStyle _monoStyle(BuildContext context, {Color? color}) {
  final scheme = ShadTheme.of(context).colorScheme;
  return TextStyle(
    fontFamily: kMacMonoFont,
    fontSize: kServerLogFontSize,
    height: 1.45,
    color: color ?? scheme.foreground,
  );
}

String _clock(DateTime time) {
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String formatLogDuration(Duration duration) {
  if (duration.inMilliseconds < 1000) return '${duration.inMilliseconds}ms';
  if (duration.inSeconds < 60) {
    return '${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '${duration.inMinutes}m ${seconds}s';
}

/// One structured log record: time, level, message, and — behind a
/// disclosure — the error and stack trace.
class _RecordRow extends StatelessWidget {
  const _RecordRow({
    required this.record,
    required this.expanded,
    required this.onToggle,
  });

  final RunnerLogRecord record;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final level = record.level;
    final levelColor = switch (level) {
      RunnerLogLevel.warning => scheme.warning,
      RunnerLogLevel.error || RunnerLogLevel.fatal => scheme.destructive,
      RunnerLogLevel.debug => scheme.mutedForeground,
      RunnerLogLevel.info => null,
    };
    final fromAppStudio = record.source == RunnerLogSource.appStudio;
    final messageColor = levelColor ??
        (fromAppStudio ? scheme.mutedForeground : scheme.foreground);
    final muted = _monoStyle(context, color: scheme.mutedForeground);

    final message = Text.rich(
      TextSpan(
        children: [
          if (level.isAtLeast(RunnerLogLevel.warning))
            TextSpan(
              text: '${level.name.toUpperCase()} ',
              style: _monoStyle(context, color: levelColor)
                  .copyWith(fontWeight: FontWeight.w600),
            ),
          TextSpan(text: record.message),
          if (record.scope case final scope?)
            TextSpan(text: '  · $scope', style: muted),
        ],
      ),
      style: _monoStyle(context, color: messageColor),
    );

    return Padding(
      padding: _kRowPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _kTimeColumnWidth,
                child: Text(_clock(record.time), style: muted),
              ),
              Expanded(child: message),
              if (record.hasDetails)
                _DisclosureButton(expanded: expanded, onPressed: onToggle),
            ],
          ),
          if (expanded && record.hasDetails)
            Padding(
              padding: const EdgeInsets.only(
                left: _kTimeColumnWidth,
                top: 2,
                bottom: 4,
              ),
              child: _RecordDetails(record: record),
            ),
        ],
      ),
    );
  }
}

class _RecordDetails extends StatelessWidget {
  const _RecordDetails({required this.record});

  final RunnerLogRecord record;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.muted,
        borderRadius: theme.radii.sm,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (record.error case final error? when error.isNotEmpty)
              Text(error, style: _monoStyle(context, color: scheme.destructive)),
            if (record.stackTrace case final stack?)
              Text(
                stack.trimRight(),
                style: _monoStyle(context, color: scheme.mutedForeground)
                    .copyWith(fontSize: kServerLogFontSize - 1),
              ),
          ],
        ),
      ),
    );
  }
}

class _DisclosureButton extends StatelessWidget {
  const _DisclosureButton({required this.expanded, required this.onPressed});

  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    // Outside the selection: a click here toggles, it does not select.
    return SelectionContainer.disabled(
      child: ShadTooltip(
        builder: (context) =>
            Text(expanded ? 'Hide details' : 'Show error and stack trace'),
        child: ShadIconButton.ghost(
          width: 20,
          height: 20,
          padding: EdgeInsets.zero,
          onPressed: onPressed,
          icon: Icon(
            expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
            size: 14,
            color: scheme.mutedForeground,
          ),
        ),
      ),
    );
  }
}

/// A finished operation: what it was, whether it worked, and how long it took.
class _OperationRow extends StatelessWidget {
  const _OperationRow({required this.operation});

  final RunnerOperation operation;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final color = operation.success ? scheme.success : scheme.destructive;
    final muted = _monoStyle(context, color: scheme.mutedForeground);
    return Padding(
      padding: _kRowPadding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _kTimeColumnWidth,
            child: Text(_clock(operation.completedAt), style: muted),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 6),
            child: Icon(
              operation.success ? LucideIcons.check : LucideIcons.x,
              size: 12,
              color: color,
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: operation.label),
                  TextSpan(
                    text: '  ${formatLogDuration(operation.duration)}',
                    style: muted,
                  ),
                ],
              ),
              style: _monoStyle(
                context,
                color: operation.success ? scheme.foreground : color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One line of a Flutter app's output.
class _LineRow extends StatelessWidget {
  const _LineRow({required this.line});

  final String line;

  @override
  Widget build(BuildContext context) => Padding(
        padding: _kRowPadding,
        child: Text(line, style: _monoStyle(context)),
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

/// Operations in flight, pinned under the log with a live elapsed time — the
/// compile or launch that explains why nothing has happened for a minute.
class _ActiveOperations extends StatefulWidget {
  const _ActiveOperations({required this.operations});

  final List<ActiveOperation> operations;

  @override
  State<_ActiveOperations> createState() => _ActiveOperationsState();
}

class _ActiveOperationsState extends State<_ActiveOperations> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final now = DateTime.now();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.muted,
        border: Border(top: paneBorderSide(scheme.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final operation in widget.operations)
              Padding(
                padding: _kRowPadding,
                child: Row(
                  children: [
                    const SizedBox(
                      width: _kTimeColumnWidth,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ShadSpinner(size: 12),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        operation.label,
                        overflow: TextOverflow.ellipsis,
                        style: _monoStyle(context),
                      ),
                    ),
                    Text(
                      formatLogDuration(
                        Duration(
                          seconds: now
                              .difference(operation.startedAt)
                              .inSeconds
                              .clamp(0, 1 << 30),
                        ),
                      ),
                      style: _monoStyle(
                        context,
                        color: scheme.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Search, the level filter (server only) and the migrations menu.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.searchController,
    required this.level,
    required this.onLevelChanged,
    required this.actions,
  });

  final TextEditingController searchController;

  /// Null hides the filter — an app's output has no levels.
  final LogLevelFilter? level;
  final ValueChanged<LogLevelFilter> onLevelChanged;
  final RunnerActionsView actions;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
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
            ShadSelect<LogLevelFilter>(
              initialValue: level,
              minWidth: 168,
              onChanged: (value) {
                if (value != null) onLevelChanged(value);
              },
              options: [
                for (final option in LogLevelFilter.values)
                  ShadOption(value: option, child: Text(option.label)),
              ],
              selectedOptionBuilder: (context, value) => Text(value.label),
            ),
          ],
          const SizedBox(width: 6),
          MigrationsMenu(actions: actions),
        ],
      ),
    );
  }
}

class _ClearIntent extends Intent {
  const _ClearIntent();
}
