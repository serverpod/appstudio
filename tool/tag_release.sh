#!/usr/bin/env bash
#
# Tags a promoted release on GitHub as v<version>, e.g. v0.3.0. Run by
# .github/workflows/promote.yml after the appcasts are updated.
#
# The tag goes on the commit that SET the version, not on the head of main.
# Release (release.yml) builds and uploads the commit whose pubspec.yaml first
# names a new build — normally the `make set_version` commit — and main may
# have moved on by the time that build has been tried and promoted. So the
# commit is the oldest one whose pubspec.yaml diff adds `version: X.Y.Z+N`.
#
# Annotated, naming the build numbers on both platforms. Never moved: an
# existing v<version> on the same commit is left as it is, and one on another
# commit (a `make set_version V=build` rebuild of a version already tagged) is
# reported and left alone too — a tag someone may have fetched should not
# change meaning.
#
# Usage: tool/tag_release.sh [--dry-run]
#   needs full history and tags (actions/checkout with fetch-depth: 0).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tool/lib/pubspec_version.sh
source "$ROOT_DIR/tool/lib/pubspec_version.sh"
cd "$ROOT_DIR"

DRY_RUN=0
[[ "${1:-}" == --dry-run ]] && DRY_RUN=1

read -r VERSION MACOS_BUILD <<<"$(read_pubspec_version pubspec.yaml)"
WINDOWS_BUILD="$(python3 -c 'import json; print(int(json.load(open("windows/release.json")).get("build", 0)))')"
TAG="v$VERSION"

# git log -G takes a regex: the dots and the plus of "0.3.0+23" are literal.
pattern="^version:[[:space:]]*${VERSION//./\\.}\\+$MACOS_BUILD[[:space:]]*\$"
COMMIT="$(git log --format=%H --reverse -G"$pattern" -- pubspec.yaml | head -1)"
if [[ -z "$COMMIT" ]]; then
  echo "::warning title=Tag::No commit adds 'version: $VERSION+$MACOS_BUILD' to pubspec.yaml; tagging the checked-out commit instead."
  COMMIT="$(git rev-parse HEAD)"
fi
echo "==> $TAG -> $(git log -1 --format='%h %s' "$COMMIT")"

if EXISTING="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}")"; then
  if [[ "$EXISTING" == "$COMMIT" ]]; then
    echo "    $TAG already marks this commit"
  else
    echo "::warning title=Tag not moved::$TAG already marks $(git log -1 --format=%h "$EXISTING"), not the commit that set $VERSION+$MACOS_BUILD. Tags are not moved; the release is live either way."
  fi
  exit 0
fi

MESSAGE="App Studio $VERSION

macOS build $MACOS_BUILD
Windows build $WINDOWS_BUILD"

if [[ "$DRY_RUN" == 1 ]]; then
  echo "    dry run: would create and push $TAG"
  printf '%s\n' "$MESSAGE" | sed 's/^/    | /'
  exit 0
fi

git -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    tag -a "$TAG" -m "$MESSAGE" "$COMMIT"
git push origin "refs/tags/$TAG"
echo "    pushed $TAG"
