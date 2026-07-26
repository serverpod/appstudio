#!/usr/bin/env bash
# Keep the prebuilt flutter_tools.snapshot valid so Flutter never rebuilds the
# tool on a target Mac (where host pub-cache paths and network are unavailable).
#
# Flutter rebuilds flutter_tools when:
#   - snapshot/stamp missing, or
#   - stamp != "$(git rev-parse HEAD):$FLUTTER_TOOL_ARGS", or
#   - packages/flutter_tools/pubspec.yaml is newer than pubspec.lock
#
# After DMG/ditto, mtimes often invert yaml vs lock → rebuild → compile fails
# with "'File' isn't a type" because package:file points at the build machine's
# pub-cache absolute path.
set -euo pipefail

FLUTTER_DIR="${1:-}"
if [[ -z "$FLUTTER_DIR" || ! -d "$FLUTTER_DIR" ]]; then
  echo "Usage: $0 /path/to/flutter/sdk" >&2
  exit 1
fi

CACHE="$FLUTTER_DIR/bin/cache"
TOOLS="$FLUTTER_DIR/packages/flutter_tools"
SNAPSHOT="$CACHE/flutter_tools.snapshot"
STAMP="$CACHE/flutter_tools.stamp"

if [[ ! -f "$SNAPSHOT" ]]; then
  echo "error: missing flutter_tools.snapshot at $SNAPSHOT" >&2
  exit 1
fi

if [[ ! -d "$FLUTTER_DIR/.git" ]]; then
  echo "error: Flutter SDK is not a git checkout (required by flutter tool): $FLUTTER_DIR" >&2
  exit 1
fi

# Prefer bundled git if the caller put it on PATH; otherwise system git.
REVISION="$(git -C "$FLUTTER_DIR" rev-parse HEAD)"
# Match shared.sh compilekey when FLUTTER_TOOL_ARGS is unset.
printf '%s:\n' "$REVISION" > "$STAMP"

# Ensure lock is newer than yaml so the -nt rebuild check stays false after
# archive extract (DMG/ditto often scramble relative mtimes).
if [[ -f "$TOOLS/pubspec.lock" ]]; then
  touch "$TOOLS/pubspec.lock"
fi

# Drop host-absolute package_config from the build machine. The JIT snapshot
# does not need it; a rebuild would regenerate it via pub get.
rm -rf "$TOOLS/.dart_tool"

echo "flutter_tools cache ready (stamp=${REVISION}:)"
