# Toolchain

Versioned runtimes, staged here so `tool/publish_toolchain.sh` can upload them
to the public bucket. **App Studio does not read this tree** — it resolves each
tool as managed (its own Application Support directory) then host, and nothing
else. This is a packaging area, not a way to run the app against local tools.

```
toolchain/
  active.json                         # pins active versions
  flutter/<flutter_version>/          # full Flutter + Dart SDK, precached for web
  serverpod_cli/<cli_version>/        # full prebuilt Serverpod CLI bundle
    bin/serverpod
    lib/                              # sqlite (and other) native libs — required
  opencode/<opencode_version>/        # OpenCode CLI (darwin-arm64 only)
    opencode
  git/<git_version>/                  # portable Git (dugite-native) — avoids Xcode CLT stub
    bin/git
    libexec/
  llvm-tools/<llvm_version>/          # otool from an LLVM release + install_name_tool from cctools
    bin/{otool,install_name_tool}
  pins/{flutter,serverpod_cli,opencode,git,llvm_tools}  # plain strings for the wrappers
  bin/{flutter,dart,serverpod,opencode,git}             # wrappers → pins + versioned binaries
```

Shell wrappers intentionally avoid `python3` / `jq`. On Macs without Xcode
Command Line Tools, `/usr/bin/python3` is a stub that prompts for CLT install.
For the same reason they read the plain files in `pins/` rather than
`active.json`, and every version they interpolate must be read at *runtime* —
the wrapper heredocs are quoted, so a generation-time variable would land in the
wrapper unexpanded and die under `set -u`.

## Updating one tool

```bash
make update_serverpod V=4.0.0-beta.2   # copy from this Mac's dart install
make update_flutter   V=3.44.2         # download full SDK; carries the Dart SDK
make update_llvm_tools V=23.1.1        # otool from that LLVM release + cctools install_name_tool
```

All three are `bundle_toolchain.sh --only=<id> --force`. `V=` becomes the new pin in
`active.json`; without it the currently pinned version is rebuilt. Tools left
out keep whatever `active.json` already pins, so a partial run cannot move a pin
for a tree it never rebuilt.

## Serverpod CLI

There is no download — pub publishes no macOS archive — so the tree is copied
from what `dart install` unpacked on this Mac:

```bash
dart install serverpod_cli <version>
make update_serverpod V=<version>
```

Both `bin/serverpod` and `lib/` (sqlite dylibs, etc.) are required. Multiple
versions can coexist; `active.json` selects which one is used. The staged binary
is asked its own `--version` before the run is allowed to succeed: the install
path claims a version, but only the binary knows one.

## Flutter + OpenCode + Git + llvm-tools

```bash
./tool/bundle_toolchain.sh
# optional pins:
./tool/bundle_toolchain.sh --flutter=3.44.2 --serverpod=4.0.0-beta.2 --opencode=1.18.4 --git=2.53.0-3
```

Downloads the full Flutter SDK (not stripped) into `toolchain/flutter/<version>/`
and runs `flutter precache --web`.
Downloads the **darwin-arm64** OpenCode binary into `toolchain/opencode/<version>/`.
Downloads portable **Git** ([dugite-native](https://github.com/desktop/dugite-native)) into
`toolchain/git/<version>/` so target Macs do not need Xcode / Command Line Tools
just to run `serverpod start` / Flutter web.

### Why Git is bundled

macOS ships a `/usr/bin/git` stub that prompts for Xcode Command Line Tools when
invoked. Flutter requires a real `git` even for web-only runs. The bundled
binary is prepended to `PATH` (and `GIT_EXEC_PATH` is set) for all spawned
Serverpod / Flutter processes.

### Why llvm-tools is bundled, and what is in it

Serverpod’s native-assets step runs `otool -D` and `install_name_tool` on sqlite
dylibs, and `dart install` runs `install_name_tool -add_rpath` on the
executable it just compiled. `/usr/bin/otool` and `/usr/bin/install_name_tool`
are CLT stubs on a clean Mac, and copying Apple's own binaries out of Xcode
would be redistribution the licence does not allow. So the two are built from
two open-source upstreams:

- **`otool`** is `llvm-objdump` from an official LLVM release (Apache-2.0 WITH
  LLVM-exception), installed under the Apple name — it dispatches on `argv[0]`.
  Apple's own `otool` has been `llvm-otool` since Xcode 15.
- **`install_name_tool`** is built from Apple's cctools sources (APSL 2.0)
  through the [cctools-port](https://github.com/tpoechtrager/cctools-port)
  autotools tree, pinned by commit in `bundle_toolchain.sh`. It is statically
  linked and depends on `libSystem` alone.

It used to be `llvm-objcopy` under the same trick, and that broke
`dart install` — and `serverpod cloud`, which installs the cloud CLI through
it. Every `dart compile exe` output carries an `LC_NOTE` load command (the
embedded snapshot), and `llvm-objcopy` refuses any Mach-O with a load command
it cannot lay out: `unsupported load command (cmd=0x31)`. LLVM `main` still
does not accept it; cctools does. `bundle_toolchain.sh` refuses to stage a
tree whose `install_name_tool` cannot add an rpath to a freshly compiled Dart
program, so that cannot ship again unnoticed.

The pin (`llvm_tools` in `active.json`) is the LLVM version, and it is what
installed copies compare their `otool --version` against. **A new cctools
reaches users only together with an LLVM bump** — bump both and run
`make update_llvm_tools V=<llvm version>`. The build needs Xcode or the CLT on
the release Mac, for the C compiler; the product needs neither.
