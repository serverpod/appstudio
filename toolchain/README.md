# Toolchain

Versioned runtimes shipped inside App Studio.

```
toolchain/
  active.json                         # pins active versions
  flutter/<flutter_version>/          # web-capable Flutter + Dart (via bundle script)
  serverpod_cli/<cli_version>/        # full prebuilt Serverpod CLI bundle
    bin/serverpod
    lib/                              # sqlite (and other) native libs — required
  opencode/<opencode_version>/        # OpenCode CLI (darwin-arm64 only)
    opencode
  bin/{flutter,dart,serverpod,opencode}  # wrappers → active.json
```

## Serverpod CLI

Copy the **full** dart-install / `dart build` bundle for a version into:

```
toolchain/serverpod_cli/<version>/
```

Both `bin/serverpod` and `lib/` (sqlite dylibs, etc.) are required. Multiple
versions can coexist; `active.json` selects which one is used.

## Flutter (web) + OpenCode

```bash
./tool/bundle_toolchain.sh
# optional pins:
./tool/bundle_toolchain.sh --flutter=3.44.2 --serverpod=4.0.0-beta.0 --opencode=1.18.4
```

Downloads and strips a web-only Flutter SDK into `toolchain/flutter/<version>/`.
Downloads the **darwin-arm64** OpenCode binary into `toolchain/opencode/<version>/`.
Does not download Serverpod — place the CLI bundle manually first.
