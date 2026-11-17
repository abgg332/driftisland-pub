/* 独立原生播放器 —— 原生播放面板 1:1 原样移植自 漂流岛 Controllers.m(除律动特效)。
   由 extract.py 逐块复制, 未改写函数体; 仅删除律动入口行并补 DIFxPage 空实现。 */
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
#import <objc/runtime.h>
#include <sys/sysctl.h>
#include <sys/param.h>
#include <stdlib.h>
static NSString *const kMaterialDir = @"/var/mobile/灵动岛";
static NSArray<NSString *> *diSortStrs(NSArray *arr);

/* 偏好字符串读写 */
static NSString *readPrefString(NSString *key) {
    if (!key.length) return nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return [v isKindOfClass:NSString.class] ? (NSString *)v : nil;
}
static void diPostReloadRaw(void) {
 /* standalone: no driftisland prefs reload */
}

static NSString *const kNotifyStr = @"com.abgg332.driftisland/prefsChanged";
static NSString *const kDIAlbumMaskKey = @"diAlbumMaskAsset";
static NSString *const kDIPlayerMaskKey = @"PlayerMaskAsset";
static NSString *const kDomain = @"com.abgg332.driftisland";
static NSString *const kDIPlayerMaskOnKey = @"PlayerMaskOn";
static NSString *const kDIMaskRoot = @"/var/mobile/灵动岛/遮罩素材";
static NSString * const kNPModuleID = @"com.apple.mediaremote.controlcenter.nowplaying";
static NSString *readPrefString(NSString *key) {
    if (!key.length) return nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return [v isKindOfClass:NSString.class] ? (NSString *)v : nil;
}
static void writePrefString(NSString *value, NSString *key) {
    if (!key.length) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)(value ?: @""),
                             (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
}
static void postReload(void) {
    static CFAbsoluteTime last; static BOOL queued;
    if (!NSThread.isMainThread) { diPostReloadRaw(); return; }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!queued && now - last >= 0.15) { last = now; diPostReloadRaw(); return; }
    if (queued) return;
    queued = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        queued = NO; last = CFAbsoluteTimeGetCurrent(); diPostReloadRaw();
    });
}
static NSArray<NSString *> *DIMaskListAssets(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:kDIMaskRoot isDirectory:&isDir] || !isDir) return out;

    NSMutableArray<NSString *> *queue = [NSMutableArray arrayWithObject:@""];
    int depthGuard = 0;
    while (queue.count && depthGuard++ < 200) {
        NSString *rel = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSInteger depth = rel.length ? ([rel componentsSeparatedByString:@"/"].count) : 0;
        NSString *full = rel.length ? [kDIMaskRoot stringByAppendingPathComponent:rel] : kDIMaskRoot;
        NSArray<NSString *> *items = diSortStrs([fm contentsOfDirectoryAtPath:full error:NULL]);
        for (NSString *name in items) {
            if (![name isKindOfClass:NSString.class]) continue;
            if ([name hasPrefix:@"."]) continue;
            NSString *childRel = rel.length ? [rel stringByAppendingPathComponent:name] : name;
            NSString *childFull = [kDIMaskRoot stringByAppendingPathComponent:childRel];
            BOOL d = NO;
            if (![fm fileExistsAtPath:childFull isDirectory:&d]) continue;
            if (!d) {
                NSString *ext = name.pathExtension.lowercaseString;
                if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] ||
                    [ext isEqualToString:@"jpeg"]) [out addObject:childRel];
            } else if (depth < 3) {
                [queue addObject:childRel];
            }
        }
    }
    return out;
}
static void diwKillByComm(const char *comm) {
    /* 3.0.12: 真要注销 SpringBoard 前先落"人为注销"标记(所有注销入口共用这里),
       启动保险据此区分"人按了注销"和"崩溃后自动 respawn"。 */
    if (comm && strcmp(comm, "SpringBoard") == 0) {
        CFPreferencesSetAppValue(CFSTR("PendingRespringTS"),
                                 (__bridge CFPropertyListRef)@([[NSDate date] timeIntervalSince1970]),
                                 CFSTR("com.abgg332.driftisland"));
        CFPreferencesAppSynchronize(CFSTR("com.abgg332.driftisland"));
    }
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) < 0 || len == 0) return;
    struct kinfo_proc *procs = malloc(len + sizeof(struct kinfo_proc));
    if (!procs) return;
    if (sysctl(mib, 4, procs, &len, NULL, 0) == 0) {
        int n = (int)(len / sizeof(struct kinfo_proc));
        for (int i = 0; i < n; i++) {
            pid_t pid = procs[i].kp_proc.p_pid;
            if (pid <= 1) continue;
            if (strncmp(procs[i].kp_proc.p_comm, comm, MAXCOMLEN) == 0) kill(pid, SIGTERM);
        }
    }
    free(procs);
}
static void diStep(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void diStep(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    static NSDateFormatter *df = nil;
    static dispatch_once_t fonce;
    dispatch_once(&fonce, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:kMaterialDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:NULL];
        df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        df.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    });
    static int n = 0; static int dropped = 0; static CFAbsoluteTime sec = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSString *dropNote = nil;
    if (now - sec >= 1.0) {
        if (dropped > 0) dropNote = [NSString stringWithFormat:@"(上一秒省略 %d 行)", dropped];
        dropped = 0; sec = now; n = 0;
    }
    if (n >= 25) { dropped++; return; }
    n++;
    NSString *path = [kMaterialDir stringByAppendingPathComponent:@"driftisland.log"];
    NSString *out = [NSString stringWithFormat:@"[%@] [现场] %@%@\n", [df stringFromDate:[NSDate date]], line,
                     dropNote ?: @""];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]; return; }
    @try { [h seekToEndOfFile]; [h writeData:[out dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (__unused NSException *e) {}
    [h closeFile];
}
static BOOL diIsFxKey(NSString *key) {
    if (![key isKindOfClass:NSString.class] || !key.length) return NO;
    static NSArray<NSString *> *pfx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pfx = @[@"Album", @"Rhythm", @"Particle", @"Spectrum", @"Ring", @"ArtworkProgress", @"ArtworkRing", @"ProgressRing"];
    });
    for (NSString *p in pfx) if ([key hasPrefix:p]) return YES;
    return NO;
}
static void diPostFxTune(void) {
    notify_post("com.abgg332.driftisland.fxtune");
}
static id diFxReadSized(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                      (__bridge CFStringRef)kDomain));
    if (v) return v;
    NSRange at = [key rangeOfString:@"@" options:NSBackwardsSearch];
    if (at.location != NSNotFound && at.location > 0) {
        NSString *base = [key substringToIndex:at.location];
        v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)base,
                                                       (__bridge CFStringRef)kDomain));
    }
    return v;
}
static double diStepForKeyOverride(NSString *key);

