export PACKAGE_VERSION := 4.2

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
ARCHS := arm64 x86_64
TARGET := simulator:clang:latest:15.0
FWK_DIR := Frameworks/_Simulator
IPHONE_SIMULATOR_ROOT := $(shell devkit/sim-root.sh)
else
ARCHS ?= arm64 arm64e
# TVZ_SDK: Swift 目标需要与 runner 工具链匹配的 SDK(由 CI 设为 xcrun 版本)
TVZ_SDK ?= 16.5
TARGET := iphone:clang:$(TVZ_SDK):16.0
INSTALL_TARGET_PROCESSES := SpringBoard
FWK_DIR := Frameworks
endif

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += TVZPrefs
SUBPROJECTS += CCTouchViz

include $(THEOS_MAKE_PATH)/aggregate.mk

TWEAK_NAME := TouchViz

TouchViz_USE_MODULES := 0

TouchViz_FILES += $(wildcard TVZPrefs/*.mm)
TouchViz_FILES += $(wildcard TVZQuickPath/*.swift)
TouchViz_FILES += $(wildcard LNTouchVisualizer/Private/*.m)
TouchViz_FILES += TouchViz.xm

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
TouchViz_FILES += libroot/dyn.c
endif

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
TouchViz_FILES += libroot/dyn.c
TouchViz_LIBRARIES += roothide
endif

TouchViz_CFLAGS += -fobjc-arc
TouchViz_CFLAGS += -I.
TouchViz_CFLAGS += -ILNTouchVisualizer
TouchViz_CFLAGS += -ILNTouchVisualizer/Private
TouchViz_CFLAGS += -DPACKAGE_VERSION=\"$(PACKAGE_VERSION)\"

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
TouchViz_CFLAGS += -DIPHONE_SIMULATOR_ROOT=\"$(IPHONE_SIMULATOR_ROOT)\"
endif

TouchViz_CCFLAGS += -Wno-unused-variable
TouchViz_CCFLAGS += -Wno-unused-function

TouchViz_LDFLAGS += -F$(FWK_DIR)

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
TouchViz_LDFLAGS += -rpath /opt/simject
endif

TouchViz_SWIFT_BRIDGING_HEADER += TouchViz-Bridging-Header.h
TouchViz_PRIVATE_FRAMEWORKS += FrontBoardServices

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
TouchViz_EXTRA_FRAMEWORKS += RevealServer
endif

include $(THEOS_MAKE_PATH)/tweak.mk

export DEBUG
before-all::
	sh devkit/standardize-entitlements.sh

export THEOS_OBJ_DIR
after-all::
	@true
