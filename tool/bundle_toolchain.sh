#!/usr/bin/env bash
# Download a web-focused Flutter SDK into the project toolchain/.
# Expects a prebuilt Serverpod CLI bundle already at:
#   toolchain/serverpod_cli/<version>/{bin,lib}
# Downloads OpenCode CLI (darwin-arm64 only) into:
#   toolchain/opencode/<version>/opencode
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/toolchain}"
FLUTTER_VERSION="${FLUTTER_VERSION:-3.44.2}"
SERVERPOD_CLI_VERSION="${SERVERPOD_CLI_VERSION:-4.0.0-beta.0}"
OPENCODE_VERSION="${OPENCODE_VERSION:-1.18.4}"
FORCE="${FORCE:-0}"

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --flutter=*) FLUTTER_VERSION="${arg#*=}" ;;
    --serverpod=*) SERVERPOD_CLI_VERSION="${arg#*=}" ;;
    --opencode=*) OPENCODE_VERSION="${arg#*=}" ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--force] [--flutter=VERSION] [--serverpod=VERSION] [--opencode=VERSION]" >&2
      exit 1
      ;;
  esac
done

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64) ARCHIVE_NAME="flutter_macos_arm64_${FLUTTER_VERSION}-stable.zip" ;;
  x86_64)
    echo "OpenCode bundling is arm64-only. Run on Apple Silicon to download opencode." >&2
    ARCHIVE_NAME="flutter_macos_${FLUTTER_VERSION}-stable.zip"
    ;;
  *)
    echo "Unsupported architecture: $HOST_ARCH" >&2
    exit 1
    ;;
esac

FLUTTER_DIR="$OUT_DIR/flutter/$FLUTTER_VERSION"
SERVERPOD_DIR="$OUT_DIR/serverpod_cli/$SERVERPOD_CLI_VERSION"
OPENCODE_DIR="$OUT_DIR/opencode/$OPENCODE_VERSION"
BIN_DIR="$OUT_DIR/bin"
DOWNLOAD_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/${ARCHIVE_NAME}"
OPENCODE_URL="https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-darwin-arm64.zip"

echo "==> Bundling toolchain into $OUT_DIR"
echo "    Flutter $FLUTTER_VERSION ($HOST_ARCH) — strip other platforms only"
echo "    serverpod_cli $SERVERPOD_CLI_VERSION — full prebuilt bundle"
echo "    opencode $OPENCODE_VERSION — darwin-arm64 only"

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

echo "==> Writing active.json and bin wrappers"
mkdir -p "$BIN_DIR"
cat > "$OUT_DIR/active.json" <<EOF
{
  "flutter": "$FLUTTER_VERSION",
  "serverpod_cli": "$SERVERPOD_CLI_VERSION",
  "opencode": "$OPENCODE_VERSION"
}
EOF

cat > "$BIN_DIR/flutter" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTIVE="$ROOT/active.json"
FLUTTER_VER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["flutter"])' "$ACTIVE")"
export FLUTTER_ROOT="$ROOT/flutter/$FLUTTER_VER"
export PATH="$FLUTTER_ROOT/bin:$PATH"
exec "$FLUTTER_ROOT/bin/flutter" "$@"
EOF

cat > "$BIN_DIR/dart" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTIVE="$ROOT/active.json"
FLUTTER_VER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["flutter"])' "$ACTIVE")"
export FLUTTER_ROOT="$ROOT/flutter/$FLUTTER_VER"
export PATH="$FLUTTER_ROOT/bin:$PATH"
exec "$FLUTTER_ROOT/bin/dart" "$@"
EOF

cat > "$BIN_DIR/serverpod" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTIVE="$ROOT/active.json"
FLUTTER_VER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["flutter"])' "$ACTIVE")"
CLI_VER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["serverpod_cli"])' "$ACTIVE")"
export FLUTTER_ROOT="$ROOT/flutter/$FLUTTER_VER"
CLI_HOME="$ROOT/serverpod_cli/$CLI_VER"
SERVERPOD="$CLI_HOME/bin/serverpod"
# Ensure sqlite dylibs from the full CLI bundle are loadable.
export DYLD_LIBRARY_PATH="$CLI_HOME/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export PATH="$FLUTTER_ROOT/bin:$CLI_HOME/bin:$PATH"
exec "$SERVERPOD" "$@"
EOF

cat > "$BIN_DIR/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTIVE="$ROOT/active.json"
OC_VER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("opencode",""))' "$ACTIVE")"
if [[ -z "$OC_VER" ]]; then
  echo "opencode version missing from active.json" >&2
  exit 1
fi
exec "$ROOT/opencode/$OC_VER/opencode" "$@"
EOF

chmod +x "$BIN_DIR/flutter" "$BIN_DIR/dart" "$BIN_DIR/serverpod" "$BIN_DIR/opencode"

echo "==> Verifying"
"$BIN_DIR/serverpod" --version | head -3
if [[ -x "$BIN_DIR/flutter" && -x "$FLUTTER_DIR/bin/flutter" ]]; then
  "$BIN_DIR/flutter" --version | head -3
fi
if [[ -x "$BIN_DIR/opencode" ]]; then
  "$BIN_DIR/opencode" --version | head -3
fi

echo "==> Done"
echo "    active: flutter=$FLUTTER_VERSION serverpod_cli=$SERVERPOD_CLI_VERSION opencode=$OPENCODE_VERSION"
echo "    serverpod bundle: $SERVERPOD_DIR/{bin,lib}"
du -sh "$OUT_DIR" "$SERVERPOD_DIR" "$FLUTTER_DIR" "$OPENCODE_DIR" 2>/dev/null || true
