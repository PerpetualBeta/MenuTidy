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

# Single-arch fast build for local install. Bypasses release.mk's universal
# binary + version stamping for speed.
dev-build:
	@echo "→ dev build (arm64 only, ad-hoc)"
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
	codesign --force --sign - $(LOCAL_BUNDLE)
	@echo "→ Done: $(LOCAL_BUNDLE)"

dev-install: dev-build
	@echo "→ Installing to $(LOCAL_INSTALL_DIR)..."
	rm -rf "$(LOCAL_INSTALL_DIR)/$(LOCAL_BUNDLE)"
	cp -R $(LOCAL_BUNDLE) "$(LOCAL_INSTALL_DIR)/$(LOCAL_BUNDLE)"
	@echo "→ Installed."
