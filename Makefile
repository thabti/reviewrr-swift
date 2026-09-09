# Reviewrr — development commands.
#
# The Xcode project is generated from project.yml, so every target that
# builds runs `xcodegen` first: a file added under Sources/Reviewrr is
# invisible to xcodebuild until it does.

APP        := build/Build/Products/Debug/Reviewrr.app
BINARY     := $(APP)/Contents/MacOS/Reviewrr
PROJECT    := Reviewrr.xcodeproj
DERIVED    := build
SUPPORT    := $(HOME)/Library/Application Support/Reviewrr
SDK        := $(shell xcrun --show-sdk-path --sdk macosx)
TARGET     := arm64-apple-macos14.0
SOURCES    := $(shell find Sources/Reviewrr -name '*.swift' 2>/dev/null)
# Everything the unit-test bundle compiles: App/ would duplicate @main and
# Views/ is verified by the app build instead.
TESTABLE   := $(shell find Sources/Reviewrr/Models Sources/Reviewrr/Services Sources/Reviewrr/ViewModels Sources/Reviewrr/Design -name '*.swift' 2>/dev/null)
AI_SUITES  := AITests AgentProviderTests AppleIntelligenceTests AIProviderFactoryTests \
	      AIAnalysisIdentityTests AIAnalysisCacheTests AISessionTests AISystemPromptTests
ONLY_AI    := $(foreach s,$(AI_SUITES),-only-testing:ReviewrrTests/$(s))

.DEFAULT_GOAL := help
.PHONY: help generate build run test clean typecheck check test-ai test-live bench \
	launch kill relaunch doctor agents crash stores reset-ai reset-all icon notify-test

## help: list these commands
help:
	@grep -hE '^## [a-z-]+:' $(MAKEFILE_LIST) \
		| sed 's/^## //' \
		| awk -F': ' '{ name = $$1; sub(/^[^:]*: ?/, "", $$0); printf "  \033[1m%-11s\033[0m %s\n", name, $$0 }'

# --- build and run ----------------------------------------------------------

## generate: regenerate Reviewrr.xcodeproj from project.yml
generate:
	xcodegen generate

## build: build the Debug configuration
build: generate
	xcodebuild -project $(PROJECT) -scheme Reviewrr -configuration Debug -derivedDataPath $(DERIVED) build

## run: build, then launch the app
run: build launch

## launch: launch the built app without rebuilding it
launch:
	@test -d $(APP) || { echo "No build yet — run 'make build'."; exit 1; }
	open $(APP)

## bench: Release build, launched on a synthetic 300-file PR with the frame probe on
# Debug numbers are meaningless for a scroll benchmark — bounds checking and
# unspecialised generics dominate — so this builds Release. STRESS sets the
# file count; REVIEWRR_PERF_SCROLL=<seconds> adds an automated scroll pass.
bench: generate
	xcodebuild -project $(PROJECT) -scheme Reviewrr -configuration Release -derivedDataPath $(DERIVED) build
	@echo "Launching with REVIEWRR_STRESS=$(or $(STRESS),300) REVIEWRR_PERF=1 — reports print to stderr every 5s."
	REVIEWRR_STRESS=$(or $(STRESS),300) REVIEWRR_PERF=1 \
		build/Build/Products/Release/Reviewrr.app/Contents/MacOS/Reviewrr

## kill: quit a running instance
kill:
	@pkill -x Reviewrr 2>/dev/null && echo "Reviewrr quit." || echo "Reviewrr was not running."

## relaunch: quit, rebuild, and launch — the loop while working on a view
relaunch: kill build launch

# --- checking ---------------------------------------------------------------

## typecheck: type-check every source file without touching build/
# Far faster than a build, and it does not fight Xcode for the derived-data
# lock while another session is building the same project.
typecheck:
	xcrun swiftc -typecheck -sdk "$(SDK)" -target $(TARGET) $(SOURCES)

## check: type-check only what the test bundle compiles
# Use when Views/ is mid-edit by someone else and you only need to know that
# your own layer still holds together.
check:
	xcrun swiftc -typecheck -sdk "$(SDK)" -target $(TARGET) $(TESTABLE)

## test: run the unit tests
test: generate
	xcodebuild -project $(PROJECT) -scheme ReviewrrTests -configuration Debug -derivedDataPath $(DERIVED) test

## test-ai: run only the AI module suites
test-ai: generate
	xcodebuild -project $(PROJECT) -scheme ReviewrrTests -configuration Debug -derivedDataPath $(DERIVED) \
		$(ONLY_AI) test

## test-live: run the AI providers against the CLIs installed on this Mac
# Off by default: it spends model tokens and needs your own agent logins.
# TEST_RUNNER_ is how xcodebuild forwards a variable into the test process —
# the runner inherits none of this shell's environment, so anything an agent
# reads from one needs the same prefix (OpenCode reads GEMINI_API_KEY).
test-live: generate
	TEST_RUNNER_REVIEWRR_LIVE_AGENT_TESTS=1 \
		xcodebuild -project $(PROJECT) -scheme ReviewrrTests -configuration Debug -derivedDataPath $(DERIVED) \
		-only-testing:ReviewrrTests/LiveAgentProviderTests test

# --- diagnosis --------------------------------------------------------------

## notify-test: post one system notification and report what macOS did with it
# The policy that decides *whether* to notify is pure and unit-tested; what
# is not is permission and whether the notification centre accepted the
# request, which fail silently. Runs the built app with the probe on, prints
# the permission state and the outcome, and exits non-zero if nothing was
# posted. Needs a build first.
notify-test:
	@test -d $(APP) || { echo "No build yet — run 'make build'."; exit 1; }
	@pkill -x Reviewrr 2>/dev/null || true
	REVIEWRR_NOTIFY_TEST=1 $(BINARY)

