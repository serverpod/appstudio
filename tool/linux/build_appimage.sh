#!/usr/bin/env bash
# Builds App Studio for Linux and packs it into an AppImage.
#
# Usage: tool/linux/build_appimage.sh     (or: make appimage)
#
# Writes dist/linux/AppStudio-<version>-x86_64.AppImage, <version> being the
# one in pubspec.yaml (without the build number).
#
# Optional environment:
#   FLUTTER               the flutter to build with (default: flutter on PATH)
#   SKIP_BUILD=1          package the release build that is already there
#                         (with the update feed it was built with)
#   APPIMAGETOOL          path to appimagetool; the pinned release is
#                         downloaded into build/linux/tools if unset
#   APPIMAGE_UPDATE_INFO  update information for AppImageUpdate and Gear Lever,
#                         e.g. "zsync|https://<host>/<path>/AppStudio-latest-x86_64.AppImage.zsync".
#                         With it, appimagetool also writes a .zsync file next
#                         to the AppImage. A release overwrites the .zsync at
#                         that fixed URL. Gear Lever offers an update whenever
#                         the .zsync's SHA-1 differs from the installed
#                         file's; it does not compare versions.
#   APPSTUDIO_APPCAST_URL, APPSTUDIO_EDDSA_PUBLIC_KEY
#                         the update feed and the public key that checks its
#                         downloads, compiled in. They come from
#                         linux/release.json (appcastUrl, eddsaPublicKey);
#                         set here they override it, for a local feed. Empty,
#                         the build reports updates as unavailable.
#   APPIMAGE_FILE_URL     where this AppImage will be downloaded from, written
#                         into the .zsync, e.g. "https://<host>/releases/linux/
#                         <version>/b<build>/AppStudio-<version>-x86_64.AppImage".
#                         Unset, the .zsync names the AppImage relative to
#                         itself, so every release would have to sit in the
#                         .zsync's folder; with it, the AppImage keeps a path
#                         of its own that is never overwritten.
#
# The AppImage carries App Studio, Flutter's engine and CEF. GTK 3 and the
# other desktop libraries come from the system; the build needs glibc 2.38 or
# newer at run time (Ubuntu 24.04 and later), so build on the oldest system
# it should run on. The build machine needs Flutter's Linux build tools, plus
# curl, python3, and readelf and strip (binutils).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
flutter="${FLUTTER:-flutter}"
bundle="$root/build/linux/x64/release/bundle"
appdir="$root/build/linux/AppStudio.AppDir"
dist="$root/dist/linux"
app_id="dev.serverpod.appstudio"

full_version="$(sed -n 's/^version: *\([^ ]*\).*/\1/p' "$root/pubspec.yaml")"
version="${full_version%%+*}"
if [[ -z "$version" ]]; then
  echo "No version in pubspec.yaml." >&2
  exit 1
fi
out="$dist/AppStudio-${version}-x86_64.AppImage"

step() { echo "==> $*"; }

missing=()
for cmd in curl python3 readelf sha256sum strip; do
  command -v "$cmd" > /dev/null || missing+=("$cmd")
