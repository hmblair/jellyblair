# Personal values live in an untracked Makefile.local:
#   TEAM_ID        := <Apple team ID>          # enables code signing
#   DEVICE         := <device name>            # for PLATFORM=ios
#   NOTARY_PROFILE := <notarytool profile>     # for METHOD=developer-id
-include Makefile.local

# The platform every target acts on, and the channel that export ships to.
PLATFORM ?= mac
METHOD ?= app-store-connect
CONFIGURATION ?= Release

SCHEME_mac := JellyBlairMac
SCHEME_ios := JellyBlairiOS
SCHEME := $(SCHEME_$(PLATFORM))

DESTINATION_mac := platform=macOS
DESTINATION_ios := generic/platform=iOS
DESTINATION ?= $(DESTINATION_$(PLATFORM))

# The products directory xcodebuild writes to, which carries the SDK name
# on every platform but the Mac.
PRODUCTS_mac := $(CONFIGURATION)
PRODUCTS_ios := $(CONFIGURATION)-iphoneos

ifeq ($(SCHEME),)
$(error PLATFORM must be mac or ios)
endif

ifeq ($(filter $(METHOD),app-store-connect developer-id),)
$(error METHOD must be app-store-connect or developer-id)
endif

APP_NAME := JellyBlair
BUNDLE_ID := com.hmblair.jellyblair
APPS_DIR := Apps
PROJECT := $(APPS_DIR)/$(APP_NAME).xcodeproj
BUILD_DIR := build
DIST_DIR := dist
INSTALL_DIR := /Applications

APP := $(BUILD_DIR)/Build/Products/$(PRODUCTS_$(PLATFORM))/$(APP_NAME).app
ARCHIVE := $(DIST_DIR)/$(SCHEME).xcarchive
EXPORT_DIR := $(DIST_DIR)/$(PLATFORM)-$(METHOD)
EXPORT_OPTIONS := $(EXPORT_DIR)/ExportOptions.plist

# The one source of the app version, stamped into both bundles at build time.
VERSION := $(shell cat VERSION)

# The build number, stamped into both bundles at build time. The App Store
# needs a number that rises with each upload, and the commit count does.
# A source tree without git history falls back to 0.
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

VERSIONING := MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)

# Where DEVICE came from, so a name typed on the command line can be told
# apart from the standing default in Makefile.local.
DEVICE_ORIGIN := $(origin DEVICE)

# This Mac's own name, read only when the guard needs it.
MAC_NAME = $(shell scutil --get ComputerName)

# Signing is optional, so a clone with no Apple account still builds and runs.
ifeq ($(TEAM_ID),)
SIGNING := CODE_SIGNING_ALLOWED=NO
else
SIGNING := -allowProvisioningUpdates DEVELOPMENT_TEAM=$(TEAM_ID)
endif

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-configuration $(CONFIGURATION) -destination '$(DESTINATION)' \
	$(VERSIONING) $(SIGNING) -quiet

.PHONY: build run install archive export clean project \
	run-mac run-ios install-mac install-ios export-options \
	notarize-app-store-connect notarize-developer-id \
	require-team require-mac-device require-ios-device

build: project
	$(XCODEBUILD) -derivedDataPath $(BUILD_DIR) build

run: require-$(PLATFORM)-device build run-$(PLATFORM)

install: require-$(PLATFORM)-device build install-$(PLATFORM)

archive: require-team project
	$(XCODEBUILD) -archivePath $(ARCHIVE) archive

export: export-options
	@test -d $(ARCHIVE) || { echo "No archive at $(ARCHIVE). Run make archive first."; exit 1; }
	rm -rf $(EXPORT_DIR)/$(APP_NAME).app
	xcodebuild -exportArchive -archivePath $(ARCHIVE) \
		-exportPath $(EXPORT_DIR) -exportOptionsPlist $(EXPORT_OPTIONS)
	$(MAKE) notarize-$(METHOD)
	@echo "Exported $(EXPORT_DIR)"

clean:
	swift package clean
	rm -rf $(BUILD_DIR) $(DIST_DIR) $(PROJECT)
	rm -f $(APPS_DIR)/Mac/Info.plist $(APPS_DIR)/iOS/Info.plist

# Regenerates the Xcode project from the spec, the one description of both apps.
project:
	cd $(APPS_DIR) && xcodegen generate

# The export options carry the team, so make writes them instead of the repo.
export-options: require-team
	@mkdir -p $(EXPORT_DIR)
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>method</key><string>$(METHOD)</string>' \
		'<key>teamID</key><string>$(TEAM_ID)</string>' \
		'<key>signingStyle</key><string>automatic</string>' \
		'</dict></plist>' > $(EXPORT_OPTIONS)

run-mac:
	open $(APP)

run-ios: install-ios
	xcrun devicectl device process launch --device "$(DEVICE)" $(BUNDLE_ID)

install-mac:
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	cp -R $(APP) $(INSTALL_DIR)/
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"

install-ios:
	xcrun devicectl device install app --device "$(DEVICE)" $(APP)
	@echo "Installed on $(DEVICE)"

# The App Store notarizes on its side, so an upload needs nothing here.
notarize-app-store-connect:
	@:

# A Developer ID build is useless until notarized, so export does it here.
# The app is zipped for submission, stapled once approved, then zipped again
# so the download carries the ticket.
notarize-developer-id:
	@test "$(PLATFORM)" = mac || { echo "developer-id applies to the Mac only."; exit 1; }
	@test -n "$(NOTARY_PROFILE)" || { echo "Set NOTARY_PROFILE in Makefile.local."; exit 1; }
	ditto -c -k --keepParent $(EXPORT_DIR)/$(APP_NAME).app $(EXPORT_DIR)/$(APP_NAME).zip
	xcrun notarytool submit $(EXPORT_DIR)/$(APP_NAME).zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(EXPORT_DIR)/$(APP_NAME).app
	rm -f $(EXPORT_DIR)/$(APP_NAME).zip
	ditto -c -k --keepParent $(EXPORT_DIR)/$(APP_NAME).app $(EXPORT_DIR)/$(APP_NAME).zip

require-team:
	@test -n "$(TEAM_ID)" || { echo "Set TEAM_ID in Makefile.local or on the command line."; exit 1; }

# A device named on the command line means somewhere other than this Mac,
# so a macOS action carrying one is a mistake. A name that matches this Mac
# passes, and the standing default in Makefile.local is ignored.
require-mac-device:
	@test "$(DEVICE_ORIGIN)" != "command line" || test "$(DEVICE)" = "$(MAC_NAME)" || \
		{ echo "DEVICE is \"$(DEVICE)\", which is not this Mac (\"$(MAC_NAME)\"). Pass PLATFORM=ios."; exit 1; }

require-ios-device:
	@test -n "$(DEVICE)" || { echo "Set DEVICE in Makefile.local or on the command line."; exit 1; }
