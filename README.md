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

Without a bundled toolchain, the app uses host `flutter` / `dart` / `serverpod`.

Opened projects must launch Flutter with `web-server` on port **9998** (Serverpod
`flutter_apps` config).

## Bundle toolchain

Source of truth is the project-level [`toolchain/`](toolchain/) directory.

1. Copy the **full** Serverpod CLI bundle (binary + `lib/` dylibs) into a
   versioned folder:

```
toolchain/serverpod_cli/4.0.0-beta.0/
  bin/serverpod
  lib/                 # sqlite dylibs — required
```

2. Download Flutter and strip non-macOS / non-web platform artifacts:

```bash
./tool/bundle_toolchain.sh
# optional: --force --flutter=3.44.2 --serverpod=4.0.0-beta.0
```

Release builds embed the entire `toolchain/` tree (including Serverpod `lib/`)
into the `.app`. Debug `flutter run` skips embedding and uses host tools.

## Distribute

```bash
./tool/bundle_toolchain.sh
SIGN_IDENTITY="Developer ID Application: …" ./tool/distribute_macos.sh
```

Creates a signed DMG under `dist/macos/`. Notarization is optional:

```bash
SIGN_IDENTITY="…" NOTARY_PROFILE="…" NOTARIZE=1 ./tool/distribute_macos.sh
```
