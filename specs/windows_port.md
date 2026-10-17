# Windows port — plan

Status: **draft — four decisions taken (below), the rest open (section 8).**
Date: 2026-10-16. Baseline: `main` @ `6c07782`, App Studio 0.2.3+22.

### Decisions

| # | Decision |
|---|---|
| D1 | **v1 is "core first":** toolchain setup, open/create projects, runner attach, CEF preview, menus + shortcuts, external editors, uninstall. The compact window (Phase 7) and auto-update (WinSparkle, Phase 8) follow later. |
| D2 | **No Serverpod CLI changes. App Studio requires Windows Developer Mode** instead, so the CLI's existing symlink-based runner registry works and long project paths stay reachable. Setup turns it on through a UAC prompt where possible, and otherwise gives clear guidance (see 4.8). |
| D3 | **App Studio installs Git for Windows** itself (official installer, silent), the Windows counterpart of triggering Apple's command line tools installer. |
| D4 | **Packaging is Inno Setup (per-user) plus WinSparkle** for updates. The updater ships after v1 (D1), but the installer layout is chosen with it in mind. |
| D5 | **Windows release management is a separate setup**, with its own scripts, storage, build counter and signing keys. It never touches the macOS `Makefile`, `tool/*.sh`, appcast, `downloads/macos.json` or `CFBundleVersion` counter (Phase 8). |

App Studio is a macOS-only Flutter desktop app today. This document is the
plan for bringing it to Windows **without changing anything a macOS user
sees or relies on**. It is organised as:

1. Ground rules (how we keep macOS safe)
2. What we verified on this machine
3. Inventory: what breaks on Windows, by subsystem
4. Architecture: the seams we introduce
5. Phased plan, each phase independently landable
6. Testing & CI
7. Risks
8. Open questions

---

## 1. Ground rules — macOS must not regress

- **Every change is either additive (a Windows-only file/branch) or a pure
  refactor whose macOS behaviour is identical.** A refactor PR changes no
  macOS output: same paths, same commands, same arguments, same copy.
- **Branch on the host in one place.** A small `HostPlatform` seam (section 4)
  is the only thing that reads `Platform.isWindows` / `isMacOS` for policy.
  Call sites ask the seam (`host.homeDir`, `host.executableName('flutter')`,
  `host.pathSeparator`) rather than sprinkling `if (Platform.isWindows)`.
- **macOS implementations move, they are not rewritten.** Where a subsystem
  needs a strategy (editors, process killing, PATH writing, tool set), the
  existing macOS code becomes `Mac…` verbatim, and its tests keep pinning it.
- **The existing test suite stays green on macOS at every step**, and
  existing macOS-specific expectations (e.g. `/usr/bin/open -a …` in
  `external_editors_test.dart`) stay as they are — they become the macOS
  strategy's tests.
- **Native macOS code (`macos/`, `packages/*/macos`, `common/` in
  `webview_cef`) is touched only behind `#ifdef OS_WIN` / `OS_MAC` guards**,
  and any change to `packages/webview_cef/common/` is rebuilt and smoke-tested
  on macOS before it lands.
- **Release tooling for macOS is not modified at all (D5).** Windows gets
  its own scripts, storage, build counter and keys (Phase 8).
- A **macOS smoke checklist** (section 6) is run on every PR that touches
  shared code.

---

## 2. Verified on this Windows machine (2026-10-16)

| Check | Result |
|---|---|
| Flutter / Dart on PATH | Flutter 3.47.7 stable, Dart 3.13.5 |
| `serverpod` on PATH | `%LOCALAPPDATA%\Dart\install\bin\serverpod.bat` (a `.bat`, from `dart install`) |
| Serverpod CLI in pub cache | `serverpod_cli-4.1.0-beta.3` — has explicit Windows branches (`serverpod.bat`, `dart.exe`, `;` PATH split, no SIGTERM on Windows) |
| **AF_UNIX sockets in dart:io on Windows** | **Work.** Bind + connect + read on a short path succeeded on Dart 3.13.5. `serverpod_shared` requires Dart ≥ 3.11 for this. |
| AF_UNIX path limit | A long absolute path fails with "length of path exceeds the limit" (108 bytes incl. NUL). The CLI shortens with `shortestPath` (relative to **its own cwd**). |
| `Link.create` (CLI runner registry link) | **Fails** without Developer Mode: `errno 1314, A required privilege is not held`, even with an absolute canonical target — Dart creates a symlink, not a junction. |
| Developer Mode | Off |
| Visual Studio 2022 (C++ desktop workload), CMake | **Not installed** — required to build the Windows runner and CEF wrapper |
| Docker | Not installed |
| `windows/` runner in repo | Does not exist; `.metadata` lists only `root` and `macos` |

Consequences:

- The runner protocol **can** work on Windows over AF_UNIX — no transport
  change in the CLI is required for the common case.
- **Long project paths are the problem.** On macOS a too-long package path
  falls back to `~/.serverpod/runners/<id>/tui.sock` via a symlink; on a
  stock Windows install that symlink cannot be created, so a project whose
  `…\.dart_tool\serverpod\tui.sock` exceeds 108 bytes may be unreachable
  (and the runner may fail to bind it). Resolved by D2: App Studio requires
  Developer Mode (4.8), which makes the symlink possible. Phase 0 confirms.
- `shortestPath` is relative to the *caller's* cwd, so App Studio must
  compute its own short form; it cannot reuse a relative path the runner used.

---

## 3. Inventory — what breaks on Windows

Line numbers are from `main` @ `6c07782`.

### 3.1 Hard blockers (the app cannot start or do its job)

| # | Issue | Where |
|---|---|---|
| B1 | No `windows/` runner; CEF needs hooks in `wWinMain` (`initCEFProcesses`) and the message loop (`handleWndProcForCEF`) | repo root; `packages/webview_cef/windows/include/…/webview_cef_plugin_c_api.h` |
| B2 | `HOME` is unset on Windows → toolchain paths fall back to `%TEMP%`, runner registry dir becomes relative, `homeDirectory()` is null | `toolchain/toolchain_paths.dart:22-25`, `runner/runner_discovery.dart:182-187`, `util/home_dir_io.dart:3` |
| B3 | `whichOnPath` splits on `:`, requires POSIX exec bits, ignores `PATHEXT` → finds nothing | `toolchain/tool_probe.dart:551-574` |
| B4 | Flutter SDK judged incomplete: probes `bin/cache/dart-sdk/bin/dart` (no `.exe`) and runs `bin/flutter` (a sh script; need `flutter.bat`) | `tool_probe.dart:350-351`, `toolchain_installer.dart:271,362-372`, `project_dependencies.dart:49-61` |
| B5 | Child env: `Map.from(Platform.environment)` loses case-insensitivity (`Path` vs `PATH`), joins with `:`, and `includeParentEnvironment: false` drops `SystemRoot`/`PATHEXT`/`TEMP` (breaks almost every Windows exe) | `toolchain/toolchain.dart:71-77`, `tool_probe.dart:241-247,423-430`, `toolchain_installer.dart:362-403` |
| B6 | Installer is built on macOS tools: `xcode-select`, `osascript`, `/usr/bin/unzip`, `/bin/df`, `open -b`, `pgrep`; `releases_macos.json` | `toolchain/toolchain_installer.dart`, `install_plan.dart:14-17` |
| B7 | Tool set hard-requires Apple's Command Line Tools (`ToolId.commandLineTools`), and the manifest validator requires every `ToolId` | `tool_status.dart:8`, `toolchain_manifest.dart:84`, `assets/toolchain_manifest.json` |
| B8 | `platform_key_io.dart` returns `'unsupported'` off macOS; arch derived from `macos-arm64` | `toolchain/platform_key_io.dart:5-7`, `toolchain_controller.dart:195` |
| B9 | All menus, and therefore Uninstall, Check for Updates, Appearance, Close, Logs show/hide, migrations and **every keyboard shortcut**, exist only in the native macOS menu bar (`mac_menu_bar` is a no-op on Windows) | `platform/macos_app_menu.dart` (whole file, `:142` early-return) |
| B10 | Spawning `.bat` shims (`serverpod.bat`, `flutter.bat`, `opencode.cmd`) without care: argument quoting goes through `cmd.exe` rules | `serverpod_process.dart:914-949`, `project_creator.dart:216-237`, `opencode_serve.dart:73-85` |

### 3.2 Functional gaps (app runs, feature broken or silent)