/* 把 specifier 的关键信息缓存到 cell 上(布局时调用一次) */
static void diStepCacheSpec(UITableViewCell *cell) {
    if (!cell) return;
    /* 3.0.60: **不能**只看"有没有缓存"就早退。
       cell 是复用的 —— 上一行(例如"粒子数量" step=1)被滚出屏幕后,
       同一个 cell 可能拿来显示"粒子大小", 但 di_k_key 还停在旧 key 上,
       于是 diStepOf() 永远拿不到 AlbumParticleSize 的 0.1, 按 + 就是 1 的步进
       (显示上 1 → 2, 用户看到的就是"怎么改都不是 0.1")。
       现在每次都对比 specifier 当前的 key, 变了就整包重写。 */
    PSSpecifier *sp = nil;
    @try {
        if ([cell respondsToSelector:NSSelectorFromString(@"specifier")]) {
            NSMethodSignature *ms = [cell methodSignatureForSelector:NSSelectorFromString(@"specifier")];
            if (ms && ms.numberOfArguments == 2 && ms.methodReturnLength == sizeof(void *)) {
                sp = ((PSSpecifier *(*)(id, SEL))objc_msgSend)(cell, NSSelectorFromString(@"specifier"));
            }
        }
    } @catch (__unused NSException *e) { sp = nil; }
    if (!sp) return;
    @try {
        NSString *k = [sp propertyForKey:@"key"];
        NSString *d = [sp propertyForKey:@"defaults"];
        if (!k.length || !d.length) return;
        NSString *cached = objc_getAssociatedObject(cell, "di_k_key");
        NSNumber *newStep = [sp propertyForKey:@"diStep"];
        id cachedStep = objc_getAssociatedObject(cell, "di_k_step");
        if ([k isEqualToString:cached] && (cachedStep || !newStep)) return;   /* 同一行且 step 没丢 */
        objc_setAssociatedObject(cell, "di_k_key", k, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, "di_k_dom", d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, "di_k_min", [sp propertyForKey:@"min"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, "di_k_max", [sp propertyForKey:@"max"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, "di_k_def", [sp propertyForKey:@"default"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, "di_k_name", [sp name], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        /* 3.0.60: 按 key 兜底 —— 就算 specifier 上的 diStep 没传下来, 这几行也强制小数步进 */
        double ov = diStepForKeyOverride(k);
        id stp = (ov > 0.0) ? @(ov) : newStep;
        objc_setAssociatedObject(cell, "di_k_step", stp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (__unused NSException *e) {}
}
static Class diStepSliderClass(void) {
    diInstallStepSliderOnPSSliderCell();
    return NSClassFromString(@"PSSliderCell");
}
static NSString * const kNPDomain = @"com.local.playerexact";

static id diNPRead(NSString *key, NSString *dom) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)dom);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                       (__bridge CFStringRef)dom));
}

static void diNPWrite(NSString *key, id val, NSString *dom) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)val,
                             (__bridge CFStringRef)dom);
    CFPreferencesAppSynchronize((__bridge CFStringRef)dom);
}

/* 尺寸/功能共用的键表 —— 导入与重置都按这张表走(与原版面板同源) */
static NSArray<NSString *> *diNPKeys(void) {
    return @[ @"Size", @"ModuleSizes", @"PlayerGridVariant",
              @"MusicArtworkBackgroundMode", @"MusicArtworkBlurRadius",
              @"MusicArtworkGradientEnabled", @"ArtworkRotationEnabled",
              @"BlockN95Artwork", @"HideRoutingIcon", @"HideNotPlaying",
              @"HideTimeWhenIdle" ];
}

static BOOL diNPReadEnabled(void) {
    id v = diNPRead(@"Enabled", kNPDomain);
    return ([v isKindOfClass:NSNumber.class]) ? [v boolValue] : YES;
}

/* ===== 3.0.5: 尺寸真正生效的写法 =====
   反编译原版面板(NativePlayerOriginalPrefs)的 setPreferenceValue:specifier: 后确认:
   播放器启动时读的**不是** Size 键, 而是
       ModuleSizes 字典里的 "com.apple.mediaremote.controlcenter.nowplaying" 一项;
       另外 3×2 布局 B 这个特殊档, 模块尺寸要写 4x2、把 "3x2b" 写进 PlayerGridVariant。
   只写 Size 时播放器永远读默认值(3x2), 所以之前不管怎么改尺寸都没反应。 */
static NSString * const kNPModuleID = @"com.apple.mediaremote.controlcenter.nowplaying";

static NSString *diNPCurrentSize(void) {
    /* 3.0.113: 3×1 必须先认 Size —— 它的模块占位写的是 4x1(系统只认这几档), 而
       PlayerGridVariant 被清空, 所以按下面原顺序会读到 ModuleSizes 的 "4x1",
       设置页于是把参数写到 AlbumXxx@4x1, 运行时却按 @3x1 读 —— 键对不上,
       用户看到的就是"3×1 下参数设置无效"。这里先拦一道。 */
    {
        id s31 = diNPRead(@"Size", kNPDomain);
        if ([s31 isKindOfClass:NSString.class] && [(NSString *)s31 isEqualToString:@"3x1"])
            return @"3x1";
    }
    id variant = diNPRead(@"PlayerGridVariant", kNPDomain);
    if ([variant isKindOfClass:NSString.class] && [variant length]) return variant;
    id dict = diNPRead(@"ModuleSizes", kNPDomain);
    if ([dict isKindOfClass:NSDictionary.class]) {
        id s = dict[kNPModuleID];
        if ([s isKindOfClass:NSString.class] && [s length]) return s;
    }
    id sz = diNPRead(@"Size", kNPDomain);
    return ([sz isKindOfClass:NSString.class] && [sz length]) ? sz : @"2x2";
}

static void diNPApplySize(NSString *size) {
    if (![size isKindOfClass:NSString.class] || !size.length) return;
    NSMutableDictionary *sizes = [NSMutableDictionary dictionary];
    id cur = diNPRead(@"ModuleSizes", kNPDomain);
    if ([cur isKindOfClass:NSDictionary.class]) [sizes addEntriesFromDictionary:cur];

    NSString *moduleSize = size;
    NSString *variant = nil;
    if ([size isEqualToString:@"3x2b"]) {   /* 布局 B: 模块按 4x2 放, 变体交给 PlayerGridVariant */
        moduleSize = @"4x2";
        variant = @"3x2b";
    } else if ([size isEqualToString:@"3x1"]) {
        /* 3.0.120: bundled renderer uses 4x1 as one-row CONTENT template only.
           Tweak overrides CCUIModuleSettings and collection layout values to 3x1.
           Never equate this template string with the physical module footprint. */
        moduleSize = @"4x1";
        variant = nil;
    }
    sizes[kNPModuleID] = moduleSize;
    diNPWrite(@"ModuleSizes", sizes, kNPDomain);
    diNPWrite(@"PlayerGridVariant", variant, kNPDomain);
    diNPWrite(@"Size", size, kNPDomain);
}

/* 3.0.111: 3×1 档位回来了 —— 原来"把遗留 3x1 改回 4x1"的自愈必须撤掉,
   否则用户刚选完 3×1, 下次进设置页就被这段改回 4×1。
   现在只做一件事: 把历史遗留的**非法模块尺寸** 3x1 修正成 4x1(模块占位永远是 4x1,
   收窄由运行时钩子做), Size 键保持 3x1 不动。 */
static void diNPMigrateRetiredSizes(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    id dict = diNPRead(@"ModuleSizes", kNPDomain);
    if (![dict isKindOfClass:NSDictionary.class]) return;
    id v = ((NSDictionary *)dict)[kNPModuleID];
    if (![v isKindOfClass:NSString.class] || ![v isEqualToString:@"3x1"]) return;
    NSMutableDictionary *m = [dict mutableCopy];
    m[kNPModuleID] = @"4x1";
    diNPWrite(@"ModuleSizes", m, kNPDomain);
}

/* 3.0.3: 播放器构造器有两道门槛 —— Enabled 必须是 true, 且 ActivationVersion 必须等于 "0.3.1"。
   只拨开关不写 ActivationVersion, 播放器直接 return, 一个 hook 都不装(表现就是"改了没效果")。
   原版面板拨开关时两个键是一起写的, 这里补上。 */
static NSString * const kNPActivationVer = @"0.3.1";

