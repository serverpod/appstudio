import 'package:flutter/foundation.dart';

import '../../feature_flags.dart';
import 'server_log_view.dart';

/// A tab in the left panel: the agent, the server log, or a Flutter app's log.
sealed class LeftPaneTab {
  const LeftPaneTab();

  static const agent = AgentTab();
  static const server = LogTab(ServerLogSource());
}

final class AgentTab extends LeftPaneTab {
  const AgentTab();

  @override
  bool operator ==(Object other) => other is AgentTab;

  @override
  int get hashCode => 1;
}

final class LogTab extends LeftPaneTab {
  const LogTab(this.source);

  final LogSource source;

  @override
  bool operator ==(Object other) => other is LogTab && other.source == source;

  @override
  int get hashCode => source.hashCode;
}

/// How the logs are being looked at: whether the panel is open, which log it
/// shows, and the lowest level the server log shows.
///
/// Lifted out of the widgets because two things drive it — the panel itself
/// and the Logs menu in the menu bar, which lives above `ShadApp` and can only
/// reach state that is not inside a `State`. Created in `main.dart`.
class LogViewController extends ChangeNotifier {
  LogViewController();

  bool _visible = true;
  LeftPaneTab _tab =
      kOpenCodeAgentEnabled ? LeftPaneTab.agent : LeftPaneTab.server;
  LogLevelFilter _level = LogLevelFilter.debug;

  /// Whether the panel left of the preview is shown.
  bool get visible => _visible;

  /// The panel's selected tab. With the agent switched off it is always a log.
  LeftPaneTab get tab => _tab;

  LogLevelFilter get level => _level;

  set visible(bool value) {
    if (value == _visible) return;
    _visible = value;
    notifyListeners();
  }

  void toggleVisible() => visible = !_visible;

  set tab(LeftPaneTab value) {
    if (value == _tab) return;
    _tab = value;
    notifyListeners();
  }

  /// Shows [source], opening the panel if it is closed — picking a log from
  /// the menu means wanting to read it.
  void show(LogSource source) {
    final tab = LogTab(source);
    if (tab == _tab && _visible) return;
    _tab = tab;
    _visible = true;
    notifyListeners();
  }

  set level(LogLevelFilter value) {
    if (value == _level) return;
    _level = value;
    notifyListeners();
  }
}
