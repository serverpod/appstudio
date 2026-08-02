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
make deps              # pub get + CEF/pods (once, or when CEF is missing)
make start             # flutter run -d macos
make clean             # drop build/ + dist/ (keeps CEF, Pods, toolchain/)
make clean_all         # also drop CEF, Pods and the dev toolchain
make dist_debug        # unsigned DMG
make dist              # Developer ID + notarized DMG
```

`start` / `dist` / `dist_debug` only need CEF; the app downloads its own tools.

**Stale-embed trap:** Xcode never deletes unknown files under `Contents/Resources`, so a build tree from before the toolchain moved out keeps a ~1.8 GB embed alive — it gets re-signed on every release and shipped in the DMG (2.1 GB app / 1.06 GB DMG instead of 350 MB / 158 MB). `distribute_macos.sh` deletes it defensively; `make clean` is the honest fix.

### Tool resolution (in the app)

- `ToolchainController` (`lib/toolchain/toolchain_controller.dart`) owns the resolved `Toolchain`. **Consumers read `toolchains.current` at call time — never capture it**, or they strand on a snapshot taken before the user installed anything.
- Resolution is **per tool** across four sources, in precedence order: dev repo (`<repo>/toolchain`) → bundled (`Contents/Resources/toolchain`) → managed (`~/Library/Application Support/AppStudio/toolchain`) → host. A missing OpenCode no longer invalidates Flutter.
- Executable getters are **nullable**. Spawn sites check `toolchain.unavailableReason(id)` first; a bare command name would only defer the failure to `Process.start`.
- `Toolchain.resolve()` short-circuits at the first satisfied candidate (~350 ms). `deep: true` enumerates every candidate (~900 ms) and is only for the Tools Manager — the full sweep is too slow to run before `runApp`.
- **Never probe `/usr/bin/{git,otool,install_name_tool,clang,ar,ld}`** — all confirmed CLT shims (identical 118,928-byte stub) that pop a modal installer. `codesign` at /usr/bin *is* real. Candidates come from Homebrew, `/Library/Developer/CommandLineTools`, and `$(xcode-select -p)`.
- Flutter is version-detected from `bin/cache/flutter.version.json`, never by running `flutter --version` — that can trigger a precache download on a cold SDK.
- `PUB_CACHE` is deliberately **not** set: `package_config.json` stores absolute paths, so a private cache would make every switch to an external editor re-resolve the project.
- Version rules live in `tool_version.dart`. A numeric-only suffix is a *packaging revision*, not a prerelease — dugite's `2.53.0-3` is newer than `2.53.0`, while `4.0.0-beta.1` is older than `4.0.0`.

### Publishing tools (release engineer)

```bash
./tool/bundle_toolchain.sh                    # build the trees (unchanged)
./tool/publish_toolchain.sh --dry-run         # sizes, no upload
./tool/publish_toolchain.sh --only=git        # publish a subset
./tool/publish_toolchain.sh                   # publish everything
```

- Bucket `gs://serverpod-appstudio-toolchain`, served from
  `https://storage.googleapis.com/serverpod-appstudio-toolchain/`. Public read; publisher has
  **`objectCreator`, not `objectAdmin`** — it can add objects but never overwrite or delete
  one, so immutability is enforced by IAM. **A mistaken publish cannot be undone with the
  publisher role: always `--dry-run` first.**
- Object names embed the build counter as a path segment
  (`tools/<id>/<version>/b<build>/<id>-macos-arm64.tar.gz`), so repacking the same upstream
  version is a new URL. There is no mutable `latest.json`.
- The script hashes the **exact bytes uploaded**, re-downloads to re-verify, then rewrites
  `assets/toolchain_manifest.json`. Commit that file with the release.
- Do **not** put a service-account key in a `.env`. Write access here is effectively
  code-signing authority over every install. Use `--impersonate-service-account` (no key
  exists) or Workload Identity Federation in CI.

### Native tools: what we can and cannot ship

Serverpod's per-start native-assets step runs exactly three commands on prebuilt dylibs:
`otool -D`, `install_name_tool -id/-change`, then `codesign --force --sign -`.

- `/usr/bin/{otool,install_name_tool,clang,ar,ld,lipo,strip}` are **all the same 118,928-byte
  Xcode CLT shim** and pop a modal installer on a clean Mac. Never execute them.
- `/usr/bin/codesign` (459,824 bytes) **is** a real base-system binary — nothing to ship.
- We ship LLVM's `llvm-objdump`/`llvm-objcopy` under the names `otool`/`install_name_tool`
  (they dispatch on `argv[0]`). Verified: `otool -D` output is byte-identical to Apple's, and
  `install_name_tool` self-reports as "compatible with cctools install_name_tool".
  `llvm-install-name-tool` does not re-sign after editing a Mach-O — which is fine, because
  Serverpod runs `codesign` on the very next line.
- **Compiling** native code from source is different: `native_toolchain_c` needs `clang`, `ar`
  and `xcrun --show-sdk-path`, and **the macOS SDK cannot be redistributed**. That path
  requires Xcode CLT; detect it and offer `xcode-select --install`.

