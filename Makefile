APP_NAME := JellyBlair
BUILD_DIR := .build/release
DIST_DIR := dist
BUNDLE := $(DIST_DIR)/$(APP_NAME).app

INSTALL_DIR := /Applications

.PHONY: all dist run install clean

all:
	swift build -c release

dist: all
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(BUNDLE)/Contents/MacOS/
	cp Packaging/Info.plist $(BUNDLE)/Contents/
	codesign --force -s - $(BUNDLE)
	@echo "Built $(BUNDLE)"

run: dist
	open $(BUNDLE)

install: dist
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	cp -R $(BUNDLE) $(INSTALL_DIR)/
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf $(DIST_DIR)
