ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DriftIslandPrefs
DriftIslandPrefs_FILES = Controllers.m
DriftIslandPrefs_CFLAGS = -fobjc-arc -I..
DriftIslandPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
DriftIslandPrefs_PRIVATE_FRAMEWORKS = Preferences
DriftIslandPrefs_INSTALL_PATH = /Library/PreferenceBundles
DriftIslandPrefs_BUNDLE_RESOURCES = Root.plist icon.png

include $(THEOS_MAKE_PATH)/bundle.mk
