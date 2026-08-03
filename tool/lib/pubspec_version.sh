#!/usr/bin/env bash
#
# Shared version helpers for set_version.sh and publish_dist.sh.
#
# Both scripts decide things about the build number, and if they ever disagreed
# the failure would be silent and unfixable: Sparkle compares CFBundleVersion,
# objects in the bucket are immutable, and an install that has seen build N
# ignores everything numbered N or lower forever.
#
# Source this file; it defines functions only.

# read_pubspec_version <pubspec-path>
#
# Prints "<version> <build>", e.g. "1.2.3 7". A version with no "+N" reports
# build 0, so callers that increment land on 1.
read_pubspec_version() {
  local pubspec="$1" raw version build
  raw="$(sed -n 's/^version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$pubspec" | head -1)"
  if [[ -z "$raw" ]]; then
    echo "error: could not read 'version:' from $pubspec" >&2
    return 1
  fi
  version="${raw%%+*}"
  build="${raw#*+}"
  [[ "$build" == "$raw" ]] && build=0
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: '$version' in $pubspec is not a three-part version" >&2
    return 1
  fi
  if [[ ! "$build" =~ ^[0-9]+$ ]]; then
    echo "error: build number '$build' in $pubspec is not a number" >&2
    return 1
  fi
  printf '%s %s\n' "$version" "$build"
}

# published_max_build <appcast-url>
#
# Highest sparkle:version in the live feed, or 0 when the feed is missing,
# unreachable or empty. Failing open is deliberate: the very first release has
# no feed, and a network blip must not block a release. The immutability of
# the object names is what actually prevents a collision.
published_max_build() {
  local url="$1" out
  out="$(fetch_uncached "$url" | sparkle_max_build 2>/dev/null || true)"
  [[ "$out" =~ ^[0-9]+$ ]] || out=0
  printf '%s\n' "$out"
}

# curl, but guaranteed not to read a stale copy of the appcast.
#
# The feed is uploaded with `max-age=300`, so a plain GET can return the
# PREVIOUS feed for five minutes after a publish. That is not cosmetic here: a
# stale read makes published_max_build under-report, which would let the gate
# approve a build number that is already taken — the one mistake that cannot be
# undone. A unique query string changes the cache key and no-cache forces
# revalidation. (file:// URLs pass through untouched; caching does not apply.)
fetch_uncached() {
  local url="$1"
  if [[ "$url" == file://* ]]; then
    curl -fsSL "$url" 2>/dev/null
    return
  fi
  local sep='?'
  [[ "$url" == *'?'* ]] && sep='&'
  curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    "${url}${sep}_cb=$$-${RANDOM}" 2>/dev/null
}

# Highest sparkle:version on stdin, in BOTH spellings.
#
# Sparkle 2.9 writes it as a child element:
#     <sparkle:version>2</sparkle:version>
# older releases put it on the enclosure:
#     <enclosure ... sparkle:version="2" .../>
#
# Matching only the attribute form makes this silently return 0 for every
# modern feed — which disables the monotonic gate entirely without failing, the
# worst possible outcome for a check whose whole job is to prevent an
# unfixable mistake. Both forms, always.
sparkle_max_build() {
  python3 -c '
import re, sys
text = sys.stdin.read()
found = [
    int(m)
    for m in re.findall(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>", text)
]
found += [int(m) for m in re.findall(r"sparkle:version=\"(\d+)\"", text)]
print(max(found) if found else 0)
'
}

# assert_build_is_newer <build> <published-max>
#
# The gate. Note it compares build numbers only and ignores the marketing
# version — that is the whole point. 1.1.0+1 published after 1.0.0+1 is what
# this exists to reject, because Sparkle would never offer it.
assert_build_is_newer() {
  local build="$1" published="$2"
  if [[ "$build" -gt "$published" ]]; then
    return 0
  fi
  echo "error: build number $build is not greater than the published $published." >&2
  echo "Sparkle compares CFBundleVersion, so the +N in pubspec.yaml is a global" >&2
  echo "release counter: it must increase on every release and must never reset" >&2
  echo "when the marketing version changes (1.0.0+7 -> 1.1.0+8, not 1.1.0+1)." >&2
  echo "Run 'make set_version V=...' rather than editing pubspec.yaml by hand." >&2
  return 1
}

# version_is_newer <candidate> <current>
#
# True when <candidate> sorts strictly after <current>. Used to refuse a
# marketing version that goes backwards, which would install cleanly and then
# read as a downgrade to every user.
version_is_newer() {
  local candidate="$1" current="$2"
  [[ "$candidate" == "$current" ]] && return 1
  local lower
  lower="$(printf '%s\n%s\n' "$candidate" "$current" \
    | sort -t. -k1,1n -k2,2n -k3,3n | head -1)"
  [[ "$lower" == "$current" ]]
}
