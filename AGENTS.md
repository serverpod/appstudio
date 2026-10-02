# App Studio — agent notes

macOS Flutter IDE for **Serverpod 4** projects: open a project, run `serverpod start` in an embedded terminal, preview the Flutter web app in CEF at `http://localhost:9998`.

## Project layout

```
lib/
  main.dart              # ShadApp, wires controllers
  agent/                 # OpenCode serve client, SSE, AgentController, transcript
  ui/                    # studio_shell, preview_pane, terminal_pane, agent/, settings/
  mcp/                   # serverpod mcp-server bridge, McpController (hot restart)
  preview/               # CEF preview: device modes, theme shim, surface sync
  process/               # ServerpodProcessController (start/stop/reload), ProjectCreator
  session/               # ProjectSession (open project, recents)
  terminal/              # xterm wrapper
  theme/                 # Shad themes, layout constants, ThemeController
  toolchain/             # Probe + install CLT, Flutter, Serverpod CLI (official sources)
  widgets/               # Shared UI (IconSegmentedControl, MenuItemTile)
test_driver/             # Driver-enabled entry points for the Dart MCP server
widgetbook/              # `make widgetbook`: catalog, host, fakes (see Widgetbook)
packages/
  mac_menu_bar/            # Local fork — SF Symbol icons, separators, reset()
  webview_cef/             # Local fork — CEF resize + skip Helper (Alerts)
tool/
  distribute_macos.sh, publish_*.sh, set_version.sh   # releasing the app
```

UI reference for design patterns: `../cloudui/cloudui_flutter/`.

## Agent (OpenCode) — switched off

**`kOpenCodeAgentEnabled` in `lib/feature_flags.dart` is `false`, and everything
in this section is dormant behind it.** The code is all still here; the flag is
the whole switch, and flipping it to `true` brings the feature back intact. Read
the rest of this section as what happens when it is on.

**OpenCode is no longer a tool App Studio installs**, whatever the flag says —
it is not in the manifest, not probed and has no Settings → Tools row. With the
flag on, `OpenCodeServe` runs whichever `opencode` is on the user's `PATH`, and
reports it missing otherwise.

Off, three things step back, and each reads the flag directly:

- **`IdeIntegration.opencode.builtIn` becomes `false`**, so `serverpod create`
  is no longer told to configure it on every new project. See the New projects
  section: `_neverInferred` in `project_settings.dart` had to stop keying off
  `builtIn` for this, because the projects that already carry an `opencode.json`
  are still on disk.
- **The left panel drops its Agent tab** and shows the server log alone, and
  **Settings drops its Providers tab** — which configures keys for this agent
  and nothing else, so one pane is left and the tab strip goes with it. The
  dialog coerces a caller asking for Providers onto Tools: the App menu still
  asks, and that pane's "waiting for the agent" spinner would never resolve.
- **`AgentController` never listens for a project**, so no `opencode serve` is
  ever spawned. It is still constructed, still handed to everything expecting
  one, and still stopped by `teardownSession`.

Tests that cover the switched-on behaviour are skipped, not deleted —
`test/support/agent_flag.dart` carries `skipWhenAgentOff` / `skipWhenAgentOn`.

- Agent tab hosts a Cursor-style chat driven by `opencode serve` (HTTP + SSE).
- Scoped to the open project directory; restart serve on project switch.
- **`opencode serve` starts as soon as a project opens — it does *not* wait for `previewReady`.** It only needs the project directory, and the Serverpod build it used to wait for takes minutes on a cold project, which left Settings unable to say which providers held a key. Starting early does not make the agent usable early: `canSend` still requires `previewReady` and `AgentPane` still shows its "Serverpod is starting" gate, so the main interface is unchanged. The trade is that the agent now outlives a server stop, which also makes a restart cheaper.
- API keys via Settings → Providers tab → OpenCode `auth.json` / `PUT /auth/{id}`.
- **Permissions:** `permission.asked` → reply with `POST /permission/{id}/reply`
  `{"reply": "once"|"always"|"reject"}`. Any other value is a 400 and the agent
  stays blocked forever, so never swallow the error — keep the card up.
- **Questions:** `question.asked` → `POST /question/{id}/reply` with
  `{"answers": [[label, …], …]}` (one list per question) or
  `POST /question/{id}/reject`. Both events carry `tool.{messageID,callID}`;
  the card is attached next to that tool part and the raw row is hidden.
- Ground truth for events/endpoints is the running server: `curl <base>/doc`.

## Hot Restart (Serverpod MCP) — switched off

**`kServerpodMcpEnabled` in `lib/feature_flags.dart` is `false`, and everything
in this section is dormant behind it.** The bridge cannot yet deliver a hot
restart to the runner App Studio starts; the code is all still here, and
flipping the flag to `true` brings it back intact. Read the rest of this section
as what happens when it is on.

Off, two things step back:

- **`McpController` registers no listeners**, so no project and no running
  server ever spawns a `serverpod mcp-server`, nothing is probed, the connection
  stays `idle` and `hotRestart()` finds no bridge. It is still constructed,
  still handed to `UpdateController` and the uninstaller, and `teardownSession`
  still awaits its `stop()`.
- **The toolbar keeps its Hot Restart button**, always enabled, opening
  `HotRestartComingSoonDialog` rather than restarting. The connection never
  leaves `idle`, so the rules below would otherwise leave it permanently
  disabled reading "start the server first" for a server that is running. The
  dialog points the user at their own AI agent, which reaches the same Serverpod
  MCP tool today, and at Full Restart next to it.

Tests covering the switched-on behaviour are skipped, not deleted —
`test/support/mcp_flag.dart` carries `skipWhenMcpOff` / `skipWhenMcpOn`.

The toolbar's **Hot Restart** button recompiles and reboots the running server,
then hot-restarts the Flutter app and force-reloads the preview. It goes through
`serverpod mcp-server`, the CLI's own MCP bridge —
`lib/mcp/serverpod_mcp_bridge.dart` speaks the protocol, `McpController` owns the
policy, `HotRestartButton` is the one control.

- **It runs the bridge's `hot_restart`, and the button says so.** `hot_reload`
  also exists and is *not* what this is: it preserves in-memory state and skips
  the server reboot, which means it does not pick up a change to `main()`.
  Switching is a one-line change in `McpController.hotRestart` — a behaviour
  change, and the label would have to move with it.

- **Transport is stdio MCP** — newline-delimited JSON-RPC 2.0, protocol
  `2024-11-05`…`2025-11-25`, server name `serverpod-bridge`. We use
  `package:dart_mcp`, which is the *same* package the bridge is built on, so the
  two ends cannot drift. Ground truth is the running bridge: pipe an
  `initialize` + `tools/list` into `serverpod mcp-server` and read the answer.
- The bridge forwards to a unix socket the runner opens at
  `<serverDir>/.dart_tool/serverpod/mcp.sock`. **Nothing has to be enabled on
  `serverpod start`** — the socket is unconditional, in both TUI and `--no-tui`
  mode, so App Studio's `--no-tui` runner is fine. No flag, no env var.
- `serverDir` is auto-detected from the working directory, and we hand the bridge
  the *same* project root `serverpod start` gets. Both ends then run the same
  detection and cannot end up pointed at different projects. Do not compute the
  `*_server` path here — nothing else in the app does either.
- **The bridge starts and answers happily with no runner behind it**, and
  `tools/list` returns the full surface either way, so "the bridge is up" says
  nothing about whether anything can be delivered. The only honest signal is the
  `serverpod://vm-service` resource: `{"uri": …}` with a runner,
  `{"uri": null, "error": "not-running"}` without — and the latter is *not*
  flagged as an error result, so the payload has to be read.
- That answer is **polled** (2s). The bridge only re-emits resource updates from
  a runner it is already talking to, so nothing arrives to announce a runner's
  *arrival* — subscribing would not help. Polling stops while a hot restart is in
  flight, so the button cannot flicker disabled mid-restart.
- Spawned with **`-q`** (a *global* option, so it precedes the command) and every
  stdout line that is not a JSON object is dropped before it reaches the
  protocol. The CLI's update notice is written to stdout, which is the protocol
  channel, and one stray line is a parse error that takes the connection down.
  Dropped lines are kept as diagnostics and reported.
- **Shut the bridge down by closing the protocol channel, never by killing it.**
  A `SIGKILL`ed bridge leaves the runner writing into a dead socket, which it
  reports in the user's server log as an internal error with a 35-frame stack
  trace and a "file an issue" banner. `stop()` closes the channel, waits, and
  only then falls back to a signal; `teardownSession` awaits it for the same
  reason the server and agent are awaited.
- **The runner's socket accepts one client at a time and evicts the previous
  one.** Our bridge therefore displaces an IDE-spawned `serverpod mcp-server`
  for the same project, and it displaces ours. Calls reconnect lazily, so this
  self-heals, but it is why two App Studio windows on one project would fight.
- **A success force-reloads the preview** via
  `ServerpodProcessController.requestPreviewReload()`. The runner does trigger a
  browser refresh of its own (`✓ Browser refresh triggered.` in the server log)
  and the preview does come back without us — but that goes through DWDS and
  leaves the cached `main.dart.js` in place, so it cannot be *trusted* to be
  showing the code that was just compiled. Ours ignores the cache. Only on
  success: reloading after a failed restart would just re-serve the old app and
  make it look like the restart worked.
- `hot_reload` exists on the bridge too, along with migrations, log tails and
  `get_flutter_app_dtd`. Only `hot_restart` is wired up.

### The restart surface is two buttons, and that is all of it

**Hot Restart** (fast, MCP) and **Full Restart** (slow, process). Both are
`ToolbarActionButton` — an outline icon button with a spinner in the icon's place
while busy — so they cannot drift in size or spinner size sitting next to each
other.

- **Icon-only, so the tooltip is load-bearing** and carries the name as well as
  the reason it is unavailable. `label` is still passed: it becomes
  `semanticLabel`, which is otherwise the icon glyph and nothing.

- **Full Restart replaced separate Start and Stop icons.** They were two controls
  for one question, and the pair invited the state that actually breaks things:
  stopped on purpose, with a preview pane and an agent still waiting for a server
  that is never coming back. `ServerpodProcessController.restart()` is stop → wait
  → start.
- **It stays enabled with the server stopped**, where it is a plain start. That is
  the recovery path after a crash or a failed compile, and it is now the only
  control that can bring the server back — disabling it there would strand the
  user. `test/process/full_restart_button_test.dart` pins this.
- **`restart()` waits for the preview port to go quiet before starting.** `stop()`
  returns once the PTY is reaped, but the runner's children can outlive the
  process-group kill by a moment and they still hold the port; a start that races
  them comes up unable to bind, which reads as a broken restart rather than a
  collision. Bounded at 5s, then `releaseTcpPort` takes the port back — the same
  reclaim `main()` runs on launch.
- **`isRestarting` spans the stop *and* the start.** Without it the UI sees a
  moment of `ProcessState.idle` between them and flips the button to "start the
  server", which reads as the restart having failed. `isTransitioning` is what the
  button actually reads.
- The button talks to `FullRestartView`, not the controller, for the same reason
  `ToolsView` exists: the state rules are worth testing without spawning a real
  Serverpod runner.

### Open in … — handing the project to an external editor

One `ShadButton.ghost` per external editor, reading **“Open in Cursor”** with a
trailing `LucideIcons.arrowUpRight`, between the toolbar's project path and the
restart buttons. `ui/open_in_editor_buttons.dart` draws them,
`session/external_editors.dart` decides which exist, and the widget imports only
`ExternalEditorsView` — the same narrow-interface split as Hot/Full Restart.

- **A button appears only when all three are true**: the project was configured
  for that editor, the editor's `.app` is on this Mac, and we know a way to hand
  that app a folder. The third is a hardcoded map (`_editorApps`), not a probe.
- **`open` cannot tell you whether it worked**, which is why that map is
  conservative. It exits 0 for an app that launched and ignored the path exactly
  as it does for one that opened it; a non-zero exit only means the *bundle*
  could not be launched. A button that silently does nothing is worse than an
  absent one.
- **Most of it goes through `open`**, which hands the request to LaunchServices
  and so routes it to the copy that is *already running*. Three forms:
  - **The folder as a document** — `open -a <bundle> <path>`, for VS Code,
    which declares `public.folder` in `CFBundleDocumentTypes`.
  - **A deep link** — `open <scheme>://…`, for Claude
    (`claude://code/new?folder=`), Codex (`codex://threads/new?path=`) and
    OpenCode (`opencode://open-project?directory=`). None of the three takes a
    folder as a document; all need the path percent-encoded. The installed
    check matters *most* here: `open <scheme>://…` exits 0 even when nothing
    claims the scheme.
  - **The editor's own CLI**, for Cursor alone — see the next section.
- **Claude's host is `code`, not `cowork`.** Both are real routes on `/new` and
  both take `folder`, but `cowork` lands in Cowork with the directory merely
  selected while `code` opens a Claude Code session in it — confirmed by
  `LocalSessions.checkGhAvailable: cwd=<project>` in `~/Library/Logs/Claude`.
  The `open-file` handler the bundle also registers goes to Cowork too, which
  is why the deep link is preferred over handing it the folder as a document.
  No `q`/`prompt` is sent: that would prefill *and* start a task, and the
  button only promises to open the project.
- **Antigravity is the one `IdeIntegration` with no button.**
  `/Applications/Antigravity.app` is not the IDE — it is a thin Electron shell
  around a Go language server, with no `open-file` handler and no
  `CFBundleDocumentTypes`, so a folder handed to it is dropped. The editor is a
  separate bundle, `Antigravity IDE.app`, and no route into it has been
  confirmed. It is out only because no build of it has been seen to open the
  folder it was given.
- **Order is preference order**, and `ProjectStartedDialog` features the first.
  OpenCode is last deliberately: it only appears when the box was ticked, but
  App Studio already runs it in the Agent tab, so an editor it does *not* have
  is the more useful next step to feature.
- **Launch is by bundle path, not by name.** `open -a "Visual Studio Code"` asks
  LaunchServices to resolve the name, which can land on a different copy than
  the one `_findApp` checked for. `/Applications` is searched before
  `~/Applications`. The CLI route joins onto that same found path, so it cannot
  drift from it either.
- A failed launch posts a notification with `force: true` — the user just
  clicked a button in this window, so App Studio is frontmost and
  `StudioNotifications` would otherwise suppress it.
