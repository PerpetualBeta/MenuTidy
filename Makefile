# MenuTidy — menu-bar app that hides cluttered status icons.
#
# Drives day-to-day dev iteration AND the release pipeline. The release
# pipeline delegates to the shared `release.mk` include in
# PerpetualBeta/jorvik-release; the dev targets below are MenuTidy-specific
# and intentionally fast — no stamping, signing, or notarisation.

# ─── Project identity ────────────────────────────────────────────────────────
BUNDLE_NAME      := MenuTidy
BUNDLE_TYPE      := app
PRODUCT_NAME     := MenuTidy.app
BUNDLE_ID        := cc.jorviksoftware.MenuTidy
BUILD_SYSTEM     := swiftc

SWIFT_FRAMEWORKS := Cocoa ServiceManagement SwiftUI
SWIFT_SOURCES    := main.swift \
                    MenuBarRestriction.swift \
                    MenuBarInventory.swift \
                    NotchWarning.swift \
                    AboutView.swift \
                    MenuTidySettingsContent.swift

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
ENTITLEMENTS     := MenuTidy.entitlements

include ../jorvik-release/release.mk

# Override release.mk's default goal: a bare `gmake` should build a fast
# local app, not run a full release pipeline.
.DEFAULT_GOAL := dev-build

# ─── Dev iteration targets (MenuTidy-specific) ───────────────────────────────
.PHONY: dev-build dev-install

LOCAL_BUNDLE := MenuTidy.app
LOCAL_INSTALL_DIR := /Applications

# Local builds are signed with the real Developer ID, not ad-hoc.
#
# This app cannot collapse the menu bar without Accessibility, and macOS keys a
# TCC grant to the signing identity. An ad-hoc signature is a DIFFERENT identity,
# so every grant the app holds is silently withheld: no error, no prompt, the
# feature simply does nothing. That cost five wasted install-and-test rounds on
# 2026-09-19 before it was spotted.
#
# `codesign --verify --strict` PASSES on an ad-hoc bundle, so it does not catch
# this. Only the Team ID does, which is what the gate below checks.
LOCAL_SIGN_ID  := Developer ID Application: Jonthan Hollin (EG86BCGUE7)
LOCAL_TEAM_ID  := EG86BCGUE7
SIGN_FRAMEWORK := ../jorvik-release/helpers/sign-framework.sh

# Single-arch fast build for local install. Bypasses release.mk's universal
# binary + version stamping for speed, but NOT its signing identity.
dev-build:
	@echo "→ dev build (arm64 only, Developer ID)"
	# Start from nothing. Without this, `cp -R Sparkle.framework <dest>` copies
	# INTO the existing directory on every rebuild after the first, producing
	# Sparkle.framework/Sparkle.framework. codesign then reports "unsealed
	# contents present in the root directory of an embedded framework", the
	# signature is not a valid Developer ID one, and macOS silently withholds
	# every TCC permission the app has been granted.
	@rm -rf $(LOCAL_BUNDLE)
	@mkdir -p $(LOCAL_BUNDLE)/Contents/MacOS $(LOCAL_BUNDLE)/Contents/Resources $(LOCAL_BUNDLE)/Contents/Frameworks
	cp -R Sparkle.framework $(LOCAL_BUNDLE)/Contents/Frameworks/Sparkle.framework
	swiftc -O -target arm64-apple-macos14.0 -sdk $(SDK) \
		-framework Cocoa -framework ServiceManagement -framework SwiftUI -framework Sparkle \
		-F . -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
		-o $(LOCAL_BUNDLE)/Contents/MacOS/$(BUNDLE_NAME) \
		$(SWIFT_SOURCES) \
		$(wildcard JorvikKit/*.swift)
	cp Info.plist $(LOCAL_BUNDLE)/Contents/Info.plist
	@if [ -f AppIcon.icns ]; then cp AppIcon.icns $(LOCAL_BUNDLE)/Contents/Resources/AppIcon.icns; fi
	@$(SIGN_FRAMEWORK) $(LOCAL_BUNDLE)/Contents/Frameworks/Sparkle.framework "$(LOCAL_SIGN_ID)"
	@codesign --force --sign "$(LOCAL_SIGN_ID)" --options runtime --timestamp \
		--entitlements $(ENTITLEMENTS) $(LOCAL_BUNDLE)
	@# `grep` without -q on purpose. release.mk sets `-o pipefail`, and `grep -q`
	@# exits the instant it matches, which kills codesign with a broken pipe and
	@# makes the whole pipeline report failure on a signature that was correct.
	@codesign -dv --verbose=2 $(LOCAL_BUNDLE) 2>&1 | grep 'TeamIdentifier=$(LOCAL_TEAM_ID)' > /dev/null \
		|| { echo "REFUSING: $(LOCAL_BUNDLE) is not Developer ID signed — a TCC grant would be lost"; exit 1; }
	@echo "→ signed Developer ID ($(LOCAL_TEAM_ID))"
	@echo "→ Done: $(LOCAL_BUNDLE)"

dev-install: dev-build
	@echo "→ Installing to $(LOCAL_INSTALL_DIR)..."
	rm -rf "$(LOCAL_INSTALL_DIR)/$(LOCAL_BUNDLE)"
	cp -R $(LOCAL_BUNDLE) "$(LOCAL_INSTALL_DIR)/$(LOCAL_BUNDLE)"
	@echo "→ Installed."
