/* 独立原生播放器 —— 主tweak。
   运行时 = 3.1 的真实实现(NativeRuntime.inc: 背景/隐藏未在/隐藏时间/MediaRemote取图)
          + 3.1 的 3×1 真实占位钩子(Grid.inc)
          + NativePlayerOriginal 核心库(旋转/隐藏投送/遮罩/背景跟随, 自读 com.local.playerexact)。
   音律/粒子/频谱/音频采样 全部排除。 */
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>
#import <notify.h>
#include <math.h>
#include <string.h>
#include <initializer_list>

#include "NativeRuntime.inc"
#include "Rotation.inc"

static void PNPLog(NSString *fmt, ...) { va_list a; va_start(a,fmt); NSString *s=[[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a); NSLog(@"[原生播放器] %@",s); }
#include "Grid.inc"

/* 播放器根视图: 背景 + 隐藏未在/时间, 由 3.1 模块容器 hook 驱动 */
static NSHashTable *npRoots = nil;

static void npDriveRoot(UIView *root) {
    if (!root || !root.window) return;
    @try {
        diArtPlayerPost(root);
    } @catch (__unused NSException *e) {}
}

static void (*npLayoutOrig)(id, SEL);
static void npLayout(id self, SEL cmd) {
    if (npLayoutOrig) npLayoutOrig(self, cmd);
    UIView *v = self;
    if (!v || [NSStringFromClass(v.class) containsString:@"Activity"]) return;
    if (!npRoots) npRoots = [NSHashTable weakObjectsHashTable];
    [npRoots addObject:v];
    __weak UIView *w = v;
    dispatch_async(dispatch_get_main_queue(), ^{ npDriveRoot(w); });
}

static void npInstallHooks(void) {
    pnp31Install();
    diArtInstallAVHook();
    static BOOL done = NO;
    if (done) return;
    Class npv = NSClassFromString(@"MRUNowPlayingView");
    if (!npv) return;
    MSHookMessageEx(npv, @selector(layoutSubviews), (IMP)npLayout, (IMP *)&npLayoutOrig);
    /* 3.1 的 3×1 真实占位钩子 */
    pnp31Install();
    done = YES;
}

static void npRespringReload(void) {
    /* 面板注销后 SpringBoard 重启, 重新驱动一次 */
    dispatch_async(diPrefQ(), ^{
        diArtForceRefresh();
        dispatch_async(dispatch_get_main_queue(), ^{
            for(UIView *a in gDIArtKnown.allObjects)diArtApply(a,diArtPrefOn()||diArtMaskWanted());
        });
    });
    gDISizeGen++;
    npInstallHooks();
    for (UIView *r in npRoots.allObjects) npDriveRoot(r);
}

__attribute__((constructor)) static void npStart(void) {
    if (![NSProcessInfo.processInfo.processName isEqual:@"SpringBoard"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        npRespringReload();
        diNPStartBgTimer();
        /* 监听面板/核心库的刷新通知 */
        int tok;
        notify_register_dispatch("com.local.playerexact/artwork-changed", &tok,
                                 dispatch_get_main_queue(), ^(int t){ (void)t; npRespringReload(); });
        /* 周期性兜底(布局可能早于通知) */
        NSTimer *tm = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t){
            (void)t; npInstallHooks();
            for (UIView *r in npRoots.allObjects) npDriveRoot(r);
        }];
        [NSRunLoop.mainRunLoop addTimer:tm forMode:NSRunLoopCommonModes];
    });
}
