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

.PHONY: all build build-release build-device install install-only swift-test clean

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

# Build + install on XR (mirrors monorepo build-ios-on-air)
install: build-device
	-xcrun devicectl device uninstall app --device $(DEVICE_UDID) $(BUNDLE_ID) 2>/dev/null
	xcrun devicectl device install app --device $(DEVICE_UDID) $(APP_PATH)
	@echo "GetBored installed on XR ($(DEVICE_UDID))"

# Install without rebuild
install-only:
	-xcrun devicectl device uninstall app --device $(DEVICE_UDID) $(BUNDLE_ID) 2>/dev/null
	xcrun devicectl device install app --device $(DEVICE_UDID) $(APP_PATH)

swift-test:
	swift test --filter IOSContractTests

clean:
	rm -rf $(DERIVED_DATA)
