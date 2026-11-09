/* ============================================================
   DriftIslandWidgets ——「组件隐藏」
   移植自 RemoveWidgetBackground 1.7 (Lessica / OwnGoal Studio, GPL/LGPL 见原仓库)
   原实现要点:
     · SpringBoard 侧: 拦 CHUISWidgetHostViewController 的背景/快照更新,
       让系统不再画底板; viewWillAppear 里把 UIVisualEffectView / MTMaterialView
       的 alpha 归零; SBIconView 的小组件标签 alpha 归零。
     · chronod / WidgetRenderer 侧(真正的绘制进程):
       给对应 widget 的窗口打标记, 在 RBLayer.display 时置线程标志,
       RBShape.setRect 把大于阈值的矩形改成 CGRectZero —— 等于把
       "铺满整张卡的大背景绘制指令"扔掉, 只留内容。这是它能通杀第三方
       SwiftUI 小组件的原因(RenderBox 是 SwiftUI 的私有渲染后端)。
   本文件按原逻辑 1:1 复刻, 只把 Logos 换成 MSHookMessageEx, 设置键换成
   DriftIsland 的 prefs 域。
   ============================================================ */
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <substrate.h>

static NSString *const DIW_DOMAIN = @"com.abgg332.driftisland";

static BOOL diwOn = NO;
static BOOL diwMaterial = YES;
static BOOL diwSystem = YES;
static BOOL diwDark = YES;
static double diwMaxW = 150.0;
static double diwMaxH = 150.0;
static NSSet<NSString *> *diwAppIds = nil;
static NSArray<NSString *> *diwSysIds = nil;

static BOOL diwIsSB = NO;
static BOOL diwIsChrono = NO;

static id diwPref(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)DIW_DOMAIN);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                       (__bridge CFStringRef)DIW_DOMAIN));
}

static void diwReloadPrefs(void) {
    id v = diwPref(@"widgetHideOn");
    diwOn = [v isKindOfClass:NSNumber.class] ? [v boolValue] : NO;
    v = diwPref(@"widgetHideMaterialOn");
    diwMaterial = [v isKindOfClass:NSNumber.class] ? [v boolValue] : YES;
    /* 2.9.20: 设置里删掉了「隐藏 MaterialView 背景」这一项 —— 它是隐藏底板的一部分,
       跟着总开关走, 恒开。 */
    diwMaterial = YES;
    v = diwPref(@"widgetHideSystemOn");
    diwSystem = [v isKindOfClass:NSNumber.class] ? [v boolValue] : YES;
    v = diwPref(@"widgetHideDarkOn");
    diwDark = [v isKindOfClass:NSNumber.class] ? [v boolValue] : YES;
    v = diwPref(@"widgetHideMaxW");
    diwMaxW = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 150.0;
    v = diwPref(@"widgetHideMaxH");
    diwMaxH = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 150.0;
    v = diwPref(@"widgetHideApps");
    NSArray *apps = [v isKindOfClass:NSArray.class] ? v : nil;
    if (!apps) apps = @[@"com.growing.topwidgetsplus", @"dk.simonbs.Scriptable", @"wiki.qaq.trapp.LaunchPad"];
    diwAppIds = [NSSet setWithArray:apps];

    diwSysIds = @[
        @"com.apple.mobiletimer.WorldClockWidget",
        @"com.apple.mobilecal.CalendarWidgetExtension",
        @"com.apple.mobilemail.MailWidgetExtension",
        @"com.apple.ScreenTimeWidgetApplication.ScreenTimeWidgetExtension",
        @"com.apple.reminders.WidgetExtension",
        @"com.apple.weather.widget",
        @"com.apple.Fitness.FitnessWidget",
        @"com.apple.Passbook.PassbookWidgets",
        @"com.apple.Health.Sleep.SleepWidgetExtension",
        @"com.apple.tips.TipsSwift",
        @"com.apple.Music.MusicWidgets",
        @"com.apple.gamecenter.widgets.extension",
        @"com.apple.tv.TVWidgetExtension",
        @"com.apple.news.widget",
    ];
    NSLog(@"[DIW] prefs on=%d mat=%d sys=%d dark=%d max=%.0fx%.0f apps=%@",
          diwOn, diwMaterial, diwSystem, diwDark, diwMaxW, diwMaxH, diwAppIds);
}

