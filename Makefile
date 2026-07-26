# App Studio — common developer / release commands
#
#   make start           Run locally (macOS)
#   make build_toolchain Pub get, CEF/pods, bundled toolchain/
#   make dist            Signed + notarized DMG
#   make dist_debug      Unsigned DMG (no notarization)
#
.DEFAULT_GOAL := help

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TOOLCHAIN := $(ROOT)/toolchain
ACTIVE := $(TOOLCHAIN)/active.json
CEF_STAMP := $(ROOT)/packages/webview_cef/macos/third/cef/version.txt

.PHONY: help start build_toolchain ensure_toolchain dist dist_debug

help:
	@echo "App Studio targets:"
	@echo "  make start            Run the app locally (flutter run -d macos)"
	@echo "  make build_toolchain  flutter pub get + CEF/pods + toolchain/"
	@echo "  make dist             Release DMG with Developer ID + notarization"
	@echo "  make dist_debug       Release DMG without signing / notarization"
	@echo ""
	@echo "start / dist / dist_debug call ensure_toolchain first (builds if missing)."

# True when bundled toolchain + CEF cache look complete enough to build/run.
define toolchain_ready
	test -f "$(ACTIVE)" \
	&& FLUTTER_VER=$$(python3 -c 'import json; print(json.load(open("$(ACTIVE)"))["flutter"])') \
	&& CLI_VER=$$(python3 -c 'import json; print(json.load(open("$(ACTIVE)"))["serverpod_cli"])') \
	&& GIT_VER=$$(python3 -c 'import json; print(json.load(open("$(ACTIVE)")).get("git",""))') \
	&& test -x "$(TOOLCHAIN)/flutter/$$FLUTTER_VER/bin/flutter" \
	&& test -x "$(TOOLCHAIN)/serverpod_cli/$$CLI_VER/bin/serverpod" \
	&& test -d "$(TOOLCHAIN)/serverpod_cli/$$CLI_VER/lib" \
	&& test -n "$$GIT_VER" && test -x "$(TOOLCHAIN)/git/$$GIT_VER/bin/git" \
	&& test -x "$(TOOLCHAIN)/cctools/bin/otool" \
	&& test -x "$(TOOLCHAIN)/cctools/bin/install_name_tool" \
	&& test -f "$(CEF_STAMP)"
endef

ensure_toolchain:
	@if $(toolchain_ready); then \
		echo "==> Toolchain ready"; \
	else \
		echo "==> Toolchain incomplete — running build_toolchain"; \
		$(MAKE) build_toolchain; \
	fi

# Full host setup: Dart deps, CocoaPods/CEF download, versioned toolchain/.
build_toolchain:
	@echo "==> flutter pub get"
	cd "$(ROOT)" && flutter pub get
	@echo "==> macOS pods / CEF"
	cd "$(ROOT)/macos" && pod install
	@echo "==> bundle toolchain/"
	cd "$(ROOT)" && ./tool/bundle_toolchain.sh

start: ensure_toolchain
	@echo "==> flutter run -d macos"
	cd "$(ROOT)" && flutter run -d macos

# Signed + notarized (defaults in tool/distribute_macos.sh).
dist: ensure_toolchain
	@echo "==> distribute (signed + notarized)"
	cd "$(ROOT)" && NOTARIZE=1 ./tool/distribute_macos.sh

# Unsigned DMG for local smoke tests on other Macs (xattr -cr may still be needed).
dist_debug: ensure_toolchain
	@echo "==> distribute (unsigned, no notarization)"
	cd "$(ROOT)" && SIGN_IDENTITY="" NOTARIZE=0 ./tool/distribute_macos.sh
