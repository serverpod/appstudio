#!/usr/bin/env bash
# Release-build, codesign, optional notarize, and package a .zip.
#
# A zip, not a DMG: it is the format Sparkle handles best, it needs no
# hdiutil, and the same artifact serves both the human download and the
# updater. `ditto` is mandatory — plain zip mangles the symlinks CEF relies on.
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
  # Settle the generated SPM package BEFORE xcodebuild starts.
  #
  # `flutter build` runs pub get inline when dependencies are stale, and that
  # rewrites Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/
  # Package.swift — while xcodebuild is already resolving packages. xcodebuild
  # then fails with "input file ... was modified during the build". Adding
  # Sparkle made this likelier: resolving a *remote* package takes long enough
  # to overlap the rewrite. Running pub get first makes the in-build
  # regeneration a no-op.
  echo "==> Settling package dependencies"
  flutter pub get

  echo "==> Building macOS release (host arch)"
  export CEF_WRAPPER_BUILD_TYPE=Release

  # Retry exactly once, and only for that race. Any other failure is real and
  # must surface immediately rather than being papered over by a blind retry.
  BUILD_LOG="$(mktemp)"
  if ! flutter build macos --release 2>&1 | tee "$BUILD_LOG"; then
    if grep -q 'was modified during the build' "$BUILD_LOG"; then
      echo "==> Xcode hit the generated-Package.swift race; retrying once" >&2
      rm -f "$BUILD_LOG"
      flutter build macos --release
    else
      rm -f "$BUILD_LOG"
      echo "error: the macOS release build failed (see output above)" >&2
      exit 1
    fi
  fi
  rm -f "$BUILD_LOG"

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

# Xcode leaves the old bundle behind when PRODUCT_NAME changes, so a tree that
# predates the AppStudio → App Studio rename holds two .apps and the `head -1`
# above would pick by sort order. Refuse rather than ship a coin flip.
APP_COUNT="$(find "$ROOT_DIR/build/macos/Build/Products/Release" -maxdepth 1 -name '*.app' | wc -l | tr -d ' ')"
if [[ "$APP_COUNT" != "1" ]]; then
  echo "error: found $APP_COUNT .app bundles under build/macos/Build/Products/Release:" >&2
  find "$ROOT_DIR/build/macos/Build/Products/Release" -maxdepth 1 -name '*.app' >&2
  echo "The build tree is stale. Run 'make clean' first." >&2
  exit 1
fi

echo "==> App: $APP_PATH"

# Xcode never deletes unknown files under Contents/Resources, so a build tree
# from before the toolchain moved out still carries the old embed — 1.8 GB that
# would be re-signed on every release and shipped in the archive. Drop it.
STALE_TOOLCHAIN="$APP_PATH/Contents/Resources/toolchain"
if [[ -d "$STALE_TOOLCHAIN" ]]; then
  echo "==> Removing stale embedded toolchain ($(du -sh "$STALE_TOOLCHAIN" | awk '{print $1}'))"
  echo "    The app downloads its tools at runtime; nothing should embed them."
  rm -rf "$STALE_TOOLCHAIN"
fi

