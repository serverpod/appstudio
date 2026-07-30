# App Studio — agent notes

macOS Flutter IDE for **Serverpod 4** projects: open a project, run `serverpod start` in an embedded terminal, preview the Flutter web app in CEF at `http://localhost:9998`.

## Project layout

```
lib/
  main.dart              # ShadApp, wires controllers
  agent/                 # OpenCode serve client, SSE, AgentController, transcript
  ui/                    # studio_shell, preview_pane, terminal_pane, agent/, settings/
  preview/               # CEF preview: device modes, theme shim, surface sync
  process/               # ServerpodProcessController (start/stop/reload), ProjectCreator
  session/               # ProjectSession (open project, recents)
  terminal/              # xterm wrapper
  theme/                 # Shad themes, layout constants, ThemeController
  toolchain/             # Bundled vs host flutter/dart/serverpod/opencode
  widgets/               # Shared UI (IconSegmentedControl, MenuItemTile)
packages/
  mac_menu_bar/            # Local fork — SF Symbol icons + menu separators
  webview_cef/             # Local fork — CEF resize + skip Helper (Alerts)
tool/
  bundle_toolchain.sh, distribute_macos.sh
toolchain/               # Release bundle (see README)
```

UI reference for design patterns: `../cloudui/cloudui_flutter/`.

## Agent (OpenCode)

- Agent tab hosts a Cursor-style chat driven by bundled `opencode serve` (HTTP + SSE).
- Scoped to the open project directory; restart serve on project switch.
- API keys via Settings → Providers → OpenCode `auth.json` / `PUT /auth/{id}`.
- Bundle: `toolchain/opencode/<ver>/` (darwin-arm64 only); pin in `active.json`.
- **Permissions:** `permission.asked` → reply with `POST /permission/{id}/reply`
  `{"reply": "once"|"always"|"reject"}`. Any other value is a 400 and the agent
  stays blocked forever, so never swallow the error — keep the card up.
- **Questions:** `question.asked` → `POST /question/{id}/reply` with
  `{"answers": [[label, …], …]}` (one list per question) or
  `POST /question/{id}/reject`. Both events carry `tool.{messageID,callID}`;
  the card is attached next to that tool part and the raw row is hidden.
- Ground truth for events/endpoints is the running server: `curl <base>/doc`.

## Setup & toolchain

### Prerequisites (dev machine)

- **Flutter 3.44+** / **Dart 3.12+** (host SDK for building App Studio itself)
- **Serverpod CLI 4.0.0-beta.1** — `dart install serverpod_cli 4.0.0-beta.1` (used when no bundled toolchain)
- **CEF / webview_cef:** `brew install cmake ninja`; then `cd macos && pod install`  
  (CEF binaries download into `packages/webview_cef/macos/third/cef/` — gitignored)

### First-time / day-to-day (Makefile)

```bash
make build_toolchain   # pub get + CEF/pods + toolchain/ (once, or when incomplete)
make start             # ensure toolchain, then flutter run -d macos
make dist_debug        # unsigned DMG
make dist              # Developer ID + notarized DMG
```

`start` / `dist` / `dist_debug` call `ensure_toolchain` first and run `build_toolchain` if pins, git, cctools, or CEF are missing.

### Bundled runtime (shipped in release builds)

App Studio embeds a **web-focused Flutter SDK**, a **full Serverpod CLI bundle**, and **OpenCode** so opened projects run without host tools installed. Source of truth: `toolchain/`.

```
toolchain/
  active.json                          # pins versions (flutter, serverpod_cli, opencode, git)
  flutter/<version>/                   # stripped macOS + web engine only
  serverpod_cli/<version>/{bin,lib}/   # full CLI bundle — lib/ has sqlite dylibs (required)
  opencode/<version>/opencode          # darwin-arm64 CLI binary
  git/<version>/{bin,libexec}/         # portable Git (dugite-native) — avoids Xcode CLT stub
  cctools/{bin,lib}/                   # real otool + install_name_tool (no CLT stubs)
  bin/{flutter,dart,serverpod,opencode,git}
```

- **`./tool/bundle_toolchain.sh`** — downloads Flutter, runs `flutter precache --web`, strips iOS/Android/other engine artifacts; downloads OpenCode + portable Git; copies real `otool` / `install_name_tool` from Xcode into `cctools/`. Does **not** download Serverpod; copy the full CLI bundle into `toolchain/serverpod_cli/<version>/` first. Flags: `--force`, `--flutter=VERSION`, `--serverpod=VERSION`, `--opencode=VERSION`, `--git=VERSION`.
- **`Toolchain.resolve()`** (`lib/toolchain/toolchain.dart`) — uses bundled toolchain if `active.json` exists (repo `toolchain/` in dev, `AppStudio.app/Contents/Resources/toolchain` in release), otherwise falls back to host `PATH`. Prepends portable `git` + `cctools` to `PATH` and sets `FLUTTER_PREBUILT_ENGINE_VERSION` so target Macs don't need Xcode / CLT for web preview.
- **Debug builds** skip embedding (`tool/embed_toolchain.sh`) and use host `flutter`/`dart`/`serverpod`. **Release** embeds the full `toolchain/` tree into the `.app`.