done
if (( ${#missing[@]} )); then
  echo "Missing on this machine: ${missing[*]}" >&2
  exit 1
fi

# --- Update feed -----------------------------------------------------------

# From linux/release.json unless the environment overrides it, as
# windows/release.json does for Windows. In-app updates need both.
read_release() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' \
    "$root/linux/release.json" "$1"
}
appcast_url="${APPSTUDIO_APPCAST_URL:-$(read_release appcastUrl)}"
eddsa_public_key="${APPSTUDIO_EDDSA_PUBLIC_KEY:-$(read_release eddsaPublicKey)}"
# https only, as the app itself insists: the signature covers the file, not
# the feed. Plain http is allowed to this machine or a private address, for
# a local feed.
secure_url() {
  python3 -c '
import ipaddress, re, sys, urllib.parse
# The same rule as isSecureUpdateUrl in lib/update/linux/appcast.dart.
u = urllib.parse.urlsplit(sys.argv[1])
host = u.hostname or ""
if u.scheme.lower() == "https" and host:
    sys.exit(0)
if u.scheme.lower() != "http":
    sys.exit(1)
if host in ("localhost", "::1"):
    sys.exit(0)
octet = r"(0|[1-9][0-9]{0,2})"
if not re.fullmatch(rf"{octet}(\.{octet}){{3}}", host):
    sys.exit(1)
try:
    ip = ipaddress.IPv4Address(host)
except ValueError:
    sys.exit(1)
nets = ("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
sys.exit(0 if any(ip in ipaddress.ip_network(n) for n in nets) else 1)' "$1"
}
if [[ -n "$appcast_url" ]] && ! secure_url "$appcast_url"; then
  echo "The update feed must be an https address: $appcast_url" >&2
  exit 1
fi
if [[ -n "$eddsa_public_key" ]] &&
  ! python3 -c 'import base64, sys; sys.exit(len(base64.b64decode(sys.argv[1], validate=True)) != 32)' \
    "$eddsa_public_key" 2> /dev/null; then
  echo "The update public key is not base64 of 32 bytes." >&2
  exit 1
fi
# Both or neither: a build with only one never checks for updates, and
# nothing else would notice until users stopped getting them.
if [[ -n "$appcast_url" && -z "$eddsa_public_key" ]] ||
  [[ -z "$appcast_url" && -n "$eddsa_public_key" ]]; then
  echo "In-app updates need both appcastUrl and eddsaPublicKey" \
    "(linux/release.json or APPSTUDIO_APPCAST_URL /" \
    "APPSTUDIO_EDDSA_PUBLIC_KEY), or neither." >&2
  exit 1
fi

# --- Build -----------------------------------------------------------------

if [[ "${SKIP_BUILD:-}" != 1 ]]; then
  step "flutter build linux --release"
  # A release build rewrites the generated plugin files (it drops Widgetbook's
  # url_launcher, a dev dependency). They are committed, so put them back
  # whatever happens, as tool/windows/build_release.ps1 does.
  restore_generated() {
    git -C "$root" checkout -- \
      linux/flutter/generated_plugin_registrant.cc \
      linux/flutter/generated_plugins.cmake \
      windows/flutter/generated_plugin_registrant.cc \
      windows/flutter/generated_plugins.cmake
  }
  trap restore_generated EXIT
  if [[ -n "$appcast_url" && -n "$eddsa_public_key" ]]; then
    echo "In-app updates from $appcast_url"
  else
    echo "In-app updates off: no feed and no key (linux/release.json)"
  fi
  (cd "$root" && "$flutter" build linux --release \
    --dart-define="APPSTUDIO_APPCAST_URL=$appcast_url" \
    --dart-define="APPSTUDIO_EDDSA_PUBLIC_KEY=$eddsa_public_key")
  restore_generated
  trap - EXIT
fi

step "Checking the bundle"
# Flutter's own files, then CEF's: libcef.so and what it loads from beside
# itself (resources, locales, ANGLE's GL libraries, SwiftShader's software
# Vulkan).
# libflutter_pty2.so is a native asset (Publish to Cloud's terminal), built by
# the package's hook rather than CMake, so nothing else would notice it gone.
for file in appstudio lib/libapp.so lib/libflutter_linux_gtk.so \
  data/flutter_assets lib/libflutter_pty2.so \
  lib/libwebview_cef_plugin.so lib/libcef.so lib/icudtl.dat \
  lib/resources.pak lib/chrome_100_percent.pak lib/chrome_200_percent.pak \
  lib/v8_context_snapshot.bin lib/locales lib/libEGL.so lib/libGLESv2.so \
  lib/libvk_swiftshader.so lib/vk_swiftshader_icd.json; do
  if [[ ! -e "$bundle/$file" ]]; then
    echo "Missing from the release build: $bundle/$file" >&2
    exit 1
  fi
done

# The bundle records the version it was built with. With SKIP_BUILD it can be
# older than pubspec.yaml, and would then ship under the wrong version.
built="$(python3 -I -c 'import json, sys
v = json.load(open(sys.argv[1]))
print(v["version"] + "+" + v["build_number"])' "$bundle/data/flutter_assets/version.json")"
if [[ "$built" != "$full_version" ]]; then
  echo "The release build is $built, pubspec.yaml says $full_version: build again." >&2
  exit 1
fi

# --- AppDir ----------------------------------------------------------------

step "Assembling $appdir"
rm -rf "$appdir"
# The bundle keeps its layout (appstudio, lib/, data/): the executable finds
# its libraries through its RPATH ($ORIGIN/lib) and CEF finds its resources
# beside libcef.so. CEF's helper processes are this same executable, started
# from inside the mounted image.
mkdir -p "$appdir/usr/lib/appstudio" "$appdir/usr/bin"
cp -a "$bundle"/. "$appdir/usr/lib/appstudio/"
ln -s ../lib/appstudio/appstudio "$appdir/usr/bin/appstudio"

step "Stripping debug symbols"
# libcef.so ships with its symbols: 1.4 GB of a 1.5 GB bundle. Only files
# that still have a symbol table are stripped; the others, Flutter's engine
# among them, ship as they were built. libapp.so (the Dart AOT snapshot) is
# left alone: Flutter already strips it.
while IFS= read -r -d '' file; do
  # Captured, not piped into grep -q: grep stopping at the match would cut
  # readelf off, and pipefail would read that as no symbol table.
  if [[ "$(readelf -S "$file")" == *.symtab* ]]; then
    strip --strip-unneeded "$file"
  fi
done < <(find "$appdir/usr/lib/appstudio" -type f \
  \( -name '*.so' -o -name '*.so.*' -o -name appstudio \) ! -name libapp.so -print0)

step "Icons and desktop entry"
# Linux icons run nearly edge to edge, like Windows' and unlike the macOS
# icon, which sits on Apple's grid with a margin. So they come from the
# Windows .ico, whose frames are PNGs: one source for both.
python3 -I - "$root/windows/runner/resources/app_icon.ico" \
  "$appdir/usr/share/icons/hicolor" "$app_id" <<'PY'
import os, struct, sys
ico, hicolor, name = sys.argv[1:4]
data = open(ico, "rb").read()
count = struct.unpack("<HHH", data[:6])[2]
wanted = {16, 24, 32, 48, 64, 128, 256}
for i in range(count):
    w, _h, _c, _r, _p, _b, size, offset = struct.unpack(
        "<BBBBHHII", data[6 + 16 * i:22 + 16 * i])
    w = w or 256
    frame = data[offset:offset + size]
    if w in wanted and frame[:4] == b"\x89PNG":
        folder = os.path.join(hicolor, f"{w}x{w}", "apps")
        os.makedirs(folder, exist_ok=True)
        open(os.path.join(folder, name + ".png"), "wb").write(frame)
        wanted.discard(w)
if wanted:
    sys.exit(f"{ico} has no PNG frames for {sorted(wanted)}")
PY
cp "$appdir/usr/share/icons/hicolor/256x256/apps/$app_id.png" "$appdir/$app_id.png"
ln -s "$app_id.png" "$appdir/.DirIcon"

# StartupWMClass is the GTK application id the runner sets (APPLICATION_ID in
# linux/CMakeLists.txt): it is how a dock matches the window to this entry.
# X-AppImage-Version is the version AppImage managers such as Gear Lever show.
# Launchers match the start of each word of Name, so "appstudio" would find
# nothing without Keywords.
mkdir -p "$appdir/usr/share/applications"
cat > "$appdir/usr/share/applications/$app_id.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=App Studio
Comment=Build full-stack apps with Flutter and Serverpod
Exec=appstudio
Icon=$app_id
Terminal=false
StartupNotify=true
StartupWMClass=$app_id
Categories=Development;IDE;
Keywords=appstudio;serverpod;flutter;dart;
X-AppImage-Version=$version
DESKTOP
ln -s "usr/share/applications/$app_id.desktop" "$appdir/$app_id.desktop"

step "Start script"
# A system that cannot load the bundle (a glibc or C++ runtime too old, or a
# system library missing) fails before any of App Studio runs, so a
# double-click does nothing visible. AppRun asks the loader first and says
# what is wrong. Its message names a glibc version and distributions that
# have it: the version is the highest GLIBC_ version any ELF file in the
# bundle references, read from the build so it cannot drift, and a build that
# needs another one stops here until the distributions are updated. They go
# into a shell string, so they are limited to plain characters.
glibc_expected=2.38
glibc_examples="Ubuntu 24.04, Fedora 39, Debian 13 or newer"
if [[ ! "$glibc_examples" =~ ^[A-Za-z0-9\ .,]+$ ]]; then
  echo "glibc_examples may hold letters, digits, spaces, dots and commas only." >&2
  exit 1
fi
glibc_versions=()
while IFS= read -r -d '' file; do
  # ELF files by their header, not their name: chrome-sandbox has no .so.
  # NUL bytes are dropped first, as bash warns about them in $(...); the ELF
  # header has none.
  [[ "$(head -c 4 "$file" | tr -d '\0')" == $'\x7fELF' ]] || continue
  # In the main shell, so a readelf that fails stops the build.
  syms="$(readelf --dyn-syms -W "$file")"
  for v in $(grep -o 'GLIBC_[0-9][0-9.]*' <<< "$syms" || true); do
    glibc_versions+=("${v#GLIBC_}")
  done
done < <(find "$appdir/usr/lib/appstudio" -path "$appdir/usr/lib/appstudio/data" -prune \
  -o -type f -print0)
glibc_required="$(printf '%s\n' "${glibc_versions[@]}" | sort -V -u | tail -n 1)"
if [[ "$glibc_required" != "$glibc_expected" ]]; then
  echo "The bundle needs glibc ${glibc_required:-(none found)}, not $glibc_expected." >&2
  echo "Update glibc_expected and glibc_examples in $0." >&2
  exit 1
fi

cat > "$appdir/AppRun" <<'APPRUN'
#!/bin/sh
# Starts App Studio from the mounted image. On a system that cannot load it,
# the executable fails before any of App Studio runs and a double-click does
# nothing visible, so this asks the loader first and says what is wrong.
here="$(dirname "$(readlink -f "$0")")"
app="$here/usr/lib/appstudio/appstudio"
required="@GLIBC_REQUIRED@"
examples="@GLIBC_EXAMPLES@"

# Joins the non-empty lines on stdin with ", ".
join() {
  joined=""
  while IFS= read -r line; do
    [ -n "$line" ] && joined="${joined:+$joined, }$line"
  done
  printf '%s' "$joined"
}

# Shows title $1 and text $2 through the first tool that manages to. Exit 1
# with nothing on stderr is a dialog the user closed; any other failure, such
# as a display the tool cannot open, hands over to the next tool.
show_window() {
  for tool in zenity kdialog notify-send; do
    command -v "$tool" > /dev/null 2>&1 || continue
    case "$tool" in
      zenity) err="$(zenity --error --no-markup --title="$1" --text="$2" 2>&1 > /dev/null)" ;;
      kdialog) err="$(kdialog --title "$1" --error "$2" 2>&1 > /dev/null)" ;;
      notify-send) err="$(notify-send "$1" "$2" 2>&1 > /dev/null)" ;;
    esac
    status=$?
    if [ "$status" -eq 0 ] || { [ "$status" -eq 1 ] && [ -z "$err" ]; }; then
      return 0
    fi
  done
  return 1
}

