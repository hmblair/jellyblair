APP_NAME := JellyBlair

# Build configuration: release, or debug via make run CONFIG=debug.
CONFIG ?= release
BUILD_DIR := .build/$(CONFIG)
DIST_DIR := dist
BUNDLE := $(DIST_DIR)/$(APP_NAME).app

# The one source of the app version, stamped into both bundles at build time.
VERSION := $(shell cat VERSION)

# The build number, stamped into both bundles at build time. The App Store
# needs a number that rises with each upload, and the commit count does.
# A source tree without git history falls back to 0.
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

# Personal values live in an untracked Makefile.local:
#   IPHONE  := <device name>       # for make iphone
#   TEAM_ID := <Apple team ID>     # for iOS code signing
-include Makefile.local

IPHONE ?=
TEAM_ID ?=

INSTALL_DIR := /Applications

# Development certificate: a stable Apple-issued identity for local use.
# Set to "Developer ID Application" for notarized distribution builds.
CODESIGN_IDENTITY := Apple Development

.PHONY: all dist run install iphone clean

all:
	swift build -c $(CONFIG)

dist: all
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(BUNDLE)/Contents/MacOS/
	cp Packaging/Info.plist $(BUNDLE)/Contents/
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" $(BUNDLE)/Contents/Info.plist
	codesign --force -s "$(CODESIGN_IDENTITY)" $(BUNDLE)
	@echo "Built $(BUNDLE)"

run: dist
	open $(BUNDLE)

install: dist
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	cp -R $(BUNDLE) $(INSTALL_DIR)/
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"

IOS_DIR := ios
IOS_APP := $(IOS_DIR)/build/Build/Products/Debug-iphoneos/JellyBlairiOS.app

iphone:
	@if [ -z "$(IPHONE)" ] || [ -z "$(TEAM_ID)" ]; then \
		echo "Set IPHONE and TEAM_ID in Makefile.local or on the command line."; \
		exit 1; \
	fi
	cd $(IOS_DIR) && xcodegen generate
	cd $(IOS_DIR) && xcodebuild -project JellyBlairiOS.xcodeproj -scheme JellyBlairiOS -destination generic/platform=iOS -derivedDataPath build -allowProvisioningUpdates DEVELOPMENT_TEAM=$(TEAM_ID) MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) -quiet build
	xcrun devicectl device install app --device "$(IPHONE)" $(IOS_APP)
	@echo "Installed on $(IPHONE)"

clean:
	swift package clean
	rm -rf $(DIST_DIR)
