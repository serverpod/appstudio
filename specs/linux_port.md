# Linux port: plan

Status: **agreed with Serverpod on 2026-11-25** (scope, the five PRs and the
Tuesday milestone). The details per subsystem below are the working plan.
Date: 2026-11-26. Baseline: `main` @ `6b3686c`, App Studio 0.4.0+24.
Updated 2026-11-28 to what was built: where the build differs from the plan,
the section says so.

## The plan in short

Five PRs, each merged into `linux/port` once tested:

| PR | Name | What |
|---|---|---|
| 1 | **App runs** | The Linux app shell, platform basics, menus |
| 2 | **Setup works** | Flutter and Serverpod CLI install, prerequisites |
| 3 | **Preview works** | The CEF fixes in the `webview_cef` fork |
| 4 | **Packaging** | AppImage, `.deb`, `.rpm`, reusing an existing Flutter Linux packaging setup, including AppImage updates through Gear Lever |
| 5 | **Polish** | "Open in…" editors, notifications, uninstall |

**Since then:** PR 4 became the AppImage alone, followed by a step that
adds it to the app menu and lets it update itself in place
(`specs/linux_appimage.md`, parts A and B). The `.deb` and `.rpm` are not
built: in-app updates cover what they were for, so they follow only if
Serverpod asks for them.

**CI, the release pipeline and the update feed (its hosting, URL and signing
key) run on Serverpod's infrastructure, so Serverpod owns them.** This port
delivers the build scripts and the updater inside the app.

Estimate: 15–25 hours.

### Tuesday 2026-12-01

**PRs 1–3, plus an AppImage that runs on Ubuntu and Arch**, built on the dev
machine:

- setup installs Flutter and the Serverpod CLI;
- a new project opens;
- the server runs;
- the preview works;
- Hot Restart and the menus work;
- closing App Studio stops the server.

**Not for Tuesday:** the `.deb` and `.rpm` (the `.deb` if time allows),
Fedora testing, auto-updates, a release pipeline, "Open in…" editors,
uninstall.

### Decisions

| # | Decision |
|---|---|
| L1 | **x64 only.** |
| L2 | **Tested on Ubuntu and Arch (Omarchy, Hyprland).** Not on Fedora for now. Omarchy is Wayland and a tiling window manager, so it is the hard case. |
| L3 | **No Flatpak.** Its sandbox gets in the way of everything App Studio does outside itself: installing Flutter into `~/develop`, editing the shell profile, starting the user's tools. |
| L4 | **App Studio never runs `sudo` or `pkexec`.** It installs Flutter and the Serverpod CLI per user, as on macOS and Windows. For system packages (git, curl, unzip, xz), setup checks and gives the distro's own install command with a **Check again** button, the same pattern as `ManualUpdateDialog`. The `.deb` and `.rpm` declare them as dependencies instead. |
| L5 | **One data folder, named after the app id: `$XDG_DATA_HOME/dev.serverpod.appstudio`** (default `~/.local/share/dev.serverpod.appstudio`). `shared_preferences` already keeps the settings there on Linux, so App Studio's own data joins them: one folder, removed in one go, and the lowercase, space-free name Linux folders usually have. macOS and Windows keep their "App Studio" folders. |

---

App Studio runs on macOS and Windows today. This document is the plan for
bringing it to Linux **without changing anything a macOS or Windows user
sees or relies on**. The Windows port already did most of the groundwork:
the host seam, process handling and the in-window menu strip all exist.
Large parts of this plan are therefore "give Linux the branch it is
missing" rather than new design.

1. Ground rules and branches
2. What we know
3. Inventory: what Linux gets for free, and where it falls through to macOS
4. Approach per subsystem
5. The five PRs in detail
6. Testing
7. Risks
8. Open questions
9. Developer machine setup (Linux)

---

## 1. Ground rules and branches

