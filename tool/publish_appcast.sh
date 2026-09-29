#!/usr/bin/env bash
#
# Promotes the build pubspec.yaml names into the Sparkle appcast — the moment
# auto-update starts offering it to every installed copy. Until this runs, an
# uploaded build is reachable only through its direct download URL (and the
# "preview" entry in downloads/macos.json), which is what makes "upload, test
# on another Mac, then promote" possible.
#
# The appcast is mutable where everything else in the bucket uses
# --if-generation-match=0: it has to be rewritten on every release. That is
# why the feed is signed — a rewritable object is only as trustworthy as its
# signature.
#
# The update is INCREMENTAL: download the one zip being promoted from the
# bucket, verify it against its .sha256 sidecar, run generate_appcast over just
# that file (it reads the private key from the login Keychain and signs the
# item with EdDSA), then insert the new item into the live feed. Existing items
# are carried over byte-for-byte with the signatures they already have — the
# old flow re-downloaded and re-signed every published release on every run,
# which was N×350 MB of work to say something about one build.
#
# Usage:
#   tool/publish_appcast.sh [--dry-run] [--bucket=NAME]
#                           [--impersonate-service-account=SA]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tool/lib/pubspec_version.sh
source "$ROOT_DIR/tool/lib/pubspec_version.sh"
BUCKET="${BUCKET:-serverpod-appstudio-toolchain}"
APPCAST_PATH="appcast/macos/appcast.xml"
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
# The feed and every enclosure in it are user-facing, so they carry the CDN host.
# The read-back that proves this publish landed is not, and reads the origin.
# See tool/lib/bucket_urls.sh.
ORIGIN_BASE_URL="$(origin_base_url "$BUCKET")"
PUBLIC_BASE_URL="$(public_base_url "$BUCKET")"

gcloud_storage() {
  if [[ -n "$IMPERSONATE" ]]; then
    gcloud storage "$@" --impersonate-service-account="$IMPERSONATE"
  else
    gcloud storage "$@"
  fi
}

# ---------------------------------------------------------------------------
# Tripwire. The private key belongs in the Keychain and nowhere else. A copy
# sitting in the repo is one `git add -A` away from being public forever, and
# whoever has it can sign an update that every install will accept and run.
# ---------------------------------------------------------------------------
#
# Scoped to where a human would actually drop one: the repo root, tool/ and
# macos/. Scanning everything matches vendored third-party trees — a Flutter
# SDK ships dummy TLS certs in its own test fixtures — and a tripwire that
# cries wolf on every run is one that gets disabled.
LEAKED="$(
  {
    find "$ROOT_DIR" -maxdepth 1 -type f \
      \( -name '*.pem' -o -name 'sparkle_priv*' -o -name '*ed25519*' \)
    find "$ROOT_DIR/tool" "$ROOT_DIR/macos" -type f \
      -not -path '*/Pods/*' \
      -not -path '*/ephemeral/*' \
      \( -name '*.pem' -o -name 'sparkle_priv*' -o -name '*ed25519*' \)
  } 2>/dev/null || true
)"
if [[ -n "$LEAKED" ]]; then
  echo "error: private-key-looking files found in the repo:" >&2
  echo "$LEAKED" >&2
  echo "The Sparkle signing key must live only in the login Keychain." >&2
  exit 1
fi

SPARKLE_BIN="$("$ROOT_DIR/tool/ensure_sparkle_tools.sh")"

# ---------------------------------------------------------------------------
# The key that signs must be the key that ships.
#
# generate_appcast signs with the private key in the login Keychain. Installed
# copies verify with the SUPublicEDKey compiled into their bundle. If those two
# ever diverge — a regenerated key, a different release machine, an edit to the
# xcconfig — every update is rejected by every install, silently, and no
# re-publish fixes it because the old builds are already out there.
# ---------------------------------------------------------------------------
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)"
# Note the trailing "=" of base64: match to end of line, do not split on "=".
SHIPPED_KEY="$(
  sed -n 's/^SPARKLE_PUBLIC_ED_KEY[[:space:]]*=[[:space:]]*//p' \
    "$ROOT_DIR/macos/Runner/Configs/Sparkle.xcconfig" | head -1
)"
if [[ -z "$KEYCHAIN_KEY" ]]; then
  echo "error: no Sparkle signing key in the login Keychain." >&2
  echo "This machine cannot sign updates. See AGENTS.md for key recovery." >&2
  exit 1
