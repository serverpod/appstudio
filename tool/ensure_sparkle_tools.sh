#!/usr/bin/env bash
#
# Fetches Sparkle's release tools (generate_keys, sign_update, generate_appcast,
# BinaryDelta) into a gitignored cache and verifies the download.
#
# The version is read from Package.resolved, NOT hardcoded here. The tools and
# the embedded framework must be the same release: generate_appcast writes the
# signature format the framework expects, and a mismatch produces a feed that
# every installed copy silently rejects.
#
# Prints the bin directory on stdout so callers can do:
#   SPARKLE_BIN="$(tool/ensure_sparkle_tools.sh)"
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_ROOT="${SPARKLE_TOOLS_CACHE:-$ROOT_DIR/.sparkle-tools}"
RESOLVED="$ROOT_DIR/macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if [[ ! -f "$RESOLVED" ]]; then
  echo "error: no Package.resolved at $RESOLVED" >&2
  echo "Build the macOS app once so Xcode resolves the Sparkle package." >&2
  exit 1
fi

VERSION="$(
  python3 - "$RESOLVED" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for pin in data.get("pins", []):
    if pin.get("identity") == "sparkle":
        print(pin["state"]["version"])
        break
else:
    sys.exit("error: Sparkle is not pinned in Package.resolved")
PY
)"

BIN_DIR="$CACHE_ROOT/$VERSION/bin"
if [[ -x "$BIN_DIR/generate_appcast" && -x "$BIN_DIR/sign_update" ]]; then
  echo "$BIN_DIR"
  exit 0
fi

echo "==> Fetching Sparkle $VERSION tools" >&2
URL="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-for-Swift-Package-Manager.zip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL --retry 3 -o "$WORK/sparkle.zip" "$URL"

# Verify against the checksum SPM recorded, when it recorded one. Sparkle's
# release zip is not itself a binaryTarget artifact for every version, so this
# is a best-effort cross-check rather than a hard requirement — the real
# integrity guarantee is that GitHub release assets are immutable.
EXPECTED="$(
  python3 - "$RESOLVED" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for pin in data.get("pins", []):
    if pin.get("identity") == "sparkle":
        print(pin["state"].get("checksum", ""))
        break
PY
)"
ACTUAL="$(shasum -a 256 "$WORK/sparkle.zip" | awk '{print $1}')"
if [[ -n "$EXPECTED" && "$EXPECTED" != "$ACTUAL" ]]; then
  echo "error: Sparkle $VERSION zip hashes $ACTUAL, Package.resolved expects $EXPECTED" >&2
  exit 1
fi
echo "    sha256 $ACTUAL" >&2

unzip -q "$WORK/sparkle.zip" -d "$WORK/unpacked"
if [[ ! -d "$WORK/unpacked/bin" ]]; then
  echo "error: no bin/ in the Sparkle $VERSION package" >&2
  exit 1
fi

# Sparkle's own tools are Developer ID signed by the Sparkle project. If that
# ever stops being true, something is wrong with the download.
for tool in generate_keys sign_update generate_appcast; do
  if ! codesign -v "$WORK/unpacked/bin/$tool" 2>/dev/null; then
    echo "error: $tool failed signature verification" >&2
    exit 1
  fi
done

rm -rf "$CACHE_ROOT/$VERSION"
mkdir -p "$(dirname "$BIN_DIR")"
mv "$WORK/unpacked/bin" "$BIN_DIR"
echo "    installed to $BIN_DIR" >&2

echo "$BIN_DIR"
