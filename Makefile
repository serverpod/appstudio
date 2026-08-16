# App Studio — common developer / release commands
#
#   make start             Run locally (macOS)
#   make deps              Pub get + CEF/pods
#   make clean             Drop build output and dist artifacts
#   make clean_all         Also drop CEF, Pods and the dev toolchain
#   make dev_toolchain     Build every toolchain/ tree (for publishing)
#   make update_flutter    Download the full Flutter/Dart SDK; V=… sets the pin
#   make update_serverpod  Copy the Serverpod CLI from this Mac's dart install
#   make publish_toolchain Upload tools to GCS and refresh the manifest
#   make previews          Browser previews of every dialog (hot reload)
#   make set_version V=…   Set the version and bump the build counter
#   make release V=…       set_version + dist, in one step
#   make dist              Signed + notarized zip, published to the bucket
#   make publish_dist      Upload an already-built zip
#   make publish_appcast   Regenerate + upload the Sparkle update feed
#   make dist_debug        Unsigned zip, local only
#
.DEFAULT_GOAL := help

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
CEF_STAMP := $(ROOT)/packages/webview_cef/macos/third/cef/version.txt

.PHONY: help start deps ensure_deps clean clean_all dev_toolchain \
        update_flutter update_serverpod \
        publish_toolchain publish_dist publish_appcast dist dist_debug \
        set_version release previews

help:
	@echo "App Studio targets:"
	@echo "  make start             Run the app locally (flutter run -d macos)"
	@echo "  make deps              flutter pub get + CEF/pods"
	@echo "  make clean             Remove build/ and dist/ (keeps CEF + toolchain)"
	@echo "  make clean_all         Also remove CEF, Pods and <repo>/toolchain"
	@echo "  make dev_toolchain     Build every <repo>/toolchain tree"
	@echo "  make update_flutter [V=3.44.2]"
	@echo "                         Download the full Flutter/Dart SDK and pin V"
	@echo "                         (no V: rebuild the currently pinned version)"
	@echo "  make update_serverpod [V=4.0.0-beta.2]"
	@echo "                         Copy the Serverpod CLI from the local dart install"
	@echo "  make publish_toolchain Dry-run the toolchain publish"
	@echo "  make previews          Browser previews of every dialog (hot reload)"
	@echo "  make set_version V=1.2.3   Set the version (or V=patch|minor|major|build)"
	@echo "  make release V=1.2.3       set_version, then dist — one step"
	@echo "  make dist              Build, notarize AND publish the zip to the bucket"
	@echo "                         (PUBLISH=0 make dist stops at the local zip)"
	@echo "  make publish_dist      Upload an already-built zip"
	@echo "  make publish_appcast   Regenerate + upload the Sparkle update feed"
	@echo "  make dist_debug        Local unsigned zip, never uploaded"
	@echo ""
	@echo "The app downloads its own tools on first run, so no toolchain is"
	@echo "needed to build or ship it. The toolchain targets are for publishing"
	@echo "new tool versions to the bucket."

# CEF is the one thing that must exist before the app can build at all.
ensure_deps:
	@if test -f "$(CEF_STAMP)"; then \
		echo "==> CEF ready"; \
	else \
		echo "==> CEF missing — running deps"; \
		$(MAKE) deps; \
	fi

deps:
	@echo "==> flutter pub get"
	cd "$(ROOT)" && flutter pub get
	@echo "==> macOS pods / CEF"
	cd "$(ROOT)/macos" && pod install

# Xcode leaves unknown files under Contents/Resources between builds, so a tree
# from before the toolchain moved out keeps a ~1.8 GB embed alive. distribute
# drops it defensively, but a clean build tree is the honest fix.
clean:
	@echo "==> flutter clean"
	cd "$(ROOT)" && flutter clean
	@echo "==> removing dist/"
	rm -rf "$(ROOT)/dist"
	@echo ""
	@echo "Kept (expensive to re-fetch, use clean_all to drop them too):"
	@echo "  packages/webview_cef/macos/third/cef   CEF binaries"
	@echo "  macos/Pods                             CocoaPods"
	@echo "  toolchain/                             local dev toolchain"
	@echo ""
	@echo "flutter clean also removed .dart_tool, so dart analyze will report"
	@echo "thousands of unresolved imports until you run: flutter pub get"

# Back to a fresh checkout. Re-fetches CEF (~380 MB) on the next build, and
# dev_toolchain would re-download Flutter and LLVM.
clean_all: clean
	@echo "==> removing CEF, Pods and the dev toolchain"
	rm -rf "$(ROOT)/packages/webview_cef/macos/third/cef"
	rm -rf "$(ROOT)/macos/Pods"
	rm -rf "$(ROOT)/toolchain/flutter" "$(ROOT)/toolchain/git" \
	       "$(ROOT)/toolchain/opencode" "$(ROOT)/toolchain/llvm-tools"
	@echo "    kept toolchain/{active.json,pins,bin,serverpod_cli} — tracked in git"

