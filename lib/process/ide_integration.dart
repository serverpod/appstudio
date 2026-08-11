import '../feature_flags.dart';

/// Editors `serverpod create --ide` can configure with agent skills and MCP.
///
/// `--ide` is a multi-option, so each one is passed as its own flag.
enum IdeIntegration {
  opencode('opencode', 'OpenCode', builtIn: kOpenCodeAgentEnabled),
  antigravity('antigravity', 'Antigravity'),
  claude('claude', 'Claude Code'),
  codex('codex', 'Codex'),
  cursor('cursor', 'Cursor'),
  vscode('vscode', 'VS Code');

  const IdeIntegration(this.option, this.label, {this.builtIn = false});

  /// Value passed to `serverpod create --ide`, and the id stored in
  /// `.appstudio/settings.json`.
  final String option;

  /// Name shown in the New Project dialog.
  final String label;

  /// Configured whether or not it was asked for.
  ///
  /// Only OpenCode is ever this, and only while App Studio runs it as its own
  /// agent — a project without it would open with an Agent tab that has no
  /// skills and no MCP server. With [kOpenCodeAgentEnabled] off there is no
  /// Agent tab, so nothing is forced on a project the user did not ask for and
  /// OpenCode is an ordinary choice like the rest.
  ///
  /// The New Project screen does not mark these — they are offered like any
  /// other editor, and picking one changes nothing.
  final bool builtIn;
}

/// The integration [option] names, or null if nothing does.
///
/// Takes an `Object?` because the caller that needs it is reading the value
/// back out of JSON, where the entry may be any type at all.
IdeIntegration? ideIntegrationForOption(Object? option) {
  for (final ide in IdeIntegration.values) {
    if (ide.option == option) return ide;
  }
  return null;
}

/// The editors `serverpod create` is asked to configure: everything picked,
/// plus everything built in whether it was picked or not.
///
/// Shared by the `--ide` arguments and the `.appstudio/settings.json` write so
/// the record cannot drift from what was actually configured.
Set<IdeIntegration> configuredIdes(Set<IdeIntegration> selected) => {
  for (final ide in IdeIntegration.values)
    if (ide.builtIn || selected.contains(ide)) ide,
};
