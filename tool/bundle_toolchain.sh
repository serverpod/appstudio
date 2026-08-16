#!/usr/bin/env bash
# Builds the toolchain/ trees that publish_toolchain.sh uploads.
#
# Downloads the full Flutter SDK (which carries the Dart SDK), precached for
# web, into:
#   toolchain/flutter/<version>/
# Copies the Serverpod CLI from this Mac's `dart install` bundle into:
#   toolchain/serverpod_cli/<version>/{bin,lib}
# Downloads OpenCode CLI (darwin-arm64 only) into:
#   toolchain/opencode/<version>/opencode
# Downloads portable Git (dugite-native) into:
#   toolchain/git/<version>/{bin,libexec,...}
# Installs otool + install_name_tool from an official LLVM release into:
#   toolchain/llvm-tools/<version>/bin
#
# --only= builds a subset. Tools left out keep whatever active.json already
# pins, so a partial run cannot rewrite a pin for a tree it never touched.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/toolchain}"
FLUTTER_VERSION="${FLUTTER_VERSION:-3.44.2}"
SERVERPOD_CLI_VERSION="${SERVERPOD_CLI_VERSION:-4.0.0-beta.2}"
OPENCODE_VERSION="${OPENCODE_VERSION:-1.18.4}"
# dugite-native release tag without leading "v" (GitHub Desktop portable Git).
GIT_VERSION="${GIT_VERSION:-2.53.0-3}"
# Official LLVM release: llvm-otool / llvm-install-name-tool are
# Apache-2.0 WITH LLVM-exception, so redistribution is unambiguous.
LLVM_VERSION="${LLVM_VERSION:-20.1.8}"
FORCE="${FORCE:-0}"
ONLY="${ONLY:-}"

usage() {
  echo "Usage: $0 [--force] [--only=IDS] [--flutter=VERSION]" >&2
  echo "          [--serverpod=VERSION] [--opencode=VERSION] [--git=VERSION]" >&2
  echo "  --only= comma-separated: flutter,serverpod_cli,opencode,git,llvm-tools" >&2
}

EXPLICIT=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --only=*) ONLY="${arg#*=}" ;;
    --flutter=*) FLUTTER_VERSION="${arg#*=}"; EXPLICIT+=",flutter" ;;
    --serverpod=*) SERVERPOD_CLI_VERSION="${arg#*=}"; EXPLICIT+=",serverpod_cli" ;;
    --opencode=*) OPENCODE_VERSION="${arg#*=}"; EXPLICIT+=",opencode" ;;
    --git=*) GIT_VERSION="${arg#*=}"; EXPLICIT+=",git" ;;
    --llvm=*) LLVM_VERSION="${arg#*=}"; EXPLICIT+=",llvm-tools" ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage
      exit 1
      ;;
  esac
done

wants() {
  [[ -z "$ONLY" ]] && return 0
  [[ ",$ONLY," == *",$1,"* ]]
}

for id in ${ONLY//,/ }; do
  case "$id" in
    flutter|serverpod_cli|opencode|git|llvm-tools) ;;
    *) echo "Unknown tool in --only: $id" >&2; usage; exit 1 ;;
  esac
done

# A version not given on the command line falls back to what active.json
# already pins, then to this script's default for a tree that was never built.
# That covers tools left out of --only — a partial run cannot rewrite a pin for
# a tree it never touched — and equally a selected tool run without its version
# flag: `--only=flutter --force` rebuilds the *pinned* Flutter rather than
# silently re-pinning whatever default this script was last written with.
pinned() {
  local key="$1"
  [[ -f "$OUT_DIR/active.json" ]] || return 1
  python3 -c "import json;print(json.load(open('$OUT_DIR/active.json')).get('$1',''))" \
    2>/dev/null | grep . || return 1
}

given() { [[ ",$EXPLICIT," == *",$1,"* ]]; }