static void diNPEnsureActivation(void) {
    id en = diNPRead(@"Enabled", kNPDomain);
    BOOL keyExists = [en isKindOfClass:NSNumber.class];
    if (keyExists && ![en boolValue]) return;   /* 用户显式关掉, 不擅自改 */
    NSString *av = diNPRead(@"ActivationVersion", kNPDomain);
    if (keyExists && [av isKindOfClass:NSString.class] && [av isEqualToString:kNPActivationVer]) return;
    diNPWrite(@"Enabled", @YES, kNPDomain);
    diNPWrite(@"ActivationVersion", kNPActivationVer, kNPDomain);
    diNPWrite(@"StartupPendingVersion", nil, kNPDomain);
    diNPWrite(@"StartupPendingToken", nil, kNPDomain);
}

    slider.frame = CGRectMake(padX, topY + rowH, W - padX - (btnW + 6.0) - padX, rowH);

    if (title) {
        NSString *name = objc_getAssociatedObject(cell, "di_k_name");
        if (name.length) title.text = name;
    }
- (PSSpecifier *)groupSpec:(NSString *)header footer:(NSString *)footer;
- (PSSpecifier *)switchSpec:(NSString *)name key:(NSString *)key def:(id)def;
- (PSSpecifier *)numSlider:(NSString *)label key:(NSString *)key def:(int)def mn:(int)mn mx:(int)mx;
- (id)readPreferenceValue:(PSSpecifier *)spec;
- (PSSpecifier *)buttonSpec:(NSString *)name action:(SEL)sel;
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls;
@end
/* 2.6.28: 锁屏设置页 —— 完全照歌词岛的做法(DIMiniBaseController + linkSpec),
   这是唯一一个从来没闪退过的二级页形态 */
@interface DILockScreenPage : DIMiniBaseController @end
/* 2.6.29: 文字颜色页(原"文字样式"组的内容, 整体搬进来, 键值零改动) */
@interface DITextStylePage : DIMiniBaseController @end
/* 2.8.12: 歌词岛合并页回归(2.8.4/2.8.5 下架后恢复) ——
   上半=左侧专辑帧率, 下半=右侧音频帧率, 下面=专辑遮罩设置(2.2.24 原版形态) */
@interface DILyricsIslandSettings : DIMiniBaseController <UIColorPickerViewControllerDelegate> @end
/* 2.8.41: 控制中心页回归(单素材=浅色键 wpLightAsset, 无深浅色分组) */
@interface DICCSettings : DIMiniBaseController @end
/* 2.8.87: 展开定义 —— 遮罩素材下面的二级页(位置/大小/颜色) */
@interface DIExpandDefinePage : DIMiniBaseController @end
/* 2.9.19: 组件隐藏(移植 RemoveWidgetBackground 1.7) */
@interface DIWidgetHidePage : DIMiniBaseController @end
@interface DIWidgetAppsPage : DIMiniBaseController @end
/* 3.0: 播放器入口 —— 组件隐藏下面同级, 开关写 com.local.playerexact(内置原生播放器域) */
@interface DIPlayerEntryPage : DIMiniBaseController @end
/* 3.0.45: 律动特效页 —— 总开关/封面律动/环/粒子/参数/渐变色全在这一页 */
@interface DIFxPage : DIMiniBaseController
/* 3.0.57: 颜色行用系统取色盘; 这几个方法在 @implementation 内部前后互相调用, 先声明一遍 */
- (void)diPickFxColor:(PSSpecifier *)sp;
- (void)diOpenFxPickerKeyA:(NSString *)a keyB:(NSString *)b title:(NSString *)t;
@end
/* 3.0.1: 尺寸选择页自建 —— 不再走系统的 PSListItemsController(点进去闪退) */
@interface DIPlayerSizePage : DIMiniBaseController @end
@interface DIFrameFoldersMask : DIFrameFolders @end /* 2.6.3: 遮罩素材选择(键 maskAnimFolder) */
@interface DIFrameFoldersMini : DIFrameFolders @end  /* 左侧(mini)帧率素材选择(键 smallAnimFolder) */
@interface DIFrameFoldersAudio : DIFrameFolders @end /* 右侧音频素材(键 miniAudioFolder) */
@interface DIPrefsController (ZoneLinkFwd)
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls;
- (void)diOpenPage:(PSSpecifier *)spec;
@end

static BOOL diGridPicked = NO; // 网格选中标记: 主页据此刷新按钮标题
@class DIPreviewGrid;
/* 2.2.22: 字体颜色面板走独立窗口(定义在文件末尾), 这里先声明 */
static void diOpenGradientPanelWindow(void);
/* 2.2.67: 流光风格面板(定义在文件后部) */
static NSArray *diStyleDefs(void);
static void diOpenStylePanelWindow(void);

/* 2.7.20: **整段删除信号处理器**。
   二进制符号对比给出了铁证 —— 2.7.13(能正常打开) 与 2.7.20(点入口闪退) 的
   DriftIslandPrefs 只差这 11 个外部符号:
     _backtrace  _backtrace_symbols_fd  _open  _close  _write  _snprintf
     _sigaction  _signal  _raise
     _OBJC_CLASS_$_UIActivityViewController  _OBJC_CLASS_$_UIDevice
   全是 2.7.16/2.7.20 新加的"崩溃抓栈/日志导出"。设置 App 是系统进程(Preferences),
   它自己会用 SIGSEGV 等信号做运行时断言/libffi 探测;我们一旦 sigaction 抢走这些信号,
   系统判定进程异常,直接 kill —— 表现就是"点一下就回桌面,日志一行都不写"。
   2.7.20 只摘掉 SIGTRAP 不够,根治办法是**一个信号都不碰**,退回 2.7.13 的干净状态。 */


static void diPrefsReloadCB(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    BOOL isColor = (name && CFStringCompare(name, CFSTR("com.abgg332.driftisland.colorchanged"), 0) == kCFCompareEqualTo);
    if (!diGridPicked && !isColor) return; // 颜色变更始终刷新(更新渐变预览条)
    diGridPicked = NO;
    id self_ = (__bridge id)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        /* 2.7.36: 横条颜色点色闪退根因 —— 这里是 async 块, tapCard 的 @try 根本罩不住:
           点色 → colorchanged → 对"被 DIHomeBarPick 盖住的列表页"reloadSpecifiers,
           PSListController 在有二级页压顶时重建列表会抛未捕获异常 → 设置页直接闪退,
           且日志里只看得到"已应用"看不到任何异常行(和 264 日志完全吻合)。
           三重防御: ① 类型校验; ② 不在导航栈顶/视图不在窗口上就不刷(反正看不见);
           ③ 整段 @try, 异常只进日志。 */
        @try {
            if (![self_ isKindOfClass:[UIViewController class]]) return;
            UIViewController *vc = (UIViewController *)self_;
            UINavigationController *nav = vc.navigationController;
            if (nav && nav.topViewController != vc) return;   /* 有面板压顶, 刷新毫无意义还危险 */
            if (!vc.isViewLoaded || !vc.view.window) return;
            if (![vc respondsToSelector:@selector(reloadSpecifiers)]) return;
            [(id)vc reloadSpecifiers]; // 刷新按钮标题/渐变条
        } @catch (NSException *e) {
            diStep(@"偏好刷新: reload 异常 %@ - %@", e.name, e.reason ?: @"(未知)");
        }
    });
}
- (PSSpecifier *)buttonSpec:(NSString *)name action:(SEL)sel;
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls;
@end
/* 2.6.28: 锁屏设置页 —— 完全照歌词岛的做法(DIMiniBaseController + linkSpec),
   这是唯一一个从来没闪退过的二级页形态 */
