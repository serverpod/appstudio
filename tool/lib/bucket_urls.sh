# Two URLs for one bucket, and which callers may use which.
#
# The bucket is reachable both ways, which is exactly why this is easy to get
# wrong and why nothing here derives one from the other:
#
#   ORIGIN — https://storage.googleapis.com/<bucket>/ — the bucket itself.
#     Every publish-time READ goes here. The "is this object already published,
#     byte for byte?" probes, the re-download-and-re-hash verification, and the
#     build-number gate that reads the live appcast are all asking what is *in
#     the bucket*, and an answer from a cache is not an answer to that question.
#     The gate is the one that cannot be allowed to be wrong: a stale read makes
#     published_max_build under-report, which approves a build number already
#     taken, and published objects are immutable so that cannot be undone.
#
#   PUBLIC — https://asdl.serverpod.dev/ — the same bucket behind Cloud CDN.
#     Every URL handed to a USER goes here: the manifest's baseUrl, the appcast
#     enclosures, and SPARKLE_FEED_URL in Sparkle.xcconfig.
#
# The origin URL keeps working forever and must: every copy of App Studio
# published before the CDN existed has it compiled in, both as its Sparkle feed
# and as the baseUrl of its baked manifest.

# The bucket the CDN is bolted to. --bucket=NAME is for a test publish, and
# public_base_url below is what keeps that from writing production URLs into a
# manifest describing objects that are somewhere else entirely.
PRODUCTION_BUCKET="serverpod-appstudio-toolchain"
CDN_BASE_URL="${CDN_BASE_URL:-https://asdl.serverpod.dev/}"

# The load balancer in front of PRODUCTION_BUCKET, for cache invalidation.
CDN_URL_MAP="${CDN_URL_MAP:-asdl-url-map}"
CDN_PROJECT="${CDN_PROJECT:-serverpod-appstudio}"

origin_base_url() {
  printf 'https://storage.googleapis.com/%s/\n' "$1"
}

# The public base URL for <bucket> — the CDN for production, the origin for
# anything else.
#
# Falling back is not a nicety. The CDN serves ONE bucket, so stamping its host
# into a manifest built from a different one yields a manifest whose every
# download either 404s or, far worse, silently resolves to the production object
# that happens to share the path.
public_base_url() {
  if [[ "$1" == "$PRODUCTION_BUCKET" ]]; then
    printf '%s\n' "$CDN_BASE_URL"
  else
    origin_base_url "$1"
  fi
}

# invalidate_cdn_path <bucket> <path> [extra gcloud args...]
#
# Drops one path from the CDN edge caches. Only the two MUTABLE objects need
# this — appcast.xml and manifest.json, both published with max-age=300 — and
# only they may have it: invalidating an immutable object is meaningless, and the
# quota is per-project and small.
#
# Best-effort by design. The object is already in the bucket by the time this
# runs, the TTL it would wait out is five minutes, and every reader that must
# not be stale reads the origin anyway. Failing a release that has already
# succeeded, over a cache that empties itself, would be the worse outcome — so
# this reports and returns 0.
invalidate_cdn_path() {
  local bucket="$1" path="$2"
  shift 2
  if [[ "$bucket" != "$PRODUCTION_BUCKET" ]]; then
    echo "    skipped CDN invalidation ($bucket is not behind the CDN)"
    return 0
  fi
  # --async: the invalidation takes minutes to report done and nothing here
  # waits on it. Clients read the origin; users get it when it lands.
  if gcloud compute url-maps invalidate-cdn-cache "$CDN_URL_MAP" \
    --path="$path" --global --async --project="$CDN_PROJECT" "$@" >/dev/null 2>&1
  then
    echo "    invalidated $path at the edge"
  else
    echo "    warning: could not invalidate $path — it expires on its own" \
      "within 5 minutes (max-age=300)" >&2
  fi
  return 0
}
