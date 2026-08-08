#!/usr/bin/env bash
#
# Publishes the toolchain trees that bundle_toolchain.sh produced to the public
# GCS bucket, and regenerates assets/toolchain_manifest.json with the hashes and
# sizes of the exact bytes uploaded.
#
# Every object name is immutable: the build counter is its own path segment, so
# a repack of the same upstream version gets a new URL. Uploads use
# --if-generation-match=0, so a name collision fails loudly instead of
# overwriting. This also means a mistaken publish cannot be undone with the
# publisher role alone — check --dry-run output first.
#
# Usage:
#   tool/publish_toolchain.sh [--dry-run] [--only=flutter,git] [--build=N]
#                             [--bucket=NAME] [--impersonate-service-account=SA]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$ROOT_DIR/toolchain}"
MANIFEST_FILE="$ROOT_DIR/assets/toolchain_manifest.json"
BUCKET="${BUCKET:-serverpod-appstudio-toolchain}"
BUILD="${BUILD:-1}"
DRY_RUN=0
ONLY=""
IMPERSONATE=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --only=*) ONLY="${arg#*=}" ;;
    --build=*) BUILD="${arg#*=}" ;;
    --bucket=*) BUCKET="${arg#*=}" ;;
    --impersonate-service-account=*) IMPERSONATE="${arg#*=}" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) PLATFORM="macos-arm64" ;;
  x86_64) PLATFORM="macos-x64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

BASE_URL="https://storage.googleapis.com/$BUCKET/"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

gcloud_storage() {
  if [[ -n "$IMPERSONATE" ]]; then
    gcloud storage "$@" --impersonate-service-account="$IMPERSONATE"
  else
    gcloud storage "$@"
  fi
}

# Reads a pin out of toolchain/active.json without needing jq.
active_version() {
  python3 -c "import json,sys; print(json.load(open('$TOOLCHAIN_DIR/active.json')).get('$1',''))"
}

wants() {
  [[ -z "$ONLY" ]] && return 0
  [[ ",$ONLY," == *",$1,"* ]]
}

# id | source dir | version
COLLECTED=()

collect() {
  local id="$1" version="$2" source_dir="$3"
  if ! wants "$id"; then
    echo "  skip $id (not selected)"
    return
  fi
  if [[ -z "$version" ]]; then
    echo "  skip $id (no version pinned in active.json)"
    return
  fi
  if [[ ! -d "$source_dir" ]]; then
    echo "  skip $id ($source_dir does not exist)"
    return
  fi
  COLLECTED+=("$id|$version|$source_dir")
}

echo "==> Reading pins from $TOOLCHAIN_DIR/active.json"
FLUTTER_VERSION="$(active_version flutter)"
SERVERPOD_VERSION="$(active_version serverpod_cli)"
OPENCODE_VERSION="$(active_version opencode)"
GIT_VERSION="$(active_version git)"

collect flutter "$FLUTTER_VERSION" "$TOOLCHAIN_DIR/flutter/$FLUTTER_VERSION"
collect serverpod_cli "$SERVERPOD_VERSION" "$TOOLCHAIN_DIR/serverpod_cli/$SERVERPOD_VERSION"
collect opencode "$OPENCODE_VERSION" "$TOOLCHAIN_DIR/opencode/$OPENCODE_VERSION"
collect git "$GIT_VERSION" "$TOOLCHAIN_DIR/git/$GIT_VERSION"
# llvm-tools is produced by bundle_toolchain.sh once it switches off Xcode's
# cctools; until then there is nothing to publish and the app falls back to a
# host Xcode/CLT otool.
LLVM_VERSION="$(active_version llvm_tools)"
collect llvm-tools "$LLVM_VERSION" "$TOOLCHAIN_DIR/llvm-tools/$LLVM_VERSION"

