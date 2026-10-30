TARGET := iphone:clang:16.5:16.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DriftIsland
DriftIsland_FILES = Tweak.mm
DriftIsland_CFLAGS = -fobjc-arc -std=c++17
DriftIsland_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreFoundation
DriftIsland_LDFLAGS = -F$(THEOS_VENDOR_LIBRARY_PATH) -framework CydiaSubstrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	@echo "==> 覆盖注入 Filter (SpringBoard + MediaRemoteUI)"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"
	@cp DriftIsland.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/DriftIsland.plist"
