#!/usr/bin/env bash
#
# Uploads the release DMG in dist/macos to the public bucket, under a path
# derived from the pubspec version.
#
# Object names are immutable (the publisher role cannot overwrite or delete),
# so re-releasing the same version means bumping the build number in
# pubspec.yaml. That is deliberate: a download URL should never change meaning.
#
# Usage:
#   tool/publish_dist.sh [--dry-run] [--bucket=NAME] [--allow-unnotarized]
#                        [--impersonate-service-account=SA]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist/macos}"
BUCKET="${BUCKET:-serverpod-appstudio-toolchain}"
DRY_RUN=0
ALLOW_UNNOTARIZED=0
IMPERSONATE=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --bucket=*) BUCKET="${arg#*=}" ;;
    --allow-unnotarized) ALLOW_UNNOTARIZED=1 ;;
    --impersonate-service-account=*) IMPERSONATE="${arg#*=}" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

BASE_URL="https://storage.googleapis.com/$BUCKET/"
ARCH="$(uname -m)"

gcloud_storage() {
  if [[ -n "$IMPERSONATE" ]]; then
    gcloud storage "$@" --impersonate-service-account="$IMPERSONATE"
  else
    gcloud storage "$@"
  fi
}

# ---------------------------------------------------------------------------
# Version, straight out of pubspec.yaml: "version: 1.0.0+3" → 1.0.0 and 3.
# ---------------------------------------------------------------------------
PUBSPEC_VERSION="$(
  sed -n 's/^version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$ROOT_DIR/pubspec.yaml" | head -1
)"
if [[ -z "$PUBSPEC_VERSION" ]]; then
  echo "error: could not read 'version:' from pubspec.yaml" >&2
  exit 1
fi
APP_VERSION="${PUBSPEC_VERSION%%+*}"
BUILD_NUMBER="${PUBSPEC_VERSION#*+}"
[[ "$BUILD_NUMBER" == "$PUBSPEC_VERSION" ]] && BUILD_NUMBER=1

DMG_PATH="$DIST_DIR/AppStudio-$ARCH.dmg"
if [[ ! -f "$DMG_PATH" ]]; then
  echo "error: no DMG at $DMG_PATH" >&2
  echo "Run 'make dist' first." >&2
  exit 1
fi

OBJECT_NAME="AppStudio-$APP_VERSION-$ARCH.dmg"
OBJECT_PATH="releases/macos/$APP_VERSION/b$BUILD_NUMBER/$OBJECT_NAME"

echo "==> Publishing App Studio $APP_VERSION (build $BUILD_NUMBER, $ARCH)"
echo "    from  $DMG_PATH"
echo "    to    gs://$BUCKET/$OBJECT_PATH"
echo "    size  $(du -h "$DMG_PATH" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# The DMG must actually contain the version we are about to publish it as.
# A stale DMG from an older build would otherwise be served under a new
# version number, which is unfixable once the object exists.
# ---------------------------------------------------------------------------
echo
echo "==> Checking the DMG contents match pubspec"
MOUNT_POINT="$(mktemp -d)"
cleanup() {
  hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_POINT" -quiet
MOUNTED_APP="$(find "$MOUNT_POINT" -maxdepth 1 -name '*.app' | head -1)"
if [[ -z "$MOUNTED_APP" ]]; then
  echo "error: no .app inside the DMG" >&2
  exit 1
fi

DMG_VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$MOUNTED_APP/Contents/Info.plist" 2>/dev/null || true
)"
DMG_BUILD="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$MOUNTED_APP/Contents/Info.plist" 2>/dev/null || true
)"
echo "    DMG reports version $DMG_VERSION (build $DMG_BUILD)"

if [[ "$DMG_VERSION" != "$APP_VERSION" ]]; then
  echo "error: the DMG contains $DMG_VERSION but pubspec.yaml says $APP_VERSION." >&2
  echo "That DMG is stale. Run 'make clean && make dist'." >&2
  exit 1
fi

# A leftover embed would mean shipping ~1.8 GB of tools the app downloads
# anyway. distribute_macos.sh drops it, but verify what we are uploading.
if [[ -d "$MOUNTED_APP/Contents/Resources/toolchain" ]]; then
  echo "error: this DMG still embeds a toolchain — it was built from a stale tree." >&2
  echo "Run 'make clean && make dist'." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Gatekeeper. Publishing an unnotarized DMG means every user gets a warning.
# ---------------------------------------------------------------------------
echo
echo "==> Checking signature and notarization"
if xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1; then
  echo "    notarization ticket stapled"
elif [[ "$ALLOW_UNNOTARIZED" == "1" ]]; then
  echo "    WARNING: not notarized — publishing anyway (--allow-unnotarized)"
  echo "    Users will see a Gatekeeper warning on first launch."
else
  echo "error: the DMG is not notarized (no stapled ticket)." >&2
  echo "Run: NOTARIZE=1 ./tool/distribute_macos.sh" >&2
  echo "Or pass --allow-unnotarized for an internal test build." >&2
  exit 1
fi

if spctl -a -t open --context context:primary-signature "$DMG_PATH" 2>&1 | grep -q accepted; then
  echo "    Gatekeeper accepts it"
fi

cleanup
trap - EXIT

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
BYTES="$(stat -f %z "$DMG_PATH")"
echo
echo "    sha256 $SHA256"

if [[ "$DRY_RUN" == "1" ]]; then
  echo
  echo "==> Dry run: nothing uploaded."
  exit 0
fi

echo
echo "==> Uploading"
# --if-generation-match=0 means "only if this object does not exist", so a
# repeat publish of the same version fails loudly instead of overwriting.
gcloud_storage cp "$DMG_PATH" "gs://$BUCKET/$OBJECT_PATH" \
  --if-generation-match=0 \
  --cache-control="public, max-age=31536000, immutable" \
  --content-type="application/x-apple-diskimage"

# Sidecar so users can verify a download without trusting the page they got
# the link from.
SUMS="$(mktemp)"
printf '%s  %s\n' "$SHA256" "$OBJECT_NAME" >"$SUMS"
gcloud_storage cp "$SUMS" "gs://$BUCKET/$OBJECT_PATH.sha256" \
  --if-generation-match=0 \
  --cache-control="public, max-age=31536000, immutable" \
  --content-type="text/plain"
rm -f "$SUMS"

echo
echo "==> Verifying the upload"
CHECK="$(mktemp)"
curl -fsSL "$BASE_URL$OBJECT_PATH" -o "$CHECK"
ACTUAL="$(shasum -a 256 "$CHECK" | awk '{print $1}')"
rm -f "$CHECK"
if [[ "$ACTUAL" != "$SHA256" ]]; then
  echo "error: uploaded object hashes $ACTUAL, expected $SHA256" >&2
  exit 1
fi
echo "    ok ($BYTES bytes)"

echo
echo "Published:"
echo "  $BASE_URL$OBJECT_PATH"
echo "  $BASE_URL$OBJECT_PATH.sha256"
echo
echo "Released versions:"
curl -fsSL "https://storage.googleapis.com/storage/v1/b/$BUCKET/o?prefix=releases/macos/&delimiter=/" \
  | python3 -c "import json,sys; [print('  ' + p) for p in json.load(sys.stdin).get('prefixes', [])]" \
  2>/dev/null || true