- **The buttons are disabled, not hidden, until `PreviewPhase.ready`**
  (`ProjectReadyView.projectIsReady`). An editor opened mid-compile attaches to
  a server that cannot answer it, and a control that materialises minutes later
  is one the user never learns is there. `ShadTooltip` needs the
  `ShadGestureDetector` wrapper to open over the disabled button.
- **The toolchain badge no longer shows a version.** It used to sit in this spot
  permanently reading `managed 3.35.0` — a number the user cannot act on.
  `_ToolchainWarningBadge` now draws nothing unless `missingRequired` is
  non-empty. That half has to stay: a required tool we cannot supply never
  reaches the first-run setup screen, so the badge is the only place it surfaces.

### Cursor goes through its CLI, because `open` cannot reach the Agents Window

`open -a Cursor <folder>` always opens a **classic editor window** on the folder
and leaves the **Agents Window** sitting on whatever project it already had. For
a user who works in that window, “Open in Cursor” read as pointing at the wrong
directory. The fix is to spawn what Cursor's own `bin/cursor` script spawns:

```sh
/usr/bin/env ELECTRON_RUN_AS_NODE=1 \
  <bundle>/Contents/MacOS/Cursor <bundle>/Contents/Resources/app/out/cli.js <path>
```

- **Cursor routes on how the request arrived, and only the CLI reaches that
  window.** In `out/main.js`, `resolveGlassCliFolderTarget` sends a folder to the
  Agents Window (internally *glass*) as `vscode:createNewComposer`, gated on
  `openContext === 0` — which comes from `VSCODE_CLI=1`, and **only `cli.js` sets
  it**. `open -a` arrives as a dock open, and the dock branch
  (`getExternalWorkspaceOpenSource` → `dockWorkspace`) requires
  `!!urisToOpen[0].workspaceUri`, i.e. a `.code-workspace` file. A plain folder
  can never reach the Agents Window from there.
- **Through the CLI, Cursor adapts on its own** and we encode no policy: Agents
  Window last active gets a new agent scoped to the folder, a classic window last
  active gets a classic window, and a project already open is focused rather than
  duplicated. All three measured against Cursor 3.15.6.
- **This is not the `cursor` shim on `PATH`.** Both files ship inside every
  bundle, so nothing has to be installed; the shim at `/usr/local/bin/cursor`
  that Cursor's own “install the command” action creates is never consulted.
  `_resolveCli` checks both paths exist and falls back to `open -a` if they do
  not, so a future layout change downgrades the button instead of breaking it.
- **Addressed inside the bundle rather than through
  `Contents/Resources/app/bin/cursor`.** That script is `#!/usr/bin/env bash`, so
  it needs a `PATH` we do not control, and it carries a branch that will
  `curl … | bash` an agent binary onto the machine when argument one is `agent`.
- **An older note here said a bundled CLI starts a second copy of the editor.
  That does not reproduce.** Spawned with launchd's bare `PATH` — what a Finder
  launch inherits — the running instance was reused every time, the helper-process
  count never moved, and the call returned in ~1.2 s.
- **A deep link cannot do this, and it is the obvious thing to try.**
  `cursor://file/<path>` does open the folder, but it arrives as a *protocol*
  open, which is excluded from the Agents Window routing exactly like the dock
  is — so it still yields a classic window, fixing nothing. It also first raises
  Cursor's own “An external application wants to open … it may represent an
  attempted attack on your system” confirmation
  (`security.promptForLocalFileProtocolHandling`).
- The `cursor://` scheme's other routes are agent-shaped and take no folder:
  `anysphere.cursor-deeplink/glass` focuses the Agents Window but cannot target a
  project, and `/command` writes a slash-command file rather than running one.

## Child processes and teardown

App Studio spawns four long-lived children: the `serverpod start` PTY, `opencode
serve`, `serverpod mcp-server`, and CEF's helpers. Getting them all down is
harder than it looks, and the failure is silent — an orphan is reparented to
launchd, where nothing will ever clean it up. This was found with **17 orphaned
`opencode serve` processes** on one machine, accumulated over days, one per
session.

Three mechanisms, and all three are needed:

1. **`AppLifecycleListener.onExitRequested`** (`main.dart`) is the *only* place a
   quit can be awaited. `dispose()` is synchronous, and on ⌘Q the isolate is
   killed at the OS's convenience — measured: the server and the bridge died with
   us because they are stdio/PTY-coupled, but `opencode serve` is an ordinary
   `Process.start` child and survived **every** quit. `AppDelegate` must keep
   *not* overriding `applicationShouldTerminate`, or this hook stops firing.
   It always answers `AppExitResponse.exit`: refusing would make the app
   unquittable, which is far worse than a stray process.
2. **An awaitable `stop()` on every controller that owns a child.**
   `AgentController.stop()` and `McpController.stop()` exist for this and are
   what `teardownSession` calls. It used to call `agent.dispose()`, which could
   only fire the teardown and return — the stop was never awaited by anyone.
3. **A pid file per child, reclaimed on next launch** (`dev_session_cleanup.dart`,
   `DevProcessKind`). The backstop for a crash, a `kill -9`, and a Flutter hot
   restart — which re-runs `main()` without `dispose()`, so the previous
   isolate's children are already orphaned by the time the new one starts. Only
   the PTY used to register, which is why only the PTY was ever reclaimed.

### The group-kill trap

`Process.killPid(-pid, …)` signals the process *group* led by `pid` — and reports
failure by **returning `false`, not by throwing**. The old reclaim wrapped it in
a `try`/`catch` with a single-pid fallback in the `catch`, so the fallback never
ran. That mattered because only a child that called `setsid` leads its own group:
the PTY does, so `-pid` reaches its whole tree, but a plain `Process.start` child
inherits our group and leads nothing, so `-pid` matched **nothing, silently**.
That is how orphaned agents survived every launch even with a reclaim in place.
`_signal` now branches on the return value. `test/process/dev_session_cleanup_test.dart`
pins it against a real child.

### `OpenCodeServe` publishes its handle late, so starts must be generation-guarded

`_process` is assigned two awaits after `start()` begins (`_freePort`, then
`Process.start`). A second start arriving in that window found `_process == null`,
killed nothing, and then *overwrote* the handle when the first one finally
published — stranding a live serve that nothing could reach again, which is
exactly the "one orphan per port" signature. Every start now takes a generation
and kills its own process if it finds itself superseded; `stop()` bumps the
generation too, so it cancels a start in flight. Concurrent starts are reachable
from a provider save/remove landing on top of a project start, and from `process`
notifying on every poll tick.

- **Claim state *before* awaiting a teardown, not after.** `_startForProject` and
  `_restartServePreservingChat` set `_boundProjectPath`/`_connection` first, then
  tear down with `keepClaim: true`. Setting them afterwards left a window where
  `_onSessionOrProcessChanged`'s idempotency guard saw an idle, unclaimed
  controller and started a second serve.
- **`startForSettings` claims `_startedForSettings` before its first await and
  re-checks it after.** Set after, a Settings dialog closed mid-start found the
  flag false, declined to stop, and left a scratch serve nobody owned; and
  without the re-check the start proceeded even after being disowned.

### Known gaps, deliberately not fixed

- `dart pub get` (`serverpod_process.dart`) and `serverpod create`
  (`project_creator.dart`) keep no handle and are never killed. Quitting during a
  cold first run leaves a `pub get` to finish on its own. They exit by themselves;
  a cancellation path is real work.
- Neither `OpenCodeServe.stop()` nor `ServerpodMcpBridge.stop()` group-kills, so a
  grandchild (an LSP server opencode spawned) could outlive its parent. Not
  observed — every orphan found was the direct child — and a group kill on a
  non-leader is a no-op anyway, so this needs the child in its own session first.
- `tool_probe.dart` times out its version probes with `Future.timeout`, which does
  not kill the process. A wedged probe binary is orphaned.

## Setup & toolchain

### Prerequisites (dev machine)

- **Flutter 3.44+** / **Dart 3.12+** (host SDK for building App Studio itself)
- **CEF / webview_cef:** `brew install cmake ninja`; then `cd macos && pod install`  
  (CEF binaries download into `packages/webview_cef/macos/third/cef/` — gitignored)

### First-time / day-to-day (Makefile)

```bash
make deps              # pub get + CEF/pods (once, or when CEF is missing)
make start             # flutter run -d macos
make clean             # drop build/ + dist/ (keeps CEF, Pods)
make clean_all         # also drop CEF, Pods and any old toolchain/ trees
make build_debug       # unsigned zip
make build             # Developer ID + notarized zip
```

`start` / `build` / `build_debug` only need CEF; the app installs its own tools.

**Stale-embed trap:** Xcode never deletes unknown files under `Contents/Resources`, so a build tree from before the toolchain moved out keeps a ~1.8 GB embed alive — it gets re-signed on every release and shipped in the archive (2.1 GB app instead of 350 MB). `distribute_macos.sh` deletes it defensively; `make clean` is the honest fix.

### How tools get onto the Mac

App Studio installs nothing privately. Each tool is installed **the way its own
instructions say, into the place they name**, so the user's terminal, their
editor and any AI agent see exactly the tools App Studio runs:

| Tool | Installed with | Lands in | `PATH` line |
|---|---|---|---|
| Apple's command line tools | `xcode-select --install` (Apple's own dialog) | `/Library/Developer/CommandLineTools` | — |
| Flutter SDK | official archive from `releases_macos.json`, `unzip` | `~/develop/flutter` | `export PATH="$HOME/develop/flutter/bin:$PATH"` |
| Serverpod CLI | `dart install serverpod_cli@<version>` | `~/Library/Application Support/Dart/install/bin` | `export PATH="$PATH":"$HOME/Library/Application Support/Dart/install/bin"` |

- **The order is load-bearing.** Flutter runs on the CLT's `git`, and `dart
  install` runs `install_name_tool` through the `/usr/bin` shims, which the
  CLT make real. The Serverpod CLI is installed with the just-resolved
  Flutter's `dart`. `ToolchainInventory.installable` is always in `ToolId`
  order, and the controller refreshes between steps so each step sees the one
  before it. The first failure ends the run — nothing after it could work.
- **Versions come from `assets/toolchain_manifest.json` (schema 2) — ranges,
  nothing else.** A fresh install takes the newest release inside the range:
  the newest *stable* Flutter for this arch in Flutter's own feed, and the newest
  non-retracted Serverpod CLI on pub.dev, preferring stable (pub's own rule).
  Flutter's range deliberately has **no upper bound**: installs take the latest
  stable and `flutter upgrade` goes to the latest stable, so a ceiling would put
  the two at odds the day a new minor ships. There is no published manifest and
  no user-raised minimum any more.
- **`ToolsView.preflight()` looks the versions up** (`install_plan.dart`) — the
  plan dialog shows them, and a HEAD on the Flutter archive gives its size. It
  is the only network step before an install, and its failure is what the setup
  error dialog reports.
- **The Flutter archive is verified against the feed's sha256**, unzipped into
  `~/develop/.flutter-install-<stamp>` and renamed into place, so a crash leaves
  a staging directory (`collectGarbage` clears it) rather than half an SDK.
  `unzip` is real in `/usr/bin` — not one of the CLT shims — and is what
  Flutter's own instructions use.
- **`~/develop/flutter` is never overwritten unless App Studio put it there.**
  An empty directory is removed; anything else stops the install and says
  where. `flutter precache --web` runs after, best effort — Flutter fetches the
  same components on the first web build.
- **Apple's installer reports nothing, so it is polled.** `xcode-select
  --install` returns at once; the installer polls `xcode-select -p` for a real
  `git` every 3 s. It also watches for the `Install Command Line Developer
  Tools` process, so a window closed early reads as a failure after 15 s
  instead of an endless wait. Cancel stops the wait, not Apple's installer.
- **Apple's installer opens behind App Studio**, where a user reading "follow
  the installation steps in the pop-up window" cannot find it. Once its
  process appears it is brought forward with `open -b
  com.apple.dt.CommandLineTools.installondemand` — twice, a poll apart, since
  the window can follow the process. `open` on a running app activates it
  through LaunchServices and needs no automation permission, which an
  AppleScript `activate` would.
- **A copy App Studio did not install is never changed**, with one exception.
  - An old **Flutter** of the user's gets `ToolAction.manual`: setup blocks on
    `ManualUpdateDialog`, which gives the exact command (the SDK's full path,
    plus `channel stable` when it is on another channel) and a **Check again**
    button that re-probes without a restart. Installing a second SDK beside it
    would leave the old one first on their `PATH`.
  - An old copy **App Studio installed** is `ToolAction.update` — it runs
    `flutter upgrade` itself. A *broken* one of ours is replaced.
  - The **Serverpod CLI** is the exception: `dart install` replaces it in
    place and is cheap, so an old one is reinstalled whoever put it there. A
    copy the user had put in the `dart install` directory stays theirs in the
    record, so uninstall never offers to remove it.

### The install record — `~/.serverpod/app_studio_installs.json`

`InstallRecord` (`install_record.dart`) lists every tool App Studio installed,
with its path, version and **every `PATH` line it wrote, as `{file, line}`**.

- **It is what makes a tool App Studio's.** `ToolSource.appStudio` vs
  `ToolSource.host` (the Tools tab's "App Studio" / "Native" badges), whether an
  old Flutter is `update` or `manual`, and what uninstall prefills all read it.
- **A `PATH` line is recorded only if App Studio wrote it.** `addToShellPath`
  writes nothing when the directory is already on the user's login-shell `PATH`
  or the exact line is already in the file — a line that was already there is
  not ours to remove later.
- **The profile is `~/.zprofile` for zsh** (what Flutter's macOS instructions
  say) and `~/.bash_profile` for bash. Any other shell gets the lines shown in
  Settings → Tools to add by hand (`manualPathLines`). Both the Flutter line
  and Dart's go in the same file so they are found together.
- **Edits resolve symlinks first** and write through a temp file and a rename.
  Dotfile managers link these files; renaming over the link would detach the
  user's config from their repo.
- **Flutter is recorded before its first run**, so an install interrupted during
  `flutter precache` is still one App Studio knows it owns and can replace.
- A missing or corrupt record reads as "nothing installed by App Studio" —
  it only costs the uninstall prefill and the auto-update of an old Flutter.

### Upgrading from a build that shipped its own tools

Earlier builds kept every tool under
`~/Library/Application Support/App Studio/toolchain`, wrapper scripts in
`…/App Studio/bin`, and a fenced `# >>> App Studio >>>` block in `.zshrc` /
`.bash_profile` / `.profile` pointing at the wrappers.