Opened Serverpod projects must launch Flutter in **`web-server`** mode on port **9998** (Serverpod `flutter_apps` config).

### Release / distribute

```bash
./tool/bundle_toolchain.sh
./tool/distribute_macos.sh              # Developer ID sign (Serverpod AB)
NOTARIZE=1 ./tool/distribute_macos.sh   # + notarize via notarytool profile "appstudio"
```

Defaults: bundle id `dev.serverpod.appstudio`,  
`SIGN_IDENTITY="Developer ID Application: Serverpod AB (WK2NRY4GS4)"`,  
`NOTARY_PROFILE=appstudio`. Produces a DMG under `dist/macos/`.

## UI & design

- **Component library:** `shadcn_ui` (`ShadApp`, `ShadTheme`, `LucideIcons`). No Material-heavy custom widgets unless necessary.
- **Palette:** Serverpod brand blue (`kBrandBlue` in `app_theme.dart`), `ShadSlateColorScheme`. Semantic status colors in `app_colors.dart`.
- **Fonts:** `.AppleSystemUIFont` (UI), `Menlo` (terminal via `kMacMonoFont`).
- **Dark mode fix:** override `border` and `input` in `darkColorScheme` — default slate dark sets `border == muted`, which hides dividers.
- **Layout constants** (`app_theme.dart`): `kPaneHeaderHeight` (36), `kDividerWidth` (1), `paneBorderSide()`, `kSplitHandleWidth` (6).
- **Pane chrome:** headers use `scheme.muted`; content uses `scheme.background`. Use `paneBorderSide()` for all 1px dividers.
- **Segmented controls:** `IconSegmentedControl` — copied from cloudui account theme toggle. Use `onMutedSurface: true` on muted pane headers (inverts track/selection for contrast).
- **Terminal tabs:** VS Code–style; selected tab overlaps bottom border via `Transform.translate`, not negative margin.
- **Split resize:** panes meet with no gap. Draw a full-height 1px `ColoredBox` in a `Stack` on the split line; overlay a transparent drag handle (`kSplitHandleWidth`). Do not use a separate wide column or `DecoratedBox` border behind opaque pane content — it won't show.

## Preview panel

- **Shell theme ≠ preview theme.** Preview light/dark toggles a JS shim (`preview_theme.dart`) that fakes `prefers-color-scheme` inside CEF.
- **View modes:** `PreviewViewMode` — portrait phone (default), landscape phone, desktop. Defined in `preview_device.dart`.
- **CEF sizing:** `PreviewSurfaceSync` + `burstSyncPreviewSurface` keep the webview sized on panel/mode changes. Defer layout reads to post-frame callbacks; avoid `MediaQuery` in `initState`.
- **webview_cef:** path dependency `packages/webview_cef` (fork of 0.5.1). Includes CEF resize surface sync and skips embedding `Helper (Alerts)`. CEF itself is fetched by `pod install` into `macos/third/cef/` (gitignored).
- **Keyboard into CEF (macOS):** a local `NSEvent` monitor (`CefWrapper.processKeyboardEvent`) routes keys. It only forwards to `current_focused_browser_`, which is set from `setClientFocus` — never let it consume an event it can't deliver, or the webview looks dead.
- **Clipboard:** off-screen browsers are not in the responder chain, so Chromium never turns ⌘X/C/V/A/Z into editing commands. They are translated to `CefFrame::Cut/Copy/Paste/…` (`WebviewHandler::sendEditCommand`). Every other ⌘ chord is left uncaptured so the app's menu bar wins.
- **IME:** while a web input is focused, text keys go to the OS input method and come back as `imeCommitText`/`imeSetComposition`; only navigation/control keys are sent raw. Don't reattach the text input client while it is already active — that kills a live composition.

## Architecture notes

- Long-lived controllers created in `main.dart`: `ThemeController`, `ProjectSession`, `StudioTerminal`, `ServerpodProcessController`.
- `ServerpodProcessController` owns process lifecycle and signals when preview is ready to load.
- The menu bar lives above `ShadApp`, so menu-triggered dialogs use the `navigatorKey` context from `main.dart`.

## New projects

- **New Project** (start page + File menu) opens `ui/new_project_dialog.dart`: project name + location, then `ProjectCreator` (`process/project_creator.dart`) runs the bundled `serverpod create <name> --ide opencode --no-interactive` in that location.
- Names must match `^[a-z][a-z0-9_]*$` (they become Dart package names); the input folds case and drops separators as you type.
- After the CLI succeeds, `patchFlutterAppForPreview` adds `device: web-server` and `web-port: 9998` to the `flutter_apps` entry in `<name>_server/pubspec.yaml` — without it `serverpod start` opens a browser instead of feeding the preview pane. The project is then opened, which auto-starts it.
- Last used location is remembered in `ProjectSession` (`new_project_directory` pref).

## Conventions for agents

- Keep diffs small; match existing naming and file placement.
- Reuse `shadcn_ui` components and cloudui patterns before inventing new ones.
- Only commit or open PRs when explicitly asked.
