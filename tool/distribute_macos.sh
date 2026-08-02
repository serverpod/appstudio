#!/usr/bin/env bash
# Release-build, codesign, optional notarize, and package a DMG.
#
# Defaults target Serverpod AB Developer ID + notarytool profile "appstudio".
# Override with env vars; set SIGN_IDENTITY="" to skip codesign.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

SIGN_IDENTITY="${SIGN_IDENTITY-Developer ID Application: Serverpod AB (WK2NRY4GS4)}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-appstudio}"
SKIP_BUNDLE_CHECK="${SKIP_BUNDLE_CHECK:-0}"
# Set SKIP_BUILD=1 to re-sign / re-package an existing Release .app (faster notarize retries).
SKIP_BUILD="${SKIP_BUILD:-0}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist/macos}"
APP_PATH="$(find "$ROOT_DIR/build/macos/Build/Products/Release" -maxdepth 1 -name '*.app' | head -n 1 || true)"

if [[ "$SKIP_BUILD" != "1" ]]; then
  echo "==> Building macOS release (host arch)"
  export CEF_WRAPPER_BUILD_TYPE=Release
  flutter build macos --release
  APP_PATH="$(find "$ROOT_DIR/build/macos/Build/Products/Release" -maxdepth 1 -name '*.app' | head -n 1)"
elif [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "SKIP_BUILD=1 but no Release .app found under build/macos/Build/Products/Release" >&2
  exit 1
else
  echo "==> SKIP_BUILD=1 — reusing $APP_PATH"
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Release .app not found under build/macos/Build/Products/Release" >&2
  exit 1
fi

echo "==> App: $APP_PATH"

# Xcode never deletes unknown files under Contents/Resources, so a build tree
# from before the toolchain moved out still carries the old embed — 1.8 GB that
# would be re-signed on every release and shipped in the DMG. Drop it.
STALE_TOOLCHAIN="$APP_PATH/Contents/Resources/toolchain"
if [[ -d "$STALE_TOOLCHAIN" ]]; then
  echo "==> Removing stale embedded toolchain ($(du -sh "$STALE_TOOLCHAIN" | awk '{print $1}'))"
  echo "    The app downloads its tools at runtime; nothing should embed them."
  rm -rf "$STALE_TOOLCHAIN"
fi

# Sign a single path.
# - Main app / helper .apps → Release.entitlements (sandbox off, JIT, network).
# - Other frameworks/dylibs → hardened runtime, no entitlements plist.
#
# The toolchain is no longer nested inside the bundle, so it needs no signing
# from us at all: it lives in ~/Library/Application Support, is written by our
# own downloader (so carries no com.apple.quarantine), and ad-hoc signatures
# execute fine on Apple Silicon.
codesign_one() {
  local path="$1"
  if [[ -z "$SIGN_IDENTITY" ]]; then
    return 0
  fi
  local args=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
  case "$path" in
    *.app)
      args+=(--entitlements "$ROOT_DIR/macos/Runner/Release.entitlements")
      ;;
  esac
  echo "    codesign ${path#"$APP_PATH/"}"
  codesign "${args[@]}" "$path"
}

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Codesigning nested Mach-O binaries (identity: $SIGN_IDENTITY)"
  # Deepest-first so CEF Libraries/*.dylib are signed before the framework.
  # Signing only the .framework bundle does *not* cover Versions/A/Libraries/*
  # (Apple rejected those as ad-hoc / missing timestamp).
  MACH_O_LIST="$(mktemp)"
  python3 - "$APP_PATH" "$MACH_O_LIST" <<'PY'
