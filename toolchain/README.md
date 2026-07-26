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
  git/<git_version>/                  # portable Git (dugite-native) — avoids Xcode CLT stub
    bin/git
    libexec/
  cctools/                            # real otool + install_name_tool from Xcode
    bin/{otool,install_name_tool}
    lib/libcodedirectory.dylib
  pins/{flutter,serverpod_cli,opencode,git}  # plain version strings for shell wrappers
  bin/{flutter,dart,serverpod,opencode,git}  # wrappers → pins + versioned binaries
```

Shell wrappers intentionally avoid `python3` / `jq`. On Macs without Xcode
Command Line Tools, `/usr/bin/python3` is a stub that prompts for CLT install.

## Serverpod CLI

Copy the **full** dart-install / `dart build` bundle for a version into:

```
toolchain/serverpod_cli/<version>/
```

Both `bin/serverpod` and `lib/` (sqlite dylibs, etc.) are required. Multiple
versions can coexist; `active.json` selects which one is used.

## Flutter (web) + OpenCode + Git

```bash
./tool/bundle_toolchain.sh
# optional pins:
./tool/bundle_toolchain.sh --flutter=3.44.2 --serverpod=4.0.0-beta.0 --opencode=1.18.4 --git=2.53.0-3
```

Downloads and strips a web-only Flutter SDK into `toolchain/flutter/<version>/`.
Downloads the **darwin-arm64** OpenCode binary into `toolchain/opencode/<version>/`.
Downloads portable **Git** ([dugite-native](https://github.com/desktop/dugite-native)) into
`toolchain/git/<version>/` so target Macs do not need Xcode / Command Line Tools
just to run `serverpod start` / Flutter web.

Does not download Serverpod — place the CLI bundle manually first.

### Why Git is bundled

macOS ships a `/usr/bin/git` stub that prompts for Xcode Command Line Tools when
invoked. Flutter requires a real `git` even for web-only runs. The bundled
binary is prepended to `PATH` (and `GIT_EXEC_PATH` is set) for all spawned
Serverpod / Flutter processes.

### Why cctools is bundled

Serverpod’s native-assets step runs `otool -D` and `install_name_tool` on sqlite
dylibs. `/usr/bin/otool` and `/usr/bin/install_name_tool` are CLT stubs on a
clean Mac. `bundle_toolchain.sh` copies real binaries from the build machine’s
Xcode into `toolchain/cctools/` and prepends that `bin/` to `PATH`.
