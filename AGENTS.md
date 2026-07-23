# App Studio — agent notes

macOS Flutter IDE for **Serverpod 4** projects: open a project, run `serverpod start` in an embedded terminal, preview the Flutter web app in CEF at `http://localhost:9998`.

## Project layout

```
lib/
  main.dart              # ShadApp, wires controllers
  agent/                 # OpenCode serve client, SSE, AgentController, transcript
  ui/                    # studio_shell, preview_pane, terminal_pane, agent/, settings/
  preview/               # CEF preview: device modes, theme shim, surface sync
  process/               # ServerpodProcessController (start/stop/reload)
  session/               # ProjectSession (open project, recents)
  terminal/              # xterm wrapper
  theme/                 # Shad themes, layout constants, ThemeController
  toolchain/             # Bundled vs host flutter/dart/serverpod/opencode
  widgets/               # Shared UI (IconSegmentedControl, MenuItemTile)
packages/
  mac_menu_bar/            # Local fork — SF Symbol icons + menu separators
tool/
  apply_webview_cef_patch.sh   # Run after flutter pub get
  webview_cef_patches/         # CEF resize fix for webview_cef
  bundle_toolchain.sh, distribute_macos.sh
toolchain/               # Release bundle (see README)
```

UI reference for design patterns: `../cloudui/cloudui_flutter/`.

## Agent (OpenCode)

- Agent tab hosts a Cursor-style chat driven by bundled `opencode serve` (HTTP + SSE).
- Scoped to the open project directory; restart serve on project switch.
- API keys via Settings → Providers → OpenCode `auth.json` / `PUT /auth/{id}`.
- Bundle: `toolchain/opencode/<ver>/` (darwin-arm64 only); pin in `active.json`.

## Setup & toolchain

### Prerequisites (dev machine)

- **Flutter 3.44+** / **Dart 3.12+** (host SDK for building App Studio itself)
- **Serverpod CLI 4.0.0-beta.0** — `dart install serverpod_cli 4.0.0-beta.0` (used when no bundled toolchain)
- **CEF / webview_cef:** `brew install cmake ninja`; then `cd macos && pod install`

### First-time dev setup

```bash
flutter pub get
./tool/apply_webview_cef_patch.sh   # required after pub get — patches webview_cef resize
cd macos && pod install && cd ..
flutter run -d macos
```

### Bundled runtime (shipped in release builds)

App Studio embeds a **web-focused Flutter SDK**, a **full Serverpod CLI bundle**, and **OpenCode** so opened projects run without host tools installed. Source of truth: `toolchain/`.

```
toolchain/
  active.json                          # pins versions (flutter, serverpod_cli, opencode)
  flutter/<version>/                   # stripped macOS + web engine only
  serverpod_cli/<version>/{bin,lib}/   # full CLI bundle — lib/ has sqlite dylibs (required)
  opencode/<version>/opencode          # darwin-arm64 CLI binary
  bin/{flutter,dart,serverpod,opencode}
```
  flutter/<version>/                   # stripped macOS + web engine only
  serverpod_cli/<version>/{bin,lib}/   # full CLI bundle — lib/ has sqlite dylibs (required)
  bin/{flutter,dart,serverpod}         # wrappers read active.json
```

- **`./tool/bundle_toolchain.sh`** — downloads Flutter, runs `flutter precache --web`, strips iOS/Android/other engine artifacts. Does **not** download Serverpod; copy the full CLI bundle into `toolchain/serverpod_cli/<version>/` first. Flags: `--force`, `--flutter=VERSION`, `--serverpod=VERSION`.
- **`Toolchain.resolve()`** (`lib/toolchain/toolchain.dart`) — uses bundled toolchain if `active.json` exists (repo `toolchain/` in dev, `AppStudio.app/Contents/Resources/toolchain` in release), otherwise falls back to host `PATH`.
- **Debug builds** skip embedding (`tool/embed_toolchain.sh`) and use host `flutter`/`dart`/`serverpod`. **Release** embeds the full `toolchain/` tree into the `.app`.

Opened Serverpod projects must launch Flutter in **`web-server`** mode on port **9998** (Serverpod `flutter_apps` config).

### Release / distribute

```bash
./tool/bundle_toolchain.sh
SIGN_IDENTITY="Developer ID Application: …" ./tool/distribute_macos.sh
# optional notarization:
SIGN_IDENTITY="…" NOTARY_PROFILE="…" NOTARIZE=1 ./tool/distribute_macos.sh
```

Produces a signed DMG under `dist/macos/`.

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
- **webview_cef patch:** run `./tool/apply_webview_cef_patch.sh` after `flutter pub get` — needed for reliable resize.

## Architecture notes

- Long-lived controllers created in `main.dart`: `ThemeController`, `ProjectSession`, `StudioTerminal`, `ServerpodProcessController`.
- `ServerpodProcessController` owns process lifecycle and signals when preview is ready to load.

## Conventions for agents

- Keep diffs small; match existing naming and file placement.
- Reuse `shadcn_ui` components and cloudui patterns before inventing new ones.
- Only commit or open PRs when explicitly asked.
