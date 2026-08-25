#!/usr/bin/env bash
#
# Uploads the release zip in dist/macos to the public bucket, under a path
# derived from the pubspec version, and refreshes the "preview" entry in
# downloads/macos.json.
#
# This does NOT touch the appcast. The uploaded build is reachable through its
# direct URL (printed at the end) so it can be tested on another Mac first;
# `make promote` (tool/publish_appcast.sh) is what makes it the live
# auto-update for existing installs.
#
# Object names are immutable: every upload uses --if-generation-match=0, so a
# name collision fails instead of overwriting. (That flag is what enforces it —
# NOT the IAM role, which for a project owner does permit overwrite.)
# Re-releasing therefore means bumping the build number in pubspec.yaml, which
# is deliberate: a download URL should never change meaning. Re-running with
# the SAME bytes is fine — the upload is recognised and skipped.
#
# Usage:
#   tool/publish_dist.sh [--dry-run] [--bucket=NAME] [--allow-unnotarized]
#                        [--impersonate-service-account=SA]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tool/lib/pubspec_version.sh
source "$ROOT_DIR/tool/lib/pubspec_version.sh"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist/macos}"
BUCKET="${BUCKET:-serverpod-appstudio-toolchain}"
APPCAST_PATH="appcast/macos/appcast.xml"
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

# shellcheck source=tool/lib/bucket_urls.sh
source "$ROOT_DIR/tool/lib/bucket_urls.sh"
# The build-number gate and the upload verification read the origin; the URLs
# printed at the end are the ones a person would hand out, so they are the CDN's.
# See tool/lib/bucket_urls.sh.
ORIGIN_BASE_URL="$(origin_base_url "$BUCKET")"
PUBLIC_BASE_URL="$(public_base_url "$BUCKET")"
ARCH="$(uname -m)"

gcloud_storage() {
  if [[ -n "$IMPERSONATE" ]]; then
    gcloud storage "$@" --impersonate-service-account="$IMPERSONATE"
  else
    gcloud storage "$@"
  fi
}

# ---------------------------------------------------------------------------
# Version, straight out of pubspec.yaml: "version: 1.0.0+3" -> 1.0.0 and 3.
# ---------------------------------------------------------------------------
read -r APP_VERSION BUILD_NUMBER <<<"$(read_pubspec_version "$ROOT_DIR/pubspec.yaml")"

ZIP_PATH="$DIST_DIR/AppStudio-$ARCH.zip"
if [[ ! -f "$ZIP_PATH" ]]; then
  echo "error: no archive at $ZIP_PATH" >&2
  echo "Run 'make build' first." >&2
  exit 1
fi

OBJECT_NAME="AppStudio-$APP_VERSION-$ARCH.zip"
OBJECT_PATH="releases/macos/$APP_VERSION/b$BUILD_NUMBER/$OBJECT_NAME"

echo "==> Publishing App Studio $APP_VERSION (build $BUILD_NUMBER, $ARCH)"
echo "    from  $ZIP_PATH"
echo "    to    gs://$BUCKET/$OBJECT_PATH"
echo "    size  $(du -h "$ZIP_PATH" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Sparkle compares CFBundleVersion, i.e. the +N in pubspec.yaml. If that ever
# goes backwards or repeats, every existing install goes permanently blind to
# updates — and because objects are immutable it cannot be fixed by reuploading.
# ---------------------------------------------------------------------------
echo
echo "==> Checking the build number is newer than everything in the appcast"
PUBLISHED_MAX="$(published_max_build "$ORIGIN_BASE_URL$APPCAST_PATH")"
echo "    pubspec build $BUILD_NUMBER, highest promoted $PUBLISHED_MAX"
assert_build_is_newer "$BUILD_NUMBER" "$PUBLISHED_MAX"

# ---------------------------------------------------------------------------
# The archive must actually contain the version we are about to publish it as.
# A stale archive from an older build would otherwise be served under a new
# version number, which is unfixable once the object exists.
# ---------------------------------------------------------------------------
echo
echo "==> Checking the archive contents match pubspec"
UNPACK="$(mktemp -d)"
cleanup() { rm -rf "$UNPACK"; }
trap cleanup EXIT

ditto -x -k "$ZIP_PATH" "$UNPACK"
UNPACKED_APP="$(find "$UNPACK" -maxdepth 1 -name '*.app' | head -1)"
if [[ -z "$UNPACKED_APP" ]]; then
  echo "error: no .app inside the archive" >&2
  exit 1
fi

ZIP_VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$UNPACKED_APP/Contents/Info.plist" 2>/dev/null || true
)"
ZIP_BUILD="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$UNPACKED_APP/Contents/Info.plist" 2>/dev/null || true
)"
echo "    archive reports version $ZIP_VERSION (build $ZIP_BUILD)"