@interface DILockScreenPage : DIMiniBaseController @end
/* 2.6.29: 文字颜色页(原"文字样式"组的内容, 整体搬进来, 键值零改动) */
@interface DITextStylePage : DIMiniBaseController @end
/* 2.8.12: 歌词岛合并页回归(2.8.4/2.8.5 下架后恢复) ——
   上半=左侧专辑帧率, 下半=右侧音频帧率, 下面=专辑遮罩设置(2.2.24 原版形态) */
@interface DILyricsIslandSettings : DIMiniBaseController <UIColorPickerViewControllerDelegate> @end
/* 2.8.41: 控制中心页回归(单素材=浅色键 wpLightAsset, 无深浅色分组) */
@interface DICCSettings : DIMiniBaseController @end
/* 2.8.87: 展开定义 —— 遮罩素材下面的二级页(位置/大小/颜色) */
@interface DIExpandDefinePage : DIMiniBaseController @end
/* 2.9.19: 组件隐藏(移植 RemoveWidgetBackground 1.7) */
@interface DIWidgetHidePage : DIMiniBaseController @end
@interface DIWidgetAppsPage : DIMiniBaseController @end
/* 3.0: 播放器入口 —— 组件隐藏下面同级, 开关写 com.local.playerexact(内置原生播放器域) */
@interface DIPlayerEntryPage : DIMiniBaseController @end
/* 3.0.45: 律动特效页 —— 总开关/封面律动/环/粒子/参数/渐变色全在这一页 */
@interface DIFxPage : DIMiniBaseController
/* 3.0.57: 颜色行用系统取色盘; 这几个方法在 @implementation 内部前后互相调用, 先声明一遍 */
- (void)diPickFxColor:(PSSpecifier *)sp;
- (void)diOpenFxPickerKeyA:(NSString *)a keyB:(NSString *)b title:(NSString *)t;
@end
/* 3.0.1: 尺寸选择页自建 —— 不再走系统的 PSListItemsController(点进去闪退) */
@interface DIPlayerSizePage : DIMiniBaseController @end
@interface DIFrameFoldersMask : DIFrameFolders @end /* 2.6.3: 遮罩素材选择(键 maskAnimFolder) */
@interface DIFrameFoldersMini : DIFrameFolders @end  /* 左侧(mini)帧率素材选择(键 smallAnimFolder) */
@interface DIFrameFoldersAudio : DIFrameFolders @end /* 右侧音频素材(键 miniAudioFolder) */
@interface DIPrefsController (ZoneLinkFwd)
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls;
- (void)diOpenPage:(PSSpecifier *)spec;
@end

static BOOL diGridPicked = NO; // 网格选中标记: 主页据此刷新按钮标题
@class DIPreviewGrid;
/* 2.2.22: 字体颜色面板走独立窗口(定义在文件末尾), 这里先声明 */
static void diOpenGradientPanelWindow(void);
/* 2.2.67: 流光风格面板(定义在文件后部) */
static NSArray *diStyleDefs(void);
static void diOpenStylePanelWindow(void);

/* 2.7.20: **整段删除信号处理器**。
   二进制符号对比给出了铁证 —— 2.7.13(能正常打开) 与 2.7.20(点入口闪退) 的
   DriftIslandPrefs 只差这 11 个外部符号:
     _backtrace  _backtrace_symbols_fd  _open  _close  _write  _snprintf
     _sigaction  _signal  _raise
     _OBJC_CLASS_$_UIActivityViewController  _OBJC_CLASS_$_UIDevice
   全是 2.7.16/2.7.20 新加的"崩溃抓栈/日志导出"。设置 App 是系统进程(Preferences),
   它自己会用 SIGSEGV 等信号做运行时断言/libffi 探测;我们一旦 sigaction 抢走这些信号,
   系统判定进程异常,直接 kill —— 表现就是"点一下就回桌面,日志一行都不写"。
   2.7.20 只摘掉 SIGTRAP 不够,根治办法是**一个信号都不碰**,退回 2.7.13 的干净状态。 */


static void diPrefsReloadCB(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    BOOL isColor = (name && CFStringCompare(name, CFSTR("com.abgg332.driftisland.colorchanged"), 0) == kCFCompareEqualTo);
    if (!diGridPicked && !isColor) return; // 颜色变更始终刷新(更新渐变预览条)
    diGridPicked = NO;
    id self_ = (__bridge id)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        /* 2.7.36: 横条颜色点色闪退根因 —— 这里是 async 块, tapCard 的 @try 根本罩不住:
           点色 → colorchanged → 对"被 DIHomeBarPick 盖住的列表页"reloadSpecifiers,
           PSListController 在有二级页压顶时重建列表会抛未捕获异常 → 设置页直接闪退,
           且日志里只看得到"已应用"看不到任何异常行(和 264 日志完全吻合)。
           三重防御: ① 类型校验; ② 不在导航栈顶/视图不在窗口上就不刷(反正看不见);
           ③ 整段 @try, 异常只进日志。 */
        @try {
            if (![self_ isKindOfClass:[UIViewController class]]) return;
            UIViewController *vc = (UIViewController *)self_;
            UINavigationController *nav = vc.navigationController;
            if (nav && nav.topViewController != vc) return;   /* 有面板压顶, 刷新毫无意义还危险 */
            if (!vc.isViewLoaded || !vc.view.window) return;
            if (![vc respondsToSelector:@selector(reloadSpecifiers)]) return;
            [(id)vc reloadSpecifiers]; // 刷新按钮标题/渐变条
        } @catch (NSException *e) {
            diStep(@"偏好刷新: reload 异常 %@ - %@", e.name, e.reason ?: @"(未知)");
        }
    });
}
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls;
@end
/* 2.6.28: 锁屏设置页 —— 完全照歌词岛的做法(DIMiniBaseController + linkSpec),
   这是唯一一个从来没闪退过的二级页形态 */
@interface DILockScreenPage : DIMiniBaseController @end
/* 2.6.29: 文字颜色页(原"文字样式"组的内容, 整体搬进来, 键值零改动) */
@interface DITextStylePage : DIMiniBaseController @end
/* 2.8.12: 歌词岛合并页回归(2.8.4/2.8.5 下架后恢复) ——
   上半=左侧专辑帧率, 下半=右侧音频帧率, 下面=专辑遮罩设置(2.2.24 原版形态) */
@interface DILyricsIslandSettings : DIMiniBaseController <UIColorPickerViewControllerDelegate> @end
/* 2.8.41: 控制中心页回归(单素材=浅色键 wpLightAsset, 无深浅色分组) */
@interface DICCSettings : DIMiniBaseController @end
/* 2.8.87: 展开定义 —— 遮罩素材下面的二级页(位置/大小/颜色) */
@interface DIExpandDefinePage : DIMiniBaseController @end
/* 2.9.19: 组件隐藏(移植 RemoveWidgetBackground 1.7) */
@interface DIWidgetHidePage : DIMiniBaseController @end
@interface DIWidgetAppsPage : DIMiniBaseController @end
/* 3.0: 播放器入口 —— 组件隐藏下面同级, 开关写 com.local.playerexact(内置原生播放器域) */
@interface DIPlayerEntryPage : DIMiniBaseController @end
/* 3.0.45: 律动特效页 —— 总开关/封面律动/环/粒子/参数/渐变色全在这一页 */
@interface DIFxPage : DIMiniBaseController
/* 3.0.57: 颜色行用系统取色盘; 这几个方法在 @implementation 内部前后互相调用, 先声明一遍 */
- (void)diPickFxColor:(PSSpecifier *)sp;
- (void)diOpenFxPickerKeyA:(NSString *)a keyB:(NSString *)b title:(NSString *)t;
@end
/* 3.0.1: 尺寸选择页自建 —— 不再走系统的 PSListItemsController(点进去闪退) */
@interface DIPlayerSizePage : DIMiniBaseController @end
@interface DIFrameFoldersMask : DIFrameFolders @end /* 2.6.3: 遮罩素材选择(键 maskAnimFolder) */
@interface DIFrameFoldersMini : DIFrameFolders @end  /* 左侧(mini)帧率素材选择(键 smallAnimFolder) */
@interface DIFrameFoldersAudio : DIFrameFolders @end /* 右侧音频素材(键 miniAudioFolder) */
@interface DIPrefsController (ZoneLinkFwd)
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls;
- (void)diOpenPage:(PSSpecifier *)spec;
@end