- **`ToolchainInventory.legacyInstallFound` is part of `needsSetup`**, so a
  legacy user always lands on the setup screen — even when every tool is
  already on the Mac. Step one there is `LegacyInstallNotice`, which says what
  changed, **but only when no Flutter is on the Mac** (`flutterFound`). With
  one already there — usable or too old — App Studio just uses it, so there is
  nothing to announce; an old one gets the update prompt next, which says what
  it needs. Either way `removeLegacyInstall()` then runs: the three legacy
  directories (`ToolchainPaths.legacyPaths`, including the pre-rename
  `AppStudio` directory) and the fenced block in every rc file it could be in.
  Then setup carries on as a first run.
- **The old managed tree is never read.** The probe does not look there, so an
  un-migrated install simply reads as missing tools — there is no state in
  which the app runs on the old copies.
- Uninstall runs the same cleanup, so a legacy block cannot survive it either.

### Tool resolution (in the app)

- `ToolchainController` (`lib/toolchain/toolchain_controller.dart`) owns the resolved `Toolchain`. **Consumers read `toolchains.current` at call time — never capture it**, or they strand on a snapshot taken before the user installed anything.
- Every candidate is an ordinary install somewhere on the Mac; the record decides whether it is App Studio's. Flutter roots, in order: `FLUTTER_ROOT`, `flutter` on `PATH`, the recorded path, `~/develop/flutter`, `~/development/flutter`, `~/flutter`, `~/fvm/default`.
- Executable getters are **nullable**. Spawn sites check `toolchain.unavailableReason(id)` first; a bare command name would only defer the failure to `Process.start`.
- `Toolchain.resolve()` short-circuits at the first satisfied candidate (~350 ms). `deep: true` enumerates every candidate and is only for the Tools tab — the full sweep is too slow to run before `runApp`.
- **The Command Line Tools are satisfied by `xcode-select -p` pointing at a directory with a real `usr/bin/git`** — the standalone tools or a full Xcode. Never execute `/usr/bin/{git,otool,install_name_tool,clang,ar,ld}` to find out: they are the CLT shims and pop a modal installer. Only App Studio's own install step opens that installer, on purpose.
- Flutter is version-detected from `bin/cache/flutter.version.json`, never by running `flutter --version` — that can trigger a precache download on a cold SDK. The web-artifacts check is gone: it existed for the precached SDK App Studio used to ship.
- `ToolProbe` takes an injectable `environment` for `PATH`, `FLUTTER_ROOT` and `PUB_CACHE`; tests that probe would otherwise find the Flutter on the machine running them.
- **`PATH` is searched by `whichOnPath`, in Dart — never by shelling out to `/usr/bin/which`.** Every probe subprocess runs with `includeParentEnvironment: false` so a user's environment cannot sway version output, and `which` inherited that empty environment, so it had no `PATH` and returned null for *everything*.
- **A GUI launch only inherits launchd's `PATH`, so the probe falls back to the user's login shell** (`login_shell_path.dart`). Opened from Finder, `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else, so a Flutter outside the conventional roots and a `dart install`ed Serverpod CLI both resolved to nothing — and the app offered to install tools the Mac already had. The installer uses the same capture to decide whether a `PATH` line is needed.
  - The shell runs `-l -i -c`, and **the `-i` is the load-bearing flag**: `.zshrc` is the *interactive* rc and is where many users and installers put their `PATH` lines, while a login-only shell reads `.zprofile` and misses them. Terminal.app is login+interactive, so this reproduces what the user sees when they type `flutter` themselves.
  - **It is a fallback, not a replacement.** `_which` tries the inherited `PATH` first and only then spawns a shell (~80 ms). The result — including a failure — is memoised per `ToolProbe`.
  - **Discovery only.** Candidates found this way are still executed by absolute path under the probe's own controlled environment.
  - **Do not wait for the shell's stdout to reach EOF.** The shell's children inherit that pipe, so an rc that backgrounds anything holds it open long after the answer is written. The reader completes on the closing marker instead, which is also what makes the timeout fire. `${PATH}` is braced for the same class of reason: unbraced, the trailing marker is read as part of the variable *name* and the answer comes back silently empty.
- **Serverpod's candidates check `~/Library/Application Support/Dart/install/bin` first**, ahead of `~/.pub-cache/bin`. That is where `dart install serverpod_cli` puts it; the pub-cache copy is the one that goes stale.
- `PUB_CACHE` is deliberately **not** set: `package_config.json` stores absolute paths, so a private cache would make every switch to an external editor re-resolve the project.
- Version rules live in `tool_version.dart`. A numeric-only suffix is a *packaging revision*, not a prerelease — `2.53.0-3` is newer than `2.53.0`, while `4.0.0-beta.1` is older than `4.0.0`.

### One bucket, two URLs — and which one a caller may use

`gs://serverpod-appstudio-toolchain` is reachable both directly and through a
Cloud CDN, and **mixing the two up is the hazard.** `tool/lib/bucket_urls.sh`
owns the distinction; nothing derives one URL from the other.

- **Origin** — `https://storage.googleapis.com/<bucket>/` — is the bucket
  itself, and every **publish-time read** uses it. `object_exists` /
  `published_sha`, the re-download-and-re-hash verification, the appcast
  read-back, and `published_max_build`'s feed read are all asking what is *in
  the bucket*, and a cached answer is not an answer to that question.
- **Public** — `https://asdl.serverpod.dev/` — is the same bucket behind the
  CDN, and every URL handed to a **user** uses it: the appcast enclosures, the
  `downloads/macos.json` links, and `SPARKLE_FEED_URL`.
- **The build-number gate is the one that cannot be allowed to read stale.** A
  low answer from `published_max_build` approves a build number already
  published, which blinds every installed copy to updates forever and cannot be
  undone. `set_version.sh` and `publish_dist.sh` both read the origin feed, and
  `fetch_uncached` cachebusts on top of that.
- **The origin URL must keep working forever.** Every copy of App Studio built
  before the CDN existed has it compiled in as its Sparkle feed. The CDN is a
  second route to one bucket, not a move; retiring the old URL strands those
  installs permanently.
- **The `tools/` objects and `manifest.json` stay in the bucket.** Nothing
  publishes them any more — App Studio installs its tools from their official
  sources now — but builds from before that change still download from them on
  first run, and they have to keep working until those builds update.
- **`--bucket=NAME` falls back to the origin for the public URL too**
  (`public_base_url`). The CDN fronts exactly one bucket, so stamping its host
  into a feed built from a different one yields downloads that 404 — or,
  worse, silently resolve to the production object sharing that path.
- **Only the mutable objects are invalidated** — `appcast.xml`
  (`max-age=300`) and `downloads/macos.json` (`max-age=60`).
  `invalidate_cdn_path` is best-effort and returns 0: the object is already in
  the bucket, the TTL it waits out is minutes, and everything that must not be
  stale reads the origin anyway — so failing a release that already succeeded
  would be the worse outcome. Invalidating an immutable object is meaningless
  and the quota is small, so nothing else gets one.
- **Negative caching is off on the backend bucket, deliberately.** The cache
  mode enables it by default and would hold a `404` for 120 s; every publish path
  here probes for object *absence*, so a freshly published object answering 404
  from the edge would resolve an archive to the wrong build number.
- The CDN is a global external Application Load Balancer in the same project
  (`serverpod-appstudio`): backend bucket `asdl-backend`, url map `asdl-url-map`,
  Google-managed cert `asdl-cert`. Those names are in `bucket_urls.sh` because
  the invalidation needs them.

### Release / distribute

Releasing is **two deliberate halves**, so a build can be tested on another
Mac before any existing install is offered it:

```bash
make release V=1.2.3      # set the version + build + notarize + upload —
                          # downloadable by direct URL, NOT yet an auto-update
make promote              # add it to the appcast: auto-update goes live

make set_version V=1.2.3  # the individual steps release is made of
make build                # signed + notarized zip in dist/, nothing uploaded
make publish              # upload the built zip (re-runnable: identical bytes
                          # are recognised and skipped)
make build_debug          # unsigned, local only, never uploaded
```

`make publish` (`tool/publish_dist.sh`) uploads the zip and its `.sha256`
sidecar and moves the **preview** entry of `downloads/macos.json`; the appcast
is untouched, so existing installs see nothing. `make promote`
(`tool/publish_appcast.sh`) is the step that reaches users — it confirms
interactively, inserts the build into the feed, and catches the **latest**
entry up.

**`downloads/macos.json`** is the pointer the website's download page reads:
`latest` (the newest build in the appcast) and `preview` (the newest upload,
which may not be promoted yet), each a full URL plus version, build and sha256.
When nothing awaits promotion the two entries are identical. It is mutable,
served with `max-age=60`, and derived entirely from published state by
`tool/publish_downloads.sh` — both publish scripts re-run it, so it never
needs running by hand and is always safe to re-run.

Defaults, all overridable from the environment: bundle id
`dev.serverpod.appstudio`, team Serverpod AB (`WK2NRY4GS4`),
`SIGN_IDENTITY="Developer ID Application: Serverpod AB (WK2NRY4GS4)"`,
`NOTARY_PROFILE=appstudio`, `NOTARIZE=0` (the make targets set it to `1`). The
zip lands in `dist/macos/`.

**Notarizing needs a one-time credential**, stored in the Keychain under the
profile name the scripts look for — an App Store Connect API key, not an Apple
ID password:

