# App Studio — common developer / release commands
#
#   make start             Run locally (macOS)
#   make deps              Pub get + CEF/pods
#   make clean             Drop build output and dist artifacts
#   make clean_all         Also drop CEF, Pods and the dev toolchain
#   make dev_toolchain     Build a local toolchain/ tree (optional)
#   make publish_toolchain Upload tools to GCS and refresh the manifest
#   make dist              Signed + notarized DMG, published to the bucket
#   make publish_dist      Upload an already-built DMG
#   make dist_debug        Unsigned DMG, local only
#
.DEFAULT_GOAL := help

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
CEF_STAMP := $(ROOT)/packages/webview_cef/macos/third/cef/version.txt

.PHONY: help start deps ensure_deps clean clean_all dev_toolchain \
        publish_toolchain publish_dist dist dist_debug

help:
	@echo "App Studio targets:"
	@echo "  make start             Run the app locally (flutter run -d macos)"
	@echo "  make deps              flutter pub get + CEF/pods"
	@echo "  make clean             Remove build/ and dist/ (keeps CEF + toolchain)"
	@echo "  make clean_all         Also remove CEF, Pods and <repo>/toolchain"
	@echo "  make dev_toolchain     Build <repo>/toolchain for offline dev (optional)"
	@echo "  make publish_toolchain Dry-run the toolchain publish"
	@echo "  make dist              Build, notarize AND publish the DMG to the bucket"
	@echo "                         (PUBLISH=0 make dist stops at the local DMG)"
	@echo "  make publish_dist      Upload an already-built DMG"
	@echo "  make dist_debug        Local unsigned DMG, never uploaded"
	@echo ""
	@echo "The app downloads its own tools on first run, so no toolchain is"
	@echo "needed to build or ship it. dev_toolchain is only for working offline."

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

# Optional: build <repo>/toolchain. The app prefers that tree over anything it
# would download, which is handy offline — but it is no longer required.
dev_toolchain:
	cd "$(ROOT)" && ./tool/bundle_toolchain.sh

# Release engineers only. Uploads are immutable and cannot be undone with the
# publisher role, so this target only ever dry-runs.
publish_toolchain:
	cd "$(ROOT)" && ./tool/publish_toolchain.sh --dry-run
	@echo ""
	@echo "Dry run above. To publish for real:"
	@echo "  ./tool/publish_toolchain.sh"

start: ensure_deps
	@echo "==> flutter run -d macos"
	cd "$(ROOT)" && flutter run -d macos

# Build, sign, notarize, then publish the DMG to the public bucket.
#
# This uploads. Object names are immutable, so a mistake means bumping the
# build number in pubspec.yaml rather than replacing anything. Use
# `PUBLISH=0 make dist` to stop after the local DMG.
dist: ensure_deps
	@echo "==> distribute (signed + notarized)"
	cd "$(ROOT)" && NOTARIZE=1 ./tool/distribute_macos.sh
	@if [ "$(PUBLISH)" = "0" ]; then \
		echo "==> PUBLISH=0 — built locally, not uploaded"; \
	else \
		cd "$(ROOT)" && ./tool/publish_dist.sh; \
	fi

# Re-upload an already-built DMG (e.g. the upload failed but the build is fine).
publish_dist:
	cd "$(ROOT)" && ./tool/publish_dist.sh

# Unsigned DMG for local smoke tests on other Macs (xattr -cr may still be needed).
dist_debug: ensure_deps
	@echo "==> distribute (unsigned, no notarization)"
	cd "$(ROOT)" && SIGN_IDENTITY="" NOTARIZE=0 ./tool/distribute_macos.sh
