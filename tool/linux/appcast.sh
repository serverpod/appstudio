#!/usr/bin/env bash
# Signs an AppImage and adds it to a Linux update feed, newest first.
#
# Usage:
#   tool/linux/appcast.sh --key <private.pem> --url <download URL> \
#     --feed <appcast.xml> <AppStudio-<version>-x86_64.AppImage>
#
#   --key   the Ed25519 private key, PEM, as `openssl genpkey -algorithm
#           ed25519` writes it. Never commit it.
#   --url   where the AppImage will be downloaded from, as installed copies
#           will fetch it: https (plain http only to a private address).
#   --feed  the appcast to add the item to; created when it does not exist.
#
# The version and build come from the AppImage itself (the version.json
# Flutter writes into the bundle), so a feed can never describe a file as
# another build. The script refuses a build the feed already has or has
# passed: installed copies order releases by build alone, and one served
# twice, or lower, would never be offered.
#
# The signature is checked against the public key in linux/release.json, the
# key installed copies carry, before the feed is written. With no key there
# yet (a local feed), the key is derived from --key and the script says so;
# such a feed only reaches builds made with
# APPSTUDIO_EDDSA_PUBLIC_KEY set to that key.
#
# Runs on Linux only: it runs the AppImage to read its version, and uses GNU
# stat and base64. Needs OpenSSL 3 (for `pkeyutl -rawin`), python3 and GNU
# coreutils.
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
  echo "appcast.sh runs on Linux only: it runs the AppImage to read its" \
    "version. Run it on the machine or CI job that built the AppImage." >&2
  exit 1
fi

root="$(cd "$(dirname "$0")/../.." && pwd)"
key="" url="" feed=""
while (( $# )); do
  case "$1" in
    --key) key="$2"; shift 2 ;;
    --url) url="$2"; shift 2 ;;
    --feed) feed="$2"; shift 2 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
if [[ -z "$key" || -z "$url" || -z "$feed" || $# -ne 1 ]]; then
  sed -n '4,6p' "$0" | sed 's/^# //' >&2
  exit 2
fi
appimage="$1"
for cmd in openssl python3 base64; do
  command -v "$cmd" > /dev/null || { echo "Missing on this machine: $cmd" >&2; exit 1; }
done
[[ -f "$appimage" ]] || { echo "No such file: $appimage" >&2; exit 1; }
# Its version is read by running it (--appimage-extract).
[[ -x "$appimage" ]] || { echo "Not executable (chmod +x it): $appimage" >&2; exit 1; }
# https only, as installed copies insist; plain http only to this machine or
# a private address, for a local feed.
if ! python3 -c '
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
sys.exit(0 if any(ip in ipaddress.ip_network(n) for n in nets) else 1)' "$url"; then
  echo "The download URL must be an https address: $url" >&2
  exit 1
fi
[[ -f "$key" ]] || { echo "No such key: $key" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- What the AppImage is ----------------------------------------------------

appimage_abs="$(cd "$(dirname "$appimage")" && pwd)/$(basename "$appimage")"
(cd "$work" && "$appimage_abs" --appimage-extract \
  usr/lib/appstudio/data/flutter_assets/version.json > /dev/null)
version_json="$work/squashfs-root/usr/lib/appstudio/data/flutter_assets/version.json"
[[ -f "$version_json" ]] || { echo "No version.json in $appimage." >&2; exit 1; }
read -r version build < <(python3 -c '
import json, sys
v = json.load(open(sys.argv[1]))
print(v["version"], v["build_number"])' "$version_json")
length="$(stat -c %s "$appimage")"
echo "==> AppStudio $version (build $build), $length bytes"

# --- Signature ---------------------------------------------------------------

openssl pkeyutl -sign -inkey "$key" -rawin -in "$appimage" -out "$work/sig.bin"
signature="$(base64 -w0 "$work/sig.bin")"

shipped="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("eddsaPublicKey", ""))' \
  "$root/linux/release.json")"
if [[ -z "$shipped" ]]; then
  shipped="$(openssl pkey -in "$key" -pubout -outform DER | tail -c 32 | base64 -w0)"
  echo "linux/release.json names no public key: checking against the key's own."
  echo "Builds see this feed only with APPSTUDIO_EDDSA_PUBLIC_KEY=$shipped"
fi
# The raw 32-byte key, wrapped as the DER openssl reads.
python3 -c '
import base64, sys
raw = base64.b64decode(sys.argv[1], validate=True)
assert len(raw) == 32, "the public key is not 32 bytes"
der = bytes.fromhex("302a300506032b6570032100") + raw
sys.stdout.buffer.write(der)' "$shipped" > "$work/public.der"
if ! openssl pkeyutl -verify -pubin -keyform DER -inkey "$work/public.der" \
  -rawin -in "$appimage" -sigfile "$work/sig.bin" > /dev/null; then
  echo "The signature does not verify against the shipped public key." >&2
  exit 1
fi

# --- The feed ----------------------------------------------------------------

python3 - "$feed" "$version" "$build" "$url" "$length" "$signature" << 'PY'
import email.utils, os, re, sys, tempfile
import xml.etree.ElementTree as ET
from xml.sax.saxutils import quoteattr, escape

feed, version, build, url, length, signature = sys.argv[1:]
build = int(build)
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"

if os.path.exists(feed):
    text = open(feed, encoding="utf-8").read()
    channel = ET.fromstring(text).find("channel")
    if channel is None:
        sys.exit("The feed has no <channel>.")
    builds = [
        int(e.get(f"{{{SPARKLE}}}version"))
        for e in channel.iter("enclosure")
        if e.get(f"{{{SPARKLE}}}os") == "linux-x86_64"
    ]
    if builds and build <= max(builds):
        sys.exit(f"The feed already serves build {max(builds)}; this is {build}.")
else:
    text = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f'<rss version="2.0" xmlns:sparkle="{SPARKLE}">\n'
        "  <channel>\n"
        "    <title>App Studio for Linux</title>\n"
        "    <link>https://serverpod.dev</link>\n"
        "  </channel>\n"
        "</rss>\n"
    )

item = f"""<item>
      <title>Version {escape(version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <enclosure url={quoteattr(url)}
                 sparkle:version="{build}"
                 sparkle:shortVersionString={quoteattr(version)}
                 sparkle:os="linux-x86_64"
                 sparkle:edSignature="{signature}"
                 length="{length}"
                 type="application/octet-stream" />
    </item>
    """
# Newest first: before the first item, or at the end of the channel.
first = text.find("<item>")
if first >= 0:
    text = text[:first] + item + text[first:]
else:
    text = re.sub(r"(\s*)</channel>", "\n    " + item.rstrip() + r"\1</channel>", text, count=1)

ET.fromstring(text)  # still well-formed
folder = os.path.dirname(os.path.abspath(feed))
fd, tmp = tempfile.mkstemp(dir=folder, prefix=".appcast-")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(text)
os.chmod(tmp, 0o644)
os.replace(tmp, feed)
PY
echo "==> Added build $build to $feed"
