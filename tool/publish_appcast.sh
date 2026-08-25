#!/usr/bin/env bash
#
# Regenerates the Sparkle appcast from the published releases and uploads it.
#
# The appcast is the ONE mutable object in the bucket. Everything else uses
# --if-generation-match=0; this file has to be rewritten on every release, so
# it deliberately does not. That is the whole exception, and it is why the feed
# is signed: a rewritable object is only as trustworthy as its signature.
#
# Flow: download every published release zip -> run generate_appcast over the
# directory (which reads the private key from the login Keychain and signs each
# item with EdDSA) -> rewrite the enclosure URLs to point back at the bucket ->
# upload -> fetch it back and verify.
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
# macos/. Scanning everything matches vendored third-party trees — the Flutter
# SDK under toolchain/ ships dummy TLS certs in its own test fixtures — and a
# tripwire that cries wolf on every run is one that gets disabled.
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
# Collect every published release. generate_appcast needs the actual bundles:
# it reads each one's CFBundleVersion and signs the archive, so a feed cannot
# be assembled from listings alone.
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RELEASES="$WORK/releases"
mkdir -p "$RELEASES"

echo "==> Collecting published releases"
OBJECTS="$(
  gcloud storage ls "gs://$BUCKET/releases/macos/**/*.zip" 2>/dev/null || true
)"
if [[ -z "$OBJECTS" ]]; then
  echo "error: no release archives under gs://$BUCKET/releases/macos/" >&2
  echo "Publish a build first: make dist" >&2
  exit 1
fi

# Remember where each file came from, so the feed can point at the immutable
# object rather than at the flat directory generate_appcast sees.
MAP="$WORK/map.txt"
: >"$MAP"
while IFS= read -r obj; do
  [[ -n "$obj" ]] || continue
  name="$(basename "$obj")"
  if [[ -f "$RELEASES/$name" ]]; then
    echo "error: two published objects share the filename $name:" >&2
    grep -F "	$name" "$MAP" >&2 || true
    echo "  $obj" >&2
    echo "The feed cannot tell them apart. Rename one before republishing." >&2
    exit 1
  fi
  echo "    $obj"
  gcloud_storage cp "$obj" "$RELEASES/$name" >/dev/null
  printf '%s\t%s\n' "${obj#gs://$BUCKET/}" "$name" >>"$MAP"
done <<<"$OBJECTS"

# ---------------------------------------------------------------------------
# Generate. The private key is read from the Keychain via SecItemCopyMatching,
# so it never appears on a command line or in shell history. macOS may prompt
# for access the first time.
# ---------------------------------------------------------------------------
echo
echo "==> Generating and signing the appcast"
# --maximum-deltas 0 keeps deltas OFF.
#
# generate_appcast turns them on by itself as soon as two versions are present,
# and then writes <sparkle:deltas> enclosures for .delta files that this script
# neither uploads nor knows how to name — so the feed points at objects that do
# not exist. Enabling deltas properly is its own piece of work: the files need
# an immutable path, and because every release regenerates every delta, the
# upload cannot simply use --if-generation-match=0 the way the release zips do.
# Until that is designed and measured, full updates only.
# --maximum-versions 0 keeps EVERY published release in the feed.
#
# The default is 3, and the pruning is silent: `generate_appcast` quietly moves
# older archives into an old_updates/ directory and drops them from the feed.
# That makes the feed disagree with the bucket, and it makes "did this publish
# work?" impossible to answer by inspection. Keeping everything means the feed
# is exactly the set of published objects — an invariant this script then
# checks. Items are ~0.5 KB, so the feed stays small for a long time.
"$SPARKLE_BIN/generate_appcast" \
  --maximum-versions 0 \
  --maximum-deltas 0 \
  --download-url-prefix "$PUBLIC_BASE_URL" \
  --link "https://serverpod.dev" \
  "$RELEASES"

FEED="$RELEASES/appcast.xml"
if [[ ! -f "$FEED" ]]; then
  echo "error: generate_appcast produced no appcast.xml" >&2
  exit 1
fi

# generate_appcast builds URLs as <prefix><filename>, because it only sees a
# flat directory. The real objects live under releases/macos/<v>/b<n>/, so
# rewrite each enclosure to its true path.
python3 - "$FEED" "$MAP" "$PUBLIC_BASE_URL" <<'PY'
import re, sys
feed_path, map_path, base = sys.argv[1], sys.argv[2], sys.argv[3]
with open(map_path) as f:
    paths = dict(
        (name, obj)
        for obj, name in (line.rstrip("\n").split("\t") for line in f if line.strip())
    )
with open(feed_path) as f:
    feed = f.read()
missing = []
for name, obj in paths.items():
    flat = base + name
    if flat in feed:
        feed = feed.replace(flat, base + obj)
    elif base + obj not in feed:
        missing.append(name)
if missing:
    sys.exit(
        "error: these published archives are missing from the generated feed:\n  "
        + "\n  ".join(missing)
        + "\n\ngenerate_appcast dropped them. Check --maximum-versions (0 keeps"
        "\nall) and look for an old_updates/ directory beside the archives."
    )

# Every enclosure must now point at an object we actually published. Anything
# else means generate_appcast emitted a file this script does not upload — as
# it did for delta updates — and the feed would advertise a 404. Catch it here,
# by name, instead of at the reachability check after the feed is already live.
known = {base + obj for obj in paths.values()}
bad = [u for u in re.findall(r'url="([^"]+)"', feed) if u not in known]
if bad:
    sys.exit(
        "error: the feed references files this script does not publish:\n  "
        + "\n  ".join(bad)
    )

with open(feed_path, "w") as f:
    f.write(feed)
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

# Every enclosure must actually be fetchable, or an update check offers a
# download that 404s. These are CDN URLs now, so this exercises the exact path
# Sparkle will take — including whether the load balancer is actually serving the
# bucket, which nothing else here would notice. Safe to check immediately:
# release zips are immutable and negative caching is off on the backend bucket,
# so there is no cached 404 to trip over.
python3 -c "
import re,sys
urls = re.findall(r'url=\"([^\"]+)\"', open('$CHECK').read())
print('\n'.join(urls))
" | while IFS= read -r url; do
  [[ -n "$url" ]] || continue
  if ! curl -fsSL -I "$url" >/dev/null 2>&1; then
    echo "error: enclosure is not reachable: $url" >&2
    exit 1
  fi
  echo "    ok $url"
done

echo
echo "Published: $PUBLIC_BASE_URL$APPCAST_PATH"