given flutter       || FLUTTER_VERSION="$(pinned flutter || echo "$FLUTTER_VERSION")"
given serverpod_cli || SERVERPOD_CLI_VERSION="$(pinned serverpod_cli || echo "$SERVERPOD_CLI_VERSION")"
given opencode      || OPENCODE_VERSION="$(pinned opencode || echo "$OPENCODE_VERSION")"
given git           || GIT_VERSION="$(pinned git || echo "$GIT_VERSION")"
given llvm-tools    || LLVM_VERSION="$(pinned llvm_tools || echo "$LLVM_VERSION")"

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64)
    ARCHIVE_NAME="flutter_macos_arm64_${FLUTTER_VERSION}-stable.zip"
    DUGITE_ARCH="arm64"
    ;;
  x86_64)
    echo "OpenCode bundling is arm64-only. Run on Apple Silicon to download opencode." >&2
    ARCHIVE_NAME="flutter_macos_${FLUTTER_VERSION}-stable.zip"
    DUGITE_ARCH="x64"
    ;;
  *)
    echo "Unsupported architecture: $HOST_ARCH" >&2
    exit 1
    ;;
esac

FLUTTER_DIR="$OUT_DIR/flutter/$FLUTTER_VERSION"
SERVERPOD_DIR="$OUT_DIR/serverpod_cli/$SERVERPOD_CLI_VERSION"
OPENCODE_DIR="$OUT_DIR/opencode/$OPENCODE_VERSION"
GIT_DIR="$OUT_DIR/git/$GIT_VERSION"
BIN_DIR="$OUT_DIR/bin"
DOWNLOAD_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/${ARCHIVE_NAME}"
OPENCODE_URL="https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-darwin-arm64.zip"
DUGITE_TAG="v${GIT_VERSION}"

LLVM_DIR="$OUT_DIR/llvm-tools/$LLVM_VERSION"
LLVM_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/LLVM-${LLVM_VERSION}-macOS-ARM64.tar.xz"

echo "==> Bundling toolchain into $OUT_DIR"
echo "    Flutter $FLUTTER_VERSION ($HOST_ARCH) — full SDK, precached for web"
echo "    serverpod_cli $SERVERPOD_CLI_VERSION — full prebuilt bundle"
echo "    opencode $OPENCODE_VERSION — darwin-arm64 only"
echo "    git $GIT_VERSION — dugite-native macOS-${DUGITE_ARCH}"
echo "    llvm-tools $LLVM_VERSION — otool + install_name_tool (no CLT stubs, no Xcode)"

mkdir -p "$OUT_DIR"

# There is no download for the Serverpod CLI — pub does not publish a macOS
# archive — so the toolchain copy is taken from what `dart install` unpacked on
# this Mac. That is the same bundle the release engineer already runs.
DART_APP_BUNDLES="$HOME/Library/Application Support/Dart/install/app-bundles"

stage_serverpod_from_local_install() {
  local src="$DART_APP_BUNDLES/serverpod_cli/hosted/$SERVERPOD_CLI_VERSION/bundle"
  if [[ ! -x "$src/bin/serverpod" || ! -d "$src/lib" ]]; then
    echo "No local Serverpod CLI $SERVERPOD_CLI_VERSION to copy from." >&2
    echo "  expected: $src/{bin,lib}" >&2
    echo "Install it first, then re-run:" >&2
    echo "  dart install serverpod_cli $SERVERPOD_CLI_VERSION" >&2
    exit 1
  fi

  echo "==> Copying Serverpod CLI $SERVERPOD_CLI_VERSION from the local install"
  echo "    $src"
  rm -rf "$SERVERPOD_DIR"
  mkdir -p "$SERVERPOD_DIR"
  # ditto, not cp -R: it carries the code signature and the exec bits across
  # intact, and the published archive is signature-verified on the far end.
  ditto "$src/bin" "$SERVERPOD_DIR/bin"
  ditto "$src/lib" "$SERVERPOD_DIR/lib"
  # The version directory is tracked in git even though its contents are not,
  # so the tree exists in a fresh clone.
  : > "$SERVERPOD_DIR/.gitkeep"

  # The install path carries a version but the binary is the authority. Without
  # this check a mistyped --serverpod publishes an archive whose name, pin and
  # manifest entry all disagree with what is inside it.
  local reported
  reported="$("$SERVERPOD_DIR/bin/serverpod" --version 2>/dev/null | head -1 || true)"
  if [[ "$reported" != *"$SERVERPOD_CLI_VERSION"* ]]; then
    echo "Copied CLI reports '$reported', expected $SERVERPOD_CLI_VERSION" >&2
    exit 1
  fi
  echo "    $reported"
}

