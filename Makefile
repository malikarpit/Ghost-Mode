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
X86_64_MIN_MACOS = $(shell lipo -archs "$$(dirname $$(xcrun --find swiftc))/../lib/swift/macosx/libswiftCompatibility56.a" 2>/dev/null | grep -q x86_64 && echo $(MIN_MACOS) || echo 14.0)
HOST_ARCH = $(shell uname -m)
DMG_NAME = GhostMode-Installer.dmg
SWIFT_SOURCES = $(wildcard Sources/*.swift)
BUILD_DIR = /tmp/ghostmode_build
TEST_BIN = $(BUILD_DIR)/GhostModeTests
TEST_SOURCES = \
	Sources/Models.swift \
	Sources/Preferences.swift \
	Sources/DurationHelpers.swift \
	Sources/SafetyControllers.swift \
	Sources/AppFreezer.swift \
	Sources/ProcessDiagnostics.swift \
	Tests/GhostModeTests.swift

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(SWIFT_SOURCES) Info.plist ghostmode_setup.sh AppIcon.icns
	@echo "Creating app bundle structure for Ghost Mode (by Arpit)..."
	mkdir -p "$(MACOS_DIR)"
	mkdir -p "$(RESOURCES_DIR)"
	@echo "Compiling Universal Swift binary (arm64 macOS $(MIN_MACOS)+ and x86_64 macOS $(X86_64_MIN_MACOS)+)..."
	mkdir -p $(BUILD_DIR)
	swiftc -target arm64-apple-macos$(MIN_MACOS) -O -sdk $(SDK_PATH) $(SWIFT_SOURCES) -o $(BUILD_DIR)/$(EXEC_NAME)_arm64
	swiftc -target x86_64-apple-macos$(X86_64_MIN_MACOS) -O -sdk $(SDK_PATH) $(SWIFT_SOURCES) -o $(BUILD_DIR)/$(EXEC_NAME)_x86_64
	lipo -create -output "$(MACOS_DIR)/$(EXEC_NAME)" $(BUILD_DIR)/$(EXEC_NAME)_arm64 $(BUILD_DIR)/$(EXEC_NAME)_x86_64
	rm -rf $(BUILD_DIR)
	@echo "Copying configuration files..."
	cp Info.plist "$(CONTENTS_DIR)/Info.plist"
	cp ghostmode_setup.sh "$(RESOURCES_DIR)/ghostmode_setup.sh"
	chmod +x "$(RESOURCES_DIR)/ghostmode_setup.sh"
	cp AppIcon.icns "$(RESOURCES_DIR)/AppIcon.icns"
	@echo "Applying code signature (Developer: Arpit)..."
	codesign --force --deep --sign - "$(APP_BUNDLE)"
	@echo "Successfully built Universal $(APP_BUNDLE) by Arpit!"

test: $(TEST_SOURCES)
	@echo "Compiling and running Ghost Mode unit tests..."
	mkdir -p $(BUILD_DIR)
	swiftc -target $(HOST_ARCH)-apple-macos$(MIN_MACOS) -sdk $(SDK_PATH) $(TEST_SOURCES) -o $(TEST_BIN)
	$(TEST_BIN)

clean:
	@echo "Cleaning build artifacts..."
	rm -rf "$(APP_BUNDLE)" "$(DMG_NAME)" dist/ $(BUILD_DIR) $(TEST_BIN)

install: all
	@echo "Installing Ghost Mode to /Applications..."
	rm -rf "/Applications/$(APP_BUNDLE)"
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
	pkill -TERM -x "GhostMode" || true
	sleep 0.5
	pkill -KILL -x "GhostMode" || true
	rm -rf "/Applications/$(APP_BUNDLE)"
	rm -f ~/Library/LaunchAgents/com.arpit.ghostmode.plist
	@echo "To remove sudoers privilege rule: sudo rm -f /private/etc/sudoers.d/ghostmode"
	@echo "Ghost Mode uninstalled successfully."

.PHONY: all clean install dmg uninstall test
