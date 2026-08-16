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

One-time setup on a release machine:

- The **Developer ID Application: Serverpod AB (WK2NRY4GS4)** certificate in the
  Keychain (signing).
- Notary credentials stored under the profile name the scripts look for — an
  App Store Connect API key, not an Apple ID password:

  ```bash
  xcrun notarytool store-credentials "appstudio" \
    --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
    --key-id "XXXXXXXXXX" \
    --issuer "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  ```

- The Sparkle ed25519 private key in the login Keychain (the appcast is signed
  with it). If this machine has never released, import it from the backup in
  Secret Manager — see `AGENTS.md`, "Back up the signing key".
- `gcloud` authenticated with write access to the release bucket.

Then the whole release is one command:

```bash
make release V=1.2.3        # set version → build → sign → notarize → publish → appcast
```

`V=` also takes `patch`, `minor`, `major` or `build`. The version step picks a
build counter that clears everything already in the live appcast, and the
publish re-checks the same gate — plus that the zip's `Info.plist` matches
`pubspec.yaml`, that no stale toolchain embed survived, and that the
notarization ticket is stapled — before anything uploads. Uploads are immutable:
a bad release is fixed by shipping the next build number, never by replacing an
object.

To inspect the zip before it goes out, split the same flow:

```bash
PUBLISH=0 make dist         # build + sign + notarize, stop at dist/macos/*.zip
make publish_dist           # upload the zip
make publish_appcast        # dry-runs the Sparkle feed, prints the real command
```

`make dist_debug` builds an unsigned zip for local use only — copied to another
Mac it trips Gatekeeper ("damaged"), which is quarantine, not damage.

A clean, notarized `.app` is ~350 MB; ~2.1 GB means a stale build tree — run
`make clean` and rebuild.

Never hand-edit `version:` in `pubspec.yaml`. The `+N` counter is what Sparkle
compares, and a repeat or a rollback makes every installed copy stop seeing
updates for good — use `make set_version` (which `make release` runs for you).

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
version you want. The full SDK is bundled — nothing is stripped — precached for
web, so expect a multi-GB download and upload.

```bash
make update_flutter V=3.45.0
# raise "hostAccepts" — a minor bump falls outside the pinned range
./tool/publish_toolchain.sh --only=flutter --dry-run
./tool/publish_toolchain.sh --only=flutter
git add -A && git commit                    # includes assets/toolchain_manifest.json
```

`V=` becomes the new pin in `toolchain/active.json`; without it, the currently
pinned version is re-downloaded and re-bundled. The publish rewrites
`assets/toolchain_manifest.json`, which ships in the app — commit it with the
release.

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