The Windows port's rules (section 1 of `windows_port.md`) apply as written,
with Windows read as "macOS and Windows":

- **Every change either adds a Linux-only branch or file, or is a refactor
  that leaves macOS and Windows behaviour identical.**
- **Host decisions go through `HostPlatform`** (`lib/platform/host.dart`),
  which already knows `HostOs.linux`. No new `Platform.isLinux` checks
  scattered around the code.
- **The existing suite stays green on macOS and Windows at every step.**
- **Native code shared with macOS or Windows** (`packages/webview_cef/common/`)
  is changed only behind `OS_LINUX` / `__linux__` guards, or where the change
  is behaviour-neutral on all three (a null check, say).
- **The macOS and Windows release tooling is not touched.**

**Branches.** The work happens on a fork. `linux/port` is the root branch,
with a single PR against `serverpod/appstudio` `main`. Each of the five PRs
is a branch off `linux/port` (`linux/1-app-runs`, `linux/2-setup`,
`linux/3-preview`, `linux/4-packaging`, `linux/5-polish`) and is merged into
`linux/port` after testing, not into `main`. Serverpod reviews only the root
PR, once the Tuesday scope works. The checklist at the end of this document
is what that PR tracks.

---

## 2. What we know

### CEF spike (2026-11-25, Omarchy / Hyprland, Flutter 3.44.8)

A throwaway Flutter app with `packages/webview_cef`:

| Check | Result |
|---|---|
| Rendering on Wayland | **Works natively.** The GPU helper runs with `--ozone-platform=wayland`; no XWayland needed. |
| Input | Clicking, typing, umlauts, and copy and paste in both directions work. The plugin's `xclip` paste workaround fails silently and is not needed. |
| Auto-setup | `target_modifier/modify_target.sh` patches `linux/main.cc` and `linux/my_application.cc`, but current Flutter puts them in `linux/runner/`. Nothing gets patched, and every CEF helper starts a full copy of the app (~30 processes). **The hooks must be wired into the runner by hand**: `initCEFProcesses` in `main`, and the key press and release handlers on the `FlView`. |
| Shortcuts | With the preview focused, app shortcuts (Ctrl+R) never reach Flutter. This is the Linux version of Windows' W4, the other way round. |
| CEF cache folder | No `root_cache_path` on Linux, so CEF uses `~/.config/cef_user_data`. A killed run leaves a `SingletonLock` there that blocks the next start. This is the bug `511902c` fixed on macOS and W3 fixed on Windows. |
| Frame buffer | A memory bug in the plugin's frame buffer handling. Fixed in PR 3. |
| Quit | Closing the window exits cleanly with no CEF helpers left behind. **Not checked:** whether the close runs App Studio's `onExitRequested` teardown (see 4.2). |
| Bundle size | 1.5 GB unstripped. |

### Checked in the code and on the dev machine (2026-11-26)

| Check | Result |
|---|---|
| Database | **No Docker on Linux either.** `serverpod_embedded_postgres` 4.1.2 ships `linux-x64` and `linux-arm64` binaries and caches them in `$XDG_CACHE_HOME/serverpod/pg-binaries`. |
| `HostPlatform` | Knows `HostOs.linux`: POSIX paths, `:` separator, plain executable names. |
| Process killing | `ProcessKiller`'s signal path already covers Linux (`host.isMacOS \|\| host.os == HostOs.linux`). |
| Runner socket limit | `runner_discovery.dart` already uses 108 bytes on Linux. The CLI's registry symlink needs no special permission on Linux, so long project paths work as on macOS. |
| AF_UNIX crash | Windows only. `settleAfUnixSockets` is already a no-op off Windows. |
| Analytics | `app_analytics.dart` already reports `Linux`. |
| CEF cache API | `setRootCachePath` in `common/webview_plugin.cc` is compiled for Windows *and* Linux already; only the Linux runner has to call it. |
| `dart install` | Puts executables in `$XDG_STATE_HOME/Dart/install/bin` (default `~/.local/state/Dart/install/bin`, capital D), as symlinks into `…/install/app-bundles/<package>/hosted/<version>/bundle/bin/`. |
| Dev machine Flutter | Comes through an **asdf shim**, which the probe already handles (`flutter --version --machine` → `flutterRoot`). The dev machine exercises the shim path for free. |

