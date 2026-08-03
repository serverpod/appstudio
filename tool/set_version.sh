#!/usr/bin/env bash
#
# Sets the version in pubspec.yaml, which is the single source of truth for
# CFBundleShortVersionString and CFBundleVersion.
#
# The build number (+N) is NOT part of the argument and is never chosen by
# hand. Sparkle compares CFBundleVersion, so +N is a global release counter:
# it must increase on every published build and must never reset when the
# marketing version changes. 1.0.0+7 -> 1.1.0+8, not 1.1.0+1.
#
# Usage:
#   tool/set_version.sh 1.2.3     explicit version
#   tool/set_version.sh patch     0.0.1 -> 0.0.2
#   tool/set_version.sh minor     0.0.1 -> 0.1.0
#   tool/set_version.sh major     0.0.1 -> 1.0.0
#   tool/set_version.sh build     keep the version, bump the build only
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tool/lib/pubspec_version.sh
source "$ROOT_DIR/tool/lib/pubspec_version.sh"

# Overridable so the test suite can drive this against a temp pubspec and a
# local feed instead of the real bucket.
PUBSPEC="${PUBSPEC:-$ROOT_DIR/pubspec.yaml}"
BUCKET="${BUCKET:-serverpod-appstudio-toolchain}"
APPCAST_URL="${APPCAST_URL:-https://storage.googleapis.com/$BUCKET/appcast/macos/appcast.xml}"

if [[ $# -ne 1 ]]; then
  sed -n '11,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
fi
SPEC="$1"

read -r CUR_VERSION CUR_BUILD <<<"$(read_pubspec_version "$PUBSPEC")"
IFS=. read -r MAJOR MINOR PATCH <<<"$CUR_VERSION"

case "$SPEC" in
  major) NEW_VERSION="$((MAJOR + 1)).0.0" ;;
  minor) NEW_VERSION="$MAJOR.$((MINOR + 1)).0" ;;
  patch) NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  build) NEW_VERSION="$CUR_VERSION" ;;
  *)
    if [[ ! "$SPEC" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "error: '$SPEC' is not a version (x.y.z) or one of major/minor/patch/build" >&2
      exit 1
    fi
    NEW_VERSION="$SPEC"
    ;;
esac

# Refuse to go backwards. A lower marketing version carried by a higher build
# number installs cleanly and then reads as a downgrade to every user.
if [[ "$NEW_VERSION" != "$CUR_VERSION" ]] \
  && ! version_is_newer "$NEW_VERSION" "$CUR_VERSION"; then
  echo "error: $NEW_VERSION is older than the current $CUR_VERSION." >&2
  echo "Edit pubspec.yaml by hand if that is really what you want." >&2
  exit 1
fi

# The counter has to clear everything already published, not just what happens
# to be in this checkout — a colleague's release, or a rebased branch, would
# otherwise hand out a build number Sparkle has already seen.
PUBLISHED_MAX="$(published_max_build "$APPCAST_URL")"
NEW_BUILD="$CUR_BUILD"
[[ "$PUBLISHED_MAX" -gt "$NEW_BUILD" ]] && NEW_BUILD="$PUBLISHED_MAX"
NEW_BUILD="$((NEW_BUILD + 1))"

python3 - "$PUBSPEC" "$NEW_VERSION+$NEW_BUILD" <<'PY'
import re, sys
path, value = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()
new, n = re.subn(r'^version:.*$', f'version: {value}', text, count=1, flags=re.M)
if n != 1:
    sys.exit("error: no 'version:' line in pubspec.yaml")
with open(path, 'w') as f:
    f.write(new)
PY

echo "==> version $CUR_VERSION+$CUR_BUILD -> $NEW_VERSION+$NEW_BUILD"
if [[ "$PUBLISHED_MAX" -gt 0 ]]; then
  echo "    (highest published build is $PUBLISHED_MAX)"
fi