# "glibc 2.39"; "none" where getconf exists but knows no glibc (musl); empty
# where there is no getconf, which then does not count against the system.
glibc=""
if command -v getconf > /dev/null 2>&1; then
  glibc="$(getconf GNU_LIBC_VERSION 2> /dev/null)"
  case "$glibc" in
    "glibc "[0-9]*) ;;
    *) glibc="none" ;;
  esac
fi

if [ "$glibc" != none ]; then
  # The loader lists what the app needs without running it, and says
  # "not found" for each library or symbol version this system lacks.
  trace="$(LD_TRACE_LOADED_OBJECTS=1 "$app" 2>&1)"
  missing_versions="$(printf '%s\n' "$trace" |
    sed -n "s/.*version [\`']\([^']*\)' not found.*/\1/p" | sort -u | join)"
  missing_libs="$(printf '%s\n' "$trace" |
    sed -n 's/^[[:space:]]*\([^[:space:]]*\) => not found.*/\1/p' | sort -u | join)"
  # Nothing recognisably missing: start, and let any other failure speak.
  if [ -z "$missing_versions$missing_libs" ]; then
    exec "$app" "$@"
  fi
fi

if [ "$glibc" = none ]; then
  title="App Studio needs a Linux with glibc"
  text="App Studio needs glibc $required or later ($examples). This system has no glibc."
