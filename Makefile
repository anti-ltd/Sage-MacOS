APP_NAME = Sage
BUNDLE   = build/$(APP_NAME).app
DMG      = build/$(APP_NAME).dmg
BIN      = .build/release/$(APP_NAME)
ICONSET  = build/AppIcon.iconset
ICNS     = Resources/AppIcon.icns
ENTITLEMENTS     = Resources/Sage.entitlements
MAS_ENTITLEMENTS = Resources/Sage.mas.entitlements
MAS_PKG          = build/$(APP_NAME).pkg
MAS_PROFILE      ?= Resources/Sage_MAS.provisionprofile

MAS_SIGN_APP ?= 3rd Party Mac Developer Application: William Whitehouse (8248296AJX)
MAS_SIGN_PKG ?= 3rd Party Mac Developer Installer: William Whitehouse (8248296AJX)
DEVID_SIGN_APP ?= Developer ID Application: William Whitehouse (8248296AJX)

NOTARY_KEY_ID  ?= KZ765P9ZHP
NOTARY_ISSUER  ?= 66eec4bc-6987-480b-9af2-c26ea01d2ed2
NOTARY_KEY     ?= $(HOME)/.appstoreconnect/private_keys/AuthKey_$(NOTARY_KEY_ID).p8

SIGN_ID := $(shell security find-certificate -c "Sage Dev" >/dev/null 2>&1 && echo "Sage Dev" || echo -)

ifdef MAS
SWIFT_FLAGS += -Xswiftc -DSAGE_MAS
endif

.PHONY: all build icon app run dmg build-mas mas-package bump version clean test dist dist-manifest

all: app

build:
	swift build -c release $(SWIFT_FLAGS)

icon: build
	rm -rf $(ICONSET)
	$(BIN) --icon $(ICONSET)
	@if command -v pngquant >/dev/null 2>&1; then \
		echo "Quantizing icon PNGs..."; \
		for f in $(ICONSET)/*.png; do \
			pngquant --quality=90-100 --speed 1 --force --output "$$f" "$$f" || true; \
		done; \
	else \
		echo "pngquant not found, skipping (brew install pngquant)"; \
	fi
	@if command -v optipng >/dev/null 2>&1; then \
		echo "Optimizing icon PNGs..."; \
		optipng -quiet -o7 $(ICONSET)/*.png; \
	else \
		echo "optipng not found, skipping (brew install optipng)"; \
	fi
	iconutil -c icns $(ICONSET) -o $(ICNS)
	@echo "Icon -> $(ICNS)"

app: icon
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	strip $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(ICNS) $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --deep --sign "$(SIGN_ID)" --entitlements $(ENTITLEMENTS) $(BUNDLE)
	@echo "Built $(BUNDLE) (signed: $(SIGN_ID))"

run: app
	@pkill -x Sage 2>/dev/null || true
	@# Register the freshly-built bundle with Launch Services, else `open` can fail -600.
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(abspath $(BUNDLE))" 2>/dev/null || true
	open $(BUNDLE)

dmg: app
	rm -rf build/dmg $(DMG)
	mkdir -p build/dmg
	cp -R $(BUNDLE) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname "$(APP_NAME)" -srcfolder build/dmg -ov -format UDZO $(DMG)
	rm -rf build/dmg
	@echo "Built $(DMG)"

version:
	@SHORT=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist); \
	BUILD=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist); \
	echo "Sage $$SHORT ($$BUILD)"

bump:
	@CURRENT=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist); \
	NEXT=$$(( CURRENT + 1 )); \
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$NEXT" Resources/Info.plist; \
	echo "CFBundleVersion: $$CURRENT -> $$NEXT"

build-mas:
	@$(MAKE) --no-print-directory mas-package MAS=1

mas-package: icon
	@if [ -z "$(NO_BUMP)" ]; then $(MAKE) --no-print-directory bump; fi
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	strip $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(ICNS) $(BUNDLE)/Contents/Resources/AppIcon.icns
	cp Resources/PrivacyInfo.xcprivacy $(BUNDLE)/Contents/Resources/PrivacyInfo.xcprivacy
	cp $(MAS_PROFILE) $(BUNDLE)/Contents/embedded.provisionprofile
	xattr -cr $(BUNDLE)
	codesign --force --deep \
		--sign "$(MAS_SIGN_APP)" \
		--identifier ltd.anti.sage \
		--entitlements $(MAS_ENTITLEMENTS) \
		--options runtime \
		$(BUNDLE)
	productbuild \
		--component $(BUNDLE) /Applications \
		--sign "$(MAS_SIGN_PKG)" \
		$(MAS_PKG)
	@echo "Built $(MAS_PKG)"

test:
	swift test

DIST_VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DIST_DMG     = build/Sage-$(DIST_VERSION).dmg
DIST_JSON    = build/Sage-$(DIST_VERSION).json

dist: icon
	@echo "── Direct-distribution build: Sage $(DIST_VERSION) ──"
	rm -rf $(BUNDLE) $(DIST_DMG) $(DIST_JSON)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	strip $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(ICNS) $(BUNDLE)/Contents/Resources/AppIcon.icns
	cp Resources/PrivacyInfo.xcprivacy $(BUNDLE)/Contents/Resources/PrivacyInfo.xcprivacy
	xattr -cr $(BUNDLE)
	codesign --force --deep --timestamp \
		--sign "$(DEVID_SIGN_APP)" \
		--options runtime \
		--entitlements $(ENTITLEMENTS) \
		$(BUNDLE)
	codesign --verify --strict --deep --verbose=2 $(BUNDLE)
	rm -rf build/dmg
	mkdir -p build/dmg
	cp -R $(BUNDLE) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname "$(APP_NAME)" -srcfolder build/dmg -ov -format UDZO $(DIST_DMG)
	rm -rf build/dmg
	xcrun notarytool submit $(DIST_DMG) \
		--key $(NOTARY_KEY) \
		--key-id $(NOTARY_KEY_ID) \
		--issuer $(NOTARY_ISSUER) \
		--wait
	xcrun stapler staple $(DIST_DMG)
	$(MAKE) --no-print-directory dist-manifest
	@echo "✓ Built $(DIST_DMG)"

dist-manifest:
	@SIZE=$$(stat -f %z $(DIST_DMG)); \
	SHA=$$(shasum -a 256 $(DIST_DMG) | awk '{print $$1}'); \
	RELEASED=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	MIN_OS=$$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist); \
	NOTES=$${SAGE_RELEASE_NOTES:-"Initial release."}; \
	printf '{\n  "version": "%s",\n  "releasedAt": "%s",\n  "notes": "%s",\n  "minOS": "macOS %s",\n  "sha256": "%s",\n  "size": %d\n}\n' \
		"$(DIST_VERSION)" "$$RELEASED" "$$NOTES" "$$MIN_OS" "$$SHA" "$$SIZE" \
		> $(DIST_JSON)

clean:
	rm -rf .build build