static BOOL diGridPicked = NO; // 网格选中标记: 主页据此刷新按钮标题
@class DIPreviewGrid;
/* 2.2.22: 字体颜色面板走独立窗口(定义在文件末尾), 这里先声明 */
static void diOpenGradientPanelWindow(void);
/* 2.2.67: 流光风格面板(定义在文件后部) */
static NSArray *diStyleDefs(void);
static void diOpenStylePanelWindow(void);

/* 2.7.20: **整段删除信号处理器**。
   二进制符号对比给出了铁证 —— 2.7.13(能正常打开) 与 2.7.20(点入口闪退) 的
   DriftIslandPrefs 只差这 11 个外部符号:
     _backtrace  _backtrace_symbols_fd  _open  _close  _write  _snprintf
     _sigaction  _signal  _raise
     _OBJC_CLASS_$_UIActivityViewController  _OBJC_CLASS_$_UIDevice
   全是 2.7.16/2.7.20 新加的"崩溃抓栈/日志导出"。设置 App 是系统进程(Preferences),
   它自己会用 SIGSEGV 等信号做运行时断言/libffi 探测;我们一旦 sigaction 抢走这些信号,
   系统判定进程异常,直接 kill —— 表现就是"点一下就回桌面,日志一行都不写"。
   2.7.20 只摘掉 SIGTRAP 不够,根治办法是**一个信号都不碰**,退回 2.7.13 的干净状态。 */


static void diPrefsReloadCB(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    BOOL isColor = (name && CFStringCompare(name, CFSTR("com.abgg332.driftisland.colorchanged"), 0) == kCFCompareEqualTo);
    if (!diGridPicked && !isColor) return; // 颜色变更始终刷新(更新渐变预览条)
    diGridPicked = NO;
    id self_ = (__bridge id)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        /* 2.7.36: 横条颜色点色闪退根因 —— 这里是 async 块, tapCard 的 @try 根本罩不住:
           点色 → colorchanged → 对"被 DIHomeBarPick 盖住的列表页"reloadSpecifiers,
           PSListController 在有二级页压顶时重建列表会抛未捕获异常 → 设置页直接闪退,
           且日志里只看得到"已应用"看不到任何异常行(和 264 日志完全吻合)。
           三重防御: ① 类型校验; ② 不在导航栈顶/视图不在窗口上就不刷(反正看不见);
           ③ 整段 @try, 异常只进日志。 */
        @try {
            if (![self_ isKindOfClass:[UIViewController class]]) return;
            UIViewController *vc = (UIViewController *)self_;
            UINavigationController *nav = vc.navigationController;
            if (nav && nav.topViewController != vc) return;   /* 有面板压顶, 刷新毫无意义还危险 */
            if (!vc.isViewLoaded || !vc.view.window) return;
            if (![vc respondsToSelector:@selector(reloadSpecifiers)]) return;
            [(id)vc reloadSpecifiers]; // 刷新按钮标题/渐变条
        } @catch (NSException *e) {
            diStep(@"偏好刷新: reload 异常 %@ - %@", e.name, e.reason ?: @"(未知)");
        }
    });
}
- (PSSpecifier *)switchSpec:(NSString *)name key:(NSString *)key def:(id)def;
- (PSSpecifier *)numSlider:(NSString *)label key:(NSString *)key def:(int)def mn:(int)mn mx:(int)mx;
- (id)readPreferenceValue:(PSSpecifier *)spec;
- (PSSpecifier *)buttonSpec:(NSString *)name action:(SEL)sel;
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls;
@end
/* 2.6.28: 锁屏设置页 —— 完全照歌词岛的做法(DIMiniBaseController + linkSpec),
   这是唯一一个从来没闪退过的二级页形态 */
@interface DILockScreenPage : DIMiniBaseController @end
/* 2.6.29: 文字颜色页(原"文字样式"组的内容, 整体搬进来, 键值零改动) */
@interface DITextStylePage : DIMiniBaseController @end
/* 2.8.12: 歌词岛合并页回归(2.8.4/2.8.5 下架后恢复) ——
   上半=左侧专辑帧率, 下半=右侧音频帧率, 下面=专辑遮罩设置(2.2.24 原版形态) */
@interface DILyricsIslandSettings : DIMiniBaseController <UIColorPickerViewControllerDelegate> @end
/* 2.8.41: 控制中心页回归(单素材=浅色键 wpLightAsset, 无深浅色分组) */
@interface DICCSettings : DIMiniBaseController @end
/* 2.8.87: 展开定义 —— 遮罩素材下面的二级页(位置/大小/颜色) */
@interface DIExpandDefinePage : DIMiniBaseController @end
/* 2.9.19: 组件隐藏(移植 RemoveWidgetBackground 1.7) */
@interface DIWidgetHidePage : DIMiniBaseController @end
@interface DIWidgetAppsPage : DIMiniBaseController @end
/* 3.0: 播放器入口 —— 组件隐藏下面同级, 开关写 com.local.playerexact(内置原生播放器域) */
@interface DIPlayerEntryPage : DIMiniBaseController @end
/* 3.0.45: 律动特效页 —— 总开关/封面律动/环/粒子/参数/渐变色全在这一页 */
@interface DIFxPage : DIMiniBaseController
/* 3.0.57: 颜色行用系统取色盘; 这几个方法在 @implementation 内部前后互相调用, 先声明一遍 */
- (void)diPickFxColor:(PSSpecifier *)sp;
- (void)diOpenFxPickerKeyA:(NSString *)a keyB:(NSString *)b title:(NSString *)t;
@end
/* 3.0.1: 尺寸选择页自建 —— 不再走系统的 PSListItemsController(点进去闪退) */
@interface DIPlayerSizePage : DIMiniBaseController @end
@interface DIFrameFoldersMask : DIFrameFolders @end /* 2.6.3: 遮罩素材选择(键 maskAnimFolder) */
@interface DIFrameFoldersMini : DIFrameFolders @end  /* 左侧(mini)帧率素材选择(键 smallAnimFolder) */
@interface DIFrameFoldersAudio : DIFrameFolders @end /* 右侧音频素材(键 miniAudioFolder) */
@interface DIPrefsController (ZoneLinkFwd)
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls;
- (void)diOpenPage:(PSSpecifier *)spec;
@end

static BOOL diGridPicked = NO; // 网格选中标记: 主页据此刷新按钮标题
@class DIPreviewGrid;
/* 2.2.22: 字体颜色面板走独立窗口(定义在文件末尾), 这里先声明 */
static void diOpenGradientPanelWindow(void);
/* 2.2.67: 流光风格面板(定义在文件后部) */
static NSArray *diStyleDefs(void);
static void diOpenStylePanelWindow(void);