### Dev toolchain (optional, `<repo>/toolchain`)

`make dev_toolchain` builds a local tree that the app prefers over anything it would download —
useful offline. It is **not** required to build, run or ship the app: the toolchain is no
longer embedded in the `.app`, and the DMG carries none of it.

```
toolchain/
  active.json                          # pins versions (flutter, serverpod_cli, opencode, git)
  flutter/<version>/                   # stripped macOS + web engine only
  serverpod_cli/<version>/{bin,lib}/   # full CLI bundle — lib/ has sqlite dylibs (required)
  opencode/<version>/opencode          # darwin-arm64 CLI binary
  git/<version>/{bin,libexec}/         # portable Git (dugite-native) — avoids Xcode CLT stub
  llvm-tools/<version>/bin/            # otool + install_name_tool from LLVM (no CLT stubs)
  bin/{flutter,dart,serverpod,opencode,git}
```

- **`./tool/bundle_toolchain.sh`** — downloads Flutter, runs `flutter precache --web`, strips iOS/Android/other engine artifacts; downloads OpenCode + portable Git; downloads an official LLVM release and installs `llvm-objdump`/`llvm-objcopy` as `otool`/`install_name_tool`. Does **not** download Serverpod; copy the full CLI bundle into `toolchain/serverpod_cli/<version>/` first. Flags: `--force`, `--flutter=VERSION`, `--serverpod=VERSION`, `--opencode=VERSION`, `--git=VERSION`.
- **`Toolchain.resolve()`** (`lib/toolchain/toolchain.dart`) — uses bundled toolchain if `active.json` exists (repo `toolchain/` in dev, `AppStudio.app/Contents/Resources/toolchain` in release), otherwise falls back to host `PATH`. Prepends portable `git` + `cctools` to `PATH` and sets `FLUTTER_PREBUILT_ENGINE_VERSION` so target Macs don't need Xcode / CLT for web preview.
- **Debug builds** skip embedding (`tool/embed_toolchain.sh`) and use host `flutter`/`dart`/`serverpod`. **Release** embeds the full `toolchain/` tree into the `.app`.

Opened Serverpod projects must launch Flutter in **`web-server`** mode on port **9998** (Serverpod `flutter_apps` config).

### Release / distribute

```bash
make dist                 # build + sign + notarize + PUBLISH to the bucket
PUBLISH=0 make dist       # stop at the local DMG
make publish_dist         # upload an already-built DMG
make dist_debug           # unsigned, local only, never uploaded
```

Defaults: bundle id `dev.serverpod.appstudio`,
`SIGN_IDENTITY="Developer ID Application: Serverpod AB (WK2NRY4GS4)"`,
`NOTARY_PROFILE=appstudio`. DMG lands in `dist/macos/`.

**`make dist` publishes.** `tool/publish_dist.sh` derives the path from
`pubspec.yaml` (`version: 1.0.0+1` → `releases/macos/1.0.0/b1/AppStudio-1.0.0-arm64.dmg`)
and uploads with `--if-generation-match=0`, so objects are immutable — a
re-release means bumping the pubspec build number, never overwriting a URL
someone already has. A `.sha256` sidecar goes up alongside it.

Three gates run before any upload, all verified to reject:
- the DMG is **mounted** and its `CFBundleShortVersionString` must match pubspec
  (stops a stale DMG being served under a new version number),
- it must contain no `Contents/Resources/toolchain` (stale embed),
- it must have a stapled notarization ticket (`--allow-unnotarized` overrides
  for internal builds, and says so loudly).

Reference sizes for a clean, notarized build: **.app 350 MB, DMG 156 MB**
(CEF is 302 MB of it). If you see ~2.1 GB / ~1.06 GB, the build tree is stale —
run `make clean`.

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
- **Reload:** the preview reload button and the DWDS-attach token both go through `PreviewPaneState.reload()`, which calls `reloadIgnoreCache()` — a plain navigation re-serves the cached `main.dart.js`, so a rebuilt app looks unchanged. Re-apply the theme shim afterwards: it is injected at load start with the brightness captured when the webview was created.
- **Backdrop:** CEF composites with alpha, so an opaque `ColoredBox` (`previewBackdropColor`) sits under the surface, following the *previewed* app's brightness, not the shell's.
- **CEF sizing:** `PreviewSurfaceSync` + `burstSyncPreviewSurface` keep the webview sized on panel/mode changes. Defer layout reads to post-frame callbacks; avoid `MediaQuery` in `initState`.
- **webview_cef:** path dependency `packages/webview_cef` (fork of 0.5.1). Includes CEF resize surface sync and skips embedding `Helper (Alerts)`. CEF itself is fetched by `pod install` into `macos/third/cef/` (gitignored).
- **Registration codes:** `serverpod start` logs `Registration code for <email>: <code>` instead of mailing it. `ServerpodProcessController` reassembles console lines across PTY chunks (`_scanLines`) and exposes `registrationCode`; `RegistrationCodeToast` floats it over the preview until dismissed or superseded.
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
