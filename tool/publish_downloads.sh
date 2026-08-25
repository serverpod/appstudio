#!/usr/bin/env bash
#
# Publishes downloads/macos.json — a small mutable pointer for the website's
# download page. Two entries, each a full download link:
#
#   latest   the newest build in the Sparkle appcast — what auto-update serves
#   preview  the newest uploaded build, which may not be in the appcast yet
#
# When nothing is waiting for promotion the two entries are identical. The file
# is derived entirely from published state — the live appcast plus the object
# for the build pubspec.yaml names — so it is safe to re-run at any time.
# publish_dist.sh republishes it after an upload (preview moves forward) and
# publish_appcast.sh after a promotion (latest catches up), so it never has to
# be run by hand.
#
# Served with max-age=60: the website reads it live, so a promotion should be
# visible on the download page within a minute.
#
# Usage:
#   tool/publish_downloads.sh [--dry-run] [--bucket=NAME]
#                             [--impersonate-service-account=SA]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tool/lib/pubspec_version.sh
source "$ROOT_DIR/tool/lib/pubspec_version.sh"
BUCKET="${BUCKET:-serverpod-appstudio-toolchain}"
APPCAST_PATH="appcast/macos/appcast.xml"
DOWNLOADS_PATH="downloads/macos.json"
DRY_RUN=0
IMPERSONATE=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --bucket=*) BUCKET="${arg#*=}" ;;
    --impersonate-service-account=*) IMPERSONATE="${arg#*=}" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# shellcheck source=tool/lib/bucket_urls.sh
source "$ROOT_DIR/tool/lib/bucket_urls.sh"
# The links in the file are user-facing, so they carry the CDN host. Every read
# this script does to BUILD the file asks what is in the bucket, and reads the
# origin. See tool/lib/bucket_urls.sh.
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

# sha_for <object-path> — first field of the .sha256 sidecar published next to
# every release zip.
sha_for() {
  local sha
  sha="$(curl -fsSL "$ORIGIN_BASE_URL$1.sha256" | awk '{print $1; exit}')" || {
    echo "error: no .sha256 sidecar at $ORIGIN_BASE_URL$1.sha256" >&2
    return 1
  }
  printf '%s\n' "$sha"
}

# ---------------------------------------------------------------------------
# The preview candidate is whatever pubspec.yaml names. That is right for both
# callers: publish_dist.sh has just uploaded exactly that build, and after
# publish_appcast.sh promotes it the appcast names the same build, so the two
# entries collapse into one below.
# ---------------------------------------------------------------------------
read -r APP_VERSION BUILD_NUMBER <<<"$(read_pubspec_version "$ROOT_DIR/pubspec.yaml")"
OBJECT_PATH="releases/macos/$APP_VERSION/b$BUILD_NUMBER/AppStudio-$APP_VERSION-$ARCH.zip"

# ---------------------------------------------------------------------------
# latest: the highest-build item in the live appcast. Old items carry origin
# enclosure URLs (they predate the CDN); the object path is the same either
# way, so strip whichever base is present and rebuild the public URL.
# ---------------------------------------------------------------------------
echo "==> Reading the live appcast"
LATEST_LINE="$(
  fetch_uncached "$ORIGIN_BASE_URL$APPCAST_PATH" | python3 -c '
import re, sys
text = sys.stdin.read()
best = None
for item in re.findall(r"<item>(.*?)</item>", text, re.S):
    b = re.search(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>", item) \
        or re.search(r"sparkle:version=\"(\d+)\"", item)
    v = re.search(
        r"<sparkle:shortVersionString>\s*([^<]+?)\s*</sparkle:shortVersionString>",
        item) or re.search(r"sparkle:shortVersionString=\"([^\"]+)\"", item)
    u = re.search(r"url=\"([^\"]+)\"", item)
    if not (b and u):
        continue
    build = int(b.group(1))
    if best is None or build > best[0]:
        best = (build, v.group(1) if v else "", u.group(1))
if best:
    print("%d\t%s\t%s" % best)
' 2>/dev/null || true
)"

