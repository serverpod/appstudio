#!/usr/bin/env bash
# Copy project toolchain/ into a built .app bundle.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-}"
SRC="${2:-$ROOT_DIR/toolchain}"

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Usage: $0 /path/to/App.app [toolchain_dir]" >&2
  exit 1
fi

if [[ ! -d "$SRC" ]]; then
  echo "error: toolchain not found at $SRC" >&2
  exit 1
fi

if [[ ! -f "$SRC/active.json" ]]; then
  echo "error: toolchain missing active.json at $SRC" >&2
  exit 1
fi

CLI_VER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["serverpod_cli"])' "$SRC/active.json")"
if [[ ! -x "$SRC/serverpod_cli/$CLI_VER/bin/serverpod" ]]; then
  echo "error: missing $SRC/serverpod_cli/$CLI_VER/bin/serverpod" >&2
  exit 1
fi
if [[ ! -d "$SRC/serverpod_cli/$CLI_VER/lib" ]]; then
  echo "error: missing $SRC/serverpod_cli/$CLI_VER/lib (full CLI bundle required)" >&2
  exit 1
fi
if [[ ! -x "$SRC/cctools/bin/otool" || ! -x "$SRC/cctools/bin/install_name_tool" ]]; then
  echo "error: missing cctools (otool / install_name_tool). Run ./tool/bundle_toolchain.sh" >&2
  exit 1
fi

DEST="$APP_PATH/Contents/Resources/toolchain"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"

echo "==> Embedding toolchain ($(du -sh "$SRC" | cut -f1)) → $DEST"
# ditto is more reliable than rsync for large macOS trees under memory pressure.
ditto "$SRC" "$DEST"

# Re-normalize flutter_tools cache after copy — archive extract can invert
# pubspec.yaml / pubspec.lock mtimes and force a broken rebuild on the target.
FLUTTER_VER="$(
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["flutter"])' \
    "$DEST/active.json"
)"
# Prefer embedded git for rev-parse (matches runtime on CLT-less Macs).
GIT_VER="$(
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("git",""))' \
    "$DEST/active.json"
)"
if [[ -n "$GIT_VER" && -x "$DEST/git/$GIT_VER/bin/git" ]]; then
  export PATH="$DEST/git/$GIT_VER/bin:$PATH"
  if [[ -d "$DEST/git/$GIT_VER/libexec/git-core" ]]; then
    export GIT_EXEC_PATH="$DEST/git/$GIT_VER/libexec/git-core"
  fi
fi
bash "$ROOT_DIR/tool/ensure_flutter_tools_cache.sh" "$DEST/flutter/$FLUTTER_VER"

echo "==> Embedded toolchain"