/* 2.7.20: **整段删除信号处理器**。
   二进制符号对比给出了铁证 —— 2.7.13(能正常打开) 与 2.7.20(点入口闪退) 的
   DriftIslandPrefs 只差这 11 个外部符号:
     _backtrace  _backtrace_symbols_fd  _open  _close  _write  _snprintf
     _sigaction  _signal  _raise
     _OBJC_CLASS_$_UIActivityViewController  _OBJC_CLASS_$_UIDevice
   全是 2.7.16/2.7.20 新加的"崩溃抓栈/日志导出"。设置 App 是系统进程(Preferences),
   它自己会用 SIGSEGV 等信号做运行时断言/libffi 探测;我们一旦 sigaction 抢走这些信号,
   系统判定进程异常,直接 kill —— 表现就是"点一下就回桌面,日志一行都不写"。
   2.7.20 只摘掉 SIGTRAP 不够,根治办法是**一个信号都不碰**,退回 2.7.13 的干净状态。 */


static void diPrefsReloadCB(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    BOOL isColor = (name && CFStringCompare(name, CFSTR("com.abgg332.driftisland.colorchanged"), 0) == kCFCompareEqualTo);
    if (!diGridPicked && !isColor) return; // 颜色变更始终刷新(更新渐变预览条)
    diGridPicked = NO;
    id self_ = (__bridge id)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        /* 2.7.36: 横条颜色点色闪退根因 —— 这里是 async 块, tapCard 的 @try 根本罩不住:
           点色 → colorchanged → 对"被 DIHomeBarPick 盖住的列表页"reloadSpecifiers,
           PSListController 在有二级页压顶时重建列表会抛未捕获异常 → 设置页直接闪退,
           且日志里只看得到"已应用"看不到任何异常行(和 264 日志完全吻合)。
           三重防御: ① 类型校验; ② 不在导航栈顶/视图不在窗口上就不刷(反正看不见);
           ③ 整段 @try, 异常只进日志。 */
        @try {
            if (![self_ isKindOfClass:[UIViewController class]]) return;
            UIViewController *vc = (UIViewController *)self_;
            UINavigationController *nav = vc.navigationController;
            if (nav && nav.topViewController != vc) return;   /* 有面板压顶, 刷新毫无意义还危险 */
            if (!vc.isViewLoaded || !vc.view.window) return;
            if (![vc respondsToSelector:@selector(reloadSpecifiers)]) return;
            [(id)vc reloadSpecifiers]; // 刷新按钮标题/渐变条
        } @catch (NSException *e) {
            diStep(@"偏好刷新: reload 异常 %@ - %@", e.name, e.reason ?: @"(未知)");
        }
    });
}
@implementation DIPlayerEntryPage

/* 从尺寸页返回后刷新右侧当前值 */
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    diNPEnsureActivation();       /* 3.0.3: 进页先补齐激活键, 页面显示状态与实际一致 */
    diNPMigrateRetiredSizes();    /* 3.0.39: 已删除的 3×1 档位改回 4×1 */
    [self reloadSpecifiers];
}

/* 本页所有 specifier 都带 defaults=com.local.playerexact, 这里按 specifier 的域读写,
   不沿用基类的 kDomain(漂流岛自己的域) —— 播放器只认它自己的域。 */
- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    NSString *dom = [spec propertyForKey:@"defaults"] ?: kNPDomain;
    if (!key.length) return nil;
    id v = diNPRead(key, dom);
    if (v && ![v isKindOfClass:NSString.class] && ![v isKindOfClass:NSNumber.class]) v = nil;
    return v ?: [spec propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    NSString *dom = [spec propertyForKey:@"defaults"] ?: kNPDomain;
    if (!key.length) return;
    diNPWrite(key, value, dom);
    /* 播放器监听的刷新通知: 改开关/尺寸后它自己重读, 不用注销 */
    notify_post("com.local.playerexact/artwork-changed");
}

/* 播放器自己的开关(Enabled 默认 YES, 与基类 switchSpec 的 def 语义一致) */
- (id)readNPEnabled:(PSSpecifier *)sp { return @(diNPReadEnabled()); }
- (void)writeNPEnabled:(id)value specifier:(PSSpecifier *)sp {
    BOOL on = [value boolValue];
    diNPWrite(@"Enabled", @(on), kNPDomain);
    if (on) {
        /* 第一次开启时把尺寸落到 ModuleSizes, 否则播放器沿用旧值(常见是 3x2) */
        NSDictionary *sizes = diNPRead(@"ModuleSizes", kNPDomain);
        if (![sizes isKindOfClass:NSDictionary.class] || !sizes[kNPModuleID]) {
            NSString *sz = diNPRead(@"Size", kNPDomain);
            diNPApplySize(([sz isKindOfClass:NSString.class] && [sz length]) ? sz : @"2x2");
        }
        /* 3.0.3: 第二道门槛 —— 拨开开关时同时写激活版本, 否则播放器照样不启动 */
        diNPWrite(@"ActivationVersion", kNPActivationVer, kNPDomain);
        /* pending 键是播放器 30 秒清理标记, 残留会被旧版误判成启动失败, 顺手清掉 */
        diNPWrite(@"StartupPendingVersion", nil, kNPDomain);
        diNPWrite(@"StartupPendingToken", nil, kNPDomain);
    }
    notify_post("com.local.playerexact/artwork-changed");
}

- (void)showMessage:(NSString *)title body:(NSString *)body {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:body
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

/* 导入原播放器参数: 依次从 EvoCenter / 旧尺寸插件域把存在的键搬进当前域 */
- (void)importPlayerPreferences:(PSSpecifier *)sp {
    NSArray<NSString *> *sources = @[ @"com.jaysuen.evocenter", @"com.local.nativeplayerresize" ];
    NSUInteger n = 0;
    for (NSString *src in sources) {
        for (NSString *key in diNPKeys()) {
            id v = diNPRead(key, src);
            if (!v) continue;
            diNPWrite(key, v, kNPDomain);
            n++;
        }
    }
    notify_post("com.local.playerexact/artwork-changed");
    [self reloadSpecifiers];
    [self showMessage:@"导入完成"
                 body:(n ? [NSString stringWithFormat:@"已导入 %lu 项参数。", (unsigned long)n]
                         : @"没有找到可导入的旧参数(EvoCenter/旧尺寸插件未安装或未设置)。")];
}

/* 恢复默认: 删掉键(播放器内置默认: 2x2、封面背景开、其余关), 保留总开关 */
- (void)resetPlayerPreferences:(PSSpecifier *)sp {
    for (NSString *key in diNPKeys()) diNPWrite(key, nil, kNPDomain);
    notify_post("com.local.playerexact/artwork-changed");
    [self reloadSpecifiers];
    [self showMessage:@"已恢复默认" body:@"尺寸 2 × 2、封面背景开、其余功能关。"];
}

- (void)doRespring:(PSSpecifier *)sp {
    /* 与组件隐藏页同一通道: 只发 Darwin 通知, SpringBoard 自己 exit(0) 由 launchd 拉起。
       另外补一次 killall(有权限就当加速, 没有也无所谓)。 */
    notify_post("com.abgg332.driftisland.widget.respring");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        diwKillByComm("chronod");
        diwKillByComm("SpringBoard");
    });
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"正在注销"
        message:@"屏幕会短暂黑一下, 桌面回来后尺寸生效。" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (ac.presentingViewController) [ac dismissViewControllerAnimated:YES completion:nil];
    });
}