| Area | Issue | Where |
|---|---|---|
| PATH persistence | Writes `export PATH=…` into `~/.zprofile`; Windows needs the user `Path` in `HKCU\Environment` + `WM_SETTINGCHANGE` broadcast. `RecordedPathLine {file, line}` needs a registry variant | `toolchain/shell_profile.dart`, `install_record.dart:10-32` |
| PATH discovery | "Login-shell PATH capture" has no meaning; the Windows analogue is reading fresh user + machine `Path` from the registry (a GUI app inherits Explorer's possibly stale env) | `toolchain/login_shell_path.dart` |
| Process teardown | SIGTERM/SIGKILL/group-kill semantics; `kill -0` liveness; no tree kill → `opencode serve` grandchildren survive | `process/dev_session_cleanup.dart:80-125`, `agent/opencode_serve.dart:180-194`, `runner/runner_ownership.dart:98`, `serverpod_process.dart:757-763` |
| Runner discovery | 104-byte limit hardcoded (Windows/Linux: 108); `p.canonicalize` lower-cases on Windows; registry dir from `HOME` | `runner/runner_discovery.dart:28-31,182-227` |
| Compact window | `dev.serverpod.appstudio/window` channel only in Swift; Dart would switch to the compact layout in an opaque normal window | `platform/compact_window.dart:77-102`, `main.dart:54`, `preview_mode_controller.dart:69-141` |
| Notifications | Channel only in Swift; gated `Platform.isMacOS` → silent | `platform/studio_notifications.dart:21` |
| Auto-update | Sparkle channel only; degrades to "unavailable" already | `update/update_controller.dart:167` |
| Version / analytics | App version/build read from Sparkle's `Info.plist` → empty; analytics id under `HOME` → `'unknown'` | `main.dart:69-70`, `analytics/analytics_user_id.dart:20-23` |
| External editors | `.app` bundles, `/usr/bin/open`, `/Applications`, Cursor's in-bundle CLI | `session/external_editors.dart` (whole file; good injection seam at `:160-170`) |
| Open URL | `/usr/bin/open <url>`; error swallowed | `util/open_url_io.dart:6` |
| Fonts | `.AppleSystemUIFont`, `Menlo`; weight-axis correction tuned to SF | `theme/app_theme.dart:9-32` (+ every `kMacMonoFont` use) |
| Copy | "⌘R", "⇧⌘R", "Terminal", "this Mac", "Apple's installer", `export PATH` | `hot_restart_button.dart:65`, `full_restart_button.dart:34`, `publish_to_cloud_button.dart:74`, `install_plan.dart:182`, `toolchain_notices.dart:141-152,232`, `manage_tools_pane.dart:117-122` |
| Paths in UI | `prettyPath` tests `'$home/'`; FVM/Puro detection splits on `/`; recents dedupe is case-sensitive | `util/pretty_path.dart:8`, `tool_status.dart:247`, `session/project_session.dart:41-51,100` |
| Uninstall | CLT via `osascript`; `~/Library/Application Support`; NSUserDefaults copy | `uninstall/uninstaller.dart`, `uninstall_confirm_dialog.dart` |
| Updates UI | "translocated" is a Gatekeeper concept | `update/update_state.dart:29-51` |

### 3.3 `webview_cef` on Windows

The Windows plugin forwards every call to `common/`, so the Dart API is
covered, but it has not been touched since the fork was imported
(`9b98806`), and the fork's later fixes were written against macOS:

| # | Issue | Where |
|---|---|---|
| W1 | `quit` pumps `CefDoMessageLoopWork()`; illegal with `multi_threaded_message_loop = true` (Windows) | `common/webview_plugin.cc:316-318,769` |
| W2 | After shutdown `HandleMethodCall` answers `result(0, nullptr)`; Windows maps 0 to `NotImplemented` → `MissingPluginException` on every quit from `WebViewController.dispose()` | `common/webview_plugin.cc:282-288`, `windows/webview_cef_plugin.cpp:436-438` |
| W3 | No `root_cache_path` → shared CEF user-data dir and singleton lock (the bug `511902c` fixed on macOS) | `common/webview_plugin.cc:759-766` (`#ifdef OS_MAC` only) |
| W4 | Keys forwarded to CEF are never swallowed → Flutter also handles them (double input / shortcuts firing while typing in the preview) | `windows/webview_cef_plugin.cpp` `handleMessageProc` |
| W5 | DevTools calls (`clearBrowsingData`, `reloadIgnoreCache`) and `CloseAllBrowsers` run on the platform thread while CEF's UI thread is separate | `common/webview_handler.cc` |
| W6 | Texture unregister commented out (upstream leak) | `windows/webview_cef_plugin.cpp:49` |
| W7 | x64 only (no arm64 CEF branch); CEF 149 download ~ hundreds of MB at CMake configure time | `windows/CMakeLists.txt`, `third/download.cmake` |

### 3.4 Release & dev tooling

Everything under `Makefile` and `tool/*.sh` is macOS-only (bash, `pod`,
`xcodebuild`, `codesign`, `notarytool`, `ditto`, `PlistBuddy`, Sparkle).
`make` itself is not on a stock Windows machine.

### 3.5 Tests that are POSIX-bound

`dev_session_cleanup_test` (`/bin/sleep`), `login_shell_path_test` (sh
scripts, `/bin/ps`), `toolchain_installer_test` (`/usr/bin/zip`,
`/bin/chmod`), `tool_probe_test` (exec bits, `xcode-select`),
`uninstaller_test` (`chmod`), `version_gate_test` (bash), `fake_runner.dart`
(`/tmp`, AF_UNIX), `macos_app_menu_test` (host guard), and path-literal
expectations in `toolchain_paths_test`, `runner_discovery_test`,
`shell_profile_test`, `install_record_test`, `toolchain_gate_test`,
`pretty_path_test`, `external_editors_test`.

### 3.6 Already portable (reuse as-is)

`file_selector`, `shared_preferences`, all pure-Dart deps, `shad`, the
JSON-RPC framing in `runner_client.dart`, `RunnerLaunch`,
`AnalyticsContext._platformString` (knows `Windows`),
`OpenCodeAuthStore` (`HOME ?? USERPROFILE`), the view interfaces
(`ToolsView`, `RunnerActionsView`, …), Widgetbook and its fakes,
`UpdateController`'s `MissingPluginException` fallback, CRLF-tolerant parsing
in `project_creator.dart`.

---

## 4. Architecture — seams to introduce

All new code lives beside what it abstracts; names are proposals.

### 4.1 `lib/platform/host.dart` — `HostPlatform`

One injectable object, `MacHost` / `WindowsHost` (+ `FakeHost` for tests):

- `homeDir` (`HOME` / `USERPROFILE`), `appSupportDir`
  (`~/Library/Application Support/App Studio` / `%APPDATA%\App Studio`),
  `localDataDir` (CEF cache: `%LOCALAPPDATA%\App Studio\CEF`),
  `dartInstallBinDir` (`~/Library/Application Support/Dart/install/bin` /
  `%LOCALAPPDATA%\Dart\install\bin`), `defaultPubCache`
  (`~/.pub-cache` / `%LOCALAPPDATA%\Pub\Cache`).
- `pathListSeparator` (`:` / `;`), `executableName('flutter')` →
  `flutter` / `flutter.bat`, `dart` / `dart.exe`, `serverpod` /
  `serverpod.bat`.
- `childEnvironment({PATH prefix, extras})` — builds a child env
  **case-insensitively** on Windows and always carries the Windows
  essentials (`SystemRoot`, `PATHEXT`, `TEMP`, `TMP`, `USERPROFILE`,
  `LOCALAPPDATA`, `APPDATA`, `ComSpec`) even when the parent env is otherwise
  excluded. macOS keeps today's exact env.
- `whichOnPath(name, path)` — on Windows: `;` split, `PATHEXT` expansion,
  existence check (no exec bits). macOS: today's function, moved verbatim.
- `isWithin(parent, child)` / `pathEquals` — case-insensitive on Windows;
  used by `prettyPath`, recents dedupe, FVM/Puro detection
  (`p.split` instead of `split('/')`).
- `modifierLabel` / `shortcutLabel(SingleActivator)` → `⌘R` / `Ctrl+R`.

`util/home_dir_io.dart`, `toolchain_paths.dart`, `runner_discovery.dart`,
`analytics_user_id.dart` and `project_session.dart` read the host instead of
`HOME`.

### 4.2 `ProcessLauncher` / `ProcessKiller`

- **Launch:** one function for "run a tool that may be a `.bat`/`.cmd`".
  On Windows, spawn `cmd.exe /d /s /c "<quoted command line>"` with strict
  quoting (reject or escape `%`, `^`, `&`, `|`, `"`, newlines — the
  BatBadBut class of bug), or better, **resolve the shim to its real
  command** where we can (`flutter.bat` → `bin\cache\dart-sdk\bin\dart.exe`
  + flutter_tools snapshot is *not* stable; `serverpod.bat` → `dart.exe
  <snapshot>` may be). Spike decides; default is the quoted `cmd /c` path.
- **Kill:** `MacProcessKiller` = today's `_signal` (TERM → wait → KILL,
  group kill when a leader). `WindowsProcessKiller` = `taskkill /PID n /T`
  then `/F`, liveness via `OpenProcess`-free `tasklist /FI "PID eq n" /NH`
  (or a tiny FFI call). Optional later: put children in a Job Object with
  `KILL_ON_JOB_CLOSE` so a crash takes them down too.
- Runner stop stays **over the socket first** on both platforms (already the
  policy); the signal fallback is a hard kill on Windows and is documented
  as such.

### 4.3 Per-platform tool set

`ToolId` gains `git` (Windows) alongside `commandLineTools` (macOS).
`ToolchainManifest` validates only the tool ids for the current platform;
the manifest JSON grows a `platforms` list per tool (schema 3, with schema 2
still read on macOS so old/new builds agree). The Windows set is
**Git for Windows → Flutter → Serverpod CLI**, the same load-bearing order
(Flutter runs on `git`).

### 4.4 PATH persistence: `PathWriter`