import os, subprocess, sys
app, out_path = sys.argv[1], sys.argv[2]
skip_ext = {
    ".json", ".plist", ".png", ".jpg", ".jpeg", ".svg", ".txt", ".md", ".html",
    ".css", ".js", ".map", ".pak", ".dat", ".icns", ".nib", ".strings", ".qml",
    ".dart", ".yaml", ".yml", ".lock", ".h", ".c", ".cc", ".cpp", ".m", ".mm",
    ".py", ".sh", ".bat", ".cmake", ".modulemap", ".swiftinterface", ".zip",
    ".gz", ".tgz", ".xz", ".jar", ".class", ".xml", ".ttf", ".otf", ".woff",
}
paths = []
for root, dirs, files in os.walk(app):
    # Don't follow symlinks into shared framework versions twice.
    dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]
    for name in files:
        path = os.path.join(root, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        ext = os.path.splitext(name)[1].lower()
        if ext in skip_ext:
            continue
        try:
            info = subprocess.check_output(["file", "-b", path], text=True)
        except Exception:
            continue
        if "Mach-O" not in info:
            continue
        paths.append(path)
# Deeper paths first.
paths.sort(key=lambda p: (-p.count(os.sep), -len(p), p))
with open(out_path, "w", encoding="utf-8") as f:
    for p in paths:
        f.write(p + "\n")
print(f"    found {len(paths)} Mach-O binaries")
PY

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    codesign_one "$f"
  done < "$MACH_O_LIST"
  rm -f "$MACH_O_LIST"

  echo "==> Codesigning bundle wrappers (helpers, frameworks, app)"
  BUNDLE_LIST="$(mktemp)"
  {
    find "$APP_PATH/Contents/Frameworks" -name '*.app' 2>/dev/null || true
    find "$APP_PATH/Contents/Frameworks" -name '*.framework' 2>/dev/null || true
    printf '%s\n' "$APP_PATH"
  } | python3 -c '
import sys
paths = [l.strip() for l in sys.stdin if l.strip()]
paths.sort(key=lambda p: (-p.count("/"), -len(p), p))
sys.stdout.write("\n".join(paths) + ("\n" if paths else ""))
' > "$BUNDLE_LIST"

  while IFS= read -r bundle; do
    [[ -n "$bundle" ]] || continue
    codesign_one "$bundle"
  done < "$BUNDLE_LIST"
  rm -f "$BUNDLE_LIST"

  echo "==> Verifying signature"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"

  # Spot-check CEF nested libs — these were the notarization failures before.
  # Note: Authority= lines need --verbose=4; TeamIdentifier/Timestamp show with -dv.
  CEF_LIBS="$APP_PATH/Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Libraries"
  if [[ -d "$CEF_LIBS" ]]; then
    for lib in "$CEF_LIBS"/*.dylib; do
      [[ -f "$lib" ]] || continue
      meta="$(codesign -dv "$lib" 2>&1 || true)"
      if ! echo "$meta" | grep -q 'TeamIdentifier=WK2NRY4GS4'; then
        echo "error: CEF lib not Developer ID signed: $lib" >&2
        echo "$meta" >&2
        exit 1
      fi
      if ! echo "$meta" | grep -qi 'Timestamp='; then
        echo "error: CEF lib missing secure timestamp: $lib" >&2
        echo "$meta" >&2
        exit 1
      fi
    done
    echo "==> CEF Libraries/*.dylib Developer ID + timestamp OK"
  fi

else
  echo "==> SIGN_IDENTITY empty — skipping codesign"
  echo "==> On other Macs, run: xattr -cr /Applications/AppStudio.app"
  echo "==> Default identity: Developer ID Application: Serverpod AB (WK2NRY4GS4)"
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
  # --wait can exit 0 even when status is Invalid; parse JSON.
  SUBMIT_JSON="$(mktemp)"
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json | tee "$SUBMIT_JSON"
  STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$SUBMIT_JSON")"
  SUB_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$SUBMIT_JSON")"
  rm -f "$SUBMIT_JSON"
  if [[ "$STATUS" != "Accepted" ]]; then
    echo "error: notarization status=$STATUS (expected Accepted)" >&2
    if [[ -n "$SUB_ID" ]]; then
      echo "==> Notary log for $SUB_ID" >&2
      xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    exit 1
  fi
  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler staple "$DMG_PATH"
  echo "==> Notarization complete"
else
  echo "==> Skipping notarization (set NOTARIZE=1 later when ready)"
fi

echo "==> Dist artifacts in $DIST_DIR"
ls -lh "$DIST_DIR"