/* 播放器域的滑杆/开关(基类 switchSpec 写漂流岛域, 这里必须自建) */
- (PSSpecifier *)npSwitch:(NSString *)name key:(NSString *)key def:(BOOL)def {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSwitchCell edit:nil];
    [sp setProperty:key forKey:@"key"];
    [sp setProperty:kNPDomain forKey:@"defaults"];
    [sp setProperty:@(def) forKey:@"default"];
    return sp;
}

/* 3.0.44: 播放器域的滑杆 —— 基类的 setPreferenceValue 会把 range 值 round 成整数,
   律动强度 0.90 / 幅度 0.70 / 环粗 4.2 全会被吃掉, 所以这里自己写一遍(保留两位小数)。 */
- (PSSpecifier *)npSlider:(NSString *)label key:(NSString *)key
                      def:(double)def mn:(double)mn mx:(double)mx {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:label target:self
        set:@selector(npSetValue:specifier:) get:@selector(npReadValue:)
        detail:nil cell:PSSliderCell edit:nil];
    Class sc = diStepSliderClass();
    if (sc) [sp setProperty:[sc description] forKey:@"cellClass"];
    [sp setProperty:self forKey:@"diTarget"];
    [sp setProperty:label forKey:@"diLabel"];
    [sp setProperty:key forKey:@"key"];
    [sp setProperty:kDomain forKey:@"defaults"];
    [sp setProperty:@(def) forKey:@"default"];
    [sp setProperty:@(mn) forKey:@"min"];
    [sp setProperty:@(mx) forKey:@"max"];
    [sp setProperty:@{ @"min": @(mn), @"max": @(mx), @"label": label } forKey:@"range"];
    return sp;
}

- (id)npReadValue:(PSSpecifier *)sp {
    NSString *key = [sp propertyForKey:@"key"];
    if (!key.length) return [sp propertyForKey:@"default"];
    /* 3.0.66: 尺寸键(带 @)读不到时回落原键; 普通键行为不变 */
    id v = diFxReadSized(key);
    return v ?: [sp propertyForKey:@"default"];
}

- (void)npSetValue:(id)value specifier:(PSSpecifier *)sp {
    NSString *key = [sp propertyForKey:@"key"];
    if (!key.length) return;
    double v = [value doubleValue];
    NSDictionary *range = [sp propertyForKey:@"range"];
    if (range) {
        double mn = [range[@"min"] doubleValue], mx = [range[@"max"] doubleValue];
        if (v < mn) v = mn;
        if (v > mx) v = mx;
    }
    /* 3.0.56: 支持 0.1 这类步进(粒子大小); 没设步进就保持两位小数 */
    double step = 0.01;
    NSNumber *st = [sp propertyForKey:@"diStep"];
    if ([st isKindOfClass:NSNumber.class] && st.doubleValue > 0.0) step = st.doubleValue;
    double ov = diStepForKeyOverride(key);       /* 3.0.60: key 兜底, 不依赖 specifier */
    if (ov > 0.0) step = ov;
    v = round(v / step) * step;
    v = round(v * 1000.0) / 1000.0;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(v),
                             (__bridge CFStringRef)kDomain);
    /* 特效键不落盘同步(拖动时每秒几十次 fsync 会卡设置页), 由 cfprefsd 异步落盘 */
    if (diIsFxKey(key)) diPostFxTune();               /* 轻量: 只重读特效参数 */
    else notify_post("com.local.playerexact/artwork-changed");
}

- (PSSpecifier *)npRotateSwitch {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:@"专辑旋转" target:self
        set:@selector(writeRotateEnabled:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSwitchCell edit:nil];
    [sp setProperty:@"ArtworkRotationEnabled" forKey:@"key"];
    [sp setProperty:kNPDomain forKey:@"defaults"];
    [sp setProperty:@NO forKey:@"default"];
    return sp;
}

/* 3.0.6: 旋转/蒙版现在由 SpringBoard 侧实时应用, 改完立即生效, 不再弹「已保存」。
   用户统一用页面底部的「注销生效」。 */
- (void)writeRotateEnabled:(id)value specifier:(PSSpecifier *)spec {
    diNPWrite(@"ArtworkRotationEnabled", @([value boolValue]), kNPDomain);
    notify_post("com.local.playerexact/artwork-changed");
}

- (NSArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    /* 3.0.24: 分组「播放器入口」→「原生播放」, 开关「启用原生播放器」→「启用播放器」 */
    [specs addObject:[self groupSpec:@"原生播放" footer:nil]];
    PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:@"启用播放器" target:self
        set:@selector(writeNPEnabled:specifier:) get:@selector(readNPEnabled:)
        detail:nil cell:PSSwitchCell edit:nil];
    [specs addObject:sw];

    /* ---- 尺寸(原版 8 档, 同一键 Size) ---- */
    [specs addObject:[self groupSpec:@"播放器尺寸" footer:nil]];
    PSSpecifier *size = [PSSpecifier preferenceSpecifierNamed:@"播放器尺寸" target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:[DIPlayerSizePage class] cell:PSLinkListCell edit:nil];
    [size setProperty:@"Size" forKey:@"key"];
    [size setProperty:kNPDomain forKey:@"defaults"];
    [size setProperty:@"2x2" forKey:@"default"];
    [size setProperty:@[ @"2x2", @"2x3", @"3x2", @"3x2b", @"4x1", @"3x1", @"4x2", @"4x2b", @"4x3" ]
               forKey:@"validValues"];
    [size setProperty:@[ @"2 × 2", @"2 × 3", @"3 × 2", @"3 × 2（布局 B）",
                         @"4 × 1", @"3 × 1", @"4 × 2", @"4 × 2（布局 B）", @"4 × 3" ]
               forKey:@"validTitles"];
    [specs addObject:size];

    /* ---- 功能(原版 4 个开关) ---- */
    [specs addObject:[self groupSpec:@"功能" footer:nil]];
    [specs addObject:[self npSwitch:@"封面背景" key:@"MusicArtworkGradientEnabled" def:YES]];
    /* 3.1.0: 参考 CCUIPlayer 的 HideNotPlaying —— 打开后隐藏模块里的「未在播放」文字 */
    [specs addObject:[self npSwitch:@"隐藏未在" key:@"HideNotPlaying" def:NO]];
    /* 3.0.58: 「时间条上下移动」已按用户要求删除。 */
    [specs addObject:[self npRotateSwitch]];
    /* 3.0.24: 「禁止 N95 修改专辑图」删除(用不上); 「隐藏投送图标」改名「隐藏投送」。 */
    [specs addObject:[self npSwitch:@"隐藏投送" key:@"HideRoutingIcon" def:NO]];
    /* 3.0.41: 播放器遮罩 —— 按用户要求就地展开, 开关 + 素材直接排在这一页, 不再进二级页 */
    [specs addObject:[self switchSpec:@"启用遮罩" key:kDIPlayerMaskOnKey def:@NO]];
    [specs addObject:[self linkSpec:@"遮罩素材" detail:[DIPlayerMaskPicker class]]];
    /* 3.0.45: 律动特效 —— 设置全部收进一个入口页(用户要求) */
    // [excluded] 律动特效(用户明确不要音律特效)

    /* ---- 原版参数管理 ----
       3.0.66: 478 用户要求「原插件参数下的设置项暂时删除(但保留源码配置)」——
       UI 入口收起, importPlayerPreferences:/resetPlayerPreferences: 两个方法原样保留,
       以后要恢复把下面三行注释打开即可。 */
    /* [specs addObject:[self groupSpec:@"原插件参数" footer:nil]];
    [specs addObject:[self buttonSpec:@"导入原播放器参数" action:@selector(importPlayerPreferences:)]];
    [specs addObject:[self buttonSpec:@"恢复默认播放器参数" action:@selector(resetPlayerPreferences:)]]; */

    [specs addObject:[self groupSpec:nil footer:nil]];
    [specs addObject:[self buttonSpec:@"注销生效" action:@selector(doRespring:)]];
    return specs;
}
@end
@implementation DIPlayerSizePage

