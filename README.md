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

## Auto-updates

App Studio updates itself with [Sparkle](https://sparkle-project.org) 2.x. The
feed lives at `appcast/macos/appcast.xml` in the public bucket and is signed
with an ed25519 key held in the release engineer's login Keychain.

Checks run automatically once a day, but installing is always a user action —
a silent relaunch would kill a running Serverpod server, the CEF preview and the
agent session. Before Sparkle relaunches, the app shuts those down cleanly.

Debug builds have no feed URL and report updates as unavailable, so a debug
build never replaces itself with a release one.

**Move the app to /Applications.** A zip extracted into `~/Downloads` runs
translocated on a read-only mount and cannot update itself; App Studio detects
this and disables the check rather than offering an update that would fail.

See `AGENTS.md` for the signing, key-backup and release details.

## Distribute

Bundle ID: `dev.serverpod.appstudio` · Team: Serverpod AB (`WK2NRY4GS4`).

```bash
make release V=1.2.3   # set the version, then build + sign + notarize + publish
make dist              # same, using the version already in pubspec.yaml
make dist_debug        # unsigned zip, local only (no notarization)
# or: NOTARIZE=1 ./tool/distribute_macos.sh
```

The artifact is a `.zip` (built with `ditto`, so CEF's symlinks survive), not a
DMG. Never hand-edit `version:` in `pubspec.yaml` — `+N` is a global counter
that Sparkle compares and that must never reset. `make set_version` picks it.

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
then show **“App Studio is damaged and can't be opened”** after copy — clear
quarantine with `xattr -cr "/Applications/App Studio.app"`, or distribute a
notarized build instead.