elif [ -n "$missing_versions" ]; then
  title="App Studio needs a newer Linux"
  # Libraries missing as well are left out: a newer Linux is the fix either
  # way, and on an old system the list runs to dozens.
  text="App Studio needs glibc $required or later ($examples). This system ${glibc:+has $glibc and }lacks $missing_versions."
else
  title="App Studio is missing system libraries"
  text="App Studio needs these libraries, which this system does not have: $missing_libs. Install them with your distribution's package manager."
fi
printf '%s\n' "$text" >&2
# Started from a launcher, nobody reads stderr: show a window as well.
if [ -n "$WAYLAND_DISPLAY$DISPLAY" ]; then
  show_window "$title" "$text"
fi
exit 1
APPRUN
sed -i -e "s/@GLIBC_REQUIRED@/$glibc_required/" \
  -e "s/@GLIBC_EXAMPLES@/$glibc_examples/" "$appdir/AppRun"
chmod +x "$appdir/AppRun"

# --- AppImage --------------------------------------------------------------

# appimagetool and the runtime it puts in front of the image are pinned and
# checked against their sha256, as WinSparkle is on Windows. Left to itself,
# appimagetool would also fetch the runtime from the moving "continuous"
# release on every run.
appimagetool_version=1.9.1
appimagetool_sha256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
runtime_version=20251108
runtime_sha256=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
tools="$root/build/linux/tools"