fi
if [[ -z "$SHIPPED_KEY" ]]; then
  echo "error: SPARKLE_PUBLIC_ED_KEY is empty in Sparkle.xcconfig." >&2
  exit 1
fi
if [[ "$KEYCHAIN_KEY" != "$SHIPPED_KEY" ]]; then
  echo "error: the signing key does not match the key shipped in the app." >&2
  echo "  Keychain: $KEYCHAIN_KEY" >&2
  echo "  Shipped:  $SHIPPED_KEY" >&2
  echo "Publishing would produce updates every installed copy rejects." >&2
  exit 1
fi
echo "==> Signing key matches the one shipped in the app"

# ---------------------------------------------------------------------------
# What is being promoted: exactly what pubspec.yaml names. That build must
# already be uploaded (make publish); this script never uploads archives.
# ---------------------------------------------------------------------------
read -r APP_VERSION BUILD_NUMBER <<<"$(read_pubspec_version "$ROOT_DIR/pubspec.yaml")"
ARCH="$(uname -m)"
OBJECT_NAME="AppStudio-$APP_VERSION-$ARCH.zip"
OBJECT_PATH="releases/macos/$APP_VERSION/b$BUILD_NUMBER/$OBJECT_NAME"
NEW_URL="$PUBLIC_BASE_URL$OBJECT_PATH"

echo
echo "==> Promoting App Studio $APP_VERSION (build $BUILD_NUMBER) into the appcast"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RELEASES="$WORK/releases"
mkdir -p "$RELEASES"

# ---------------------------------------------------------------------------
# The live feed, read from the origin without the cache — this is the document
# being edited, and editing a stale copy would silently drop a release.
# ---------------------------------------------------------------------------
EXISTING="$WORK/existing.xml"
HAVE_FEED=0
if fetch_uncached "$ORIGIN_BASE_URL$APPCAST_PATH" >"$EXISTING" && [[ -s "$EXISTING" ]]; then
  HAVE_FEED=1
fi

if [[ "$HAVE_FEED" == "1" ]] \
  && grep -Eq "<sparkle:version>[[:space:]]*$BUILD_NUMBER[[:space:]]*</sparkle:version>" \
    "$EXISTING"; then
  echo "    build $BUILD_NUMBER is already in the appcast — nothing to promote."
  if [[ "$DRY_RUN" != "1" ]]; then
    # Re-running after a half-finished promote: make sure the downloads
    # pointer caught up too.
    "$ROOT_DIR/tool/publish_downloads.sh" --bucket="$BUCKET" \
      ${IMPERSONATE:+--impersonate-service-account="$IMPERSONATE"}
  fi
  exit 0
fi

# The monotonic gate, against the feed itself. Promoting a build Sparkle has
# already seen a higher number than would be invisible to every install.
if [[ "$HAVE_FEED" == "1" ]]; then
  FEED_MAX="$(sparkle_max_build <"$EXISTING")"
  assert_build_is_newer "$BUILD_NUMBER" "$FEED_MAX"
fi

# ---------------------------------------------------------------------------
# Fetch the one zip being promoted and prove it is the upload it claims to be.
# generate_appcast needs the actual bundle — it reads CFBundleVersion and signs
# the archive — and the bytes MUST come from the bucket, not from dist/: the
# feed describes the published object, so that object is what gets signed.
# ---------------------------------------------------------------------------
echo
echo "==> Fetching the uploaded build"
if ! curl -fsSL "$ORIGIN_BASE_URL$OBJECT_PATH" -o "$RELEASES/$OBJECT_NAME"; then
  echo "error: nothing is uploaded at $ORIGIN_BASE_URL$OBJECT_PATH" >&2
  echo "Run 'make publish' first." >&2
  exit 1
