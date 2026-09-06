APP_NAME := JellyBlair
BUILD_DIR := .build/release
DIST_DIR := dist
BUNDLE := $(DIST_DIR)/$(APP_NAME).app

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
	swift build -c release

dist: all
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(BUNDLE)/Contents/MacOS/
	cp Packaging/Info.plist $(BUNDLE)/Contents/
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
	cd $(IOS_DIR) && xcodebuild -project JellyBlairiOS.xcodeproj -scheme JellyBlairiOS -destination generic/platform=iOS -derivedDataPath build -allowProvisioningUpdates DEVELOPMENT_TEAM=$(TEAM_ID) -quiet build
	xcrun devicectl device install app --device "$(IPHONE)" $(IOS_APP)
	@echo "Installed on $(IPHONE)"

clean:
	swift package clean
	rm -rf $(DIST_DIR)