/* widget 是否命中"要隐藏背景"的名单。
   兼容两种写法: 直接是插件 id, 或用户选的是宿主 App id(插件 id 以它开头)。 */
static BOOL diwMatchWidget(id widget) {
    if (!diwOn || !widget) return NO;
    NSString *ext = nil;
    @try { ext = [widget valueForKey:@"extensionBundleIdentifier"]; } @catch (__unused NSException *e) {}
    if (![ext isKindOfClass:NSString.class] || !ext.length) return NO;
    if (diwSystem && [diwSysIds containsObject:ext]) return YES;
    for (NSString *a in diwAppIds) {
        if ([ext isEqualToString:a]) return YES;
        if ([ext hasPrefix:[a stringByAppendingString:@"."]]) return YES;
    }
    return NO;
}

static id diwWidgetOf(id host) {
    id w = nil;
    @try { w = [host valueForKey:@"widget"]; } @catch (__unused NSException *e) {}
    return w;
}

static UIView *diwFirstSubview(UIViewController *vc) {
    UIView *v = nil;
    @try { v = vc.view; } @catch (__unused NSException *e) {}
    return v.subviews.firstObject;
}

@interface UIWindow (DIW)
@property (nonatomic, strong) NSNumber *diw_hideBg;
@end
static char kDIWHideBg;
@implementation UIWindow (DIW)
- (NSNumber *)diw_hideBg { return objc_getAssociatedObject(self, &kDIWHideBg); }
- (void)setDiw_hideBg:(NSNumber *)v {
    objc_setAssociatedObject(self, &kDIWHideBg, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

static void diwHook(Class c, NSString *selName, IMP imp, IMP *outOld) {
    if (!c) return;
    SEL sel = NSSelectorFromString(selName);
    if (!class_getInstanceMethod(c, sel)) return;
    MSHookMessageEx(c, sel, imp, outOld);
}

/* ===================== SpringBoard ===================== */

static void (*o_avocadoUpdateBg)(id, SEL);
static void h_avocadoUpdateBg(id self, SEL _cmd) {
    if (diwMatchWidget(diwWidgetOf(self))) return;   /* 不更新原背景材质/颜色 */
    o_avocadoUpdateBg(self, _cmd);
}

static id (*o_avocadoShotMgr)(id, SEL);
static id h_avocadoShotMgr(id self, SEL _cmd) {
    if (diwMatchWidget(diwWidgetOf(self))) return nil;
    return o_avocadoShotMgr(self, _cmd);
}

static void (*o_sbhVWA)(id, SEL, BOOL);
static void h_sbhVWA(id self, SEL _cmd, BOOL animated) {
    o_sbhVWA(self, _cmd, animated);
    if (!diwOn) return;
    UIView *first = diwFirstSubview(self);
    if ([first isKindOfClass:UIVisualEffectView.class]) first.alpha = 0;
}

static NSUInteger (*o_hostScheme)(id, SEL);
static NSUInteger h_hostScheme(id self, SEL _cmd) {
    if (diwOn && diwDark) return 2;   /* UIUserInterfaceStyleDark */
    return o_hostScheme(self, _cmd);
}

/* 2.9.20: 修「强制深色没效果」——
   只改 colorScheme 在某些路径上不够: 宿主 VC 自己是从 trait 环境取外观的,
   这里在它 viewWillAppear 时把 VC 与它的 view 都强制成深色,
   让传给渲染进程的外观参数从一开始就是 dark。 */
static void (*o_hostVWA)(id, SEL, BOOL);
static void h_hostVWA(id self, SEL _cmd, BOOL animated) {
    o_hostVWA(self, _cmd, animated);
    if (!diwOn || !diwDark) return;
    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *vc = (UIViewController *)self;
    vc.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    vc.view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
}

static void (*o_hostUpdateBg)(id, SEL);
static void h_hostUpdateBg(id self, SEL _cmd) {
    if (diwMatchWidget(diwWidgetOf(self))) return;
    o_hostUpdateBg(self, _cmd);
}

static void (*o_hostUpdateSnap)(id, SEL);
static void h_hostUpdateSnap(id self, SEL _cmd) {
    if (diwMatchWidget(diwWidgetOf(self))) return;
    o_hostUpdateSnap(self, _cmd);
}

static void (*o_hostUpdateSnapIf)(id, SEL);
static void h_hostUpdateSnapIf(id self, SEL _cmd) {
    if (diwMatchWidget(diwWidgetOf(self))) return;
    o_hostUpdateSnapIf(self, _cmd);
}

static id (*o_hostShotURL)(id, SEL, id);
static id h_hostShotURL(id self, SEL _cmd, id url) {
    if (diwMatchWidget(diwWidgetOf(self))) return nil;
    return o_hostShotURL(self, _cmd, url);
}

/* 小组件标签名: 原实现是"只要是 SBWidgetIcon 就 alpha 0" */
static BOOL diwIsWidgetIconView(id self) {
    id icon = nil;
    @try { icon = [self valueForKey:@"icon"]; } @catch (__unused NSException *e) {}
    if (!icon) return NO;
    return [NSStringFromClass([icon class]) containsString:@"SBWidgetIcon"];
}

static double (*o_iconLabelAlpha)(id, SEL);
static double h_iconLabelAlpha(id self, SEL _cmd) {
    if (diwOn && diwIsWidgetIconView(self)) return 0;
    return o_iconLabelAlpha(self, _cmd);
}

static double (*o_iconEffLabelAlpha)(id, SEL);
static double h_iconEffLabelAlpha(id self, SEL _cmd) {
    if (diwOn && diwIsWidgetIconView(self)) return 0;
    return o_iconEffLabelAlpha(self, _cmd);
}

static void (*o_stackVWA)(id, SEL, BOOL);
static void h_stackVWA(id self, SEL _cmd, BOOL animated) {
    o_stackVWA(self, _cmd, animated);
    if (!diwOn || !diwMaterial) return;
    UIView *first = diwFirstSubview(self);
    first = first.subviews.firstObject;
    if ([first isKindOfClass:NSClassFromString(@"MTMaterialView")]) first.alpha = 0;
}

static void (*o_wgItemVWA)(id, SEL, BOOL);
static void h_wgItemVWA(id self, SEL _cmd, BOOL animated) {
    o_wgItemVWA(self, _cmd, animated);
    if (!diwOn || !diwMaterial) return;
    UIView *first = diwFirstSubview(self);
    if ([first isKindOfClass:NSClassFromString(@"MTMaterialView")]) first.alpha = 0;
}

/* ===================== chronod / WidgetRenderer ===================== */

static id (*o_windowInit)(id, SEL, id);
static id h_windowInit(id self, SEL _cmd, id scene) {
    NSString *ext = nil;
    @try { ext = [[scene valueForKey:@"widget"] valueForKey:@"extensionBundleIdentifier"]; } @catch (__unused NSException *e) {}
    if ([ext isKindOfClass:NSString.class] && ext.length) {
        if (diwSystem && [diwSysIds containsObject:ext]) {
            [self setDiw_hideBg:@YES];
        } else {
            for (NSString *a in diwAppIds) {
                if ([ext isEqualToString:a] || [ext hasPrefix:[a stringByAppendingString:@"."]]) {
                    [self setDiw_hideBg:@YES];
                    break;
                }
            }
        }
    }
    id win = o_windowInit(self, _cmd, scene);
    if (win && diwDark) [win setOverrideUserInterfaceStyle:UIUserInterfaceStyleDark];
    return win;
}

static NSUInteger (*o_sceneScheme)(id, SEL);
static NSUInteger h_sceneScheme(id self, SEL _cmd) {
    if (diwDark) return 2;
    return o_sceneScheme(self, _cmd);
}

/* 2.9.20: RenderBox / SwiftUI 取"当前外观"走的这个私有值对象, 直接把它钉成 2。
   原插件在 iOS 15 就是这么干的; iOS 16 上也存在, 一并挂上 —— 这比只改窗口
   override 更彻底(有些小组件的内容不走 trait)。 */
static long long (*o_uisStyle)(id, SEL);
static long long h_uisStyle(id self, SEL _cmd) {
    if (diwOn && diwDark) return 2;
    return o_uisStyle(self, _cmd);
}

static long long (*o_attrScheme)(id, SEL);
static long long h_attrScheme(id self, SEL _cmd) {
    if (diwDark) return 2;
    return o_attrScheme(self, _cmd);
}

/* 原实现: chronod 里除 UIHostingView 外的所有视图背景都清成透明。
   真正把背景去掉的还是下面的 RBShape 裁剪, 这里只是兜底。 */
static void (*o_uivLayout)(UIView *self, SEL);
static void h_uivLayout(UIView *self, SEL _cmd) {
    o_uivLayout(self, _cmd);
    if (!diwOn) return;
    /* 2.9.20: 渲染进程里把承载小组件的窗口统一压成深色 —— 这是"强制深色"
       真正生效的一环(SwiftUI 的 UIHostingController 会跟随 window 的 trait)。 */
    if (diwDark) {
        UIWindow *w = self.window;
        if (w && w.overrideUserInterfaceStyle != UIUserInterfaceStyleDark)
            w.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    if (![NSStringFromClass([self class]) containsString:@"UIHostingView"])
        [self setBackgroundColor:UIColor.clearColor];
}

static void (*o_rbDisplay)(id, SEL);
static void h_rbDisplay(id self, SEL _cmd) {
    UIView *view = (UIView *)[self delegate];
    UIWindow *win = [view isKindOfClass:UIView.class] ? view.window : nil;
    if (win && win.diw_hideBg.boolValue) {
        NSMutableDictionary *td = [NSThread currentThread].threadDictionary;
        td[@"diw_hideBg"] = @YES;
        if (@available(iOS 17, *)) { if ([self isOpaque]) [self setOpaque:NO]; }
        o_rbDisplay(self, _cmd);
        [td removeObjectForKey:@"diw_hideBg"];
        [td removeObjectForKey:@"diw_skipFirst"];
        [td removeObjectForKey:@"diw_skipFirstN"];
        return;
    }
    o_rbDisplay(self, _cmd);
}

/* iOS 15: 第一个超阈值矩形直接丢
   iOS 16: 第一次超阈值放过, 之后丢
   iOS 17: 前两次放过/丢交错(第一个必丢, 第二个放过), 之后丢 —— 与原实现一致 */
static void (*o_rbSetRect)(id, SEL, CGRect);
static void h_rbSetRect(id self, SEL _cmd, CGRect rect) {
    NSMutableDictionary *td = [NSThread currentThread].threadDictionary;
    if (td[@"diw_hideBg"]) {
        if (rect.size.width > diwMaxW && rect.size.height > diwMaxH) {
            int major = (int)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
            if (major >= 17) {
                NSNumber *firstN = td[@"diw_skipFirstN"];
                if ([firstN intValue] > 1) { o_rbSetRect(self, _cmd, CGRectZero); return; }
                int newN = firstN ? [firstN intValue] + 1 : 0;
                td[@"diw_skipFirstN"] = @(newN);
                if (newN == 1) { o_rbSetRect(self, _cmd, CGRectZero); return; }
            } else if (major >= 16) {
                if ([td[@"diw_skipFirst"] boolValue]) { o_rbSetRect(self, _cmd, CGRectZero); return; }
                td[@"diw_skipFirst"] = @YES;
            } else {
                o_rbSetRect(self, _cmd, CGRectZero);
                return;
            }
        }
    }
    o_rbSetRect(self, _cmd, rect);
}

static void diwInstallSpringBoardHooks(void) {
    diwHook(NSClassFromString(@"CHUISAvocadoHostViewController"),
            @"_updateBackgroundMaterialAndColor", (IMP)h_avocadoUpdateBg, (IMP *)&o_avocadoUpdateBg);
    diwHook(NSClassFromString(@"CHUISAvocadoHostViewController"),
            @"screenshotManager", (IMP)h_avocadoShotMgr, (IMP *)&o_avocadoShotMgr);

    diwHook(NSClassFromString(@"SBHWidgetViewController"),
            @"viewWillAppear:", (IMP)h_sbhVWA, (IMP *)&o_sbhVWA);

    Class host = NSClassFromString(@"CHUISWidgetHostViewController");
    diwHook(host, @"colorScheme", (IMP)h_hostScheme, (IMP *)&o_hostScheme);
    diwHook(host, @"viewWillAppear:", (IMP)h_hostVWA, (IMP *)&o_hostVWA);
    diwHook(host, @"_updateBackgroundMaterialAndColor", (IMP)h_hostUpdateBg, (IMP *)&o_hostUpdateBg);
    diwHook(host, @"_updatePersistedSnapshotContent", (IMP)h_hostUpdateSnap, (IMP *)&o_hostUpdateSnap);
    diwHook(host, @"_updatePersistedSnapshotContentIfNecessary", (IMP)h_hostUpdateSnapIf, (IMP *)&o_hostUpdateSnapIf);
    diwHook(host, @"_snapshotImageFromURL:", (IMP)h_hostShotURL, (IMP *)&o_hostShotURL);

    Class iconView = NSClassFromString(@"SBIconView");
    diwHook(iconView, @"iconLabelAlpha", (IMP)h_iconLabelAlpha, (IMP *)&o_iconLabelAlpha);
    diwHook(iconView, @"effectiveIconLabelAlpha", (IMP)h_iconEffLabelAlpha, (IMP *)&o_iconEffLabelAlpha);

    diwHook(NSClassFromString(@"SBHWidgetStackViewController"),
            @"viewWillAppear:", (IMP)h_stackVWA, (IMP *)&o_stackVWA);
    diwHook(NSClassFromString(@"WGWidgetListItemViewController"),
            @"viewWillAppear:", (IMP)h_wgItemVWA, (IMP *)&o_wgItemVWA);
}

static void diwInstallChronoHooks(void) {
    diwHook(NSClassFromString(@"UIWindow"), @"initWithWindowScene:", (IMP)h_windowInit, (IMP *)&o_windowInit);
    diwHook(NSClassFromString(@"CHUISWidgetScene"), @"colorScheme", (IMP)h_sceneScheme, (IMP *)&o_sceneScheme);
    diwHook(NSClassFromString(@"CHSMutableScreenshotPresentationAttributes"),
            @"colorScheme", (IMP)h_attrScheme, (IMP *)&o_attrScheme);
    diwHook(NSClassFromString(@"CHSScreenshotPresentationAttributes"),
            @"colorScheme", (IMP)h_attrScheme, (IMP *)&o_attrScheme);
    diwHook(NSClassFromString(@"UIView"), @"layoutSubviews", (IMP)h_uivLayout, (IMP *)&o_uivLayout);
    diwHook(NSClassFromString(@"UISCurrentUserInterfaceStyleValue"),
            @"userInterfaceStyle", (IMP)h_uisStyle, (IMP *)&o_uisStyle);
    diwHook(NSClassFromString(@"RBLayer"), @"display", (IMP)h_rbDisplay, (IMP *)&o_rbDisplay);
    diwHook(NSClassFromString(@"RBShape"), @"setRect:", (IMP)h_rbSetRect, (IMP *)&o_rbSetRect);
}

/* 2.9.20: 设置页「注销生效」不再依赖 kill 权限 —— 它只发一条 Darwin 通知,
   哪个进程收到就自己退出, launchd 会立刻把它拉起来(等于 respring)。 */
static void diwRegisterRespring(void) {
    static BOOL done = NO;
    int token = 0;
    notify_register_dispatch("com.abgg332.driftisland.widget.respring", &token,
                             dispatch_get_main_queue(), ^(int t) {
        if (done) return;
        done = YES;
        NSLog(@"[DIW] 收到注销通知, %@ 自行退出", NSProcessInfo.processInfo.processName);
        exit(0);
    });
}

__attribute__((constructor)) static void diwInit(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *exe = NSProcessInfo.processInfo.arguments.firstObject.lastPathComponent ?: @"";
    diwIsSB = [bid isEqualToString:@"com.apple.springboard"];
    diwIsChrono = [bid isEqualToString:@"com.apple.chronod"]
               || [bid hasPrefix:@"com.apple.chrono.WidgetRenderer-"]
               || [exe isEqualToString:@"chronod"]
               || [exe hasPrefix:@"com.apple.chrono.WidgetRenderer-"];
    if (!diwIsSB && !diwIsChrono) return;

    diwRegisterRespring();   /* 放在总开关判断之前: 关了开关也能被注销按钮叫醒 */

    diwReloadPrefs();
    if (!diwOn) { NSLog(@"[DIW] 总开关关闭, 不装 hook (%@)", bid); return; }

    if (diwIsSB) {
        diwInstallSpringBoardHooks();
        NSLog(@"[DIW] SpringBoard hook 安装完成");
    } else {
        diwInstallChronoHooks();
        NSLog(@"[DIW] chronod hook 安装完成 (%@)", bid);
    }
}