- `ShellProfilePathWriter` (macOS, today's `ShellProfile`, unchanged).
- `RegistryPathWriter` (Windows): read/modify `HKCU\Environment\Path`
  (preserving `REG_EXPAND_SZ` and `%VAR%` references — do **not** use
  `setx`, which truncates at 1024 chars and expands variables), broadcast
  `WM_SETTINGCHANGE "Environment"`. Implemented with `reg.exe query/add` or
  `package:win32` FFI (preferred — no quoting games).
- `InstallRecord`'s `RecordedPathLine {file, line}` gains a sibling
  `RecordedPathEntry {scope: user, entry}`; JSON is backward compatible.
- `LoginShellPath` gets a Windows counterpart: fresh user + machine `Path`
  from the registry, expanded, so tools installed after App Studio started
  are found without a restart.

### 4.5 App commands, decoupled from the menu bar

Extract the actions in `macos_app_menu.dart` into an `AppCommands` model
(id, label, shortcut, enabled/checked `ValueListenable`, handler).
`MacAppMenu` becomes a renderer of `AppCommands` onto `mac_menu_bar`
(**identical** items, ids, order and shortcuts — its test pins this). A new
`WindowsMenuBar` renders the same commands as an in-window Flutter
`MenuBar` (File · View · Server · Logs · Help) with `Ctrl` shortcuts
through `Shortcuts`/`CallbackShortcuts` at the app root. This keeps "one
source of truth for enabled state" (`canOpenProjects`, `_syncServerMenu`)
across both platforms.

### 4.6 Native channels on Windows

Same channel names, implemented in the Windows runner (`windows/runner/`):

- `dev.serverpod.appstudio/window` — v1: **not implemented**; Dart hides the
  minimize/compact toggle when `CompactWindowPlatform.isSupported` is false.
  Later phase: a Win32 implementation (borderless, `WM_NCHITTEST` for
  drag/resize, `WM_SIZING` aspect lock). True per-pixel transparency of the
  Flutter surface on Windows is non-trivial and is the main cost.
- `dev.serverpod.appstudio/notifications` — Windows toast (via a plugin such
  as `local_notifier`, or WinRT `ToastNotificationManager` in the runner;
  requires an AppUserModelID / Start-menu shortcut, which the installer
  provides).
- `dev.serverpod.appstudio/updates` — WinSparkle bridge with the same
  methods (`getState`, `setSessionBusy`, `checkForUpdates`,
  `setAutomaticallyChecks`, native→Dart `prepareForRelaunch`). WinSparkle's
  `win_sparkle_set_can_shutdown_callback` / `shutdown_request_callback` map
  onto the existing busy/teardown contract.
- Window min size 670×720 and initial size set in `windows/runner/main.cpp`
  / `flutter_window.cpp` (`WM_GETMINMAXINFO`), kept in step with
  `kMinAppWindowSize`.

### 4.7 External editors: `EditorLauncher` strategy

`MacEditorStrategy` = today's code, verbatim. `WindowsEditorStrategy`:

| Editor | Detect | Launch |
|---|---|---|
| VS Code | `%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe`, `%ProgramFiles%\Microsoft VS Code\Code.exe` | `Code.exe <path>` (or `bin\code.cmd`) |
| Cursor | `%LOCALAPPDATA%\Programs\cursor\Cursor.exe` | Same trick as macOS: `ELECTRON_RUN_AS_NODE=1 Cursor.exe resources\app\out\cli.js <path>` — **verify** it reaches the Agents Window on Windows |
| Claude / Codex / OpenCode | protocol handler registered in `HKCU\Software\Classes\<scheme>` (installed check) | deep link via `ShellExecute` / `url_launcher` |
| Antigravity | — | no button (same reason as macOS until verified) |

The "is it installed" check matters even more on Windows: an unregistered
scheme opens a "choose an app" dialog.

### 4.8 Developer Mode as a setup prerequisite (D2)

Developer Mode lets an unelevated process create symlinks. The Serverpod
CLI's runner registry (`~\.serverpod\runners\<id>` → `<server>\.dart_tool\serverpod`)
needs that, and so does Flutter whenever a project carries a Windows
desktop target (`.plugin_symlinks`). With it on, the socket path a client
uses for a deep project is
`C:\Users\<user>\.serverpod\runners\<uuid>\tui.sock`, about 70 bytes and
well inside the 108-byte limit.

- **It is a prerequisite tool, not a tool App Studio installs.** It gets a
  `ToolId.developerMode` (Windows only) that comes first in the setup order,
  before Git, since nothing after it should hit the symlink failure.
- **Probe:** read
  `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowDevelopmentWithoutDevLicense`
  (DWORD 1 = on). This is a read with no side effects, so it is safe to run
  before `runApp`, like the other probes.
- **Enable (preferred):** an elevated `reg.exe add … /t REG_DWORD /d 1 /f`
  launched with `ShellExecuteEx` verb `runas`. Windows raises its own UAC
  prompt; App Studio itself never runs elevated. The setup row says
  "Requires administrator approval". Afterwards App Studio re-probes rather
  than trusting the exit code, the same way the CLT install is polled on
  macOS.
- **Fallback:** if UAC is cancelled or the account is not an administrator,
  or the setting is policy-locked (managed machines), show guidance:
  - open `ms-settings:developers` (Settings → System → For developers);
  - the exact toggle to flip;
  - a **Check again** button, the same pattern as `ManualUpdateDialog`.

  Setup blocks on it, like a too-old user-installed Flutter does.
- **Install record:** record `developerMode: enabledByAppStudio` only when
  App Studio turned it on. Uninstall then offers to turn it off again
  (elevated the same way). It is unticked by default, because other tools
  may rely on it.
- **Runner discovery is unchanged in policy.** App Studio tries the package
  path first and then the registry link, as the CLI's own clients do.
  - With Developer Mode **off**, a server package path that doesn't fit is
    reported with a message pointing at the setting.
  - That can only happen if the user turned it off after setup. In that
    case the setup gate re-raises the prerequisite on the next launch.
- **Widgetbook:** add use cases for the on, UAC-cancelled and policy-locked
  states.

---

## 5. Phased plan

Each phase ends green on macOS (tests + smoke checklist) and is mergeable on
its own. Rough sizes are relative (S/M/L/XL).

### Phase 0 — De-risk spikes (S–M, no product code merged)

Goal: prove the three load-bearing assumptions before investing.

0.1 **Build environment.** Install VS 2022 Build Tools (Desktop C++ workload)
    + CMake; `flutter doctor` clean for Windows.
0.2 **Runner end-to-end with the stock CLI** on a Windows box:
    `serverpod create` → `serverpod start` → `serverpod attach`; record:
    database requirements (Docker Desktop/WSL2? embedded Postgres?), firewall
    prompts, how the CLI detaches the runner on Windows, `runner.json`
    contents, socket path used, behaviour with a **long project path**
    (>~60 chars server dir) and with Developer Mode off, `serverpod runner
    stop`, and Ctrl+C semantics.
0.3 **Attach from Dart:** a scratch client using App Studio's
    `runner_client.dart` connects, sends `snapshot`, streams events.
0.4 **CEF on Windows:** `flutter create --platforms=windows` in a branch,
    wire `initCEFProcesses` / `handleWndProcForCEF`, load the runner's
    `flutterAppState.url`, check input, IME, resize, DevTools, quit.
0.5 **`.bat` spawning:** confirm quoting for paths with spaces, `&`, `%`,
    non-ASCII; decide `cmd /c` vs resolving shims.

0.6 **Developer Mode via UAC:** confirm that an elevated `reg add` of
    `AllowDevelopmentWithoutDevLicense` takes effect for symlink creation
    without a logoff. Also check what a Group-Policy-locked machine reports.

Exit: a short findings note appended to this spec, and a go/no-go on D2
holding without CLI changes.

#### Phase 0 findings (2026-10-16)

**Verdict: go.**
- **The protocol works on Windows unchanged.** The runner, its protocol and
  App Studio's own client all work as they are.
- **D2 holds:** with Developer Mode on, deep projects attach through the
  CLI's registry symlink, with no CLI change needed.
- **Two real problems.** Both sit in code App Studio owns:
  - the CEF GPU texture path does not reach Flutter;
  - window close skips the exit hook.
- **Not tested yet:** IME, DevTools, the software path's quit, and the
  Developer Mode UAC flow. These need a VM, or Phase 2.

Work was done on the branch `spike/windows-phase0`. Nothing is committed.

| # | Check | Result |
|---|---|---|
| 0.1 | Build environment | VS 2022 17.14 + Flutter 3.47.7. `flutter create --platforms=windows` plus the two CEF hooks in `main.cpp` builds `appstudio.exe` with CEF 149. The first build took 186 s, including the CEF download and the wrapper compile; incremental builds take 10–40 s. |
| 0.2 | Runner, short path | `serverpod create` (fullstack, `--ide claude`) took 28 s. `serverpod runner start --directory` returned in 35 s. The runner is detached and survives its parent shell. |
| 0.2 | Database | **No Docker.** The CLI runs a bundled **Postgres 16** per project from `%LOCALAPPDATA%\serverpod\Cache\pg-binaries\…\postgres.exe -D <server>\.serverpod\development\pgdata`. This answers open question 9: nothing to install. |
| 0.2 | Runner, long path (183-byte socket path) | The CLI created `~\.serverpod\runners\<id>` as a **symlink**, which needs Developer Mode. App Studio's `runnerSocketPath` fell back to it (78 bytes) and attached. |
| 0.2 | Stop over socket | `RunnerClient.stop()` closed the connection within 16 ms. Discovery then reported `NoRunner`, and the Flutter web server and Dart processes exited. **But the project's `postgres.exe` was orphaned and kept running.** It had to be stopped with `pg_ctl stop -D <pgdata> -m fast`. This is a CLI bug on Windows (worth reporting to Serverpod). App Studio can mitigate it after a stop it initiated, using the `pgdata` path. |
| 0.2 | Flutter app teardown | When the last preview page disconnects, the runner logs `Flutter heartbeat: no isolates; tearing down.` and stops the web app. A crashed or restarted App Studio therefore finds it gone. `launchFlutterApp` brings it back on a **new port** within ~50 s, which App Studio already handles. This is runner behaviour on every platform, not Windows-specific. |
| 0.2 | CLI wart | `serverpod create` prints "Updating Flutter app MacOS entitlements… failed" on Windows. It is harmless. |
| 0.3 | App Studio's client, unchanged | `resolveRunner` took 26–36 ms; `attach` got the snapshot, armed auto-launch, streamed events and delivered the preview URL. **The only Windows fix needed is `HOME`**: the probe supplied it from `USERPROFILE` (B2). `p.canonicalize` lower-cases the path, which AF_UNIX accepts. |
| 0.4 | CEF, GPU texture path (fork default) | **Broken.** Flutter 3.47 on Windows renders with **Impeller (OpenGL ES)**. CEF does produce `OnAcceleratedPaint` frames, but every one fails in the engine with `Could not create external texture`, so the webview stays blank. The plugin also warns "no GPU accelerated-paint frame after 5s". |
| 0.4 | CEF, software path (`WEBVIEW_CEF_GPU_TEXTURE=OFF`) | **Works**, as confirmed by eye: the Serverpod app renders, and clicks, typing and window resize work. `executeJavaScript`, `evaluateJavascript`, `reloadIgnoreCache` and `clearBrowsingData` all return. |
| 0.4 | Keys (W4) | **Confirmed:** every key typed into the webview also reached Flutter's `HardwareKeyboard` handler. App Studio's Ctrl shortcuts would fire while the user types in the preview. |
| 0.4 | Quit, GPU path | `WebviewManager.quit()` crashed with an **access violation in `webview_cef_plugin.dll`** (WER APPCRASH). This is W1/W2-class. |
| 0.4 | Quit, software path | Inconclusive. The automated run stalled after loading `about:blank`. Retest in Phase 2. |
| 0.4 | Window close | **`AppLifecycleListener.onExitRequested` did not fire** when the window's X was clicked. The process exited without running teardown. No CEF processes were left behind, but App Studio's runner stop and `opencode` stop would never run. Phase 2 must make WM_CLOSE reach the framework (`System.requestAppExit`) before anything else relies on teardown. |
| 0.5 | `.bat` spawning | **Every naive route is unsafe or broken:** <ul><li>`Process.run('x.bat', args)` **executed `b` from the argument `a&b`**, which is command injection;</li><li>`runInShell` and `cmd /c` fail on any path with a space;</li><li>child output decoded with the default system code page mangles non-ASCII text.</li></ul> **A real `.exe` with `stdoutEncoding: utf8` received all eleven hostile arguments intact**: non-ASCII, `&`, `%`, `^`, `"`, `|`, `( )`, `;`, an empty argument and trailing `\`. |
| 0.5 | Shims | `serverpod.bat` (from `dart install`) is a two-line wrapper with a `REM target_file_path_marker` line, followed by the real `…\app-bundles\serverpod_cli\hosted\<v>\bundle\bin\serverpod.exe`. `flutter.bat` is a real script and needs `cmd`. App Studio passes only fixed tokens to `flutter`; paths go through `workingDirectory`. |
| 0.6 | Developer Mode | The registry probe (`AllowDevelopmentWithoutDevLicense` = 1) works. With it on, Dart `Link.create` and AF_UNIX through the link both work. The UAC enable flow and the Group-Policy case still need the clean VM (section 9). |

**Plan changes that follow:**

1. **CEF rendering (Phase 2):**
   - Ship the software pixel-buffer path on Windows. Set
     `WEBVIEW_CEF_GPU_TEXTURE` to `OFF` in `packages/webview_cef/windows/CMakeLists.txt`.
     It is Windows-only, so macOS is not affected.
   - Revisit the GPU path later. It needs Flutter's Windows embedder to
     accept a D3D11 shared-handle texture under Impeller, or a Skia
     fallback, if one still exists.
   - Measure the software path's CPU cost on a busy page.
2. **Exit hook (Phase 2, blocking):**
   - Make window close run `onExitRequested`, and verify it with
     `AppExitResponse.exit`.
   - Then retest quit on the software path:
     - W1: no `CefDoMessageLoopWork` under the multi-threaded loop;
     - W2: `close` after `quit` must not throw.
3. **W4 (Phase 2/5):** the Windows plugin must swallow the keys it delivers
   to a focused webview, as the macOS router does.
4. **`ProcessLauncher` (Phase 1):**
   - Never pass arguments to a `.bat`.
   - Resolve `serverpod.bat` to its target `.exe` through the marker line.
     If the marker is missing, fall back to the `.exe` beside the bundle;
     otherwise, refuse.
   - Run `flutter.bat` through `cmd` with fixed arguments only, so that
     every path travels in `workingDirectory` or the environment.
   - Decode child output as UTF-8.
5. **Postgres after stop (Phase 4):** after a stop App Studio initiated,
   check for the project's `postmaster.pid`. If its process is alive, run
   `pg_ctl stop -m fast` from the CLI's `pg-binaries`. Report the CLI bug
   upstream.
6. **Open question 9 is closed:** no Docker on Windows.

### Phase 1 — Foundations: host seam, no behaviour change on macOS (M)

- Add `HostPlatform` (4.1) and route `HOME`, app-support, Dart-install,
  pub-cache, PATH separator and executable names through it.
- Move `whichOnPath`/`pathContainsDir` behind the host; Windows version with
  `PATHEXT`.
- Rebuild `processEnvironment()` on `host.childEnvironment` (case-insensitive
  env, Windows essentials).
- `ProcessLauncher` + `ProcessKiller` (4.2); `dev_session_cleanup`,
  `opencode_serve`, `runner_ownership`, `serverpod_process` use them.
- `prettyPath`, FVM/Puro detection, recents dedupe become separator- and
  case-aware.
- `platform_key_io.dart` returns `windows-x64` / `windows-arm64`; arch
  derivation stops string-matching `macos-arm64`.
- Unit tests run against `FakeHost(windows)` **on the macOS host**, so this
  phase is fully testable before a Windows runner exists.

#### As built (2026-10-16)

- `lib/platform/host_platform.dart` (pure) + `host.dart` (`currentHost`,
  which carries `package:path`'s own context so `currentHost.path.join` is
  `p.join` on the machine itself). `ToolchainPaths`, `Toolchain`, the probe,
  runner discovery, `prettyPath`, the home directory, recents and the
  platform key all go through it; macOS answers are unchanged and pinned by
  tests that pass `HostPlatform.macos` explicitly.
- `process/tool_command.dart`: `resolveToolCommand` skips a `dart install`
  launcher for the `.exe` it names and refuses unsafe arguments to any other
  batch file (0.5). Used for `serverpod runner start`, `serverpod create`,
  `pub get`, the probe's `--version` and `opencode serve`.
- `process/process_killer.dart`: the macOS signal logic moved verbatim. **On
  Windows it ends only the process (`TerminateProcess`)** — the `taskkill
  /T` tree walk first written here is gone (see the afunix risk below), and
  ending the tree moves to Phase 2, as a Job Object the children start in.
- Tests: `process` tag for anything that starts real processes or opens
  AF_UNIX sockets (fake runners); `@TestOn('mac-os || linux')` for POSIX-only
  files; `macOSOnlyForNow` skips three tests of behaviour a later phase
  ports. On the Windows dev laptop: `flutter test -x process -j 1` — 587
  pass, 17 skipped, 0 fail (81 failed before). Fake runner pids are
  impossible pids (`FakeRunner.fakePid`).
- `.gitattributes` pins LF everywhere (CRLF for `.bat`/`.cmd`).
- **CI moved forward into this phase** (section 6), because the `process`
  tests now only run there.

### Phase 2 — Windows runner, CEF, boots to the start page (L)

- `flutter create --platforms=windows --org dev.serverpod .`; commit
  `windows/` (with its generated `.gitignore`). Product name "App Studio",
  exe `App Studio.exe` (or `AppStudio.exe` — question), icon, version
  resource from `pubspec.yaml`.
- `main.cpp`: `initCEFProcesses` first; `handleWndProcForCEF` in the loop;
  min size 670×720 via `WM_GETMINMAXINFO`.
- `webview_cef` Windows fixes W1–W6, each behind `OS_WIN` or in
  `windows/`; W3 sets `root_cache_path` to `%LOCALAPPDATA%\App Studio\CEF`.
  Re-verify macOS after any `common/` edit.
- `CompactWindowPlatform.isSupported`; hide the minimize toggle on Windows.
- Guard `MacAppMenu` construction; stub `AppCommands` renderer so the app
  boots.
- Exit test: launch on Windows, start page renders, no unhandled
  exceptions, quit is clean (no orphaned CEF subprocesses).

#### As built (2026-10-17)

- **Runner** (`windows/runner`): CEF hooks, title "App Studio", 1280×800,
  670×720 minimum; `setCEFRootCachePath(%LOCALAPPDATA%\App Studio\CEF)` (W3)
  before the window exists, through a new export of the plugin's C API.
- **`webview_cef`**, every change fenced so macOS compiles what it did
  before: software pixel-buffer path is the Windows default
  (`WEBVIEW_CEF_GPU_TEXTURE` OFF, Phase 0); W1 — `quit` sleeps briefly
  instead of pumping `CefDoMessageLoopWork()` on Windows; W2 — after
  shutdown Windows answers a null success instead of NotImplemented; W3 —
  `setRootCachePath` for Windows/Linux. W4 (key swallowing) stays with
  Phase 5, W5/W6 with the preview work in Phase 4.
- **Window close → teardown.** The engine only routes `WM_CLOSE` to the
  framework for the process's *last* top-level window, and CEF keeps hidden
  windows of its own, so the close bypassed `onExitRequested` (Phase 0).
  `FlutterWindow` now intercepts `WM_CLOSE` and asks Dart over
  `dev.serverpod.appstudio/lifecycle`; `lib/platform/window_close.dart`
  answers with `exitApplication(AppExitType.cancelable)`, which runs the same
  `onExitRequested` teardown as ⌘Q. If Dart cannot answer, the window closes
  as before. Verified: the setup screen's close ran the teardown, no
  processes left behind. A ~2 s pause on close with nothing running is to be
  measured in Phase 4.
- **Compact window:** `CompactWindowPlatform.supportsCompactWindow` (macOS
  only); without it a minimized phone view behaves as desktop-minimized —
  chrome hidden, window untouched — so the toggle stays useful.
- **Job Objects — decided against for the runner.** A child inherits its
  parent's job, so `serverpod runner start` in a kill-on-close job would take
  the *detached* runner with it when App Studio exits: against the design
  (App Studio stops only its own runner, over the socket) and the very
  process-exit-with-AF_UNIX pattern of the afunix risk. A job belongs only
  around `opencode serve`, when the agent is switched back on.
- Boots to the first-run setup screen on Windows (the tool set is Phase 3).

### Phase 3 — Toolchain on Windows: probe, install, PATH (L)

- Per-platform tool set (4.3). The Windows order is **Developer Mode (4.8)
  → Git for Windows → Flutter → Serverpod CLI**.
- **Git for Windows (D3).** Probe:
  1. `git.exe` via `whichOnPath`;
  2. `%ProgramFiles%\Git\cmd\git.exe` and `%LOCALAPPDATA%\Programs\Git\cmd\git.exe`;
  3. the registry (`HKLM`/`HKCU\SOFTWARE\GitForWindows\InstallPath`).

  Install:
  - Resolve the latest release from the official `git-for-windows/git`
    GitHub releases API and pick the `64-bit.exe` asset. Verify it against
    the release's published sha256.
  - Run it per-user and silently:
    `/VERYSILENT /NORESTART /CURRENTUSER /NOICONS /SP- /SUPPRESSMSGBOXES`,
    plus `/COMPONENTS` / `/o:PathOption=Cmd`, so `git` lands on the user
    `Path`.
  - Record it so uninstall can offer `unins000.exe /VERYSILENT`.
  - Afterwards, set `git config --global core.longpaths true` only if the
    user has no value for it already. Record it as ours.
- Flutter: `releases_windows.json`, archive verified against the feed's
  sha256, extracted with `package:archive` (or `tar.exe`, which ships with
  Windows 10 1803+) into `%USERPROFILE%\develop\.flutter-install-<stamp>` and
  renamed into place (retry on `ERROR_ACCESS_DENIED` — Defender holds new
  files briefly). `flutter.bat` for every run. Probe `dart.exe`.
- Serverpod CLI: `dart install serverpod_cli@<v>` →
  `%LOCALAPPDATA%\Dart\install\bin\serverpod.bat`.
- `RegistryPathWriter` + registry PATH discovery (4.4); install record
  entries for registry PATH changes.
- Free-space check via `GetDiskFreeSpaceEx` (FFI) or skip gracefully as
  today's `df` failure path does.
- Copy: "Apple's command line tools" → "Git for Windows", "Terminal" →
  "PowerShell", sh `export` → PowerShell/`setx`-free instructions, plan
  dialog names `%USERPROFILE%\develop\flutter`.
- Windows-specific checks to surface in setup:
  - MAX_PATH: read the `LongPathsEnabled` registry flag and warn only; do
    not change it.
  - Developer Mode (4.8) is a blocking prerequisite.
- Widgetbook use cases for the Windows variants of every setup state.

#### As built (2026-10-17)

- **Tool set per host.** `ToolId` declares the hosts that need it
  (`ToolId.requiredOn`): macOS keeps Command Line Tools → Flutter →
  Serverpod; Windows is Developer Mode → Git for Windows → Flutter →
  Serverpod. One `assets/toolchain_manifest.json` serves both;
  `ToolManifest.tryParse(…, host:)` requires and keeps only that host's
  tools, so a Mac's inventory is exactly what it was.
- **`lib/platform/windows/`**: `WindowsSystem` (interface) +
  `Win32System` (`dart:ffi`: `RegGetValueW`, `RegSetKeyValueW`,
  `SendMessageTimeoutW`, `ShellExecuteExW` "runas") — no PowerShell or
  `reg.exe` parsing; `NoWindowsSystem` elsewhere and in sandboxes;
  `FakeWindowsSystem` in tests. `ffi` (already in the lockfile) is now a
  direct dependency. `registryPath()` (machine + user `Path`, expanded)
  replaces the login-shell `PATH` on Windows, for the probe and installs.
- **Probe:** Developer Mode from the registry (and the Group Policy that can
  lock it); Git on `PATH`, in `%ProgramFiles%\Git` or
  `%LOCALAPPDATA%\Programs\Git`, versioned by `git --version`.
- **Installs:**
  - Developer Mode — an elevated `reg.exe add` through Windows' UAC prompt
    (`ToolPhase.waitingForApproval`), read back from the registry;
    declined, failed or policy-locked → a `ToolInstallException` naming
    Settings → System → For developers, and the dialog's Try again.
  - Git — latest release from the GitHub API, the `-64-bit`/`-arm64`
    installer verified against the asset's `sha256` digest (refused without
    one), run `/VERYSILENT /CURRENTUSER /o:PathOption=Cmd` into
    `%LOCALAPPDATA%\Programs\Git`; its own installer owns the `Path` entry.
  - Flutter — `releases_windows.json`, `tar.exe` unpacks the zip, the
    rename into `%USERPROFILE%\develop\flutter` retries while Defender holds
    files, `flutter.bat` runs with the registry `Path` (so the Git just
    installed is found).
  - Serverpod — `dart.exe install` with the registry `Path`; records
    `serverpod.bat`.
  - `PATH` — appended to `HKCU\Environment\Path` as stored (`%VARS%` kept,
    `REG_EXPAND_SZ`), skipped when already on the machine or user `Path`,
    then `WM_SETTINGCHANGE`. Recorded as `{file: HKCU\Environment\Path,
    line: <dir>}`; uninstall removes exactly that entry.
- **Copy:** the manual Flutter update command is `flutter.bat` (PowerShell
  `& "…"` when quoted) and says PowerShell; Developer Mode reads "On".
- **Verified on the dev laptop:** the real probe finds everything (286 ms,
  `needsSetup=false`) and App Studio opens on the start page.
  **Not yet exercised for real:** Developer Mode via UAC, the Git install
  and a fresh Flutter install — they need the clean-room VM (section 9),
  since this machine already has all of them. Uninstalling Git/Developer
  Mode is Phase 6 (not offered until then). Widgetbook Windows use cases and
  the `LongPathsEnabled` warning are still to do.

### Phase 4 — Runner, projects and preview on Windows (L)

- Discovery: 108-byte limit off macOS; registry dir from the host;
  `shortestPath` computed against **App Studio's** cwd; canonical-path
  comparisons case-insensitive.
- Long paths rely on Developer Mode (D2, 4.8). The CLI's registry symlink
  then exists and App Studio connects through it. No CLI changes. Phase 0.2
  confirms this end to end with Developer Mode on, and confirms the exact
  failure with it off so the error message can name the fix.
- `launchRunnerProcess` / `ProjectCreator` / `ProjectDependencies` via
  `ProcessLauncher`; verify the CLI's detach on Windows leaves the runner
  alive after App Studio quits and that `reclaimOwnedRunner` stops it over
  the socket on next launch.
- Teardown: `onExitRequested` path verified on Windows (window close, Alt+F4,
  logoff/shutdown `WM_QUERYENDSESSION`), CEF quit ordering, no orphans
  (check with `tasklist` in an integration script).
- `patchFlutterAppForPreview` unchanged (`device: web-server`).
- New Project dialog: `file_selector` works; name rules unchanged; default
  location `%USERPROFILE%\…` (question Q8).

### Phase 5 — Commands, menus, shortcuts, platform polish (M–L)

- `AppCommands` extraction (4.5) with `MacAppMenu` producing identical
  output (existing test is the gate), then `WindowsMenuBar` + Ctrl
  shortcuts. Settings at `Ctrl+,`, Close `Ctrl+W`, Hot Restart `Ctrl+R`,
  Full Restart `Ctrl+Shift+R`, migrations `Ctrl+M`, logs `Ctrl+L`.
- Shortcut glyphs in tooltips/copy from `host.shortcutLabel`.
- Ctrl+C/V/X/A/Z inside the CEF preview (Windows counterpart of
  `sendEditCommand`), and fix W4 so typed keys do not double-fire shortcuts.
- Fonts: `Segoe UI Variable` (fallback `Segoe UI`) and `Cascadia Mono`
  (fallback `Consolas`); re-measure the weight-axis correction for Segoe UI
  Variable or disable it on Windows. macOS values unchanged.
- `openUrl` via `url_launcher` (already transitive) on Windows; macOS keeps
  `/usr/bin/open`.
- Notifications channel on Windows (4.6).
- External editors strategy (4.7).
- App version from a generated constant (`--dart-define` or a build-time
  `version.g.dart`) on Windows; analytics id `%USERPROFILE%\.serverpod\uuid`
  (matches the CLIs' `LocalStorageManager.homeDirectory`).

#### As built (2026-10-17)

- **Menu:** `lib/platform/windows_app_menu.dart` (`WindowsAppMenuBar`) is a
  shad menu strip above the app, mounted through `ShadApp.builder` on
  Windows only.
  - Menus: File (New, Open, Open Recent, Close, Settings, Exit) · View
    (Appearance) · Server · Logs · Help (updates, Uninstall).
  - Shortcuts: a `HardwareKeyboard` handler, with Ctrl but not Alt (AltGr
    is Ctrl+Alt).
  - **Deviation from 4.5:** there is no `AppCommands` extraction. The strip
    repeats `MacAppMenu`'s enable rules command for command, so the macOS
    menu code is untouched.
- **Shortcut hints:** `shortcutHint()` (`lib/platform/shortcut_hint.dart`)
  gives `Ctrl+Shift+R` on Windows and `⇧⌘R` on macOS.
- **Fonts:**
  - UI text uses shad's bundled Inter on Windows. Segoe UI Variable was
    not adopted: Inter keeps the macOS metrics, and the weight-axis
    correction is set to 1 on Windows.
  - Monospace: `kMonoFont` (renamed from `kMacMonoFont`) is Cascadia Mono
    on Windows and Menlo on macOS.
- **`openUrl`:** `ShellExecuteW` "open" through `Win32System.shellOpen`,
  with no `url_launcher`.
- **External editors (4.7):**
  - Cursor and VS Code run as `<exe> resources\app\out\cli.js <folder>`
    with `ELECTRON_RUN_AS_NODE=1`, which is what their `bin\*.cmd` does.
    The exe is real, so the folder is passed as one argument with no
    cmd.exe parsing.
  - Search order: `%LOCALAPPDATA%\Programs` first, then `%ProgramFiles%`
    (VS Code only).
  - No `cli.js` means no button. Unlike macOS there is no `open -a` to
    fall back to.
  - Claude, Codex and OpenCode open by deep link through `ShellExecute`.
    The link is offered only when `AssocQueryStringW` finds a handler for
    the scheme, which covers Store apps too. Antigravity gets no button.
  - **Still to verify:** that Cursor's CLI reaches its Agents Window on
    Windows.
- **Preview keys (W4):**
  - The runner now calls `routeKeyForCEF` after `TranslateMessage` and
    skips `DispatchMessage` for keys that belong to the page alone.
  - While the preview has Flutter focus:
    - Ctrl+X/C/V/A/Z/Y and Ctrl+Shift+Z become frame editing commands, as
      on macOS.
    - Ctrl on another character key stays the app's shortcut.
    - Modifiers and IME keys go to both the page and Flutter.
    - Alt+F4 stays with the window.
    - Everything else, including AltGr characters, goes to the page alone.
  - A key up always follows its key down.
  - Keys typed while the preview is not focused no longer reach the page.
  - **Verified** with a throwaway spike that posted keys to its own window.
    a, Ctrl+A, Ctrl+Left and AltGr+2 reached the page once each and
    Flutter not at all. Ctrl+R reached Flutter only. A key typed into a
    Flutter field reached that field only.
- **Version:** the runner answers `updates.getState` with `configured:
  false` and the `currentVersion`/`currentBuild` CMake compiles in from
  pubspec (`0.2.3+22` → `0.2.3`, `22`). The version label and analytics
  get it, and WinSparkle extends the same channel in Phase 8. The analytics
  id already resolves to `%USERPROFILE%\.serverpod\uuid` through
  `homeDirectory()` (Phase 1).
- **Deferred:**
  - Notifications move to Phase 8. Toasts need the AppUserModelID that
    the installer's Start-menu shortcut provides, and
    `StudioNotifications` already does nothing off macOS.
  - Widgetbook Windows use cases (the menu strip, the setup rows for
    Developer Mode and Git) are not done.
- **Still to check in the VM:** the version line in the log
  (`UpdateController: … Version 0.2.3 (build 22)`), the editor buttons
  with real installs, and preview copy and paste against a real Flutter
  web app.

### Phase 6 — Uninstall on Windows (M)

Remove `%APPDATA%\App Studio`, `%LOCALAPPDATA%\App Studio` (CEF),
registry PATH entries exactly as recorded, Flutter dir (if ours), `dart
uninstall serverpod_cli`, pub cache (with Flutter, same rule), `~\.serverpod`
(with the CLI, same rule), shared_preferences. Git for Windows: only if we
installed it, via its own `unins000.exe /VERYSILENT`, offered as a ticked
checkbox. Developer Mode: only if we enabled it, offered unticked, and
turned off through the same UAC route. Files
held open by a running `dart.exe` are the Windows-specific failure mode —
stop the session first (already the order) and retry deletes. The app's own
binaries are removed by the installer's uninstaller, not by App Studio.

#### As built (2026-10-17)

- **Offered** (`ToolchainController.removableTools`), only for tools App
  Studio's install record holds, in removal order:
  - Serverpod, then Flutter.
  - Git for Windows, when its `cmd\git.exe` is still there; ticked.
  - Developer Mode, when it is still on; offered unticked
    (`kUninstallUntickedByDefault`) and labelled "Turn off Developer Mode".
- **Git:**
  - `unins000.exe /VERYSILENT /NORESTART /SUPPRESSMSGBOXES`. Inno's
    uninstaller relaunches itself from the temp folder and returns at once,
    so App Studio polls until `git.exe` is gone (up to 3 minutes), then
    deletes what is left of the folder.
  - Git's uninstaller removes its own `Path` entry.
  - If there is no uninstaller, the error points to Settings → Apps →
    Installed apps.
- **Developer Mode:** the same elevated `reg add`, with `/d 0`, read back
  from the registry. A declined prompt is a named failure, and the rest of
  the uninstall continues.
- **Folders:**
  - `%APPDATA%\App Studio` as before.
  - New: `%LOCALAPPDATA%\App Studio` (`ToolchainPaths.localDataRoot`),
    which holds the CEF cache.
  - `~\.serverpod` goes with the CLI, as on macOS.
  - All of them go through `deleteDirectory`, which retries five times,
    500 ms apart. That covers files the session's processes and CEF's
    helpers still hold for a moment after teardown.
- **Copy:** the dialog and the final screen say "Settings → Apps → Installed
  apps" on Windows instead of the Trash.
- **Left for Phase 8:**
  - `shared_preferences` is cleared but its file stays, under
    `%APPDATA%\dev.serverpod\appstudio`, named from `Runner.rc`'s
    CompanyName and ProductName. Those two still read `dev.serverpod` and
    `appstudio`. Rename them with the installer, and have its uninstaller
    remove that folder.
- **Still to check in the VM:** a real Git uninstall, and the UAC prompt
  turning Developer Mode off.

### Phase 7 — Compact window on Windows (L–XL, optional for v1)

Win32 implementation of the `window` channel (borderless,
`WM_NCHITTEST`-based drag/corner resize, aspect lock in `WM_SIZING`,
diagonal cursors are native on Windows so the cursor channel is not needed).
Transparency: `DwmExtendFrameIntoClientArea` + a transparent Flutter
surface; prototype first, ship only if it looks right with CEF composited
underneath.

#### As built (2026-10-17)

- `windows/runner/compact_window.cpp` implements the `window` channel.
  - **Shape:** the window goes borderless but stays sizable (`WS_THICKFRAME`
    with `WM_NCCALCSIZE` returning 0), with rounded corners on Windows 11.
  - **Size:** `WM_SIZING` holds the frame's aspect on the content (fixed
    chrome, as on macOS). An orientation flip carries the frame's scale.
    The window stays inside the work area and enters at most 80% of its
    height.
  - **Exit:** restores the saved placement and styles exactly.
  - **Move and resize:** `startDrag` and `startResize` post a message that
    starts Windows' own modal loops (`WM_NCLBUTTONDOWN` with `HTCAPTION` or
    the corner's `HT*`), after the method call has been answered. The
    corners' diagonal cursors come from the engine (`MouseRegion`), so
    `showResizeCursor` is a no-op on Windows.
- **Not transparent.** Flutter's Windows embedder draws to a swap chain DWM
  cannot blend per pixel, so the margin around the frame shows the app's
  background. `CompactWindowChannel.supportsTransparency` keeps `ShadApp`
  opaque there.
- The Windows menu strip hides while compact (`stripHidden`), swapped for an
  empty box so the preview's subtree, and its CEF webview, is not rebuilt.
  The shortcuts stay live.
- **Verified** with a spike on the dev laptop: exact aspect at enter, the
  scale carried over a flip, corner sizing held to the aspect down to the
  minimum width, and the exact rectangle and style back on exit. **Still to
  see** in the VM, against a real preview: how the opaque margin looks.

### Phase 8 — Packaging, signing, updates, release tooling (L)

Per D4. The installer is needed for the first public v1 build. WinSparkle can
follow it (D1). Until then the runner's `updates` channel answers only
`getState`, with the version and `configured: false`, so Check for Updates
is greyed out (Phase 5).

- **Installer:** Inno Setup per-user install to
  `%LOCALAPPDATA%\Programs\App Studio` (no admin), Start-menu shortcut with
  AppUserModelID (needed for toasts), uninstaller entry. Alternative: MSIX
  (clean updates, but sandbox/virtualised `%APPDATA%` and file-system
  redirection interfere with editing `HKCU\Environment`, spawning
  user-installed toolchains and writing into `%USERPROFILE%\develop`).
- **Visual C++ runtime:** a clean Windows does not have the
  `msvcp140`/`vcruntime140` DLLs Flutter and CEF need. Ship them next to
  `appstudio.exe` (app-local, from VS's `Microsoft.VC143.CRT`, as the VM test
  package does) so the per-user install needs no administrator.
- Release builds leave out plugins that only dev dependencies bring
  (`url_launcher` via Widgetbook), so building one rewrites
  `windows/flutter/generated_plugin*` — restore them rather than commit that.
- **Signing:** Authenticode for the exe, CEF DLLs, `WinSparkle.dll` and the
  installer (Azure Trusted Signing or an OV/EV cert). Unsigned builds hit
  SmartScreen on every download.
- **Separate from the macOS pipeline (D5).** Nothing in the Windows release
  path reads or writes anything the macOS one owns:
  - **Scripts:** `tool/windows/*.ps1` with their own entry point.
    `Makefile`, `tool/*.sh` and `tool/lib/` are not touched, and the
    Windows scripts do not source them.
  - **Storage:** its own GCS bucket (name to be decided), or failing that,
    a `windows/` root that the macOS scripts never list. The candidate
    layout is:
    - `appcast/windows/appcast.xml`
    - `downloads/windows.json`
    - `releases/windows/<v>/b<n>/AppStudio-<v>-x64-setup.exe` plus a
      `.sha256` sidecar
    - immutable objects uploaded with `--if-generation-match=0`, the same
      discipline as macOS
  - **Build numbers:**
    - Windows keeps its own monotonic counter, independent of
      `CFBundleVersion` and the macOS appcast.
    - It is stored in `windows/release.json` and passed to
      `flutter build windows --build-name <v> --build-number <n>`.
    - `pubspec.yaml`'s `version:` stays owned by `make set_version`, and
      the Windows scripts never write it.
    - The Windows gate reads only the Windows appcast and pointer.
  - **Signing keys:** a separate WinSparkle EdDSA key pair, never the
    Sparkle key, and a separate Authenticode credential. Losing or rotating
    one cannot affect the other platform.
  - **Runs:** locally on a Windows machine, or later on a GitHub Actions
    `windows-latest` runner holding the signing secret.
- **Updates:** WinSparkle (an EdDSA-signed appcast, the same model as
  Sparkle) reading `appcast/windows/appcast.xml`.
- **Merging later.** Folding the two pipelines together (one counter, one
  `release` command) is possible once Windows is stable. It is a separate
  decision, and nothing in this phase may assume it.

#### As built (2026-10-17)

- **Runner:**
  - Product metadata: Serverpod, "App Studio".
  - The App Studio icon, built from the macOS PNGs by
    `tool/windows/make_icon.dart` (PNG entries in an `.ico`).
  - One instance at a time: the `Serverpod.AppStudio.Running` mutex; a
    second launch brings the first window forward.
  - AppUserModelID `Serverpod.AppStudio`.
- **Visual C++ runtime:** release builds install it beside the exe through
  CMake's `InstallRequiredSystemLibraries` (Profile/Release only).
- **WinSparkle 0.9.4:**
  - Downloaded and checked against GitHub's digest in
    `windows/runner/CMakeLists.txt`.
  - `winsparkle_updater.cpp` answers the same `updates` methods as
    `SparkleUpdater.swift`. Its shutdown request posts to the window, which
    calls Dart's `prepareForRelaunch` (the teardown, then the AF_UNIX
    settle), with a 20 s fallback before `DestroyWindow`.
  - Configured only in release builds whose `windows/release.json` names
    `appcastUrl` and `eddsaPublicKey`.
  - **Differences from macOS:** WinSparkle cannot veto a scheduled check
    while a session is busy (`setSessionBusy` is accepted and kept), and
    there is no translocation.
- **Toasts:** `toast_notifications.cpp` (C++/WinRT, `windowsapp.lib`),
  skipped while App Studio is in the foreground unless forced.
  `StudioNotifications` now posts on Windows too.
- **Installer:** `windows/installer/app_studio.iss`, a per-user install into
  `%LOCALAPPDATA%\Programs\App Studio` for Windows 10 1809+ x64.
  - `AppMutex` and `CloseApplications`, and a Start menu entry with the
    AUMID.
  - A silent install (an update) relaunches the app.
  - It never removes user data; Help → Uninstall App Studio does.
  - Optional Authenticode through `/DSignTool`.
- **Release scripts** (`tool/windows/`, PowerShell 5.1):
  - `build_release.ps1`: version from pubspec, build from `release.json`
    (`-BumpBuild`); checks the bundle, signs optionally, then ISCC and a
    `.sha256` sidecar into `dist\windows`.
  - `publish_release.ps1`: the immutable upload, as a preview.
  - `promote_release.ps1`: verifies the uploaded installer against its
    sidecar, signs it with `winsparkle-tool`, and puts it at the top of
    `appcast/windows/appcast.xml`.
  - `publish_downloads.ps1`: `downloads/windows.json`, latest and preview.
  - Every script takes `-Bucket` (still to be chosen, Q7), `-PublicBaseUrl`
    and `-DryRun`. Only the dry-run paths have been exercised.
- **Uninstall:** removes the preferences folder too:
  `%APPDATA%\Serverpod\App Studio`, named from `Runner.rc`.
- **CI:** builds the release and the installer on `windows-latest` (the
  `windows installer` job).
- **Q8 resolved:** the executable stays `appstudio.exe`, shown as "App
  Studio" through its version resource. New projects default to the home
  folder, as on macOS.
- **Still needs a person:**
  - a code-signing credential (Q5);
  - the release bucket (Q7);
  - generating and storing the WinSparkle key pair;
  - a first real install and update in the VM.

### Phase 9 — Docs (S, continuous)

- `AGENTS.md`: a "Windows" section mirroring the macOS sections that differ
  (paths, toolchain, PATH, runner sockets, CEF, menus, release).
- `README.md`: Windows dev prerequisites (section 9 of this spec), and how
  to run.
- `pubspec.yaml` description: drop "macOS".

---

#### As built (2026-10-17)

`AGENTS.md` has a Windows section: dev machine, the afunix rules, the platform
seam, paths, toolchain, window, CEF and keys, releases, CI. The README covers
running, testing and releasing on Windows. The `pubspec.yaml` description no
longer says macOS only.

## 6. Testing & CI

- **Make the suite host-agnostic first** (in Phase 1): tests that need POSIX
  tools get `@TestOn('mac-os || linux')`; path expectations use `p.join`
  or explicit `FakeHost` paths; `FakeRunner` binds under
  `Directory.systemTemp` with a short relative socket path.
- **Windows-specific unit tests** run on the macOS host via `FakeHost`
  (PATH parsing, env building, executable names, registry PATH writer
  against a fake registry, editor strategy, menu commands).
- **Windows-host tests** (`@TestOn('windows')`): `ProcessKiller` against a
  real child tree, `.bat` launching with awkward paths, AF_UNIX `FakeRunner`.
- **CI matrix, from Phase 1:** `macos-latest` (existing behaviour, the
  "macOS unchanged" gate) + `windows-latest`, each running `flutter analyze`
  and the whole `flutter test` suite, `process` tests included —
  `.github/workflows/ci.yml`. `flutter build windows` joins once Phase 2
  makes the Windows build part of the product.
- **Where tests run:** pure logic everywhere; `process`-tagged tests (real
  child processes, AF_UNIX fake runners) in CI and the clean-room VM only,
  never on the Windows dev laptop (afunix risk, section 7).
- **macOS smoke checklist** for any PR touching shared code: launch from
  Finder, first-run setup screen state, open a project, attach to a runner
  started in a terminal, Hot/Full Restart, preview reload, Open in Cursor/VS
  Code, Settings → Tools, menus + shortcuts, quit (no orphans), compact
  window, Check for Updates greyed in debug.
- **Windows smoke checklist** (same list, Windows equivalents) from Phase 4
  on.
- **As run (2026-10-17):** `.github/workflows/ci.yml` has four jobs.
  - **macOS:** the full suite.
  - **Windows:** every test not tagged `process` (`-x process -j 1`), plus
    an annotation naming the image's afunix.sys.
  - **`windows sockets (canary)`:** the AF_UNIX tests, one step per file or
    group. It is allowed to fail.
  - **`windows installer`:** the release build and the installer.
- **The canary keeps taking GitHub's Windows machine down.** Every full
  Windows run so far ended with the step limit never firing and the job
  running out its time, which a hang inside a test cannot do.
  - It happens in plain in-process socket tests: `runner_discovery_test`
    has both passed and crashed with the same code.
  - Letting Windows finish closing sockets before the test process ends
    (`afunix_guard.dart`, 1 s) did not make it go away.
  - So the afunix risk is not limited to the dev laptop's build, and it is
    not limited to killed processes.
- Widgetbook runs on Windows too (`flutter run -d windows -t
  widgetbook/main.dart`) once Phase 2 lands.

---

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| **Windows `afunix.sys` bug (0xD1 bugcheck)**: a process exiting while holding an AF_UNIX socket can blue-screen Windows (afunix.sys 10.0.26100.8972, still present on 26300.9711). Seen 3× on the dev laptop with test processes; App Studio, the runner and CLI clients all hold AF_UNIX connections | OS crash for users, not just the app | Reported (`specs/windows_afunix_bsod_report.md`). Close runner connections gracefully before any exit, then wait 500 ms (`settleAfUnixSockets`); never kill a process that holds one; process tests in CI/VM only; re-check each Windows CU. **CI (2026-10-17):** GitHub's Windows machines go down intermittently in plain in-process socket tests, settle or not, so treat it as reachable by users: the VM's end-to-end pass is the evidence that decides whether Windows can ship on Serverpod's AF_UNIX transport as it is |
| Developer Mode can't be enabled (non-admin account, Group Policy on managed PCs) | Setup blocks; deep projects can't attach | Guidance + Check again (4.8). Projects with short paths still work, so the blocking rule can be relaxed later if that proves too strict |
| Database for Serverpod dev on Windows needs Docker Desktop (WSL2, admin, licence) | Biggest first-run friction | Phase 0.2 decides; possibly a setup check + guidance rather than an install |
| `.bat` argument injection / quoting | Broken starts, security | `ProcessLauncher` with strict quoting; tests with hostile names |
| CEF on Windows untested in this fork (W1–W7) | Crashes on quit, double keys, leaks | Phase 0.4 + Phase 2 fixes; orphan check |
| Defender / indexing lock freshly extracted files | Flaky Flutter install/rename | Retry with backoff; extract to staging then rename |
| MAX_PATH (260) in pub cache / Flutter / Git | Odd build failures | Detect `LongPathsEnabled`; `core.longpaths` |
| Windows Firewall prompt when the dev server/runner binds | User confusion on first start | Document; bind loopback where the CLI allows |
| Shared `common/` CEF edits regress macOS | macOS breakage | `OS_` guards; macOS rebuild + smoke before merge |
| SmartScreen on unsigned builds | Users can't install | Sign from the first public build |
| Windows on ARM | CEF build is x64-only | x64 only for v1 (runs under emulation); Q6 |

---

## 8. Open questions

Questions 1–4 (scope, CLI changes, Git, packaging) and the release split
are answered. See Decisions D1–D5 at the top.

5. **Code signing.** Is there a Windows code-signing route available
   (Azure Trusted Signing account or a certificate for Serverpod AB)?
6. **Architectures.** x64 only for v1, with Windows on ARM later?
7. **Windows release storage.** A new GCS bucket (and CDN host) for
   Windows, or a `windows/` root in the existing bucket? D5 prefers a new
   bucket. The dev-loop tooling is PowerShell scripts under `tool/windows/`
   either way, and the Makefile stays macOS-only.
8. **Defaults.** Executable/product name (`App Studio.exe` with a space, or
   `AppStudio.exe`), app data location (`%APPDATA%\App Studio`), and default
   new-project folder on Windows (`%USERPROFILE%\Projects`?).
9. ~~**Database.**~~ Closed by Phase 0: the CLI runs its own bundled
   Postgres on Windows, so there is no Docker to detect or install.

---

## 9. Developer machine setup (Windows)

What a Windows machine needs to build and run App Studio from this repo.
State of the first dev machine (2026-10-16) is in the last column.

### Required

| What | Why | How | First machine |
|---|---|---|---|
| Visual Studio 2022 with **Desktop development with C++** (MSVC v143, Windows 11 SDK, C++ CMake tools) | `flutter build windows`; builds the CEF wrapper. VS's bundled CMake is the one Flutter uses, so no separate CMake is needed. | `winget install --id Microsoft.VisualStudio.2022.Community -e --override "--add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended --passive --wait"`, then check with `flutter doctor` | Installed (VS Community 2022 17.14) |
| **Developer Mode** | Flutter refuses Windows builds with plugins without symlink support. App Studio also requires it at runtime (D2). | Settings → System → For developers → Developer Mode (`start ms-settings:developers`) | On |
| **Git for Windows** | Flutter needs it. The `git` on `PATH` now is a private copy inside the Codex app's runtime. | `winget install --id Git.Git -e` | Installed (`C:\Program Files\Git`) |
| **Long paths** | The CEF tree, the pub cache and the build output get deep. | Admin PowerShell: set `HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled` = 1; then `git config --global core.longpaths true` | On |
| Flutter ≥ 3.44 (stable) | Host SDK for building App Studio | Any stable SDK on `PATH`. Prefer `C:\src\flutter` (Flutter's documented spot) over `%USERPROFILE%\develop\flutter`, which is where App Studio installs its own and refuses to overwrite. | Official 3.47.7 stable at `%USERPROFILE%\develop\flutter` (Flutter's documented location), on the user `Path`. App Studio therefore sees it as the user's own Flutter. The Codex-managed copy has been removed from `Path`. |
| ~2 GB free + network on first build | The CEF 149 download (`third/download.cmake`) runs during the first CMake configure | — | 857 GB free |

### For the Phase 0 spikes

| What | Why | First machine |
|---|---|---|
| Serverpod CLI in range (`>=4.1.0-beta.1 <4.2.0`) | Runner end-to-end test | 4.1.0-beta.3 at `%LOCALAPPDATA%\Dart\install\bin\serverpod.bat` |
| Docker Desktop (WSL2 backend) | **Only if** spike 0.2 shows the project template needs it for Postgres | WSL present, Docker not installed. Wait for the spike. |
| VS Code and/or Cursor | Exercising Open in … | — |

### Not needed yet

`make` (the Makefile stays macOS-only, D5), Chrome, the Android toolchain,
`gcloud`, Inno Setup, WinSparkle and signing credentials (all Phase 8).

### Clean-room testing

A dev machine already has Git, Flutter, the CLI, Developer Mode and long
paths, so it never takes the first-run paths. The first dev machine runs
Windows 11 **Home**: it has no Windows Sandbox and no Hyper-V Manager, but
its hypervisor is already on through WSL2. It has 31 GB of RAM.

1. **Main clean room: a VMware Workstation Pro VM.** VMware is free for
   any use, runs on Home alongside WSL2, and its 3D acceleration is better
   than VirtualBox's, which matters for the CEF GPU texture path.
   - **Guest:** the Windows 11 Enterprise 90-day evaluation from
     Microsoft's Evaluation Center, with a virtual TPM. Give it 8 GB of
     RAM, 4 vCPUs and 100 GB of disk.
   - **Snapshots,** reverting to one before every run:
     - `pristine`: no Git, no Flutter, Developer Mode off, long paths off.
       The test user is an admin.
     - `pristine-standard-user`: the same, but the test user is a standard
       (non-admin) account. This exercises the Developer Mode guidance
       fallback (4.8).
     - `user-flutter`: an existing user-installed Flutter in a custom folder
       on `PATH`. This exercises the "Native" tool and the manual-update
       prompt.
   - **The test user's name has a space and non-ASCII letters,** e.g.
     `Åsa Öberg`. That puts both into `%USERPROFILE%`, which is how
     path-quoting and `.bat`-argument bugs (B10) show up.
2. **Fast inner loop: a second local user account on the dev machine.** It
   gets a fresh `%USERPROFILE%` and `HKCU` in seconds, so it covers the
   per-user installs of Flutter and the Serverpod CLI, `PATH` writing and
   uninstall. It cannot cover machine-wide state: Developer Mode, long
   paths, or a Git in Program Files.
3. **CI and release checks:**
   - a `windows-latest` GitHub Actions runner for builds and tests;
   - a real second machine for SmartScreen, GPU and installer checks
     before public releases.

On Windows 11 Pro, Windows Sandbox would be the quickest throwaway smoke
test, and Hyper-V could replace VMware.
