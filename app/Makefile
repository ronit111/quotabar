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
SCRIPTS_MANIFEST := $(BUILD_DIR)/bundle-scripts.list
SWIFT_FLAGS := -swift-version 6 -target $(TARGET) -sdk $(SDK) -framework SwiftUI -framework AppKit -framework ServiceManagement

.PHONY: all typecheck test audit bundle bundle-scripts verify verify-bundle check-scripts-dir install launch clean

all: bundle

typecheck:
	$(SWIFTC) -typecheck -parse-as-library $(SWIFT_FLAGS) $(SOURCES)

test:
	/bin/mkdir -p "$(BUILD_DIR)"
	$(SWIFTC) $(SWIFT_FLAGS) Models.swift Services.swift Tests.swift -o "$(BUILD_DIR)/QuotaBarTests"
	"$(BUILD_DIR)/QuotaBarTests"

audit:
	@# Forbidden everywhere: credentials/keychain, analytics, structured logging, and every
	@# networking API other than the single allowlisted update check pinned below.
	@! /usr/bin/grep -En 'URLSession|NWConnection|Network\.framework|import Security|SecItem|Keychain|analytics|telemetry|OSLog|Logger\(' App.swift Models.swift Views.swift
	@! /usr/bin/grep -En 'NWConnection|Network\.framework|import Security|SecItem|Keychain|analytics|telemetry|OSLog|Logger\(' Services.swift
	@# (v102) THE update-check allowlist. The app gained exactly one network call: an
	@# unauthenticated GET of this project's own public "latest release" document, at most once a
	@# day, so a released tool can tell its owner a new version exists instead of leaving them on
	@# a stale build indefinitely. Weakening the audit to "Services.swift may do networking" would
	@# have retired the guarantee the rule exists for, so the callsite is PINNED instead: exactly
	@# one URLSession in the whole app, and no URL literal anywhere in Services.swift other than
	@# this endpoint. Adding a second endpoint, or moving the call into another file, fails here.
	@test "$$(/usr/bin/grep -Ec 'URLSession\(' Services.swift)" = "1"
	@test "$$(/usr/bin/grep -Ec 'URLSession' Services.swift)" = "4"
	@/usr/bin/grep -F 'https://api.github.com/repos/ronit111/quotabar/releases/latest' Services.swift >/dev/null
	@test "$$(/usr/bin/grep -Ec 'https?://' Services.swift)" = "$$(/usr/bin/grep -cF 'https://api.github.com/repos/ronit111/quotabar/releases/latest' Services.swift)"
	@# (v102-r2) ONE ENDPOINT MEANS ONE HOST AND ONE PATH, not one string literal. URLSession
	@# follows redirects by default, so the pinned literal above bounded only the FIRST request:
	@# a 302 from it could carry the connection, and the product/version User-Agent, to any host.
	@# The runtime now refuses redirects at the task delegate and applies UpdateEndpoint.isAllowed
	@# to the URL it sends AND the URL that answered. Those three parts are what the endpoint
	@# boundary actually consists of, so each is pinned here — and the allowlist itself is pinned
	@# to the same host+path the literal spells, in Models.swift where it lives.
	@/usr/bin/grep -F 'willPerformHTTPRedirection' Services.swift >/dev/null
	@test "$$(/usr/bin/grep -Ec 'completionHandler\(nil\)' Services.swift)" = "1"
	@test "$$(/usr/bin/grep -Ec 'UpdateEndpoint\.isAllowed\(' Services.swift)" = "2"
	@/usr/bin/grep -F 'delegate: RefuseRedirects()' Services.swift >/dev/null
	@/usr/bin/grep -Fx '    static let host = "api.github.com"' Models.swift >/dev/null
	@/usr/bin/grep -Fx '    static let path = "/repos/ronit111/quotabar/releases/latest"' Models.swift >/dev/null
	@# The request must stay anonymous: no auth header, no cookies, no credentialed session.
	@! /usr/bin/grep -En 'Authorization|setHTTPCookie|httpCookieStorage *= *HTTPCookieStorage|URLCredential' Services.swift
	@# Filesystem-mutating APIs: create/copy/move forbidden everywhere; removeItem forbidden in
	@# App/Models/Views (allowed in Services ONLY for the runtime-marker teardown, asserted below).
	@# (\.moveItem so the pattern does not match the 'moveItem' substring inside removeItem.)
	@! /usr/bin/grep -En 'createFile|copyItem|\.moveItem' App.swift Models.swift Services.swift Views.swift
	@! /usr/bin/grep -En 'removeItem' App.swift Models.swift Views.swift
	@# File writes and UserDefaults are permitted ONLY in Services.swift (SPEC "Allowed I/O").
	@! /usr/bin/grep -En 'Data\.write|write\(to:|write\(contentsOf:|UserDefaults' App.swift Models.swift Views.swift
	@# Services.swift may write ONLY the 2 failure-log calls + the 1 runtime-marker write, persist
	@# ONLY its own prefs (codexLastPing / seedAuditAckTs), and the log path must be the sanctioned
	@# one. The runtime marker (accounts/quotabar.runtime.json {pid,epoch_aware}) is the SOLE file
	@# the app writes under accounts/ — attest-cutover.sh fails closed without it (SPEC "Allowed I/O").
	@test "$$(/usr/bin/grep -Ec 'Data\.write|write\(to:|write\(contentsOf:' Services.swift)" = "3"
	@# The ONLY removeItem in Services is the runtime-marker teardown (exactly one call).
	@test "$$(/usr/bin/grep -Ec 'removeItem' Services.swift)" = "1"
	@/usr/bin/grep -F 'quotabar.runtime.json' Services.swift >/dev/null
	@/usr/bin/grep -F 'epoch_aware' Services.swift >/dev/null
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