---

## 3. Inventory

### 3.1 Already works on Linux

- `HostPlatform`, path handling, `whichOnPath` (POSIX execute bits),
  `resolveToolCommand` (no batch files).
- `ProcessKiller`, dev-session cleanup, runner ownership.
- The runner protocol, discovery and client.
- The login-shell `PATH` capture (`login_shell_path.dart`). A program
  started from a desktop launcher gets the session's `PATH`, which can miss
  lines from `.zshrc`, the same problem as a Finder launch on macOS.
- FVM, Puro, asdf and mise shims in the probe.
- `UpdateController`'s `MissingPluginException` fallback: with no native
  side, Check for Updates is greyed out.
- The compact window's fallback: with `supportsCompactWindow` false, a
  minimized phone view behaves as desktop-minimized (chrome hidden, window
  untouched).

### 3.2 Falls through to macOS behaviour

These check `isWindows` and treat everything else as macOS, so Linux gets
macOS paths and commands:

| # | Area | Where | What Linux gets today | PR |
|---|---|---|---|---|
| F1 | App data folder | `toolchain_paths.dart` `forHome` | `~/Library/Application Support/App Studio` | 1 |
| F2 | `dart install` folder | `toolchain_paths.dart` `dartInstallBinDir` | `~/Library/Application Support/Dart/install/bin` | 2 |
| F3 | CEF cache and preferences folders | `toolchain_paths.dart` `localDataRoot`, `preferencesRoot` | null (macOS has neither) | 1 |
| F4 | Platform key | `platform_key_io.dart` | `unsupported` | 1 |
| F5 | Tool set | `tool_status.dart` `ToolId.requiredOn` | **no tools at all**: Flutter and Serverpod list only macOS and Windows, so setup installs nothing | 2 |
| F6 | Flutter download | `install_plan.dart`, `toolchain_installer.dart` | `releases_macos.json`, a `.zip`. Linux needs `releases_linux.json`, which serves **`.tar.xz`** | 2 |
| F7 | Shell profile | `shell_profile.dart` | macOS's files: `~/.zprofile` for zsh, `~/.bash_profile` for bash. **On Linux both are wrong.** A Linux terminal starts a non-login shell, which reads neither, so a new terminal would not find Flutter. And creating `~/.bash_profile` on Ubuntu (which has only `~/.profile`) makes login bash stop reading `~/.profile`. | 2 |
| F8 | Opening a URL | `open_url_io.dart` | `/usr/bin/open` (does not exist) | 1 |
| F9 | External editors | `external_editors.dart` | looks for `.app` bundles in `/Applications`; finds nothing, so no buttons | 5 |
| F10 | Menus | `main.dart` mounts the menu strip only `if isWindows`; `MacAppMenu` returns early off macOS | **no menus and no shortcuts** | 1 |
| F11 | Shortcut hints | `shortcut_hint.dart` | `⌘R` | 1 |
| F12 | Fonts | `app_theme.dart` | `.AppleSystemUIFont` and `Menlo`, which do not exist | 1 |
| F13 | Notifications | `studio_notifications.dart` | silent (returns off macOS and Windows) | 5 |
| F14 | Uninstall | `uninstaller.dart`, copy | macOS folders; copy about the Trash and NSUserDefaults | 5 |
| F15 | Setup copy | `toolchain_notices.dart`, `install_plan.dart` | "Terminal", "this Mac", "Apple's installer" | 2 |

### 3.3 Missing outright

