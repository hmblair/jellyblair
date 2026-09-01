APP_NAME := JellyBlair
BUILD_DIR := .build/release
DIST_DIR := dist
BUNDLE := $(DIST_DIR)/$(APP_NAME).app

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
IPHONE := Hamish’s iPhone

iphone:
	cd $(IOS_DIR) && xcodegen generate
	cd $(IOS_DIR) && xcodebuild -project JellyBlairiOS.xcodeproj -scheme JellyBlairiOS -destination generic/platform=iOS -derivedDataPath build -allowProvisioningUpdates -quiet build
	xcrun devicectl device install app --device "$(IPHONE)" $(IOS_APP)
	@echo "Installed on $(IPHONE)"

clean:
	swift package clean
	rm -rf $(DIST_DIR)