# Downloads $1 to $2 unless a file with sha256 $3 is already there.
fetch_pinned() {
  local url="$1" dest="$2" sha="$3"
  if [[ -f "$dest" ]] && echo "$sha  $dest" | sha256sum -c --status; then
    return
  fi
  step "Downloading $url"
  mkdir -p "$(dirname "$dest")"
  curl -fsSL -o "$dest.part" "$url"
  if ! echo "$sha  $dest.part" | sha256sum -c --status; then
    rm -f "$dest.part"
    echo "Checksum mismatch for $url" >&2
    exit 1
  fi
  mv "$dest.part" "$dest"
}

tool="${APPIMAGETOOL:-}"
if [[ -z "$tool" ]]; then
  tool="$tools/appimagetool-$appimagetool_version-x86_64.AppImage"
  fetch_pinned \
    "https://github.com/AppImage/appimagetool/releases/download/$appimagetool_version/appimagetool-x86_64.AppImage" \
    "$tool" "$appimagetool_sha256"
  chmod +x "$tool"
fi
runtime="$tools/runtime-$runtime_version-x86_64"
fetch_pinned \
  "https://github.com/AppImage/type2-runtime/releases/download/$runtime_version/runtime-x86_64" \
  "$runtime" "$runtime_sha256"

update=()
if [[ -n "${APPIMAGE_UPDATE_INFO:-}" ]]; then
  update=(--updateinformation "$APPIMAGE_UPDATE_INFO")
  if [[ -n "${APPIMAGE_FILE_URL:-}" ]]; then
    update+=(--file-url "$APPIMAGE_FILE_URL")
  fi
elif [[ -n "${APPIMAGE_FILE_URL:-}" ]]; then
  echo "APPIMAGE_FILE_URL needs APPIMAGE_UPDATE_INFO: it only goes into the .zsync." >&2
  exit 1
fi

step "Packing $out"
mkdir -p "$dist"
rm -f "$out" "$out.zsync"
# CI runners have no FUSE; extract-and-run works everywhere. appimagetool
# writes the .zsync into the working directory. VERSION is unset because
# appimagetool would write it over the desktop entry's X-AppImage-Version: a
# VERSION left in the caller's environment would ship as App Studio's.
(
  cd "$dist"
  env -u VERSION APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 \
    "$tool" --runtime-file "$runtime" "${update[@]}" "$appdir" "$out"
)
if [[ -n "${APPIMAGE_UPDATE_INFO:-}" && ! -s "$out.zsync" ]]; then
  echo "appimagetool wrote no $out.zsync." >&2
  exit 1
fi

step "Built $out ($(du -h "$out" | cut -f1))"
