# App Studio

Self-contained macOS IDE for **Serverpod 4** projects. Open a project, run
`serverpod start` in an embedded terminal, and preview the Flutter web app in
Chromium (CEF) at `http://localhost:9998`.

## Development

Prerequisites:

- Flutter 3.44+ / Dart 3.12+
- `serverpod_cli` 4.0.0-beta.1 (`dart install serverpod_cli 4.0.0-beta.1`)
- For CEF: `brew install cmake ninja`

```bash
make build_toolchain   # pub get + CEF/pods + toolchain/ (once)
make start             # ensure toolchain, then flutter run -d macos
```

Or manually: `flutter pub get && cd macos && pod install && cd .. && flutter run -d macos`.

Without a bundled toolchain, the app uses host `flutter` / `dart` / `serverpod` /
`opencode`.

Opened projects must launch Flutter with `web-server` on port **9998** (Serverpod
`flutter_apps` config).

**New Project** (start page or File menu) runs the bundled
`serverpod create --ide opencode`, sets that `flutter_apps` device/port in
`<name>_server/pubspec.yaml`, and opens the project.

The **Agent** tab runs a project-scoped OpenCode server (`opencode serve`) and
streams chat over HTTP/SSE. Configure LLM API keys via the toolbar Settings
dialog (stored in OpenCode’s `auth.json`).

## Bundle toolchain

Source of truth is the project-level [`toolchain/`](toolchain/) directory.

1. Copy the **full** Serverpod CLI bundle (binary + `lib/` dylibs) into a
   versioned folder:

```
toolchain/serverpod_cli/4.0.0-beta.1/
  bin/serverpod
  lib/                 # sqlite dylibs — required
```

2. Download Flutter (web-stripped), OpenCode (darwin-arm64), and portable Git
   (also done by `make build_toolchain`):

```bash
make build_toolchain
# or: ./tool/bundle_toolchain.sh
# optional flags: --force --flutter=3.44.2 --serverpod=4.0.0-beta.1 --opencode=1.18.4 --git=2.53.0-3
```

Release builds embed the entire `toolchain/` tree (including Serverpod `lib/`,
OpenCode, and Git) into the `.app`. Debug `flutter run` skips embedding and uses
host tools when the local `toolchain/` pin is incomplete.

Portable Git avoids the macOS `/usr/bin/git` stub that otherwise prompts for
Xcode Command Line Tools on machines without developer tools installed.

## Distribute

Bundle ID: `dev.serverpod.appstudio` · Team: Serverpod AB (`WK2NRY4GS4`).

```bash
make dist              # ensure toolchain, signed + notarized DMG
make dist_debug        # ensure toolchain, unsigned DMG (no notarization)
# or: NOTARIZE=1 ./tool/distribute_macos.sh
```

Defaults (override via env):

| Variable | Default |
|---|---|
| `SIGN_IDENTITY` | `Developer ID Application: Serverpod AB (WK2NRY4GS4)` |
| `NOTARY_PROFILE` | `appstudio` |
| `NOTARIZE` | `0` (set to `1` to submit) |

One-time notary setup (App Store Connect API key):

```bash
xcrun notarytool store-credentials "appstudio" \
  --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
  --key-id "XXXXXXXXXX" \
  --issuer "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### Unsigned builds on another Mac

Skip signing with `SIGN_IDENTITY="" ./tool/distribute_macos.sh`. Gatekeeper may
then show **“AppStudio is damaged and can't be opened”** after copy — clear
quarantine with `xattr -cr /Applications/AppStudio.app`, or distribute a
notarized build instead.
