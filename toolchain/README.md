# Toolchain

Versioned runtimes shipped inside App Studio.

```
toolchain/
  active.json                         # pins active versions
  flutter/<flutter_version>/          # web-capable Flutter + Dart (via bundle script)
  serverpod_cli/<cli_version>/        # full prebuilt Serverpod CLI bundle
    bin/serverpod
    lib/                              # sqlite (and other) native libs — required
  bin/{flutter,dart,serverpod}        # wrappers → active.json
```

## Serverpod CLI

Copy the **full** dart-install / `dart build` bundle for a version into:

```
toolchain/serverpod_cli/<version>/
```

Both `bin/serverpod` and `lib/` (sqlite dylibs, etc.) are required. Multiple
versions can coexist; `active.json` selects which one is used.

## Flutter (web)

```bash
./tool/bundle_toolchain.sh
```

Downloads and strips a web-only Flutter SDK into `toolchain/flutter/<version>/`.
Does not download Serverpod — place the CLI bundle manually first.
