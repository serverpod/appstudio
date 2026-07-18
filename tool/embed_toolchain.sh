#!/usr/bin/env bash
# Xcode Run Script phase: copy project toolchain/ into the built .app.
set -euo pipefail

# Project-level source of truth (full Flutter + Serverpod CLI bundles).
SRC="${SRCROOT}/../toolchain"
DEST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/toolchain"

# Debug builds use the host toolchain — skip embedding multi-GB SDK.
if [[ "${CONFIGURATION:-}" == "Debug" ]]; then
  echo "note: Debug build — not embedding toolchain (host flutter/dart/serverpod)"
  exit 0
fi

if [[ ! -d "$SRC" ]]; then
  echo "note: toolchain not found at $SRC — using host toolchain at runtime"
  exit 0
fi

if [[ ! -f "$SRC/active.json" ]]; then
  echo "note: toolchain missing active.json — skipping embed"
  exit 0
fi

# Require the full Serverpod CLI bundle (binary + native libs).
CLI_VER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["serverpod_cli"])' "$SRC/active.json")"
if [[ ! -x "$SRC/serverpod_cli/$CLI_VER/bin/serverpod" ]]; then
  echo "error: missing $SRC/serverpod_cli/$CLI_VER/bin/serverpod" >&2
  exit 1
fi
if [[ ! -d "$SRC/serverpod_cli/$CLI_VER/lib" ]]; then
  echo "error: missing $SRC/serverpod_cli/$CLI_VER/lib (full CLI bundle required)" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
# Copy the entire versioned tree, including serverpod lib/ dylibs.
rsync -a --delete "$SRC/" "$DEST/"
echo "Embedded toolchain → $DEST"