if wants serverpod_cli; then
  if [[ -x "$SERVERPOD_DIR/bin/serverpod" && -d "$SERVERPOD_DIR/lib" && "$FORCE" != "1" ]]; then
    echo "==> Serverpod CLI $SERVERPOD_CLI_VERSION already present (pass --force to recopy)"
  else
    stage_serverpod_from_local_install
  fi
fi

if ! wants flutter; then
  echo "==> Skipping Flutter (not selected); keeping pinned $FLUTTER_VERSION"
elif [[ -x "$FLUTTER_DIR/bin/flutter" && "$FORCE" != "1" ]]; then
  echo "==> Flutter $FLUTTER_VERSION already present (pass --force to redownload)"
else
  TMP_DIR="$(mktemp -d)"
  cleanup() { rm -rf "$TMP_DIR"; }
  trap cleanup EXIT
  ARCHIVE_PATH="$TMP_DIR/$ARCHIVE_NAME"
  echo "==> Downloading $DOWNLOAD_URL"
  curl -fL --progress-bar -o "$ARCHIVE_PATH" "$DOWNLOAD_URL"
  echo "==> Extracting Flutter SDK"
  rm -rf "$FLUTTER_DIR"
  mkdir -p "$OUT_DIR/flutter"
  unzip -q "$ARCHIVE_PATH" -d "$TMP_DIR/extract"
  mv "$TMP_DIR/extract/flutter" "$FLUTTER_DIR"
  cleanup
  trap - EXIT
fi

export FLUTTER_ROOT="$FLUTTER_DIR"
export PATH="$FLUTTER_DIR/bin:$PATH"

precache_flutter_web() {
  echo "==> Precaching web artifacts"
  (
    cd "$FLUTTER_DIR"
    # Do not run `flutter config --no-enable-*` — those write global user settings.
    flutter precache --web
  )
}

if wants flutter; then
  precache_flutter_web
  echo "==> Ensuring flutter_tools snapshot stays valid on other Macs"
  bash "$ROOT_DIR/tool/ensure_flutter_tools_cache.sh" "$FLUTTER_DIR"
fi

# Portable Git (avoids Apple's /usr/bin/git CLT stub on target Macs)
if ! wants git; then
  echo "==> Skipping Git (not selected); keeping pinned $GIT_VERSION"
elif [[ -x "$GIT_DIR/bin/git" && "$FORCE" != "1" ]]; then
  echo "==> Git $GIT_VERSION already present (pass --force to redownload)"
else
  TMP_DIR="$(mktemp -d)"
  cleanup_git() { rm -rf "$TMP_DIR"; }
  trap cleanup_git EXIT
  echo "==> Resolving dugite-native asset for $DUGITE_TAG (macOS-${DUGITE_ARCH})"
  DUGITE_URL="$(
    python3 - "$DUGITE_TAG" "$DUGITE_ARCH" <<'PY'
import json, sys, urllib.request
tag, arch = sys.argv[1], sys.argv[2]
url = f"https://api.github.com/repos/desktop/dugite-native/releases/tags/{tag}"
with urllib.request.urlopen(url) as resp:
    data = json.load(resp)
needle = f"-macOS-{arch}.tar.gz"
for asset in data.get("assets", []):
    name = asset.get("name", "")
    if name.endswith(needle) and not name.endswith(".sha256"):
        print(asset["browser_download_url"])
        raise SystemExit(0)
raise SystemExit(f"No dugite-native asset matching *{needle} for {tag}")
PY
  )"
  echo "==> Downloading $DUGITE_URL"
  curl -fL --progress-bar -o "$TMP_DIR/git.tar.gz" "$DUGITE_URL"
  echo "==> Extracting portable Git"
  rm -rf "$GIT_DIR"
  mkdir -p "$GIT_DIR"
  tar -xzf "$TMP_DIR/git.tar.gz" -C "$GIT_DIR"
  if [[ ! -x "$GIT_DIR/bin/git" ]]; then
    echo "Could not find bin/git in dugite-native archive" >&2
    exit 1
  fi
  chmod +x "$GIT_DIR/bin/git"
  cleanup_git
  trap - EXIT
