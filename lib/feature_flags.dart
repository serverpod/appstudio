/// Build-time switches for features that stay in the tree but are not shipped.
///
/// A flag here is the whole switch: everything it gates reads it directly, so
/// turning a feature back on is one edit rather than a hunt through the app.
library;

/// Whether the bundled OpenCode agent is part of App Studio.
///
/// Off, and the four places it reaches into the app step back:
///
/// - [ToolProbe.inventory] does not probe `opencode`, so it is neither offered
///   on first run nor listed in Settings → Tools, and nothing downloads it.
/// - [IdeIntegration.opencode] stops being `builtIn`, so `serverpod create` is
///   no longer told to configure it on every new project.
/// - The left panel drops its Agent tab and shows the server log alone, and
///   Settings drops its Providers tab — which configures keys for this agent
///   and nothing else.
/// - [AgentController] never spawns `opencode serve`.
///
/// All of that code is still here. Flipping this to `true` brings it back.
const bool kOpenCodeAgentEnabled = false;

/// Whether App Studio drives Hot Restart through `serverpod mcp-server`.
///
/// Off, because the bridge cannot yet deliver a hot restart to the runner App
/// Studio starts. Two things step back:
///
/// - [McpController] registers no listeners, so no project and no running
///   server ever spawns a `serverpod mcp-server`, and nothing is probed.
/// - The toolbar's Hot Restart button stays, but instead of restarting it opens
///   a dialog pointing the user at their own AI agent, which can run the same
///   tool over Serverpod's MCP server today.
///
/// TODO(appstudio): Turn this back on once the bridge can hot restart the
/// running project. Everything behind it is still here — the bridge, the runner
/// probe and the button's real action — so this is a one-line change.
const bool kServerpodMcpEnabled = false;