| # | What | PR |
|---|---|---|
| M1 | The `linux/` Flutter runner (`.metadata` lists only `root`, `macos`, `windows`). | 1 |
| M2 | CEF hooks in that runner, wired by hand (section 2). | 1 |
| M3 | Window close → teardown on GTK (done, 4.2). | 1 |
| M4 | Packaging: AppImage, `.deb`, `.rpm`, a `.desktop` file, the icon. | 4 |

---

## 4. Approach per subsystem

### 4.1 Folders (XDG)

| What | Linux | Follows |
|---|---|---|
| App data (F1) | `$XDG_DATA_HOME/dev.serverpod.appstudio` (default `~/.local/share/dev.serverpod.appstudio`) | L5 |
| CEF cache (F3) | `<app data>/CEF`, set by the runner through `setRootCachePath` before CEF starts | — |
| Preferences (F3) | where `shared_preferences` puts them: `$XDG_DATA_HOME/<APPLICATION_ID>/shared_preferences.json`, with `APPLICATION_ID` `dev.serverpod.appstudio`: the same folder | L5 |
| Flutter | `~/develop/flutter`, as on macOS | — |
| `dart install` (F2) | `$XDG_STATE_HOME/Dart/install/bin` (section 2) | — |
| Pub cache | `~/.pub-cache` | — |
| `~/.serverpod` | unchanged | — |

App data and preferences share one folder (L5), so uninstall is one delete.

### 4.2 The Linux app shell (PR 1)

- `flutter create --platforms=linux --org dev.serverpod .`, then commit
  `linux/`. `APPLICATION_ID` `dev.serverpod.appstudio`, binary
  `appstudio`, window title "App Studio", 1280×800, minimum 670×600 (in step
  with `kMinAppWindowSize`): Windows' minimum, since 720 high does not fit a
  1080p laptop screen at 150%. A tiling window manager ignores both.
- **CEF hooks by hand**: `initCEFProcesses(argc, argv)` first in `main()`,
  so helper processes return before GTK starts; the key press and release
  handlers on the `FlView`. Without them the app does not run at all, which
  is why they are in PR 1 and the rest of the CEF work is in PR 3.
- **Window close → teardown.** On GTK every way out reaches
  `onExitRequested`: the close button, the window manager's close (Super+Q
  on Hyprland), File → Quit and Ctrl+Q. No `delete-event` handler was
  needed. Two things did need fixing:
  - A second exit request while the teardown runs waits for it, at most
    15 s (`_kLinuxExitWait` in `main.dart`), instead of quitting before the
    server has stopped. macOS and Windows still answer at once.
  - `linux/runner/main.cc` ends with `_exit()` after `g_application_run`.
    Flutter's Linux quit leaves the engine running, and a normal `exit()`
    raced Mesa's exit handlers against the raster thread and crashed about
    one quit in four.
- **Menus (F10):** mount the Windows shad menu strip (`windows_app_menu.dart`)
  on Linux too. Same commands, same Ctrl shortcuts, same enable rules.
- **Shortcut hints (F11):** `shortcutHint()` gives the Ctrl form on Linux.
- **Fonts (F12):** UI in shad's bundled Inter, as on Windows (weight
  correction 1). Monospace: the generic `monospace` family, which fontconfig
  resolves to the distro's default (DejaVu Sans Mono on Ubuntu). Bundling a
  font is the fallback if that looks wrong.
- **`openUrl` (F8):** `xdg-open`.
- Folders (4.1) and the platform key `linux-x64` (F4).
- **Compact window:** off (`supportsCompactWindow` false). Wayland does not
  let a program place its own window, and a tiling window manager decides
  the size, so the phone-shaped borderless window is unlikely to be worth
  it. The desktop-minimized fallback already works.

### 4.3 Setup (PR 2)

