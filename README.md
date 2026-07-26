# App Studio

Self-contained macOS IDE for **Serverpod 4** projects. Open a project, run
`serverpod start` in an embedded terminal, and preview the Flutter web app in
Chromium (CEF) at `http://localhost:9998`.

## Development

Prerequisites:

- Flutter 3.44+ / Dart 3.12+
- `serverpod_cli` 4.0.0-beta.0 (`dart install serverpod_cli 4.0.0-beta.0`)
- For CEF: `brew install cmake ninja`

```bash
flutter pub get
cd macos && pod install && cd ..
flutter run -d macos
```

Without a bundled toolchain, the app uses host `flutter` / `dart` / `serverpod` /
`opencode`.

Opened projects must launch Flutter with `web-server` on port **9998** (Serverpod
`flutter_apps` config).

The **Agent** tab runs a project-scoped OpenCode server (`opencode serve`) and
streams chat over HTTP/SSE. Configure LLM API keys via the toolbar Settings
dialog (stored in OpenCode’s `auth.json`).

## Bundle toolchain

Source of truth is the project-level [`toolchain/`](toolchain/) directory.

1. Copy the **full** Serverpod CLI bundle (binary + `lib/` dylibs) into a
   versioned folder:

```
toolchain/serverpod_cli/4.0.0-beta.0/
  bin/serverpod
  lib/                 # sqlite dylibs — required
```

2. Download Flutter (web-stripped), OpenCode (darwin-arm64), and portable Git:

```bash
./tool/bundle_toolchain.sh
# optional: --force --flutter=3.44.2 --serverpod=4.0.0-beta.0 --opencode=1.18.4 --git=2.53.0-3
```

Release builds embed the entire `toolchain/` tree (including Serverpod `lib/`,
OpenCode, and Git) into the `.app`. Debug `flutter run` skips embedding and uses
host tools when the local `toolchain/` pin is incomplete.

Portable Git avoids the macOS `/usr/bin/git` stub that otherwise prompts for
Xcode Command Line Tools on machines without developer tools installed.

## Distribute

```bash
./tool/bundle_toolchain.sh
SIGN_IDENTITY="Developer ID Application: …" ./tool/distribute_macos.sh
```

Creates a signed DMG under `dist/macos/`. Notarization is optional:

```bash
SIGN_IDENTITY="…" NOTARY_PROFILE="…" NOTARIZE=1 ./tool/distribute_macos.sh
```

### Unsigned builds on another Mac

If you skip `SIGN_IDENTITY`, macOS Gatekeeper may show **“AppStudio is damaged
and can't be opened”** after copying the DMG. The app is not corrupted — it is
unsigned and carries a quarantine flag from download/copy.

On the target Mac, after installing to `/Applications`:

```bash
xattr -cr /Applications/AppStudio.app
```

Then open normally (or **Right-click → Open** the first time).

For frictionless installs, sign with a **Developer ID Application** certificate
and notarize (`NOTARIZE=1`).
