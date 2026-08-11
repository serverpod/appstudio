# App Studio

Self-contained macOS IDE for **Serverpod 4** projects. Open a project, run
`serverpod start` in an embedded terminal, preview the Flutter web app in
Chromium (CEF) at `http://localhost:9998`, and work with an OpenCode-backed
agent in the sidebar.

App Studio downloads its own Flutter, Dart, Serverpod CLI, OpenCode and Git on
first run, so a user needs nothing preinstalled — not even Xcode.

## Getting started

Prerequisites: Flutter 3.44+ / Dart 3.12+, and `brew install cmake ninja` for
CEF.

```bash
make deps      # pub get + CEF/pods — once, or when CEF is missing
make start     # flutter run -d macos
```

`make help` lists every target.

## Releasing

### The app

```bash
make release V=1.2.3        # set version → build → sign → notarize → publish → appcast
```

`V=` also takes `patch`, `minor`, `major` or `build`. To check the zip before it
goes out:

```bash
PUBLISH=0 make dist         # local zip only, nothing uploaded
make publish_dist           # upload it
make publish_appcast        # refresh the Sparkle feed
```

Never hand-edit `version:` in `pubspec.yaml`. The `+N` counter is what Sparkle
compares, and a repeat or a rollback makes every installed copy stop seeing
updates for good.

### The Serverpod CLI

```bash
dart install serverpod_cli 4.0.0-beta.3     # pub publishes no macOS archive
make update_serverpod V=4.0.0-beta.3
# raise "hostAccepts" in assets/toolchain_manifest.json if this is a new minimum
./tool/publish_toolchain.sh --only=serverpod_cli --dry-run
./tool/publish_toolchain.sh --only=serverpod_cli
git add -A && git commit
```

### Dart / Flutter

Dart ships inside the Flutter SDK, so pick the Flutter release carrying the Dart
version you want. Expect ~700 MB down and ~673 MB up.

```bash
make update_flutter V=3.45.0
# raise "hostAccepts" — a minor bump falls outside the pinned range
./tool/publish_toolchain.sh --only=flutter --dry-run
./tool/publish_toolchain.sh --only=flutter
git add -A && git commit
```

### Why the toolchain publish is not a make target

`make publish_toolchain` only ever dry-runs. Published objects are immutable and
the account that uploads them cannot undo the mistake, so the real upload is
always typed out. `--dry-run` first, every time.

`hostAccepts` is the one manifest field the script never writes — it is the
minimum version App Studio will accept, which is a decision rather than a
packaging fact. Every publish prints each tool's version and floor side by side
at the end.

## More

`AGENTS.md` is the reference: architecture, the toolchain and bucket layout,
signing and key backup, Sparkle, CEF, and the reasoning behind the decisions
that look surprising.
