ifeq ($(THEOS_DEVICE_SIMULATOR),1)
ARCHS := x86_64 arm64
TARGET := simulator:clang:latest:15.0
IPHONE_SIMULATOR_ROOT := $(shell ../devkit/sim-root.sh)
else
ARCHS ?= arm64 arm64e
TARGET := iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES := SpringBoard
endif

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME := CCTouchViz

CCTouchViz_BUNDLE_EXTENSION += bundle

CCTouchViz_FILES += CCTouchViz.mm
CCTouchViz_FILES += $(wildcard ../TVZPrefs/*.mm)

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
CCTouchViz_FILES += ../libroot/dyn.c
endif
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CCTouchViz_FILES += ../libroot/dyn.c
endif

CCTouchViz_CFLAGS += -fobjc-arc
CCTouchViz_CFLAGS += -I../TVZPrefs
CCTouchViz_CFLAGS += -DPACKAGE_VERSION=\"$(PACKAGE_VERSION)\"

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
CCTouchViz_CFLAGS += -DIPHONE_SIMULATOR_ROOT=\"$(IPHONE_SIMULATOR_ROOT)\"
endif

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
CCTouchViz_LDFLAGS += -FFrameworks/_Simulator
endif

CCTouchViz_FRAMEWORKS += UIKit
CCTouchViz_PRIVATE_FRAMEWORKS += ControlCenterUIKit
CCTouchViz_INSTALL_PATH += /Library/ControlCenter/Bundles

include $(THEOS_MAKE_PATH)/bundle.mk
