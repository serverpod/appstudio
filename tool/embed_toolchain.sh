#!/usr/bin/env bash
# Xcode Run Script phase — toolchain embed is deferred to post-build.
#
# Copying the multi-GB toolchain during xcodebuild (while CEF is linking) often
# gets SIGKILL'd under memory pressure. Use copy_toolchain_into_app.sh after the
# build completes (distribute_macos.sh does this automatically).
set -euo pipefail

if [[ "${CONFIGURATION:-}" == "Debug" ]]; then
  echo "note: Debug build — not embedding toolchain (host flutter/dart/serverpod)"
  exit 0
fi

echo "note: ${CONFIGURATION:-Release} build — deferring toolchain embed to post-build"
echo "note: distribute_macos.sh embeds automatically after flutter build"
