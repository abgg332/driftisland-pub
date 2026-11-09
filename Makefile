TARGET := iphone:clang:16.5:16.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DriftIsland DIWidgetHide
DriftIsland_FILES = Tweak.mm DIAlbumMask.mm
DriftIsland_CFLAGS = -fobjc-arc -std=c++17

DriftIsland_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreFoundation MediaPlayer
DriftIsland_LDFLAGS = -F$(THEOS_VENDOR_LIBRARY_PATH) -framework CydiaSubstrate

# 2.9.19: 组件隐藏(移植 RemoveWidgetBackground 1.7) —— 单独一个 dylib,
# 只注入 SpringBoard / chronod / WidgetRenderer, 与灵动岛那套互不干扰。
DIWidgetHide_FILES = DIWidgetHide.mm
DIWidgetHide_CFLAGS = -fobjc-arc
DIWidgetHide_FRAMEWORKS = UIKit Foundation
DIWidgetHide_LDFLAGS = -F$(THEOS_VENDOR_LIBRARY_PATH) -framework CydiaSubstrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	@echo "==> 覆盖注入 Filter (SpringBoard + MediaRemoteUI + 组件隐藏)"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"
	@cp DriftIsland.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/DriftIsland.plist"
	@cp DIWidgetHide.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/DIWidgetHide.plist"
