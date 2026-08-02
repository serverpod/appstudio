#!/usr/bin/env bash
# Download a web-focused Flutter SDK into the project toolchain/.
# Expects a prebuilt Serverpod CLI bundle already at:
#   toolchain/serverpod_cli/<version>/{bin,lib}
# Downloads OpenCode CLI (darwin-arm64 only) into:
#   toolchain/opencode/<version>/opencode
# Downloads portable Git (dugite-native) into:
#   toolchain/git/<version>/{bin,libexec,...}
# Copies real otool + install_name_tool from the build Mac's Xcode into:
#   toolchain/llvm-tools/<version>/bin
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/toolchain}"
FLUTTER_VERSION="${FLUTTER_VERSION:-3.44.2}"
SERVERPOD_CLI_VERSION="${SERVERPOD_CLI_VERSION:-4.0.0-beta.1}"
OPENCODE_VERSION="${OPENCODE_VERSION:-1.18.4}"
# dugite-native release tag without leading "v" (GitHub Desktop portable Git).
GIT_VERSION="${GIT_VERSION:-2.53.0-3}"
# Official LLVM release: llvm-otool / llvm-install-name-tool are
# Apache-2.0 WITH LLVM-exception, so redistribution is unambiguous.
LLVM_VERSION="${LLVM_VERSION:-20.1.8}"
FORCE="${FORCE:-0}"

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --flutter=*) FLUTTER_VERSION="${arg#*=}" ;;
    --serverpod=*) SERVERPOD_CLI_VERSION="${arg#*=}" ;;
    --opencode=*) OPENCODE_VERSION="${arg#*=}" ;;
    --git=*) GIT_VERSION="${arg#*=}" ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--force] [--flutter=VERSION] [--serverpod=VERSION] [--opencode=VERSION] [--git=VERSION]" >&2
      exit 1
      ;;
  esac
done

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
echo "    Flutter $FLUTTER_VERSION ($HOST_ARCH) — strip other platforms only"
echo "    serverpod_cli $SERVERPOD_CLI_VERSION — full prebuilt bundle"
echo "    opencode $OPENCODE_VERSION — darwin-arm64 only"
echo "    git $GIT_VERSION — dugite-native macOS-${DUGITE_ARCH}"
echo "    llvm-tools $LLVM_VERSION — otool + install_name_tool (no CLT stubs, no Xcode)"

mkdir -p "$OUT_DIR"

if [[ ! -x "$SERVERPOD_DIR/bin/serverpod" ]]; then
  echo "Missing Serverpod CLI bundle at:" >&2
  echo "  $SERVERPOD_DIR/bin/serverpod" >&2
  echo "Copy the full dart-install bundle into toolchain/serverpod_cli/<version>/:" >&2
  echo "  bin/serverpod" >&2
  echo "  lib/   (sqlite dylibs, etc.)" >&2
  exit 1
fi
if [[ ! -d "$SERVERPOD_DIR/lib" ]]; then
  echo "Missing Serverpod CLI lib/ directory (sqlite dylibs) at:" >&2
  echo "  $SERVERPOD_DIR/lib" >&2
  exit 1
fi

if [[ -x "$FLUTTER_DIR/bin/flutter" && "$FORCE" != "1" ]]; then
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

echo "==> Precaching web artifacts"
(
  cd "$FLUTTER_DIR"
  # Do not run `flutter config --no-enable-*` — those write global user settings.
  flutter precache --web
)

strip_flutter_for_web() {
  local flutter_dir="$1"
  local cache_dir="$flutter_dir/bin/cache"
  local engine_dir="$cache_dir/artifacts/engine"
  echo "==> Stripping non-macOS / non-web platform artifacts"
  # Keep packages/*, dart-sdk snapshots/resources, DevTools, examples, etc.
  # Only drop other platforms' engine builds and mobile/Android tooling.

  if [[ -d "$engine_dir" ]]; then
    find "$engine_dir" -mindepth 1 -maxdepth 1 | while read -r entry; do
      local base
      base="$(basename "$entry")"
      case "$base" in
        common|darwin-arm64|darwin-x64) ;;
        *)
          echo "    drop engine/$base"
          rm -rf "$entry"
          ;;
      esac
    done
  fi

  rm -rf \
    "$cache_dir/artifacts/ios-deploy" \
    "$cache_dir/artifacts/libimobiledevice" \
    "$cache_dir/artifacts/libimobiledeviceglue" \
    "$cache_dir/artifacts/libplist" \
    "$cache_dir/artifacts/libusbmuxd" \
    "$cache_dir/artifacts/usbmuxd" \
    "$cache_dir/artifacts/gradle_wrapper" \
    "$cache_dir/artifacts/openssl" \
    "$cache_dir/artifacts/flutter-pi" \
    "$cache_dir/downloads" \
    "$flutter_dir/.pub-cache"

  if [[ -d "$flutter_dir/.git" ]]; then
    git -C "$flutter_dir" gc --aggressive --prune=all >/dev/null 2>&1 || true
  fi
}

strip_flutter_for_web "$FLUTTER_DIR"

echo "==> Ensuring flutter_tools snapshot stays valid on other Macs"
bash "$ROOT_DIR/tool/ensure_flutter_tools_cache.sh" "$FLUTTER_DIR"

# Portable Git (avoids Apple's /usr/bin/git CLT stub on target Macs)
if [[ -x "$GIT_DIR/bin/git" && "$FORCE" != "1" ]]; then
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
if [[ "$HOST_ARCH" != "arm64" ]]; then
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
if [[ -x "$LLVM_DIR/bin/otool" && -x "$LLVM_DIR/bin/install_name_tool" && "$FORCE" != "1" ]]; then
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
# Real otool / install_name_tool ahead of /usr/bin CLT stubs.
if [[ -x "$ROOT/llvm-tools/$LLVM_VERSION/bin/otool" ]]; then
  export PATH="$ROOT/llvm-tools/$LLVM_VERSION/bin:$PATH"
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
if [[ -x "\$ROOT/llvm-tools/$LLVM_VERSION/bin/otool" ]]; then
  export PATH="\$ROOT/llvm-tools/\$LLVM_PIN/bin:\$PATH"
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

echo "==> Verifying"
"$BIN_DIR/serverpod" --version | head -3
if [[ -x "$BIN_DIR/git" ]]; then
  "$BIN_DIR/git" --version | head -1
fi
if [[ -x "$LLVM_DIR/bin/otool" ]]; then
  PATH="$LLVM_DIR/bin:/usr/bin:/bin" "$LLVM_DIR/bin/otool" -D \
    "$SERVERPOD_DIR/lib/libsqlite3_connection_pool.dylib" | head -2
fi
if [[ -x "$BIN_DIR/flutter" && -x "$FLUTTER_DIR/bin/flutter" ]]; then
  "$BIN_DIR/flutter" --version | head -3
fi
if [[ -x "$BIN_DIR/opencode" ]]; then
  "$BIN_DIR/opencode" --version | head -3
fi

echo "==> Done"
echo "    active: flutter=$FLUTTER_VERSION serverpod_cli=$SERVERPOD_CLI_VERSION opencode=$OPENCODE_VERSION git=$GIT_VERSION"
echo "    serverpod bundle: $SERVERPOD_DIR/{bin,lib}"
echo "    llvm-tools: $LLVM_DIR/bin"
du -sh "$OUT_DIR" "$SERVERPOD_DIR" "$FLUTTER_DIR" "$OPENCODE_DIR" "$GIT_DIR" "$LLVM_DIR" 2>/dev/null || true