fi
EXPECTED_SHA="$(
  curl -fsSL "$ORIGIN_BASE_URL$OBJECT_PATH.sha256" | awk '{print $1; exit}'
)" || {
  echo "error: no .sha256 sidecar next to the uploaded zip" >&2
  exit 1
}
ACTUAL_SHA="$(shasum -a 256 "$RELEASES/$OBJECT_NAME" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "error: the uploaded zip hashes $ACTUAL_SHA but its sidecar says $EXPECTED_SHA" >&2
  exit 1
fi
echo "    sha256 verified against the published sidecar"

# ---------------------------------------------------------------------------
# Generate. The private key is read from the Keychain via SecItemCopyMatching,
# so it never appears on a command line or in shell history. macOS may prompt
# for access the first time.
# ---------------------------------------------------------------------------
echo
echo "==> Generating and signing the new item"
# generate_appcast only sees the one zip being promoted, so it emits a
# single-item feed; the item is extracted and merged into the live feed below.
#
# --maximum-deltas 0 keeps deltas OFF. generate_appcast turns them on by itself
# the moment two versions are present in its directory — only one ever is now,
# but the flag stays, because a .delta enclosure points at a file this script
# neither uploads nor knows how to name. --maximum-versions 0 for the same
# belt-and-braces reason: the default (3) silently prunes.
"$SPARKLE_BIN/generate_appcast" \
  --maximum-versions 0 \
  --maximum-deltas 0 \
  --download-url-prefix "$PUBLIC_BASE_URL" \
  --link "https://serverpod.dev" \
  "$RELEASES"

GENERATED="$RELEASES/appcast.xml"
if [[ ! -f "$GENERATED" ]]; then
  echo "error: generate_appcast produced no appcast.xml" >&2
  exit 1
fi

# Merge: rewrite the generated enclosure URL to the real object path (the tool
# builds <prefix><filename> because it only sees a flat directory), check the
# item says exactly what we mean to publish, and insert it at the top of the
# live feed. Existing items pass through untouched.
FEED="$WORK/merged.xml"
python3 - "$GENERATED" "$EXISTING" "$FEED" \
  "$PUBLIC_BASE_URL$OBJECT_NAME" "$NEW_URL" "$BUILD_NUMBER" "$HAVE_FEED" <<'PY'
import re, sys
gen_path, old_path, out_path, flat_url, real_url, build, have_feed = sys.argv[1:8]

with open(gen_path) as f:
    generated = f.read()
generated = generated.replace(flat_url, real_url)

items = re.findall(r"<item>.*?</item>", generated, re.S)
if len(items) != 1:
    sys.exit(f"error: generate_appcast emitted {len(items)} items, expected 1")
item = items[0]

if not re.search(
    rf"<sparkle:version>\s*{build}\s*</sparkle:version>", item
) and not re.search(rf'sparkle:version="{build}"', item):
    sys.exit(f"error: the generated item does not carry build {build} — "
             "the zip in the bucket is not the build pubspec.yaml names")
if "sparkle:edSignature" not in item:
    sys.exit("error: the generated item is not signed")
urls = re.findall(r'url="([^"]+)"', item)
if urls != [real_url]:
    sys.exit("error: the item references URLs this script does not publish:\n  "
             + "\n  ".join(urls))

if have_feed == "1":
    with open(old_path) as f:
        old = f.read()
    # Newest first, matching what generate_appcast itself writes.
    if "<item>" in old:
        merged = old.replace("<item>", item + "\n        <item>", 1)
    elif "</channel>" in old:
        merged = old.replace("</channel>", item + "\n    </channel>", 1)
    else:
        sys.exit("error: the live appcast has no <channel> to insert into")
else:
    merged = generated

with open(out_path, "w") as f:
    f.write(merged)
PY

echo
echo "==> Feed contents"
python3 - "$FEED" <<'PYEOF'
import re, sys

feed = open(sys.argv[1]).read()

# Sparkle 2.9 writes version/shortVersionString as child ELEMENTS; older
# releases put them on the <enclosure>. Parse per <item> and accept either, so
# this summary cannot quietly report an empty feed for a perfectly good one.
items = re.findall(r"<item>(.*?)</item>", feed, re.S)
if not items:
    sys.exit("error: the generated feed has no items")


