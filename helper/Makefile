ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = DriftIslandPreview
DriftIslandPreview_FILES = main.m
DriftIslandPreview_CFLAGS = -fobjc-arc
DriftIslandPreview_FRAMEWORKS = Foundation UIKit UserNotifications
DriftIslandPreview_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