if [[ "$ZIP_VERSION" != "$APP_VERSION" ]]; then
  echo "error: the archive contains $ZIP_VERSION but pubspec.yaml says $APP_VERSION." >&2
  echo "That archive is stale. Run 'make clean && make build'." >&2
  exit 1
fi
if [[ "$ZIP_BUILD" != "$BUILD_NUMBER" ]]; then
  echo "error: the archive reports build $ZIP_BUILD but pubspec.yaml says $BUILD_NUMBER." >&2
  exit 1
fi

# A leftover embed would mean shipping ~1.8 GB of tools the app downloads
# anyway. distribute_macos.sh drops it, but verify what we are uploading.
if [[ -d "$UNPACKED_APP/Contents/Resources/toolchain" ]]; then
  echo "error: this build still embeds a toolchain — it came from a stale tree." >&2
  echo "Run 'make clean && make build'." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Gatekeeper. Publishing an unnotarized build means every user gets a warning,
# and Sparkle installs the app itself, so the ticket must be on the APP.
# ---------------------------------------------------------------------------
echo
echo "==> Checking signature and notarization"
if xcrun stapler validate "$UNPACKED_APP" >/dev/null 2>&1; then
  echo "    notarization ticket stapled to the app"
elif [[ "$ALLOW_UNNOTARIZED" == "1" ]]; then
  echo "    WARNING: not notarized — publishing anyway (--allow-unnotarized)"
  echo "    Users will see a Gatekeeper warning on first launch."
else
  echo "error: the app in this archive has no stapled notarization ticket." >&2
  echo "Run: NOTARIZE=1 ./tool/distribute_macos.sh" >&2
  echo "Or pass --allow-unnotarized for an internal test build." >&2
  exit 1
fi

cleanup
trap - EXIT

SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
BYTES="$(stat -f %z "$ZIP_PATH")"
echo
echo "    sha256 $SHA256"

if [[ "$DRY_RUN" == "1" ]]; then
  echo
  echo "==> Dry run: nothing uploaded."
  exit 0
fi

# A re-run for bytes already in the bucket is fine (a failed downloads-pointer
# update, a second `make publish` to be sure); the same PATH holding DIFFERENT
# bytes means a stale or rebuilt archive and needs a new build number.
ALREADY_PUBLISHED="$(
  curl -fsSL "$ORIGIN_BASE_URL$OBJECT_PATH.sha256" 2>/dev/null \
    | awk '{print $1; exit}' || true
)"
if [[ -n "$ALREADY_PUBLISHED" && "$ALREADY_PUBLISHED" != "$SHA256" ]]; then
  echo "error: gs://$BUCKET/$OBJECT_PATH already exists with different bytes." >&2
  echo "Published objects are immutable — bump the build number:" >&2
  echo "  make set_version V=build && make build && make publish" >&2
  exit 1
fi

echo
if [[ -n "$ALREADY_PUBLISHED" ]]; then
  echo "==> Already uploaded (byte-identical) — skipping the upload"
else
  echo "==> Uploading"
  # --if-generation-match=0 means "only if this object does not exist", so a
  # repeat publish of the same version fails loudly instead of overwriting.
  gcloud_storage cp "$ZIP_PATH" "gs://$BUCKET/$OBJECT_PATH" \
    --if-generation-match=0 \
    --cache-control="public, max-age=31536000, immutable" \
    --content-type="application/zip"

  # Sidecar so users can verify a download without trusting the page they got
  # the link from.
  SUMS="$(mktemp)"
  printf '%s  %s\n' "$SHA256" "$OBJECT_NAME" >"$SUMS"
  gcloud_storage cp "$SUMS" "gs://$BUCKET/$OBJECT_PATH.sha256" \
    --if-generation-match=0 \
    --cache-control="public, max-age=31536000, immutable" \
    --content-type="text/plain"
  rm -f "$SUMS"
fi

echo
echo "==> Verifying the upload"
CHECK="$(mktemp)"
curl -fsSL "$ORIGIN_BASE_URL$OBJECT_PATH" -o "$CHECK"
ACTUAL="$(shasum -a 256 "$CHECK" | awk '{print $1}')"
rm -f "$CHECK"
if [[ "$ACTUAL" != "$SHA256" ]]; then
  echo "error: uploaded object hashes $ACTUAL, expected $SHA256" >&2
  exit 1
fi
echo "    ok ($BYTES bytes)"

# The website's "preview" pointer follows the newest upload.
echo
"$ROOT_DIR/tool/publish_downloads.sh" --bucket="$BUCKET" \
  ${IMPERSONATE:+--impersonate-service-account="$IMPERSONATE"}

echo
echo "Uploaded, NOT yet in the appcast — existing installs are untouched."
echo
echo "Test this build on another Mac:"
echo "  $PUBLIC_BASE_URL$OBJECT_PATH"
echo
echo "When it checks out, make it the live auto-update:"
echo "  make promote"
