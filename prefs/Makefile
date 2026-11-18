ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DriftIslandPrefs
DriftIslandPrefs_FILES = Controllers.m DISpectrumPreview.m
DriftIslandPrefs_CFLAGS = -fobjc-arc -I..
DriftIslandPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
DriftIslandPrefs_PRIVATE_FRAMEWORKS = Preferences
DriftIslandPrefs_INSTALL_PATH = /Library/PreferenceBundles
DriftIslandPrefs_BUNDLE_RESOURCES = Root.plist icon.png

# Install explicit bundle metadata. A bare Mach-O + Root.plist does not provide
# NSBundle with the correct root controller; never inherit the Touch-Viz principal.
after-stage::
	@cp Resources/Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/DriftIslandPrefs.bundle/Info.plist"

include $(THEOS_MAKE_PATH)/bundle.mk
