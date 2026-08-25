# App Studio — every command for running the app, releasing it, and publishing
# the bundled tools. The Makefile is the whole interface: no release step
# should require running a tool/ script by hand.
#
# Run locally:
#   make start             Run the app (flutter run -d macos)
#   make deps              flutter pub get + CEF/pods
#   make previews          Browser previews of the first-run dialogs
#   make clean             Drop build output and dist artifacts
#   make clean_all         Also drop CEF, Pods and the dev toolchain
#
# Release the app (two steps, so a build can be tested before it goes live):
#   make release V=1.2.3   Set the version, build, notarize, upload — the build
#                          is downloadable and testable, existing installs
#                          are NOT updated yet
#   make promote           Put the uploaded build in the appcast: auto-update
#                          goes live for every existing install
#
#   make set_version V=…   Set the version and bump the build counter
#   make build             Signed + notarized zip in dist/, nothing uploaded
#   make publish           Upload the built zip + refresh downloads/macos.json
#   make build_debug       Unsigned zip, local only
#
# Publish the bundled tools:
#   make update_flutter    Download the full Flutter/Dart SDK; V=… sets the pin
#   make update_serverpod  Copy the Serverpod CLI from this Mac's dart install
#   make dev_toolchain     Build every toolchain/ tree
#   make publish_toolchain Upload the tools to GCS and refresh the manifest
#
.DEFAULT_GOAL := help

# Recipes use [[ ]] and read -p.
SHELL := /bin/bash

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
CEF_STAMP := $(ROOT)/packages/webview_cef/macos/third/cef/version.txt

.PHONY: help start deps ensure_deps previews clean clean_all \
        set_version release build build_debug publish promote \
        update_flutter update_serverpod dev_toolchain publish_toolchain

help:
	@echo "Run locally:"
	@echo "  make start             Run the app (flutter run -d macos)"
	@echo "  make deps              flutter pub get + CEF/pods"
	@echo "  make previews          Browser previews of the first-run dialogs"
	@echo "  make clean             Remove build/ and dist/ (keeps CEF + toolchain)"
	@echo "  make clean_all         Also remove CEF, Pods and <repo>/toolchain"
	@echo ""
	@echo "Release the app:"
	@echo "  make release V=1.2.3   Set the version (or V=patch|minor|major|build),"
	@echo "                         build, notarize, upload. Testable by direct"
	@echo "                         download; existing installs are NOT updated yet."
	@echo "  make promote           Put the uploaded build in the appcast —"
	@echo "                         auto-update goes live for every install"
	@echo ""
	@echo "  make set_version V=…   Set the version and bump the build counter"
	@echo "  make build             Signed + notarized zip in dist/, no upload"
	@echo "  make publish           Upload the built zip + refresh the download links"
	@echo "  make build_debug       Unsigned zip, local only"
	@echo ""
	@echo "Publish the bundled tools:"
	@echo "  make update_flutter [V=3.44.2]     Download the SDK and set the pin"
	@echo "  make update_serverpod [V=4.0.0]    Copy the CLI from the dart install"
	@echo "  make dev_toolchain                 Build every <repo>/toolchain tree"
	@echo "  make publish_toolchain             Dry-run, confirm, then upload"
	@echo ""
	@echo "The app downloads its own tools on first run, so no toolchain is"
	@echo "needed to build or ship it. The toolchain targets are for publishing"
	@echo "new tool versions to the bucket."

# ---------------------------------------------------------------------------
# Run locally
# ---------------------------------------------------------------------------

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

start: ensure_deps
	@echo "==> flutter run -d macos"
	cd "$(ROOT)" && flutter run -d macos

# Widget previews for iterating on copy and layout. Runs in a browser — the
# only target the preview scaffold supports — which is why everything under
# lib/previews/ and the UI it renders must stay free of dart:io.
previews:
	cd "$(ROOT)" && flutter widget-preview start

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

# ---------------------------------------------------------------------------
# Release the app
#
# Two deliberate halves. `make release` ends with the build uploaded and
# testable by direct download, but invisible to auto-update; `make promote`
# is the separate, confirmed step that puts it in the appcast. That split is
# what lets a build be tried on another Mac before every install is offered it.
# ---------------------------------------------------------------------------

# Set the version. The build counter is bumped automatically and never reset —
# Sparkle compares CFBundleVersion, so a repeat or a rollback would make every
# installed copy stop seeing updates. It clears promoted releases AND uploads
# still waiting for promotion.
#
#   make set_version V=1.2.3     make set_version V=patch
set_version:
	@test -n "$(V)" || { \
		echo "usage: make set_version V=1.2.3   (or V=patch|minor|major|build)"; \
		exit 1; \
	}
	cd "$(ROOT)" && ./tool/set_version.sh "$(V)"

# Build, sign and notarize the zip into dist/macos. Nothing is uploaded.
build: ensure_deps
	@echo "==> distribute (signed + notarized)"
	cd "$(ROOT)" && NOTARIZE=1 ./tool/distribute_macos.sh

# Unsigned zip for local smoke tests on other Macs (xattr -cr may still be
# needed there). Never uploaded.
build_debug: ensure_deps
	@echo "==> distribute (unsigned, no notarization)"
	cd "$(ROOT)" && SIGN_IDENTITY="" NOTARIZE=0 ./tool/distribute_macos.sh

# Upload the built zip to the immutable releases/ path and point the
# downloads/macos.json "preview" entry at it. Does NOT touch the appcast.
# Safe to re-run: an upload of identical bytes is recognised and skipped.
publish:
	cd "$(ROOT)" && ./tool/publish_dist.sh

# The whole first half in one action: set the version, build, upload.
release: set_version
	@$(MAKE) build
	@$(MAKE) publish

# The second half: add the uploaded build to the Sparkle appcast, after which
# every installed copy is offered it. Asks first — this is the step that
# reaches users, and it cannot be taken back (build numbers never repeat).
promote:
	@grep '^version:' "$(ROOT)/pubspec.yaml" | sed 's/^version: */  about to promote: /'
	@read -r -p "Make this build the live auto-update for every install? [y/N] " a; \
		[[ $$a == [yY]* ]] || { echo "aborted"; exit 1; }
	cd "$(ROOT)" && ./tool/publish_appcast.sh

# ---------------------------------------------------------------------------
# Publish the bundled tools
# ---------------------------------------------------------------------------

# Builds the <repo>/toolchain trees that publish_toolchain uploads.
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
	@echo "Flutter updated. Publish it with: make publish_toolchain"

# `dart install serverpod_cli <version>` first — pub publishes no macOS archive,
# so the tree is copied from the bundle that command unpacks.
update_serverpod:
	cd "$(ROOT)" && ./tool/bundle_toolchain.sh --only=serverpod_cli --force \
		$(if $(V),--serverpod=$(V))
	@echo ""
	@echo "Serverpod CLI updated. Raise hostAccepts in"
	@echo "assets/toolchain_manifest.json if this is a new minimum, then:"
	@echo "  make publish_toolchain"

# Dry-run first, then confirm before uploading for real. Uploads are immutable
# and cannot be undone with the publisher role, which is why the dry run is
# not optional.
publish_toolchain:
	cd "$(ROOT)" && ./tool/publish_toolchain.sh --dry-run
	@echo ""
	@read -r -p "Dry run above. Publish for real? [y/N] " a; \
		[[ $$a == [yY]* ]] || { echo "aborted"; exit 1; }
	cd "$(ROOT)" && ./tool/publish_toolchain.sh