LATEST_BUILD=0 LATEST_VERSION="" LATEST_PATH=""
if [[ -n "$LATEST_LINE" ]]; then
  IFS=$'\t' read -r LATEST_BUILD LATEST_VERSION LATEST_URL <<<"$LATEST_LINE"
  LATEST_PATH="${LATEST_URL#"$ORIGIN_BASE_URL"}"
  LATEST_PATH="${LATEST_PATH#"$PUBLIC_BASE_URL"}"
  echo "    appcast serves $LATEST_VERSION (build $LATEST_BUILD)"
else
  echo "    no appcast published yet"
fi

# ---------------------------------------------------------------------------
# Resolve the two entries. A pubspec build newer than the appcast is a preview;
# anything else means there is nothing waiting and both entries are the latest.
# ---------------------------------------------------------------------------
if [[ "$BUILD_NUMBER" -gt "$LATEST_BUILD" ]]; then
  echo "==> Preview: $APP_VERSION (build $BUILD_NUMBER), not yet in the appcast"
  if ! curl -fsI "$ORIGIN_BASE_URL$OBJECT_PATH" >/dev/null 2>&1; then
    echo "error: pubspec names build $BUILD_NUMBER but nothing is uploaded at" >&2
    echo "  $ORIGIN_BASE_URL$OBJECT_PATH" >&2
    echo "Run 'make publish' first." >&2
    exit 1
  fi
  PREVIEW_VERSION="$APP_VERSION" PREVIEW_BUILD="$BUILD_NUMBER"
  PREVIEW_PATH="$OBJECT_PATH"
else
  echo "==> Nothing awaiting promotion — preview is the latest release"
  PREVIEW_VERSION="$LATEST_VERSION" PREVIEW_BUILD="$LATEST_BUILD"
  PREVIEW_PATH="$LATEST_PATH"
fi

# First release ever: nothing promoted yet, so the download page's only honest
# answer is the preview build.
if [[ "$LATEST_BUILD" -eq 0 ]]; then
  LATEST_VERSION="$PREVIEW_VERSION" LATEST_BUILD="$PREVIEW_BUILD"
  LATEST_PATH="$PREVIEW_PATH"
fi

LATEST_SHA="$(sha_for "$LATEST_PATH")"
if [[ "$PREVIEW_PATH" == "$LATEST_PATH" ]]; then
  PREVIEW_SHA="$LATEST_SHA"
else
  PREVIEW_SHA="$(sha_for "$PREVIEW_PATH")"
fi

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
python3 - "$OUT" <<PY
import datetime, json, sys
doc = {
    "generatedAt": datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "latest": {
        "version": "$LATEST_VERSION",
        "build": $LATEST_BUILD,
        "url": "$PUBLIC_BASE_URL$LATEST_PATH",
        "sha256": "$LATEST_SHA",
    },
    "preview": {
        "version": "$PREVIEW_VERSION",
        "build": $PREVIEW_BUILD,
        "url": "$PUBLIC_BASE_URL$PREVIEW_PATH",
        "sha256": "$PREVIEW_SHA",
    },
}
with open(sys.argv[1], "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

echo
echo "==> downloads/macos.json"
sed 's/^/    /' "$OUT"

if [[ "$DRY_RUN" == "1" ]]; then
  echo
  echo "==> Dry run: not uploaded."
  exit 0
fi

# ---------------------------------------------------------------------------
# Upload. Mutable by design, like the appcast — but with max-age=60 rather than
# 300, because the website reads it live and a promotion should show up on the
# download page within a minute.
# ---------------------------------------------------------------------------
echo
echo "==> Uploading"
gcloud_storage cp "$OUT" "gs://$BUCKET/$DOWNLOADS_PATH" \
  --cache-control="public, max-age=60, must-revalidate" \
  --content-type="application/json"

invalidate_cdn_path "$BUCKET" "/$DOWNLOADS_PATH" \
  ${IMPERSONATE:+--impersonate-service-account="$IMPERSONATE"}

echo
echo "==> Verifying"
CHECK="$(mktemp)"
fetch_uncached "$ORIGIN_BASE_URL$DOWNLOADS_PATH" >"$CHECK"
if ! diff -q "$OUT" "$CHECK" >/dev/null 2>&1; then
  echo "error: the published file differs from what was generated" >&2
  diff "$OUT" "$CHECK" >&2 || true
  rm -f "$CHECK"
  exit 1
fi
rm -f "$CHECK"
echo "    ok"

echo
echo "Published: $PUBLIC_BASE_URL$DOWNLOADS_PATH"
