ifeq ($(THEOS_DEVICE_SIMULATOR),1)
ARCHS := x86_64 arm64
TARGET := simulator:clang:latest:15.0
IPHONE_SIMULATOR_ROOT := $(shell ../devkit/sim-root.sh)
else
ARCHS ?= arm64 arm64e
TVZ_SDK ?= 16.5
TARGET := iphone:clang:$(TVZ_SDK):16.0
INSTALL_TARGET_PROCESSES := Preferences
endif

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME := TVZPrefs

TVZPrefs_FILES += $(wildcard *.mm)
TVZPrefs_FILES += $(wildcard *.swift)

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
TVZPrefs_FILES += ../libroot/dyn.c
endif
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
TVZPrefs_FILES += ../libroot/dyn.c
endif

TVZPrefs_CFLAGS += -fobjc-arc
TVZPrefs_CFLAGS += -I..
TVZPrefs_CFLAGS += -DPACKAGE_VERSION=\"$(PACKAGE_VERSION)\"
ifneq ($(THEOS_DEVICE_SIMULATOR),1)
# SwiftUI module interfaces in the downloaded iOS16.5 SDK were built by Swift5.8;
# this runner uses Swift6. Use its matching Xcode SDK while retaining iOS16 deployment.
TVZPrefs_SWIFTFLAGS += -sdk $(shell xcrun --sdk iphoneos --show-sdk-path)
endif

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
TVZPrefs_CFLAGS += -DIPHONE_SIMULATOR_ROOT=\"$(IPHONE_SIMULATOR_ROOT)\"
endif

# swift-create-xcframework --no-debug-symbols --static-library --platform ios --xc-setting ARCHS="arm64 arm64e" --clean SwiftUIIntrospect

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
TVZPrefs_LDFLAGS += -FFrameworks/_Simulator
TVZPrefs_LDFLAGS += -FFrameworks/_Simulator/MCEmojiPicker.xcframework/ios-arm64_x86_64-simulator -framework MCEmojiPicker
TVZPrefs_LDFLAGS += -FFrameworks/_Simulator/SwiftUIIntrospect.xcframework/ios-arm64_x86_64-simulator -framework SwiftUIIntrospect
TVZPrefs_SWIFTFLAGS += -FFrameworks/_Simulator/MCEmojiPicker.xcframework/ios-arm64_x86_64-simulator -framework MCEmojiPicker
TVZPrefs_SWIFTFLAGS += -FFrameworks/_Simulator/SwiftUIIntrospect.xcframework/ios-arm64_x86_64-simulator -framework SwiftUIIntrospect
else
TVZPrefs_LDFLAGS += -FFrameworks
TVZPrefs_LDFLAGS += -FFrameworks/MCEmojiPicker.xcframework/ios-arm64_arm64e -framework MCEmojiPicker
TVZPrefs_LDFLAGS += -FFrameworks/SwiftUIIntrospect.xcframework/ios-arm64_arm64e -framework SwiftUIIntrospect
TVZPrefs_SWIFTFLAGS += -FFrameworks/MCEmojiPicker.xcframework/ios-arm64_arm64e -framework MCEmojiPicker
TVZPrefs_SWIFTFLAGS += -FFrameworks/SwiftUIIntrospect.xcframework/ios-arm64_arm64e -framework SwiftUIIntrospect
endif

TVZPrefs_FRAMEWORKS += UIKit
TVZPrefs_PRIVATE_FRAMEWORKS += Preferences

TVZPrefs_SWIFT_BRIDGING_HEADER += TVZPrefs-Bridging-Header.h
TVZPrefs_INSTALL_PATH += /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