# Builds the <repo>/toolchain trees that publish_toolchain.sh uploads.
#
# The app itself never reads this tree — it resolves each tool as managed (its
# own Application Support directory) then host, and nothing else — so this is a
# packaging step for a release, not a way to run App Studio against local tools.
dev_toolchain:
	cd "$(ROOT)" && ./tool/bundle_toolchain.sh

# Update one tool in the tree, then publish. Both take an optional V=, which
# becomes the new pin in toolchain/active.json; without one they rebuild the
# version that file already pins. Tools not named keep their pins too, so a
# partial run cannot quietly move a pin for a tree it never rebuilt.
#
# Flutter carries the Dart SDK (bin/cache/dart-sdk), so this is how Dart moves
# too — there is no separate dart tool in the toolchain.
update_flutter:
	cd "$(ROOT)" && ./tool/bundle_toolchain.sh --only=flutter --force \
		$(if $(V),--flutter=$(V))
	@echo ""
	@echo "Flutter updated. Publish it with:"
	@echo "  ./tool/publish_toolchain.sh --only=flutter --dry-run"
	@echo "  ./tool/publish_toolchain.sh --only=flutter"

# `dart install serverpod_cli <version>` first — pub publishes no macOS archive,
# so the tree is copied from the bundle that command unpacks.
update_serverpod:
	cd "$(ROOT)" && ./tool/bundle_toolchain.sh --only=serverpod_cli --force \
		$(if $(V),--serverpod=$(V))
	@echo ""
	@echo "Serverpod CLI updated. Raise hostAccepts in"
	@echo "assets/toolchain_manifest.json if this is a new minimum, then:"
	@echo "  ./tool/publish_toolchain.sh --only=serverpod_cli --dry-run"
	@echo "  ./tool/publish_toolchain.sh --only=serverpod_cli"

# Release engineers only. Uploads are immutable and cannot be undone with the
# publisher role, so this target only ever dry-runs.
publish_toolchain:
	cd "$(ROOT)" && ./tool/publish_toolchain.sh --dry-run
	@echo ""
	@echo "Dry run above. To publish for real:"
	@echo "  ./tool/publish_toolchain.sh"

# Widget previews for iterating on copy and layout. Runs in a browser — the
# only target the preview scaffold supports — which is why everything under
# lib/previews/ and the UI it renders must stay free of dart:io.
previews:
	cd "$(ROOT)" && flutter widget-preview start

start: ensure_deps
	@echo "==> flutter run -d macos"
	cd "$(ROOT)" && flutter run -d macos

# Set the version. The build counter is bumped automatically and never reset —
# Sparkle compares CFBundleVersion, so a repeat or a rollback would make every
# installed copy stop seeing updates.
#
#   make set_version V=1.2.3     make set_version V=patch
set_version:
	@test -n "$(V)" || { \
		echo "usage: make set_version V=1.2.3   (or V=patch|minor|major|build)"; \
		exit 1; \
	}
	cd "$(ROOT)" && ./tool/set_version.sh "$(V)"

# The whole release in one action: set the version, build, sign, notarize,
# publish. PUBLISH=0 stops after the local zip.
release: set_version
	@$(MAKE) dist

# Build, sign, notarize, then publish the zip to the public bucket.
#
# This uploads. Object names are immutable, so a mistake means bumping the
# build number in pubspec.yaml rather than replacing anything. Use
# `PUBLISH=0 make dist` to stop after the local zip.
dist: ensure_deps
	@echo "==> distribute (signed + notarized)"
	cd "$(ROOT)" && NOTARIZE=1 ./tool/distribute_macos.sh
	@if [ "$(PUBLISH)" = "0" ]; then \
		echo "==> PUBLISH=0 — built locally, not uploaded"; \
	else \
		cd "$(ROOT)" && ./tool/publish_dist.sh && ./tool/publish_appcast.sh; \
	fi

# Re-upload an already-built zip (e.g. the upload failed but the build is fine).
publish_dist:
	cd "$(ROOT)" && ./tool/publish_dist.sh

# Rebuild the Sparkle feed from everything published and upload it.
#
# The appcast is the only mutable object in the bucket, and it is what every
# installed copy asks for updates. Signing needs the private key from the login
# Keychain, so macOS may prompt. Dry-run first; the target does that for you and
# leaves appcast-dry-run.xml to inspect.
publish_appcast:
	cd "$(ROOT)" && ./tool/publish_appcast.sh --dry-run
	@echo ""
	@echo "Dry run above. To publish for real:"
	@echo "  ./tool/publish_appcast.sh"

# Unsigned zip for local smoke tests on other Macs (xattr -cr may still be needed).
dist_debug: ensure_deps
	@echo "==> distribute (unsigned, no notarization)"
	cd "$(ROOT)" && SIGN_IDENTITY="" NOTARIZE=0 ./tool/distribute_macos.sh