fi

# OpenCode: darwin-arm64 only
if ! wants opencode; then
  echo "==> Skipping OpenCode (not selected); keeping pinned $OPENCODE_VERSION"
elif [[ "$HOST_ARCH" != "arm64" ]]; then
  echo "==> Skipping OpenCode download (arm64 hosts only)"
elif [[ -x "$OPENCODE_DIR/opencode" && "$FORCE" != "1" ]]; then
  echo "==> OpenCode $OPENCODE_VERSION already present (pass --force to redownload)"
else
  TMP_DIR="$(mktemp -d)"
  cleanup_oc() { rm -rf "$TMP_DIR"; }
  trap cleanup_oc EXIT
  echo "==> Downloading $OPENCODE_URL"
  curl -fL --progress-bar -o "$TMP_DIR/opencode.zip" "$OPENCODE_URL"
  echo "==> Extracting OpenCode"
  unzip -q "$TMP_DIR/opencode.zip" -d "$TMP_DIR/extract"
  BIN="$(find "$TMP_DIR/extract" -type f -name opencode | head -1)"
  if [[ -z "$BIN" || ! -f "$BIN" ]]; then
    echo "Could not find opencode binary in archive" >&2
    exit 1
  fi
  rm -rf "$OPENCODE_DIR"
  mkdir -p "$OPENCODE_DIR"
  cp "$BIN" "$OPENCODE_DIR/opencode"
  chmod +x "$OPENCODE_DIR/opencode"
  cleanup_oc
  trap - EXIT
fi

# otool + install_name_tool, from an official LLVM release rather than Xcode.
#
# Copying Apple's binaries out of Xcode is restricted by its licence, and
# publishing them to a public bucket would be plain redistribution. LLVM's are
# verified drop-ins: `llvm-otool -D` output is byte-identical to Apple's, and
# although llvm-install-name-tool does not re-sign after editing a Mach-O
# (Apple's does, via libcodedirectory.dylib), Serverpod runs `codesign` on the
# very next line — so that difference does not matter here.
#
# Both are argv[0]-dispatching aliases, so they are installed under the Apple
# names and behave accordingly.
if ! wants llvm-tools; then
  echo "==> Skipping llvm-tools (not selected); keeping pinned $LLVM_VERSION"
elif [[ -x "$LLVM_DIR/bin/otool" && -x "$LLVM_DIR/bin/install_name_tool" && "$FORCE" != "1" ]]; then
  echo "==> llvm-tools already present (pass --force to re-download)"
else
  echo "==> Downloading LLVM $LLVM_VERSION (~1.4 GB, for two binaries)"
  LLVM_TMP="$(mktemp -d)"
  curl -fL --retry 3 --progress-bar -o "$LLVM_TMP/llvm.tar.xz" "$LLVM_URL"

  PREFIX="LLVM-${LLVM_VERSION}-macOS-ARM64"
  tar -xJf "$LLVM_TMP/llvm.tar.xz" -C "$LLVM_TMP" --strip-components=2 \
    "$PREFIX/bin/llvm-objdump" "$PREFIX/bin/llvm-objcopy"

  rm -rf "$LLVM_DIR"
  mkdir -p "$LLVM_DIR/bin"
  # Installed under Apple's names: both binaries switch behaviour on argv[0].
  cp "$LLVM_TMP/llvm-objdump" "$LLVM_DIR/bin/otool"
  cp "$LLVM_TMP/llvm-objcopy" "$LLVM_DIR/bin/install_name_tool"
  chmod +x "$LLVM_DIR/bin/otool" "$LLVM_DIR/bin/install_name_tool"
  rm -rf "$LLVM_TMP"
fi

echo "==> Writing active.json, pins, and bin wrappers"
mkdir -p "$BIN_DIR" "$OUT_DIR/pins"
cat > "$OUT_DIR/active.json" <<EOF
{
  "flutter": "$FLUTTER_VERSION",
  "serverpod_cli": "$SERVERPOD_CLI_VERSION",
  "opencode": "$OPENCODE_VERSION",
  "git": "$GIT_VERSION",
  "llvm_tools": "$LLVM_VERSION"
}
EOF

