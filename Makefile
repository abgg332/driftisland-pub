TARGET := iphone:clang:16.5:16.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DriftIsland
DriftIsland_FILES = Tweak.mm
DriftIsland_CFLAGS = -fobjc-arc -std=c++17
DriftIsland_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