# Strip Sparkle's XPC services HERE, not only in the build phase.
#
# Xcode embeds SPM binary frameworks in an internal step that is not ordered
# after custom build phases, so whenever it re-copies Sparkle the build-phase
# strip is undone — and the next incremental build hides that by skipping the
# copy. Doing it after the build and before signing is the only placement where
# the result cannot be re-copied over.
if [[ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]]; then
  echo "==> Stripping Sparkle XPC services"
  bash "$ROOT_DIR/macos/Runner/Scripts/strip_sparkle_xpc.sh" "$APP_PATH"
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
    # Sparkle's helpers get hardened runtime and nothing else. Handing the
    # process that installs our updates disable-library-validation and
    # allow-unsigned-executable-memory would be backwards.
    *"/Sparkle.framework/"*) ;;
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
    # ! -type l: find matches by NAME, so without it a framework that exposes
    # symlinks like Updater.app or Versions/Current would be "signed" through
    # the symlink, in an order decided by the depth sort. Sparkle's layout does
    # exactly that.
    find "$APP_PATH/Contents/Frameworks" -name '*.app' ! -type l 2>/dev/null || true
    find "$APP_PATH/Contents/Frameworks" -name '*.framework' ! -type l 2>/dev/null || true
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

  # Sparkle installs our updates, so its helpers are the last thing that should
  # ship mis-signed. Versions/*/ rather than a hardcoded Versions/B — the
  # version letter is Sparkle's to change.
  SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$SPARKLE_FW" ]]; then
    # The XPC services exist only for sandboxed hosts and are stripped at build
    # time. If any survived, the wrapper pass never signed them (they match
    # neither *.app nor *.framework) and notarization would reject the bundle.
    if find "$SPARKLE_FW" -name '*.xpc' | grep -q .; then
      echo "error: Sparkle XPC services were not stripped:" >&2
      find "$SPARKLE_FW" -name '*.xpc' >&2
      exit 1
    fi

    for helper in \
      "$SPARKLE_FW"/Versions/*/Autoupdate \
      "$SPARKLE_FW"/Versions/*/Updater.app; do
      [[ -e "$helper" ]] || continue
      meta="$(codesign -dv "$helper" 2>&1 || true)"
      if ! echo "$meta" | grep -q 'TeamIdentifier=WK2NRY4GS4'; then
        echo "error: Sparkle helper not Developer ID signed: $helper" >&2
        echo "$meta" >&2
        exit 1
      fi
      if ! echo "$meta" | grep -qi 'Timestamp='; then
        echo "error: Sparkle helper missing secure timestamp: $helper" >&2
        echo "$meta" >&2
        exit 1
      fi
      # Granting library-validation bypass to the process that replaces our app
      # would defeat the point of signing the update in the first place.
      if codesign -d --entitlements - "$helper" 2>/dev/null \
        | grep -q 'disable-library-validation'; then
        echo "error: Sparkle helper got app entitlements: $helper" >&2
        echo "Check the Sparkle carve-out in codesign_one." >&2
        exit 1
      fi
    done
    echo "==> Sparkle helpers Developer ID + timestamp OK, no XPC services"
  fi

else
  echo "==> SIGN_IDENTITY empty — skipping codesign"
  echo "==> On other Macs, run: xattr -cr \"/Applications/App Studio.app\""
  echo "==> Default identity: Developer ID Application: Serverpod AB (WK2NRY4GS4)"
fi

mkdir -p "$DIST_DIR"

# The bundle is "App Studio.app", but download filenames stay space-free so a
# URL is typeable. Keep the two decoupled deliberately.
DIST_BASENAME="${DIST_BASENAME:-AppStudio}"
ZIP_PATH="$DIST_DIR/${DIST_BASENAME}-$(uname -m).zip"
rm -f "$ZIP_PATH"

# ditto, never `zip`: the CEF framework is full of symlinks and plain zip
# mangles them. --norsrc, because ditto otherwise archives the build machine's
# xattrs (com.apple.provenance and friends) as inline `._foo` AppleDouble
# entries — and Archive Utility extracts those as literal files (it only folds
# the sequestered __MACOSX form back into xattrs), which lands unsealed
# `._*` litter in every framework root and a Gatekeeper-rejected app for
# anyone who unzips by double-clicking in Finder. Safari's auto-extract goes
# through ditto itself, which is the only reason this ever looked fine.
make_zip() {
  rm -f "$ZIP_PATH"
  ditto -c -k --norsrc --keepParent "$APP_PATH" "$ZIP_PATH"
  if unzip -l "$ZIP_PATH" | grep -qE '/\._|__MACOSX'; then
    echo "error: archive carries AppleDouble metadata entries (._*) — these" >&2
    echo "       extract as unsealed files and break Gatekeeper validation" >&2
    exit 1
  fi
}

echo "==> Creating $ZIP_PATH"
make_zip

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
  xcrun notarytool submit "$ZIP_PATH" \
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

  # A zip cannot carry a stapled ticket; the app inside it can. Staple the app,
  # then re-zip, so the installed copy launches offline without a Gatekeeper
  # stall — for both a human download and a Sparkle update.
  echo "==> Stapling notarization ticket to the app"
  xcrun stapler staple "$APP_PATH"
  echo "==> Re-zipping the stapled app"
  make_zip

  xcrun stapler validate "$APP_PATH" >/dev/null
  echo "==> Notarization complete (app stapled, zip rebuilt)"
else
  echo "==> Skipping notarization (set NOTARIZE=1 later when ready)"
fi

echo "==> Dist artifacts in $DIST_DIR"
ls -lh "$DIST_DIR"
