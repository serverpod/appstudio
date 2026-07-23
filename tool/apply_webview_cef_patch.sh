#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_FILE="$ROOT/tool/webview_cef_patches/webview.dart"
LOCK_FILE="$ROOT/pubspec.lock"

if [[ ! -f "$PATCH_FILE" ]]; then
  echo "Missing patch file: $PATCH_FILE" >&2
  exit 1
fi

if [[ ! -f "$LOCK_FILE" ]]; then
  echo "Run flutter pub get first (pubspec.lock not found)." >&2
  exit 1
fi

VERSION="$(python3 - <<'PY'
import re
from pathlib import Path
text = Path("pubspec.lock").read_text()
match = re.search(r'^\s+webview_cef:\n(?:.*\n)*?\s+version:\s+"([^"]+)"', text, re.M)
if not match:
    raise SystemExit("Could not read webview_cef version from pubspec.lock")
print(match.group(1))
PY
)"

TARGET="${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev/webview_cef-${VERSION}/lib/src/webview.dart"

if [[ ! -f "$TARGET" ]]; then
  echo "webview_cef ${VERSION} not found at:" >&2
  echo "  $TARGET" >&2
  echo "Run: flutter pub get" >&2
  exit 1
fi

cp "$PATCH_FILE" "$TARGET"
echo "Applied webview_cef resize patch to:"
echo "  $TARGET"