bundle: typecheck bundle-scripts
	$(SWIFTC) -parse-as-library -O $(SWIFT_FLAGS) $(SOURCES) -o "$(EXECUTABLE)"
	/bin/cp Info.plist "$(CONTENTS)/Info.plist"
	/usr/bin/codesign --force --sign - --timestamp=none "$(APP_BUNDLE)"

# (r15 #5) Bundle the account-bank scripts so the app has a self-contained fallback when
# nothing is installed (see Services.swift) — but ship ONLY the runtime, from an EXPLICIT
# file list. The old `ditto ../scripts` copied the live working tree wholesale: the shipped
# v1.0.0 zip contained tests/__pycache__/test_g10.cpython-314.pyc, whose embedded absolute
# source path leaked the maintainer's home directory to every user who downloaded it, and any
# untracked scratch file, credential dump or editor backup under scripts/ would have shipped
# the same way. The manifest is the repo's TRACKED files when we are in a git checkout (so
# untracked files cannot ship by construction), with a find-based equivalent for builds from
# an exported tarball. COPYFILE_DISABLE=1 keeps bsdtar from writing AppleDouble ._ sidecars,
# so no resource forks or extended attributes ride along either.
bundle-scripts:
	/bin/rm -rf "$(APP_BUNDLE)"
	/bin/mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	/bin/cp AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	@set -eu; \
	dest="$(CONTENTS)/Resources/account-bank"; \
	/bin/rm -rf "$$dest"; \
	if [ ! -d "$(SCRIPTS_SRC)" ]; then \
	  echo "bundle: $(SCRIPTS_SRC) absent — no scripts bundled" >&2; exit 0; \
	fi; \
	/bin/mkdir -p "$(BUILD_DIR)" "$$dest"; \
	if /usr/bin/git -C "$(SCRIPTS_SRC)" rev-parse --show-toplevel >/dev/null 2>&1; then \
	  /usr/bin/git -C "$(SCRIPTS_SRC)" ls-files --cached -- .; \
	else \
	  ( cd "$(SCRIPTS_SRC)" && /usr/bin/find . -type d \( -name tests -o -name __pycache__ \) -prune \
	      -o -type f -print | /usr/bin/sed 's|^\./||' ); \
	fi \
	  | /usr/bin/grep -vE '(^|/)(tests|__pycache__)/' \
	  | /usr/bin/grep -vE '\.py[co]$$' \
	  | /usr/bin/grep -vE '(^|/)\.' \
	  > "$(SCRIPTS_MANIFEST)"; \
	for required in usage.py lib.sh swap-account.sh bank_common.py; do \
	  /usr/bin/grep -qxF "$$required" "$(SCRIPTS_MANIFEST)" || \
	    { echo "bundle: manifest is missing $$required — the filter is wrong, refusing to ship" >&2; exit 1; }; \
	done; \
	COPYFILE_DISABLE=1 /usr/bin/tar -c -f - -C "$(SCRIPTS_SRC)" -T "$(SCRIPTS_MANIFEST)" \
	  | ( cd "$$dest" && COPYFILE_DISABLE=1 /usr/bin/tar -x -f - ); \
	echo "bundle: $$(/usr/bin/wc -l < "$(SCRIPTS_MANIFEST)" | /usr/bin/tr -d ' ') runtime script files bundled"

# (r15 #5) Inspect the FINISHED artifact, not the recipe that built it — this is the gate
# release.sh runs before packaging, and it is what would have caught the leaked absolute
# path inside the shipped v1.0.0 zip. Checks what must not be there (test trees, bytecode,
# AppleDouble sidecars, dotfiles) and what must not be IN it (absolute /Users paths, which
# no tracked script contains: they only ever arrive via compiled or generated files).
verify-bundle: bundle
	@$(MAKE) --no-print-directory check-scripts-dir DIR="$(CONTENTS)/Resources/account-bank"

# The check itself, over any directory, so the gate is testable against a planted fixture
# instead of only ever seeing a bundle we just built (scripts/tests/test_r15.sh drives it).
check-scripts-dir:
	@set -eu; \
	dest="$(DIR)"; \
	[ -d "$$dest" ] || { echo "verify-bundle: $$dest missing" >&2; exit 1; }; \
	found="$$(/usr/bin/find "$$dest" \( -name '__pycache__' -o -name 'tests' -o -name '*.pyc' \
	   -o -name '*.pyo' -o -name '._*' -o -name '.*' \) -print)"; \
	if [ -n "$$found" ]; then \
	  echo "verify-bundle: excluded artifacts made it into the bundle:" >&2; \
	  echo "$$found" >&2; exit 1; \
	fi; \
	if /usr/bin/grep -rlI '/Users/' "$$dest" >/dev/null 2>&1; then \
	  echo "verify-bundle: an absolute /Users path is embedded in the bundled scripts:" >&2; \
	  /usr/bin/grep -rlI '/Users/' "$$dest" >&2; exit 1; \
	fi; \
	echo "verify-bundle: no tests, bytecode, dotfiles, sidecars or absolute home paths"

verify: bundle verify-bundle
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
