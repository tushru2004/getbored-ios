SCHEME          := GetBored iOS
WORKSPACE       := GetBoredIOS.xcworkspace
DERIVED_DATA    := ./iOSDeviceDerivedData
APP_PATH        := $(DERIVED_DATA)/Build/Products/Debug-iphoneos/GetBored.app
RELEASE_APP     := $(DERIVED_DATA)/Build/Products/Release-iphoneos/GetBored.app
BUNDLE_ID       := com.getbored.filter

# iPhone XR — E2E / debug installs
DEVICE_UDID     ?= 00008020-0004695621DA002E
# iPhone 13 mini — production Release installs
PROD_DEVICE_UDID ?= 00008110-0016786001D2401E

# Java for Gradle (KMP XCFramework builds)
JAVA_HOME       ?= /opt/homebrew/opt/openjdk
export JAVA_HOME

# Port for kill-port (defaults to Metro)
PORT            ?= 8081

.PHONY: all build build-release build-device install install-only install-release preflight preflight-release swift-test clean kmp kmp-clean kill-port agents-api-wake agents-wake-api agents-api-wake-kill agents-wake-api-kill

all: build

# Unsigned simulator/CI build (no device required)
build:
	xcodebuild \
		-workspace $(WORKSPACE) \
		-scheme "$(SCHEME)" \
		-destination 'generic/platform=iOS' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO \
		build

# Signed Debug build for physical device (requires connected XR + keychain unlock)
build-device:
	xcodebuild \
		-workspace $(WORKSPACE) \
		-scheme "$(SCHEME)" \
		-destination 'generic/platform=iOS' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGN_STYLE=Automatic \
		-allowProvisioningUpdates \
		clean build

# Signed Release build
build-release:
	xcodebuild \
		-workspace $(WORKSPACE) \
		-scheme "$(SCHEME)" \
		-destination 'generic/platform=iOS' \
		-derivedDataPath $(DERIVED_DATA) \
		-configuration Release \
		CODE_SIGN_STYLE=Automatic \
		-allowProvisioningUpdates \
		clean build

# Preflight guard: refuse to install a build with missing required dynamic frameworks.
preflight:
	./scripts/preflight-check.sh $(APP_PATH)

# Preflight guard for the Release (App Store configuration) build.
preflight-release:
	./scripts/preflight-check.sh $(RELEASE_APP)

# Build + install on XR (mirrors monorepo build-ios-on-air)
install: build-device preflight
	-xcrun devicectl device uninstall app --device $(DEVICE_UDID) $(BUNDLE_ID) 2>/dev/null
	@attempt=1; until xcrun devicectl device install app --device $(DEVICE_UDID) $(APP_PATH); do \
		attempt=$$((attempt + 1)); \
		if [ $$attempt -gt 3 ]; then echo "install failed after 3 attempts"; exit 1; fi; \
		echo "install attempt $$((attempt - 1)) failed, retrying in 3s..."; \
		sleep 3; \
	done
	@echo "GetBored installed on XR ($(DEVICE_UDID))"

# Install without rebuild
install-only: preflight
	-xcrun devicectl device uninstall app --device $(DEVICE_UDID) $(BUNDLE_ID) 2>/dev/null
	@attempt=1; until xcrun devicectl device install app --device $(DEVICE_UDID) $(APP_PATH); do \
		attempt=$$((attempt + 1)); \
		if [ $$attempt -gt 3 ]; then echo "install failed after 3 attempts"; exit 1; fi; \
		echo "install attempt $$((attempt - 1)) failed, retrying in 3s..."; \
		sleep 3; \
	done

# Build Release + install on the 13 mini. The Release configuration points
# the app at PRODUCTION (dashboard.getbored.online) — use this to smoke-test
# the real prod flow on-device before archiving to TestFlight.
install-release: build-release preflight-release
	-xcrun devicectl device uninstall app --device $(PROD_DEVICE_UDID) $(BUNDLE_ID) 2>/dev/null
	@attempt=1; until xcrun devicectl device install app --device $(PROD_DEVICE_UDID) $(RELEASE_APP); do \
		attempt=$$((attempt + 1)); \
		if [ $$attempt -gt 3 ]; then echo "install failed after 3 attempts"; exit 1; fi; \
		echo "install attempt $$((attempt - 1)) failed, retrying in 3s..."; \
		sleep 3; \
	done
	@echo "GetBored (Release/prod) installed on 13 mini ($(PROD_DEVICE_UDID))"

# Kill whatever is listening on PORT (e.g. a stale Metro): make kill-port PORT=8081
kill-port:
	@pids=$$(lsof -ti tcp:$(PORT) -s tcp:LISTEN); \
	if [ -z "$$pids" ]; then \
		echo "nothing listening on port $(PORT)"; \
	else \
		for pid in $$pids; do ps -p $$pid -o pid=,command=; done; \
		kill $$pids && echo "killed listener(s) on port $(PORT)"; \
	fi

swift-test:
	swift test --filter IOSContractTests

# Rebuild the Kotlin GetBoredSharedCore.xcframework (run after editing shared-kotlin/**)
kmp:
	./gradlew :shared-kotlin:assembleGetBoredSharedCoreXCFramework

kmp-clean:
	./gradlew :shared-kotlin:clean

clean:
	rm -rf $(DERIVED_DATA)


agents-api-wake: ## Start isolated API-wake cmux agent workspace
	REPO_ROOT=$(CURDIR) ~/Agents-api-wake/configs/getbored-ios/cmux-api-wake-up

agents-wake-api: agents-api-wake ## Alias for agents-api-wake

agents-api-wake-kill: ## Kill isolated API-wake cmux agent workspace
	REPO_ROOT=$(CURDIR) ~/Agents-api-wake/configs/getbored-ios/cmux-api-wake-up --kill

agents-wake-api-kill: agents-api-wake-kill ## Alias for agents-api-wake-kill
