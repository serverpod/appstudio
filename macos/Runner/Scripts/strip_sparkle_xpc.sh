#!/usr/bin/env bash
#
# Removes Sparkle's XPC services from the embedded framework.
#
# They exist only so a *sandboxed* app can reach the network and write outside
# its container. App Studio is not sandboxed (Release.entitlements sets
# com.apple.security.app-sandbox = false), so Sparkle never launches them.
#
# Leaving them in is not merely dead weight: `distribute_macos.sh` re-signs
# nested code by matching `*.app` and `*.framework`, and an `.xpc` bundle
# matches neither. It would ship with the signature it arrived with, inside a
# framework we have re-signed — which notarization rejects.
#
# Usage:
#   strip_sparkle_xpc.sh [/path/to/App.app]
#
# With no argument it reads Xcode's TARGET_BUILD_DIR/PRODUCT_NAME, so it can
# also run as a build phase.
#
# BUT the build phase is not sufficient on its own. Xcode embeds an SPM binary
# framework in an internal step that is NOT ordered after custom build phases,
# so a run that re-copies Sparkle can undo a strip that already happened. That
# is silent: the next incremental build skips the copy and looks fine again.
# `distribute_macos.sh` therefore calls this directly, after the build and
# before signing, which is the only point where the answer cannot change.
set -euo pipefail

if [[ $# -ge 1 ]]; then
  APP="$1"
else
  APP="${TARGET_BUILD_DIR:?}/${PRODUCT_NAME:?}.app"
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

if [[ ! -d "$SPARKLE" ]]; then
  # Sparkle is embedded by SPM; if it is not here yet the framework simply is
  # not part of this configuration. Not an error.
  echo "note: no Sparkle.framework at $SPARKLE — nothing to strip"
  exit 0
fi

removed=0
# Versions/*/ rather than a hardcoded Versions/B: the version letter is
# Sparkle's to choose and has changed before.
while IFS= read -r -d '' xpc; do
  rm -rf "$xpc"
  echo "note: removed $(basename "$xpc")"
  removed=$((removed + 1))
done < <(find "$SPARKLE" -name '*.xpc' -print0 2>/dev/null)

# Drop the now-empty XPCServices directories, AND the framework-root symlink
# that pointed at them. Leaving the symlink behind gives the bundle a dangling
# link into Versions/Current, which codesign and notarization both dislike.
# Order matters: -type d would follow nothing, so remove the link explicitly.
find "$SPARKLE" -name 'XPCServices' -type d -empty -delete 2>/dev/null || true
find "$SPARKLE" -name 'XPCServices' -type l -delete 2>/dev/null || true

# A dangling symlink anywhere in here means the strip was incomplete, and the
# failure would otherwise surface much later as an opaque notarization reject.
while IFS= read -r -d '' link; do
  if [[ ! -e "$link" ]]; then
    echo "error: dangling symlink left in Sparkle.framework: $link" >&2
    exit 1
  fi
done < <(find "$SPARKLE" -type l -print0)

echo "note: stripped $removed Sparkle XPC service(s)"