def field(item, name):
    m = re.search(rf"<sparkle:{name}>\s*([^<]+?)\s*</sparkle:{name}>", item)
    if m:
        return m.group(1)
    m = re.search(rf'sparkle:{name}="([^"]+)"', item)
    return m.group(1) if m else "?"


for item in items:
    build = field(item, "version")
    version = field(item, "shortVersionString")
    hardware = re.search(r"<sparkle:hardwareRequirements>([^<]+)<", item)
    note = f"  [{hardware.group(1)} only]" if hardware else ""
    print(f"    {version} (build {build}){note}")

    if "sparkle:edSignature" not in item:
        sys.exit(f"error: {version} (build {build}) is not signed")

print(f"    {len(items)} signed item(s)")
PYEOF

if [[ "$DRY_RUN" == "1" ]]; then
  echo
  echo "==> Dry run: not uploaded. Feed is at $FEED"
  # The trap would delete it; hand back a copy the caller can inspect.
  cp "$FEED" "$ROOT_DIR/appcast-dry-run.xml"
  echo "    copied to $ROOT_DIR/appcast-dry-run.xml"
  exit 0
fi

# ---------------------------------------------------------------------------
# Upload. Deliberately WITHOUT --if-generation-match=0: this object is meant to
# be replaced. Short max-age so "publish then test" works; irrelevant next to
# the 86400 s check interval.
# ---------------------------------------------------------------------------
echo
echo "==> Uploading the appcast"
gcloud_storage cp "$FEED" "gs://$BUCKET/$APPCAST_PATH" \
  --cache-control="public, max-age=300, must-revalidate" \
  --content-type="application/xml"

# This is the object the CDN is most likely to be holding a stale copy of, and
# the one where staleness is most visible: an update check inside the max-age
# window is told there is nothing new. Fire the invalidation now so it runs while
# the verification below does its own work.
invalidate_cdn_path "$BUCKET" "/$APPCAST_PATH" \
  ${IMPERSONATE:+--impersonate-service-account="$IMPERSONATE"}

echo
echo "==> Verifying the published feed"
# Read back from the ORIGIN, and WITHOUT the cache. The feed we just replaced was
# served with max-age=300, so a plain GET happily returns the previous one and
# this check fails on a perfectly good publish. Retry a few times anyway, for
# genuine propagation rather than caching.
#
# Not the CDN copy: the invalidation above is asynchronous, so for the next few
# minutes the edge may legitimately still serve the old feed, and diffing against
# it would fail every publish. What must be true right now is that the BUCKET
# holds the feed we generated — the edge catches up on its own, and every reader
# that cannot tolerate a stale answer reads the origin too.
CHECK="$WORK/published.xml"
for attempt in 1 2 3 4 5; do
  fetch_uncached "$ORIGIN_BASE_URL$APPCAST_PATH" >"$CHECK" || true
  if diff -q "$FEED" "$CHECK" >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" == 5 ]]; then
    echo "error: the published feed differs from what was generated" >&2
    diff "$FEED" "$CHECK" | head -20 >&2
    exit 1
  fi
  echo "    not visible yet (attempt $attempt), retrying"
  sleep 3
done

# The new enclosure must actually be fetchable, or the update check offers a
# download that 404s. It is a CDN URL, so this exercises the exact path Sparkle
# will take — including whether the load balancer is actually serving the
# bucket. Only the item just added is checked: every older enclosure was
# checked when IT was promoted, and the objects are immutable, so re-probing
# them on every release proves nothing new. Safe to check immediately: release
# zips are immutable and negative caching is off on the backend bucket, so
# there is no cached 404 to trip over.
if ! curl -fsSL -I "$NEW_URL" >/dev/null 2>&1; then
  echo "error: enclosure is not reachable: $NEW_URL" >&2
  exit 1
fi
echo "    ok $NEW_URL"

# The download page's "latest" pointer follows the appcast; catch it up.
echo
"$ROOT_DIR/tool/publish_downloads.sh" --bucket="$BUCKET" \
  ${IMPERSONATE:+--impersonate-service-account="$IMPERSONATE"}

echo
echo "Published: $PUBLIC_BASE_URL$APPCAST_PATH"
echo "App Studio $APP_VERSION (build $BUILD_NUMBER) is now live for auto-update."
