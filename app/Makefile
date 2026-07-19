SHELL := /bin/zsh

APP_NAME := QuotaBar
BUNDLE_ID := com.quotabar.QuotaBar
BUILD_DIR := .build
DIST_DIR := dist.noindex
APP_BUNDLE := $(DIST_DIR)/$(APP_NAME).app
CONTENTS := $(APP_BUNDLE)/Contents
EXECUTABLE := $(CONTENTS)/MacOS/$(APP_NAME)
INSTALL_BUNDLE := /Applications/$(APP_NAME).app
SWIFTC := /usr/bin/swiftc
SDK := $(shell /usr/bin/xcrun --sdk macosx --show-sdk-path)
TARGET := arm64-apple-macosx14.0
SOURCES := App.swift Models.swift Services.swift Views.swift
SCRIPTS_SRC := ../scripts
SWIFT_FLAGS := -swift-version 6 -target $(TARGET) -sdk $(SDK) -framework SwiftUI -framework AppKit -framework ServiceManagement

.PHONY: all typecheck test audit bundle verify install launch clean

all: bundle

typecheck:
	$(SWIFTC) -typecheck -parse-as-library $(SWIFT_FLAGS) $(SOURCES)

test:
	/bin/mkdir -p "$(BUILD_DIR)"
	$(SWIFTC) $(SWIFT_FLAGS) Models.swift Services.swift Tests.swift -o "$(BUILD_DIR)/QuotaBarTests"
	"$(BUILD_DIR)/QuotaBarTests"

audit:
	@# Forbidden everywhere: networking, credentials/keychain, analytics, structured logging.
	@! /usr/bin/grep -En 'URLSession|NWConnection|Network\.framework|import Security|SecItem|Keychain|analytics|telemetry|OSLog|Logger\(' App.swift Models.swift Services.swift Views.swift
	@# No filesystem-mutating APIs anywhere.
	@! /usr/bin/grep -En 'createFile|removeItem|copyItem|moveItem' App.swift Models.swift Services.swift Views.swift
	@# File writes and UserDefaults are permitted ONLY in Services.swift (SPEC "Allowed I/O").
	@! /usr/bin/grep -En 'Data\.write|write\(to:|write\(contentsOf:|UserDefaults' App.swift Models.swift Views.swift
	@# Services.swift may write ONLY the failure log (exactly its 2 log write calls) and
	@# persist ONLY its own prefs (codexLastPing); the log path must be the sanctioned one.
	@test "$$(/usr/bin/grep -Ec 'Data\.write|write\(to:|write\(contentsOf:' Services.swift)" = "2"
	@/usr/bin/grep -F 'Library/Logs/QuotaBar.log' Services.swift >/dev/null
	@/usr/bin/grep -F 'codexLastPing' Services.swift >/dev/null
	@/usr/bin/grep -F '"/usr/bin/python3"' Services.swift >/dev/null
	@/usr/bin/grep -F '"/bin/bash"' Services.swift >/dev/null
	@/usr/bin/grep -F 'usage.py' Services.swift >/dev/null
	@/usr/bin/grep -F 'ping-account.sh' Services.swift >/dev/null
	@/usr/bin/grep -F 'swap-account.sh' Services.swift >/dev/null
	@/usr/bin/grep -F 'bank-account.sh' Services.swift >/dev/null
	@/usr/bin/grep -F 'toggle-autoping.sh' Services.swift >/dev/null
	@/usr/bin/grep -F 'remove-account.sh' Services.swift >/dev/null
	@/usr/bin/grep -F 'last_ping' Services.swift >/dev/null
	@/usr/bin/grep -F 'auto_ping' Services.swift >/dev/null

bundle: typecheck
	/bin/rm -rf "$(APP_BUNDLE)"
	/bin/mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	/bin/cp AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	@# Bundle the account-bank scripts so the app has a self-contained fallback when
	@# nothing is installed at ~/.local/share/quotabar/account-bank (see Services.swift).
	@if [ -d "$(SCRIPTS_SRC)" ]; then \
	  /bin/rm -rf "$(CONTENTS)/Resources/account-bank"; \
	  /usr/bin/ditto "$(SCRIPTS_SRC)" "$(CONTENTS)/Resources/account-bank"; \
	  /bin/rm -rf "$(CONTENTS)/Resources/account-bank/__pycache__"; \
	fi
	$(SWIFTC) -parse-as-library -O $(SWIFT_FLAGS) $(SOURCES) -o "$(EXECUTABLE)"
	/bin/cp Info.plist "$(CONTENTS)/Info.plist"
	/usr/bin/codesign --force --sign - --timestamp=none "$(APP_BUNDLE)"

verify: bundle
	/usr/bin/codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"
	/usr/bin/plutil -lint "$(CONTENTS)/Info.plist"
	@test "$$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleIdentifier' "$(CONTENTS)/Info.plist")" = "$(BUNDLE_ID)"
	@test "$$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleExecutable' "$(CONTENTS)/Info.plist")" = "$(APP_NAME)"
	@test "$$('/usr/libexec/PlistBuddy' -c 'Print :LSMinimumSystemVersion' "$(CONTENTS)/Info.plist")" = "14.0"
	@test "$$('/usr/libexec/PlistBuddy' -c 'Print :LSUIElement' "$(CONTENTS)/Info.plist")" = "true"
	/usr/bin/file "$(EXECUTABLE)" | /usr/bin/grep -q 'arm64'

install: verify
	@set -eu; \
	if [[ -d "$(INSTALL_BUNDLE)" ]]; then \
	  for pid in $$(/usr/bin/pgrep -x "$(APP_NAME)" 2>/dev/null || true); do \
	    executable=$$(/usr/sbin/lsof -a -p "$$pid" -d txt -Fn 2>/dev/null | /usr/bin/sed -n 's/^n//p' | /usr/bin/head -1); \
	    if [[ "$$executable" == "$(INSTALL_BUNDLE)/Contents/MacOS/$(APP_NAME)" ]]; then \
	      /bin/kill -TERM "$$pid"; \
	      for attempt in {1..30}; do \
	        /bin/kill -0 "$$pid" 2>/dev/null || break; \
	        /bin/sleep 0.1; \
	      done; \
	      if /bin/kill -0 "$$pid" 2>/dev/null; then /bin/kill -KILL "$$pid"; fi; \
	      for attempt in {1..20}; do \
	        /bin/kill -0 "$$pid" 2>/dev/null || break; \
	        /bin/sleep 0.1; \
	      done; \
	      if /bin/kill -0 "$$pid" 2>/dev/null; then \
	        echo "Refusing to replace $(INSTALL_BUNDLE): process $$pid did not exit" >&2; exit 1; \
	      fi; \
	    fi; \
	  done; \
	  /bin/rm -rf "$(INSTALL_BUNDLE)"; \
	fi; \
	/usr/bin/ditto "$(APP_BUNDLE)" "$(INSTALL_BUNDLE)"
	/usr/bin/codesign --verify --deep --strict --verbose=2 "$(INSTALL_BUNDLE)"
	@test "$$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleIdentifier' "$(INSTALL_BUNDLE)/Contents/Info.plist")" = "$(BUNDLE_ID)"
	/usr/bin/file "$(INSTALL_BUNDLE)/Contents/MacOS/$(APP_NAME)" | /usr/bin/grep -q 'arm64'

launch:
	/usr/bin/open "$(INSTALL_BUNDLE)"

clean:
	/bin/rm -rf "$(BUILD_DIR)" "$(DIST_DIR)"