- **Tool set (F5).** Linux gets **System packages → Flutter → Serverpod**.
  `ToolId.systemPackages` is new and Linux only.
  - Probe: `git`, `curl`, `unzip` and `xz` via `whichOnPath`. These are the
    command-line tools Flutter's own Linux instructions list.
  - Install: none (L4). Setup shows the missing ones and the command for
    this distro, read from `/etc/os-release` (`ID`, `ID_LIKE`):
    `sudo apt install …`, `sudo pacman -S --needed …`, `sudo dnf install …`.
    Unknown distro: the list of package names. **Check again** re-probes.
- **Flutter (F6).** `releases_linux.json`, verified against its sha256 as
  on macOS, unpacked with `tar -xJf` into a staging folder, then renamed into
  `~/develop/flutter`. Same ownership rules as macOS.
- **Serverpod CLI.** `dart install serverpod_cli@<v>`, the same as macOS.
- **`PATH` lines (F7): the files Flutter's own Linux instructions name**
  (docs.flutter.dev/install/add-to-path, Linux section). That follows the
  existing rule that every tool is installed the way its own instructions
  say. The Dart line goes in the same file as Flutter's, as on macOS.

  | Shell | Linux | macOS (unchanged) |
  |---|---|---|
  | zsh | `~/.zshenv` (read by every zsh, login or not), or `$ZDOTDIR/.zshenv` when the login shell sets `ZDOTDIR` | `~/.zprofile` |
  | bash | `~/.bashrc` (read by every interactive bash) | `~/.bash_profile` |
  | sh, ksh | `~/.profile` | not supported |
  | fish | by hand for now. Flutter's command is `fish_add_path -U -p ~/develop/flutter/bin`, a universal variable rather than a line in a file, so the install record and uninstall need a new kind of entry. | by hand |
  | anything else | the lines to add by hand, as today | same |

  Discovery is unaffected: the probe's login-shell fallback runs `-l -i`,
  which reads all of these.
- **Copy (F15):** "Terminal" stays, "this Mac" becomes "this computer",
  Apple's installer becomes the system packages step.

### 4.4 The preview (PR 3)

All in `packages/webview_cef/linux/`, or behind `__linux__` in `common/`
unless the change is behaviour-neutral on all three:

- **Auto-setup:** take `modify_target.sh` out of the plugin's CMake. The
  hooks live in the runner (PR 1), and the script is what breaks on current
  Flutter.
- **Cache folder:** export `setRootCachePath` from the Linux plugin and call
  it from the runner with `<app data>/CEF` before CEF starts.
- **Shortcuts:** with the preview focused, the page gets the keys, but Ctrl
  on any other character key stays App Studio's shortcut, as on Windows.
  Ctrl+A/C/V/X/Y/Z stay with the page.
