#!/usr/bin/env bash
# Release-build, codesign, optional notarize, and package a DMG.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SKIP_BUNDLE_CHECK="${SKIP_BUNDLE_CHECK:-0}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist/macos}"
TOOLCHAIN_DIR="$ROOT_DIR/toolchain"

if [[ "$SKIP_BUNDLE_CHECK" != "1" ]]; then
  if [[ ! -f "$TOOLCHAIN_DIR/active.json" ]]; then
    echo "Bundled toolchain missing. Run ./tool/bundle_toolchain.sh first," >&2
    echo "or set SKIP_BUNDLE_CHECK=1 to continue with host toolchain." >&2
    exit 1
  fi
  CLI_VER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["serverpod_cli"])' "$TOOLCHAIN_DIR/active.json")"
  if [[ ! -x "$TOOLCHAIN_DIR/serverpod_cli/$CLI_VER/bin/serverpod" || ! -d "$TOOLCHAIN_DIR/serverpod_cli/$CLI_VER/lib" ]]; then
    echo "Serverpod CLI bundle incomplete. Need:" >&2
    echo "  $TOOLCHAIN_DIR/serverpod_cli/$CLI_VER/bin/serverpod" >&2
    echo "  $TOOLCHAIN_DIR/serverpod_cli/$CLI_VER/lib/" >&2
    exit 1
  fi
fi

echo "==> Building macOS release (host arch)"
export CEF_WRAPPER_BUILD_TYPE=Release
flutter build macos --release

APP_PATH="$(find "$ROOT_DIR/build/macos/Build/Products/Release" -maxdepth 1 -name '*.app' | head -n 1)"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Release .app not found under build/macos/Build/Products/Release" >&2
  exit 1
fi

echo "==> App: $APP_PATH"

# Ensure toolchain is inside the app (Embed phase should have done this).
if [[ -f "$TOOLCHAIN_DIR/active.json" ]]; then
  DEST_TC="$APP_PATH/Contents/Resources/toolchain"
  mkdir -p "$(dirname "$DEST_TC")"
  rsync -a --delete "$TOOLCHAIN_DIR/" "$DEST_TC/"
fi

sign_item() {
  local path="$1"
  if [[ -z "$SIGN_IDENTITY" ]]; then
    return 0
  fi
  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT_DIR/macos/Runner/Release.entitlements" \
    --sign "$SIGN_IDENTITY" \
    "$path"
}

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Codesigning nested binaries (identity: $SIGN_IDENTITY)"
  # Deepest-first: toolchain executables, then CEF helpers/frameworks, then app.
  if [[ -d "$APP_PATH/Contents/Resources/toolchain" ]]; then
    find "$APP_PATH/Contents/Resources/toolchain" \
      \( -type f -perm -111 -o -name '*.dylib' -o -name '*.so' \) \
      -print0 | while IFS= read -r -d '' f; do
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$f" || true
      done
  fi

  if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
    find "$APP_PATH/Contents/Frameworks" -name '*.app' -print0 \
      | while IFS= read -r -d '' helper; do
          codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$helper"
        done
    find "$APP_PATH/Contents/Frameworks" -name '*.framework' -print0 \
      | while IFS= read -r -d '' fw; do
          codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$fw"
        done
  fi

  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT_DIR/macos/Runner/Release.entitlements" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"

  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
else
  echo "==> SIGN_IDENTITY not set — skipping codesign"
fi

mkdir -p "$DIST_DIR"
APP_NAME="$(basename "$APP_PATH" .app)"
DMG_PATH="$DIST_DIR/${APP_NAME}-$(uname -m).dmg"
rm -f "$DMG_PATH"

echo "==> Creating DMG $DMG_PATH"
STAGE="$(mktemp -d)"
cp -R "$APP_PATH" "$STAGE/"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGE"

if [[ "$NOTARIZE" == "1" ]]; then
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "NOTARIZE=1 requires SIGN_IDENTITY" >&2
    exit 1
  fi
  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "NOTARIZE=1 requires NOTARY_PROFILE (notarytool keychain profile)" >&2
    exit 1
  fi
  echo "==> Submitting for notarization"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  xcrun stapler staple "$DMG_PATH"
  echo "==> Notarization complete"
else
  echo "==> Skipping notarization (set NOTARIZE=1 later when ready)"
fi

echo "==> Dist artifacts in $DIST_DIR"
ls -lh "$DIST_DIR"