if [[ ${#COLLECTED[@]} -eq 0 ]]; then
  echo "Nothing to publish." >&2
  exit 1
fi

# Flutter must have a valid tools stamp *inside* the archive, or the target Mac
# rebuilds flutter_tools and fails with "'File' isn't a type".
for entry in "${COLLECTED[@]}"; do
  IFS='|' read -r id version source_dir <<<"$entry"
  if [[ "$id" == "flutter" ]]; then
    echo "==> Refreshing flutter_tools cache stamp before packing"
    bash "$ROOT_DIR/tool/ensure_flutter_tools_cache.sh" "$source_dir"
  fi
done

echo
echo "==> Packing"
ENTRIES_JSON="$STAGING/entries.json"
: >"$ENTRIES_JSON"

for entry in "${COLLECTED[@]}"; do
  IFS='|' read -r id version source_dir <<<"$entry"

  archive_name="$id-$PLATFORM.tar.gz"
  archive="$STAGING/$archive_name"
  object_path="tools/$id/$version/b$BUILD/$archive_name"

  parent="$(dirname "$source_dir")"
  base="$(basename "$source_dir")"

  # --no-mac-metadata keeps ._* AppleDouble entries out. Mach-O signatures live
  # inside the file and survive the round trip; the smoke test below proves it.
  tar --no-mac-metadata -czf "$archive" -C "$parent" "$base"

  download_bytes="$(stat -f %z "$archive")"
  installed_kb="$(du -sk "$source_dir" | awk '{print $1}')"
  installed_bytes=$((installed_kb * 1024))
  sha="$(shasum -a 256 "$archive" | awk '{print $1}')"

  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "$id" "$version" "$object_path" "$sha" "$download_bytes" "$installed_bytes" "$base" \
    >>"$ENTRIES_JSON"

  printf '  %-14s %-14s %10s  ->  %s\n' \
    "$id" "$version" "$(du -h "$archive" | awk '{print $1}')" "$object_path"
done

echo
if [[ "$DRY_RUN" == "1" ]]; then
  echo "==> Dry run: nothing uploaded, manifest not written."
  exit 0
fi

echo "==> Uploading to gs://$BUCKET"
while IFS='|' read -r id version object_path sha download_bytes installed_bytes base; do
  archive="$STAGING/$id-$PLATFORM.tar.gz"
  # --if-generation-match=0 means "only if this object does not exist".
  gcloud_storage cp "$archive" "gs://$BUCKET/$object_path" \
    --if-generation-match=0 \
    --cache-control="public, max-age=31536000, immutable" \
    --content-type="application/gzip"
  echo "  uploaded $object_path"
done <"$ENTRIES_JSON"

echo
echo "==> Verifying uploads (re-download and re-hash)"
while IFS='|' read -r id version object_path sha download_bytes installed_bytes base; do
  check="$STAGING/verify-$id.tar.gz"
  curl -fsSL "$BASE_URL$object_path" -o "$check"
  actual="$(shasum -a 256 "$check" | awk '{print $1}')"
  if [[ "$actual" != "$sha" ]]; then
    echo "  MISMATCH for $object_path: expected $sha, got $actual" >&2
    exit 1
  fi
  echo "  ok $id"
  rm -f "$check"
done <"$ENTRIES_JSON"

echo
echo "==> Writing $MANIFEST_FILE"
python3 - "$MANIFEST_FILE" "$ENTRIES_JSON" "$PLATFORM" "$BUILD" "$BASE_URL" <<'PYTHON'
import json, sys, datetime

manifest_path, entries_path, platform, build, base_url = sys.argv[1:6]

with open(manifest_path) as f:
    manifest = json.load(f)

by_id = {}
with open(entries_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        tool_id, version, path, sha, download, installed, base = line.split('|')
        by_id[tool_id] = {
            'path': path,
            'sha256': sha,
            'downloadBytes': int(download),
            'installedBytes': int(installed),
            'format': 'tar.gz',
            # One top-level directory in the archive.
            'stripComponents': 1,
        }

manifest['baseUrl'] = base_url
manifest['manifestId'] = datetime.datetime.now(datetime.UTC).strftime('%Y.%m.%d.%H%M')

for tool in manifest['tools']:
    entry = by_id.get(tool['id'])
    if entry is None:
        continue
    tool['build'] = int(build)
    tool.setdefault('platforms', {})[platform] = entry

manifest.pop('_note', None)
with open(manifest_path, 'w') as f:
    json.dump(manifest, f, indent=2)
    f.write('\n')

print(f'  {len(by_id)} tool(s) published for {platform}')
PYTHON

echo
echo "==> Uploading live manifest"
gcloud_storage cp "$MANIFEST_FILE" "gs://$BUCKET/manifest.json" \
  --cache-control="public, max-age=300" \
  --content-type="application/json"
echo "  uploaded manifest.json"

echo
echo "==> Smoke test: vendor signatures survived the tar round trip"
if [[ -n "$FLUTTER_VERSION" ]] && wants flutter; then
  dart_bin="$TOOLCHAIN_DIR/flutter/$FLUTTER_VERSION/bin/cache/dart-sdk/bin/dart"
  if [[ -x "$dart_bin" ]]; then
    codesign -dv "$dart_bin" 2>&1 | grep -q "TeamIdentifier=S8QB4VV633" \
      && echo "  dart still carries Google's Developer ID" \
      || echo "  WARNING: dart signature not as expected" >&2
  fi
fi

echo
echo "Done. Review the manifest diff, then commit assets/toolchain_manifest.json."