```bash
xcrun notarytool store-credentials "appstudio" \
  --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
  --key-id "XXXXXXXXXX" \
  --issuer "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

**An unsigned build (`SIGN_IDENTITY="" ./tool/distribute_macos.sh`) reads as
corrupt once it has been copied to another Mac** — Gatekeeper says “App Studio
is damaged and can't be opened”, which is quarantine rather than actual damage.
`xattr -cr "/Applications/App Studio.app"` clears it. Prefer shipping a notarized
build; this is for a build that never leaves the machine.

**Artifact is a `.zip`, not a DMG.** Built with `ditto -c -k --norsrc
--keepParent` — plain `zip` mangles symlinks and the CEF framework is full of
them, and **`--norsrc` is load-bearing**: without it ditto archives the build
machine's xattrs as inline `._foo` AppleDouble entries, which Archive Utility
extracts as literal files (it only folds the sequestered `__MACOSX` form back
into xattrs). Those land as unsealed contents in every framework root and
Gatekeeper rejects the app — "unsealed contents present in the root directory
of an embedded framework" — for anyone who unzips by double-clicking in
Finder, while Safari's auto-extract goes through ditto itself and hides it.
`make_zip` asserts the archive is clean. The app is
notarized, then **stapled, then re-zipped**: a zip cannot carry a ticket but the
app inside it can, and Sparkle installs that app directly. The bundle is
`App Studio.app` (with a space); download filenames stay `AppStudio-…` so URLs
are typeable.

### Build numbers are a global counter — this one is unfixable

`+N` in `pubspec.yaml` becomes `CFBundleVersion`, which is **the only thing
Sparkle compares**. It must increase on every release and must **never reset**
when the marketing version changes: `1.0.0+7` → `1.1.0+8`, not `1.1.0+1`. A
repeat or a rollback makes every installed copy see "you're up to date" forever,
and because published objects are immutable it cannot be fixed by re-uploading.

Never hand-edit the version. Use `make set_version V=1.2.3` (or
`V=patch|minor|major|build`), which reads the live appcast **and** the
`downloads/macos.json` pointer — the latter is what knows about a build
uploaded but not yet promoted, which the appcast alone under-reports — and
picks a counter that clears everything, including releases made from another
checkout. `publish_dist.sh` re-checks the appcast gate before uploading. All
of it shares `tool/lib/pubspec_version.sh`;
`test/tool/version_gate_test.dart` covers it.

`tool/publish_dist.sh` derives the path from `pubspec.yaml`
(`version: 1.0.0+1` → `releases/macos/1.0.0/b1/AppStudio-1.0.0-arm64.zip`)
and uploads with `--if-generation-match=0`, so objects are immutable — a
re-release means bumping the build number, never overwriting a URL someone
already has. A `.sha256` sidecar goes up alongside it. A re-run for bytes
already published is recognised (via the sidecar) and skipped, so `make
publish` is idempotent; the same path holding *different* bytes is a hard
error.

Four gates run before any upload, all verified to reject:
- the build number must beat every `sparkle:version` in the live appcast,
- the archive is **unpacked** and its `CFBundleShortVersionString` *and*
  `CFBundleVersion` must match pubspec (stops a stale archive being served
  under a new version number),
- it must contain no `Contents/Resources/toolchain` (stale embed),
- it must have a stapled notarization ticket (`--allow-unnotarized` overrides
  for internal builds, and says so loudly).

Reference sizes for a clean, notarized build: **.app 350 MB** (CEF is 302 MB of
it). If you see ~2.1 GB, the build tree is stale — run `make clean`.

## Auto-updates (Sparkle)

Sparkle 2.9.5 via Swift Package Manager, pinned in `Package.resolved`. A small
Swift bridge (`macos/Runner/SparkleUpdater.swift`) exposes it to Dart over
`dev.serverpod.appstudio/updates`; `lib/update/` is the Dart half.

Sparkle owns the update UI. A Flutter dialog cannot show install progress after
our own process has terminated, which is exactly when it matters.

```
appcast/macos/appcast.xml       MUTABLE — what installed copies poll (max-age=300)
downloads/macos.json            MUTABLE — latest + preview links for the website (max-age=60)
releases/macos/<v>/b<n>/*.zip   immutable
```

- `SUFeedURL` / `SUPublicEDKey` come from `macos/Runner/Configs/Sparkle.xcconfig`,
  which **`Release.xcconfig` includes and `Debug.xcconfig` does not**. A debug
  build therefore resolves both to empty, reports `configured: false`, and greys
  the menu item out instead of trying to replace itself with a release build.
- **xcconfig treats `//` as a comment anywhere on a line, including inside a
  value.** Writing the feed URL literally silently truncates it to `https:`.
  That is why the file builds the slashes from `$(SPARKLE_SLASH)`. Verify with
  `PlistBuddy -c 'Print :SUFeedURL'` on the built `Info.plist` after any change.
- `SUAllowsAutomaticUpdates` is `false`, which removes the silent-install option
  from Sparkle's UI entirely. An unattended relaunch would kill a running
  Serverpod server, the CEF preview and the agent with no warning.

### Behaviour under a running session

`UpdateController` **pushes** busy state to Swift (`setSessionBusy`) whenever
the server or agent starts or stops. Push, not pull: Sparkle asks its delegate
synchronously on the main thread, so calling back into Dart and waiting there
would deadlock the thread that has to produce the answer.

Scheduled checks are vetoed while a session is live; a user-initiated check
never is. Before relaunching, Sparkle waits on `prepareForRelaunch`, which runs
`teardownSession()` — the *same* function `dispose()` uses, so the quit path and
the update path cannot drift. It is time-boxed (15 s in Dart, 20 s in Swift):
leaving a stray process is better than stranding the user mid-install.

### Signing

Sparkle embeds nested bundles (`Versions/*/Updater.app`, `Versions/*/Autoupdate`)
and, by default, XPC services.

- The XPC services are **stripped by `distribute_macos.sh`, after the build and
  before signing** (`macos/Runner/Scripts/strip_sparkle_xpc.sh`). They exist
  only for sandboxed hosts. Leaving them in is not just dead weight: the wrapper
  signing pass matches `*.app` and `*.framework`, and an `.xpc` matches neither,
  so it would ship unsigned inside a framework we re-signed. The script also
  removes the framework-root `XPCServices` symlink — a dangling link there fails
  notarization with an opaque error.
- **A build phase is not enough, and this failed in practice.** Xcode embeds an
  SPM binary framework in an internal step that is *not* ordered after custom
  build phases, so any run that re-copies `Sparkle.framework` undoes a
  build-phase strip. It hides itself too: the next incremental build skips the
  copy and looks clean again. The build phase is still there for plain
  `flutter build` runs, but `distribute_macos.sh` does it at the one point where
  nothing can copy over the result, and asserts afterwards.
- Both wrapper `find`s use `! -type l`. `find` matches by name, and Sparkle's
  framework root is symlinks (`Updater.app`, `Autoupdate`, `Versions/Current`);
  without it they get signed *through* the link in depth-sort order.
- `codesign_one` carves Sparkle out of the `*.app` entitlements arm. Its helpers
  get hardened runtime and nothing else — handing `disable-library-validation`
  to the process that installs your updates is backwards.
- `distribute_macos.sh` asserts after signing: no `.xpc` survives, and each
  helper reports `TeamIdentifier=WK2NRY4GS4`, a `Timestamp=`, and no app
  entitlements.

### Back up the signing key — this is the unrecoverable one

`generate_keys` puts the ed25519 private key in the **login Keychain**;
`generate_appcast` reads it via `SecItemCopyMatching`, so it never touches a
command line or shell history. The public half is committed in `Sparkle.xcconfig`.

If that private key is lost, every already-installed copy has the old
`SUPublicEDKey` compiled in and becomes **permanently un-updatable through
Sparkle**. Recovery means a new key, a manually distributed build, and an
out-of-band notice to every user.

```bash
.sparkle-tools/<ver>/bin/generate_keys -x sparkle_private.pem   # export
# store in GCP Secret Manager, then:
rm sparkle_private.pem
```

Store it somewhere that does *not* also grant bucket write access: one
compromised credential should not be enough to ship a signed malicious update.
`publish_appcast.sh` refuses to run if a `*.pem` / `sparkle_priv*` / `*ed25519*`
file is sitting in the repo.

### Releasing

```bash
make release V=1.2.3     # set version -> build -> notarize -> upload
make promote             # add the uploaded build to the feed (confirms first)
```

`tool/ensure_sparkle_tools.sh` fetches `generate_appcast` / `sign_update` /
`generate_keys`, reading the version from `Package.resolved` rather than a
hardcoded constant — the tools and the embedded framework must be the same
release or the feed's signatures will not verify.

**The appcast is updated incrementally.** `publish_appcast.sh` downloads only
the one zip being promoted — from the *bucket*, never from `dist/`, verified
against its `.sha256` sidecar, because the feed describes the published object
and that object is what gets signed — runs `generate_appcast` over just that
file, and inserts the resulting item into the live feed. Existing items pass
through byte-for-byte with the signatures they already have, and only the new
enclosure is probed for reachability: the old flow re-downloaded, re-signed
and re-probed every published release (N×350 MB) to say something about one
build. Promoting a build already in the feed is a no-op that still refreshes
`downloads/macos.json`, so a half-finished promote can just be re-run.

`generate_appcast` only sees a flat directory, so it builds the enclosure URL
as `<prefix><filename>`; the script rewrites it to the real
`releases/macos/<v>/b<n>/` object and refuses an item that names any other
URL, a different build number, or no signature. Every release stays in the
feed forever — items are ~0.5 KB, and the monotonic build-number gate runs
against the feed itself before anything is inserted.

**The signing key is checked against the shipped key before anything uploads.**
`generate_appcast` signs with the Keychain private key; installed copies verify
with the `SUPublicEDKey` in their bundle. If those diverge, every update is
rejected by every install, silently, and no re-publish fixes it — the old
builds are already out there. When reading the key from the xcconfig, match to
end of line: base64 ends in `=`, so splitting on `=` yields an empty string.

**Deltas are off** (`--maximum-deltas 0`). `generate_appcast` enables them by
itself the moment two versions are present, and writes `<sparkle:deltas>`
enclosures for `.delta` files this script neither uploads nor knows how to
name — which put two dead URLs in the live feed before it was caught. Turning
them on is real work, not a flag: the files need an immutable path, and since
every run regenerates every delta, the upload cannot use
`--if-generation-match=0` the way release zips do. A guard now rejects any
enclosure that is not a published object, so a surprise like this fails before
the feed goes live rather than after.

**Reads of the appcast must bypass the cache.** It is served with
`max-age=300`, so a plain GET returns the *previous* feed for five minutes
after a publish. That is not cosmetic: `published_max_build` reads this feed,
and a stale answer would let the build-number gate approve a number already
taken. Use `fetch_uncached` from `tool/lib/pubspec_version.sh`, and read the
**origin** URL — see One bucket, two URLs. Now that a CDN sits in front of the
bucket there are two caches to get past, and only the origin read has just one.
The app's own feed URL is the CDN's, and `publish_appcast.sh` invalidates that
path at the edge on every publish.

### Zip, not DMG — and why translocation matters

A zip auto-extracts to `~/Downloads`, and an app launched from there is
*translocated* by Gatekeeper onto a read-only mount, where it physically cannot
replace itself. `UpdateState.translocated` detects this and `canCheck` goes
false, so the menu item greys out rather than offering an update that cannot
install. Sparkle would also catch it, but later and less clearly.

## UI & design

- **Component library:** `shad` (`ShadApp`, `ShadTheme`, `LucideIcons`). No Material-heavy custom widgets unless necessary. Replaced `shadcn_ui` — same `Shad*` API, higher fidelity to upstream shadcn/ui. Two defaults differ: `ShadTabs.expandTabs` now defaults to `false` (the Settings tabs pass `expandTabs: true`), and `ghost`/`outline` buttons take their foreground from `foreground` rather than `primary`, so they are no longer brand-blue — that change was kept.
- `shad` deliberately does **not** re-export the extensions on `double`/`Duration`/`List`/`TextStyle` that `shadcn_ui` did, nor `boxy`/`flutter_svg`/`universal_image`. Depend on those directly if you ever need them.
- **Theme** (`app_theme.dart`): Slate base, **Nova** style, **Medium** radius (`--radius` 10, so the component step is 8). Serverpod brand blue is the *accent*: `ShadSlateColorScheme.…().applyAccent(kBrandBlue)` derives `primary`, `primaryForeground`, `ring` and `selection` from the one constant, so there is nothing to keep in sync by hand.
- **Fonts:** `.AppleSystemUIFont` (UI), `Menlo` (terminal via `kMacMonoFont`), **Inter Black for the headline roles** (`kHeadlineFont`). The text theme is otherwise stock — `ShadTextTheme(family:)` swaps only the family, so every weight, size and line height matches upstream shad.
- **`h1Large`…`h4` are Inter Black (900) and nothing else is.** `assets/fonts/Inter-Black.ttf` is bundled — 400 KB, one weight, OFL — rather than reached for through shad's own `packages/shad/Inter`, so the display face cannot change under a package bump. Headlines are also the one place the weight correction below does *not* apply: Inter is the typeface shad's metrics were drawn for, and the static cut carries no `wght` axis to correct on anyway.
- **A `ShadCard` `title:` resolves to `h3`, so it is now a Black headline.** That is right for a title and wrong for a label — the tools install banner passes an explicit `titleStyle: textTheme.large` for exactly this reason. Check any new card title before letting it default.
- **Our font's weight axis moves about twice as fast as shad's**, and the whole type scale is corrected for it. Measured over the same string at 14px: Inter (shad's default) widens ~1.65px per 100 weight units, `.AppleSystemUIFont` ~3.17px — so an uncorrected `w500` lands where Inter's `w600` would. Both axes resolve correctly and neither synthesises bold; it is a typeface difference. `app_theme.dart` rebuilds every `ShadTextTheme` role with a `wght` variation at the corrected value, including the `w400` ones — a variation beats an inherited `fontWeight`, so a component that copies a role and bumps the weight (`ShadCheckbox` does this to its label) lands on the corrected weight instead of a too-heavy one.
- **Never write `copyWith(fontWeight: …)` on UI-font text — it is silently ignored.** Every role already carries a variation and the variation wins, so a raw weight leaves the text at its role's weight. Use the `.medium` / `.semibold` getters from the `UiTextWeight` extension instead. Monospace is the exception: `Menlo` is not variable, so `fontWeight` is the right lever there and the variation is a no-op.
- **`textTheme.small` is the *label* role, not body copy.** It is `w500` at `height: 1.0` (`font-medium leading-none`), so prose set in it reads bold and cramped the moment it wraps. Use it for single-line labels, list rows and badges. For anything that wraps use `textTheme.muted` (`w400`, `height: 1.43`), and for a dialog's lead paragraph use `ShadDialog`'s `description` slot, which resolves to `style.body` over `textTheme.muted`. The agent transcript is the one place that keeps `small` for prose, and only because it sets an explicit `height: 1.4`.
- **Custom widgets read the theme; they do not carry colors.** Use `scheme.*` for color, `theme.radii.{sm,md,lg,full}` for corners and `theme.style.*` for geometry — a literal `Color(0x…)` or `BorderRadius.circular(n)` in a widget is the thing to fix, not to match. Failure states are `scheme.destructive`, never a private red.
- **Success and warning have no shadcn token**, so they ride in the scheme's `custom` map and are read through the `AppColorScheme` extension as `scheme.success` / `scheme.warning`. One value per status, picked to be legible on that brightness's background, covers both the dot and its label.
- **Layout constants** (`app_theme.dart`): `kPaneHeaderHeight` (36), `kDividerWidth` (1), `paneBorderSide()`, `kSplitHandleWidth` (6).
- **Pane chrome:** headers use `scheme.muted`; content uses `scheme.background`. Use `paneBorderSide()` for all 1px dividers.
- **Segmented controls:** `IconSegmentedControl` / `TextSegmentedControl` share `widgets/segmented_control_theme.dart`, which resolves color and geometry from the theme's **tab** tokens — the strip/segment treatment `ShadTabs` uses — so both follow the style preset like a built-in. Hover moves the *foreground*, not the fill, so no blend has to be invented. `onMutedSurface: true` on muted pane headers swaps track and selection.
- **Header breathing room is set by `kPaneHeaderHeight`, not by the controls.** All three (icon group, text group, standalone button) come out 30px from the preset's tab tokens, and the bar is 40 so they clear it by 5 top and bottom. Tightening the strip inset instead buys that gap out of the space between the strip edge and the segment pills, which is what makes the labels look cramped — that was tried and reverted. Retune the bar.
- **Component themes are near-stock.** `app_theme.dart` keeps two: the 700 ms tooltip wait, and a `cardTheme` that drops the radius from nova's `xl` (14) to `lg` (10) — the step buttons and select triggers use, so a card no longer looks rounder than the dropdown beside it — and halves the 16px padding, because our cards stack as list rows rather than standing alone. The tooltip delay is there because the default flashes tooltips while the pointer crosses a toolbar. Two overrides that used to live here are gone on purpose: the dark `border`/`input` pair (slate dark had `border == muted` in `shadcn_ui`, but `shad` sets a translucent white and dividers show fine) and the solid `destructive` button fill — `destructive` is upstream's soft `bg-destructive/10` tint everywhere now, including the Uninstall confirm.
- **Prefer a shad component over a hand-built one.** Panels drawn as a `DecoratedBox` with tinted `scheme.muted`/`scheme.border` are the pattern to replace: `ShadCard` already carries the right fill, hairline border, radius and padding. Likewise `ShadSeparator` over a `Divider`, and `ShadRow`/`ShadColumn`/`ShadGap` — whose `spacing` is in 4px theme steps, not pixels — over `SizedBox` spacers. Both Settings panes are converted; there is no tinted `DecoratedBox` left in the dialog. The install banner is a `ShadCard` on `scheme.muted`.
- **One table, `widgets/settings_table.dart`, for the setup dialog, Settings → Tools and Settings → Providers.** They ask the same question of different subjects — what is this, and where does it stand — and drawing it three times is what let the setup dialog offer a plain download where the Tools tab said "Update needed". `versionBadge` lives beside it so the `1.15.13 → 1.18.4` form is written once. `SettingsTable` renders nothing when handed no rows — `ShadTable.list` asserts on an empty child list, and an empty inventory is reachable, since `ToolchainController.create` falls back to one when the probe throws rather than refusing to launch.
- The Tools tab deliberately has no per-row buttons, install path or version-range line. Those were answering questions nobody asked; installing is the dialog footer's job, and removing everything is the App Studio menu's.
- **Putting the tools on the user's `PATH` is not a choice, and there is no checkbox for it.** It is what lets an external editor or AI agent find the toolchain, so it is part of installing: the installer writes the official line for each tool it installs, unless the user's login shell already has that directory. The Tools tab says nothing about it in the ordinary case; for a shell App Studio cannot edit (fish, nu) it shows the lines to add by hand in a `CommandBlock`.
- **The Tools tab has no Update All.** A copy App Studio installed that falls out of range becomes `ToolAction.update` and appears in the footer's Install button like anything else missing; a copy the user installed gets a banner with the command to run.
- **Settings → Providers lists only providers that hold a key**, each with a green Connected badge and a trash button, and an Add Provider button that opens `add_provider_dialog.dart` (provider dropdown, key field, Connect/Cancel, no close X, narrower than Settings). It used to render a card with a key field for all seventeen curated providers, which buried the two that were actually configured. The dropdown filters out anything already connected: the fix for a bad key is remove-then-add, not a second add.
- **The Add Provider dialog does the save itself** and stays open on failure with the key still in the field, because losing a pasted key to a dialog that closed is the worst possible response to an error. Be careful what it claims: `saveApiKey` writes to the auth store and treats that as the source of truth — it swallows a failed `PUT /auth/{id}` and restarts serve — so **a wrong-but-well-formed key does not fail here**. What the pane's `_connect` can report is an exception from the write, and the provider not appearing in `connectedProviders` afterwards, which is "that did not take effect" rather than "your key is wrong". Do not word it as validation.
- Its width comes from `ShadDialog.constraints`, not a fixed-width child: the dialog sizes itself to its widest content, so a narrower child just leaves the inputs floating short of the edge.
- **Every dialog's `child` goes through `DialogBody`** (`widgets/dialog_body.dart`)
  — `const DialogBody()` alone for a dialog that is only a title and a
  description. shad puts one `gap` between every part of a dialog, and nova sets
  it to 4, which leaves the buttons sitting on the text; `DialogBody` makes the
  space above the buttons `kDialogActionsSpacing` (16, shadcn's `gap-4`) with
  content or without. Do not pad the buttons or the end of the content by hand
  — that is what it replaced, one different amount per dialog.
  `test/widgets/dialog_body_test.dart` measures the spacing and fails on a file
  with more dialogs than `DialogBody`s.
- **`ShadBadge.secondary` is invisible on a `muted` card** — slate defines `secondary` and `muted` as the same colour, in both brightnesses. Use `.outline` on a muted surface, and check any `secondary`-on-`muted` pairing before assuming it reads.
- **`onPressed: null` does not grey out a `ShadButton` — pass `enabled: false` too.** The dimming is an `Opacity(.5)` driven by `ShadState.disabled`, which shad sets from the `enabled` property alone; that defaults to `true` no matter what `onPressed` is. A null handler on its own gets you a button that is inert but looks live, which reads as a broken click rather than an unavailable action. Settings → Tools passes both. The toolbar's `_IconAction` derives it as `enabled: onPressed != null`, so Start and Stop dim like everything else.
- **A `ShadTooltip` never opens on a disabled `ShadButton`** — which is exactly when its text is worth reading. `ShadTooltip` owns no `MouseRegion`: it injects `onHoverChange` into the theme's hover strategies and relies on the *child* to report hover, and a disabled button puts its content behind an `AbsorbPointer`, so nothing ever reports. Wrap the button in a bare `ShadGestureDetector` — that sits outside the absorber and reports hover regardless. `HotRestartButton` does this, because "start the server first" is the whole point of the tooltip there.
- **Success and warning badges go through `appSuccessBadge` / `appWarningBadge`** (`app_theme.dart`), which wash the status colour at 10% (light) / 20% (dark) the way shad tints `destructive`. Warning, not destructive, is right for "not installed yet": nothing is broken and there is a button on the same screen that fixes it.
- **Terminal tabs:** VS Code–style; selected tab overlaps bottom border via `Transform.translate`, not negative margin.
- **Split resize:** panes meet with no gap. Draw a full-height 1px `ColoredBox` in a `Stack` on the split line; overlay a transparent drag handle (`kSplitHandleWidth`). Do not use a separate wide column or `DecoratedBox` border behind opaque pane content — it won't show.

## Preview panel

- **Shell theme ≠ preview theme.** Preview light/dark toggles a JS shim (`preview_theme.dart`) that fakes `prefers-color-scheme` inside CEF.
- **View modes:** `PreviewViewMode` — portrait phone (default), landscape phone, desktop. Defined in `preview_device.dart`.
- **Reload: there is no reload button, and no second path.** Every reload goes through `previewReloadToken` → `PreviewPaneState.reload()`, so it is always the hard one — a plain navigation re-serves the cached `main.dart.js`, so a rebuilt app looks unchanged. Three things bump the token: the DWDS attach, `ServerpodProcessController.requestPreviewReload()`, and a successful Hot Restart. Re-apply the theme shim afterwards: it is injected at load start with the brightness captured when the webview was created.
- **A hard reload has to take three separate caches, and missing any one of them shows the previous build.** `reload()` runs `previewCachePurgeScript` (`preview/preview_cache_purge.dart`) first, because a **service worker and its Cache Storage entries are page state**: they outlive the navigation entirely and then answer the *new* document's requests out of the build that registered them, which no amount of cache-bypassing on our side can reach. Flutter web in debug registers no service worker, but the previewed app is the user's and may. The purge is asynchronous and `executeJavaScript` cannot await it, so `_purgePageCaches` polls `window.__appStudioCachesPurged` — bounded at 1s, then reloads regardless, since not reloading is the worse failure. `reloadIgnoreCache()` then covers the other two: the fork's `WebviewHandler::reloadIgnoreCache` issues DevTools `Network.clearBrowserCache` before `CefBrowser::ReloadIgnoreCache()`, because the latter only bypasses the cache for the requests *this* navigation makes — the stored entries survive it, so the next plain navigation (DWDS triggers one of its own) serves the old bytes again. CEF exposes no cache-clear API; the DevTools protocol is the route, and commands on one session run in order.
- **Every project serves from the same origin, so switching projects clears the
  profile.** The CEF request context (HTTP cache, localStorage, service
  workers, cookies) is global and in-memory — it outlives the per-project
  webview, and `http://localhost:9998` is the same origin for every project, so
  project B's first load could be answered out of project A's state.
  `_ensureWebView` tracks which project the profile last served (module-level
  in `preview_pane.dart` — the pane's State unmounts when a project closes, the
  profile does not) and on a switch calls the fork's
  `WebViewController.clearBrowsingData` — DevTools `Storage.clearDataForOrigin`
  with `storageTypes: "all"` plus `Network.clearBrowserCache`, the same pair
  Chrome's own "Clear site data" uses — then runs the full `reload()`, since
  the initial navigation may already have been served from the old state. The
  tracker is only advanced after the clear succeeds, so a failed clear stays
  due on the retry. Same-project restarts are deliberately untouched: the clear
  keys on the project changing, not on the webview being recreated, so
  localStorage survives a Full Restart within one session. Keeping the profile
  in-memory (the `cache_path` note below) is unchanged — this is about state
  crossing projects inside one app run, not across launches.
- **The runner is not racing us.** `serverpod`'s `hot_restart` MCP tool is `WatchSession.forceRestart`, which awaits the full compile, the server reboot, `_restartAllFlutterApps()` (a VM-service hot restart of the running `flutter run`) and `_notifyBrowserRefresh()` before it answers — so by the time `McpController` bumps the token, the web server is already serving the new output. If the preview still shows old code, it is a cache and not timing.
- The header's reload button is **gone on purpose.** Hot Restart now force-reloads the preview itself, so the button's only remaining job was papering over a reload that had not happened — and the honest fix for that is the token, not a second control that does the same thing by hand.
- **Backdrop:** CEF composites with alpha, so an opaque `ColoredBox` (`previewBackdropColor`) sits under the surface, following the *previewed* app's brightness, not the shell's.
- **CEF sizing:** `PreviewSurfaceSync` + `burstSyncPreviewSurface` keep the webview sized on panel/mode changes. Defer layout reads to post-frame callbacks; avoid `MediaQuery` in `initState`.
- **webview_cef:** path dependency `packages/webview_cef` (fork of 0.5.1). Includes CEF resize surface sync and skips embedding `Helper (Alerts)`. CEF itself is fetched by `pod install` into `macos/third/cef/` (gitignored).
- **`root_cache_path` is set, and it has to be.** Left unset, CEF falls back to
  `~/Library/Application Support/CEF/User Data` — *one* directory for every CEF
  app on the Mac that also left it unset, and the one holding `SingletonLock`,
  `SingletonCookie` and `SingletonSocket`. That is the "unintended process
  singleton behavior" CEF warns about on every launch: another vendor's CEF app
  can hold the lock our browser needs. `CefWrapper.mm` resolves
  `~/Library/Application Support/<CFBundleName>/CEF` — `App Studio/CEF` here, so
  the uninstaller's recursive sweep of the support directory takes it too — and
  passes it through `setMacRootCachePath` before `startCEF()`. It is set
  *outside* the bundled-helper check that guards the other three paths, because
  it applies in single-process mode as well.
- **`cache_path` stays empty on purpose**, so the HTTP cache remains in-memory
  only. Setting it would start persisting the previewed app's `main.dart.js`
  across launches, which is the exact thing `reloadIgnoreCache()` exists to
  defeat. `root_cache_path` alone does not turn that on.
- **`CefShutdown()` is one-way, and the plugin outlives it — every way back into
  CEF is gated on `webview_cef::cefIsShutdown()`.** `teardownSession` quits CEF
  first (its helpers are our children), and only then does Flutter tear the
  widget tree down, so `PreviewPaneState.dispose()`'s `close` call always
  arrives *after* the shutdown. Ungated it reached `CefBrowser::GetHost()` on a
  dead wrapper, which is `shutdown_checker::AssertNotShutdown` — a `SIGTRAP`
  that took the app down on quit in a debug build, and silent undefined
  behaviour in release. The same window is what an update lands in:
  `prepareForRelaunch` quits CEF and Sparkle then installs for several seconds
  with the app still live, where a mouse move over the preview is enough to
  reach in. `HandleMethodCall` answers without touching CEF once shut down; the
  platform entry points that bypass it (the `NSEvent` key monitor, the IME
  forwarders, the vblank tick) carry their own gate; and
  `CefWrapper.stopDrivingCEF` kills the pump timer and the `CVDisplayLink`,
  which otherwise call into a library that is no longer there ~60 times a
  second.
- **`quit` closes the browsers before it shuts CEF down.** A
  `CefRefPtr<CefBrowser>` still held at `CefShutdown()` is a wrapper whose
  release lands in that same dead library. The handler force-closes, drops the
  renderers and pumps the loop a bounded number of times so the close can land
  — nothing else drives CEF here, since macOS runs it on an external message
  pump.
- **`browser_map_` was not the only reference — `current_focused_browser_` is a
  file-scope one, and it crashed every ⌘Q.** Nothing cleared it, so its atexit
  destructor released a `CefBrowser` from `__cxa_finalize_ranges`, which is by
  definition after `CefShutdown()`: `AssertNotShutdown` again, this time with no
  Dart or plugin frame anywhere in the stack to point at the cause.
  `CloseAllBrowsers` now drops it *before* its own empty-map early return (a
  popup takes focus without ever entering the map), and `closeBrowser` drops it
  when the browser going away is the focused one. It is also allocated once and
  never destroyed, so no exit-time release exists to get this wrong again.
- The fork's event getters (`onToolTip`, `onCursorChanged`, `onFocusedNodeChangeMessage`, …) carry **explicit types**; upstream leaves them inferred, which makes them `dynamic` and silences the analyzer at every call site. Annotating them surfaced a real one: `onFocusedNodeChangeMessage` was invoked unguarded while every sibling case used `?.call`, so a focus change arriving before a WebView registered its callback would throw. Keep the annotations through any rebase — they are what makes that class of bug visible.
- **Registration codes:** `serverpod start` logs `Registration code for <email>: <code>` instead of mailing it. `ServerpodProcessController` reassembles console lines across PTY chunks (`_scanLines`) and exposes `registrationCode`; `RegistrationCodeToast` floats it over the preview until dismissed or superseded.
- **Keyboard into CEF (macOS):** a local `NSEvent` monitor (`CefWrapper.processKeyboardEvent`) routes keys. It only forwards to `current_focused_browser_`, which is set from `setClientFocus` — never let it consume an event it can't deliver, or the webview looks dead.
- **Clipboard:** off-screen browsers are not in the responder chain, so Chromium never turns ⌘X/C/V/A/Z into editing commands. They are translated to `CefFrame::Cut/Copy/Paste/…` (`WebviewHandler::sendEditCommand`). Every other ⌘ chord is left uncaptured so the app's menu bar wins.
- **IME:** while a web input is focused, text keys go to the OS input method and come back as `imeCommitText`/`imeSetComposition`; only navigation/control keys are sent raw. Don't reattach the text input client while it is already active — that kills a live composition.

### Minimized preview — the compact window

The header's minimize button (a `SegmentedIconButton` beside the view/theme
controls) strips the shell down to the preview. **Minimized means two different
things by view mode**, and `PreviewModeController.compactWindow` is the one
place that policy lives: in a phone mode the window itself becomes the phone
frame — borderless, transparent, moved by dragging the frame's edges and
resized aspect-locked from its corners, with a floating control bar (view mode,
app theme, expand) below the frame; in desktop mode the toolbar *and* the
server-log panel are hidden and the window is untouched — minimized is
preview-only in every view mode, and the user's own log toggle is preserved for
the way back. The preview header stays in desktop-minimized, so the same
button — now an expand icon — is the way back.

- **View mode, preview brightness and minimized are lifted out of
  `PreviewPaneState`** into `PreviewModeController`
  (`preview/preview_mode_controller.dart`), created in `main.dart`. Minimizing
  reshapes things that live *above* the pane: `StudioShell` drops its toolbar,
  `ShadApp` drops its opaque background, and the native window goes borderless.
  The pane listens and reacts exactly as its old local setters did (surface
  sync on view-mode change, theme shim on brightness change).
- **Transparency has three layers, and all three must clear.** The native
  window (`isOpaque = false`, clear background), the Flutter surface
  (`FlutterViewController.backgroundColor = .clear` — the recipe is documented
  in FlutterViewController.h), and `ShadApp`, which paints an opaque
  `ColoredBox` behind every route — its `backgroundColor:` is set to
  transparent while `compactWindow`, from the same `main.dart` listener. The
  CEF surface stays backed by the preview backdrop inside the frame, so the
  page itself never goes see-through.
- **The compact window keeps the *frame's* aspect, not the window's.** The
  chrome — `kCompactFrameMargin` around the frame (room for its drop shadow,
  which would otherwise clip at the window edge — and the shadow scales with
  the frame, so the margin carries slack beyond the ~33px resting extent) plus
  the gap and control bar — is fixed-size, so the contract is `height =
  chromeHeight + (width − chromeWidth) · aspectH/aspectW`.
  `CompactWindowGeometry` carries it over the `dev.serverpod.appstudio/window`
  channel; `MainFlutterWindow.swift` stores it and applies it on corner resizes
  and orientation flips. **A flip carries the frame's *scale* over, never the
  window height** — carrying the height turned a tall portrait window into a
  landscape one wider than the screen, with its resize corners off it. Every
  geometry application clamps the scale so the whole window fits the visible
  screen.
- **Move and resize are tracked natively, not with Dart deltas** — Dart
  gestures would measure against a window that is moving under them. Both run
  a local `NSEvent` monitor that swallows the drag events until mouse-up.
  **Not `performDrag(with:)`** — that hands the move to the window server,
  which enforces the stop-at-the-menu-bar rule itself and never consults
  `constrainFrameRect`, so the transparent top margin kept the bezel from ever
  reaching the top of the screen; the monitor's `setFrameOrigin` is
  unconstrained and the only clamp is ours (bezel to the visible top of the
  display under the mouse, margin past it). Corner names cross the channel in
  UI (top-left origin) terms; the Swift side flips them for screen
  coordinates. **The new width is start width + mouse travel, never
  mouse-to-anchor distance** — the grab lands tens of points inside the corner
  handle, and anchor-distance sizing snapped the window smaller by exactly
  that inset on the first drag event.
- **The corners' diagonal resize cursor is AppKit's, not Flutter's.** The
  macOS engine maps no diagonal `SystemMouseCursors` (they fall back to the
  arrow), so corner hover asks the native side for
  `NSCursor.frameResize(position:directions:)` (macOS 15+; crosshair before).
  The call is deferred a microtask so it lands *after* the framework's own
  `activateSystemCursor` for that pointer update, which would otherwise paint
  the arrow over it — and nothing resets it: the framework's next cursor
  change is the reset.
- **Entering compact saves the window state (`CompactSavedState`) and exiting
  restores it** — frame, style mask, min size, opacity, shadow, both background
  colors. `canBecomeKey`/`canBecomeMain` are overridden to `true` on
  `MainFlutterWindow`: a borderless window otherwise refuses key status and the
  preview would stop taking keyboard input. The window's own shadow is off in
  compact — the frame paints its own, and AppKit would hug a second one around
  whatever pixels happen to be opaque.
- **The pane keeps its `GlobalKey` across the re-parent**, so the CEF webview
  survives the layout swap instead of reloading. The compact tree builds
  *nothing but* the pane — anything else in the shell would paint onto the
  transparent window.
- **A compact window never outlives its preview**: `main.dart`'s
  `_onSessionChanged` calls `previewMode.expand()` (a no-op when not minimized)
  before the project notices, so closing or switching projects always comes
  back to the full window. Native calls are fire-and-forget with a logged
  catch — a window that failed to go transparent is cosmetic, not fatal.
- **Any route pushed over the compact window expands it first**
  (`CompactDialogYield`, a `NavigatorObserver` on `ShadApp`). Dialogs are
  sized for the full shell — they overflow the phone-sized window, some
  breaking its layout — and their blurred barrier has nothing to blur on a
  transparent window. The menu bar stays fully live in compact mode, so this
  cannot be prevented at the sources; the navigator is the one funnel. The
  expand is deferred a microtask (observers run inside the navigator's
  mutation) and still lands before the route's first frame. Deliberately
  one-way: re-minimizing on close collides with everything else that pops
  routes (project switches clear the stack), and one click re-minimizes.
- **`constrainFrameRect` is overridden while compact** to allow exactly the
  transparent margin past the visible top. AppKit stops a dragged window's top
  at the menu bar, and the compact window's top `kCompactFrameMargin` is
  shadow room — without the override the visible bezel stopped that far short
  of the top of the screen.
- `test/preview/preview_mode_controller_test.dart` pins the mode transitions
  against `FakeCompactWindow` (`test/support/fake_compact_window.dart`),
  including the two subtle ones: compact → desktop restores the window but
  stays minimized, and desktop-minimized → phone re-enters compact.

## Analytics (PostHog)

`lib/analytics/` sends `app_studio.*` events to the **same PostHog project the
Serverpod CLIs report to** — one key (`kPostHogProjectApiKey`, the `phc_…` the
`serverpod_cli` and `serverpod_cloud_cli` binaries carry), the EU host, and
the same body `cli_tools`' `PostHogAnalytics` posts. It is a ~40-line client
on the app's existing `http` dependency rather than a dependency on
`cli_tools`, which would pull in `args`, `config` and `pub_api_client` for one
class.

- **Three events, one method each on `AppAnalytics`**, so a property set is
  written once: `app_opened` (from `main()`, with `tool_sources` and whether
  setup is required), `project_created` (from `ProjectCreator.create`, success
  or not, with the `failure_stage` — `validation`, `cli` or
  `configure_preview`) and `project_opened` (from `_onSessionChanged`, so the
  picker, Open Recent and a fresh creation all count).
- **Every event carries the launch context**: `$lib: app_studio`,
  `$lib_version`/`app_version`/`app_build` (from `UpdateState`, which already
  reads `Info.plist` — no `package_info_plus`), `platform` spelled `MacOS`
  exactly as `cli_tools` spells it so one PostHog filter covers the CLIs and
  the app, `os_version`, `dart_version` and `is_debug`.
- **The distinct id is `~/.serverpod/uuid`, shared with the CLIs.** Read if
  present, created in the same v4 format if not, so one person is one user
  across all three tools. The uninstaller removes `~/.serverpod`, so a fresh
  install gets a fresh id — which is also what the CLIs do. Unwritable →
  `'unknown'`, never "no event".
- **Debug and profile builds send nothing**, so `make start` runs do not
  pollute the project — the CLI gates on `productionMode` for the same reason.
  `APPSTUDIO_ANALYTICS=1` in the environment overrides that; it is how a
  change here is verified end to end.
- **Fire-and-forget, never awaited on a user path.** `capture` returns at
  once, sends are swallowed on failure and time out at 2 s, and nothing flushes
  on quit — a quit must not wait on the network. `flush()` exists for tests.
- **Call sites use the `appAnalytics` global, which is a no-op until `main()`
  installs one** — the same shape as the CLI's `cliAnalytics`. That keeps
  `ProjectCreator` free of an analytics parameter and means a test that
  constructs one sends nothing. `test/support/recording_analytics.dart`
  installs a recording sink for one test and puts the disabled one back.
- No opt-out UI yet. The CLI has `--no-analytics`; a Settings toggle is the
  obvious next step if one is wanted.

## Settings & uninstall

- **One dialog, two tabs** (`ui/settings/settings_dialog.dart`): Providers and
  Tools. They were separate dialogs behind unrelated menus. Each pane owns no
  chrome — no title, no Done button; the dialog supplies both, including the
  Tools install button, which needs `toolchains` state the pane no longer has to
  expose.
- **With `kOpenCodeAgentEnabled` off it is one pane and no tab strip.** Providers
  configures keys for that agent and nothing else, so a single remaining tab
  would be a button that does nothing. `_tab` coerces a caller asking for
  Providers onto Tools rather than trusting it: the App menu's Settings item
  still asks for Providers, and that pane would sit on its "waiting for the
  agent" spinner forever, since no agent is coming.
- **The pane box is a fixed height, not a maximum.** Both panes scroll
  internally, so sizing to content made the window jump every time a tab
  changed, a provider was added or a tool finished installing. Whitespace under
  a short pane is the cheaper trade; `_kPaneHeight` is the one knob.
- **Settings starts the agent on a scratch directory when no project is open** (`AgentController.startForSettings`, called from `StudioShell._showSettings`) — with the agent switched off this returns immediately, since there is no Providers tab for a scratch serve to answer. Keys and the default model are configured here and both are read from the running agent, so the pane would otherwise be unusable until a project existed. `opencode serve` needs a working directory, so it gets `<appSupportRoot>/agent-scratch` — a real path it can drop its own state into. Closing Settings calls `stopIfStartedForSettings`, which **only** stops a serve it started: with a project open the whole thing is a no-op, and a live session is never torn down. Opening a project clears the flag, so a project that appears while Settings is open supersedes the scratch serve rather than being killed with it.
- **The Providers pane waits for the agent rather than rendering an empty list.** Until `ProvidersView.agentReady`, "which providers hold a key" and "which models exist" are *unknown*, not empty — showing the list anyway marks every provider disconnected and invites the user to re-enter keys they already saved. `_WaitingForAgent` stands in, and the pane reloads models on the edge into ready. Its spinner animates forever, so any test touching this pane must use fixed pumps, never `pumpAndSettle`.
- **`ManageToolsPane` defers its deep probe to a post-frame callback.**
  `ToolchainController.refresh()` calls `notifyListeners()` *synchronously*
  before its first await, so starting it in `initState` marks any ancestor
  listening to the controller dirty mid-build. Harmless while it was a
  standalone dialog; a crash the moment the Settings dialog wrapped it.
- **Uninstall lives in the App Studio menu**, not the Tools tab — it is not a
  tool operation. App Studio's own data always goes: the Application Support
  directory, whatever an earlier build left for tools (its private toolchain
  and fenced `PATH` block), and preferences (NSUserDefaults), which is what
  makes a relaunch behave like a fresh install.
- **The tools App Studio installed are checkboxes, ticked.** They are real
  installs now, and other projects or the user's own terminal may rely on
  them, so they are a choice rather than implied. Only the command line tools
  carry a line on what removing them affects (`uninstallConsequence`): Flutter
  and Serverpod say nothing beyond their label, by request — the dialog is
  meant to be short. Only tools in the install record that are still on disk
  are offered (`removableTools`); a tool the user installed themselves is
  never listed.
- **Removing Flutter forces Serverpod** (`kUninstallRequires`): the CLI runs
  on Flutter's Dart. Its box is ticked and disabled while Flutter's is, and
  says why. The command line tools are not forced either way.
- **The Dart package cache goes with Flutter, and only with Flutter**
  (`UninstallChoice.clearPubCache`). There is no checkbox for it. `dart pub
  cache clean` does it while Flutter's Dart is still there; without a Dart,
  `~/.pub-cache` is deleted directly — built from `ToolchainPaths.home`, never
  from `$PUB_CACHE`, so a test's scratch home cannot reach a real cache.
- **Order matters, and it is Serverpod → pub cache → Flutter → CLT.** `dart
  uninstall` and `dart pub cache clean` both need Flutter's Dart. The CLT go
  through `osascript … with administrator privileges` running Apple's
  documented `rm -rf /Library/Developer/CommandLineTools`; a full Xcode is
  never touched, and cancelling the password prompt is reported as a failure.
- **Each `PATH` line goes exactly as recorded.** `withoutLine` removes lines
  equal to the recorded one and touches nothing else. Dart's line stays while
  anything else is still installed with `dart install` — that directory is
  shared.
- It never aborts on a failed step: stopping halfway leaves neither a working
  install nor a clean machine. Failures are collected and named on the final
  screen, which never claims a clean uninstall that did not happen.
- **`~/.serverpod` goes with the Serverpod CLI, and only then.** The CLI keeps
  its own state there — template caches, the analytics id, the cloud CLI's
  login — and so does the install record. When the CLI goes, the directory
  goes, and `persistRecord()` writes back whatever App Studio installed that
  the user chose to keep, so it can still be offered next time.
- Deliberately **not** removed: anything App Studio did not install, and
  `~/.local/share/opencode/auth.json` (API keys the OpenCode CLI uses
  independently of App Studio).
- **Both uninstall screens ride on `LandingScaffold`**, like the start page and
  first-run setup: with no project, no toolchain and no session left, the
  branded gradient is the one surface here that does not depend on something
  that was just deleted. That means the fixed dark landing theme, so **every
  colour on them is set explicitly** — a text role with no colour of its own
  falls through to the `DefaultTextStyle` `ShadApp` installed from the *app*
  theme, and lands as black text on the gradient in light mode.
  `test/uninstall/uninstalled_screen_test.dart` pins that in both brightnesses.
- The final screen is a dead end by design. The session is stopped, the
  toolchain is gone and preferences are cleared, so any control would either
  fail or silently recreate what was just removed.

## Widgetbook

```bash
make widgetbook    # every screen and dialog, in every state, light and dark
```

- **It is for reviewing copy and layout without reaching each state by hand** —
  a clean Mac, a failed install, Apple's installer, an old Flutter, a partly
  created project. The catalog (`widgetbook/catalog.dart`) is ordered the way a
  user meets things: First run → Start → Open project → Settings → Uninstall,
  then the shared Components.
- **It is a second entry point into this package, not an app of its own**
  (`flutter run -d macos -t widgetbook/main.dart`). It runs in App Studio's own
  macOS runner, so the fonts, the `assets/` images and every plugin are the
  real ones — and `webview_cef` needs no second CEF setup. `widgetbook` is a
  dev dependency and nothing under `lib/` imports it, so release builds do not
  carry it. It replaced Flutter's widget previews, which only ran on the web:
  anything that reached `dart:io` could not be shown, which is why they
  covered first-run setup and nothing else.
- **Every use case is hosted in the app's own `ShadApp`** (`widgetbook/host.dart`,
  `UseCaseHost`), keyed by the Widgetbook URL — use case *and* theme — so each
  view starts fresh. The theme switch is Widgetbook's Theme addon; there are no
  knobs, because every state worth reviewing is its own use case.
- **One use case is one screen or one dialog, in one state — never a flow.**
  `DialogUseCase` draws the dialog *in place* over a realistic backdrop
  (`landingBackdrop` for first-run dialogs, `StudioWindowMock` for anything
  shown with a project open) behind the theme's barrier colour. Nothing is
  pushed, so nothing sits over Widgetbook's controls. An earlier version drove
  the real `show…` functions and a simulated install; it opened dialog after
  dialog on top of Widgetbook and was replaced for exactly that. States that
  sit behind a button are reached with a constructor parameter instead —
  `NewProjectDialog.createOnOpen` is the one that exists.
- **The use case lives on a page above a "Closed." page.** A dialog's Cancel or
  Done pops it, as in the app, and leaves **Show again** rather than an empty
  navigator. Quit is the exception: it is `exit(0)`, and closes Widgetbook.
- **Every dialog goes through `showAppDialog`** (`widgets/app_dialog.dart`),
  never `showShadDialog` directly. shad defaults to the *root* navigator, which
  in the app is the only one but in Widgetbook is Widgetbook's: a dialog
  opened from inside a use case — the toolbar's Publish to Cloud, say — would
  cover Widgetbook's own UI and outlive the use case that opened it, which
  surfaces as a cascade of `Duplicate GlobalKey` assertions.
- **Screens and dialogs are drawn at a real window size and scaled down**
  (`AppWindow`, `kAppWindowSize` 1280×800), with `MediaQuery` saying so.
  Widgetbook's canvas is narrower than App Studio's 1024×720 minimum, so laid
  out at canvas size the toolbar overflowed, and shad — which switches dialogs
  to a phone layout below a 640-wide *screen* — centred dialog text and
  stacked the buttons. Neither ever happens in the app. The catalog
  test also builds the studio window at exactly the minimum
  (`kMinAppWindowSize`), which is the overflow a real user could hit.
- **`StudioWindowMock` is an open project assembled from the real parts** —
  `StudioToolbar`, `TerminalPaneHeader`, `PreviewHeaderBar`,
  `PreviewStatusOverlay`, `RegistrationCodeToast`. Two parts are stand-ins
  because they are native: the server log is an xterm with sample output, and
  the preview is a placeholder where CEF would draw the app. As a use case of
  its own it is live — hover shows tooltips, the toolbar's dialogs open inside
  the canvas; as a dialog's backdrop it ignores the pointer.
- **The widgets take narrow interfaces so they can be faked**, the pattern
  `ToolsView` started: `RecentProjectsView` (start page), `NewProjectView`
  (Create Project — the folder picker, `serverpod create`, opening the result),
  `FullRestartView`, `HotRestartView`, `ExternalEditorsView`,
  `ProjectReadyView`, `ProvidersView`. The real controllers implement them
  directly. Anything that was private only for tidiness and is worth reviewing
  on its own — the toolbar, the pane headers, the uninstalling screen — is
  public in its own file.
- **The fakes live in `widgetbook/fakes/`** and the widget tests import them
  from there too, so the states Widgetbook shows and the states the tests pin
  are the same objects.
- **`test/widgetbook/catalog_test.dart` builds every use case in both themes**
  inside the same host, under an outer navigator standing in for Widgetbook's.
  A use case that throws on build, overflows at desktop size, closes itself,
  or pushes anything onto that outer navigator fails there rather than the
  next time someone opens Widgetbook. Add new screens to the catalog; the test
  picks them up.
- **Not covered:** the agent pane (switched off, and it takes a concrete
  `AgentController`), the live terminal and CEF itself. Their surroundings are.

## Architecture notes

- Long-lived controllers created in `main.dart`: `ThemeController`, `ProjectSession`, `StudioTerminal`, `ServerpodProcessController`, `AgentController`, `McpController`.
- **`teardownSession` takes every controller that owns a child process, and the parameters are required on purpose.** It is the one function both the quit path and Sparkle's `prepareForRelaunch` call, so anything optional there is a stray process waiting to happen — a bridge still shutting down when Sparkle swaps the bundle.
- `ServerpodProcessController` owns process lifecycle and signals when preview is ready to load.
- The menu bar lives above `ShadApp`, so menu-triggered dialogs use the `navigatorKey` context from `main.dart`.
- **Swapping `home` does not clear what is pushed over it — call `_clearPushedRoutes()`.** `home` is the *first* route, so a screen swap happens underneath any open route and is simply invisible: uninstalling with the Create Project screen up left the user filling in a form for an app that had just deleted itself. The menu bar stays live behind every dialog and every full-screen route, so this is reachable from all three transitions that replace the screen, and all three call it — uninstall, the toolchain flip that swaps setup for the shell, and a project opening (⌘O and Open Recent work while Create Project is up, and the project would otherwise load behind it). `Navigator.pop` ignores `PopScope`, which is what lets this clear a screen the *user* may not dismiss; `test/new_project_dialog_test.dart` pins that.
- **The toolchain caller defers to a post-frame callback and the other two do not.** `ToolchainSetupDialog` closes itself on the same `ToolchainController` notification and is a later listener, so popping synchronously there would land first and leave its own `Navigator.pop` to hit `home`, emptying the navigator.
- **A key Flutter reports as handled never reaches the menu bar**, so a focused widget that swallows keys takes every menu shortcut with it. The server log (`ServerLogView` in `ui/terminal_pane.dart`) autofocuses and did exactly that: xterm's `hardwareKeyboardOnly` listener types any key it did not otherwise handle into the terminal and calls it handled, so ⌘W arrived at the server as a `w`. The log is output only now — `readOnly` on the view, `inputHandler: null` on `StudioTerminal`'s `Terminal` — and answers ⌘C and ⌘A alone. ⌘V is refused explicitly: unlisted, it bubbles to `ShadApp`'s default text-editing shortcuts and xterm's paste action writes the clipboard to the PTY. `test/server_log_view_test.dart` pins all of it.
- **`MacAppMenu.install()` calls `MacMenuBar.reset()` first, and must keep doing so.** A hot restart replaces the Dart isolate but not the engine, its plugins or the native `NSMenu`, so without it every menu is added again on each restart — and `_recentItemIds` comes back empty, so Open Recent duplicates too. `reset()` removes exactly the items this plugin added: those are the ones carrying a String `representedObject`, which is also how the plugin finds items by id, so stock MainMenu.xib entries cannot be stripped.
- **Never return `menuItem.isEnabled` from `validateMenuItem`** for an item the plugin overrode. Under automatic enabling AppKit *writes* `isEnabled` from the previous validation pass, so reading it back is a latch, not a query. MainMenu.xib ships `Preferences…` with no action at all, so AppKit disabled it before the override was installed and it could never re-enable — the Settings item was permanently greyed out. Overridden standard items are tracked in `overriddenItems` and validate to `true`; the Dart handler decides what happens when they fire.

## First run

`main.dart` picks the whole screen from `toolchains.inventory.needsSetup`:
true means `ToolchainSetupScreen`, false means `StudioShell`. **The start
page and the setup flow are two screens, never stacked.** The dialog used to
float over the start page, which offered New Project and Open Project buttons
that could not work — there is no Flutter SDK to build with yet.

- The gate is `ToolsView.needsSetup`: something App Studio can install or
  update, a Flutter the user has to update themselves, an earlier build's
  toolchain still to remove (all `ToolchainInventory.needsSetup`), or the
  one-time Puro/FVM notice still unanswered. It is named rather than written out,
  because three things have to agree on it and would otherwise drift: the screen `main.dart` picks, `MacAppMenu.canOpenProjects` — ⌘O, Open
  Recent and Settings would walk straight past the gate — and
  `StudioShell._showSettings`.
- **Settings is disabled *and* inert while setup is up, which is two mechanisms
  on purpose.** The menu item greys out, and `_showSettings` returns without
  opening anything. The shell is not even built in that state, so the second is
  belt to the first's braces — but every route into the dialog goes through that
  one function (the menu item via `AgentController`'s handler, and the toolbar's
  warning badge), and the only pane Settings could show then is a Tools tab
  duplicating the setup screen already on top of it.
- **`MacMenuBar.setSettingsEnabled` is pushed before the menus are installed,
  not after.** The plugin installs its Settings override from a block queued at
  registration — which force-enables the item — and its own flag defaults to
  enabled, so until Dart says otherwise the stock item is live and ⌘, reaches
  the action without the menu ever being drawn. The native side re-applies
  whatever it was last told when the override lands, so pushing early is safe
  either way round.
- **Disabling the stock Settings item sets `isEnabled`, not `validateMenuItem`.**
  `addMenuItem` turns `autoenablesItems` off on whatever menu it adds to, and
  this app adds Check for Updates and Uninstall to the App menu — so AppKit
  stops validating that whole menu and `validateMenuItem` is never consulted for
  anything in it. `MacMenuBar.setSettingsEnabled` therefore writes `isEnabled`
  directly, the same mechanism the plugin's own items use. It cannot reuse
  `setMenuItemEnabled`: that is keyed by the String `representedObject` stamped
  on items the plugin *added*, and `reset()` deletes exactly those, so giving a
  MainMenu.xib item one would make reset strip it.
- The plugin re-applies the flag when it installs the override, because that
  runs from a block queued at registration and can land either side of the first
  channel call — and the override force-enables the item.
- **Both screens share one backdrop.** `ui/landing_scaffold.dart` owns the black
  logo banner and the gradient; `StartPage` and `ToolchainSetupScreen` supply
  only what sits on top. They are two states of the same moment — the app open
  with no project — so a different backdrop on each read as a different app. It
  is its own file rather than something exported from `start_page.dart` because
  that one imports `ProjectSession` and so drags in `dart:io`.
- **Everything over that backdrop runs on `buildLandingTheme()`, in both system
  brightnesses.** `LandingScaffold` wraps its child in it, so the landing screens
  never read the system's light/dark setting: the image behind them does not
  change either way, and light chrome on it would be dark text on a photograph.
  Dialogs raised from these screens are `Navigator` routes and so are *not*
  covered — they sit above the scaffold and keep the app's theme.
- **The backdrop is drawn, not loaded.** `_LandingBackground` is one vertical
  `LinearGradient` — black at the banner, through navy and indigo, to orchid at
  the floor. It replaced a 19 KB WebP that had to be decoded and rescaled on
  every resize and letterboxed by hand to keep its aspect ratio. Retune the
  whole backdrop by editing that one stop list. The stops bunch through the
  middle deliberately: spread evenly, the indigo-to-purple leg bands visibly
  down a tall window.
- **Both landing surfaces are white glass, and that is downstream of the
  gradient.** The action cards (`kLandingCardSurface`) sit in the middle of it;
  the recents panel (`kLandingPanelSurface` / `kLandingPanelBorder`) is thinner
  so the deepest part still reads through. This only works because the drawn
  backdrop stays dark at the bottom — the photograph it replaced washed out to
  pale pink there, where a white scrim lightens an already-light surface, and
  the panel had to be black glass with a *darker* edge to survive it. Restore a
  light-bottomed backdrop and that inversion comes back with it. Everything with
  an obvious slot rides in the scheme (`primary`, `card`, `accent`, `border`,
  `mutedForeground`); the panel is the exception, having no token of its own.
- **Both landing actions are the same pink** (`kLandingActionColor`, pink-600).
  Creating and opening are the two ways in, not a choice with a recommended
  answer, so neither gets primary/secondary weighting — and the app's brand blue
  is a poor neighbour to the blues this gradient starts in.
- **Nothing over the backdrop may leave a text colour unset.** A shad text role
  with no colour falls through to the `DefaultTextStyle` `ShadApp` installed
  from the *app* theme, which is the one thing on these screens that still
  follows the system's light/dark setting. A recent project's path was set in
  bare `textTheme.muted` and so went black in light mode while every explicitly
  coloured string beside it stayed white. `kLandingSubduedForeground` is the
  translucent white for type that should recede.
- **A card nested around a control needs `concentricRadius`**, not the same
  radius as the control. The two action buttons sit in 10px of card; sharing one
  radius makes the visible ring of card measurably fatter at the corners than
  along the edges.
- The setup spinner is explicitly `Colors.white`. The backdrop is a fixed brand
  image in both themes and the spinner sits over its saturated middle, where the
  default (`primary`, brand blue) all but disappears — the same reason the banner
  hardcodes black.
- **Setup is a sequence of dialogs over a spinner** (`_drive()` in
  `toolchain_setup_screen.dart`), each blocking on the user so the loop cannot
  spin: the Puro/FVM notice, then the legacy notice and cleanup, then the
  "update your Flutter" prompt, then the plan.
- **The Puro/FVM notice (`FlutterInstallNotice`) is asked once, on a first
  launch without a standard Flutter.** App Studio does not work with a Flutter
  managed by Puro or FVM yet, and the notice points those users at Serverpod's
  Quick Start instead; Quit or Continue. "Standard" is
  `ToolchainInventory.standardFlutterFound`: a Flutter found outside `fvm`,
  `.fvm` and `.puro` path segments — both managers resolve their symlinks into
  their own folders. `ToolchainController.create` records the question as
  answered (`setup.flutter_notice_seen`) when a standard Flutter is there, so
  removing one later does not bring it back; Continue records it too. Quit
  does not, so the next launch asks again. Uninstall clears preferences, so a
  reinstall is a first launch. The Flutter prompt comes before the plan because the
  Serverpod CLI is installed with that Flutter's `dart`.
- **The plan is not raised until `ToolsView.preflight()` has answered.** Every
  version in it comes from Flutter's release feed and pub.dev; raising the
  dialog first and filling the table in afterwards is what made a slow network
  read as a stuck dialog.
- **The plan says where everything goes.** It edits the user's machine outside
  the app, so the description names `~/develop/flutter`, `dart install`,
  Apple's installer and the shell profile, and each row says how its tool
  arrives (a size, "From Apple", "dart install", "flutter upgrade").
- Failure raises `ToolchainSetupErrorDialog` — the message plus **Try again**,
  which loops back, and **Quit**. There is no third option: the app cannot
  build a Serverpod project without these tools.
- Both dialogs are `canPop: false`. The plan dialog closes *itself* when the
  inventory comes back complete, which is why that uses `Navigator.pop` and not
  `maybePop` — `maybePop` honours the same `PopScope` that refuses the user.
- `_drive()` re-checks `installable` after the preflight. The user can install
  a tool in a terminal meanwhile, and the plan dialog only self-closes once an
  install has run, so an empty one would strand a modal over the shell.
- **An install runs to the end without ever going back to the plan.** There is
  real work after the last step — a deep re-probe — and showing the plan again
  through it read as the install having been thrown away, right before the
  dialog closed. `ToolchainController._finalizing` folds into `isInstalling`
  and covers it; the dialog's own `_running` covers the rest of
  `installMissing()`. `_closeIfComplete` defers to `_running`, so the
  self-close fires once, from `_install`'s `finally`.
- **Progress is per step, not one bar.** Only the Flutter download can measure
  itself; Apple's installer, `flutter upgrade` and `dart install` report
  nothing. So the bar is determinate while downloading and indeterminate
  otherwise, and the caption says "Step 2 of 3" plus either the byte count or
  what the step is doing (`ToolPhase.hint`) — for Apple's installer, that the
  user has to click through its window.
- **The dialog is closed from outside, and its self-close checks for that.**
  Because it now outlives the moment `installable` goes empty, `main.dart`'s
  post-frame `_clearPushedRoutes()` is what actually takes it off on a first
  run. A `Navigator.pop` afterwards pops **`home`** instead and leaves an empty
  navigator — a white window, with the start page's page transition playing out
  as it goes, which is precisely the failure the comment in
  `_onToolchainsChanged` has always warned about. `_closeIfComplete` therefore
  pops only while its own route `isCurrent`. The window is one frame wide (the
  route is out of the history, the `State` is not yet unmounted) and the end of
  the install can land right in it; `test/toolchain/toolchain_setup_dialog_test.dart`
  reproduces it with `removeRoute` and fails without the check.
- Past the last step there is nothing left to cancel, so **Cancel dims rather
  than disappearing** — in the setup dialog and in the Tools tab's banner.
  Cancel stops between steps; it cannot stop Apple's installer, which is its
  own app. The line over the bar comes from `InstallProgress.statusLabel`,
  which names the step in progress and calls the tail "Finishing up…".

## New projects

- **New Project** (start page + File menu) opens `ui/new_project_dialog.dart`: project name + location + external AI editors, then `ProjectCreator` (`process/project_creator.dart`) runs the bundled `serverpod create <name> --ide … --no-interactive` in that location.
- **It is a screen, not a dialog over one.** `showNewProjectScreen` pushes a route whose `NewProjectScreen` draws the form on `LandingScaffold` — the same backdrop and fixed dark theme the start page uses, so arriving here does not read as a different app. There is no barrier, so nothing to blur and nothing to click through: a stray click beside a form holding a typed name used to throw it away. Cancel pops back to wherever it was opened from, which is the start page in the common case and the shell when it came from the File menu.
- The form itself is still a `ShadDialog.alert` (`NewProjectDialog`), which is the variant with no close X — Cancel is the way out, and mid-run there is none. It is centred *outside* its `SingleChildScrollView`: a scroll view sized to its viewport pins a short child to the top.
- **The form is put back on the app's theme**, with a `ShadTheme` read above `LandingScaffold` and reinstalled inside it. The landing theme is fixed dark because the gradient is, which is right for chrome sitting on that backdrop and wrong for a surface with its own background — a light app would otherwise show one dark panel here. Routes raised from the start page already behave this way by landing outside the scaffold; this one is inside it and has to say so.
- **Every `--ide` value is an `IdeIntegration`, and exactly one is picked** — a `ShadRadioGroup` of `_IdeRadios`, three to a row. `--ide` is still a multi-option and the pick still goes out as its own flag; passing any value at all replaces the CLI's own defaults (claude, cursor, vscode), so what is picked is what is configured and nothing else.
- **Picking one is mandatory, and Create is what says so.** `_canCreate` waits on the editor as well as the name. This replaced a set of checkboxes that could all be left clear plus a "No external editor selected" prompt (Continue / Pick Editor) raised *after* the user had committed — a control that cannot express the empty answer says the same thing up front and needs no prompt. `_hasExternalEditor` and `_confirmNoExternalEditor` are gone with it.
- **`builtIn` still exists and nothing sets it any more.** It meant "configured whether or not it was asked for", and OpenCode was the only one, because App Studio ran it as its own agent. With `kOpenCodeAgentEnabled` off there is no Agent tab, so `IdeIntegration.opencode` takes `builtIn: kOpenCodeAgentEnabled` and a new project gets exactly what was picked. `configuredIdes()` is consequently an identity function today; it is kept because the flag can come back. Do not mark OpenCode's option specially — a checked-and-disabled box was tried and deliberately reverted.
- Names must match `^[a-z][a-z0-9_]*$` (they become Dart package names); the input folds case and drops separators as you type.
- After the CLI succeeds, `patchFlutterAppForPreview` adds `device: web-server` and `web-port: 9998` to the `flutter_apps` entry in `<name>_server/pubspec.yaml` — without it `serverpod start` opens a browser instead of feeding the preview pane. The project is then opened, which auto-starts it.
- Last used location is remembered in `ProjectSession` (`new_project_directory` pref).
- **`IdeIntegration` lives in `process/ide_integration.dart`, not in the creator**, purely so `ProjectSettings` can use it without dragging `dart:io` in. `project_creator.dart` re-exports it, so every existing import still reads naturally.
- **`configuredIdes()` is the one place "which editors got configured" is computed**, shared by the `--ide` flags and the settings write below. Two lists of the same thing is how the record drifts from the reality.

### `.appstudio/settings.json`

`ProjectCreator` writes `<project>/.appstudio/settings.json` after the CLI
succeeds (`session/project_settings.dart`). It records which editors the user
**picked**, which is what the toolbar's Open in … buttons are drawn from.

- **Picked, not configured — the distinction is the whole point of the file.**
  `configuredIdes` adds the `builtIn` entries whether or not they were asked
  for, so writing that set down would put an Open in OpenCode button on every
  project anyone ever created. `recordProjectSettings` takes the raw selection
  and `test/project_creator_test.dart` pins it.

- **It is project state, not preferences.** Preferences are global and live in
  `SharedPreferences`; this belongs to the project, so a copy of it carries the
  answer and a second machine reads the same one.
- **A failed write never fails the creation.** The project is complete and
  usable without it, and losing a finished project to an unwritable dotfile
  would be a far worse trade than losing two buttons.
- **A missing or corrupt file falls back to the config files the CLI itself
  wrote** — `.cursor/mcp.json`, `.vscode/mcp.json`, `.mcp.json`,
  `.codex/config.toml`, `.agents/plugins/serverpod-local/mcp_config.json` —
  mirroring the CLI's own `TemplateIde.filePath`. Without it the feature would
  do nothing for any project that predates it. Each path is specific enough that
  its presence really does mean `--ide` ran: half the projects on a Mac have a
  `.vscode/`, but `.vscode/mcp.json` is ours.
- **Inference skips `opencode.json`**, which is listed in that map and never
  read. It is in *every* project App Studio has created up to now, picked or
  not, so it carries no signal about the choice — inferring from it would
  reinstate the button the picked/configured split exists to keep off.
- **`_neverInferred` is a list of its own, not a read of `builtIn`.** It used to
  be the latter, which was the same set right up until `IdeIntegration.opencode`
  stopped being built in — at which point every project already on disk would
  have grown an "Open in OpenCode" button. The projects do not change when the
  flag does, so neither does this.
- **A file that parses wins even when it lists nothing.** Ticking no editor is a
  real choice, and the config the CLI left behind must not be read as one.
- An id the running build does not know is dropped without taking the rest of
  the list with it — that is a newer App Studio's editor, not a corrupt file.

## Opening a project

- Opening one auto-starts the server (`ServerpodProcessController._onSessionChanged`), which compiles the whole stack before anything reaches the preview. `ui/project_startup_dialog.dart` says so up front, because the first minute or two is otherwise indistinguishable from a hang.
- It is triggered in `main.dart` from a `ProjectSession` listener that tracks the **project path**, not `hasProject` — switching straight from one project to another recompiles just as much, and the boolean never changes across that. The dialog is pushed from a post-frame callback: the session can notify mid-build, and pushing a route from inside a build is illegal.
- "Don't show this again" is written to `project.startup_notice_dismissed` **only when the box is ticked**, and by the caller — the widget just pops the bool, which keeps it `dart:io`-free and easy to show in Widgetbook. This is a one-way door, so `test/project_startup_dialog_test.dart` covers both directions: OK alone must leave the pref unset.
- The dialog is `barrierDismissible: false`. With the confirm button as the only action, a stray click on the barrier would otherwise silently discard a ticked checkbox.
- It styles nothing itself. Two shad details make that possible, and both generalise:
  - **`ShadDialog.alert` has no close X**; `ShadDialog` (primary) does. The only difference is that `primaryDialogTheme` sets `closeIconData` and `alertDialogTheme` does not, and there is no flag to turn it off — so pick the variant, don't fight it. Alert is also the right semantics for a notice you acknowledge rather than dismiss.
  - **Body copy belongs in `description`, not a `child` with `textTheme.small`.** `small` is shadcn's *label* role — `w500` at `height: 1.0` (`font-medium leading-none`) — so paragraphs set in it read bold and cramped. `description` resolves to `style.body` over `textTheme.muted`: `w400` at `height: 1.43`.
- The checkbox sits in `actions` beside the confirm button. The actions row defaults to `MainAxisSize.min` / `MainAxisAlignment.end`, so `spaceBetween` does nothing on its own — it needs `actionsMainAxisSize: MainAxisSize.max` too.

### Two notices, in sequence, never stacked

Opening a project raises **"Starting your project"** while it compiles, then
**"Your project has started"** (`ui/project_started_dialog.dart`) once
`PreviewPhase.ready` lands. `main.dart`'s `_showProjectNotices` runs them one
after the other.

- **The startup notice closes itself when the project comes up**, carrying its
  ticked checkbox with it. That is also what makes the sequencing work: awaiting
  its future is how the second notice waits out a user who left the first one
  sitting there. Showing the second on a timer instead would land it *on top of*
  the first. The self-close is guarded on `ModalRoute.isCurrent` — popping a
  route that has already gone takes `home` with it and empties the navigator.
- Its second paragraph ("When the app has started, open this project in your AI
  editor…") is gone: that is the whole job of the notice that now follows it,
  and saying it during a two-minute compile is advice the user cannot act on.
- **The started notice names one editor and offers one button** —
  `featuredEditor`, the first of `ExternalEditorsView.editors`. A row of equally
  weighted buttons is a decision; this is a next step. The toolbar carries the
  full set. With nothing openable the copy falls back to "your editor" and there
  is no button: naming an editor we cannot launch is an offer we can't keep.
- **The Cursor tip carries a screenshot** (`assets/cursor-setup.png`), because
  the MCP toggles it points at live behind a search field that is hard to
  describe in a sentence. `Image.asset` needs `width: double.infinity` — the
  asset is 842px wide and would otherwise ask for 842 *logical* pixels and blow
  the dialog open.
- **The actions row wraps its checkbox in `Flexible`.** This one carries two
  buttons and the wider is named after whatever editor turns up, so unlike the
  startup notice it can overflow. Note that `flutter_test`'s font makes every
  glyph a full em, so text there is roughly twice its real width — a row that is
  fine in the app can still overflow in a test, and the fix is to make the row
  survive it rather than to widen the dialog until the test passes.
- Both preferences are one-way doors and both are written by the caller, not the
  widget: `project.startup_notice_dismissed` and
  `project.started_notice_dismissed`. Opening the editor is the caller's job for
  the same reason — it keeps the dialogs clear of `dart:io`.

## Testing with the Dart MCP server

The Dart MCP server (`dart mcp-server`) is configured for this repo in
`.mcp.json` (Claude Code) and `.cursor/mcp.json` (Cursor). It connects to a
running debug build and can inspect it, read its errors, hot reload it and —
with Flutter Driver's extension on — tap, type and take screenshots.
**Use it to check UI and behaviour changes in the running app, not only in
widget tests.** Tests stay the gate; this is how you look at the result.

**Launch a driver build, in the background, then attach:**

1. `make widgetbook_driver` for a screen or dialog; `make start_driver` only
   for a flow Widgetbook cannot show. Both are `flutter run` with the driver
   extension (`test_driver/`). Run it in the background and wait for
   `Flutter run key commands` in its output — the first build takes minutes.
2. **Bring the window to the front**, and again whenever you come back to it:
   `osascript -e 'tell application "System Events" to set frontmost of (first
   process whose unix id is <pid>) to true'`, with the pid from
   `pgrep -f 'Debug/App Studio.app/Contents/MacOS/App Studio'`. A window
   behind others stops drawing frames: screenshots come back stale — the
   *launch* screen, long after you navigated away — and frame-synced commands
   time out. `flutter run` itself reports `Failed to foreground app`.
3. `dtd` → `listDtdUris`, pick the instance whose workspace root is this repo
   (not the IDE's, rooted at `/`), `connect`. Then `flutter_driver_command` →
   `get_health` should answer `ok`.
4. `get_runtime_errors` first, and again after every step.
5. `widget_inspector` → `get_widget_tree` with `summaryOnly: true` before any
   driver command. **Never guess a finder**: use the text, tooltip or widget
   type the tree actually shows. The tree is 200 KB of JSON; search it
   (`textPreview` holds a widget's text) rather than reading it whole. Hint
   text is not in it — a text field is found `ByType`.
6. **`waitFor` with a short `timeout` (3000) before every `tap`**, and only tap
   what it found. A tap whose finder never matches does not end when the MCP
   call times out: it keeps waiting inside the app, and every later tap fails
   with `Guarded function conflict`. `hot_restart` is the only way out of
   that; `get_health` works again a moment after it.
7. `flutter_driver_command` → `tap` (`ByText`, `ByTooltipMessage`, `ByType`),
   then `screenshot` **twice and trust the second** — on macOS the first
   returns the frame before your action. `enter_text` needs
   `set_text_entry_emulation` with `enabled: true` first — it is off at launch
   so a human can still type in the window — and `ByText` then also matches
   the text you typed into the field.
8. After editing code: `hot_reload`, or `hot_restart` for changes to `main()`,
   globals or consts. Then `get_runtime_errors` again.
9. Stop the `flutter run` when done (`q`, or kill it). Do not leave it running.

**In Widgetbook, reach a use case through the Search field**, not by
scrolling the tree: the tree is a lazy list, so an item below the fold does
not exist until it is scrolled to, and a finder for it just waits. Tap
`ByType` `SearchField`, `enter_text` a word from the use case's name — a
prefix like `Runnin`, so the field's own text does not also match the name —
tap the component to expand it, then `waitFor` and tap the use case. The theme
switch is the Theme addon in the right-hand panel.

**Rules — each is about something that happens outside the window:**

- **Never launch while the user has their own `flutter run` of this app
  going.** Every run builds into the same `build/macos` bundle, so a second
  one replaces the app they are using. The `make` run targets refuse on their
  own (`refuse_second_run`: any `flutter run` whose working directory is this
  repo) — so launch through them, never with a bare `flutter run`, and treat
  their refusal as final. Attach to theirs instead: the inspector, runtime errors and
  hot reload all work over DTD, but driver commands do not — a plain
  `make start` has no driver extension. Ask before stopping their run.
- **Prefer Widgetbook to the real app.** The real app acts on the machine:
  `main()` reclaims processes left in the dev-session pid files (it will kill a
  `serverpod start` another App Studio session owns), opening a project runs
  `serverpod start`, the setup screen installs the Command Line Tools and
  Flutter and edits `~/.zprofile`, and Uninstall deletes tools. Do not press
  Install, Uninstall or Create Project in the real app without asking.
- **Quit is `exit(0)` everywhere**, Widgetbook included — pressing it ends the
  session you are driving.

## Conventions for agents

- After a UI change, look at it running — Widgetbook through the Dart MCP
  server (see Testing with the Dart MCP server) — as well as running the tests.
- Keep diffs small; match existing naming and file placement.
- Reuse `shad` components and cloudui patterns before inventing new ones.
- Only commit or open PRs when explicitly asked.
