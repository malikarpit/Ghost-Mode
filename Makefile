# ==============================================================================
#  Ghost Mode - Universal macOS Build & Distribution Automation
#  Developer & Creator: Arpit
#  Copyright © 2026 Arpit. All rights reserved.
#  Identifier: com.arpit.GhostMode
#  Target: Universal 2 Binary (Apple Silicon arm64 + Intel x86_64, macOS 12.0+)
# ==============================================================================

APP_NAME = Ghost Mode
EXEC_NAME = GhostMode
APP_BUNDLE = $(APP_NAME).app
CONTENTS_DIR = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources
SDK_PATH = $(shell xcrun --show-sdk-path --sdk macosx)
MIN_MACOS = 12.0
DMG_NAME = GhostMode-Installer.dmg

all: $(APP_BUNDLE)

$(APP_BUNDLE): main.swift Info.plist ghostmode_setup.sh AppIcon.icns
	@echo "Creating app bundle structure for Ghost Mode (by Arpit)..."
	mkdir -p "$(MACOS_DIR)"
	mkdir -p "$(RESOURCES_DIR)"
	@echo "Compiling Universal Swift binary (arm64 + x86_64 for macOS $(MIN_MACOS)+)..."
	mkdir -p /tmp/ghostmode_build
	swiftc -target arm64-apple-macos$(MIN_MACOS) -O -sdk $(SDK_PATH) main.swift -o /tmp/ghostmode_build/$(EXEC_NAME)_arm64
	swiftc -target x86_64-apple-macos$(MIN_MACOS) -O -sdk $(SDK_PATH) main.swift -o /tmp/ghostmode_build/$(EXEC_NAME)_x86_64
	lipo -create -output "$(MACOS_DIR)/$(EXEC_NAME)" /tmp/ghostmode_build/$(EXEC_NAME)_arm64 /tmp/ghostmode_build/$(EXEC_NAME)_x86_64
	rm -rf /tmp/ghostmode_build
	@echo "Copying configuration files..."
	cp Info.plist "$(CONTENTS_DIR)/Info.plist"
	cp ghostmode_setup.sh "$(RESOURCES_DIR)/ghostmode_setup.sh"
	chmod +x "$(RESOURCES_DIR)/ghostmode_setup.sh"
	cp AppIcon.icns "$(RESOURCES_DIR)/AppIcon.icns"
	@echo "Applying code signature (Developer: Arpit)..."
	codesign --force --deep --sign - "$(APP_BUNDLE)"
	@echo "Successfully built Universal $(APP_BUNDLE) by Arpit!"

clean:
	@echo "Cleaning build artifacts..."
	rm -rf "$(APP_BUNDLE)" "$(DMG_NAME)" dist/ /tmp/ghostmode_build

install: all
	@echo "Installing Ghost Mode to /Applications..."
	rm -rf "/Applications/$(APP_BUNDLE)"
	rm -rf "/Applications/LidSentry.app"
	cp -R "$(APP_BUNDLE)" "/Applications/"
	@echo "Installed successfully to /Applications/$(APP_BUNDLE)!"

dmg: all
	@echo "Creating Ghost Mode Universal DMG installer..."
	rm -rf dist "$(DMG_NAME)"
	mkdir -p dist
	cp -R "$(APP_BUNDLE)" dist/
	ln -s /Applications dist/Applications
	hdiutil create -volname "Ghost Mode" -srcfolder dist -ov -format UDZO "$(DMG_NAME)"
	rm -rf dist
	@echo "Successfully created Universal $(DMG_NAME) by Arpit!"

uninstall:
	@echo "Uninstalling Ghost Mode..."
	pkill -f "GhostMode" || true
	rm -rf "/Applications/$(APP_BUNDLE)"
	rm -f ~/Library/LaunchAgents/com.arpit.ghostmode.plist
	@echo "To remove sudoers privilege rule: sudo rm -f /private/etc/sudoers.d/ghostmode"
	@echo "Ghost Mode uninstalled successfully."

.PHONY: all clean install dmg uninstall