# Plain pin files — wrappers must NOT use python3/jq. On Macs without Xcode
# CLT, /usr/bin/python3 is a stub that triggers "No developer tools found".
printf '%s\n' "$FLUTTER_VERSION" > "$OUT_DIR/pins/flutter"
printf '%s\n' "$SERVERPOD_CLI_VERSION" > "$OUT_DIR/pins/serverpod_cli"
printf '%s\n' "$OPENCODE_VERSION" > "$OUT_DIR/pins/opencode"
printf '%s\n' "$GIT_VERSION" > "$OUT_DIR/pins/git"
printf '%s\n' "$LLVM_VERSION" > "$OUT_DIR/pins/llvm_tools"

# Shared env preamble for wrappers (bash only — no python).
# Puts llvm-tools + portable git FIRST on PATH; pins Flutter engine version.
read -r -d '' WRAPPER_ENV <<'EOF' || true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER_VER="$(tr -d '[:space:]' < "$ROOT/pins/flutter")"
GIT_VER="$(tr -d '[:space:]' < "$ROOT/pins/git" 2>/dev/null || true)"
LLVM_VER="$(tr -d '[:space:]' < "$ROOT/pins/llvm_tools" 2>/dev/null || true)"
export FLUTTER_ROOT="$ROOT/flutter/$FLUTTER_VER"
ENGINE_VERSION_FILE="$FLUTTER_ROOT/bin/internal/engine.version"
if [[ -f "$ENGINE_VERSION_FILE" ]]; then
  export FLUTTER_PREBUILT_ENGINE_VERSION="$(tr -d '[:space:]' < "$ENGINE_VERSION_FILE")"
fi
if [[ -d "$FLUTTER_ROOT/bin/cache/dart-sdk" ]]; then
  export DART_SDK="$FLUTTER_ROOT/bin/cache/dart-sdk"
fi
export PATH="$FLUTTER_ROOT/bin:$PATH"
GIT_HOME=""
if [[ -n "$GIT_VER" && -x "$ROOT/git/$GIT_VER/bin/git" ]]; then
  GIT_HOME="$ROOT/git/$GIT_VER"
  if [[ -d "$GIT_HOME/libexec/git-core" ]]; then
    export GIT_EXEC_PATH="$GIT_HOME/libexec/git-core"
  fi
  export PATH="$GIT_HOME/bin:$PATH"
fi
# Real otool / install_name_tool ahead of /usr/bin CLT stubs. Read from the pin
# at runtime like flutter and git — this heredoc is quoted, so a generation-time
# variable would land in the wrapper unexpanded and die under `set -u`.
if [[ -n "$LLVM_VER" && -x "$ROOT/llvm-tools/$LLVM_VER/bin/otool" ]]; then
  export PATH="$ROOT/llvm-tools/$LLVM_VER/bin:$PATH"
fi
EOF

cat > "$BIN_DIR/flutter" <<EOF
#!/usr/bin/env bash
set -euo pipefail
$WRAPPER_ENV
exec "\$FLUTTER_ROOT/bin/flutter" "\$@"
EOF

cat > "$BIN_DIR/dart" <<EOF
#!/usr/bin/env bash
set -euo pipefail
$WRAPPER_ENV
exec "\$FLUTTER_ROOT/bin/dart" "\$@"
EOF

cat > "$BIN_DIR/serverpod" <<EOF
#!/usr/bin/env bash
set -euo pipefail
$WRAPPER_ENV
CLI_VER="\$(tr -d '[:space:]' < "\$ROOT/pins/serverpod_cli")"
CLI_HOME="\$ROOT/serverpod_cli/\$CLI_VER"
SERVERPOD="\$CLI_HOME/bin/serverpod"
# Ensure sqlite dylibs from the full CLI bundle are loadable.
export DYLD_LIBRARY_PATH="\$CLI_HOME/lib\${DYLD_LIBRARY_PATH:+:\$DYLD_LIBRARY_PATH}"
export PATH="\$CLI_HOME/bin:\$PATH"
# Keep portable tools ahead of /usr/bin after CLI prepend.
if [[ -n "\${GIT_HOME:-}" ]]; then
  export PATH="\$GIT_HOME/bin:\$PATH"
