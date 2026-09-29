# App Studio — every command for running the app and releasing it. The
# Makefile is the whole interface: no release step should require running a
# tool/ script by hand.
#
# Run locally:
#   make start             Run the app (flutter run -d macos)
#   make deps              flutter pub get + CEF/pods
#   make previews          Browser previews of the first-run dialogs
#   make clean             Drop build output and dist artifacts
#   make clean_all         Also drop CEF and Pods
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
.DEFAULT_GOAL := help

# Recipes use [[ ]] and read -p.
SHELL := /bin/bash

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
CEF_STAMP := $(ROOT)/packages/webview_cef/macos/third/cef/version.txt

.PHONY: help start deps ensure_deps previews clean clean_all \
        set_version release build build_debug publish promote

help:
	@echo "Run locally:"
	@echo "  make start             Run the app (flutter run -d macos)"
	@echo "  make deps              flutter pub get + CEF/pods"
	@echo "  make previews          Browser previews of the first-run dialogs"
	@echo "  make clean             Remove build/ and dist/ (keeps CEF)"
	@echo "  make clean_all         Also remove CEF and Pods"
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
	@echo "The app installs Flutter and the Serverpod CLI from their official"
	@echo "sources on first run, so no toolchain is needed to build or ship it."

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
	@echo ""
	@echo "flutter clean also removed .dart_tool, so dart analyze will report"
	@echo "thousands of unresolved imports until you run: flutter pub get"

# Back to a fresh checkout. Re-fetches CEF (~380 MB) on the next build. Also
# drops toolchain/, what the retired tool-publishing pipeline left behind.
clean_all: clean
	@echo "==> removing CEF, Pods and any old toolchain/ build trees"
	rm -rf "$(ROOT)/packages/webview_cef/macos/third/cef"
	rm -rf "$(ROOT)/macos/Pods"
	rm -rf "$(ROOT)/toolchain"

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