## doctor: report the toolchain and everything the AI providers depend on
doctor:
	@echo "macOS:      $$(sw_vers -productVersion) ($$(sw_vers -buildVersion))"
	@echo "Xcode:      $$(xcodebuild -version | head -1)"
	@echo "Swift:      $$(swift --version 2>&1 | head -1)"
	@echo "xcodegen:   $$(xcodegen --version 2>/dev/null || echo MISSING)"
	@echo "SDK:        $(SDK)"
	@printf "Apple Intelligence: "
	@test -d "$(SDK)/System/Library/Frameworks/FoundationModels.framework" \
		&& echo "FoundationModels present in SDK (runtime state shows in Settings → AI provider)" \
		|| echo "no FoundationModels in this SDK — needs macOS 26"
	@$(MAKE) --no-print-directory agents

## agents: which local agent CLIs resolve, and their versions
agents:
	@for spec in "codex:CODEX_BIN" "claude:CLAUDE_BIN" "kiro-cli:KIRO_BIN" "opencode:OPENCODE_BIN"; do \
		cmd=$${spec%%:*}; var=$${spec##*:}; \
		path=$$(eval echo \$$$$var); \
		if [ -z "$$path" ]; then path=$$(command -v $$cmd 2>/dev/null); fi; \
		if [ -n "$$path" ] && [ -x "$$path" ]; then \
			printf "  %-10s %s (%s)\n" "$$cmd" "$$($$path --version 2>&1 | head -1)" "$$path"; \
		else \
			printf "  %-10s not installed — set %s to override the path\n" "$$cmd" "$$var"; \
		fi; \
	done

## crash: summarise the most recent crash report, if there is one
crash:
	@latest=$$(ls -t "$(HOME)"/Library/Logs/DiagnosticReports/Reviewrr-*.ips 2>/dev/null | head -1); \
	if [ -z "$$latest" ]; then echo "No crash reports."; else \
		echo "$$latest"; \
		python3 -c "import json,sys;p=sys.argv[1];h,b=open(p).read().split(chr(10),1);d=json.loads(b);\
e=d.get('exception',{});print('  type:  ',e.get('type'),e.get('signal'));\
print('  when:  ',d.get('captureTime'));\
import datetime as dt;fmt='%Y-%m-%d %H:%M:%S.%f %z';\
l=d.get('procLaunch');c=d.get('captureTime');\
print('  uptime:',(round((dt.datetime.strptime(c,fmt)-dt.datetime.strptime(l,fmt)).total_seconds(),1) if l and c else '?'),'s after launch');\
bt=(d.get('asiBacktraces') or [''])[0];\
print('  top frames:');\
print(chr(10).join('    '+l.strip()[:110] for l in bt.split(chr(10))[:8]))" "$$latest"; \
	fi

## stores: where local review state lives, and how big it is
stores:
	@test -d "$(SUPPORT)" || { echo "Nothing stored yet."; exit 0; }
	@du -sh "$(SUPPORT)"/* 2>/dev/null | sed 's|$(SUPPORT)/|  |'

# --- local state ------------------------------------------------------------

## reset-ai: drop cached analyses and Ask transcripts (keeps your drafts)
# Drafts are unsent human work, so they are never touched here.
reset-ai:
	@rm -rf "$(SUPPORT)/ai-analysis" "$(SUPPORT)/ai-sessions"
	@echo "Cleared cached analyses and AI sessions. Drafts and the watchlist are untouched."

## reset-all: delete ALL local state, drafts included — needs CONFIRM=1
reset-all:
	@if [ "$(CONFIRM)" != "1" ]; then \
		echo "This deletes $(SUPPORT), including unsent review drafts you have not submitted."; \
		echo "Re-run as: make reset-all CONFIRM=1"; \
		exit 1; \
	fi
	rm -rf "$(SUPPORT)"
	@echo "Removed $(SUPPORT)."

# --- assets -----------------------------------------------------------------

## icon: regenerate every app-icon size from one square PNG (SRC=path.png)
icon:
	@test -n "$(SRC)" || { echo "Usage: make icon SRC=path/to/icon.png"; exit 1; }
	@test -f "$(SRC)" || { echo "No such file: $(SRC)"; exit 1; }
	@set -e; dir=Sources/Reviewrr/Resources/Assets.xcassets/AppIcon.appiconset; \
	for spec in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 128x128@2x:256 \
			256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do \
		name=$${spec%%:*}; px=$${spec##*:}; \
		sips -s format png -z $$px $$px "$(SRC)" --out "$$dir/icon_$$name.png" >/dev/null; \
	done; \
	echo "Wrote 10 sizes into $$dir from $(SRC)."

# --- housekeeping -----------------------------------------------------------

## clean: remove build/ and the generated .xcodeproj
clean:
	rm -rf $(DERIVED) $(PROJECT)

# Regenerates docs/img/workspace.png from the demo pull request.
#
# Launched through `open` on purpose: run the binary directly and the SwiftUI
# scene never appears, so the export task never fires. The app renders its own
# window (no Screen Recording permission needed) and exits. Add LIGHT=1 for the
# light appearance.
screenshot: build
	@rm -f docs/img/workspace.png
	@pkill -x Reviewrr || true
	@open -n "$(APP)" --args --export-screenshot "$(PWD)/docs/img/workspace.png" $(if $(LIGHT),--light,)
	@for i in $$(seq 1 30); do [ -f docs/img/workspace.png ] && break; sleep 2; done
	@pkill -x Reviewrr || true
	@test -f docs/img/workspace.png \
		&& echo "wrote docs/img/workspace.png" \
		|| (echo "screenshot failed; see /tmp/reviewrr-screenshot.log"; exit 1)
