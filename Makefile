TARGET := iphone:clang:16.5:16.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DriftIsland DIWidgetHide DIAudio
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

# 3.0.45: 音频能量采样端 —— 只注入 mediaserverd, hook AudioUnitRender 算 RMS,
# 本机 socket 推给 SpringBoard 侧做专辑律动/粒子。不动音频数据, 卸载即还原。
DIAudio_FILES = DIAudio.mm
DIAudio_CFLAGS = -fobjc-arc
DIAudio_FRAMEWORKS = Foundation AudioToolbox
DIAudio_LDFLAGS = -F$(THEOS_VENDOR_LIBRARY_PATH) -framework CydiaSubstrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	@echo "==> 覆盖注入 Filter (SpringBoard + MediaRemoteUI + 组件隐藏)"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"
	@cp DriftIsland.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/DriftIsland.plist"
	@cp DIWidgetHide.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/DIWidgetHide.plist"
	@cp DIAudio.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/DIAudio.plist"
	@echo "==> 3.0.3 捆绑原生播放器 (0.3.20 原版二进制 + 启动自禁用两条指令补丁; 保留 rootless/roothide 双 rpath)"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support/NativePlayerOriginal/"
	@cp np/NativePlayerOriginal.dylib np/NativePlayerOriginal.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"
	@cp np/NPROriginalRuntime.dylib np/NPROriginalRuntime3x2B.dylib np/NPROriginalLayout.dylib np/NPROriginalLayout3x2B.dylib np/extraction-manifest.json "$(THEOS_STAGING_DIR)/Library/Application Support/NativePlayerOriginal/"
	@chmod 755 "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/NativePlayerOriginal.dylib" "$(THEOS_STAGING_DIR)/Library/Application Support/NativePlayerOriginal/"*.dylib
	@echo "==> 重签打过启动补丁的 NativePlayerOriginal.dylib"
	@if command -v ldid >/dev/null 2>&1; then \
		ldid -S "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/NativePlayerOriginal.dylib" && echo "ldid OK"; \
	else echo "警告: 没有 ldid, 跳过重签"; fi
	@echo "==> 校验 rpath (rootless /var/jb + roothide .jbroot 必须都在)"
	@grep -aq "/var/jb/Library/Frameworks" "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/NativePlayerOriginal.dylib" \
		&& echo "rpath rootless OK" || (echo "rpath 缺失 /var/jb" && exit 1)
	@echo "==> 生成合并版 postinst (初始化播放器偏好域 com.local.playerexact: Enabled + ActivationVersion)"
	@mkdir -p "$(THEOS_STAGING_DIR)/DEBIAN"
	@printf '#!/bin/sh\nset -e\nif [ "$$1" = "configure" ]; then\n  rm -f -- /var/mobile/Library/Logs/NativePlayerOriginal-0.3.1.log\n  P=/var/mobile/Library/Preferences/com.local.playerexact\n  for D in /var/jb/usr/bin/defaults /usr/bin/defaults; do\n    if [ -x "$$D" ]; then\n      "$$D" write "$$P" Enabled -bool true >/dev/null 2>&1 || true\n      "$$D" write "$$P" ActivationVersion -string 0.3.1 >/dev/null 2>&1 || true\n      "$$D" delete "$$P" StartupPendingVersion >/dev/null 2>&1 || true\n      "$$D" delete "$$P" StartupPendingToken >/dev/null 2>&1 || true\n      break\n    fi\n  done\n  chown mobile:mobile "$$P.plist" 2>/dev/null || true\n  chmod 644 "$$P.plist" 2>/dev/null || true\nfi\nexit 0\n' > "$(THEOS_STAGING_DIR)/DEBIAN/postinst"
	@chmod 755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst"