- **Clipboard, through GTK.** On Wayland only a window with keyboard focus
  may use the clipboard, and CEF draws off-screen, so it never has focus:
  its copies stayed inside Chromium and it never saw what others copied.
  The plugin carries the text across itself. Ctrl+C and Ctrl+X put the
  page's selection on the clipboard, and Ctrl+V types the clipboard's text
  into the page, as an input method would. Two limits follow:
  - The page gets no paste event, so a page that reads paste events (an
    image, rich text) gets nothing.
  - Only a selection Chromium sees is copied. A copy made by the page's own
    code (`Clipboard.setData`, Flutter web's `SelectionArea`) does not reach
    other programs.
- **Frame buffer:** the memory bug from the spike.
- **The `xclip` workaround:** remove it (not needed, section 2).
- **End to end:** hard reload and the project-switch clear
  (`clearBrowsingData`, `reloadIgnoreCache`) on Linux's multi-threaded CEF
  loop; Hot Restart reloads the preview.

### 4.5 Packaging (PR 4)

- **AppImage** (Tuesday), built on the dev machine by `make appimage`
  (`tool/linux/build_appimage.sh`), from an existing Flutter Linux AppImage
  setup. The CEF helpers resolve their own paths inside the mounted image.
- **Updates come from inside the app** (`specs/linux_appimage.md` part B):
  a signed feed that `tool/linux/appcast.sh` writes, and the feed and key
  in `linux/release.json`. zsync update information for Gear Lever is still
  possible (`APPIMAGE_UPDATE_INFO`) but off unless the build is given it.
- **`.deb` and `.rpm`: not built**, only if asked (see the plan in short).
  They would declare git, curl, unzip and xz, plus CEF's runtime libraries
  (libnss3, libgbm1, libasound2 and the rest; to list from `ldd` on the
  bundle).
- **Every format:** a `.desktop` file with `StartupWMClass` matching the GTK
  application id, so the dock and window match; the icon in hicolor sizes.
- **Size:** strip the bundle (1.5 GB unstripped). The macOS app is 350 MB
  with 302 MB of it CEF, which is a fair target.
- **Build scripts in `tool/linux/`**, handed over for Serverpod's CI and
  release pipeline.

### 4.6 Polish (PR 5)

- **External editors (F9):**
  - VS Code and Cursor are found as `code` and `cursor` on `PATH`, or
    through their `.desktop` files, and started with the folder.
  - Deep links (Codex, OpenCode) go through `xdg-open`, but only when
    `xdg-mime query default x-scheme-handler/<scheme>` names a handler.
  - Claude has no official Linux desktop app, so it gets no button.
  - Whether Cursor's CLI reaches its Agents Window on Linux is still to
    verify, as on Windows.
- **Notifications (F13):** freedesktop notifications over D-Bus
  (`notify-send` is not installed everywhere).
- **Uninstall (F14):** remove the XDG folders, the recorded `PATH` lines,
  Flutter and the CLI under the existing rules. Never touch system packages.
  The app itself goes by deleting the AppImage or through the package
  manager; the copy says which.

---

## 5. The five PRs in detail

Each PR is one branch off `linux/port`, merged into it after testing, with
macOS and Windows CI green.

### PR 1: App runs (`linux/1-app-runs`) [Tuesday]

- The app shell (4.2): runner, CEF hooks, window, menus, shortcut hints,
  fonts, `xdg-open`, folders, platform key.
- Window close → teardown, checked and fixed if needed.
- Done when: App Studio starts on Omarchy, shows the setup screen with no
  runtime errors, the menus work, and closing leaves no processes behind.

### PR 2: Setup works (`linux/2-setup`) [Tuesday]

- System packages check, Flutter, Serverpod CLI, `PATH` lines, copy (4.3).
- Widgetbook use cases for the system packages step.
- Done when: on a fresh Ubuntu user account, setup installs Flutter and the
  CLI and lands on the start page; on Omarchy it finds the system packages,
  the existing asdf Flutter (and asks for it to be updated when it is too
  old) and the Serverpod CLI already on `PATH`, and installs nothing.

### PR 3: Preview works (`linux/3-preview`) [Tuesday]

- The CEF fixes (4.4).
- Done when: a new project opens, the server runs, the preview shows the app
  and takes typing, copy and paste, Hot Restart works with the preview
  focused, and closing App Studio stops the server and its Postgres
  (`pgrep -f serverpod`, `pgrep -f postgres` come back empty).

### PR 4: Packaging (`linux/4-packaging`)

- The AppImage for Tuesday (4.5). Then, in `linux/4b-appimage`, Add to
  Applications and in-app updates. No `.deb` or `.rpm` unless asked.
- Done when (Tuesday): the AppImage runs on Ubuntu and on Omarchy and passes
  the smoke checklist (section 6).

### PR 5: Polish (`linux/5-polish`)

- Editors, notifications, uninstall (4.6). After Tuesday.

### Serverpod's side

- CI (a Linux job, if wanted), the release pipeline, and the update feed's
  hosting and signing key, using the build scripts from PR 4.

---

## 6. Testing

- **Unit tests for Linux logic run on every host** through
  `HostPlatform.linux`, as Windows logic does: folders, the tool set, the
  shell profile choice, the distro install command.
- **Smoke checklist** for Tuesday, run on Ubuntu and Omarchy with the
  AppImage:
  - start from the launcher;
  - first-run setup installs Flutter and the Serverpod CLI;
  - create a project; it opens and the server runs;
  - the preview works: typing, copy and paste;
  - Hot Restart, also with the preview focused;
  - the menus and their shortcuts;
  - closing App Studio stops the server and leaves nothing running.
- **macOS and Windows:** CI stays the gate. Any PR touching
  `packages/webview_cef/common/` also gets a macOS build before it merges
  into `linux/port`.
- **For Serverpod's CI, if wanted:** a job on `ubuntu-latest` can run the
  whole suite, including the `process` tests (there is no AF_UNIX crash on
  Linux), plus `flutter build linux`. Widget tests need no display; the
  build needs the GTK headers.

---

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Window close skips the teardown, as it did on Windows | The server and Postgres keep running after App Studio closes | Checked first in PR 1; the `lifecycle` channel already exists |
| Shell profile choice (F7) | macOS's files on Linux: a new terminal does not find Flutter, and a new `~/.bash_profile` silently disables the user's `~/.profile` | Flutter's Linux files (`~/.zshenv`, `~/.bashrc`, `~/.profile`); tests pin each shell on both hosts |
| CEF inside an AppImage | Helpers fail to find their resources or sandbox inside the mounted image | Build a first AppImage as soon as PR 1 runs, not on Monday |
| CEF's Chromium sandbox | Distros that restrict unprivileged user namespaces (Ubuntu 24.04's AppArmor rule) can stop the sandbox | Check on Ubuntu early |
| Bundle size | A 1.5 GB download | Strip; compare with the macOS 350 MB |
| X11 sessions | The spike only covered Wayland | Check Ubuntu on X11 once |
| Shared `common/` CEF edits | macOS or Windows break | `__linux__` guards; a macOS build before merging |
| Tight schedule | 15–25 hours over Friday, Saturday and some of Monday | PR 5 and the `.deb`/`.rpm` are already outside Tuesday |