/* 与播放器入口页同一套注销通道 */
- (void)doRespring:(PSSpecifier *)sp {
    notify_post("com.abgg332.driftisland.widget.respring");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        diwKillByComm("chronod");
        diwKillByComm("SpringBoard");
    });
}

- (NSArray *)buildSpecifiers {
    diNPMigrateRetiredSizes();
    NSMutableArray *specs = [NSMutableArray array];
    [specs addObject:[self groupSpec:@"播放器尺寸" footer:nil]];

    NSArray<NSString *> *vals = @[ @"2x2", @"2x3", @"3x2", @"3x2b", @"4x1", @"3x1", @"4x2", @"4x2b", @"4x3" ];
    NSArray<NSString *> *titles = @[ @"2 × 2", @"2 × 3", @"3 × 2", @"3 × 2（布局 B）",
                                     @"4 × 1", @"3 × 1（窄岛）", @"4 × 2", @"4 × 2（布局 B）", @"4 × 3" ];
    NSString *cur = diNPCurrentSize();

    for (NSUInteger i = 0; i < vals.count && i < titles.count; i++) {
        BOOL on = [vals[i] isEqualToString:cur];
        NSString *name = on ? [@"✓ " stringByAppendingString:titles[i]] : titles[i];
        PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:name target:self
            set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
        [sp setProperty:vals[i] forKey:@"sizeValue"];
        [sp setButtonAction:@selector(pickSize:)];
        [specs addObject:sp];
    }
    return specs;
}

- (void)pickSize:(PSSpecifier *)sp {
    NSString *v = [sp propertyForKey:@"sizeValue"];
    if ([v isKindOfClass:NSString.class] && v.length) {
        diNPApplySize(v);
        notify_post("com.local.playerexact/artwork-changed");
    }
    /* 3.0.6: 选完直接回上一页, 不弹「已保存/需要注销」——
       用户自己用底部「注销生效」按钮, 不打断连选。 */
    [self.navigationController popViewControllerAnimated:YES];
}
@end
@implementation DIMaskPicker
- (NSString *)maskKey { return kDIAlbumMaskKey; }
- (NSString *)pickerTitle { return @"专辑遮罩素材"; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self pickerTitle];
    /* 进页就保证目录存在, 方便用户直接往里面丢 png(不用先手动建目录) */
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL d = NO;
    if (![fm fileExistsAtPath:kDIMaskRoot isDirectory:&d] || !d) {
        [fm createDirectoryAtPath:kDIMaskRoot withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0777} error:NULL];
    }
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        NSArray<NSString *> *list = DIMaskListAssets();
        NSString *cur = readPrefString([self maskKey]);

        PSSpecifier *none = [PSSpecifier preferenceSpecifierNamed:@"不遮罩（关闭遮罩）"
                                                           target:self set:nil get:@selector(currentValueForSpecifier:)
                                                           detail:nil cell:PSListItemCell edit:nil];
        [none setProperty:@"__none__" forKey:@"diKey"];
        [none setProperty:[NSNumber numberWithBool:[cur isEqualToString:@"__none__"]] forKey:@"diChecked"];
        [specs addObject:none];

        if (!list.count) {
            PSSpecifier *empty = [PSSpecifier preferenceSpecifierNamed:@"（目录里还没有 png 素材）"
                                                                target:nil set:nil get:nil detail:nil
                                                                cell:PSListItemCell edit:nil];
            [empty setProperty:@"把 png 放进 /var/mobile/灵动岛/遮罩素材 即可, 无需重编译" forKey:@"footerText"];
            [specs addObject:empty];
        } else {
            NSString *eff = cur.length ? cur : list.firstObject;
            for (NSString *rel in list) {
                PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:rel
                                                                 target:self set:nil get:@selector(currentValueForSpecifier:)
                                                                 detail:nil cell:PSListItemCell edit:nil];
                [sp setProperty:rel forKey:@"diKey"];
                [sp setProperty:[NSNumber numberWithBool:[rel isEqualToString:eff]] forKey:@"diChecked"];
                [specs addObject:sp];
            }
        }
        _specifiers = specs;
    }
    return _specifiers;
}

- (id)currentValueForSpecifier:(PSSpecifier *)spec {
    return nil;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    PSSpecifier *sp = [self specifierAtIndexPath:ip];
    NSString *key = [sp propertyForKey:@"diKey"];
    if (key) {
        writePrefString(key, [self maskKey]);
        /* 让悬浮岛立刻刷新 */
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.abgg332.driftisland/prefsChanged"), NULL, NULL, YES);
        [tv deselectRowAtIndexPath:ip animated:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self reloadSpecifiers];
        });
    }
}

/* 选中项打勾 */
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    PSSpecifier *sp = [self specifierAtIndexPath:ip];
    BOOL on = [[sp propertyForKey:@"diChecked"] boolValue];
    cell.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return @"点选即生效（无需重启）";
}
@end
@implementation DIPlayerMaskPicker
- (NSString *)maskKey { return kDIPlayerMaskKey; }
- (NSString *)pickerTitle { return @"播放器遮罩素材"; }
@end
@interface DIMiniBaseController : PSListController
- (NSArray *)buildSpecifiers;
- (PSSpecifier *)groupSpec:(NSString *)header footer:(NSString *)footer;
- (PSSpecifier *)switchSpec:(NSString *)name key:(NSString *)key def:(id)def;
- (PSSpecifier *)numSlider:(NSString *)label key:(NSString *)key def:(int)def mn:(int)mn mx:(int)mx;
- (id)readPreferenceValue:(PSSpecifier *)spec;
- (PSSpecifier *)buttonSpec:(NSString *)name action:(SEL)sel;
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls;
@end
@interface DIMaskPicker : PSListController
- (NSString *)maskKey;       /* 读写的偏好键 */
- (NSString *)pickerTitle;   /* 页面标题 */
@end
@interface DIPlayerMaskPicker : DIMaskPicker @end
@implementation DIPlayerMaskPicker
- (NSString *)maskKey { return kDIPlayerMaskKey; }
- (NSString *)pickerTitle { return @"播放器遮罩素材"; }
@end
@interface DIPlayerEntryPage : DIMiniBaseController @end
/* 3.0.45: 律动特效页 —— 总开关/封面律动/环/粒子/参数/渐变色全在这一页 */
@interface DIFxPage : DIMiniBaseController
/* 3.0.57: 颜色行用系统取色盘; 这几个方法在 @implementation 内部前后互相调用, 先声明一遍 */
- (void)diPickFxColor:(PSSpecifier *)sp;
- (void)diOpenFxPickerKeyA:(NSString *)a keyB:(NSString *)b title:(NSString *)t;
@end
@interface DIPlayerSizePage : DIMiniBaseController @end
@interface DIFrameFoldersMask : DIFrameFolders @end /* 2.6.3: 遮罩素材选择(键 maskAnimFolder) */
@interface DIFrameFoldersMini : DIFrameFolders @end  /* 左侧(mini)帧率素材选择(键 smallAnimFolder) */
@interface DIFrameFoldersAudio : DIFrameFolders @end /* 右侧音频素材(键 miniAudioFolder) */
@interface DIPrefsController (ZoneLinkFwd)
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls;
- (void)diOpenPage:(PSSpecifier *)spec;
@end
@interface DIFxPage : PSListController @end
@implementation DIFxPage
@end
