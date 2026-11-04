#!/usr/bin/env bash
#
# Decides what the release workflows do for the commit that is checked out,
# for each platform: act, skip, or stop with an error. It reads only published
# state, from the bucket's ORIGIN (never the CDN — see tool/lib/bucket_urls.sh),
# and needs no credentials, so it runs on any runner and on any Mac:
#
#   tool/release_plan.sh upload     what .github/workflows/release.yml uploads
#   tool/release_plan.sh promote    what .github/workflows/promote.yml promotes
#
# upload, per platform:
#   skip    this exact build is already uploaded (its .sha256 sidecar is in
#           the bucket). Every push to main runs the release workflow, and
#           this is what makes "upload when the version changes" true: a
#           commit that did not bump the version names a build that is up.
#           A rebuild could not be re-uploaded anyway — signing and
#           notarizing make every build's bytes different, and objects are
#           immutable.
#   upload  not uploaded, and its build number beats every build the world
#           has seen: the appcast AND the downloads pointer, which knows about
#           uploads still waiting for promotion. The same rule as
#           `make set_version`.
#   error   not uploaded, but the number is taken. Shipping it would repeat
#           a build number — unfixable — so the workflow stops and says why.
#
# Windows is also skipped while windows/release.json has no appcastUrl or
# eddsaPublicKey: a build without them never checks for updates, so whoever
# installs it is stranded on it.
#
# promote, per platform:
#   promote the uploaded build is newer than everything in the appcast
#   skip    it is already in the appcast
#   error   not uploaded, or older than what the appcast serves
#
# Prints GitHub Actions outputs (key=value) on stdout, for $GITHUB_OUTPUT.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tool/lib/pubspec_version.sh
source "$ROOT_DIR/tool/lib/pubspec_version.sh"
# shellcheck source=tool/lib/bucket_urls.sh
source "$ROOT_DIR/tool/lib/bucket_urls.sh"

MODE="${1:-}"
case "$MODE" in
  upload | promote) ;;
  *) echo "usage: tool/release_plan.sh upload|promote" >&2; exit 1 ;;
esac

BUCKET="${BUCKET:-serverpod-appstudio-toolchain}"
ORIGIN="${ORIGIN_BASE_URL:-$(origin_base_url "$BUCKET")}"
PUBLIC="$(public_base_url "$BUCKET")"
# Release Macs are Apple silicon, and so is the runner that builds in CI
# (release.yml checks). This script may run on Linux, so not `uname -m`.
MACOS_ARCH="arm64"

exists() { curl -fsI "$ORIGIN$1" >/dev/null 2>&1; }

# in_appcast <appcast-url> <build> — the exact build is an item in the feed.
in_appcast() {
  fetch_uncached "$1" | python3 -c '
import re, sys
build = sys.argv[1]
text = sys.stdin.read()
sys.exit(0 if re.search(
    rf"<sparkle:version>\s*{build}\s*</sparkle:version>|sparkle:version=\"{build}\"",
    text) else 1)
' "$2"
}

out() { printf '%s=%s\n' "$1" "$2"; }

# plan <platform> <version> <build> <object-path> <appcast-path> <downloads-path>
plan() {
  local p="$1" version="$2" build="$3" object="$4" appcast="$5" downloads="$6"
  local status reason seen
  out "${p}_version" "$version"
  out "${p}_build" "$build"
  out "${p}_url" "$PUBLIC$object"

  if [[ "$MODE" == upload ]]; then
    if exists "$object.sha256"; then
      status=skip reason="$version (build $build) is already uploaded"
    else
      seen="$(release_max_build "$ORIGIN$appcast" "$ORIGIN$downloads")"
      if [[ "$build" -gt "$seen" ]]; then
        status=upload reason="$version (build $build) is new"
      else
        status=error
        reason="build $build is not uploaded, but builds up to $seen already are"
        reason+=" (appcast or downloads pointer): bump the build number"
      fi
    fi
  else
    if ! exists "$object.sha256"; then
      status=error reason="$version (build $build) has not been uploaded"
    elif in_appcast "$ORIGIN$appcast" "$build"; then
      status=skip reason="$version (build $build) is already in the appcast"
    else
      seen="$(published_max_build "$ORIGIN$appcast")"
      if [[ "$build" -gt "$seen" ]]; then
        status=promote reason="$version (build $build) replaces build $seen"
      else
        status=error reason="the appcast already serves build $seen, newer than $build"
      fi
    fi
  fi
  out "$p" "$status"
  out "${p}_reason" "$reason"
  echo "$p: $status — $reason" >&2
}

read -r VERSION MACOS_BUILD <<<"$(read_pubspec_version "$ROOT_DIR/pubspec.yaml")"
plan macos "$VERSION" "$MACOS_BUILD" \
  "releases/macos/$VERSION/b$MACOS_BUILD/AppStudio-$VERSION-$MACOS_ARCH.zip" \
  appcast/macos/appcast.xml downloads/macos.json

# windows/release.json: its own build counter, and the feed URL and public key
# a release build compiles in.
read -r WINDOWS_BUILD WINDOWS_CONFIGURED <<<"$(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
print(int(c.get("build", 0)), int(bool(c.get("appcastUrl")) and bool(c.get("eddsaPublicKey"))))
' "$ROOT_DIR/windows/release.json")"
if [[ "$WINDOWS_CONFIGURED" != 1 ]]; then
  out windows_version "$VERSION"
  out windows_build "$WINDOWS_BUILD"
  out windows skip
  out windows_reason "windows/release.json has no appcastUrl or eddsaPublicKey, so the build could never update"
  echo "windows: skip — windows/release.json has no appcastUrl or eddsaPublicKey" >&2
else
  plan windows "$VERSION" "$WINDOWS_BUILD" \
    "releases/windows/$VERSION/b$WINDOWS_BUILD/AppStudio-$VERSION-x64-setup.exe" \
    appcast/windows/appcast.xml downloads/windows.json
fi
