TARGET := iphone:clang:16.5:16.0
ARCHS = arm64 arm64e
include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = PrivateNativePlayerPrefs
PrivateNativePlayerPrefs_FILES = Controllers.m
PrivateNativePlayerPrefs_CFLAGS = -fobjc-arc
PrivateNativePlayerPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
PrivateNativePlayerPrefs_PRIVATE_FRAMEWORKS = Preferences
PrivateNativePlayerPrefs_INSTALL_PATH = /Library/PreferenceBundles
PrivateNativePlayerPrefs_RESOURCE_DIRS = Resources
include $(THEOS_MAKE_PATH)/bundle.mk