fi
if [[ -n "\${LLVM_VER:-}" && -x "\$ROOT/llvm-tools/\$LLVM_VER/bin/otool" ]]; then
  export PATH="\$ROOT/llvm-tools/\$LLVM_VER/bin:\$PATH"
fi
exec "\$SERVERPOD" "\$@"
EOF

cat > "$BIN_DIR/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OC_VER="$(tr -d '[:space:]' < "$ROOT/pins/opencode")"
if [[ -z "$OC_VER" ]]; then
  echo "opencode pin missing at $ROOT/pins/opencode" >&2
  exit 1
fi
exec "$ROOT/opencode/$OC_VER/opencode" "$@"
EOF

# Thin wrapper around the versioned dugite binary (not a copy of git).
cat > "$BIN_DIR/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GIT_VER="$(tr -d '[:space:]' < "$ROOT/pins/git")"
GIT_HOME="$ROOT/git/$GIT_VER"
if [[ ! -x "$GIT_HOME/bin/git" ]]; then
  echo "bundled git missing at $GIT_HOME/bin/git" >&2
  exit 1
fi
if [[ -d "$GIT_HOME/libexec/git-core" ]]; then
  export GIT_EXEC_PATH="$GIT_HOME/libexec/git-core"
fi
exec "$GIT_HOME/bin/git" "$@"
EOF

chmod +x "$BIN_DIR/flutter" "$BIN_DIR/dart" "$BIN_DIR/serverpod" "$BIN_DIR/opencode" "$BIN_DIR/git"

# Every check is guarded: a --only run leaves the other trees untouched, and
# they may legitimately not be here at all.
#
# Output is captured before it is trimmed, never piped straight into `head`.
# `head` closes the pipe on its Nth line, and `flutter --version` prints more
# than that — the SIGPIPE surfaces as a Dart stack trace and, under `pipefail`,
# as a failed run of an otherwise perfectly good toolchain.
show() {
  local lines="$1"; shift
  local out
  out="$("$@" 2>/dev/null || true)"
  [[ -n "$out" ]] && printf '%s\n' "$out" | head -"$lines"
  return 0
}

# Only what this run actually built is exercised. Running a tool writes to its
# own tree — `flutter --version` alone rewrites several files under bin/cache —
# and publish_toolchain.sh recognises an unchanged archive by its hash, so
# verifying an untouched Flutter here would cost it a fresh build number and a
# 673 MB upload on the next publish, for nothing.
echo "==> Verifying"
if wants serverpod_cli && [[ -x "$SERVERPOD_DIR/bin/serverpod" ]]; then
  show 3 "$BIN_DIR/serverpod" --version
fi
if wants git && [[ -x "$GIT_DIR/bin/git" ]]; then
  show 1 "$BIN_DIR/git" --version
fi
if wants llvm-tools && [[ -x "$LLVM_DIR/bin/otool" ]] \
    && [[ -f "$SERVERPOD_DIR/lib/libsqlite3_connection_pool.dylib" ]]; then
  show 2 env PATH="$LLVM_DIR/bin:/usr/bin:/bin" "$LLVM_DIR/bin/otool" -D \
    "$SERVERPOD_DIR/lib/libsqlite3_connection_pool.dylib"
fi
if wants flutter && [[ -x "$BIN_DIR/flutter" && -x "$FLUTTER_DIR/bin/flutter" ]]; then
  show 3 "$BIN_DIR/flutter" --version
fi
if wants opencode && [[ -x "$OPENCODE_DIR/opencode" ]]; then
  show 3 "$BIN_DIR/opencode" --version
fi

echo "==> Done"
echo "    active: flutter=$FLUTTER_VERSION serverpod_cli=$SERVERPOD_CLI_VERSION opencode=$OPENCODE_VERSION git=$GIT_VERSION"
echo "    serverpod bundle: $SERVERPOD_DIR/{bin,lib}"
echo "    llvm-tools: $LLVM_DIR/bin"
du -sh "$OUT_DIR" "$SERVERPOD_DIR" "$FLUTTER_DIR" "$OPENCODE_DIR" "$GIT_DIR" "$LLVM_DIR" 2>/dev/null || true
