TARGET := iphone:clang:16.5:16.0
ARCHS = arm64 arm64e
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = PrivateNativePlayer
PrivateNativePlayer_FILES = Player.mm
PrivateNativePlayer_CFLAGS = -fobjc-arc -std=c++17 -Wno-unused-function -Wno-unused-variable
PrivateNativePlayer_FRAMEWORKS = UIKit Foundation QuartzCore CoreFoundation
PrivateNativePlayer_LDFLAGS = -F$(THEOS_VENDOR_LIBRARY_PATH) -framework CydiaSubstrate
include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
after-stage::
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries" "$(THEOS_STAGING_DIR)/Library/Application Support/NativePlayerOriginal"
	@cp np/NativePlayerOriginal.dylib np/NativePlayerOriginal.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"
	@cp np/NPROriginal*.dylib np/extraction-manifest.json "$(THEOS_STAGING_DIR)/Library/Application Support/NativePlayerOriginal/"
	@ldid -S "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/NativePlayerOriginal.dylib"
