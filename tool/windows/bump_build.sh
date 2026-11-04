#!/usr/bin/env bash
#
# Bumps the Windows build counter, `build` in windows/release.json. Run by
# `make set_version`, beside tool/set_version.sh, so one command moves both
# platforms to a new release.
#
# The rule is the macOS one: WinSparkle compares build numbers, objects in the
# bucket are immutable, and a number that repeats one already published can
# never be fixed. So the new number clears this checkout's AND everything
# published — the live Windows appcast plus downloads/windows.json, which also
# knows about uploads not yet promoted — read from the bucket's ORIGIN, never
# the CDN (tool/lib/bucket_urls.sh).
#
# It is a bash script, not PowerShell, so it runs where `make set_version`
# runs. tool/windows/build_release.ps1 -BumpBuild is the Windows-only route
# and does the same to the same file.
#
# The other two fields, appcastUrl and eddsaPublicKey, are kept as they are.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tool/lib/pubspec_version.sh
source "$ROOT_DIR/tool/lib/pubspec_version.sh"
# shellcheck source=tool/lib/bucket_urls.sh
source "$ROOT_DIR/tool/lib/bucket_urls.sh"

# Overridable so the test suite can drive this against a temp file and local
# feeds instead of the real bucket.
RELEASE_JSON="${RELEASE_JSON:-$ROOT_DIR/windows/release.json}"
BUCKET="${BUCKET:-serverpod-appstudio-toolchain}"
APPCAST_URL="${WINDOWS_APPCAST_URL:-$(origin_base_url "$BUCKET")appcast/windows/appcast.xml}"
DOWNLOADS_URL="${WINDOWS_DOWNLOADS_URL:-$(origin_base_url "$BUCKET")downloads/windows.json}"

CURRENT="$(python3 -c '
import json, sys
print(int(json.load(open(sys.argv[1])).get("build", 0)))
' "$RELEASE_JSON")"
PUBLISHED="$(release_max_build "$APPCAST_URL" "$DOWNLOADS_URL")"
NEW="$CURRENT"
[[ "$PUBLISHED" -gt "$NEW" ]] && NEW="$PUBLISHED"
NEW="$((NEW + 1))"

# The same layout tool/windows/release_common.ps1's Save-ReleaseConfig writes,
# so the two routes never fight over formatting.
python3 - "$RELEASE_JSON" "$NEW" <<'PY'
import json, sys
path, build = sys.argv[1], int(sys.argv[2])
config = json.load(open(path))
with open(path, "w") as f:
    f.write('{\n  "build": %d,\n  "appcastUrl": "%s",\n  "eddsaPublicKey": "%s"\n}\n'
            % (build, config.get("appcastUrl", ""), config.get("eddsaPublicKey", "")))
PY

echo "==> Windows build $CURRENT -> $NEW"
if [[ "$PUBLISHED" -gt 0 ]]; then
  echo "    (highest published Windows build is $PUBLISHED)"
fi