---

## 8. Open questions

For Serverpod, since updates and releases are theirs:

1. **Updates.** App Studio updates the AppImage itself from a signed feed.
   Where is it hosted, and who holds the signing key? Are `.deb` and `.rpm`
   wanted on top?
2. **Ubuntu baseline.** 24.04 LTS?

---

## 9. Developer machine setup (Linux)

| What | Why | How |
|---|---|---|
| Flutter ≥ 3.44 (stable) | Host SDK for building App Studio | any stable SDK on `PATH`; not in `~/develop/flutter`, which is where App Studio installs its own |
| Flutter's Linux desktop dependencies | `flutter build linux` | Ubuntu: `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev`; Arch: `sudo pacman -S --needed clang cmake ninja pkgconf gtk3` |
| git, curl, unzip, xz | Flutter itself, and App Studio's own setup check | usually there already |
| ~2 GB free and network on the first build | CEF downloads during the first CMake configure | — |

Clean-room testing: a second user account on the dev machine gives a fresh
home folder in seconds, which covers setup and `PATH` writing. A spare
laptop with a fresh Ubuntu covers the AppImage on a clean system.

---

## Root PR checklist

Tuesday:

- [x] PR 1: App runs
- [x] PR 2: Setup works
- [x] PR 3: Preview works
- [x] AppImage runs on Ubuntu (smoke checklist)
- [x] AppImage runs on Omarchy (smoke checklist)

After Tuesday:

- [x] AppImage: Add to Applications and in-app updates
- [ ] `.deb` and `.rpm`, only if asked
- [ ] PR 5: Polish ("Open in…" editors, notifications, uninstall)
- [ ] Build scripts handed over for Serverpod's CI and release pipeline
