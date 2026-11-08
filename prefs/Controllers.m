#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <PhotosUI/PhotosUI.h>
#import <spawn.h>
#include <dlfcn.h>

/* 2.2.25: 字体颜色相关页面统一背景 —— 之前色块页/预览卡/调色页各用各的灰白,
   视觉上"分裂"。现在统一: 页面 = 分组灰底, 卡片 = 白底圆角, 输入框 = 浅灰。 */
#define DI_PAGE_BG   [UIColor systemGroupedBackgroundColor]
#define DI_CARD_BG   [UIColor secondarySystemGroupedBackgroundColor]
#define DI_FIELD_BG  [UIColor tertiarySystemGroupedBackgroundColor]

static NSString *const kDomain = @"com.abgg332.driftisland";
/* 2.6.25: 设置页底部显示的版本号 */
static NSString *const DI_VERSION_STR = @"2.9.6";
/* 2.6.10: 专辑光晕遮罩 —— 与 Tweak 侧 DIAlbumMask.h 保持一致 */
static NSString *const kDIAlbumMaskKey = @"diAlbumMaskAsset";
static NSString *const kDIMaskRoot = @"/var/mobile/灵动岛/遮罩素材";
/* 2.7.0: 壁纸素材目录 —— png/jpg/mp4, 浅色深色各选一个 */
static NSString *const kDIWallpaperRoot = @"/var/mobile/灵动岛/壁纸素材";

/* 2.6.11: 通用字符串排序 —— 不用 sortedArrayUsingSelector:@selector(localizedCompare),
   它在部分系统上会对 __NSCFString 抛 unrecognized selector("点遮罩素材闪退"的根因)。 */
static NSArray<NSString *> *diSortStrs(NSArray *arr);

/* 偏好字符串读写 */
static NSString *readPrefString(NSString *key) {
    if (!key.length) return nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return [v isKindOfClass:NSString.class] ? (NSString *)v : nil;
}
__attribute__((unused)) static BOOL readPrefBool(NSString *key, BOOL def) {   /* 2.7.32 */
    if (!key.length) return def;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:NSString.class]) return [(NSString *)v boolValue];
    return def;
}
__attribute__((unused)) static NSInteger readPrefInt(NSString *key, NSInteger def) {   /* 2.8.0 */
    if (!key.length) return def;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v integerValue];
    if ([v isKindOfClass:NSString.class]) return [(NSString *)v integerValue];
    return def;
}
static void writePrefString(NSString *value, NSString *key) {
    if (!key.length) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)(value ?: @""),
                             (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
}
static NSString *const kNotifyStr = @"com.abgg332.driftisland.reload";
static NSString *const kMaterialDir = @"/var/mobile/灵动岛";
static NSString *const kFrameDir = @"/var/mobile/灵动岛/帧率素材";
static NSString *const kMaskDir = @"/var/mobile/灵动岛/遮罩素材"; // 2.6.4: 遮罩素材(图片)

/* 现场日志: 不受日志开关控制, 设置页崩溃时也要留痕(与 Tweak.mm 的 DI_STEP 同一格式) */
static void diStep(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void diStep(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kMaterialDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:NULL];
    NSString *path = [kMaterialDir stringByAppendingPathComponent:@"driftisland.log"];
    [fm setAttributes:@{NSFilePosixPermissions: @0666} ofItemAtPath:path error:NULL];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *out = [NSString stringWithFormat:@"[%@] [现场] %@\n", [df stringFromDate:[NSDate date]], line];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]; return; }
    [h seekToEndOfFile];
    [h writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

/* 2.2.50: 通用视频扫描(小岛/展开用主目录, 录屏用录屏目录) */
/* 2.7.1: 壁纸素材枚举 —— png / jpg / jpeg / mp4, 最多往下钻 3 层(和 Tweak 侧 diWallpaperList 一致) */
static NSArray<NSString *> *diWallpaperFilesIn(NSString *base, NSInteger maxDepth) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:base isDirectory:&isDir] || !isDir) return out;
    NSMutableArray<NSString *> *queue = [NSMutableArray arrayWithObject:@""];
    int guard = 0;
    while (queue.count && guard++ < 200) {
        NSString *rel = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSInteger depth = rel.length ? ([rel componentsSeparatedByString:@"/"].count) : 0;
        NSString *full = rel.length ? [base stringByAppendingPathComponent:rel] : base;
        for (NSString *name in diSortStrs([fm contentsOfDirectoryAtPath:full error:NULL])) {
            if (![name isKindOfClass:NSString.class] || [name hasPrefix:@"."]) continue;
            NSString *childRel = rel.length ? [rel stringByAppendingPathComponent:name] : name;
            NSString *childFull = [base stringByAppendingPathComponent:childRel];
            BOOL d = NO;
            if (![fm fileExistsAtPath:childFull isDirectory:&d]) continue;
            if (!d) {
                NSString *e = name.pathExtension.lowercaseString;
                if ([e isEqualToString:@"png"] || [e isEqualToString:@"jpg"] ||
                    [e isEqualToString:@"jpeg"] || [e isEqualToString:@"mp4"]) [out addObject:childRel];
            } else if (depth < 3) {
                [queue addObject:childRel];
            }
        }
    }
    return out;
}

static NSArray<NSString *> *diWallpaperFiles(void) { return diWallpaperFilesIn(kDIWallpaperRoot, 3); }

/* 2.7.32: 壁纸深浅合并成一套, 素材一律放总目录 /var/mobile/灵动岛/壁纸素材,
   扫描用 diWallpaperFiles()(含历史 浅色/ 深色/ 子目录里的老素材)。 */
static BOOL diWallpaperIsVideoName(NSString *n) {
    return [n.pathExtension.lowercaseString isEqualToString:@"mp4"];
}

static NSArray<NSString *> *videoFilesIn(NSString *dir) {
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL] ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *f in files) {
        NSString *ext = f.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [ext isEqualToString:@"m4v"])
            [out addObject:f];
    }
    /* 2.6.11: 不用 sortUsingSelector:localizedCompare: —— 对 __NSCFString 会抛
       unrecognized selector(点素材列表闪退的根因), 统一走 diSortStrs */
    return diSortStrs(out);
}
static NSArray<NSString *> *videoFiles(void) { return videoFilesIn(kMaterialDir); }

/* 2.6.11: 排序用 block 比较器 —— sortedArrayUsingSelector:@selector(localizedCompare)
   在部分系统上会对 __NSCFString 抛 unrecognized selector, 是"点遮罩素材闪退"的根因。
   定义放在所有使用者之前。 */
static NSArray<NSString *> *diSortStrs(NSArray *arr) {
    if (![arr isKindOfClass:NSArray.class]) return @[];
    return [arr sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        NSString *sa = [a isKindOfClass:NSString.class] ? (NSString *)a : @"";
        NSString *sb = [b isKindOfClass:NSString.class] ? (NSString *)b : @"";
        return [sa compare:sb options:NSCaseInsensitiveSearch | NSNumericSearch];
    }];
}

/* 2.6.10: 扫描遮罩素材目录, 返回相对路径("文件夹/子文件夹/文件名")
   2.6.13: 之前只递归一层, 用户把 png 放在两层文件夹里就选不到 → 改成通用递归(最多 4 层) */
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


/* matMode: 0=小岛素材 1=展开素材 */
static NSInteger indexForKey(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    if (v) return [v integerValue];
    if (![key isEqualToString:@"videoIndex"]) { /* 兼容旧版单素材键 */ }
    id legacy = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("videoIndex"), (__bridge CFStringRef)kDomain));
    NSInteger idx = legacy ? [legacy integerValue] : 0;
    NSInteger cnt = (NSInteger)videoFiles().count;
    if (cnt == 0) return -1;
    if (idx < 0 || idx >= cnt) return 0;
    return idx;
}

static void diOpenHomeBarPanelWindow(void);   /* 2.5.10 横条颜色面板 */
static void diOpenHomeBarPickWindow(void);    /* 2.5.12 横条配色预设面板 */
static void diCloseBarWindow(void);           /* 2.7.35: 前置声明(安全收掉横条颜色窗口) */
static void diPushPanel(UIViewController *panel, NSString *title, UIWindow **legacyWin);  /* 2.8.36: 前置声明 */
/* 2.8.93: 通知合并(尾部去抖) —— 拖滑杆时每秒几十次写盘+通知, SpringBoard 那边
   每条都跑一遍全量刷新, 主线程被堆满, 看门狗直接把 SpringBoard 干掉(表现为
   "一拖左右就进安全模式")。这里 0.15s 内只放行第一条, 后续合并成"停下来再发一次",
   保证松手后的最终值一定送达。 */
static void diPostReloadRaw(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kNotifyStr, NULL, NULL, YES);
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
/* 2.2.11: 颜色变更通知(取色页/面板共用) —— Tweak 收到后 0.5s 内实时重绘, 主页刷新渐变条 */
static void diColorChangedNotify(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.abgg332.driftisland.colorchanged"), NULL, NULL, YES);
}

/* ===== 2.2.21: 带左右 −/+ 按钮的数值滑杆(歌词岛同款手法) =====
   继承 PSSliderCell, 保留系统滑块与数值显示; 左右各叠一个可点按钮,
   点一下 = 滑块值 ±1 步, 立即写偏好并 reload(实时生效)。 */
/* ===== 2.2.21: 带左右 −/+ 的数值滑杆(歌词岛同款) =====
   Preferences 头文件里 PSSliderCell 不完整, 用运行时动态子类,
   只重写 layoutSubviews + 加两个按钮, 其余完全走系统实现。 */

static void diStepSliderSyncLabel(UITableViewCell *cell);
static void diStepSliderApply(UITableViewCell *cell, double d);
static void diStepSliderDrag(UITableViewCell *cell);

/* 2.2.44: 控件直接挂在 cell 上(回到 2.2.39 的稳定做法), 不再有 diStepBox 中间层。
   之前 2.2.43 引入的自建 box + 跨对象 target 就是"点一下就闪退"的根源:
   UILabel 上加 tap 手势却把 target 设成 cell, 而方法只装在 PSSliderCell 上,
   UILabel 不是那个类 → unrecognized selector, 直接崩。 */
static inline UISlider *diStepBoxSlider(UITableViewCell *cell) {
    return objc_getAssociatedObject(cell, "di_step_slider");
}
static inline id diStepBoxValue(UITableViewCell *cell) {
    return objc_getAssociatedObject(cell, "di_step_val");   /* 可能是 UIButton 也可能是 UILabel */
}

/* 2.2.36: 直接注入参数(帧率组不走 PSSpecifier 的 key/defaults, 由行号自绘) */
static void diStepSeedCache(UITableViewCell *cell, NSString *key, NSString *domain,
                            NSNumber *mn, NSNumber *mx, NSNumber *def, NSString *label);

/* ===== 2.2.35 关键: 不再依赖 [cell specifier] =====

   点 ± 闪退的根因: 我们一直靠 `[cell specifier]` 拿 key/domain,
   但 PSSliderCell 上这个方法在不同 iOS 上行为不一致(有的是别的返回类型),
   通过 objc_msgSend 强转成 PSSpecifier* 就可能拿到脏指针 → 一取属性就崩。
   即使套 @try 也没用, 因为那是野指针访问(EXC_BAD_ACCESS), 不是 ObjC 异常。

   新方案: 布局时把 key/domain/min/max/default 直接存到 cell 上(关联对象),
   ± 按钮只读这些存好的值, 一个 objc_msgSend 都不打 → 不可能崩。 */

/* 把 specifier 的关键信息缓存到 cell 上(布局时调用一次) */
static void diStepCacheSpec(UITableViewCell *cell) {
    if (!cell) return;
    if (objc_getAssociatedObject(cell, "di_k_key")) return;   /* 已缓存 */
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
        objc_setAssociatedObject(cell, "di_k_key", k, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, "di_k_dom", d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, "di_k_min", [sp propertyForKey:@"min"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, "di_k_max", [sp propertyForKey:@"max"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, "di_k_def", [sp propertyForKey:@"default"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, "di_k_name", [sp name], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, "di_k_step", [sp propertyForKey:@"diStep"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (__unused NSException *e) {}
}

/* 2.2.36: 外部直接灌参数(帧率组用)。写完后 diStepCacheSpec 会因为 di_k_key 已存在而早退,
   正好保证不被 [cell specifier] 覆盖。 */
__attribute__((unused))
static void diStepSeedCache(UITableViewCell *cell, NSString *key, NSString *domain,
                            NSNumber *mn, NSNumber *mx, NSNumber *def, NSString *label) {
    if (!cell || !key.length || !domain.length) return;
    objc_setAssociatedObject(cell, "di_k_key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, "di_k_dom", domain, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, "di_k_min", mn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, "di_k_max", mx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, "di_k_def", def, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, "di_k_name", label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, "di_k_step", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/* 从缓存读当前值 */
static double diStepReadValue(UITableViewCell *cell) {
    NSString *k = objc_getAssociatedObject(cell, "di_k_key");
    NSString *d = objc_getAssociatedObject(cell, "di_k_dom");
    NSNumber *def = objc_getAssociatedObject(cell, "di_k_def");
    if (!k.length || !d.length) return 0;
    CFPreferencesAppSynchronize((__bridge CFStringRef)d);
    id cur = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)k, (__bridge CFStringRef)d));
    if (cur) return [cur doubleValue];
    return def ? [def doubleValue] : 0;
}

/* 写值 + 限位, 返回最终值 */
static double diStepWriteValue(UITableViewCell *cell, double v) {
    NSString *k = objc_getAssociatedObject(cell, "di_k_key");
    NSString *d = objc_getAssociatedObject(cell, "di_k_dom");
    NSNumber *mn = objc_getAssociatedObject(cell, "di_k_min");
    NSNumber *mx = objc_getAssociatedObject(cell, "di_k_max");
    if (!k.length || !d.length) return v;
    v = round(v);
    if (mn && v < [mn doubleValue]) v = [mn doubleValue];
    if (mx && v > [mx doubleValue]) v = [mx doubleValue];
    CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)@(v),
                             (__bridge CFStringRef)d);
    CFPreferencesAppSynchronize((__bridge CFStringRef)d);
    return v;
}

/* 拖动滑杆: 写偏好 + 刷新数字

   2.2.39 修闪退: 拖动时 ValueChanged 每秒触发几十次, 每次都
   CFPreferencesSetAppValue + CFPreferencesAppSynchronize + postReload(达尔文通知)。
   Preferences 进程和 SpringBoard 会同时抢同一个偏好域 → 写盘互锁, 拖快就崩。
   改法:
     · 拖动过程只更新界面数字, 不写盘
     · 松手(TouchUpInside/Outside)才写入一次, 并只发一次通知
     · 用 CA 事务关掉隐式动画, 避免拖动时布局抖动 */

static void diStepSliderCommit(UITableViewCell *cell) {
    if (!cell) return;
    @try {
        UISlider *slider = diStepBoxSlider(cell);
        if (!slider) return;
        NSNumber *last = objc_getAssociatedObject(cell, "di_drag_last");
        double v = last ? last.doubleValue : round(slider.value);
        diStepWriteValue(cell, v);
        postReload();
        diStepSliderSyncLabel(cell);
    } @catch (__unused NSException *e) {}
}

static void diStepSliderDrag(UITableViewCell *cell) {
    if (!cell) return;
    @try {
        UISlider *slider = diStepBoxSlider(cell);
        if (!slider) return;
        /* 只在界面层显示, 不写盘 —— 松手时由 diStepSliderCommit 落盘 */
        double v = round(slider.value);
        objc_setAssociatedObject(cell, "di_drag_last", @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id val = diStepBoxValue(cell);
        NSString *t = [NSString stringWithFormat:@"%.0f", v];
        if ([val isKindOfClass:[UIButton class]]) {
            [(UIButton *)val setTitle:t forState:UIControlStateNormal];
        } else if ([val isKindOfClass:[UILabel class]]) {
            [(UILabel *)val setText:t];
        }
    } @catch (__unused NSException *e) {}
}
static void diStepSliderLayout(UITableViewCell *cell) {
    UIView *cv = cell.contentView;
    CGFloat H = cv.bounds.size.height, W = cv.bounds.size.width;
    if (W < 100 || H < 20) return;

    diStepCacheSpec(cell);
    if (![objc_getAssociatedObject(cell, "di_k_step") boolValue]) return;

    /* ===== 2.2.44 锁屏通知组: 按真截图逐像素量的「四段并列」 =====

       之前 2.2.39/2.2.40 布局不对, 2.2.43 更是理解错了结构(以为"整行长杠 + 标题压在杠上"),
       结果界面变成一团。这次直接从用户截图(1226px 宽)扫蓝色像素, 拿到真实坐标:

         左侧短蓝条   78 → 242      0.064 ~ 0.197   ← 独立的装饰短条, 不是轨道
         标题「宽度」 250 → 460      0.204 ~ 0.375
         滑杆轨道    471 → 890      0.384 ~ 0.726
         + 号        976 → 1003     0.796 ~ 0.818
         数值        1092 → 1137    0.891 ~ 0.927

       换算成 405pt 宽 contentView(除以 3.027):
         短条   x=26  w=54
         标题   x=83  w=69
         轨道   x=156 w=139
         +      x=322 w=30
         数值   x=361 w=52

       四段彼此不重叠、不压盖, 所以不需要 box、不需要白底遮断、不需要层级调整。
       这也回到了 2.2.39 那套"直接在 cell 上摆控件"的稳定做法 ——
       cell 上摆的控件归属明确, 拖动时不涉及任何跨对象调用, 不会崩。 */

    /* 2.2.46: 废弃上一版的逐像素坐标(四段并列), 改回两行结构。
       下面这几个常量只给控件尺寸用, 横向位置全部在摆位处按 W 现算。 */
    CGFloat btnW    = 30.0;
    CGFloat valW    = 52.0;

    UILabel *title  = objc_getAssociatedObject(cell, "di_step_title");
    UIButton *minus = objc_getAssociatedObject(cell, "di_step_minus");
    UIButton *plus  = objc_getAssociatedObject(cell, "di_step_plus");
    UIButton *val   = objc_getAssociatedObject(cell, "di_step_val");
    UIView *bar     = objc_getAssociatedObject(cell, "di_step_bar");
    UISlider *slider = objc_getAssociatedObject(cell, "di_step_slider");

    if (!minus) {
        /* ---- 左侧装饰短蓝条(截图最左那段独立蓝线) ---- */
        bar = [[UIView alloc] initWithFrame:CGRectZero];
        bar.backgroundColor = [UIColor systemBlueColor];
        bar.layer.cornerRadius = 2.0;
        bar.userInteractionEnabled = NO;
        [cv addSubview:bar];
        objc_setAssociatedObject(cell, "di_step_bar", bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        /* ---- 标题: 左对齐, 字号 17 加粗(截图里字重明显偏重) ---- */
        title = [[UILabel alloc] init];
        title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        if (@available(iOS 13.0, *)) title.textColor = [UIColor labelColor];
        title.numberOfLines = 1;
        title.textAlignment = NSTextAlignmentLeft;
        title.adjustsFontSizeToFitWidth = YES;
        title.minimumScaleFactor = 0.7;
        [cv addSubview:title];
        objc_setAssociatedObject(cell, "di_step_title", title, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        /* ---- − (截图无, 保留但隐藏) ---- */
        minus = [UIButton buttonWithType:UIButtonTypeSystem];
        [minus setTitle:@"−" forState:UIControlStateNormal];
        [minus setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        minus.titleLabel.font = [UIFont boldSystemFontOfSize:22];
        [minus addTarget:cell action:NSSelectorFromString(@"diStepDown") forControlEvents:UIControlEventTouchUpInside];
        minus.hidden = YES;
        [cv addSubview:minus];
        objc_setAssociatedObject(cell, "di_step_minus", minus, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        /* ---- + ---- */
        plus = [UIButton buttonWithType:UIButtonTypeSystem];
        [plus setTitle:@"+" forState:UIControlStateNormal];
        [plus setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        plus.titleLabel.font = [UIFont boldSystemFontOfSize:24];
        [plus addTarget:cell action:NSSelectorFromString(@"diStepUp") forControlEvents:UIControlEventTouchUpInside];
        [cv addSubview:plus];
        objc_setAssociatedObject(cell, "di_step_plus", plus, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        /* ---- 数值: 蓝色、右对齐、可点输入 ---- */
        val = [UIButton buttonWithType:UIButtonTypeSystem];
        val.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightSemibold];
        val.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
        [val setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        [val addTarget:cell action:NSSelectorFromString(@"diStepEdit") forControlEvents:UIControlEventTouchUpInside];
        [cv addSubview:val];
        objc_setAssociatedObject(cell, "di_step_val", val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    /* ---- 滑杆: 接管 cell 里那个原生 UISlider, 没有就自己造 ---- */
    if (!slider) {
        for (UIView *v in cv.subviews) {
            if ([v isKindOfClass:[UISlider class]]) { slider = (UISlider *)v; break; }
        }
        if (!slider) {
            slider = [[UISlider alloc] init];
            [cv addSubview:slider];
        }
        slider.minimumTrackTintColor = [UIColor systemBlueColor];
        NSNumber *mnN = objc_getAssociatedObject(cell, "di_k_min");
        NSNumber *mxN = objc_getAssociatedObject(cell, "di_k_max");
        slider.minimumValue = mnN ? mnN.floatValue : 0;
        slider.maximumValue = mxN ? mxN.floatValue : 100;
        slider.value = (float)diStepReadValue(cell);
        [slider addTarget:cell action:NSSelectorFromString(@"diStepSliderChanged")
            forControlEvents:UIControlEventValueChanged];
        [slider addTarget:cell action:NSSelectorFromString(@"diStepSliderCommit")
            forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        objc_setAssociatedObject(cell, "di_step_slider", slider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    slider.hidden = NO;
    /* 系统原滑杆可能还压在我们上面, 全部藏掉(包括 cell 层) */
    for (UIView *v in cell.subviews)
        if ([v isKindOfClass:[UISlider class]] && v != slider) v.hidden = YES;

    /* ---- 摆位 2.2.46: 回到最早那版「标题一行 + 滑杆一行」的两行结构 ----
       前几版一直想把标题和滑杆挤在同一行(四段并列), 但标题文字宽度不可控,
       一旦标签变长就直接压到滑杆轨道上 —— 用户截图里"宽度"两个字糊在蓝条上就是这个原因。
       两行结构天生不重叠, 也最贴近 iOS 原生 PSSliderCell 的排法, 最稳。

         第一行(上): 标题 左对齐                +  数值 右对齐
         第二行(下): 滑杆 从左边铺到 + 前面为止

       左侧那条短蓝条(装饰)去掉 —— 截图里它其实是滑杆轨道的填充部分, 不是独立装饰。 */
    CGFloat padX   = 16.0;
    CGFloat rowH   = 22.0;                 /* 每行高度 */
    CGFloat topY   = (H - rowH * 2) / 2.0; /* 两行整体垂直居中 */
    if (topY < 2) topY = 2;

    if (bar) { bar.hidden = YES; }         /* 装饰短条不再需要 */
    title.frame  = CGRectMake(padX, topY, W - padX * 2 - btnW - valW - 8, rowH);
    plus.frame   = CGRectMake(W - padX - valW - btnW, topY, btnW, rowH);
    val.frame    = CGRectMake(W - padX - valW, topY, valW, rowH);
    slider.frame = CGRectMake(padX, topY + rowH, W - padX - (btnW + 6.0) - padX, rowH);

    if (title) {
        NSString *name = objc_getAssociatedObject(cell, "di_k_name");
        if (name.length) title.text = name;
    }

    diStepSliderSyncLabel(cell);
}

/* 数值 ±1 步: 写偏好 + 通知刷新
   2.2.33 修闪退: 
     1) 原来 setValue: 用 float 传参 —— PSSliderCell 声明是 -(void)setValue:(double),
        ARM64 上浮点实参走 d0, 按 float 传会让 d0 高 32 位是脏值, 滑块拿到天文数字/NaN
        → 内部 [slider setValue:] 断言崩。改成 double。
     2) [cell specifier] 在 cell 已出队/复用后可能返回 nil → 全部判空。
     3) diTarget 用弱引用校验, 对象没了就不发消息。
     4) 整个函数包 @try, 偏好已写成功就不因为界面刷新失败而崩。 */
static void diStepSliderApply(UITableViewCell *cell, double d) {
    if (!cell) return;
    diStepCacheSpec(cell);                    /* 首次调用补缓存 */
    NSString *key = objc_getAssociatedObject(cell, "di_k_key");
    if (!key.length) return;
    double v = [@(diStepReadValue(cell) + d) doubleValue];
    v = diStepWriteValue(cell, v);
    NSString *nm = objc_getAssociatedObject(cell, "di_k_name") ?: key;
    diStep(@"滑杆[%@]: %@ → %.0f", nm, d > 0 ? @"+" : @"−", v);
    postReload();
    /* 同步滑块位置(只碰我们自己的 UISlider, 不打 setValue:) */
    UISlider *sl = diStepBoxSlider(cell);
    if (sl) sl.value = (float)v;
    diStepSliderSyncLabel(cell);
}

/* 把当前值写到右侧数字按钮上(只用缓存, 不碰 specifier) */
static void diStepSliderSyncLabel(UITableViewCell *cell) {
    if (!cell) return;
    id val = diStepBoxValue(cell);
    if (!val) return;
    NSString *key = objc_getAssociatedObject(cell, "di_k_key");
    if (!key.length) return;
    double v = diStepReadValue(cell);
    NSString *t = [NSString stringWithFormat:@"%.0f", round(v)];
    /* 2.2.44: 兼容两种载体 —— UIButton 用 setTitle, UILabel 用 text。
       之前无脑 cast 成 UILabel 再点 .text, 对象其实是 UIButton → 崩。 */
    if ([val isKindOfClass:[UIButton class]]) {
        [(UIButton *)val setTitle:t forState:UIControlStateNormal];
    } else if ([val isKindOfClass:[UILabel class]]) {
        [(UILabel *)val setText:t];
    }
}

/* 点数字 → 输入框(2.2.35: 全部改用缓存, 不打 specifier, 不崩) */
static void diStepSliderEdit(UITableViewCell *cell) {
    if (!cell) return;
    diStepCacheSpec(cell);
    NSString *key = objc_getAssociatedObject(cell, "di_k_key");
    if (!key.length) return;
    double v = diStepReadValue(cell);
    NSString *nm = objc_getAssociatedObject(cell, "di_k_name") ?: key;
    NSNumber *mn = objc_getAssociatedObject(cell, "di_k_min");
    NSNumber *mx = objc_getAssociatedObject(cell, "di_k_max");

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nm
                                                              message:@"输入数值"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = [NSString stringWithFormat:@"%.0f", round(v)];
        tf.textAlignment = NSTextAlignmentCenter;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        /* 弹窗关闭时 cell 可能已被复用 → 用 weak 校验 */
        UITableViewCell *c = cell;
        if (!c) return;
        double nv = [ac.textFields.firstObject.text doubleValue];
        nv = diStepWriteValue(c, nv);
        diStep(@"滑杆[%@]: 输入 %.0f", nm, nv);
        postReload();
        UISlider *sl = diStepBoxSlider(c);
        if (sl) sl.value = (float)nv;
        diStepSliderSyncLabel(c);
    }]];
    (void)mn; (void)mx;

    /* 找宿主 VC: 沿响应链上溯 */
    UIViewController *vc = nil;
    for (UIResponder *r = cell.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) { vc = (UIViewController *)r; break; }
    }
    if (!vc) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) { vc = w.rootViewController; break; }
            }
            if (vc) break;
        }
    }
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (vc) [vc presentViewController:ac animated:YES completion:nil];
}


/* ===== 2.2.30 滑杆布局: 直接装进 PSSliderCell 本身 =====

   上一版用 objc_allocateClassPair 造子类 + specifier.cellClass 指定,
   但 Preferences 对 cellClass 只认已注册的类名, 动态注册的类经常被忽略,
   于是 layoutSubviews 里的排版根本没跑 —— 这就是"横杠还是那么长"的原因。
   现在改成: 直接给 PSSliderCell 装方法(hook), 全设置页的滑杆行统一生效。 */

__attribute__((unused)) static char kDiStepInited;

/* 原 layoutSubviews 备份(按类存) */
static NSMutableDictionary<NSString *, NSValue *> *diOrigLayoutIMPs(void) {
    static NSMutableDictionary *d;
    if (!d) d = [NSMutableDictionary dictionary];
    return d;
}
static void diStepSliderLayoutHook(id slf);

/* 2.2.32: 用交换 + 转发的方式 hook, 并对所有当前已加载的 PSSliderCell 子类都装一遍。
   之前只装了 PSSliderCell 本体, 而 iOS 16 设置里实际用的是 PSSliderCell 的子类
   (如 PSControlTableCell/PSSliderTableCell 之类), 子类自己实现了 layoutSubviews
   就会把父类的 hook 完全绕过 → 排版一次都没跑过。 */
/* 2.2.34: 完全接管布局 —— 不再调用 PSSliderCell 的原 layoutSubviews。
   之前"每次先调原实现再改"是错的: 原实现会把 UISlider 摆成"标题下方、整行满宽",
   我们再改, 导致 track 视觉上仍是长横杠, 且我们的按钮被压在它上面重叠。
   现在只做一件事: 把我们自己的布局跑一遍(标题/滑块/±/数字 全部自己摆)。 */
__attribute__((unused))
static void diHookSliderClass(Class c) {
    if (!c) return;
    NSString *name = NSStringFromClass(c);
    if (diOrigLayoutIMPs()[name]) return;            /* 已装 */
    Method m = class_getInstanceMethod(c, @selector(layoutSubviews));
    if (!m) return;
    IMP orig = method_getImplementation(m);
    if (orig == (IMP)diStepSliderLayoutHook) return; /* 已经是我们的转发器 */
    diOrigLayoutIMPs()[name] = [NSValue valueWithPointer:(void *)orig];

    IMP origIMP = orig;
    IMP fwd = imp_implementationWithBlock(^(id slf) {
        /* 2.2.44: 先建缓存, 否则 layoutSubviews 早于 willDisplayCell 时
           di_k_step 还是 nil, 会误判成"不是我的行"而整段跳过。 */
        @try { diStepCacheSpec((UITableViewCell *)slf); } @catch (__unused NSException *e) {}

        BOOL mine = [objc_getAssociatedObject(slf, "di_k_step") boolValue];
        if (mine) {
            /* 锁屏通知组: 由我们全权接管(系统原布局会把滑杆铺满整行) */
            diStepSliderLayoutHook(slf);
        } else {
            /* 其它行(帧率组等): 原样跑系统实现。
               直接调捕获下来的 origIMP, 不再查字典 —— 避免拿到别的类的 IMP 造成递归。 */
            if (origIMP) ((void (*)(id, SEL))origIMP)(slf, @selector(layoutSubviews));
        }
    });
    method_setImplementation(m, fwd);
}

static void diStepSliderLayoutHook(id slf) {
    /* 2.2.43: 这个 hook 只为"锁屏通知组"服务。其它滑动行(包括帧率组)
       一律不动它们的分支 —— 帧率组有自己的 diBox 自绘, 绝不能在这里被接管。 */
    @try {
        UITableViewCell *cell = (UITableViewCell *)slf;
        diStepCacheSpec(cell);
        BOOL mine = [objc_getAssociatedObject(cell, "di_k_step") boolValue];
        if (!mine) return;                 /* 不是锁屏组: 直接放行, 什么都不做 */
        diStepSliderLayout(cell);
    } @catch (__unused NSException *e) {}
}

static void diInstallStepSliderOnPSSliderCell(void) {
    Class base = NSClassFromString(@"PSSliderCell");
    if (!base) return;

    /* 动作方法(可重复调用, 已存在就跳过) */
    if (!class_getInstanceMethod(base, NSSelectorFromString(@"diStepDown"))) {
        class_addMethod(base, NSSelectorFromString(@"diStepDown"),
            imp_implementationWithBlock(^(id slf) { diStepSliderApply(slf, -1); }), "v@:");
        class_addMethod(base, NSSelectorFromString(@"diStepUp"),
            imp_implementationWithBlock(^(id slf) { diStepSliderApply(slf, 1); }), "v@:");
        class_addMethod(base, NSSelectorFromString(@"diStepEdit"),
            imp_implementationWithBlock(^(id slf) { diStepSliderEdit(slf); }), "v@:");
        /* 2.2.34: 拖动滑杆 → 立即写偏好 + 刷新右侧数字 */
        class_addMethod(base, NSSelectorFromString(@"diStepSliderChanged"),
            imp_implementationWithBlock(^(id slf) { diStepSliderDrag(slf); }), "v@:");
        class_addMethod(base, NSSelectorFromString(@"diStepSliderCommit"),
            imp_implementationWithBlock(^(id slf) { diStepSliderCommit(slf); }), "v@:");
    }

    /* 2.2.45: 不再全局替换 layoutSubviews！
       入口闪退的根源排查: 入口阶段唯一的全局高危操作就是这里对所有 PSSliderCell
       子类做 method_setImplementation —— Preferences 进程里任何别的滑杆行
       (包括其它插件的)都会跑到我们的转发 block。
       而它本来就是多余的: willDisplayCell 已经在每次上屏时调 diStepSliderLayout
       并 0/0.2/0.6s 补排三次, 排版从不依赖这个 hook。
       现在只保留 class_addMethod 给按钮 target 用的动作方法, 不动任何系统方法。 */
    (void)base;
}

/* 兼容旧调用点: 确保已安装, 返回 PSSliderCell */
static Class diStepSliderClass(void) {
    diInstallStepSliderOnPSSliderCell();
    return NSClassFromString(@"PSSliderCell");
}

@interface DIMaterialsController : PSListController
- (NSInteger)matMode; /* 0=小岛 1=展开 */
@end

@interface DIMaterialsSmall : DIMaterialsController @end
@interface DIMaterialsExpand : DIMaterialsController @end
@interface DIFrameFolders : PSListController @end

@interface DIPrefsController : PSListController {
    NSInteger _smallRow; /* 小岛素材选择 行号 */
    NSInteger _expandRow; /* 展开素材选择 行号 */
}
- (void)toast:(NSString *)msg;
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
/* 2.6.28: 锁屏设置页 —— 完全照歌词岛的做法(DIMiniBaseController + linkSpec),
   这是唯一一个从来没闪退过的二级页形态 */
@interface DILockScreenPage : DIMiniBaseController @end
/* 2.6.29: 文字颜色页(原"文字样式"组的内容, 整体搬进来, 键值零改动) */
@interface DITextStylePage : DIMiniBaseController @end
/* 2.8.12: 歌词岛合并页回归(2.8.4/2.8.5 下架后恢复) ——
   上半=左侧专辑帧率, 下半=右侧音频帧率, 下面=专辑遮罩设置(2.2.24 原版形态) */
@interface DILyricsIslandSettings : DIMiniBaseController @end
/* 2.8.41: 控制中心页回归(单素材=浅色键 wpLightAsset, 无深浅色分组) */
@interface DICCSettings : DIMiniBaseController @end
/* 2.8.87: 展开定义 —— 遮罩素材下面的二级页(位置/大小/颜色) */
@interface DIExpandDefinePage : DIMiniBaseController @end
/* 2.9.5: 专辑律动(粒子 + 鼓点震动)
   2.9.6: 颜色改成系统取色器(一行入口), 不再摆一排色块 + 三条滑杆 */
@interface DIRhythmPage : DIMiniBaseController <UIColorPickerViewControllerDelegate>
@end
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

@implementation DIPrefsController

/* 2.7.20: +load 保持极简, 只写一行日志 —— 与 2.7.13 一致(那版无 +load) */
+ (void)load {
    diStep(@"漂流岛设置 2.7.20 bundle 已加载, DIPrefsController 已注册");
}

- (instancetype)init {
    if ((self = [super init])) {
        diStep(@"DIPrefsController init 成功 (2.7.22)");   /* 确认入口页真的创建出来了 */
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self,
            diPrefsReloadCB, (__bridge CFStringRef)kNotifyStr, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        /* 2.2.8: 取色页改了颜色 → 回主页面时刷新渐变预览条 */
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self,
            diPrefsReloadCB, CFSTR("com.abgg332.driftisland.colorchanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    return self;
}
- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self);
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key) return nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return v ?: [spec propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key.length) return;
    NSDictionary *range = [spec propertyForKey:@"range"];
    if (range) { // 数值键: 取整+clamp
        double v = [value doubleValue];
        double mn = [range[@"min"] doubleValue], mx = [range[@"max"] doubleValue];
        if (v < mn) v = mn; if (v > mx) v = mx;
        value = @(round(v));
    }
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
    /* 开关切换: 立即增删下方参数行 */
    if ([key isEqualToString:@"spectrumOn"] || [key isEqualToString:@"materialOn"]
        || [key isEqualToString:@"notifyFlowOn"] || [key isEqualToString:@"notifyColorOn"]
        || [key isEqualToString:@"notifyBgOff"] || [key isEqualToString:@"lockWOn"] || [key isEqualToString:@"homeBarOn"]
        || [key isEqualToString:@"homeBarHideOn"] || [key isEqualToString:@"homeBarMode"]) {
        _specifiers = nil;
        [self reloadSpecifiers];
    } else if ([key isEqualToString:@"diNotifColors"] || [key isEqualToString:@"notifyColorHex"]) {
        [self scheduleSync]; // 2.2.11: 颜色改动后刷新主页渐变预览条
    } else if (range) {
        [self scheduleSync]; // 数值改动: 稍后刷新标题里的数字
    }
}

/* 2.5.6: 底栏横条颜色模式 —— 单色 / 多色渐变 / 流光 */
- (NSString *)homeBarModeValue {
    NSString *m = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("homeBarMode"),
                                                                    (__bridge CFStringRef)kDomain);
    if (![m isKindOfClass:[NSString class]] || !m.length) return @"single";
    return m;
}
- (NSString *)homeBarModeTitle {
    NSString *m = [self homeBarModeValue];
    if ([m isEqualToString:@"gradient"]) return @"颜色模式: 多色渐变";
    if ([m isEqualToString:@"flow"]) return @"颜色模式: 流光";
    return @"颜色模式: 单色";
}
/* 2.5.7: 隐藏模式 —— 完全隐藏 / 渐变隐藏 */
- (NSString *)homeBarHideModeValue {
    NSString *m = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("homeBarHideMode"),
                                                                   (__bridge CFStringRef)kDomain);
    if (![m isKindOfClass:[NSString class]] || !m.length) return @"full";
    return m;
}
/* 2.5.26: 流光方向选择 —— 0 左→右 / 1 右→左 / 2 中间向两边散开 / 3 两边向中间收紧 */
- (void)diPickHomeBarFlowDir:(PSSpecifier *)spec {
    NSInteger cur = [(__bridge NSNumber *)CFPreferencesCopyAppValue(CFSTR("homeBarFlowDir"), (__bridge CFStringRef)kDomain) integerValue];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"流光方向"
        message:@"横条流光颜色的流动方式(需先开启流光动态)" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *names = @[@"左→右", @"右→左", @"中间向两边散开", @"两边向中间收紧"];
    for (NSUInteger i = 0; i < names.count; i++) {
        UIAlertAction *act = [UIAlertAction actionWithTitle:[names[i] stringByAppendingString:
            (i == (NSUInteger)cur ? @" ✓" : @"")]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            CFPreferencesSetAppValue(CFSTR("homeBarFlowDir"), (__bridge CFPropertyListRef)(@((NSInteger)i)), (__bridge CFStringRef)kDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            postReload();
            _specifiers = nil; [self reloadSpecifiers];
            [self toast:[NSString stringWithFormat:@"流光方向: %@", names[i]]];
        }];
        [a addAction:act];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (NSString *)homeBarHideModeTitle {
    return [[self homeBarHideModeValue] isEqualToString:@"fade"] ? @"渐变隐藏" : @"完全隐藏";
}
- (void)diPickHomeBarHideMode:(PSSpecifier *)spec {
    NSString *cur = [self homeBarHideModeValue];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"隐藏模式"
        message:@"完全隐藏=横条彻底不可见; 渐变隐藏=横条周期性渐隐渐显(隐约可见)"
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *modes = @[@"full", @"fade"];
    NSArray *names = @[@"完全隐藏", @"渐变隐藏"];
    for (NSUInteger i = 0; i < modes.count; i++) {
        UIAlertAction *act = [UIAlertAction actionWithTitle:[names[i] stringByAppendingString:
            [modes[i] isEqualToString:cur] ? @" ✓" : @""]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            CFPreferencesSetAppValue(CFSTR("homeBarHideMode"), (__bridge CFPropertyListRef)modes[i],
                                     (__bridge CFStringRef)kDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            postReload();
            _specifiers = nil; [self reloadSpecifiers];
            [self toast:[NSString stringWithFormat:@"隐藏模式: %@", names[i]]];
        }];
        [a addAction:act];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)diPickHomeBarMode:(PSSpecifier *)spec {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"颜色模式"
        message:@"单色=纯色横条; 多色渐变=多种颜色横向渐变; 流光=渐变色带持续流动"
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *modes = @[@"single", @"gradient", @"flow"];
    NSArray *names = @[@"单色", @"多色渐变", @"流光"];
    for (NSUInteger i = 0; i < modes.count; i++) {
        [a addAction:[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *x) {
            CFPreferencesSetAppValue(CFSTR("homeBarMode"), (__bridge CFPropertyListRef)modes[i],
                                     (__bridge CFStringRef)kDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            postReload();
            _specifiers = nil; [self reloadSpecifiers];
            [self toast:[NSString stringWithFormat:@"颜色模式: %@", names[i]]];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

/* 2.5.6: 多色 —— 逗号分隔的 HEX 列表, 最多 8 色 */
- (void)diPickHomeBarColors:(PSSpecifier *)spec {
    NSString *cur = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("homeBarHexes"),
                                                                     (__bridge CFStringRef)kDomain);
    if (!cur.length) {
        cur = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("homeBarHex"),
                                                                 (__bridge CFStringRef)kDomain);
    }
    NSArray *presets = @[
        @[@"彩虹", @"FF3B30,FF9500,FFCC00,34C759,32ADE6,AF52DE"],
        @[@"蓝紫", @"32ADE6,007AFF,AF52DE"],
        @[@"橙红", @"FFCC00,FF9500,FF3B30"],
        @[@"青绿", @"32ADE6,34C759"],
        @[@"粉紫", @"FF2D55,AF52DE"],
        @[@"金白", @"FFFFFF,FFCC00"],
    ];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"横条颜色(多色)"
        message:@"用英文逗号分隔多个 6 位 HEX，最多 8 色\n例如: FF3B30,FF9500,FFCC00,34C759"
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray *pr in presets) {
        [a addAction:[UIAlertAction actionWithTitle:pr[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [self saveHomeBarHexes:pr[1]];
        }]];
    }
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"FF3B30,FF9500,FFCC00";
        tf.text = cur.length ? cur : @"";
        tf.keyboardType = UIKeyboardTypeASCIICapable;
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"确定自定义" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *txt = a.textFields.firstObject.text ?: @"";
        NSMutableArray *ok = [NSMutableArray array];
        NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFabcdef"];
        for (NSString *h in [txt componentsSeparatedByString:@","]) {
            NSString *s = [[h stringByReplacingOccurrencesOfString:@"#" withString:@""]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].uppercaseString;
            if (s.length == 6 && [s rangeOfCharacterFromSet:hexSet.invertedSet].location == NSNotFound)
                [ok addObject:s];
            if (ok.count >= 8) break;
        }
        if (!ok.count) { [self toast:@"格式不对(要 6 位 HEX, 逗号分隔)"]; return; }
        [self saveHomeBarHexes:[ok componentsJoinedByString:@","]];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)saveHomeBarHexes:(NSString *)hexes {
    CFPreferencesSetAppValue(CFSTR("homeBarHexes"), (__bridge CFPropertyListRef)hexes,
                             (__bridge CFStringRef)kDomain);
    /* 单色模式也同步到首色, 两个模式切换时不丢色 */
    NSArray *parts = [hexes componentsSeparatedByString:@","];
    if (parts.count) {
        CFPreferencesSetAppValue(CFSTR("homeBarHex"), (__bridge CFPropertyListRef)parts[0],
                                 (__bridge CFStringRef)kDomain);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
    [self toast:[NSString stringWithFormat:@"横条颜色: %@", hexes]];
}

/* 2.5.12: 横条配色预设面板入口 */
- (void)diOpenHomeBarPick:(PSSpecifier *)spec {
    diStep(@"点[横条配色选择]: 开始");
    diOpenHomeBarPickWindow();
}

/* 2.5.10: 横条颜色 —— 打开独立面板(仿"字体颜色"的可用做法) */
- (void)diOpenHomeBarColorPanel:(PSSpecifier *)spec {
    diStep(@"点[横条颜色]: 开始");
    diOpenHomeBarPanelWindow();
}

/* 2.2.19: 锁屏通知背景视频 —— 从本地素材目录(/var/mobile/灵动岛)选, 也可从相册导入 */
/* 2.5.0: 底栏横条颜色 —— 预设色 + 自定义 HEX 输入 */
- (void)diPickHomeBarColor:(PSSpecifier *)spec {
    void (^save)(NSString *) = ^(NSString *hex) {
        CFPreferencesSetAppValue(CFSTR("homeBarHex"), (__bridge CFPropertyListRef)hex, (__bridge CFStringRef)kDomain);
        CFPreferencesSetAppValue(CFSTR("homeBarHexes"), (__bridge CFPropertyListRef)hex, (__bridge CFStringRef)kDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        postReload();
        [self toast:[NSString stringWithFormat:@"横条颜色: %@", hex]];
    };
    NSArray *presets = @[
        @[@"白色", @"FFFFFF"], @[@"黑色", @"000000"], @[@"红色", @"FF3B30"],
        @[@"橙色", @"FF9500"], @[@"黄色", @"FFCC00"], @[@"绿色", @"34C759"],
        @[@"青色", @"32ADE6"], @[@"蓝色", @"007AFF"], @[@"紫色", @"AF52DE"],
        @[@"粉色", @"FF2D55"],
    ];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"横条颜色"
        message:@"选预设或输入 HEX(如 1A9EFF)" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray *pr in presets) {
        [a addAction:[UIAlertAction actionWithTitle:pr[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            save(pr[1]);
        }]];
    }
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"自定义 HEX, 如 1A9EFF";
        tf.text = @"";
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"确定自定义" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *hex = [a.textFields.firstObject.text stringByReplacingOccurrencesOfString:@"#" withString:@""].uppercaseString;
        NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"];
        if (hex.length == 6 && [hex rangeOfCharacterFromSet:ok.invertedSet].location == NSNotFound) save(hex);
        else [self toast:@"HEX 格式不对(要 6 位十六进制)"];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)pickLockBgVideo:(PSSpecifier *)spec {
    NSArray *files = videoFiles();
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"背景视频"
        message:[NSString stringWithFormat:@"素材目录: %@\n共 %lu 个视频", kMaterialDir, (unsigned long)files.count]
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *f in files) {
        [a addAction:[UIAlertAction actionWithTitle:f style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            CFPreferencesSetAppValue(CFSTR("lkBgVideo"), (__bridge CFPropertyListRef)f, (__bridge CFStringRef)kDomain);
            CFPreferencesSetAppValue(CFSTR("lkBgOn"), (__bridge CFPropertyListRef)@YES, (__bridge CFStringRef)kDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            postReload();
            _specifiers = nil; [self reloadSpecifiers];
            diStep(@"锁屏背景视频: 选了 %@", f);
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"从相册导入视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self importForLockBg];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"不用视频(清除)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        CFPreferencesSetAppValue(CFSTR("lkBgVideo"), (__bridge CFPropertyListRef)@"", (__bridge CFStringRef)kDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        postReload(); _specifiers = nil; [self reloadSpecifiers];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    /* iPad 上 ActionSheet 需要 popover 锚点 */
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)importForLockBg {
    Class phpPicker = NSClassFromString(@"PHPickerViewController");
    Class phpCfg = NSClassFromString(@"PHPickerConfiguration");
    if (!phpPicker || !phpCfg) { [self toast:@"当前系统不可用(PHPicker 需要 iOS 14+)"]; return; }
    id cfg = [[phpCfg alloc] init];
    Class f = NSClassFromString(@"PHPickerFilter");
    if ([cfg respondsToSelector:@selector(setFilter:)] && [f respondsToSelector:@selector(videosFilter)])
        [cfg performSelector:@selector(setFilter:) withObject:((id (*)(id, SEL))objc_msgSend)(f, @selector(videosFilter))];
    if ([cfg respondsToSelector:@selector(setSelectionLimit:)])
        [cfg performSelector:@selector(setSelectionLimit:) withObject:@1];
    id p = [[phpPicker alloc] initWithConfiguration:cfg];
    if ([p respondsToSelector:@selector(setDelegate:)]) [p performSelector:@selector(setDelegate:) withObject:self];
    [self presentViewController:p animated:YES completion:nil];
}
- (void)picker:(id)picker didFinishPicking:(NSArray *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    id r = results.firstObject;
    id provider = [r valueForKey:@"itemProvider"];
    NSString *sugg = [provider respondsToSelector:@selector(suggestedName)] ? [provider performSelector:@selector(suggestedName)] : nil;
    [provider loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *err) {
        if (!url) { dispatch_async(dispatch_get_main_queue(), ^{ [self toast:@"导入失败"]; }); return; }
        NSString *ext = url.pathExtension.length ? url.pathExtension : @"mov";
        NSString *base = @"锁屏背景";
        if (sugg.length) {
            base = sugg.pathExtension.length ? sugg.stringByDeletingPathExtension : sugg;
            base = [base stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:kMaterialDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *name = [NSString stringWithFormat:@"%@.%@", base, ext];
        NSString *dst = [kMaterialDir stringByAppendingPathComponent:name];
        NSInteger n = 1;
        while ([fm fileExistsAtPath:dst]) {
            name = [NSString stringWithFormat:@"%@_%ld.%@", base, (long)n++, ext];
            dst = [kMaterialDir stringByAppendingPathComponent:name];
        }
        if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:NULL]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CFPreferencesSetAppValue(CFSTR("lkBgVideo"), (__bridge CFPropertyListRef)name, (__bridge CFStringRef)kDomain);
                CFPreferencesSetAppValue(CFSTR("lkBgOn"), (__bridge CFPropertyListRef)@YES, (__bridge CFStringRef)kDomain);
                CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
                postReload();
                _specifiers = nil; [self reloadSpecifiers];
                diStep(@"锁屏背景视频: 相册导入 %@", name);
            });
        }
    }];
}

/* 素材选择行右侧显示的当前素材名 */
- (NSString *)nameForMode:(NSInteger)mode {
    NSArray *files = videoFiles();
    NSString *key = (mode == 0) ? @"smallIndex" : @"expandIndex";
    NSInteger idx = indexForKey(key);
    if (idx < 0 || idx >= (NSInteger)files.count) return @"无素材";
    return files[idx];
}

/* 频谱行右侧: 当前素材文件夹名 */
- (NSString *)frameStatusName {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("animFolder"), (__bridge CFStringRef)kDomain));
    if ([v isKindOfClass:NSString.class] && [(NSString *)v length]) return v;
    return @"默认(全部帧)";
}

- (id)readSmallVideoName:(PSSpecifier *)spec { return [self nameForMode:0]; }
- (id)readExpandVideoName:(PSSpecifier *)spec { return [self nameForMode:1]; }
- (id)readSpectrumName:(PSSpecifier *)spec { return [self frameStatusName]; }

- (PSSpecifier *)switchSpec:(NSString *)name key:(NSString *)key def:(id)def {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSwitchCell edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:kDomain forKey:@"defaults"];
    [s setProperty:def forKey:@"default"];
    return s;
}

/* 2.5.8: 分段控件行(截图同款: 两/三段并排, 直接点击切换) */
- (PSSpecifier *)segmentedSpec:(NSString *)name key:(NSString *)key
                         titles:(NSArray *)titles values:(NSArray *)vals def:(NSString *)def {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSegmentCell edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:kDomain forKey:@"defaults"];
    [s setProperty:def forKey:@"default"];
    [s setProperty:titles forKey:@"titlesValues"];
    [s setProperty:vals forKey:@"values"];
    return s;
}

- (PSSpecifier *)groupSpec:(NSString *)header footer:(NSString *)footer {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:header target:nil
        set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
    if (footer) [s setProperty:footer forKey:@"footerText"];
    return s;
}

/* 2.2.17: 文本输入行(HEX 颜色 / 视频文件名等) */
/* 2.2.24: 多色颜色行 —— 支持 "FF0000,00FF00,..." 逗号分隔;
   行右侧用「边框颜色」那种小方块展示当前色(多色时并排显示), 点行进批量输入页。 */
- (PSSpecifier *)multiColorSpec:(NSString *)name key:(NSString *)key def:(NSString *)def {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSEditTextCell edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:kDomain forKey:@"defaults"];
    [s setProperty:def ?: @"" forKey:@"default"];
    [s setProperty:@"可填 1~4 个, 用逗号分隔 如 FF0000,00FF00" forKey:@"placeholder"];
    [s setProperty:@YES forKey:@"diMultiColor"];
    return s;
}

- (PSSpecifier *)textSpec:(NSString *)name key:(NSString *)key def:(NSString *)def ph:(NSString *)ph {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSEditTextCell edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:kDomain forKey:@"defaults"];
    [s setProperty:def ?: @"" forKey:@"default"];
    if (ph) [s setProperty:ph forKey:@"placeholder"];
    return s;
}

/* 2.2.8: 颜色工具 —— HEX/RGB 互转, 多色数组读写 */
static NSString *diHexFromColor(UIColor *c) {
    CGFloat r = 1, g = 1, b = 1, a = 1;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return @"FFFFFF";
    return [NSString stringWithFormat:@"%02X%02X%02X", (int)lround(r * 255), (int)lround(g * 255), (int)lround(b * 255)];
}
static UIColor *diColorFromHexStr(NSString *hex, UIColor *def) {
    if (!hex.length) return def;
    NSMutableString *s = [NSMutableString stringWithString:hex];
    [s replaceOccurrencesOfString:@"#" withString:@"" options:0 range:NSMakeRange(0, s.length)];
    if (s.length < 6) return def;
    unsigned v = 0;
    if (![[NSScanner scannerWithString:s] scanHexInt:&v]) return def;
    return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0 alpha:1.0];
}
/* 默认渐变(白→浅黄→浅粉→浅蓝): 与图二风格一致的柔和色 */
static NSArray<NSString *> *diDefaultGradient(void) { return @[@"FFEFEA", @"FF9EA8", @"C9E8F7", @"FFF0B1"]; }

/* 多色数组: 存成逗号分隔 HEX 字符串(diNotifColors) */
static NSArray<NSString *> *diReadColors(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("diNotifColors"), (__bridge CFStringRef)kDomain));
    NSMutableArray *out = [NSMutableArray array];
    if ([v isKindOfClass:NSString.class] && [(NSString *)v length]) {
        for (NSString *h in [(NSString *)v componentsSeparatedByString:@","])
            if (h.length >= 6) [out addObject:h.uppercaseString];
    }
    if (!out.count) [out addObjectsFromArray:diDefaultGradient()];
    return out;
}
static void diWriteColors(NSArray<NSString *> *colors) {
    NSString *joined = [colors componentsJoinedByString:@","];
    CFPreferencesSetAppValue(CFSTR("diNotifColors"), (__bridge CFPropertyListRef)joined, (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
}

/* 多色面板入口: 图二式色块横排 + 批量输入 + 增删
   2.2.22: 不再 push 进 Preferences 导航栈(会被反复重排 → 加减色点击丢失),
   改为独立窗口弹出(和预览浮层同一套手法)。 */
- (void)diOpenStylePanel:(PSSpecifier *)spec {
    diOpenStylePanelWindow();
}

- (void)diOpenGradientPanel:(PSSpecifier *)spec {
    diStep(@"点[字体颜色]: 开始");
    diOpenGradientPanelWindow();
    diStep(@"点[字体颜色]: 已请求打开独立面板窗口");
}

/* 2.2.16: 预览 —— 交给独立小 App(DriftIslandPreview)去投递。
   必须用真实 bundle 身份: SpringBoard 自己调 UNUserNotificationCenter 会
   "返回成功但通知被系统丢弃"(日志实证), 所以走 helper 进程。 */
- (void)diPreviewTapped:(PSSpecifier *)spec {
    /* 2.2.21: 按用户要求去掉"预览通知已发送"弹窗, 直接弹 3 秒小窗 */
    diStep(@"点[预览]: 开始(不弹窗)");
    postReload();
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.abgg332.driftisland.preview"), NULL, NULL, YES);
}

/* 数值行: 标题=文字+当前整数(如"帧率速度 60"), 滑杆改动后刷新标题; 保存取整并clamp */
/* 数值行: 标题=文字+当前整数(如"帧率速度 60"), 滑杆改动后刷新标题; 保存取整并clamp */
- (int)numValue:(NSString *)key def:(int)def {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return v ? (int)round([v doubleValue]) : def;
}

- (PSSpecifier *)numSlider:(NSString *)label key:(NSString *)key def:(int)def mn:(int)mn mx:(int)mx {
    return [self numSlider:label key:key def:def mn:mn mx:mx fmt:nil];
}

- (NSString *)strValue:(NSString *)key def:(NSString *)def {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return [v isKindOfClass:[NSString class]] ? v : def;
}

/* 2.2.19: 带自定义格式(如 "%@  %.0f%%" / "%@  %.1f")的数值行
   2.2.34: 标题不再带数值 —— 数值统一由右侧数字按钮显示,
   否则会出现 "54 54" 这种原生值 + 我们按钮 双份重复。 */
- (PSSpecifier *)numSlider:(NSString *)label key:(NSString *)key def:(int)def mn:(int)mn mx:(int)mx fmt:(NSString *)fmt {
    int v = [self numValue:key def:def];
    if (v < mn) v = mn; if (v > mx) v = mx;
    (void)fmt;
    (void)v;
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
        target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSliderCell edit:nil];
    Class sc = diStepSliderClass();
    if (sc) [s setProperty:[sc description] forKey:@"cellClass"];
    [s setProperty:self forKey:@"diTarget"];
    [s setProperty:label forKey:@"diLabel"];      /* 给自定义 cell 画标题用 */
    [s setProperty:key forKey:@"key"];
    [s setProperty:kDomain forKey:@"defaults"];
    [s setProperty:@(def) forKey:@"default"];
    [s setProperty:@(mn) forKey:@"min"];
    [s setProperty:@(mx) forKey:@"max"];
    [s setProperty:@{ @"min": @(mn), @"max": @(mx), @"label": label } forKey:@"range"];
    return s;
}

/* 2.2.36: 带 −/+ 与数字按钮的单行滑杆(锁屏通知组 + 帧率组共用)。
   布局在 diStepSliderLayout 里, 一行搞定: [标题][−][短滑杆][+][数值]。 */
- (PSSpecifier *)stepSlider:(NSString *)label key:(NSString *)key def:(int)def mn:(int)mn mx:(int)mx {
    PSSpecifier *s = [self numSlider:label key:key def:def mn:mn mx:mx fmt:nil];
    [s setProperty:@(44) forKey:@"height"];      /* 单行行高, 与截图一致 */
    [s setProperty:@YES forKey:@"diStep"];       /* 打标记: 用自定义 cell 布局 */
    return s;
}

- (void)scheduleSync {
    static NSTimer *t = nil;
    [t invalidate];
    t = [NSTimer scheduledTimerWithTimeInterval:0.6 target:self selector:@selector(doSync)
        userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}

- (void)doSync {
    [self reloadSpecifiers]; // 重建后标题带上最新数值
}

- (PSSpecifier *)buttonSpec:(NSString *)name action:(SEL)sel {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
    [s setButtonAction:sel];
    return s;
}

/* 2.6.24: 主页排版(第四版, 用户指定) ——
   [总开关]
   [灵动岛]   小岛设置 / 展开设置 / 录屏设置
   [附加功能] 锁屏设置
   [工具]     跳转素材目录 / 跳转帧率目录
   [日志开关] 下面中间加问候语 + 版本号
   子页面用手动 push(pageSpec:)打开, 不再让 Preferences 自动实例化(2.6.23 点进页闪退的根因)。 */
- (NSArray *)specifiers {
    /* 2.7.16: 入口页一闪退, 必须先分清崩在哪个阶段:
         init 成功但这里没日志  → 崩在 PSListController 内部构造视图时
         这里也有日志但没有"完成" → 崩在下面某一条 spec 的创建里
       两条标记之间就是崩溃发生的位置。 */
    diStep(@"specifiers 开始构建");
    @try {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        /* 2.7.16: 每加一条就更新一个"最后成功的条目"标记 ——
           下次崩溃时日志最后一条就是崩溃前最后一条成功的 spec, 精确到行。 */
        #define DI_ADD(x) do { id _o = (x); if (_o) { [specs addObject:_o]; diStep(@"  spec[%lu] OK", (unsigned long)specs.count); } } while (0)

        /* ===== 2.6.27: 回到 2.6.21 的单页排版 =====
           2.6.22~2.6.26 那套"子页面"改法让横条组名定位失效(素材名不显示)+
           横条显示异常, 本版全部退回单页: 各区组名与顺序严格保持 2.6.21,
           因为 willDisplayCell 靠组名("小岛素材/展开素材/录屏素材/帧率")定位滑杆与素材名。
           唯一新增: 锁屏区改成一行"锁屏设置"进页, 页内是 2.6.21 原有的全部锁屏项。 */

        DI_ADD([self groupSpec:@"开启灵动岛定制" footer:nil]);
        DI_ADD([self switchSpec:@"总开关" key:@"enabled" def:@NO]);
        /* 2.8.31: 隐藏药丸(放歌/录屏时灵动岛底层那块 HDR 增益图黑块) */
        DI_ADD([self switchSpec:@"隐藏药丸" key:@"hideBlackPill" def:@NO]);
        DI_ADD([self switchSpec:@"隐藏小岛" key:@"hideNoMusic" def:@NO]);

        /* ---- 小岛素材 ---- */
        DI_ADD([self groupSpec:@"小岛素材" footer:nil]);
        PSSpecifier *smallMat = [self buttonSpec:@"素材选择" action:@selector(openSmallGrid:)];
        DI_ADD([self switchSpec:@"小岛显示素材" key:@"smallOn" def:@YES]);
        DI_ADD(smallMat);

        /* ---- 展开素材 ---- */
        DI_ADD([self groupSpec:@"展开素材" footer:nil]);
        PSSpecifier *expandMat = [self buttonSpec:@"素材选择" action:@selector(openExpandGrid:)];
        DI_ADD([self switchSpec:@"展开显示素材" key:@"expandOn" def:@YES]);
        DI_ADD(expandMat);

        /* 2.8.89: 主页「帧率」组整体移除 —— 已并入「附加功能 → 展开定义」页的顶部,
           两处一模一样的东西没必要重复显示。参数键一个字没改, 老设置照旧生效。 */

        /* ---- 2.6.29: 附加功能 —— 文字颜色 / 锁屏通知 / 专辑遮罩 统一进页 ---- */
        DI_ADD([self groupSpec:@"附加功能" footer:nil]);
        DI_ADD([self linkSpec:@"文字颜色" detail:[DITextStylePage class]]);
        DI_ADD([self linkSpec:@"锁屏通知" detail:[DILockScreenPage class]]);
        /* 2.8.22: "歌词岛"更名"专辑遮罩"(左侧专辑帧率 + 右侧音频帧率 + 专辑遮罩) */
        DI_ADD([self linkSpec:@"专辑遮罩" detail:[DILyricsIslandSettings class]]);
        /* 2.8.88: 展开定义 —— 按用户要求做成独立入口, 就放在「专辑遮罩」下面;
           页内上面是帧率, 下面是展开岛的歌词/歌名位置与大小 */
        DI_ADD([self linkSpec:@"歌词位置" detail:[DIExpandDefinePage class]]);
        /* 2.9.5: 专辑律动 —— 封面粒子 + 鼓点震动 */
        DI_ADD([self linkSpec:@"专辑律动" detail:[DIRhythmPage class]]);
        /* 2.8.41: 控制中心入口回归 */
        DI_ADD([self linkSpec:@"控制中心" detail:[DICCSettings class]]);

        _smallRow = _expandRow = -1;
        {
            NSInteger n = 0;
            for (PSSpecifier *s in specs) {
                if (s.cellType == PSGroupCell) continue;
                if (s == smallMat) _smallRow = n;
                if (s == expandMat) _expandRow = n;
                n++;
            }
        }

        DI_ADD([self groupSpec:@"工具" footer:@"视频素材目录: /var/mobile/灵动岛\n频谱帧率素材目录: /var/mobile/灵动岛/帧率素材"]);
        DI_ADD([self buttonSpec:@"跳转素材目录" action:@selector(openMaterialDir)]);
        DI_ADD([self buttonSpec:@"跳转帧率目录" action:@selector(openFrameDir)]);

        DI_ADD([self groupSpec:nil footer:nil]);
        DI_ADD([self switchSpec:@"日志开关" key:@"logging" def:@NO]);

        /* ---- 2.6.28: 版本号单独一组, 放在整页最底部(与日志分开) ---- */
        DI_ADD([self groupSpec:nil footer:nil]);
        {
            PSSpecifier *ver = [PSSpecifier preferenceSpecifierNamed:@"" target:nil
                set:NULL get:NULL detail:nil cell:PSStaticTextCell edit:nil];
            [ver setProperty:@"diVersion" forKey:@"diKind"];
            [ver setProperty:[NSString stringWithFormat:@"漂流岛  v%@", DI_VERSION_STR] forKey:@"diVerText"];
            DI_ADD(ver);
        }

        _specifiers = specs;
    }
    } @catch (NSException *e) {
        /* 2.7.16: 任何一条 spec 创建失败都不许拖垮设置 App ——
           退回"最简可用"列表: 总开关 + 跳目录 + 导出日志。
           用户至少能进页面, 而我们能拿到异常原因。 */
        diStep(@"!!! specifiers 构建异常: %@ — %@\n%@", e.name, e.reason, e.callStackSymbols);
        _specifiers = [[self diFallbackSpecifiers] mutableCopy];
    }
    diStep(@"specifiers 构建完成 (%lu 条)", (unsigned long)_specifiers.count);
    return _specifiers;
}

/* 2.7.16: 兜底列表 —— 保证入口页一定能打开 */
- (NSArray *)diFallbackSpecifiers {
    NSMutableArray *a = [NSMutableArray array];
    @try {
        [a addObject:[self groupSpec:@"开启灵动岛定制" footer:@"页面加载异常, 已切换为最简模式"]];
        [a addObject:[self switchSpec:@"总开关" key:@"enabled" def:@NO]];
        [a addObject:[self buttonSpec:@"跳转素材目录" action:@selector(openMaterialDir)]];
        [a addObject:[self buttonSpec:@"导出日志报告" action:@selector(exportLogReport)]];
    } @catch (__unused NSException *e) {}
    if (!a.count) {
        PSSpecifier *g = [PSSpecifier groupSpecifierWithName:@"漂流岛"];
        if (g) [a addObject:g];
    }
    return a;
}

/* 强制在箭头位置显示当前素材名（valueLabel / detailTextLabel 双保险） */
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    /* 仅当父类真的实现了该回调时才转发，避免 unrecognized selector 闪退 */
    if ([[self superclass] instancesRespondToSelector:@selector(tableView:willDisplayCell:forRowAtIndexPath:)])
        ((void (*)(struct objc_super *, SEL, UITableView *, UITableViewCell *, NSIndexPath *))objc_msgSendSuper)(
            (struct objc_super *)&(struct objc_super){ .receiver = self, .super_class = class_getSuperclass(object_getClass(self)) },
            @selector(tableView:willDisplayCell:forRowAtIndexPath:), tableView, cell, indexPath);
    /* 注意: PSGroupCell 是 section header 不占行, indexPath.row 是组内行号:
       section1(通知样式): 开关/色块/流光开关/(起始色/结束色)/背景开关 —— 行数随流光开关变化, 故按 specifier 判定;
       section2(小岛) / section3(展开) / section4(帧率) 结构固定 */
    /* 渐变行: 右侧一条渐变预览条 + 颜色数(图二风格) */
    PSSpecifier *sp = [self specifierAtIndexPath:indexPath];

    /* 2.6.25: 底部"漂流岛"横幅 —— 居中大字号 + 渐变彩色 + 右侧箭头(点箭头进关于页) */
    /* 2.6.27: 底部版本号 —— 纯文本, 居中, 不可点, 无箭头 */
    if ([[sp propertyForKey:@"diKind"] isEqualToString:@"diVersion"]) {
        NSString *txt = [sp propertyForKey:@"diVerText"] ?: @"";
        cell.textLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = NO;
        /* 2.6.30: 去掉白色卡片底色 —— 让整行透明, 文字直接落在分组灰底上 */
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
        cell.backgroundView = nil;
        cell.backgroundView.backgroundColor = [UIColor clearColor];
        UILabel *lb = objc_getAssociatedObject(cell, "diVerLabel");
        if (!lb) {
            lb = [UILabel new];
            lb.textAlignment = NSTextAlignmentCenter;
            lb.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
            lb.textColor = [UIColor secondaryLabelColor];
            [cell.contentView addSubview:lb];
            objc_setAssociatedObject(cell, "diVerLabel", lb, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CGFloat cw = cell.contentView.bounds.size.width, ch = cell.contentView.bounds.size.height;
        lb.text = txt;
        lb.frame = CGRectMake(0, (ch - 20) / 2, cw, 20);
        return;
    }

    /* 2.2.47: 先把 specifier 信息缓存到 cell 上(di_k_step 等)。
       2.2.45 卸掉了全局 layoutSubviews hook 之后, 建缓存的责任就落在这里 ——
       否则下面判断 di_k_step 永远是 nil, 锁屏组会退化成系统原始样式。 */
    @try { diStepCacheSpec(cell); } @catch (__unused NSException *e) {}

    /* 2.2.47: 锁屏组滑杆 —— 完全照搬帧率组那套 diBox 写法(用户指定的"很完美"那版)。

       之前几版的失败路径:
         · 2.2.43 自建 box + 跨对象 target → 闪退
         · 2.2.44 四段并列逐像素坐标 → 标题压到滑杆上
         · 2.2.46 两行结构 → 标题和滑杆仍然各说各话
       帧率组之所以稳, 是因为它只做三件事:
         1) 标题交给系统自己的 cell.textLabel 渲染(字体/位置都不用我们操心)
         2) 隐藏系统滑杆, 用一个 diBox 容器装"滑杆 + 数值"两件东西
         3) 全部按 cw/ch 的比例算坐标, 不写死像素
       这里逐行照抄, 只把 key/范围换成锁屏组的。帧率组那段一个字都没动。 */
    BOOL isStepRow = [objc_getAssociatedObject(cell, "di_k_step") boolValue];
    if (isStepRow) {
        NSString *skey = objc_getAssociatedObject(cell, "di_k_key");
        NSString *slabel = objc_getAssociatedObject(cell, "di_k_name") ?: skey;
        if (skey.length) {
            double smn = [objc_getAssociatedObject(cell, "di_k_min") doubleValue];
            double smx = [objc_getAssociatedObject(cell, "di_k_max") doubleValue];
            double sdef = [objc_getAssociatedObject(cell, "di_k_def") doubleValue];
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            id cur = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)skey,
                                                                (__bridge CFStringRef)kDomain));
            double v = cur ? [cur doubleValue] : sdef;
            v = round(v);
            if (v < smn) v = smn; if (v > smx) v = smx;

            /* 标题交给系统 */
            cell.textLabel.text = slabel;
            cell.textLabel.font = [UIFont systemFontOfSize:15];

            /* 隐藏系统滑杆 */
            UIView *sroot = cell.contentView.subviews.count ? cell.contentView : cell;
            for (UIView *sv in sroot.subviews) if ([sv isKindOfClass:UISlider.class]) sv.hidden = YES;
            for (UIView *sv in cell.subviews) if ([sv isKindOfClass:UISlider.class]) sv.hidden = YES;

            CGFloat scw = cell.contentView.bounds.size.width, sch = cell.contentView.bounds.size.height;
            UIView *sbox = objc_getAssociatedObject(cell, "diStepBoxV");
            if (!sbox) {
                sbox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, scw, sch)];
                sbox.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                UISlider *sl = [UISlider new];
                sl.minimumTrackTintColor = [UIColor systemBlueColor];
                [sl addTarget:self action:@selector(diSliderChanged:) forControlEvents:UIControlEventValueChanged];
                UILabel *vl = [UILabel new];
                vl.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightRegular];
                vl.textAlignment = NSTextAlignmentRight;
                vl.userInteractionEnabled = YES;
                vl.textColor = [UIColor systemBlueColor];
                [vl addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(diTapValue:)]];
                [sbox addSubview:sl];
                [sbox addSubview:vl];
                [cell.contentView addSubview:sbox];
                objc_setAssociatedObject(cell, "diStepBoxV", sbox, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(sbox, "slider", sl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(sbox, "valLabel", vl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            /* 复用帧率组的 key/label/mn/mx 关联键, 动作方法无需改动 */
            objc_setAssociatedObject(sbox, "key", skey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(sbox, "label", slabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(sbox, "mn", @(smn), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(sbox, "mx", @(smx), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            sbox.frame = CGRectMake(0, 0, scw, sch);
            UISlider *ssl = objc_getAssociatedObject(sbox, "slider");
            UILabel *svl = objc_getAssociatedObject(sbox, "valLabel");
            /* 与帧率组同一套坐标: 滑杆 30%~68%, 数值 70%~88% */
            ssl.frame = CGRectMake(scw * 0.30, (sch - 31) / 2, scw * 0.38, 31);
            ssl.minimumValue = smn; ssl.maximumValue = smx;
            if ((int)round(ssl.value) != (int)v) ssl.value = v;
            svl.text = [NSString stringWithFormat:@"%d", (int)v];
            svl.frame = CGRectMake(scw * 0.70, (sch - 24) / 2, scw * 0.18, 24);
            sbox.hidden = NO;
        }
        /* 锁屏组已由 diBox 接管, 不再走下面那个 diStepSliderLayout(那是旧的两行方案) */
        return;
    }

    /* 2.2.32: 滑杆行排版 —— willDisplayCell 每次上屏都重排(不等任何 hook 时机),
       并在 0.2/0.6 秒后再补两次: Preferences 会在这两个时间点做二次布局,
       会把我们摆好的 frame 冲掉, 补排才能压住它(之前"改了跟没改一样"就是被冲掉了)。 */
    BOOL isSliderCell = [cell isKindOfClass:NSClassFromString(@"PSSliderCell")];
    if (!isSliderCell) {
        for (UIView *sub in cell.contentView.subviews)
            if ([sub isKindOfClass:NSClassFromString(@"UISlider")]) { isSliderCell = YES; break; }
    }
    if (isSliderCell) {
        diStepSliderLayout(cell);
        __weak UITableViewCell *wc = cell;
        double delays[3] = {0.0, 0.2, 0.6};
        for (int di = 0; di < 3; di++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[di] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ if (wc) diStepSliderLayout(wc); });
        }
    }

    if ([[sp propertyForKey:@"diKind"] isEqualToString:@"gradient"]) {
        UIView *bar = objc_getAssociatedObject(cell, "diGradBar");
        if (!bar) {
            bar = [[UIView alloc] initWithFrame:CGRectZero];
            bar.userInteractionEnabled = NO;
            bar.layer.cornerRadius = 10;
            bar.layer.masksToBounds = YES;
            bar.layer.borderWidth = 1;
            bar.layer.borderColor = [UIColor separatorColor].CGColor;
            CAGradientLayer *gl = [CAGradientLayer layer];
            gl.startPoint = CGPointMake(0, 0.5);
            gl.endPoint = CGPointMake(1, 0.5);
            [bar.layer addSublayer:gl];
            objc_setAssociatedObject(bar, "gl", gl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [cell.contentView addSubview:bar];
            objc_setAssociatedObject(cell, "diGradBar", bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CGFloat cw = cell.contentView.bounds.size.width, ch = cell.contentView.bounds.size.height;
        CGFloat bw = MIN(150.0, cw * 0.42);
        bar.frame = CGRectMake(cw - bw - 22, (ch - 24) / 2, bw, 24);
        CAGradientLayer *gl = objc_getAssociatedObject(bar, "gl");
        gl.frame = bar.bounds;
        NSArray *cs = diReadColors();
        NSMutableArray *cols = [NSMutableArray array];
        for (NSString *h in cs) [cols addObject:(id)diColorFromHexStr(h, [UIColor whiteColor]).CGColor];
        if (cols.count == 1) [cols addObject:cols.firstObject];
        gl.colors = cols;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    /* 2.2.52: 动态定位组 section —— 之前硬编码 indexPath.section == 2/3/4,
       一旦插入/移动"录屏素材"组, 帧率/素材名的 section 全部错位(2.2.51 的教训)。
       现在按组名(PSGroupCell 的 name)实时算 section, 组顺序怎么调都不失效。 */
    NSInteger secSmall = -1, secExpand = -1, secFrame = -1;
    {
        NSInteger sec = -1;
        for (PSSpecifier *gs in self.specifiers) {
            if (gs.cellType != PSGroupCell) continue;
            sec++;
            NSString *gnm = gs.name ?: @"";
            if ([gnm isEqualToString:@"小岛素材"]) secSmall = sec;
            else if ([gnm isEqualToString:@"展开素材"]) secExpand = sec;
            else if ([gnm isEqualToString:@"帧率"]) secFrame = sec;
        }
    }

    /* 帧率参数滑杆行(帧率组 row2~5): 文字(左) + 滑杆(中) + 数值(右), 自绘布局
       —— 2.2.38: 原样恢复, 这是用户要求的"帧率保持以前的", 不要动。 */
    if (indexPath.section == secFrame && secFrame >= 0 && indexPath.row >= 2 && indexPath.row <= 5) {
        NSArray *labels = @[@"帧率速度", @"素材大小", @"左右偏移", @"上下偏移"];
        NSArray *keys   = @[@"animFPS", @"animScaleAdj", @"animOffsetX3", @"animOffsetY3"];
        NSArray *defs   = @[@50, @0, @0, @0];
        NSArray *mins   = @[@10, @-20, @-50, @-50];
        NSArray *maxs   = @[@200, @20, @50, @50];
        NSInteger i = indexPath.row - 2;
        int v = [self numValue:keys[i] def:[defs[i] intValue]];
        if (v < [mins[i] intValue]) v = [mins[i] intValue];
        if (v > [maxs[i] intValue]) v = [maxs[i] intValue];

        cell.textLabel.text = labels[i];
        cell.textLabel.font = [UIFont systemFontOfSize:15];

        /* 隐藏系统滑杆(它不渲染标题且铺满整行) */
        UIView *root = cell.contentView.subviews.count ? cell.contentView : cell;
        for (UIView *sv in root.subviews) if ([sv isKindOfClass:UISlider.class]) sv.hidden = YES;
        for (UIView *sv in cell.subviews) if ([sv isKindOfClass:UISlider.class]) sv.hidden = YES;

        CGFloat cw = cell.contentView.bounds.size.width, ch = cell.contentView.bounds.size.height;
        UIView *box = objc_getAssociatedObject(cell, "diBox");
        if (!box) {
            box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cw, ch)];
            box.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            UISlider *sl = [UISlider new];
            sl.minimumTrackTintColor = [UIColor systemBlueColor];
            [sl addTarget:self action:@selector(diSliderChanged:) forControlEvents:UIControlEventValueChanged];
            UILabel *vl = [UILabel new];
            vl.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightRegular];
            vl.textAlignment = NSTextAlignmentRight;
            vl.userInteractionEnabled = YES;
            vl.textColor = [UIColor systemBlueColor]; // 提示可点击输入
            [vl addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(diTapValue:)]];
            [box addSubview:sl];
            [box addSubview:vl];
            [cell.contentView addSubview:box];
            objc_setAssociatedObject(cell, "diBox", box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(box, "slider", sl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(box, "valLabel", vl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(box, "key", keys[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(box, "label", labels[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(box, "mn", mins[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(box, "mx", maxs[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        box.frame = CGRectMake(0, 0, cw, ch);
        UISlider *sl = objc_getAssociatedObject(box, "slider");
        UILabel *vl = objc_getAssociatedObject(box, "valLabel");
        sl.frame = CGRectMake(cw * 0.30, (ch - 31) / 2, cw * 0.38, 31);
        sl.minimumValue = [mins[i] intValue]; sl.maximumValue = [maxs[i] intValue];
        if ((int)round(sl.value) != v) sl.value = v; // 不在拖动中才校准
        vl.text = [NSString stringWithFormat:@"%d", v];
        vl.frame = CGRectMake(cw * 0.70, (ch - 24) / 2, cw * 0.18, 24);
        box.hidden = NO;
    }
    NSString *name = nil;
    if (indexPath.section == secSmall && secSmall >= 0 && indexPath.row == 1) name = [self nameForMode:0];
    if (indexPath.section == secExpand && secExpand >= 0 && indexPath.row == 1) name = [self nameForMode:1];
    if (indexPath.section == secFrame && secFrame >= 0 && indexPath.row == 6) name = [self frameStatusName];
    if (name) {
        if ([cell respondsToSelector:@selector(setValue:)])
            ((void (*)(id, SEL, id))objc_msgSend)(cell, @selector(setValue:), name);
        if ([cell respondsToSelector:@selector(valueLabel)]) {
            UILabel *vl = ((id (*)(id, SEL))objc_msgSend)(cell, @selector(valueLabel));
            if (vl) { vl.text = name; vl.textColor = [UIColor secondaryLabelColor]; }
        }
        if (cell.detailTextLabel) cell.detailTextLabel.text = name;
    }
}

/* Filza 官方 URL 格式: filza://view/路径 或 filza://路径（见 tigisoftware 官方指南），中文路径严格百分号编码 */
- (void)openDirWithConfirm:(NSString *)dir title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:nil // 只留标题一行, 不放路径文字
        preferredStyle:UIAlertControllerStyleAlert]; // 二次确认防误触
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"跳转" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self openDir:dir]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toast:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

/* 2.2.38: 恢复帧率组的自绘滑杆回调(2.2.36 误删, 那时把帧率改成共用布局了)。
   自绘滑杆拖动: 实时保存(取整+clamp) + 实时刷新数值 */
- (void)diSliderChanged:(UISlider *)sl {
    UIView *box = sl.superview;
    NSString *key = objc_getAssociatedObject(box, "key");
    double v = round(sl.value);
    double mn = [objc_getAssociatedObject(box, "mn") doubleValue];
    double mx = [objc_getAssociatedObject(box, "mx") doubleValue];
    if (v < mn) v = mn; if (v > mx) v = mx;
    if (sl.value != v) sl.value = v;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(v), (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
    UILabel *vl = objc_getAssociatedObject(box, "valLabel");
    vl.text = [NSString stringWithFormat:@"%d", (int)v];
}

/* 点击右侧数值: 弹框手动输入精确值(取整+clamp) */
- (void)diTapValue:(UITapGestureRecognizer *)tap {
    UIView *box = tap.view.superview;
    NSString *key = objc_getAssociatedObject(box, "key");
    NSString *label = objc_getAssociatedObject(box, "label");
    double mn = [objc_getAssociatedObject(box, "mn") doubleValue];
    double mx = [objc_getAssociatedObject(box, "mx") doubleValue];
    UILabel *vl = objc_getAssociatedObject(box, "valLabel");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:label
        message:[NSString stringWithFormat:@"范围 %.0f ~ %.0f", mn, mx]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = vl.text;
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        double v = round([alert.textFields.firstObject.text doubleValue]);
        if (v < mn) v = mn; if (v > mx) v = mx;
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(v), (__bridge CFStringRef)kDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        postReload();
        vl.text = [NSString stringWithFormat:@"%d", (int)v];
        UISlider *sl = objc_getAssociatedObject(box, "slider");
        if (sl && (int)round(sl.value) != (int)v) sl.value = v; // 滑杆同步
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openMaterialDir {
    [self openDirWithConfirm:kMaterialDir title:@"跳转素材目录"];
}

/* 2.7.16: Root.plist 里有一条 "导出日志报告" 的 PSButtonCell 指向 exportLogReport,
   但这个方法从来没实现过 —— Preferences 框架按 action 名字调 selector 时
   抛 unrecognized selector, 设置 App 当场退出。
   这就是**点插件入口就闪退**的真正原因, 而且崩在框架内部,
   我们自己的 diUncaught/信号处理器都来不及介入, 所以日志里一条记录都没有。
   现在补上实现: 收集日志 + 运行环境信息, 写成一份可分享的文本。 */
- (void)exportLogReport {
    @try {
        NSMutableString *rep = [NSMutableString string];
        [rep appendString:@"===== 漂流岛 日志报告 =====\n"];
        [rep appendFormat:@"版本: %@\n", DI_VERSION_STR];
        [rep appendFormat:@"系统: %@ %@\n", UIDevice.currentDevice.systemName, UIDevice.currentDevice.systemVersion];
        [rep appendFormat:@"机型: %@\n", UIDevice.currentDevice.model];
        [rep appendFormat:@"时间: %@\n", [NSDate date]];
        [rep appendFormat:@"素材目录: %@\n", kMaterialDir];

        NSArray *files = @[
            [kMaterialDir stringByAppendingPathComponent:@"driftisland.log"],
            @"/var/mobile/灵动岛/driftisland_crash.log",
        ];
        for (NSString *f in files) {
            [rep appendFormat:@"\n----- %@ -----\n", f.lastPathComponent];
            NSString *txt = [NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:NULL];
            [rep appendString:txt.length ? txt : @"(空或不存在)"];
            [rep appendString:@"\n"];
        }

        NSString *outPath = [kMaterialDir stringByAppendingPathComponent:@"日志报告.txt"];
        [rep writeToFile:outPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        diStep(@"导出日志报告: %@", outPath);

        UIActivityViewController *av = [[UIActivityViewController alloc]
            initWithActivityItems:@[[NSURL fileURLWithPath:outPath]] applicationActivities:nil];
        /* iPad 上必须给 sourceView, 否则 present 会崩 */
        if (av.popoverPresentationController) {
            av.popoverPresentationController.sourceView = self.view;
            av.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 120, 1, 1);
        }
        [self presentViewController:av animated:YES completion:nil];
    } @catch (NSException *e) {
        diStep(@"导出日志报告异常: %@ — %@", e.name, e.reason);
        [self toast:[NSString stringWithFormat:@"导出失败: %@", e.reason ?: e.name]];
    }
}

- (void)openFrameDir {
    [self openDirWithConfirm:kFrameDir title:@"跳转帧率目录"];
}

- (void)openDir:(NSString *)dir {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"];
    NSString *enc = [dir stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"filza://view%@", enc]];
    if (!url) url = [NSURL URLWithString:[NSString stringWithFormat:@"filza://%@", enc]];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end

@implementation DIMaterialsController
- (NSInteger)matMode { return 0; }
@end

@implementation DIMaterialsSmall
- (NSInteger)matMode { return 0; }
@end

@implementation DIMaterialsExpand
- (NSInteger)matMode { return 1; }
@end

@implementation DIFrameFolders

/* 偏好键: 基类=展开岛音频动画素材(animFolder), 子类=歌词岛左侧(smallAnimFolder)/右侧(miniAudioFolder) */
- (NSString *)prefKey { return @"animFolder"; }

- (void)saveFolder:(NSString *)name {
    CFPreferencesSetAppValue((__bridge CFStringRef)[self prefKey], (__bridge CFPropertyListRef)name, (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kNotifyStr, NULL, NULL, YES);
}

/* 2.6.4: 素材根目录 —— 默认帧率素材; 遮罩素材选择页覆写为遮罩素材目录 */
- (NSString *)rootDir { return kFrameDir; }

- (NSArray<NSString *> *)folders {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *out = [NSMutableArray array];
    BOOL hasDirectFrame = NO;
    for (NSString *n in [fm contentsOfDirectoryAtPath:[self rootDir] error:NULL]) {
        NSString *p = [[self rootDir] stringByAppendingPathComponent:n];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&isDir]) continue;
        if (isDir) [out addObject:n];
        else {
            NSString *ext = n.pathExtension.lowercaseString;
            if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) hasDirectFrame = YES;
        }
    }
    /* 2.6.11: 同上, 避开 __NSCFString 抛 selector */
    out = [diSortStrs(out) mutableCopy];
    if (hasDirectFrame || out.count == 0) [out insertObject:@"默认(全部帧)" atIndex:0];
    return out;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *g = [PSSpecifier preferenceSpecifierNamed:@"选择素材" target:nil
            set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
        [g setProperty:[NSString stringWithFormat:@"点击选择素材文件夹。素材目录: %@", [self rootDir]] forKey:@"footerText"];
        [specs addObject:g];
        NSString *cur = nil;
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)[self prefKey], (__bridge CFStringRef)kDomain));
        if ([v isKindOfClass:NSString.class]) cur = v;
        for (NSString *f in [self folders]) {
            BOOL isCur = cur ? [f isEqualToString:cur] : [f isEqualToString:@"默认(全部帧)"];
            NSString *label = isCur ? [NSString stringWithFormat:@"✓ %@", f] : f;
            PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label target:self
                set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
            [s setButtonAction:@selector(pick:)];
            [s setProperty:f forKey:@"folder"];
            [specs addObject:s];
        }
        _specifiers = specs;
    }
    return _specifiers;
}

- (void)pick:(PSSpecifier *)spec {
    NSString *f = [spec propertyForKey:@"folder"];
    [self saveFolder:[f isEqualToString:@"默认(全部帧)"] ? nil : f];
    NSArray *vcs = self.navigationController.viewControllers;
    UIViewController *parent = (vcs.count >= 2) ? vcs[vcs.count - 2] : nil;
    [self.navigationController popViewControllerAnimated:YES];
    if ([parent respondsToSelector:@selector(reloadSpecifiers)])
        [(id)parent performSelector:@selector(reloadSpecifiers)];
}

- (void)reloadSpecifiers {
    _specifiers = nil;
    [super reloadSpecifiers];
}

@end

#pragma mark - 素材预览网格

static NSCache *diThumbCache(void) {
    static NSCache *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [NSCache new]; c.countLimit = 60; });
    return c;
}

@interface DIPreviewCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iv;
@property (nonatomic, strong) UILabel *lb;
@end
@implementation DIPreviewCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _iv = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height - 20)];
        _iv.contentMode = UIViewContentModeScaleAspectFill;
        _iv.clipsToBounds = YES;
        _iv.layer.cornerRadius = 12;
        _iv.backgroundColor = [UIColor tertiarySystemFillColor];
        _iv.translatesAutoresizingMaskIntoConstraints = NO;
        _lb = [[UILabel alloc] initWithFrame:CGRectZero];
        _lb.font = [UIFont systemFontOfSize:11];
        _lb.textAlignment = NSTextAlignmentCenter;
        _lb.textColor = [UIColor secondaryLabelColor];
        _lb.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_iv];
        [self.contentView addSubview:_lb];
        [NSLayoutConstraint activateConstraints:@[
            [_iv.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_iv.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_iv.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_iv.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-20],
            [_lb.topAnchor constraintEqualToAnchor:_iv.bottomAnchor constant:2],
            [_lb.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_lb.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        ]];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = 0;
    if (self.highlighted) self.contentView.alpha = 0.6; else self.contentView.alpha = 1;
}
@end

@interface DIPreviewGrid : UICollectionViewController
@property (nonatomic, assign) NSInteger matMode; /* 0=小岛 1=展开 3=壁纸更换(2.7.32 起只有一套) */
+ (void)diRefreshHostingList;   /* 2.2.58: 选完素材后让主页那一行立刻刷新 */
/* 2.7.1: 分类 Import 里要用到这些, 先声明一次 */
- (BOOL)isWallpaperMode;
- (NSString *)dirForMode;
- (NSString *)keyForMode;
- (NSArray<NSString *> *)filesForMode;
@end

@implementation DIPreviewGrid
/* 素材目录与偏好键按模式取 —— 小岛/展开共用主目录 */
- (BOOL)isWallpaperMode { return (self.matMode == 3); }   /* 2.7.32: 深色(mode 4)已删除 */
- (NSString *)dirForMode {
    if (self.isWallpaperMode) return kDIWallpaperRoot;
    return kMaterialDir;
}
- (NSString *)keyForMode {
    if (self.matMode == 0) return @"smallIndex";
    if (self.matMode == 3) return @"wpLightAsset";   /* 2.7.1: 壁纸存的是相对路径字符串, 不是序号 */
    return @"expandIndex";
}
- (NSArray<NSString *> *)filesForMode {
    if (self.isWallpaperMode) return diWallpaperFiles();
    return videoFilesIn([self dirForMode]);
}
- (instancetype)init {
    UICollectionViewFlowLayout *fl = [UICollectionViewFlowLayout new];
    CGFloat w = [UIScreen mainScreen].bounds.size.width - 32;
    fl.itemSize = CGSizeMake((w - 12) / 3, (w - 12) / 3 * 0.72 + 22);
    fl.minimumInteritemSpacing = 6;
    fl.minimumLineSpacing = 14;
    fl.sectionInset = UIEdgeInsetsMake(12, 16, 24, 16);
    return [super initWithCollectionViewLayout:fl];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    /* 2.2.30: 确保滑杆排版已装进 PSSliderCell(尽早装, 免得第一屏还是旧样式) */
    diInstallStepSliderOnPSSliderCell();
    /* 2.7.32: 深浅两套合并, mode 4(深色背景)整体删除 */
    self.title = (self.matMode == 0) ? @"小岛素材"
               : (self.matMode == 3 ? @"壁纸更换" : @"展开素材");
    self.collectionView.backgroundColor = DI_PAGE_BG;
    [self.collectionView registerClass:[DIPreviewCell class] forCellWithReuseIdentifier:@"cell"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"相册导入" style:UIBarButtonItemStylePlain target:self action:NSSelectorFromString(@"diImportFromAlbumWP")]; // 右上角相册导入(支持图片, 实现在分类里)
    /* 2.7.31: 左侧不再设按钮 —— push 二进页自带系统"‹"返回箭头 + 左滑返回。
       上一版这里设了"关闭"(dismiss), 会盖掉系统返回箭头, push 后就回不去了。 */
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressDelete:)]; // 长按删除素材
    [self.collectionView addGestureRecognizer:lp];
}
/* 长按视频缩略图 → 确认后删除该素材文件; 若删的是当前选中项, 选中归零并通知岛重载 */
- (void)longPressDelete:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [gr locationInView:self.collectionView];
    NSIndexPath *ip = [self.collectionView indexPathForItemAtPoint:p];
    if (!ip || ip.item >= (NSInteger)[self filesForMode].count) return;
    NSString *name = [self filesForMode][ip.item];
    NSString *path = [[self dirForMode] stringByAppendingPathComponent:name];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除素材"
        message:[NSString stringWithFormat:@"确定删除 \"%@\" 吗?\n此操作不可恢复", name]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        NSString *key = [self keyForMode];
        id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
        BOOL hitCur = self.isWallpaperMode ? ([v isKindOfClass:NSString.class] && [v isEqualToString:name])
                                           : (v && [v integerValue] == (NSInteger)ip.item);
        if (hitCur) { // 删的是当前选中项 → 归零并刷新
            CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@0, (__bridge CFStringRef)kDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            postReload();
        }
        [self.collectionView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)close {   /* 2.7.31: push 页用 pop 返回(兼容万一被 present 的场合) */
    if (self.navigationController && self.navigationController.viewControllers.count > 1)
        [self.navigationController popViewControllerAnimated:YES];
    else
        [self dismissViewControllerAnimated:YES completion:nil];
}
- (NSInteger)currentIndex {
    if (self.isWallpaperMode) return -1;   /* 壁纸按字符串匹配, 不用序号 */
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)[self keyForMode], (__bridge CFStringRef)kDomain));
    return v ? [v integerValue] : 0;
}

/* 2.7.1: 壁纸模式 —— 判断某一项是不是当前选中 */
- (BOOL)isSelectedName:(NSString *)name atIndex:(NSInteger)idx {
    if (!self.isWallpaperMode) return (idx == [self currentIndex]);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)[self keyForMode], (__bridge CFStringRef)kDomain));
    return [v isKindOfClass:NSString.class] && [v isEqualToString:name];
}
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)[self filesForMode].count;
}
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    DIPreviewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:ip];
    if (ip.item >= (NSInteger)[self filesForMode].count) return cell;
    NSString *name = [self filesForMode][ip.item];
    BOOL sel = [self isSelectedName:name atIndex:ip.item];
    cell.lb.text = name;
    cell.lb.textColor = sel ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];
    cell.iv.layer.borderWidth = sel ? 2 : 0;
    cell.iv.layer.borderColor = [UIColor systemBlueColor].CGColor;
    NSString *absPath = [[self dirForMode] stringByAppendingPathComponent:name];
    UIImage *thumb = [diThumbCache() objectForKey:absPath];
    if (thumb) { cell.iv.image = thumb; }
    else if (self.isWallpaperMode && !diWallpaperIsVideoName(name)) {
        /* 2.7.1: 壁纸图片 —— 直接按缩略尺寸解码, 别整张读进内存 */
        cell.iv.image = nil;
        __weak DIPreviewCell *wc = cell;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            UIImage *ui = nil;
            CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:absPath], NULL);
            if (src) {
                NSDictionary *opts = @{(__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                       (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @360,
                                       (__bridge id)kCGImageSourceCreateThumbnailWithTransform: @YES};
                CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
                if (cg) { ui = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
                CFRelease(src);
            }
            if (ui) [diThumbCache() setObject:ui forKey:absPath];
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([wc.lb.text isEqualToString:name]) wc.iv.image = ui;
            });
        });
    }
    else {
        cell.iv.image = nil;
        __weak DIPreviewCell *wc = cell;
        __weak UICollectionView *wcv = cv;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[[self dirForMode] stringByAppendingPathComponent:name]] options:nil];
            AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
            gen.appliesPreferredTrackTransform = YES;
            gen.maximumSize = CGSizeMake(360, 360);
            NSError *err = nil;
            CGImageRef img = [gen copyCGImageAtTime:CMTimeMake(5, 10) actualTime:NULL error:&err];
            if (img) {
                UIImage *ui = [UIImage imageWithCGImage:img];
                CGImageRelease(img);
                [diThumbCache() setObject:ui forKey:absPath];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([wc.lb.text isEqualToString:name]) wc.iv.image = ui;
                    [wcv reloadItemsAtIndexPaths:@[ip]];
                });
            }
        });
    }
    return cell;
}
- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    NSString *key = [self keyForMode];
    if (self.isWallpaperMode) {
        /* 2.7.1: 壁纸存相对路径字符串; 选中即铺满, 没有其它参数 */
        NSString *name = [self filesForMode][ip.item];
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)name, (__bridge CFStringRef)kDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.abgg332.driftisland/prefsChanged"), NULL, NULL, YES);
        [cv reloadData];
        [self close];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [DIPreviewGrid diRefreshHostingList]; });
        return;
    }
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(ip.item), (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    diGridPicked = YES;
    postReload();
    /* 2.2.58: 选完要让"素材选择"那一行**立刻**显示新素材名。
       原来只置 diGridPicked 就 close —— 但网格是 PageSheet 模态,
       主页 cell 不会重新走 willDisplayCell, 只有等返回/重进才刷新(用户 141 反馈)。
       这里关掉弹窗后主动找到主页并 reloadSpecifiers + 重绘可见 cell。 */
    __weak typeof(self) weakSelf = self;
    [self close];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        (void)weakSelf;
        [DIPreviewGrid diRefreshHostingList];
    });
}

/* 2.2.58: 找到当前屏幕上的主页 PSListController, 强制它重建 specifier 并重绘表格,
   这样"素材选择"行右侧的名字会在选完立即可见(不用退出再进)。 */
+ (void)diRefreshHostingList {
    /* 从所有 scene 的窗口根控制器出发, 广度找第一个非素材页的 PSListController。
       用 KVC/selector 取窗口, 绕开 keyWindow/windows 的弃用告警 */
    NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
    id app = (id)UIApplication.sharedApplication;
    NSArray *scenes = [app respondsToSelector:@selector(connectedScenes)]
                    ? ((NSArray *(*)(id, SEL))objc_msgSend)(app, @selector(connectedScenes)) : nil;
    for (id sc in scenes) {
        if (![sc respondsToSelector:@selector(windows)]) continue;
        NSArray *wins = ((NSArray *(*)(id, SEL))objc_msgSend)(sc, @selector(windows));
        for (id w in wins) {
            id root = ((id (*)(id, SEL))objc_msgSend)(w, @selector(rootViewController));
            if (root) [queue addObject:root];
        }
    }
    PSListController *target = nil;
    NSInteger guard = 0;
    while (queue.count && guard++ < 200) {
        UIViewController *vc = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([vc isKindOfClass:NSClassFromString(@"PSListController")]
            && ![vc isKindOfClass:[DIMaterialsController class]]) {
            target = (PSListController *)vc;
            break;
        }
        [queue addObjectsFromArray:vc.childViewControllers];
        if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
    }
    if (!target) return;
    [target reloadSpecifiers];
    /* reloadSpecifiers 只重建数据, 屏幕上的 cell 要再刷一次才会显示新文字 */
    UITableView *tv = [target valueForKey:@"table"];
    if (![tv isKindOfClass:UITableView.class]) {
        for (UIView *sv in target.view.subviews) {
            if ([sv isKindOfClass:UITableView.class]) { tv = (UITableView *)sv; break; }
        }
    }
    if (tv) [tv reloadData];
}
@end

@implementation DIMaterialsController (Internal)

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        NSInteger cnt = (NSInteger)videoFiles().count;
        (void)cnt;
        NSString *title = (self.matMode == 0) ? @"小岛素材" : @"展开素材";
        [specs addObject:[self groupSpec:title footer:@"进入本页会自动弹出预览网格; 点选封面即生效。素材目录: /var/mobile/灵动岛"]];
        PSSpecifier *btn = [PSSpecifier preferenceSpecifierNamed:@"重新打开预览" target:self
            set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
        [btn setButtonAction:@selector(openGrid:)];
        [specs addObject:btn];
        _specifiers = specs;
    }
    return _specifiers;
}

- (PSSpecifier *)groupSpec:(NSString *)header footer:(NSString *)footer {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:header target:nil
        set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
    if (footer) [s setProperty:footer forKey:@"footerText"];
    return s;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    objc_setAssociatedObject(self, "diShown", @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // 每次进入重置, 自动弹出预览
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if ([objc_getAssociatedObject(self, "diShown") boolValue]) return;
    objc_setAssociatedObject(self, "diShown", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    DIPreviewGrid *g = [[DIPreviewGrid alloc] init];
    g.matMode = self.matMode;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:g];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil]; // 进入页面立即弹出平铺预览(模态弹窗不动 PSListController 视图结构, 不会闪退)
}

- (void)reloadSpecifiers {
    _specifiers = nil;
    [super reloadSpecifiers];
}

@end



/* 点击"素材选择"直接弹出平铺预览网格(不进二级页) */
/* ===== 2.6.23: 四个子页面(纯排版迁移, 键值与行为零改动) ===== */

/* 小岛设置: 原有开关+素材选择, 文字样式, 隐藏小岛(通知背景之后), 歌词岛(最后) */
/* 锁屏设置: 锁屏通知全部功能(键值零改动) */
/* ===== 2.6.30: 底栏横条页 =====
   从"锁屏通知"里抽出来单独成页(用户: 直接叫底栏横条, 不用自定义)。
   键值全部沿用: homeBarOn / homeBarLen / homeBarHexes / homeBarMode / homeBarFlowOn /
   homeBarFlowDir / homeBarHideOn / homeBarHideFade。功能一个没少。 */
/* ===== 2.6.29: 文字颜色页 =====
   原主页"文字样式"组的全部内容原样搬进来: 文字颜色开关 / 字体颜色 / 流光动态 /
   预览文字效果 / 通知背景。键值完全不变(notifyColorOn / notifyFlowOn / notifyBgOff)。 */
@implementation DITextStylePage
- (NSArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    [specs addObject:[self groupSpec:@"文字样式" footer:nil]];
    [specs addObject:[self switchSpec:@"文字颜色" key:@"notifyColorOn" def:@NO]];
    {
        PSSpecifier *gradRow = [self buttonSpec:@"字体颜色" action:@selector(diOpenGradientPanel:)];
        [gradRow setProperty:@"gradient" forKey:@"diKind"];
        [specs addObject:gradRow];
    }
    [specs addObject:[self switchSpec:@"流光动态" key:@"notifyFlowOn" def:@NO]];
    {
        PSSpecifier *prev = [PSSpecifier preferenceSpecifierNamed:@"预览文字效果" target:self
            set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
        [prev setButtonAction:@selector(diPreviewTapped:)];
        [specs addObject:prev];
    }
    [specs addObject:[self switchSpec:@"通知背景" key:@"notifyBgOff" def:@NO]];
    return specs;
}
/* 字体颜色走独立窗口面板(定义在文件后部), 与主页原来的入口完全一致 */
- (void)diOpenGradientPanel:(PSSpecifier *)spec { diOpenGradientPanelWindow(); }
/* 预览: 通过 Darwin 通知让 SpringBoard 弹示范岛(与主页同一机制) */
- (void)diPreviewTapped:(PSSpecifier *)spec {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.abgg332.driftisland.preview"), NULL, NULL, true);
}
@end

@implementation DILockScreenPage
/* 2.6.28: 与歌词岛同一形态 —— buildSpecifiers + 自己的工具方法, 键值零改动。
   之前闪退是因为继承 DIPrefsController(rootController + Darwin 通知), 换成
   DIMiniBaseController(纯 PSListController)后与歌词岛完全同构。 */
- (NSArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    /* 2.8.12: 整页统一为一个"锁屏通知"组 —— 原"通知/播放器发光"整组并入,
       开关改名"背景发光", 所有功能排在锁屏定义之下, 显示统一 */
    [specs addObject:[self groupSpec:@"锁屏通知" footer:nil]];
    [specs addObject:[self switchSpec:@"锁屏定义" key:@"lockWOn" def:@NO]];
    if ([[self readPreferenceValue:[self switchSpec:@"锁屏定义" key:@"lockWOn" def:@NO]] boolValue]) {
        [specs addObject:[self numSlider:@"宽度" key:@"lockWPercent" def:100 mn:50 mx:100]];
    }
    /* 2.8.12: 背景发光(原 2.8.8"通知/播放器发光", 整组并入锁屏通知组) */
    [specs addObject:[self switchSpec:@"背景发光" key:@"lkGlowOn" def:@NO]];
    if ([[self readPreferenceValue:[self switchSpec:@"背景发光" key:@"lkGlowOn" def:@NO]] boolValue]) {
        [specs addObject:[self numSlider:@"发光半径" key:@"lkGlowR" def:8 mn:0 mx:24]];
        {
            PSSpecifier *btn = [PSSpecifier preferenceSpecifierNamed:@"发光颜色" target:self
                set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
            [btn setButtonAction:@selector(diOpenGlowPick:)];
            [specs addObject:btn];
        }
    }
    /* 2.8.35: 背景边框(锁屏所有通知加一圈边框, 宽度/颜色自定义) */
    [specs addObject:[self switchSpec:@"背景边框" key:@"lkFrameOn" def:@NO]];
    if ([[self readPreferenceValue:[self switchSpec:@"背景边框" key:@"lkFrameOn" def:@NO]] boolValue]) {
        [specs addObject:[self numSlider:@"边框宽度" key:@"lkFrameW" def:3 mn:0 mx:12]];
        {
            PSSpecifier *btn = [PSSpecifier preferenceSpecifierNamed:@"边框颜色" target:self
                set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
            [btn setButtonAction:@selector(diOpenFramePick:)];
            [specs addObject:btn];
        }
    }
    /* 2.6.31: 底栏横条全部功能回归锁屏通知页(用户要求: 不要单独一页) */
    [specs addObject:[self switchSpec:@"底栏横条" key:@"homeBarOn" def:@NO]];
    if ([[self readPreferenceValue:[self switchSpec:@"底栏横条" key:@"homeBarOn" def:@NO]] boolValue]) {
        [specs addObject:[self numSlider:@"横条长短" key:@"homeBarLen" def:100 mn:10 mx:200]];
        {
            PSSpecifier *btn = [PSSpecifier preferenceSpecifierNamed:@"横条颜色" target:self
                set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
            [btn setButtonAction:@selector(diOpenHomeBarPick:)];
            [specs addObject:btn];
        }
        [specs addObject:[self switchSpec:@"流光动态" key:@"homeBarFlowOn" def:@NO]];
        {
            PSSpecifier *btn = [PSSpecifier preferenceSpecifierNamed:@"流光方向" target:self
                set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
            [btn setButtonAction:@selector(diPickHomeBarFlowDir:)];
            [specs addObject:btn];
        }
    }
    [specs addObject:[self switchSpec:@"隐藏底部横条" key:@"homeBarHideOn" def:@NO]];
    if ([[self readPreferenceValue:[self switchSpec:@"隐藏底部横条" key:@"homeBarHideOn" def:@NO]] boolValue]) {
        [specs addObject:[self switchSpec:@"渐变隐藏" key:@"homeBarHideFade" def:@NO]];
    }
    [specs addObject:[self switchSpec:@"启用手势保护" key:@"gestureProtectOn" def:@NO]];
    {
        PSSpecifier *last = specs.lastObject;
        NSString *old = [last propertyForKey:@"footerText"];
        [last setProperty:[NSString stringWithFormat:@"%@\n启用手势保护: ① 上滑需二次确认才退出; ② 横屏静置 2 秒后横条自动彻底隐藏, 随意滑动一下即可重新显示。", old ?: @""]
                   forKey:@"footerText"];
    }
    return specs;
}
/* 横条配色 / 流光方向: 两个都是独立窗口, 直接开(与 HOME 面板同一入口) */
- (void)diOpenHomeBarPick:(PSSpecifier *)spec { diOpenHomeBarPickWindow(); }
- (void)diPickHomeBarFlowDir:(PSSpecifier *)spec {
    NSInteger cur = 0;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id cv = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("homeBarFlowDir"), (__bridge CFStringRef)kDomain));
    if (cv) cur = [cv integerValue];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"流光方向"
        message:@"横条流光颜色的流动方式(需先开启流光动态)" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *names = @[@"左→右", @"右→左", @"中间向两边散开", @"两边向中间收紧"];
    for (NSUInteger i = 0; i < names.count; i++) {
        [a addAction:[UIAlertAction actionWithTitle:[names[i] stringByAppendingString:(i == (NSUInteger)cur ? @" ✓" : @"")]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            CFPreferencesSetAppValue(CFSTR("homeBarFlowDir"), (__bridge CFPropertyListRef)(@((NSInteger)i)), (__bridge CFStringRef)kDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            postReload();
            _specifiers = nil; [self reloadSpecifiers];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}
/* 2.8.36: 发光/边框颜色统一走 DIColorPick 预设面板(内置多彩 + 自定义) */
- (void)diOpenGlowPick:(PSSpecifier *)spec {
    [self diOpenColorPickForKey:@"lkGlowHex" title:@"发光颜色"];
}
- (void)diOpenFramePick:(PSSpecifier *)spec {
    [self diOpenColorPickForKey:@"lkFrameHex" title:@"边框颜色"];
}
/* DIColorPick 实现在文件后部, 这里走运行时查找 + KVC 设键, 不依赖类型可见性 */
- (void)diOpenColorPickForKey:(NSString *)key title:(NSString *)title {
    @try {
        Class cls = NSClassFromString(@"DIColorPick");
        if (!cls) { diStep(@"配色: 类缺失"); return; }
        UIViewController *vc = [[cls alloc] initWithNibName:nil bundle:nil];
        [vc setValue:key forKey:@"prefKey"];
        diPushPanel(vc, title, nil);
    } @catch (NSException *e) {
        diStep(@"配色: 打开失败 %@", e.reason ?: @"(未知)");
    }
}
/* 发光颜色: 预设 + 自定义(多色逗号分隔, 呼吸轮换) */
- (void)diPickGlowColor:(PSSpecifier *)spec {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    NSString *cur = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("lkGlowHex"), (__bridge CFStringRef)kDomain)) ?: @"";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"发光颜色"
        message:@"选预设, 或自定义输入十六进制色值;\n多个色值用逗号分隔(如 00AEFF,B570E3)即为多色呼吸" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *names = @[@"天蓝", @"紫", @"金", @"青绿", @"白", @"粉", @"多彩呼吸", @"自定义…"];
    NSArray *hexes = @[@"00AEFF", @"B570E3", @"FFD700", @"00FF87", @"FFFFFF", @"FF5FA2",
                       @"00AEFF,B570E3,FFD700,00FF87", @""];
    for (NSUInteger i = 0; i < names.count; i++) {
        BOOL isCur = ((NSString *)hexes[i]).length && [((NSString *)hexes[i]) isEqualToString:cur.uppercaseString];
        [a addAction:[UIAlertAction actionWithTitle:[names[i] stringByAppendingString:(isCur ? @" ✓" : @"")]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            if (i == names.count - 1) { [self diPickGlowCustom]; return; }
            CFPreferencesSetAppValue(CFSTR("lkGlowHex"), (__bridge CFPropertyListRef)hexes[i], (__bridge CFStringRef)kDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            postReload();
            _specifiers = nil; [self reloadSpecifiers];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}
/* 自定义发光色: 输入框收十六进制(支持 # 前缀与多色逗号) */
- (void)diPickGlowCustom {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"自定义发光颜色"
        message:@"填十六进制色值, 如 00AEFF;\n多个色值用逗号分隔即为多色呼吸" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        NSString *cur = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("lkGlowHex"), (__bridge CFStringRef)kDomain));
        tf.text = cur ?: @"00AEFF";
        tf.placeholder = @"00AEFF";
        tf.keyboardType = UIKeyboardTypeASCIICapable;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *hex = a.textFields.firstObject.text ?: @"";
        hex = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (hex.length) {
            CFPreferencesSetAppValue(CFSTR("lkGlowHex"), (__bridge CFPropertyListRef)hex.uppercaseString, (__bridge CFStringRef)kDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            postReload();
        }
        _specifiers = nil; [self reloadSpecifiers];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
/* 2.8.35: 边框颜色: 预设 + 自定义(与发光颜色同一套交互, 键改 lkFrameHex) */
- (void)diPickFrameColor:(PSSpecifier *)spec {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    NSString *cur = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("lkFrameHex"), (__bridge CFStringRef)kDomain)) ?: @"";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"边框颜色"
        message:@"选预设, 或自定义输入十六进制色值;\n多个色值用逗号分隔(如 00AEFF,B570E3)即为多色呼吸" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *names = @[@"天蓝", @"紫", @"金", @"青绿", @"白", @"粉", @"多彩呼吸", @"自定义…"];
    NSArray *hexes = @[@"00AEFF", @"B570E3", @"FFD700", @"00FF87", @"FFFFFF", @"FF5FA2",
                       @"00AEFF,B570E3,FFD700,00FF87", @""];
    for (NSUInteger i = 0; i < names.count; i++) {
        BOOL isCur = ((NSString *)hexes[i]).length && [((NSString *)hexes[i]) isEqualToString:cur.uppercaseString];
        [a addAction:[UIAlertAction actionWithTitle:[names[i] stringByAppendingString:(isCur ? @" ✓" : @"")]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            if (i == names.count - 1) { [self diPickFrameCustom]; return; }
            CFPreferencesSetAppValue(CFSTR("lkFrameHex"), (__bridge CFPropertyListRef)hexes[i], (__bridge CFStringRef)kDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            postReload();
            _specifiers = nil; [self reloadSpecifiers];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}
/* 自定义边框色: 输入框收十六进制(支持 # 前缀与多色逗号) */
- (void)diPickFrameCustom {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"自定义边框颜色"
        message:@"填十六进制色值, 如 00AEFF;\n多个色值用逗号分隔即为多色呼吸" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        NSString *cur = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("lkFrameHex"), (__bridge CFStringRef)kDomain));
        tf.text = cur ?: @"00AEFF";
        tf.placeholder = @"00AEFF";
        tf.keyboardType = UIKeyboardTypeASCIICapable;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *hex = a.textFields.firstObject.text ?: @"";
        hex = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (hex.length) {
            CFPreferencesSetAppValue(CFSTR("lkFrameHex"), (__bridge CFPropertyListRef)hex.uppercaseString, (__bridge CFStringRef)kDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            postReload();
        }
        _specifiers = nil; [self reloadSpecifiers];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end



@implementation DIPrefsController (Grid)
- (void)presentGridMode:(NSInteger)mode {
    DIPreviewGrid *g = [[DIPreviewGrid alloc] init];
    g.matMode = mode;
    /* 2.7.30: 从 pageSheet 模态改成 **push 二进页面** —— 和"浅色/深色背景"选择页
       同一形态: 左上角自动是系统"‹"返回, 支持左滑返回, 不再盖在页面上。 */
    g.navigationItem.leftBarButtonItem = nil;   /* 左侧交给系统返回箭头 */
    [self.navigationController pushViewController:g animated:YES];
}
- (void)openSmallGrid:(PSSpecifier *)s { [self presentGridMode:0]; }
- (void)openExpandGrid:(PSSpecifier *)s { [self presentGridMode:1]; }
/* 相册素材导入: PHPicker(系统相册选择器, 无需相册权限)选视频, 拷入素材目录 */
- (void)importFromAlbum {
    Class phpPicker = NSClassFromString(@"PHPickerViewController");
    Class phpCfg = NSClassFromString(@"PHPickerConfiguration");
    if (!phpPicker || !phpCfg) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"相册导入" message:@"当前系统不可用(PHPicker 需要 iOS 14+)" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    id cfg = [[phpCfg alloc] init];
    Class f = NSClassFromString(@"PHPickerFilter");
    if ([cfg respondsToSelector:@selector(setFilter:)] && [f respondsToSelector:@selector(videosFilter)])
        [cfg performSelector:@selector(setFilter:) withObject:((id (*)(id, SEL))objc_msgSend)(f, @selector(videosFilter))]; // 只显示视频
    if ([cfg respondsToSelector:@selector(setSelectionLimit:)])
        [cfg performSelector:@selector(setSelectionLimit:) withObject:@0]; // 0=不限制, 多选多导
    id p = [[phpPicker alloc] initWithConfiguration:cfg];
    if ([p respondsToSelector:@selector(setDelegate:)]) [p performSelector:@selector(setDelegate:) withObject:self];
    [self presentViewController:p animated:YES completion:nil];
}

- (void)picker:(id)picker didFinishPicking:(NSArray *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kMaterialDir withIntermediateDirectories:YES attributes:nil error:nil];
    __block NSInteger okCnt = 0, failCnt = 0;
    __block NSString *firstNew = nil;
    dispatch_group_t grp = dispatch_group_create();
    for (id r in results) {
        id provider = [r valueForKey:@"itemProvider"];
        NSString *sugg = [provider respondsToSelector:@selector(suggestedName)] ? [provider performSelector:@selector(suggestedName)] : nil;
        dispatch_group_enter(grp);
        [provider loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *err) {
            if (url) {
                NSString *ext = url.pathExtension.length ? url.pathExtension : @"mov";
                NSString *base = @"相册导入";
                if (sugg.length) {
                    base = sugg.pathExtension.length ? sugg.stringByDeletingPathExtension : sugg;
                    base = [base stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
                }
                NSString *name = [NSString stringWithFormat:@"%@.%@", base, ext];
                NSString *dst = [kMaterialDir stringByAppendingPathComponent:name];
                NSInteger n = 1;
                while ([fm fileExistsAtPath:dst]) { // 重名自动加序号
                    name = [NSString stringWithFormat:@"%@_%ld.%@", base, (long)n++, ext];
                    dst = [kMaterialDir stringByAppendingPathComponent:name];
                }
                NSError *cpErr = nil;
                if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:&cpErr]) {
                    okCnt++;
                    if (!firstNew) firstNew = name;
                } else failCnt++;
            } else failCnt++;
            dispatch_group_leave(grp);
        }];
    }
    dispatch_group_notify(grp, dispatch_get_main_queue(), ^{
        NSString *msg;
        if (failCnt > 0) msg = [NSString stringWithFormat:@"成功 %ld 个, 失败 %ld 个", (long)okCnt, (long)failCnt];
        else if (okCnt == 1) msg = [NSString stringWithFormat:@"已导入: %@", firstNew];
        else msg = [NSString stringWithFormat:@"已导入 %ld 个素材", (long)okCnt];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"相册素材导入" message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    });
}
@end

/* 素材预览网格页(小岛/展开)的相册导入: 同一套 PHPicker 逻辑, 导入完成后自动刷新网格 */
/* 2.7.1: 壁纸/素材的相册导入 delegate —— 单独一个对象。
   为什么不用 DIPreviewGrid 自己当 delegate:
   同一个文件里 DIPrefsController(Grid) 已经实现过 picker:didFinishPicking:,
   两个分类同名方法会被 linker 当成"覆盖", 运行时到底走哪份不确定(会静默导到错目录)。
   用独立类各自持有自己的实现, 彻底隔离。 */
@interface DIAlbumImporter : NSObject
@property (nonatomic, strong) UICollectionView *grid;   /* 导入完刷这个网格 */
@property (nonatomic, copy) NSString *dir;              /* 落盘目录 */
@property (nonatomic, assign) BOOL allowImage;          /* YES = 图片和视频都收(壁纸) */
@property (nonatomic, assign) BOOL wallpaperMode;       /* 壁纸: 选中写的键是字符串 */
@property (nonatomic, copy) NSString *prefKey;
- (void)finishImportWithResults:(NSArray *)results;
@end

@implementation DIAlbumImporter

- (void)openPickerFrom:(UIViewController *)vc {
    Class phpPicker = NSClassFromString(@"PHPickerViewController");
    Class phpCfg = NSClassFromString(@"PHPickerConfiguration");
    if (!phpPicker || !phpCfg) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"相册导入"
            message:@"当前系统不可用(PHPicker 需要 iOS 14+)" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
        return;
    }
    id cfg = [[phpCfg alloc] init];
    Class f = NSClassFromString(@"PHPickerFilter");
    if ([cfg respondsToSelector:@selector(setFilter:)] && f) {
        id filter = nil;
        if (self.allowImage && [f respondsToSelector:@selector(anyFilter)]) {
            filter = ((id (*)(id, SEL))objc_msgSend)(f, @selector(anyFilter));      /* 图片+视频 */
        } else if ([f respondsToSelector:@selector(videosFilter)]) {
            filter = ((id (*)(id, SEL))objc_msgSend)(f, @selector(videosFilter));   /* 只有视频 */
        }
        if (filter) [cfg performSelector:@selector(setFilter:) withObject:filter];
    }
    if ([cfg respondsToSelector:@selector(setSelectionLimit:)])
        [cfg performSelector:@selector(setSelectionLimit:) withObject:@0];          /* 0=多选 */
    id p = [[phpPicker alloc] initWithConfiguration:cfg];
    if ([p respondsToSelector:@selector(setDelegate:)]) [p performSelector:@selector(setDelegate:) withObject:self];
    /* picker 自己会持有 delegate(weak?) —— 用关联对象挂在 vc 上, 保证活到回调结束 */
    objc_setAssociatedObject(vc, "diAlbumImporter", self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [vc presentViewController:p animated:YES completion:nil];
}

/* 单个 provider → 落地文件名; 失败回调 nil */
- (void)copyProvider:(id)provider suggested:(NSString *)sugg isImage:(BOOL)isImage
                done:(void (^)(NSString *saved))done {
    NSFileManager *fm = [NSFileManager defaultManager];
    /* 2.7.30: 目录权限显式 0777 —— 之前 attributes:nil 建出来的目录可能没有写权限,
       拷贝文件静默失败, 表现就是"选完确定, 素材没进来"(用户本次报的导入失效)。 */
    [fm createDirectoryAtPath:self.dir withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions: @0777} error:NULL];
    void (^finish)(NSString *) = ^(NSString *saved) {
        dispatch_async(dispatch_get_main_queue(), ^{
            diStep(@"[相册导入] 落地%@: %@ (目录 %@)", saved ? @"成功" : @"失败", saved ?: @"nil", self.dir);
            if (done) done(saved);
        });
    };
    NSString *typeId = isImage ? @"public.image" : @"public.movie";
    diStep(@"[相册导入] 开始取文件: %@ 类型=%@ 建议=%@", self.dir.lastPathComponent, typeId, sugg ?: @"(无)");
    [provider loadFileRepresentationForTypeIdentifier:typeId completionHandler:^(NSURL *url, NSError *err) {
        if (!url) {
            diStep(@"[相册导入] 系统没给出文件(loadFileRepresentation 失败): %@", err.localizedDescription ?: @"(无错误信息)");
            finish(nil);
            return;
        }
        NSString *ext = url.pathExtension.length ? url.pathExtension.lowercaseString : (isImage ? @"png" : @"mov");
        BOOL needConv = isImage && !([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] ||
                                     [ext isEqualToString:@"jpeg"]);
        NSString *base = sugg.length ? sugg.stringByDeletingPathExtension : @"相册导入";
        base = [base stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        if (base.length > 60) base = [base substringToIndex:60];
        if (needConv) {
            /* 相册里多数是 HEIC —— 统一转码。JPEG 优先(兼容好/体积小), 转不动再试 PNG,
               都不行就原样落盘(至少文件在, 用户能看到为什么没出现在网格里)。 */
            NSData *d = [NSData dataWithContentsOfURL:url];
            UIImage *im = d ? [UIImage imageWithData:d] : nil;
            NSData *out = nil;
            NSString *oext = @"jpg";
            if (im) {
                out = UIImageJPEGRepresentation(im, 0.92);
                if (!out) { out = UIImagePNGRepresentation(im); oext = @"png"; }
            }
            if (out) {
                NSString *name = [NSString stringWithFormat:@"%@.%@", base, oext];
                NSString *dst = [self.dir stringByAppendingPathComponent:name];
                NSInteger n = 1;
                while ([fm fileExistsAtPath:dst])
                    name = [NSString stringWithFormat:@"%@_%ld.%@", base, (long)n++, oext],
                    dst = [self.dir stringByAppendingPathComponent:name];
                finish([out writeToFile:dst atomically:YES] ? name : nil);
                return;
            }
            /* 转码失败: 直接把原文件拷进去(HEIC 网格不认, 但总比静默丢掉好, 日志里有交待) */
            diStep(@"[相册导入] 图片转码失败, 原样拷贝: %@", url.lastPathComponent);
        }
        NSString *name = [NSString stringWithFormat:@"%@.%@", base, ext];
        NSString *dst = [self.dir stringByAppendingPathComponent:name];
        NSInteger n = 1;
        while ([fm fileExistsAtPath:dst]) {
            name = [NSString stringWithFormat:@"%@_%ld.%@", base, (long)n++, ext];
            dst = [self.dir stringByAppendingPathComponent:name];
        }
        BOOL ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:NULL];
        if (!ok) {
            /* 同一进程里 PHPicker 的临时文件只读且只允许读一次 —— 拷不动就改读内容再写 */
            NSData *raw = [NSData dataWithContentsOfURL:url];
            ok = raw.length ? [raw writeToFile:dst atomically:YES] : NO;
        }
        finish(ok ? name : nil);
    }];
}

- (void)picker:(id)picker didFinishPicking:(NSArray *)results {
    /* 2.7.5 修"点相册导入→取消 会卡死":
       旧写法先 dismissViewControllerAnimated:YES 再立刻弹结果 alert; 取消时 results.count==0
       直接 return —— 但 PHPicker 的 delegate 方法返回后 picker 自己还会做一次收尾,
       两次 dismiss 抢同一层 presentation, 结果设置页卡在"正在关闭"状态, 表现为整页卡死。
       现在: 先把结果拷出来, dismiss 完成后(completion 里)再处理, 并且无论成功/取消都保证回调。 */
    NSArray *picked = [results copy];
    __weak typeof(self) weakSelf = self;
    [picker dismissViewControllerAnimated:YES completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishImportWithResults:picked];
        });
    }];
}

- (void)finishImportWithResults:(NSArray *)results {
    if (!results.count) {
        /* 取消: 什么都不弹, 只刷新一下网格, 保证界面回到可用状态 */
        [self.grid reloadData];
        return;
    }
    __block NSInteger okCnt = 0, failCnt = 0;
    __block NSString *firstNew = nil;
    dispatch_group_t grp = dispatch_group_create();
    for (id r in results) {
        id provider = [r valueForKey:@"itemProvider"];
        NSString *sugg = [provider respondsToSelector:@selector(suggestedName)] ? [provider performSelector:@selector(suggestedName)] : nil;
        BOOL isImage = NO;
        if (self.allowImage) {
            /* 2.7.30: 先判视频再判图片。之前的顺序在"两个类型都判不出来"时会把
               扩展名不认识的视频当成图片 → 走图片转码 → 必然失败 → 静默丢素材。 */
            Class ut = NSClassFromString(@"UTType");
            BOOL img = NO, mov = NO;
            if (ut && [provider respondsToSelector:@selector(hasItemConformingToTypeIdentifier:)]) {
                if ([ut respondsToSelector:@selector(imageType)])
                    img = ((BOOL (*)(id, SEL, id))objc_msgSend)(provider, @selector(hasItemConformingToTypeIdentifier:),
                            ((id (*)(id, SEL))objc_msgSend)(ut, @selector(imageType)));
                if ([ut respondsToSelector:@selector(movieType)])
                    mov = ((BOOL (*)(id, SEL, id))objc_msgSend)(provider, @selector(hasItemConformingToTypeIdentifier:),
                            ((id (*)(id, SEL))objc_msgSend)(ut, @selector(movieType)));
            }
            if (mov && !img) isImage = NO;
            else if (img && !mov) isImage = YES;
            else {
                /* 都判不出来 → 按扩展名: 认识的视频扩展名才算视频, 其余一律当图片 */
                NSString *e = sugg.pathExtension.lowercaseString;
                isImage = !([e isEqualToString:@"mp4"] || [e isEqualToString:@"mov"] ||
                            [e isEqualToString:@"m4v"] || [e isEqualToString:@"avi"]);
            }
        } else {
            isImage = NO;   /* 只收视频的模式 */
        }
        dispatch_group_enter(grp);
        [self copyProvider:provider suggested:sugg isImage:isImage done:^(NSString *saved) {
            if (saved) { okCnt++; if (!firstNew) firstNew = saved; } else failCnt++;
            dispatch_group_leave(grp);
        }];
    }
    __weak typeof(self) weakSelf2 = self;
    dispatch_group_notify(grp, dispatch_get_main_queue(), ^{
        DIAlbumImporter *me = weakSelf2;
        if (!me) return;
        NSString *msg;
        if (failCnt > 0) msg = [NSString stringWithFormat:@"成功 %ld 个, 失败 %ld 个", (long)okCnt, (long)failCnt];
        else if (okCnt == 1) msg = [NSString stringWithFormat:@"已导入: %@", firstNew];
        else msg = [NSString stringWithFormat:@"已导入 %ld 个素材", (long)okCnt];
        [me.grid reloadData];
        /* 2.7.5: 不再自己找"最顶上的 presentedViewController"乱弹 —— 上面已经有系统 picker 的
           关闭动画在跑, 抢着 present 就会卡住。改成延迟到 picker 完全关闭之后再弹。 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *presenter = me.grid.window.rootViewController;
            while (presenter.presentedViewController) presenter = presenter.presentedViewController;
            if (!presenter) return;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"相册素材导入"
                message:msg preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [presenter presentViewController:a animated:YES completion:nil];
        });
    });
}
@end

/* DIPreviewGrid 的导入入口: 建 importer → 弹选择器。
   方法名带 di 前缀, 避免与 DIPrefsController(Grid) 的 importFromAlbum 冲突。 */
@implementation DIPreviewGrid (Import)
- (void)diImportFromAlbumWP {
    DIAlbumImporter *imp = [DIAlbumImporter new];
    imp.grid = self.collectionView;
    imp.dir = [self dirForMode];
    imp.allowImage = self.isWallpaperMode;      /* 壁纸: 图片+视频; 岛素材: 只视频 */
    imp.wallpaperMode = self.isWallpaperMode;
    imp.prefKey = [self keyForMode];
    [imp openPickerFrom:self];
}
@end

#pragma mark - 2.2.8 自定义取色页(图三式: 大预览 + HEX + RGB 三滑杆) 与 多色列表面板(图二式)

/* 单个颜色的精细编辑页 */
@interface DIColorEditor : UIViewController <UITextFieldDelegate>
@property (nonatomic, assign) NSInteger colorIndex;
@property (nonatomic, strong) UIColor *curColor;
- (instancetype)initWithIndex:(NSInteger)idx;
@end

@implementation DIColorEditor {
    UIView *_preview;
    UITextField *_hexField;
    UISlider *_rs, *_gs, *_bs;
    UILabel *_rv, *_gv, *_bv;
    UILabel *_tmpValueLabel;
}

- (instancetype)initWithIndex:(NSInteger)idx {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _colorIndex = idx;
        /* 2.7.15: 读色失败不能拖垮 init —— 给白色兜底 */
        UIColor *c = nil;
        @try {
            NSArray *cs = diReadColors();
            NSString *hex = (idx >= 0 && idx < (NSInteger)cs.count) ? cs[idx] : @"FFFFFF";
            c = diColorFromHexStr(hex, [UIColor whiteColor]);
        } @catch (NSException *e) {
            diStep(@"调色页: init 读色异常: %@ — %@", e.name, e.reason);
        }
        _curColor = c ?: [UIColor whiteColor];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = DI_PAGE_BG;
    self.title = [NSString stringWithFormat:@"第 %ld 个颜色", (long)(_colorIndex + 1)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(diCancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(diDone)];

    CGFloat W = self.view.bounds.size.width;
    if (W < 100) W = [UIScreen mainScreen].bounds.size.width;
    CGFloat pad = 20;

    /* 大预览块 */
    _preview = [[UIView alloc] initWithFrame:CGRectMake(pad, 90, W - pad * 2, 110)];
    _preview.layer.cornerRadius = 18;
    _preview.layer.masksToBounds = YES;
    [self.view addSubview:_preview];

    /* HEX 输入框 */
    _hexField = [[UITextField alloc] initWithFrame:CGRectMake(pad, 220, W - pad * 2, 54)];
    _hexField.backgroundColor = DI_CARD_BG;
    _hexField.layer.cornerRadius = 12;
    _hexField.textAlignment = NSTextAlignmentCenter;
    _hexField.font = [UIFont boldSystemFontOfSize:22];
    _hexField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    _hexField.autocorrectionType = UITextAutocorrectionTypeNo;
    _hexField.returnKeyType = UIReturnKeyDone;
    _hexField.delegate = self;
    _hexField.textColor = [UIColor labelColor];
    [_hexField addTarget:self action:@selector(hexChanged) forControlEvents:UIControlEventEditingChanged];
    /* 2.2.24: 结束编辑(点完成/收起键盘)时也写一次, 避免只输入不触发 EditingChanged 的情况 */
    [_hexField addTarget:self action:@selector(hexCommit) forControlEvents:UIControlEventEditingDidEnd];
    [self.view addSubview:_hexField];

    /* RGB 三滑杆 */
    _rs = [self makeSlider:300 label:@"红 R" red:YES]; _rv = [self lastSliderValueLabel];
    _gs = [self makeSlider:360 label:@"绿 G" red:NO];  _gv = [self lastSliderValueLabel];
    _bs = [self makeSlider:420 label:@"蓝 B" red:NO];  _bv = [self lastSliderValueLabel];
    [self syncFromColor];
}

- (UILabel *)lastSliderValueLabel { return _tmpValueLabel; }
- (UISlider *)makeSlider:(CGFloat)y label:(NSString *)title red:(BOOL)red {
    CGFloat W = self.view.bounds.size.width;
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 60, 30)];
    t.text = title;
    t.font = [UIFont boldSystemFontOfSize:17];
    [self.view addSubview:t];

    UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(80, y, W - 80 - 90, 30)];
    s.minimumValue = 0; s.maximumValue = 255;
    [s addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:s];

    UILabel *v = [[UILabel alloc] initWithFrame:CGRectMake(W - 85, y - 4, 65, 38)];
    v.backgroundColor = DI_FIELD_BG;
    v.layer.cornerRadius = 10;
    v.layer.masksToBounds = YES;
    v.textAlignment = NSTextAlignmentCenter;
    v.font = [UIFont boldSystemFontOfSize:19];
    [self.view addSubview:v];
    _tmpValueLabel = v;
    if (red) s.minimumTrackTintColor = [UIColor systemRedColor];
    return s;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    /* 颜色条颜色由 syncFromColor 设置; 这里只补滑杆轨道颜色 */
    if (_gs) _gs.minimumTrackTintColor = [UIColor systemGreenColor];
    if (_bs) _bs.minimumTrackTintColor = [UIColor systemBlueColor];
}

- (void)syncFromColor {
    /* 2.7.15: 全部空值兜底 —— 点色块闪退最可能就崩在这里:
       _curColor 为 nil 时 [_curColor getRed:...] 在 arm64e 上是野指针调用,
       _gs/_bs 还没建好时直接赋值 value 也可能出问题。 */
    if (!_curColor) _curColor = [UIColor whiteColor];
    CGFloat r = 1, g = 1, b = 1, a = 1;
    @try { [_curColor getRed:&r green:&g blue:&b alpha:&a]; }
    @catch (__unused NSException *e) { r = g = b = 1; }
    _preview.backgroundColor = _curColor;
    if (_rv) _rv.text = [NSString stringWithFormat:@"%d", (int)lround(r * 255)];
    if (_gv) _gv.text = [NSString stringWithFormat:@"%d", (int)lround(g * 255)];
    if (_bv) _bv.text = [NSString stringWithFormat:@"%d", (int)lround(b * 255)];
    if (_rs && _gs && _bs) {
        _rs.value = r * 255; _gs.value = g * 255; _bs.value = b * 255;
    }
    if (_hexField && !_hexField.isFirstResponder) _hexField.text = diHexFromColor(_curColor);
}

- (void)sliderChanged {
    _curColor = [UIColor colorWithRed:_rs.value / 255.0 green:_gs.value / 255.0 blue:_bs.value / 255.0 alpha:1.0];
    [self syncFromColor];
    [self diSaveNow];
}

- (void)hexChanged {
    NSString *h = _hexField.text;
    if (h.length != 6) return;
    _curColor = diColorFromHexStr(h, _curColor);
    [self syncFromColor];
    [self diSaveNow];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; [self hexCommit]; return YES; }

/* 2.2.24: 失焦时兜底写一次 —— 用户输入 6 位后直接点"完成"也能生效 */
- (void)hexCommit {
    NSString *h = [_hexField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    h = [h stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (h.length < 6) return;
    UIColor *c = diColorFromHexStr(h, nil);
    if (!c) return;
    _curColor = c;
    [self syncFromColor];
    [self diSaveNow];
    diStep(@"调色页: HEX 提交 %@", h.uppercaseString);
}

- (void)diSaveNow {
    NSMutableArray *cs = [diReadColors() mutableCopy];
    if (_colorIndex < 0 || _colorIndex >= (NSInteger)cs.count) return;
    cs[_colorIndex] = diHexFromColor(_curColor);
    diWriteColors(cs);
    diColorChangedNotify(); // 2.2.11: 拖动滑杆即刻生效, 不用点完成
    static CFAbsoluteTime lastLog;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if (t - lastLog > 0.5) {
        lastLog = t;
        diStep(@"调色页: 第 %ld 色 → %@", (long)(_colorIndex + 1), diHexFromColor(_curColor));
    }
}
/* 2.2.23: 本页既可能被 push(旧路径) 也可能被 present(面板里), 两种都要能关;
   否则被 present 时 popViewController 对 modal 栈无效 → "点完成没反应" */
- (void)diCloseSelf {
    if (self.presentingViewController && self.navigationController.viewControllers.firstObject == self) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)diCancel {
    [self diCloseSelf];
}
- (void)diDone {
    [self diSaveNow];
    diStep(@"调色页: 点了完成, 已写入第 %ld 个颜色 = %@", (long)(_colorIndex + 1), diHexFromColor(_curColor));
    [self diCloseSelf];
}
@end

#pragma mark - 多色面板 2.2.22: 独立窗口实现(彻底绕开设置页重排)

/* 2.2.22 复盘: 面板做成 push 进 PSListController 的 UIViewController 时,
   Preferences 会持续重排/重建视图树 —— 日志里"色块已刷新"在 0.3 秒内刷了 40 多次,
   点击落在被重建掉的旧按钮上 → 加减色永远没反应(2.2.20/2.2.21 两版都栽在这)。
   现在改用独立 UIWindow(和预览浮层同一套手法), 完全脱离 Preferences 的视图树:
   建一次、不重建、不发通知自刷新 → 点哪儿就是哪儿。 */

static UIWindow *gPanelWin;

/* 2.7.9: 面板被 push 进设置页导航栈后, 系统导航栏已经显示了标题, 面板自绘的那条
   「‹ 返回 + 标题」就会和系统导航栏标题**上下叠字**(用户截图里的"横条颜色/横条颜色")。
   这里统一处理: 在导航栈里 → 整条自绘栏隐藏 + 内容整体上移到安全区顶部;
   退回独立窗口 → 自绘栏照常显示(此时没有系统导航栏, 必须有返回键)。 */
/* 2.7.10: 面板顶部这层"自制导航条"彻底不用了 —— 一律隐藏。
   原因: 进栈后系统导航栏已经占了一条, 再留一条就是双层占位, 页面被往下推、第一行内容被压住。
   独立窗口那条退路也一并隐藏(它本来就没有场景会走到, 留着只会意外露出来压住内容)。
   内容起始位置交给页面自己算: 进栈时页面坐标 = 导航栏正下方, 值很小; 不在栈里就留足状态栏。 */
static void diStyleOwnBar(UIViewController *vc, UIView *bar, CGFloat *topPadPtr) {
    if (!vc || !bar) return;
    BOOL pushed = (vc.navigationController != nil);
    bar.hidden = YES;
    /* 2.7.11: 进栈时留 28 —— 240 版给 4 还是贴边(用户说"有点遮挡"),
       系统导航栏下沿到第一行内容之间需要一段肉眼可见的呼吸距离。 */
    if (topPadPtr) *topPadPtr = pushed ? 28 : 58;
}

@interface DIGradientPanel : UIViewController
@end

/* 事件入口: 面板每次回到前台都强制重画色块(调色页确定后回来就靠这条) */
static void diPanelReRefresh(CFNotificationCenterRef c, void *obs, CFStringRef name,
                             const void *obj, CFDictionaryRef info);

@implementation DIGradientPanel {
    UIButton *_addBtn, *_delBtn, *_batchBtn, *_doneBtn;
    UIScrollView *_scroll;
    NSMutableArray *_swatches;
    UIView *_previewCard;      /* 2.2.23: 恢复预览 —— 用户第一次就要的那块 */
    UILabel *_previewLabel;
    CAGradientLayer *_previewGrad;
}

/* 一次性搭好, 之后只 refresh(改色块颜色/显隐), 从不删视图 */
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = DI_PAGE_BG;
    diStep(@"面板: viewDidLoad 进入 (独立窗口版)");

    CGFloat W = self.view.bounds.size.width;
    if (W < 100) W = [UIScreen mainScreen].bounds.size.width;

    /* 顶部导航条: 深色底, 关闭键放左上, 整体下移不贴状态栏 */
    /* 2.7.11: 58 → 78。进栈后页面坐标原点就在系统导航栏下方, 58 只留了一点点,
       第一行内容(字体页是"批量输入", 横条页是胶囊预览)仍贴着导航栏底边。 */
    CGFloat topPad = 78, barH = 52;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, topPad, W, barH)];
    bar.backgroundColor = DI_PAGE_BG; /* 与页面底色全局统一, 不再分块 */
    /* 2.7.9: push 进导航栈时用系统的返回+标题, 自绘整条隐藏(否则上下叠字) */
    diStyleOwnBar(self, bar, &topPad);
    [self.view addSubview:bar];

    _doneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _doneBtn.frame = CGRectMake(8, 4, 76, barH - 8);
    [_doneBtn setTitle:@"‹ 返回" forState:UIControlStateNormal];
    _doneBtn.titleLabel.font = [UIFont systemFontOfSize:17];
    _doneBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [_doneBtn addTarget:self action:@selector(diClose) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:_doneBtn];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(W / 2 - 70, 4, 140, barH - 8)];
    title.text = @"字体颜色";
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:17];
    [bar addSubview:title];

    /* 第二行: 批量输入(左) + −(右倒数) + +(最右), 按钮各自独立、互不叠压、触控区 44 */
    CGFloat y = topPad + barH + 14;
    _batchBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _batchBtn.frame = CGRectMake(16, y, 100, 44);
    [_batchBtn setTitle:@"批量输入" forState:UIControlStateNormal];
    _batchBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    _batchBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [_batchBtn addTarget:self action:@selector(batchInput) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_batchBtn];

    _delBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _delBtn.frame = CGRectMake(W - 104, y, 44, 44);
    [_delBtn setTitle:@"−" forState:UIControlStateNormal];
    _delBtn.titleLabel.font = [UIFont boldSystemFontOfSize:28];
    [_delBtn addTarget:self action:@selector(delColor) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_delBtn];

    _addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _addBtn.frame = CGRectMake(W - 56, y, 44, 44);
    [_addBtn setTitle:@"+" forState:UIControlStateNormal];
    _addBtn.titleLabel.font = [UIFont boldSystemFontOfSize:28];
    [_addBtn addTarget:self action:@selector(addColor) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_addBtn];

    /* 色块横排: 每个色块 68 + 4 号字嵌在色块内(色块本身是 button, 点它进调色页) */
    CGFloat sw = 68, sy = y + 56;
    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, sy, W, sw + 10)];
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.alwaysBounceHorizontal = YES;
    [self.view addSubview:_scroll];
    _swatches = [NSMutableArray array];

    /* 2.2.23: 恢复预览块(用户要的) —— 立在色块下面, 实时显示渐变文字效果 */
    CGFloat py = sy + sw + 20;
    _previewCard = [[UIView alloc] initWithFrame:CGRectMake(16, py, W - 32, 96)];
    _previewCard.backgroundColor = DI_CARD_BG;
    _previewCard.layer.cornerRadius = 18;
    _previewCard.layer.masksToBounds = YES;
    [self.view addSubview:_previewCard];

    UILabel *cap = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, 160, 16)];
    cap.text = @"效果预览";
    cap.font = [UIFont systemFontOfSize:11];
    cap.textColor = [UIColor secondaryLabelColor];
    [_previewCard addSubview:cap];

    _previewLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 28, W - 32 - 28, 56)];
    _previewLabel.text = @"漂流岛 · 字体颜色示例";
    _previewLabel.font = [UIFont boldSystemFontOfSize:22];
    _previewLabel.numberOfLines = 1;
    _previewLabel.adjustsFontSizeToFitWidth = YES;
    _previewLabel.minimumScaleFactor = 0.6;
    [_previewCard addSubview:_previewLabel];

    CGFloat hy = py + 96 + 16;
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, hy, W - 32, 46)];
    hint.text = @"点色块可精细调色; 关闭「流光」= 取第 1 个颜色固定显示, 打开 = 颜色沿文字从左到右流动。";
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.numberOfLines = 0;
    [self.view addSubview:hint];

    [self refresh];

    /* 2.2.24: 订阅颜色变更 —— 调色页确定 / 批量输入都会发这条, 面板据此立刻重画色块。
       刷新走 dispatch_after 节流, 不会像 2.2.21 那样把自己刷爆。 */
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self,
        diPanelReRefresh, CFSTR("com.abgg332.driftisland.colorchanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    diStep(@"面板: viewDidLoad 完成");
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    /* 从调色页返回时, 面板一定重新 appear → 在这里补一次刷新, 保证色块是最新色 */
    [self refresh];
}

/* 颜色变更 → 节流刷新(0.15s 内多次只刷一次), 避免自激 */
static void diPanelReRefresh(CFNotificationCenterRef c, void *obs, CFStringRef name,
                             const void *obj, CFDictionaryRef info) {
    DIGradientPanel *p = (__bridge DIGradientPanel *)obs;
    if (!p) return;
    static CFAbsoluteTime last;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 0.15) return;
    last = now;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try { [p refresh]; }   /* 2.7.36: 同 diPrefsReloadCB 的防御 */
        @catch (NSException *e) { diStep(@"面板刷新异常 %@ - %@", e.name, e.reason ?: @"(未知)"); }
    });
}

- (void)diClose {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self);
    diColorChangedNotify();      /* 关面板时让岛立即吃到最新颜色 */
    diStep(@"面板: 点了 ‹ 返回, 关闭");
    UIWindow *w = gPanelWin;
    gPanelWin = nil;
    [w setHidden:YES];
    w.hidden = YES;
    w.rootViewController = nil;
}

- (void)refresh {
    NSArray *cs = diReadColors();
    CGFloat sw = 68, gap = 12, x = 16;
    while (_swatches.count < cs.count) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.layer.cornerRadius = 16;
        b.layer.borderWidth = 1;
        b.layer.borderColor = [UIColor separatorColor].CGColor;
        [b addTarget:self action:@selector(tapSwatch:) forControlEvents:UIControlEventTouchUpInside];
        UILabel *n = [[UILabel alloc] initWithFrame:CGRectMake(0, sw - 20, sw, 16)];
        n.font = [UIFont systemFontOfSize:11];
        n.textColor = [UIColor whiteColor];
        n.textAlignment = NSTextAlignmentCenter;
        n.userInteractionEnabled = NO;              /* 别让 label 吃掉点击 */
        [b addSubview:n];
        [_scroll addSubview:b];
        [_swatches addObject:b];
    }
    for (NSInteger i = 0; i < (NSInteger)_swatches.count; i++) {
        UIButton *b = _swatches[i];
        b.hidden = (i >= (NSInteger)cs.count);
        if (b.hidden) continue;
        b.frame = CGRectMake(x + i * (sw + gap), 0, sw, sw);
        b.backgroundColor = diColorFromHexStr(cs[i], [UIColor whiteColor]);
        b.tag = 100 + i;
        UILabel *n = b.subviews.firstObject;
        n.text = [NSString stringWithFormat:@"%ld", (long)(i + 1)];
    }
    _scroll.contentSize = CGSizeMake(x + cs.count * (sw + gap) + 16, sw);
    /* 按钮可点状态跟着数量走, 一眼能看出边界 */
    _addBtn.enabled = (cs.count < 8);
    _delBtn.enabled = (cs.count > 1);
    _addBtn.alpha = _addBtn.enabled ? 1.0 : 0.3;
    _delBtn.alpha = _delBtn.enabled ? 1.0 : 0.3;
    [self diRefreshPreviewWithColors:cs];
    diStep(@"面板: 色块已刷新 (%lu 个)", (unsigned long)cs.count);
}

/* 预览: 单色 = 纯色文字; 多色 = 横向渐变(与岛上流光同一份色表) */
- (void)diRefreshPreviewWithColors:(NSArray<NSString *> *)cs {
    if (!_previewLabel) return;
    NSMutableArray *cols = [NSMutableArray array];
    for (NSString *h in cs) [cols addObject:(id)diColorFromHexStr(h, [UIColor whiteColor]).CGColor];
    if (cols.count == 1) {
        _previewLabel.textColor = diColorFromHexStr(cs.firstObject, [UIColor whiteColor]);
        [_previewGrad removeFromSuperlayer];
        _previewGrad = nil;
        return;
    }
    CGSize sz = _previewLabel.bounds.size;
    if (sz.width < 10) sz = CGSizeMake(300, 30);
    if (!_previewGrad) {
        _previewGrad = [CAGradientLayer layer];
        _previewGrad.startPoint = CGPointMake(0, 0.5);
        _previewGrad.endPoint = CGPointMake(1, 0.5);
        [_previewLabel.layer insertSublayer:_previewGrad atIndex:0];
    }
    _previewGrad.frame = CGRectMake(0, 0, sz.width, sz.height);
    _previewGrad.colors = cols;
    _previewGrad.locations = nil;
    if (_previewLabel.textColor != [UIColor clearColor]) _previewLabel.textColor = [UIColor clearColor];
}

/* 兼容旧调用名 */
- (void)rebuild { [self refresh]; }

- (void)tapSwatch:(UIButton *)b {
    /* 2.7.15: 这里原来完全没有 @try —— 248 日志里点色块闪退却一条记录都没有,
       就是因为在 alloc/initWithIndex: 里抛了异常(或 present 失败)直接崩掉。
       现在每一步单独兜底, 任何失败都只弹提示, 绝不闪退。 */
    NSInteger idx = b.tag - 100;
    diStep(@"面板: 点了色块 %ld", (long)(idx + 1));
    @try {
        Class ec = NSClassFromString(@"DIColorEditor");
        if (!ec) { [self toast:@"调色页不可用"]; return; }
        if (![ec instancesRespondToSelector:@selector(initWithIndex:)]) {
            diStep(@"面板: DIColorEditor 没有 initWithIndex:, 改用 init");
            UIViewController *vc = [[ec alloc] init];
            if (!vc) { [self toast:@"调色页创建失败"]; return; }
            [self presentViewController:vc animated:YES completion:nil];
            return;
        }
        UIViewController *vc = nil;
        @try {
            vc = ((UIViewController *(*)(id, SEL, NSInteger))objc_msgSend)(
                ((id (*)(id, SEL))objc_msgSend)(ec, @selector(alloc)), @selector(initWithIndex:), idx);
        } @catch (NSException *e) {
            diStep(@"面板: 调色页 init 异常: %@ — %@", e.name, e.reason);
            vc = nil;
        }
        if (!vc) { [self toast:@"调色页创建失败"]; return; }
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        @try { [self presentViewController:nav animated:YES completion:nil]; }
        @catch (NSException *e) { diStep(@"面板: present 调色页异常: %@ — %@", e.name, e.reason); }
    } @catch (NSException *e) {
        diStep(@"面板: 点色块异常: %@ — %@\n%@", e.name, e.reason, e.callStackSymbols);
    }
}

- (void)addColor {
    diStep(@"面板: 点了 + 增加颜色");
    NSMutableArray *cs = [diReadColors() mutableCopy];
    if (cs.count >= 8) { [self toast:@"最多 8 个颜色"]; return; }
    [cs addObject:cs.lastObject ?: @"FFFFFF"];   /* 复制最后一个, 方便微调 */
    diWriteColors(cs);
    diColorChangedNotify();
    [self refresh];
    diStep(@"面板: 增加后共 %lu 个", (unsigned long)cs.count);
}

- (void)delColor {
    diStep(@"面板: 点了 − 删除颜色");
    NSMutableArray *cs = [diReadColors() mutableCopy];
    if (cs.count <= 1) { [self toast:@"至少保留 1 个颜色"]; return; }
    [cs removeLastObject];
    diWriteColors(cs);
    diColorChangedNotify();
    [self refresh];
    diStep(@"面板: 删除后共 %lu 个", (unsigned long)cs.count);
}

- (void)batchInput {
    diStep(@"面板: 点了 批量输入");
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"批量输入"
        message:@"每行一个 HEX, 或用逗号分隔\n例: FFEFEA,FF9EA8,C9E8F7"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [diReadColors() componentsJoinedByString:@","];
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *raw = a.textFields.firstObject.text ?: @"";
        raw = [raw stringByReplacingOccurrencesOfString:@"\n" withString:@","];
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *p in [raw componentsSeparatedByString:@","]) {
            NSString *h = [[p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                           stringByReplacingOccurrencesOfString:@"#" withString:@""];
            if (h.length >= 6) [out addObject:h.uppercaseString];
        }
        if (!out.count) { [self toast:@"没有识别到有效颜色"]; return; }
        diStep(@"面板: 批量输入写入 %lu 个颜色", (unsigned long)out.count);
        diWriteColors(out);
        diColorChangedNotify();
        [self refresh];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)toast:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

/* ===== 2.2.67: 流光风格选择面板 =====

   6 张卡片, 每张画一个胶囊 + 该风格的真实配色 + 跑动光点标记,
   点一下立刻写入 smallEdgeStyle 并 post 通知让 SpringBoard 重读。
   卡片本身用 CAGradientLayer 沿胶囊描边渲染, 所见即所得。 */

@interface DIStylePanel : UIViewController
@end

static UIWindow *gStyleWin = nil;

/* 与 Tweak 中 diStyleColors 保持同一份配色表 */
static NSArray *diStyleDefs(void) {
    return @[
        @{@"name": @"霓虹跑马灯", @"c": @[@"FFC71A", @"FF299E", @"33F25A", @"1A9EFF", @"A833FF", @"1AF2F2"]},
        @{@"name": @"幻彩流沙",   @"c": @[@"FF8CC7", @"D98CFF", @"8CBFFF", @"A6FFE6"]},
        @{@"name": @"电光青蓝",   @"c": @[@"1AF2FF", @"268CFF", @"8CF2FF"]},
        @{@"name": @"烈焰红橙",   @"c": @[@"FF331A", @"FF731A", @"FFCC33"]},
        @{@"name": @"极光绿紫",   @"c": @[@"33FF8C", @"7333FF", @"33D9FF"]},
        @{@"name": @"白金星轨",   @"c": @[@"FFFFFF", @"D9E6FF", @"FFF2D9"]},
    ];
}

static UIColor *diHexColor(NSString *hex) {
    unsigned int v = 0;
    NSScanner *sc = [NSScanner scannerWithString:hex];
    [sc scanHexInt:&v];
    return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                           green:((v >> 8) & 0xFF) / 255.0
                            blue:(v & 0xFF) / 255.0 alpha:1.0];
}

@implementation DIStylePanel {
    int _cur;
    NSMutableArray *_cards;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = DI_PAGE_BG;
    _cards = [NSMutableArray array];

    id saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"smallEdgeStyle"];
    _cur = saved ? [saved intValue] : 0;

    CGFloat W = self.view.bounds.size.width;
    if (W < 100) W = UIScreen.mainScreen.bounds.size.width;
    /* 2.7.11: 58 → 78。进栈后页面坐标原点就在系统导航栏下方, 58 只留了一点点,
       第一行内容(字体页是"批量输入", 横条页是胶囊预览)仍贴着导航栏底边。 */
    CGFloat topPad = 78, barH = 52;

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, topPad, W, barH)];
    bar.backgroundColor = DI_PAGE_BG;
    diStyleOwnBar(self, bar, &topPad);   /* 2.7.9: 在导航栈里就隐藏自绘栏, 只留系统导航 */
    [self.view addSubview:bar];

    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    back.frame = CGRectMake(8, 4, 76, barH - 8);
    [back setTitle:@"‹ 返回" forState:UIControlStateNormal];
    back.titleLabel.font = [UIFont systemFontOfSize:17];
    back.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [back addTarget:self action:@selector(diClose) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:back];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(W / 2 - 80, 4, 160, barH - 8)];
    title.text = @"流光风格";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textAlignment = NSTextAlignmentCenter;
    [bar addSubview:title];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, topPad + barH + 4, W - 40, 20)];
    hint.text = @"点一下即应用 · 只在播放歌曲的灵动岛上显示";
    hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    hint.font = [UIFont systemFontOfSize:12];
    [self.view addSubview:hint];

    NSArray *defs = diStyleDefs();
    CGFloat y0 = topPad + barH + 34;
    CGFloat gap = 12, padX = 18;
    CGFloat cw = (W - padX * 2 - gap) / 2.0;
    CGFloat ch = 86;
    for (int i = 0; i < (int)defs.count; i++) {
        int col = i % 2, row = i / 2;
        CGFloat x = padX + col * (cw + gap);
        CGFloat y = y0 + row * (ch + gap);
        UIControl *card = [[UIControl alloc] initWithFrame:CGRectMake(x, y, cw, ch)];
        card.tag = 100 + i;
        card.layer.cornerRadius = 16;
        card.layer.masksToBounds = YES;
        card.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        card.layer.borderWidth = 1.0;
        card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
        [card addTarget:self action:@selector(diPick:) forControlEvents:UIControlEventTouchUpInside];

        /* 胶囊预览: 用渐变层铺满一条胶囊, 再叠一圈描边模拟灯管 */
        NSArray *hexs = defs[i][@"c"];
        CGFloat pw = cw - 36, ph = 26;
        UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(18, 16, pw, ph)];
        pill.userInteractionEnabled = NO;
        pill.backgroundColor = UIColor.clearColor;
        pill.layer.cornerRadius = ph / 2.0;
        pill.layer.borderWidth = 2.5;
        pill.layer.borderColor = diHexColor(hexs.firstObject).CGColor;
        pill.layer.shadowColor = diHexColor(hexs.firstObject).CGColor;
        pill.layer.shadowOpacity = 0.9;
        pill.layer.shadowRadius = 4;
        pill.layer.shadowOffset = CGSizeZero;

        CAGradientLayer *gl = [CAGradientLayer layer];
        gl.frame = pill.bounds;
        gl.startPoint = CGPointMake(0, 0.5);
        gl.endPoint = CGPointMake(1, 0.5);
        NSMutableArray *cg = [NSMutableArray array];
        for (NSString *hx in hexs) [cg addObject:(__bridge id)diHexColor(hx).CGColor];
        gl.colors = cg;
        gl.cornerRadius = ph / 2.0;
        gl.opacity = 0.85;
        [pill.layer addSublayer:gl];
        [card addSubview:pill];

        UILabel *nm = [[UILabel alloc] initWithFrame:CGRectMake(14, ch - 34, cw - 28, 20)];
        nm.text = defs[i][@"name"];
        nm.textColor = UIColor.whiteColor;
        nm.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        [card addSubview:nm];

        [self.view addSubview:card];
        [_cards addObject:card];
        [self diMarkSelected];
    }
}

/* 选中态: 白边加粗 + 右侧小勾 */
- (void)diMarkSelected {
    for (UIControl *c in _cards) {
        int i = (int)c.tag - 100;
        BOOL on = (i == _cur);
        c.layer.borderWidth = on ? 2.0 : 1.0;
        c.layer.borderColor = on ? [UIColor colorWithWhite:1.0 alpha:0.85].CGColor
                                 : [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
        c.backgroundColor = on ? [UIColor colorWithWhite:1.0 alpha:0.13]
                               : [UIColor colorWithWhite:1.0 alpha:0.06];
        UILabel *ck = (UILabel *)[c viewWithTag:900];
        if (on && !ck) {
            ck = [[UILabel alloc] initWithFrame:CGRectMake(c.bounds.size.width - 30, 8, 22, 20)];
            ck.tag = 900;
            ck.text = @"✓";
            ck.font = [UIFont boldSystemFontOfSize:15];
            ck.textColor = UIColor.whiteColor;
            ck.textAlignment = NSTextAlignmentRight;
            [c addSubview:ck];
        } else if (!on && ck) {
            [ck removeFromSuperview];
        }
    }
}

- (void)diPick:(UIControl *)sender {
    int i = (int)sender.tag - 100;
    _cur = i;
    [[NSUserDefaults standardUserDefaults] setObject:@(i) forKey:@"smallEdgeStyle"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.abgg332.driftisland.reload"), NULL, NULL, true);
    [self diMarkSelected];
    NSArray *defs = diStyleDefs();
    UILabel *t = (UILabel *)[self.view viewWithTag:7777];
    if (!t) {
        t = [[UILabel alloc] initWithFrame:CGRectMake(20, self.view.bounds.size.height - 80,
                                                      self.view.bounds.size.width - 40, 24)];
        t.tag = 7777;
        t.textAlignment = NSTextAlignmentCenter;
        t.textColor = UIColor.whiteColor;
        t.font = [UIFont systemFontOfSize:14];
        [self.view addSubview:t];
    }
    t.text = [NSString stringWithFormat:@"已应用：%@", defs[i][@"name"]];
}

- (void)diClose {
    [self dismissViewControllerAnimated:YES completion:nil];
    gStyleWin.hidden = YES;
    gStyleWin = nil;
}
@end

/* ===== 2.7.8: 把面板做成"真正的系统二级页" =====
   2.7.7 的做法是新建一个窗口 + nav, 里面放"空壳根页 + 面板页"。
   结果按返回后 pop 到底 = 那个空壳页(只有一行标题), 而且这个窗口盖在最上面,
   看起来就是"返回到一个白板然后卡住"(用户截图)。
   2.7.8 改法: **不新建窗口**, 直接借用设置页自己的 UINavigationController:
       · 找到当前最上层的 PSListController 的 navigationController
       · 把面板页 push 进去
   这样面板页就是设置页里真正的二级页: 顶部系统返回按钮显示"‹ 上一级标题",
   左滑返回同样是系统原生行为, 返回后回到的也是真实存在的设置页, 不会再卡死。
   面板页本来就是自绘 UIView, 放进导航栈完全没问题; 它的"关闭/返回"逻辑照旧。 */
static UINavigationController *diFindPrefsNav(void) {
    NSMutableArray<UINavigationController *> *navs = [NSMutableArray array];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            UIViewController *r = w.rootViewController;
            /* 只从"设置页所在的那套窗口"里找: 跳过我们自己开的 Alert 级窗口 */
            if (w.windowLevel >= UIWindowLevelAlert) continue;
            NSMutableArray<UIViewController *> *q = [NSMutableArray array];
            if (r) [q addObject:r];
            NSInteger guard = 0;
            while (q.count && guard++ < 200) {
                UIViewController *vc = q.firstObject;
                [q removeObjectAtIndex:0];
                if ([vc isKindOfClass:[UINavigationController class]]) {
                    UINavigationController *n = (UINavigationController *)vc;
                    for (UIViewController *c in n.viewControllers)
                        if ([c isKindOfClass:NSClassFromString(@"PSListController")]) { [navs addObject:n]; break; }
                }
                for (UIViewController *c in vc.childViewControllers) [q addObject:c];
                if (vc.presentedViewController) [q addObject:vc.presentedViewController];
            }
        }
    }
    return navs.firstObject;
}

/* 通用: 把面板 push 成设置页的二级页; 失败则退回"独立窗口 + 自带返回按钮" */
static void diPushPanel(UIViewController *panel, NSString *title, UIWindow **legacyWin) {
    if (!panel) return;
    if (title.length) panel.title = title;
    UINavigationController *nav = diFindPrefsNav();
    if (nav && nav.topViewController && nav.topViewController != panel) {
        nav.navigationBar.hidden = NO;
        /* 2.7.10: 系统导航栏标题选"内联"模式。
           默认的大标题模式会把 contentView 往下推一截, 结果 push 上来的页面里
           最上面那行内容(横条页是胶囊预览, 字体页是"批量输入"那排按钮)被导航栏压住一半。
           内联模式高度固定 44, 页面从导航栏正下方开始, 不再互相遮挡。 */
        panel.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
        [nav pushViewController:panel animated:YES];
        diStep(@"面板: 已 push 为设置页二级页 (%@)", title ?: @"");
        return;
    }
    /* 退路: 设置页导航栈拿不到 → 老办法, 独立窗口(此时只能靠面板内自制返回) */
    UIWindowScene *scene = nil;
    for (UIScene *s2 in UIApplication.sharedApplication.connectedScenes)
        if ([s2 isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s2; break; }
    if (!scene) return;
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = scene.coordinateSpace.bounds;
    w.windowLevel = UIWindowLevelAlert + 1;
    w.rootViewController = panel;
    w.backgroundColor = DI_PAGE_BG;
    w.hidden = NO;
    if (legacyWin) *legacyWin = w;
    diStep(@"面板: 退路(独立窗口), 未接入设置页导航栈");
}

static void diOpenStylePanelWindow(void) {
    if (gStyleWin && !gStyleWin.hidden) return;
    DIStylePanel *vc = [[DIStylePanel alloc] initWithNibName:nil bundle:nil];
    UIWindow *w = nil;
    diPushPanel(vc, @"流光风格", &w);
    gStyleWin = w;
}

/* 打开面板: 独立窗口, 与设置页视图树无关 */
static void diOpenGradientPanelWindow(void) {
    if (gPanelWin && !gPanelWin.hidden) return;
    DIGradientPanel *vc = [[DIGradientPanel alloc] initWithNibName:nil bundle:nil];
    /* 2.7.8: 直接 push 进设置页的导航栈 → 系统返回按钮 + 系统左滑返回, 返回即回到设置页 */
    UIWindow *w = nil;
    diPushPanel(vc, @"字体颜色", &w);
    gPanelWin = w;
}

/* ===== 2.5.10: 横条颜色独立面板 =====
   PSListController 内的 ActionSheet 点击无效、分段控件不渲染(实测),
   唯一可靠的是"字体颜色"那种独立窗口 —— 这里照搬该做法。 */
static UIWindow *gBarWin = nil;
static void diOpenHomeBarPanelWindow(void);

@interface DIHomeBarPanel : UIViewController
@end

@implementation DIHomeBarPanel
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = DI_PAGE_BG;
    CGFloat W = UIScreen.mainScreen.bounds.size.width;

    /* 2.7.9: 这个面板是独立窗口(没有系统导航栏), 自绘的 26pt 大标题就留着;
       但它的 y 是 60 —— 若哪天被塞进导航栈会和系统标题叠字, 这里同样按情况处理。 */
    BOOL inNav = (self.navigationController != nil);
    CGFloat topY = inNav ? 28 : 60;   /* 2.7.11: 进栈后下移, 与其它两个面板对齐 */

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(20, topY, W - 40, 34)];
    t.text = @"横条颜色";
    t.font = [UIFont boldSystemFontOfSize:inNav ? 17 : 26];
    t.hidden = inNav;   /* 有系统导航栏时, 标题由导航栏负责 */
    [self.view addSubview:t];

    /* 2.7.10: 整页各块统一从 topY 往下排 —— 之前在导航栈里还留着 60/110/162 这套"独立窗口"坐标,
       结果分段控件被导航栏压住一半。现在进栈时全部贴到导航栏正下方。 */
    CGFloat yTop = inNav ? (topY + 42) : 110;

    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"单色", @"多色渐变", @"流光"]];
    seg.frame = CGRectMake(20, yTop, W - 40, 40);
    NSString *m = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("homeBarMode"), (__bridge CFStringRef)kDomain);
    seg.selectedSegmentIndex = [m isEqualToString:@"gradient"] ? 1 : ([m isEqualToString:@"flow"] ? 2 : 0);
    [seg addTarget:self action:@selector(diSegChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:seg];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, yTop + 52, W - 40, 40)];
    hint.text = @"多个颜色用英文逗号分隔(最多 8 色), 例: FF3B30,FF9500,FFCC00";
    hint.numberOfLines = 2;
    hint.font = [UIFont systemFontOfSize:13];
    hint.textColor = UIColor.secondaryLabelColor;
    [self.view addSubview:hint];

    NSString *cur = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("homeBarHexes"), (__bridge CFStringRef)kDomain);
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(20, yTop + 102, W - 40, 44)];
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.text = cur.length ? cur : @"FFFFFF";
    tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.tag = 1001;
    tf.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    [self.view addSubview:tf];

    UIView *pv = [[UIView alloc] initWithFrame:CGRectMake(20, yTop + 158, W - 40, 34)];
    pv.layer.cornerRadius = 17; pv.layer.masksToBounds = YES;
    pv.tag = 1002;
    pv.backgroundColor = UIColor.systemGray5Color;
    [self.view addSubview:pv];

    NSArray *presets = @[@"FFFFFF", @"000000", @"FF3B30", @"FF9500", @"FFCC00", @"34C759",
                         @"32ADE6", @"007AFF", @"AF52DE", @"FF2D55"];
    CGFloat bw = (W - 40 - 9 * 8) / 10.0, x = 20;
    CGFloat ySw = yTop + 158 + 34 + 16;   /* 2.7.10: 跟着 yTop 走, 不再写死 316 */
    for (NSString *hx in presets) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(x, ySw, bw, bw);
        b.backgroundColor = diColorFromHexStr(hx, UIColor.whiteColor);
        b.layer.cornerRadius = bw / 2;
        b.layer.borderWidth = 1;
        b.layer.borderColor = [UIColor separatorColor].CGColor;
        b.accessibilityIdentifier = hx;
        [b addTarget:self action:@selector(diPickPreset:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
        x += bw + 8;
    }

    UIButton *ok = [UIButton buttonWithType:UIButtonTypeSystem];
    ok.frame = CGRectMake(20, ySw + bw + 24, W - 40, 48);
    [ok setTitle:@"保存并应用" forState:UIControlStateNormal];
    ok.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    ok.backgroundColor = UIColor.systemBlueColor;
    ok.layer.cornerRadius = 12; ok.layer.masksToBounds = YES;
    [ok setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [ok addTarget:self action:@selector(diSave) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:ok];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(diDismissKb)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
    [self diRefreshPreview];
}
- (void)diDismissKb { [self.view endEditing:YES]; }

- (void)diSegChanged:(UISegmentedControl *)sg {
    NSArray *vals = @[@"single", @"gradient", @"flow"];
    CFPreferencesSetAppValue(CFSTR("homeBarMode"), (__bridge CFPropertyListRef)vals[sg.selectedSegmentIndex],
                             (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
    diStep(@"横条颜色: 模式 → %@", vals[sg.selectedSegmentIndex]);
}

- (void)diPickPreset:(UIButton *)b {
    UITextField *tf = (UITextField *)[self.view viewWithTag:1001];
    tf.text = b.accessibilityIdentifier;
    [self diRefreshPreview];
}

- (void)diRefreshPreview {
    UITextField *tf = (UITextField *)[self.view viewWithTag:1001];
    UIView *pv = (UIView *)[self.view viewWithTag:1002];
    NSArray *cols = [tf.text componentsSeparatedByString:@","];
    CAGradientLayer *old = nil;
    for (CALayer *l in pv.layer.sublayers) if ([l isKindOfClass:[CAGradientLayer class]]) old = (CAGradientLayer *)l;
    if (cols.count <= 1) {
        if (old) [old removeFromSuperlayer];
        pv.backgroundColor = diColorFromHexStr(
            [cols.firstObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]],
            UIColor.systemGray5Color);
    } else {
        pv.backgroundColor = [UIColor clearColor];
        CAGradientLayer *g = old ?: [CAGradientLayer layer];
        if (!old) { g.startPoint = CGPointMake(0, 0.5); g.endPoint = CGPointMake(1, 0.5); [pv.layer addSublayer:g]; }
        g.frame = pv.bounds;
        NSMutableArray *cs = [NSMutableArray array];
        for (NSString *h in cols) [cs addObject:(id)diColorFromHexStr(
            [h stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]], UIColor.grayColor).CGColor];
        g.colors = cs;
    }
}

- (void)diSave {
    UITextField *tf = (UITextField *)[self.view viewWithTag:1001];
    NSMutableArray *ok = [NSMutableArray array];
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFabcdef"];
    for (NSString *h in [tf.text componentsSeparatedByString:@","]) {
        NSString *sg = [[h stringByReplacingOccurrencesOfString:@"#" withString:@""]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].uppercaseString;
        if (sg.length == 6 && [sg rangeOfCharacterFromSet:hexSet.invertedSet].location == NSNotFound)
            [ok addObject:sg];
        if (ok.count >= 8) break;
    }
    if (!ok.count) { diStep(@"横条颜色: 格式不对"); return; }
    NSString *joined = [ok componentsJoinedByString:@","];
    CFPreferencesSetAppValue(CFSTR("homeBarHexes"), (__bridge CFPropertyListRef)joined, (__bridge CFStringRef)kDomain);
    CFPreferencesSetAppValue(CFSTR("homeBarHex"), (__bridge CFPropertyListRef)ok.firstObject, (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
    diStep(@"横条颜色: 已保存 %@", joined);
    [self diClose];
}

- (void)diClose { gBarWin.hidden = YES; gBarWin = nil; }
@end

static void diOpenHomeBarPanelWindow(void) {
    if (gBarWin && !gBarWin.hidden) return;
    UIWindowScene *scene = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)sc; break; }
    if (!scene) { diStep(@"横条颜色: 找不到场景"); return; }
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = scene.coordinateSpace.bounds;
    w.windowLevel = UIWindowLevelAlert + 1;
    w.rootViewController = [[DIHomeBarPanel alloc] initWithNibName:nil bundle:nil];
    w.backgroundColor = DI_PAGE_BG;
    w.hidden = NO;
    gBarWin = w;
    diStep(@"横条颜色: 面板已打开");
}

/* ===== 2.5.12: 横条配色预设面板(独立窗口, 照搬"字体颜色"可靠做法) =====
   卡片即所选: 每张卡片画一个胶囊 + 该配色的真实渐变, 点一下立刻写入 homeBarHexes。 */
static NSArray *diHomeBarPresets(void) {
    return @[
        @{@"name": @"系统默认",   @"c": @[@"FFFFFF"]},
        @{@"name": @"霓虹跑马灯", @"c": @[@"FFC71A", @"FF299E", @"33F25A", @"1A9EFF", @"A833FF", @"1AF2F2"]},
        @{@"name": @"幻彩流沙",   @"c": @[@"FF8CC7", @"D98CFF", @"8CBFFF", @"A6FFE6"]},
        @{@"name": @"电光青蓝",   @"c": @[@"1AF2FF", @"268CFF", @"8CF2FF"]},
        @{@"name": @"烈焰红橙",   @"c": @[@"FF331A", @"FF731A", @"FFCC33"]},
        @{@"name": @"极光绿紫",   @"c": @[@"33FF8C", @"7333FF", @"33D9FF"]},
        @{@"name": @"白金星轨",   @"c": @[@"FFFFFF", @"D9E6FF", @"FFF2D9"]},
        @{@"name": @"纯黑",       @"c": @[@"000000"]},
        @{@"name": @"樱花粉",     @"c": @[@"FFB6C1", @"FF8FAB", @"FFD9E3"]},
        @{@"name": @"落日金",     @"c": @[@"FF9500", @"FFCC00", @"FF6A00"]},
        /* 2.6.1: 新增 6 组配色 */
        @{@"name": @"星云紫粉",   @"c": @[@"C86CFF", @"FF6CD9", @"8C5CFF", @"FF9CE8"]},
        @{@"name": @"冰蓝极光",   @"c": @[@"6CFFE0", @"4CA8FF", @"A8F2FF", @"5C7CFF"]},
        @{@"name": @"熔岩流火",   @"c": @[@"FF4C1A", @"FF9A00", @"FFE04C", @"FF1A5C"]},
        @{@"name": @"翡翠鎏金",   @"c": @[@"1AFF8C", @"B8FF4C", @"FFD94C", @"0CE8B8"]},
        @{@"name": @"蜜桃奶昔",   @"c": @[@"FFB89C", @"FFD9B8", @"FF9CB8", @"FFE8CC"]},
        @{@"name": @"深海蓝银",   @"c": @[@"0C6CE8", @"4CD9FF", @"D9E8FF", @"334CFF"]},
    ];
}

/* ===== 2.8.37: 通用配色面板(发光颜色/边框颜色共用) =====
   306 实证: 2.8.36 版"点预设只改输入框文字、不即时应用、无预览",
   用户感知就是"切换无效"; 自定义框在顶部也被忽略。本版重做交互:
     ① 顶部大预览条 —— 当前色的真实渐变/纯色, 点预设/输文字都即时刷新;
     ② 预设网格(16 组) —— 点卡片**即时保存并应用**, 不用再按保存;
     ③ 自定义区放**最后面** —— 输入框监听 EditingChanged,
        "输入几个色值显示几个"(1 个纯色, 2+ 个渐变, 最多 6 个, 最少 1 个),
        按「应用自定义」才写键。
   prefKey 决定写哪个键: lkGlowHex / lkFrameHex。 */
@interface DIColorPick : UIViewController
@property (nonatomic, copy) NSString *prefKey;
@end
@implementation DIColorPick {
    UIScrollView *_scroll;
    UITextField *_hexField;
    UIView *_preview;
    UILabel *_curLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = DI_PAGE_BG;
    CGFloat W = self.view.bounds.size.width;
    if (W < 100) W = UIScreen.mainScreen.bounds.size.width;
    CGFloat topPad = 78;

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, topPad, W, self.view.bounds.size.height - topPad)];
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    /* ① 预览条: 当前选中/输入的色的真实渲染 */
    _preview = [[UIView alloc] initWithFrame:CGRectMake(20, 12, W - 40, 44)];
    _preview.layer.cornerRadius = 10;
    _preview.layer.masksToBounds = YES;
    _preview.layer.borderWidth = 0.5;
    _preview.layer.borderColor = UIColor.separatorColor.CGColor;
    [_scroll addSubview:_preview];

    _curLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, W - 40, 16)];
    _curLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _curLabel.textColor = UIColor.secondaryLabelColor;
    _curLabel.adjustsFontSizeToFitWidth = YES;
    [_scroll addSubview:_curLabel];

    /* ② 预设网格: 三列卡片, 点一下即时保存并应用 */
    NSArray *presets = diHomeBarPresets();
    CGFloat bw = (W - 40 - 8 * 2) / 3.0;
    CGFloat cardH = bw * 0.72 + 8 + 30;
    CGFloat y = 84;
    for (NSUInteger i = 0; i < presets.count; i++) {
        NSDictionary *p = presets[i];
        NSUInteger col = i % 3, row = i / 3;
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(20 + col * (bw + 8), y + row * (cardH + 8), bw, cardH)];
        card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        card.layer.cornerRadius = 12; card.layer.masksToBounds = YES;
        NSArray *cs = p[@"c"];
        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(6, 6, bw - 12, bw * 0.72)];
        bar.layer.cornerRadius = 8; bar.layer.masksToBounds = YES;
        if (cs.count <= 1) {
            bar.backgroundColor = diColorFromHexStr(cs.firstObject, UIColor.systemGray5Color);
        } else {
            CAGradientLayer *g = [CAGradientLayer layer];
            g.frame = bar.bounds;
            g.startPoint = CGPointMake(0, 0.5); g.endPoint = CGPointMake(1, 0.5);
            NSMutableArray *cc = [NSMutableArray array];
            for (NSString *h in cs) [cc addObject:(id)diColorFromHexStr(h, UIColor.grayColor).CGColor];
            g.colors = cc;
            [bar.layer addSublayer:g];
        }
        [card addSubview:bar];
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(4, bw * 0.72 + 8, bw - 8, 18)];
        lb.text = p[@"name"];
        lb.font = [UIFont systemFontOfSize:11];
        lb.textAlignment = NSTextAlignmentCenter;
        lb.adjustsFontSizeToFitWidth = YES;
        [card addSubview:lb];
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = card.bounds;
        btn.accessibilityIdentifier = [cs componentsJoinedByString:@","];
        [btn addTarget:self action:@selector(diPickPreset:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:btn];
        [_scroll addSubview:card];
    }
    NSInteger rows = (NSInteger)((presets.count + 2) / 3);

    /* ③ 自定义区: 放在**最后面**。输入几个色值, 预览就显示几个 */
    CGFloat yCustom = y + rows * (cardH + 8) + 16;
    UILabel *lbCustom = [[UILabel alloc] initWithFrame:CGRectMake(20, yCustom, W - 40, 18)];
    lbCustom.text = @"自定义颜色(1~6 个色值, 用逗号分隔, 如 00AEFF,B570E3)";
    lbCustom.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [_scroll addSubview:lbCustom];

    _hexField = [[UITextField alloc] initWithFrame:CGRectMake(20, yCustom + 24, W - 40, 46)];
    _hexField.borderStyle = UITextBorderStyleRoundedRect;
    _hexField.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    _hexField.placeholder = @"00AEFF 或 00AEFF,B570E3,FFD700";
    _hexField.autocorrectionType = UITextAutocorrectionTypeNo;
    _hexField.keyboardType = UIKeyboardTypeASCIICapable;
    /* 输入即刷新预览: 几个合法色值就画几条 */
    [_hexField addTarget:self action:@selector(diRefreshPreview) forControlEvents:UIControlEventEditingChanged];
    [_scroll addSubview:_hexField];

    /* 预填当前色值 */
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    NSString *cur = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)self.prefKey, (__bridge CFStringRef)kDomain)) ?: @"";
    _hexField.text = cur;

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    apply.frame = CGRectMake(20, yCustom + 78, W - 40, 48);
    [apply setTitle:@"应用自定义" forState:UIControlStateNormal];
    apply.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    apply.backgroundColor = UIColor.systemBlueColor;
    apply.layer.cornerRadius = 12; apply.layer.masksToBounds = YES;
    [apply setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [apply addTarget:self action:@selector(diSaveCustom) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:apply];

    _scroll.contentSize = CGSizeMake(W, yCustom + 78 + 48 + 24);

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(diDismissKb)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];

    [self diRefreshPreview];
}

- (void)diDismissKb { [self.view endEditing:YES]; }

/* 解析输入框: 合法 hex(6 位, 可带 #), 1~6 个; 一个不合法返回 nil */
- (NSArray *)diParseHex {
    NSMutableArray *ok = [NSMutableArray array];
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFabcdef"];
    for (NSString *h in [_hexField.text componentsSeparatedByString:@","]) {
        NSString *sg = [[h stringByReplacingOccurrencesOfString:@"#" withString:@""]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].uppercaseString;
        if (sg.length == 6 && [sg rangeOfCharacterFromSet:hexSet.invertedSet].location == NSNotFound)
            [ok addObject:sg];
        if (ok.count >= 6) break;   /* 2.8.37: 最多 6 个色值 */
    }
    return ok.count ? ok : nil;
}

/* 输入几个色值显示几个: 1 个=纯色, 2+ 个=横向渐变; 空/非法置灰并提示 */
- (void)diRefreshPreview {
    NSArray *cols = [self diParseHex];
    for (CALayer *l in _preview.layer.sublayers) {
        if ([l isKindOfClass:[CAGradientLayer class]]) [l removeFromSuperlayer];
    }
    if (!cols) {
        _preview.backgroundColor = UIColor.systemGray5Color;
        _curLabel.text = @"等待输入 1~6 个色值(逗号分隔)";
        return;
    }
    _preview.backgroundColor = [UIColor clearColor];
    if (cols.count <= 1) {
        _preview.backgroundColor = diColorFromHexStr(cols.firstObject, UIColor.systemGray5Color);
    } else {
        CAGradientLayer *g = [CAGradientLayer layer];
        g.frame = _preview.bounds;
        g.startPoint = CGPointMake(0, 0.5); g.endPoint = CGPointMake(1, 0.5);
        NSMutableArray *cc = [NSMutableArray array];
        for (NSString *h in cols) [cc addObject:(id)diColorFromHexStr(h, UIColor.grayColor).CGColor];
        g.colors = cc;
        [_preview.layer addSublayer:g];
    }
    _curLabel.text = [NSString stringWithFormat:@"当前 %lu 个色值: %@",
                      (unsigned long)cols.count, [cols componentsJoinedByString:@","]];
}

/* 点预设: 即时保存并应用 + 刷预览 + 回填输入框 */
- (void)diPickPreset:(UIButton *)b {
    NSArray *cs = [b.accessibilityIdentifier componentsSeparatedByString:@","];
    if (!cs.count) return;
    _hexField.text = b.accessibilityIdentifier;
    [self diRefreshPreview];
    [self diApplyColors:cs];
}

/* 应用自定义: 校验 1~6 个色值后写键 */
- (void)diSaveCustom {
    NSArray *cols = [self diParseHex];
    if (!cols) { diStep(@"配色: 色值不对(1~6 个, 逗号分隔)"); return; }
    [self diApplyColors:cols];
}

/* 写键 + 发 reload 通知(SpringBoard 侧下个 tick 重读生效) */
- (void)diApplyColors:(NSArray *)cols {
    NSString *joined = [cols componentsJoinedByString:@","];
    CFPreferencesSetAppValue((__bridge CFStringRef)self.prefKey, (__bridge CFPropertyListRef)joined, (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
    diStep(@"配色(%@): 已应用 %lu 个色值 %@", self.prefKey, (unsigned long)cols.count, joined);
}

- (void)diClose {
    if (self.navigationController) { [self.navigationController popViewControllerAnimated:YES]; return; }
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

@interface DIHomeBarPick : UIViewController
@end
@implementation DIHomeBarPick {
    UIScrollView *_scroll;
    NSMutableArray *_cards;
    UIView *_previewPill;
    CAGradientLayer *_previewGrad;
    UITextField *_hexField;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = DI_PAGE_BG;
    CGFloat W = self.view.bounds.size.width;
    if (W < 100) W = UIScreen.mainScreen.bounds.size.width;

    /* 2.7.11: 58 → 78。进栈后页面坐标原点就在系统导航栏下方, 58 只留了一点点,
       第一行内容(字体页是"批量输入", 横条页是胶囊预览)仍贴着导航栏底边。 */
    CGFloat topPad = 78, barH = 52;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, topPad, W, barH)];
    bar.backgroundColor = DI_PAGE_BG;
    diStyleOwnBar(self, bar, &topPad);   /* 2.7.9: 在导航栈里就隐藏自绘栏, 只留系统导航 */
    [self.view addSubview:bar];

    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    back.frame = CGRectMake(8, 4, 76, barH - 8);
    [back setTitle:@"‹ 返回" forState:UIControlStateNormal];
    back.titleLabel.font = [UIFont systemFontOfSize:17];
    back.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [back addTarget:self action:@selector(diClose) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:back];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(W / 2 - 70, 4, 140, barH - 8)];
    title.text = @"横条颜色";
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:17];
    [bar addSubview:title];

    /* 当前效果预览胶囊 */
    CGFloat py = topPad + barH + 16;
    UIView *pv = [[UIView alloc] initWithFrame:CGRectMake(16, py, W - 32, 72)];
    pv.backgroundColor = DI_CARD_BG;
    pv.layer.cornerRadius = 18;
    [self.view addSubview:pv];
    UILabel *cap = [[UILabel alloc] initWithFrame:CGRectMake(14, 6, 160, 14)];
    cap.text = @"当前效果";
    cap.font = [UIFont systemFontOfSize:11];
    cap.textColor = [UIColor secondaryLabelColor];
    [pv addSubview:cap];
    _previewPill = [[UIView alloc] initWithFrame:CGRectMake(24, 28, pv.bounds.size.width - 48, 12)];
    _previewPill.layer.cornerRadius = 6;
    _previewPill.layer.masksToBounds = YES;
    [pv addSubview:_previewPill];

    /* 2.5.13: 自定义色值区 —— 输入框 + 应用/添加, 支持 1~8 个逗号分隔 HEX */
    CGFloat cy = py + 88;
    UIView *cu = [[UIView alloc] initWithFrame:CGRectMake(16, cy, W - 32, 84)];
    cu.backgroundColor = DI_CARD_BG;
    cu.layer.cornerRadius = 14;
    [self.view addSubview:cu];

    _hexField = [[UITextField alloc] initWithFrame:CGRectMake(14, 10, cu.bounds.size.width - 28, 34)];
    _hexField.placeholder = @"自定义 HEX, 多个用逗号分隔 如 FF8C00,00C8FF";
    _hexField.font = [UIFont systemFontOfSize:13];
    _hexField.autocorrectionType = UITextAutocorrectionTypeNo;
    _hexField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    _hexField.returnKeyType = UIReturnKeyDone;
    [_hexField addTarget:self action:@selector(applyCustom:) forControlEvents:UIControlEventEditingDidEndOnExit];
    _hexField.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _hexField.layer.cornerRadius = 8;
    _hexField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 34)];
    _hexField.leftViewMode = UITextFieldViewModeAlways;
    [cu addSubview:_hexField];

    CGFloat by = 48, bw = 120;
    /* 2.5.18: 窄屏(≤375pt)时两个 120pt 按钮 + 间距会超宽, "应用"按钮会被挤出卡片外,
       手指点到卡片外面 → 这就是"自定义输入应用不生效"的原因。改成按卡片宽度自适应。 */
    CGFloat availW = cu.bounds.size.width - 28;
    CGFloat gap = 12;
    bw = (availW - gap) * 0.5;
    if (bw > 140) bw = 140;
    UIButton *applyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    applyBtn.frame = CGRectMake(14, by, bw, 34);
    applyBtn.layer.cornerRadius = 8;
    applyBtn.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    [applyBtn setTitle:@"应用" forState:UIControlStateNormal];
    applyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [applyBtn addTarget:self action:@selector(applyCustom:) forControlEvents:UIControlEventTouchUpInside];
    [cu addSubview:applyBtn];

    UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    addBtn.frame = CGRectMake(14 + bw + gap, by, bw, 34);
    addBtn.layer.cornerRadius = 8;
    addBtn.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    [addBtn setTitle:@"添加颜色" forState:UIControlStateNormal];
    addBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    [addBtn addTarget:self action:@selector(addCustom:) forControlEvents:UIControlEventTouchUpInside];
    [cu addSubview:addBtn];

    UILabel *hint2 = [[UILabel alloc] initWithFrame:CGRectMake(14, by + 40, availW, 16)];
    hint2.text = @"应用 = 替换全部颜色；添加 = 追加到末尾（最多 8 个）";
    hint2.font = [UIFont systemFontOfSize:10];
    hint2.textColor = [UIColor secondaryLabelColor];
    hint2.userInteractionEnabled = NO;
    [cu addSubview:hint2];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, cy + 96, W, self.view.bounds.size.height - cy - 108)];
    [self.view addSubview:_scroll];
    _cards = [NSMutableArray array];

    NSArray *presets = diHomeBarPresets();
    CGFloat cw = (W - 16 * 2 - 12) / 2, ch = 84, y = 8;
    for (NSUInteger i = 0; i < presets.count; i++) {
        NSDictionary *p = presets[i];
        if (i % 2 == 0 && i > 0) y += ch + 12;
        CGFloat x = (i % 2 == 0) ? 16 : 16 + cw + 12;
        UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
        card.frame = CGRectMake(x, y, cw, ch);
        card.backgroundColor = DI_CARD_BG;
        card.layer.cornerRadius = 14;
        card.layer.borderWidth = 1;
        card.layer.borderColor = [UIColor separatorColor].CGColor;
        card.tag = 200 + i;
        [card addTarget:self action:@selector(tapCard:) forControlEvents:UIControlEventTouchUpInside];

        CAGradientLayer *g = [CAGradientLayer layer];
        g.startPoint = CGPointMake(0, 0.5); g.endPoint = CGPointMake(1, 0.5);
        g.frame = CGRectMake(14, 14, cw - 28, 12);
        g.cornerRadius = 6; g.masksToBounds = YES;
        NSMutableArray *cols = [NSMutableArray array];
        for (NSString *h in p[@"c"]) [cols addObject:(id)diColorFromHexStr(h, [UIColor whiteColor]).CGColor];
        if (cols.count == 1) [cols addObject:cols.firstObject];
        g.colors = cols;
        [card.layer addSublayer:g];

        UILabel *nm = [[UILabel alloc] initWithFrame:CGRectMake(14, 34, cw - 28, 18)];
        nm.text = p[@"name"];
        nm.font = [UIFont systemFontOfSize:14];
        nm.textColor = [UIColor labelColor];
        nm.userInteractionEnabled = NO;
        [card addSubview:nm];

        UILabel *hx = [[UILabel alloc] initWithFrame:CGRectMake(14, 56, cw - 28, 16)];
        hx.text = [p[@"c"] componentsJoinedByString:@","];
        hx.font = [UIFont systemFontOfSize:10];
        hx.textColor = [UIColor secondaryLabelColor];
        hx.userInteractionEnabled = NO;
        [card addSubview:hx];

        [_scroll addSubview:card];
        [_cards addObject:card];
    }
    _scroll.contentSize = CGSizeMake(W, y + ch + 24);
    NSString *curHex = (__bridge NSString *)(CFPreferencesCopyAppValue(CFSTR("homeBarHexes"), (__bridge CFStringRef)kDomain)) ?: @"";
    if ([curHex isKindOfClass:NSString.class]) _hexField.text = curHex;
    [self diRefreshPreview];
}

- (void)diRefreshPreview {
    NSString *hex = (__bridge NSString *)(CFPreferencesCopyAppValue(CFSTR("homeBarHexes"), (__bridge CFStringRef)kDomain))
                    ?: @"FFFFFF";
    if (![hex isKindOfClass:NSString.class]) hex = @"FFFFFF";
    NSMutableArray *cols = [NSMutableArray array];
    for (NSString *h in [hex componentsSeparatedByString:@","]) {
        NSString *t = [h stringByReplacingOccurrencesOfString:@"#" withString:@""];
        if (t.length != 6) continue;
        CGColorRef cg = diColorFromHexStr(t, [UIColor whiteColor]).CGColor;
        if (cg) [cols addObject:(__bridge id)cg];   /* 2.7.35: 绝不往数组里塞 NULL */
    }
    if (!cols.count) cols = [(id)@[ (id)[UIColor whiteColor].CGColor ] mutableCopy];
    if (!_previewGrad) {
        _previewGrad = [CAGradientLayer layer];
        _previewGrad.startPoint = CGPointMake(0, 0.5);
        _previewGrad.endPoint = CGPointMake(1, 0.5);
        [_previewPill.layer addSublayer:_previewGrad];
    }
    _previewGrad.frame = _previewPill.bounds;
    _previewGrad.colors = cols;
}

/* 2.5.13: 解析输入框里的 HEX 列表
   2.5.18: 容错加固 —— 空格/分号/中文逗号/顿号/换行都当分隔符; 支持 3 位简写(自动展开);
   输入框为空时退回预览当前色, 不再直接报"没有有效 HEX"。 */
- (NSMutableArray<NSString *> *)parseHexField {
    NSString *raw = _hexField.text ?: @"";
    diStep(@"横条配色[输入]: '%@' 长度=%lu", raw, (unsigned long)raw.length);
    raw = [raw stringByReplacingOccurrencesOfString:@"#" withString:@""];
    raw = [raw stringByReplacingOccurrencesOfString:@"，" withString:@","];
    raw = [raw stringByReplacingOccurrencesOfString:@"、" withString:@","];
    raw = [raw stringByReplacingOccurrencesOfString:@"；" withString:@","];
    raw = [raw stringByReplacingOccurrencesOfString:@";" withString:@","];
    raw = [raw stringByReplacingOccurrencesOfString:@" " withString:@","];
    raw = [raw stringByReplacingOccurrencesOfString:@"\n" withString:@","];
    raw = [raw stringByReplacingOccurrencesOfString:@"\t" withString:@","];
    NSMutableArray *out = [NSMutableArray array];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *p in [raw componentsSeparatedByString:@","]) {
        NSString *h = [[p stringByTrimmingCharactersInSet:ws] uppercaseString];
        if (h.length == 3) {   /* 简写 F0C → FF00CC */
            h = [NSString stringWithFormat:@"%C%C%C%C%C%C",
                 [h characterAtIndex:0], [h characterAtIndex:0],
                 [h characterAtIndex:1], [h characterAtIndex:1],
                 [h characterAtIndex:2], [h characterAtIndex:2]];
        }
        if (h.length != 6) continue;
        unsigned v = 0;
        NSScanner *sc = [NSScanner scannerWithString:h];
        if ([sc scanHexInt:&v] && sc.isAtEnd && v <= 0xFFFFFF) [out addObject:h];
    }
    return out;
}
- (void)writeHexes:(NSArray<NSString *> *)cs {
    if (!cs.count) return;
    NSString *joined = [cs componentsJoinedByString:@","];
    CFPreferencesSetAppValue(CFSTR("homeBarHexes"), (__bridge CFPropertyListRef)joined,
                             (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
    diColorChangedNotify();
    [_hexField resignFirstResponder];
    [self diRefreshPreview];
}
- (void)applyCustom:(UIButton *)b {
    [_hexField resignFirstResponder];
    NSMutableArray *cs = [self parseHexField];
    if (!cs.count) {
        /* 2.5.18: 空输入时提示更明确, 避免用户以为是"按了没反应" */
        if (![[_hexField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length])
            diStep(@"横条配色: 请先在输入框里填 HEX, 例如 FF8C00");
        else
            diStep(@"横条配色: '%@' 不是有效 HEX(需 6 位, 如 FF8C00)", _hexField.text);
        return;
    }
    [self writeHexes:cs];
    diStep(@"横条配色: 自定义已应用 %@", [cs componentsJoinedByString:@","]);
}
- (void)addCustom:(UIButton *)b {
    NSMutableArray *cs = [self parseHexField];
    if (!cs.count) { diStep(@"横条配色: 自定义输入没有有效 HEX"); return; }
    NSMutableArray *cur = [NSMutableArray array];
    NSString *hex = (__bridge NSString *)(CFPreferencesCopyAppValue(CFSTR("homeBarHexes"), (__bridge CFStringRef)kDomain)) ?: @"";
    if ([hex isKindOfClass:NSString.class]) {
        for (NSString *h in [hex componentsSeparatedByString:@","]) {
            NSString *t = [[h stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] uppercaseString];
            if (t.length == 6) [cur addObject:t];
        }
    }
    for (NSString *h in cs) if (cur.count < 8) [cur addObject:h];
    [self writeHexes:cur];
    diStep(@"横条配色: 自定义已添加, 共 %lu 个", (unsigned long)cur.count);
}

/* 2.7.35: 点卡片切颜色 —— 整段 @try, 并对预设数据做类型校验。
   之前 `presets[i][@"c"]` 一旦拿到的不是数组(或下标越界)就会直接抛异常崩掉设置页,
   现在异常只进日志, 页面照常活着。 */
- (void)tapCard:(UIButton *)b {
    @try {
        NSInteger i = (NSInteger)b.tag - 200;
        NSArray *presets = diHomeBarPresets();
        if (i < 0 || i >= (NSInteger)presets.count) return;
        id item = presets[(NSUInteger)i];
        if (![item isKindOfClass:NSDictionary.class]) return;
        NSDictionary *d = (NSDictionary *)item;
        id cs = d[@"c"];
        if (![cs isKindOfClass:NSArray.class]) return;
        NSArray *cols = (NSArray *)cs;
        NSMutableArray *ok = [NSMutableArray array];
        for (id h in cols) if ([h isKindOfClass:NSString.class] && [(NSString *)h length] == 6) [ok addObject:h];
        if (!ok.count) return;
        NSString *joined = [ok componentsJoinedByString:@","];
        CFPreferencesSetAppValue(CFSTR("homeBarHexes"), (__bridge CFPropertyListRef)joined,
                                 (__bridge CFStringRef)kDomain);
        CFPreferencesSetAppValue(CFSTR("homeBarHex"), (__bridge CFPropertyListRef)ok.firstObject,
                                 (__bridge CFStringRef)kDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        postReload();
        diColorChangedNotify();
        [self diRefreshPreview];
        diStep(@"横条配色: 已应用 %@", [d[@"name"] description] ?: @"");
    } @catch (NSException *e) {
        diStep(@"横条配色: 切换异常 %@", e.reason ?: @"(未知)");
    }
}

- (void)diClose {
    diStep(@"横条配色: 关闭");
    /* 2.7.35: 若是被 push 进设置页导航栈的(绝大多数情况), 走 pop;
       只有独立窗口那条退路才需要关窗口。之前一律关窗口, push 进来时点"‹ 返回"没反应。 */
    if (self.navigationController && self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    diCloseBarWindow();
}
@end

/* 2.7.35: 用户报"锁屏通知 → 横条颜色 → 点切换颜色闪退"。
   这里是入口, 整段包异常保护: ① 先把上一个窗口彻底收干净(旧窗口没清 rootViewController
   就再开新的, 会留下野窗口/重复视图树, 是这类崩溃最常见的来源);
   ② 创建与 push 全程 @try, 任何一步出问题都只是打日志, 不再让设置页直接崩掉。 */
static void diCloseBarWindow(void) {
    UIWindow *w = gBarWin;
    gBarWin = nil;
    if (!w) return;
    @try {
        w.rootViewController = nil;
        w.hidden = YES;
    } @catch (NSException *e) { diStep(@"横条颜色: 关闭旧窗口异常 %@", e.reason); }
}
static void diOpenHomeBarPickWindow(void) {
    @try {
        diCloseBarWindow();
        DIHomeBarPick *vc = [[DIHomeBarPick alloc] initWithNibName:nil bundle:nil];
        UIWindow *w = nil;
        diPushPanel(vc, @"横条颜色", &w);
        gBarWin = w;
    } @catch (NSException *e) {
        diStep(@"横条颜色: 打开失败 %@", e.reason ?: @"(未知)");
    }
}

#pragma mark - 歌词岛(2.5.23-3 从老版 2.2.x 完整迁移, 只保留歌词岛, 录屏岛不用)


@implementation DIPrefsController (ZoneLink)
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:NULL get:NULL detail:cls cell:PSLinkCell edit:nil];
    return s;
}

/* 2.6.24: 手动推入子页面 —— 2.6.22/2.6.23 点进页闪退的根因:
   PSLinkCell 的 detail:cls 由 Preferences 框架自己 alloc/init 目标控制器,
   那条路径对 DIPrefsController 子类不成立(它的 init 依赖本 bundle 的上下文),
   一进去就抛异常 → 闪退。改为点一下自己 alloc + push, 并全程 @try 兜住,
   任何异常都只弹提示不崩。 */
/* 2.6.25: 全局异常兜底 —— 点进页若还有未捕获异常, 至少先落盘现场再让系统处理 */
/* 2.7.20: 这个 hook 从来没被调用过, 且引用了已删除的 diUncaught —— 一并清掉,
   保证 prefs 二进制的外部符号与 2.7.13 完全一致(不再多出任何 libexecinfo 符号)。 */
- (PSSpecifier *)pageSpec:(NSString *)name cls:(Class)cls {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
    [s setButtonAction:@selector(diOpenPage:)];
    [s setProperty:NSStringFromClass(cls) forKey:@"diPageCls"];
    return s;
}
- (void)diOpenPage:(PSSpecifier *)spec {
    /* 2.6.26: 三道保险 —— 类存在性 / 实例化 / 推入全都 @try, 任何一步失败只提示不崩 */
    @try {
        NSString *cn = [spec propertyForKey:@"diPageCls"];
        Class cls = cn.length ? NSClassFromString(cn) : Nil;
        diStep(@"点进页: %@ → 类=%@ → class=%@ nav=%@",
               spec.name, cn, cls ? @"找到" : @"缺失", self.navigationController ? @"有" : @"无");
        if (!cls) { [self toast:[NSString stringWithFormat:@"页面未找到: %@", cn ?: @"(空)"]]; return; }

        UIViewController *vc = nil;
        @try {
            vc = [[cls alloc] init];
        } @catch (NSException *e) {
            diStep(@"点进页 init 异常: %@ — %@", e.name, e.reason);
            vc = nil;
        }
        if (!vc) { [self toast:[NSString stringWithFormat:@"页面创建失败: %@", cn]]; return; }
        vc.title = spec.name;
        diStep(@"点进页: 实例化成功 %@", NSStringFromClass(vc.class));

        /* 先在自己的导航栈里 push; 没有导航栈(或 push 抛异常)就退回模态 */
        BOOL pushed = NO;
        UINavigationController *nav = self.navigationController;
        if (nav && nav.view.window) {
            @try { [nav pushViewController:vc animated:YES]; pushed = YES; }
            @catch (NSException *e) { diStep(@"点进页 push 异常: %@ — %@", e.name, e.reason); pushed = NO; }
        }
        if (!pushed) {
            UINavigationController *n2 = [[UINavigationController alloc] initWithRootViewController:vc];
            n2.modalPresentationStyle = UIModalPresentationPageSheet;
            [self presentViewController:n2 animated:YES completion:nil];
            diStep(@"点进页: 模态弹出 %@", spec.name);
        } else {
            diStep(@"点进页: 已推入 %@", spec.name);
        }
    } @catch (NSException *e) {
        diStep(@"点进页异常: %@ — %@\n%@", e.name, e.reason, e.callStackSymbols);
        [self toast:[NSString stringWithFormat:@"打开失败: %@", e.reason ?: e.name]];
    }
}

@end

/* 2.6.1: 歌词岛(2.2.45 原版) —— 合并页 = 上半左侧专辑 + 下半右侧音频 */
@interface DIMiniBaseController (DIWallpaperName)
- (id)readWallpaperName:(PSSpecifier *)sp;
@end
@implementation DIMiniBaseController
/* ===== 2.2.45 原版照搬: 歌词岛合并页自管基类 ===== */
- (NSInteger)diSliderRowForIndexPath:(NSIndexPath *)ip {
    NSArray *specs = self.specifiers;
    NSInteger sec = -1, swRow = -1;
    for (NSUInteger i = 0; i < specs.count; i++) {
        PSSpecifier *sp = specs[i];
        if (sp.cellType == PSGroupCell) { sec++; continue; }
        if (sec == ip.section) {
            if ([sp propertyForKey:@"range"]) {
                if (swRow < 0) return -1;
                NSInteger idx = ip.row - swRow - 1;
                if (idx >= 0 && idx <= 3) return idx;
                return -1;
            }
            if (sp.cellType == PSSwitchCell) swRow = ip.row;
        }
    }
    return -1;
}

- (double)numValueD:(NSString *)key def:(double)def {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return v ? [v doubleValue] : def;
}
- (double)numStepForKey:(NSString *)key {
    return ([key containsString:@"FPS"] ? 1.0 : 0.5);
}
- (id)readSmallAnimName:(PSSpecifier *)sp { return [self folderNameForKey:@"smallAnimFolder"]; }
- (id)readAudioAnimName:(PSSpecifier *)sp { return [self folderNameForKey:@"miniAudioFolder"]; }
/* 2.6.10: 专辑遮罩素材摘要(独立页选完后主页面显示当前项) */
- (id)readAlbumMaskName:(PSSpecifier *)sp {
    NSString *cur = readPrefString(kDIAlbumMaskKey);
    if ([cur isEqualToString:@"__none__"]) return @"不遮罩";
    NSArray<NSString *> *list = DIMaskListAssets();
    if (!list.count) return @"(目录无 png)";
    if (cur.length && [list containsObject:cur]) return cur;
    return [NSString stringWithFormat:@"%@（默认）", list.firstObject];
}

- (id)readMaskAnimName:(PSSpecifier *)sp {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("maskAnimFolder"), (__bridge CFStringRef)kDomain));
    NSString *name = ([v isKindOfClass:NSString.class] && [(NSString *)v length]) ? v : nil;
    if (name) {
        BOOL isDir = NO;
        NSString *p = [kMaskDir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] && isDir) return name;
    }
    return @"未选择";
}
/* 2.6.3: 遮罩/旋转用带小数的滑杆行(range + 自定义渲染已支持 0.5 步进) */
- (PSSpecifier *)numSliderD:(NSString *)label key:(NSString *)key def:(double)def mn:(double)mn mx:(double)mx {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:label
        target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSliderCell edit:nil];
    [sp setProperty:key forKey:@"key"];
    [sp setProperty:kDomain forKey:@"defaults"];
    [sp setProperty:@(def) forKey:@"default"];
    [sp setProperty:@(mn) forKey:@"min"];
    [sp setProperty:@(mx) forKey:@"max"];
    [sp setProperty:@{ @"min": @(mn), @"max": @(mx), @"label": label } forKey:@"range"];
    return sp;
}
- (NSString *)folderNameForKey:(NSString *)key {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    NSString *name = ([v isKindOfClass:NSString.class] && [(NSString *)v length]) ? v : nil;
    if (name) {
        BOOL isDir = NO;
        NSString *p = [kFrameDir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] && isDir) return name;
    }
    return @"默认(全部帧)";
}
- (NSString *)numFormat:(double)v {
    return (fabs(v - round(v)) < 0.01) ? [NSString stringWithFormat:@"%d", (int)round(v)] : [NSString stringWithFormat:@"%.1f", v];
}
- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key) return nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    if (v && ![v isKindOfClass:NSString.class] && ![v isKindOfClass:NSNumber.class]) v = nil;
    return v ?: [spec propertyForKey:@"default"];
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key.length) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)kDomain);
    /* 2.8.93: 拖滑杆时这里每秒被调几十次 —— 以前每次都 synchronize + 直发通知,
       写盘互锁 + SpringBoard 全量刷新叠在一起, 拖快就崩。SetAppValue 本身已经
       递给 cfprefsd, 不需要每条都 fsync; 通知交给 postReload 合并。 */
    postReload();
}
- (PSSpecifier *)groupSpec:(NSString *)header footer:(NSString *)footer {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:header target:nil
        set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
    if (footer) [sp setProperty:footer forKey:@"footerText"];
    return sp;
}
- (PSSpecifier *)switchSpec:(NSString *)name key:(NSString *)key def:(id)def {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSwitchCell edit:nil];
    [sp setProperty:key forKey:@"key"];
    [sp setProperty:kDomain forKey:@"defaults"];
    [sp setProperty:def forKey:@"default"];
    return sp;
}
- (PSSpecifier *)buttonSpec:(NSString *)name action:(SEL)sel {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
    [sp setButtonAction:sel];
    return sp;
}
/* 2.8.87: 二级页入口(展开定义) —— 与主页那几个入口同一形态 */
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls {
    return [PSSpecifier preferenceSpecifierNamed:name target:self
        set:NULL get:NULL detail:cls cell:PSLinkCell edit:nil];
}
- (PSSpecifier *)numSlider:(NSString *)label key:(NSString *)key def:(int)def mn:(int)mn mx:(int)mx {
    double v = [self numValueD:key def:def];
    if (v < mn) v = mn; if (v > mx) v = mx;
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:label
        target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSliderCell edit:nil];
    [sp setProperty:key forKey:@"key"];
    [sp setProperty:kDomain forKey:@"defaults"];
    [sp setProperty:@(def) forKey:@"default"];
    [sp setProperty:@(mn) forKey:@"min"];
    [sp setProperty:@(mx) forKey:@"max"];
    [sp setProperty:@{ @"min": @(mn), @"max": @(mx), @"label": label } forKey:@"range"];
    return sp;
}
- (void)reloadSpecifiers { _specifiers = nil; [super reloadSpecifiers]; }


- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [[self buildSpecifiers] mutableCopy];
    return _specifiers;
}
- (NSArray *)buildSpecifiers { return @[]; }

- (void)diWrite:(NSString *)key value:(double)v {
    if (!key.length) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(v), (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
}
- (void)diApplyValue:(double)v forBox:(UIView *)box syncSlider:(BOOL)sync {
    double mn = [objc_getAssociatedObject(box, "mn") doubleValue];
    double mx = [objc_getAssociatedObject(box, "mx") doubleValue];
    NSString *key = objc_getAssociatedObject(box, "key");
    double st = [self numStepForKey:key];
    v = round(v / st) * st;
    if (v < mn) v = mn; if (v > mx) v = mx;
    [self diWrite:key value:v];
    UISlider *sl = objc_getAssociatedObject(box, "slider");
    UILabel *vl = objc_getAssociatedObject(box, "val");
    if (sync && sl && fabs(round(sl.value / st) * st - v) > 0.01) sl.value = v;
    vl.text = [self numFormat:v];
}
- (void)diSliderMoved:(UISlider *)sl {
    UIView *box = sl.superview;
    NSString *key = objc_getAssociatedObject(box, "key");
    double st = [self numStepForKey:key];
    double v = round(sl.value / st) * st;
    sl.value = v;
    [self diApplyValue:v forBox:box syncSlider:NO];
}
- (void)diStep:(UIButton *)btn {
    UIView *box = btn.superview;
    UISlider *sl = objc_getAssociatedObject(box, "slider");
    NSString *key = objc_getAssociatedObject(box, "key");
    double st = [self numStepForKey:key];
    double v = round(sl.value / st) * st + (btn.tag == 1 ? st : -st);
    [self diApplyValue:v forBox:box syncSlider:YES];
}
- (void)diTapValue:(UITapGestureRecognizer *)tap {
    UIView *box = tap.view.superview;
    UILabel *vl = objc_getAssociatedObject(box, "val");
    NSString *label = objc_getAssociatedObject(box, "label");
    int mn = [objc_getAssociatedObject(box, "mn") intValue];
    int mx = [objc_getAssociatedObject(box, "mx") intValue];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:label
        message:[NSString stringWithFormat:@"范围 %d ~ %d", mn, mx]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = vl.text;
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        tf.textAlignment = NSTextAlignmentCenter;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIView *wbox = box;
    __weak UIViewController *wself = self;
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        UIView *bb = wbox; UIViewController *ss = wself;
        if (!bb || !ss) return;
        double v = [a.textFields.firstObject.text doubleValue];
        [(DIMiniBaseController *)ss diApplyValue:v forBox:bb syncSlider:YES];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    @try {
        @try { [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath]; } @catch (__unused NSException *e) {}
        PSSpecifier *sp = nil;
        SEL selFP = NSSelectorFromString(@"specifierForIndexPath:");
        if ([self respondsToSelector:selFP]) {
            @try {
                id (*fp)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
                sp = fp(self, selFP, indexPath);
            } @catch (__unused NSException *e) { sp = nil; }
        }
        if (!sp) {
            __block NSInteger cursor = 0; NSInteger target = indexPath.section;
            NSArray *all = self.specifiers;
            NSInteger sec = -1;
            for (NSUInteger i = 0; i < all.count; i++) {
                PSSpecifier *x = all[i];
                if (x.cellType == PSGroupCell) { sec++; cursor = 0; continue; }
                if (sec == target) {
                    if (cursor == indexPath.row) { sp = x; break; }
                    cursor++;
                }
            }
        }
        if (!sp) return;
        /* 2.6.30: 字体颜色行右侧渐变预览条 (子页复用主页同一套画法) */
        if ([[sp propertyForKey:@"diKind"] isEqualToString:@"gradient"]) {
            @try {
                UIView *bar = objc_getAssociatedObject(cell, "diGradBar");
                if (!bar) {
                    bar = [[UIView alloc] initWithFrame:CGRectZero];
                    bar.userInteractionEnabled = NO;
                    bar.layer.cornerRadius = 10;
                    bar.layer.masksToBounds = YES;
                    bar.layer.borderWidth = 1;
                    bar.layer.borderColor = [UIColor separatorColor].CGColor;
                    CAGradientLayer *gl = [CAGradientLayer layer];
                    gl.startPoint = CGPointMake(0, 0.5);
                    gl.endPoint = CGPointMake(1, 0.5);
                    [bar.layer addSublayer:gl];
                    objc_setAssociatedObject(bar, "gl", gl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [cell.contentView addSubview:bar];
                    objc_setAssociatedObject(cell, "diGradBar", bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                CGFloat cw = cell.contentView.bounds.size.width;
                CGFloat ch = cell.contentView.bounds.size.height;
                if (cw < 10) cw = 320;
                if (ch < 10) ch = 44;
                CGFloat bw = MIN(150.0, cw * 0.42);
                bar.frame = CGRectMake(cw - bw - 22, (ch - 24) / 2, bw, 24);
                CAGradientLayer *gl = objc_getAssociatedObject(bar, "gl");
                gl.frame = bar.bounds;
                NSArray *cs = diReadColors();
                NSMutableArray *cols = [NSMutableArray array];
                for (NSString *h in cs) {
                    UIColor *c = diColorFromHexStr(h, [UIColor whiteColor]);
                    [cols addObject:(id)c.CGColor];
                }
                if (cols.count == 0) [cols addObject:(id)[UIColor whiteColor].CGColor];
                if (cols.count == 1) [cols addObject:cols.firstObject];
                gl.colors = cols;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            } @catch (__unused NSException *e) {}
            return;
        }
        NSDictionary *range0 = [sp propertyForKey:@"range"];
        if (!range0) {
            /* 素材名称行: 右侧显示当前文件夹名 */
            @try {
                NSString *nk = [sp propertyForKey:@"nameKey"];
                if (nk) {
                    NSString *nm = ([nk isEqualToString:@"wpLightAsset"] || [nk isEqualToString:@"wpDarkAsset"])
                        ? [self readWallpaperName:sp] : [self folderNameForKey:nk];
                    if ([cell respondsToSelector:@selector(setValue:)])
                        ((void (*)(id, SEL, id))objc_msgSend)(cell, @selector(setValue:), nm);
                    if ([cell respondsToSelector:@selector(valueLabel)]) {
                        UILabel *vl2 = ((id (*)(id, SEL))objc_msgSend)(cell, @selector(valueLabel));
                        if (vl2) { vl2.text = nm; vl2.textColor = [UIColor secondaryLabelColor]; }
                    }
                    if (cell.detailTextLabel) cell.detailTextLabel.text = nm;
                }
            } @catch (__unused NSException *e) {}
            return;
        }
        NSDictionary *range = range0;
        NSString *key = [sp propertyForKey:@"key"];
        NSString *label = range[@"label"] ?: sp.name;
        double mn = [range[@"min"] doubleValue], mx = [range[@"max"] doubleValue];
        double v = [self numValueD:key def:[[sp propertyForKey:@"default"] doubleValue]];
        double st = [self numStepForKey:key];
        v = round(v / st) * st;
        if (v < mn) v = mn; if (v > mx) v = mx;

        for (UIView *sv in cell.contentView.subviews) if ([sv isKindOfClass:UISlider.class]) sv.hidden = YES;
        for (UIView *sv in cell.subviews) if ([sv isKindOfClass:UISlider.class]) sv.hidden = YES;
        cell.textLabel.text = @"";
        cell.detailTextLabel.text = @"";

        CGFloat cw = cell.contentView.bounds.size.width, ch = cell.contentView.bounds.size.height;
        if (cw < 10) cw = tableView.bounds.size.width - 20;
        if (ch < 10) ch = 44;
        UIView *box = objc_getAssociatedObject(cell, "diMiniBox");
        if (!box) {
            box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cw, ch)];
            box.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            box.backgroundColor = [UIColor clearColor];
            UIButton *minus = [UIButton buttonWithType:UIButtonTypeSystem];
            [minus setTitle:@"-" forState:UIControlStateNormal];
            minus.titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightMedium];
            minus.tag = 0;
            [minus addTarget:self action:@selector(diStep:) forControlEvents:UIControlEventTouchUpInside];
            UISlider *sl = [UISlider new];
            sl.minimumTrackTintColor = [UIColor systemBlueColor];
            [sl addTarget:self action:@selector(diSliderMoved:) forControlEvents:UIControlEventValueChanged];
            UIButton *plus = [UIButton buttonWithType:UIButtonTypeSystem];
            [plus setTitle:@"+" forState:UIControlStateNormal];
            plus.titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightMedium];
            plus.tag = 1;
            [plus addTarget:self action:@selector(diStep:) forControlEvents:UIControlEventTouchUpInside];
            UILabel *vl = [UILabel new];
            vl.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightRegular];
            vl.textAlignment = NSTextAlignmentRight;
            vl.textColor = [UIColor systemBlueColor];
            vl.userInteractionEnabled = YES;
            [vl addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(diTapValue:)]];
            UILabel *tl = [UILabel new];
            tl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
            [box addSubview:tl]; [box addSubview:minus]; [box addSubview:sl]; [box addSubview:plus]; [box addSubview:vl];
            [cell.contentView addSubview:box];
            objc_setAssociatedObject(cell, "diMiniBox", box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(box, "title", tl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(box, "slider", sl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(box, "val", vl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(box, "minus", minus, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(box, "plus", plus, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(box, "key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(box, "label", label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(box, "mn", @(mn), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(box, "mx", @(mx), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        box.frame = CGRectMake(0, 0, cw, ch);
        UILabel *tl = objc_getAssociatedObject(box, "title");
        UIButton *minus = objc_getAssociatedObject(box, "minus");
        UIButton *plus = objc_getAssociatedObject(box, "plus");
        UISlider *sl = objc_getAssociatedObject(box, "slider");
        UILabel *vl = objc_getAssociatedObject(box, "val");
        CGFloat pad = 12, tw = 88, bw = 30, vw = 46;
        tl.text = label;
        tl.textAlignment = NSTextAlignmentLeft;
        tl.numberOfLines = 1;
        tl.adjustsFontSizeToFitWidth = YES;
        tl.minimumScaleFactor = 0.7;
        tl.frame = CGRectMake(pad, 0, tw, ch);
        minus.frame = CGRectMake(pad + tw - 4, 0, bw, ch);
        plus.frame = CGRectMake(cw - pad - vw - bw, 0, bw, ch);
        sl.frame = CGRectMake(pad + tw + bw - 6, (ch - 31) / 2, cw - (pad + tw + bw - 6) - (pad + vw + bw) + 4, 31);
        vl.frame = CGRectMake(cw - pad - vw, 0, vw, ch);
        sl.minimumValue = mn; sl.maximumValue = mx;
        if (fabs(sl.value - v) > 0.01) sl.value = v;
        vl.text = [self numFormat:v];
        box.hidden = NO;
        return;
    } @catch (__unused NSException *e) {}
}
@end

/* 2.6.10: 专辑遮罩素材选择页 —— 独立 PSListController, 不继承主控制器。
 */
@interface DIMaskPicker : PSListController
@end

/* 2.7.0: 壁纸素材选择页 —— 与遮罩页同构, 只是扫描目录和写入的键不同 */
/* 2.7.4: 用户明确要求"跟小岛素材那样一样的效果" —— 点"浅色/深色"一句话进平铺网格,
   不能再有"外壳页 + 按钮 + 自动 push"的两段式(那样会先进一个列表页再弹一层, 很难用)。
   做法: 把平铺网格直接做进 PSListController 的 tableHeaderView(高度 = 整屏),
   点进来即是一屏网格, 右上角"相册导入", 长按删除, 点一下即选中 —— 与岛素材页操作完全一致。
   仍然继承 PSListController(DI 的素材页都是这个形态, 从未崩过), 只是不渲染任何 specifier。 */
@interface DIWallpaperPicker : PSListController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) UICollectionView *grid;
@property (nonatomic, copy) NSString *prefKey;
@property (nonatomic, assign) BOOL isDark;
@end
@interface DIWallpaperPickerDark : DIWallpaperPicker @end

@implementation DIMaskPicker
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"专辑遮罩素材";
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
        NSString *cur = readPrefString(kDIAlbumMaskKey);

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
        writePrefString(key, kDIAlbumMaskKey);
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

/* 2.7.0: 壁纸素材选择页 —— 与遮罩页同构, 只是扫描目录和写入的键不同 */
@implementation DIWallpaperPicker
/* 2.7.4: 选中哪一套由 specifier 的 nameKey 决定(detail: 会把 specifier 传进来) */
/* 2.7.6: 让它真正是一个"系统二级页" —— 系统才给左滑返回、才有"‹ 上一级"的自动返回按钮。
   上一版把导航栏藏了、自己塞了个 UICollectionView 当 tableHeaderView, 看起来像二级页,
   但实际上退出只能点按钮(用户说的"不是正确的二进页")。
   现在: 导航栏正常显示(title = 浅色/深色背景, 左上角自动是"‹ 设置/控制中心"),
   网格照旧铺满, 不再自己造返回按钮。 */
- (void)viewDidLoad {
    [super viewDidLoad];
    self.isDark = [self isKindOfClass:[DIWallpaperPickerDark class]];
    self.prefKey = self.isDark ? @"wpDarkAsset" : @"wpLightAsset";
    self.title = self.isDark ? @"深色素材" : @"浅色素材";
    self.navigationController.navigationBar.hidden = NO;
    self.navigationController.interactivePopGestureRecognizer.enabled = YES;

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL d = NO;
    if (![fm fileExistsAtPath:kDIWallpaperRoot isDirectory:&d] || !d)
        [fm createDirectoryAtPath:kDIWallpaperRoot withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0777} error:NULL];
    /* 2.7.32: 只建总目录, 不再建 浅色/深色 子目录 */
    d = NO;
    if (![fm fileExistsAtPath:kDIWallpaperRoot isDirectory:&d] || !d)
        [fm createDirectoryAtPath:kDIWallpaperRoot withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0777} error:NULL];

    UICollectionViewFlowLayout *fl = [UICollectionViewFlowLayout new];
    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    CGFloat iw = (w - 16 * 2 - 12) / 3.0;
    fl.itemSize = CGSizeMake(iw, iw * 0.72 + 20);
    fl.minimumInteritemSpacing = 6;
    fl.minimumLineSpacing = 14;
    fl.sectionInset = UIEdgeInsetsMake(14, 16, 24, 16);
    UICollectionView *cv = [[UICollectionView alloc] initWithFrame:CGRectMake(0, 0, w, 100)
                                               collectionViewLayout:fl];
    cv.backgroundColor = DI_PAGE_BG;
    cv.dataSource = self;
    cv.delegate = self;
    cv.alwaysBounceVertical = YES;
    [cv registerClass:[DIPreviewCell class] forCellWithReuseIdentifier:@"cell"];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(longPressDelete:)];
    [cv addGestureRecognizer:lp];
    self.grid = cv;

    /* 表格只当容器: 网格铺满整个 tableHeaderView, 底下不留空 specifier */
    self.table.tableHeaderView = cv;
    self.table.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.table.backgroundColor = DI_PAGE_BG;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"相册导入" style:UIBarButtonItemStylePlain
        target:self action:@selector(importFromAlbum)];
}

/* 不生成任何行 —— 整个页面就是那一屏网格 */
- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = (NSMutableArray *)[NSArray array];
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    CGSize bs = self.table.bounds.size;
    if (bs.height > 1 && !CGSizeEqualToSize(self.grid.frame.size, bs)) {
        self.grid.frame = CGRectMake(0, 0, bs.width, bs.height);
        self.table.tableHeaderView = self.grid;   /* 重新赋值才会重算 header 高度 */
    }
    [self.grid reloadData];
}

- (NSArray<NSString *> *)files { return diWallpaperFiles(); }   /* 2.7.32: 深浅合一套, 列目录下全部素材 */
- (NSString *)curValue { return readPrefString(self.prefKey); }

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)[self files].count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    DIPreviewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:ip];
    NSArray<NSString *> *fs = [self files];
    if (ip.item >= (NSInteger)fs.count) return cell;
    NSString *name = fs[ip.item];
    NSString *cur = [self curValue];
    BOOL sel = ([cur isKindOfClass:NSString.class] && [cur isEqualToString:name]);
    cell.lb.text = name;
    cell.lb.textColor = sel ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];
    cell.iv.layer.borderWidth = sel ? 2 : 0;
    cell.iv.layer.borderColor = [UIColor systemBlueColor].CGColor;

    NSString *absPath = [kDIWallpaperRoot stringByAppendingPathComponent:name];
    UIImage *thumb = [diThumbCache() objectForKey:absPath];
    if (thumb) { cell.iv.image = thumb; return cell; }
    cell.iv.image = nil;
    __weak DIPreviewCell *wc = cell;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        UIImage *ui = nil;
        if (diWallpaperIsVideoName(name)) {
            AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:absPath] options:nil];
            AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:a];
            gen.appliesPreferredTrackTransform = YES;
            gen.maximumSize = CGSizeMake(360, 360);
            CGImageRef cg = [gen copyCGImageAtTime:CMTimeMake(5, 10) actualTime:NULL error:NULL];
            if (cg) { ui = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
        } else {
            CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:absPath], NULL);
            if (src) {
                NSDictionary *opts = @{(__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                       (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @360,
                                       (__bridge id)kCGImageSourceCreateThumbnailWithTransform: @YES};
                CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
                if (cg) { ui = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
                CFRelease(src);
            }
        }
        if (ui) [diThumbCache() setObject:ui forKey:absPath];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([wc.lb.text isEqualToString:name]) wc.iv.image = ui;
        });
    });
    return cell;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    NSArray<NSString *> *fs = [self files];
    if (ip.item >= (NSInteger)fs.count) return;
    NSString *name = fs[ip.item];
    CFPreferencesSetAppValue((__bridge CFStringRef)self.prefKey,
                             (__bridge CFPropertyListRef)name, (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.abgg332.driftisland/prefsChanged"), NULL, NULL, YES);
    [cv reloadData];
}

- (void)longPressDelete:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [gr locationInView:self.grid];
    NSIndexPath *ip = [self.grid indexPathForItemAtPoint:p];
    NSArray<NSString *> *fs = [self files];
    if (!ip || ip.item >= (NSInteger)fs.count) return;
    NSString *name = fs[ip.item];
    NSString *path = [kDIWallpaperRoot stringByAppendingPathComponent:name];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除素材"
        message:[NSString stringWithFormat:@"确定删除 \"%@\" 吗?\n此操作不可恢复", name]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        if ([[self curValue] isEqualToString:name]) {
            CFPreferencesSetAppValue((__bridge CFStringRef)self.prefKey,
                                     (__bridge CFPropertyListRef)@"" , (__bridge CFStringRef)kDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("com.abgg332.driftisland/prefsChanged"), NULL, NULL, YES);
        }
        [self.grid reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)importFromAlbum {
    DIAlbumImporter *imp = [DIAlbumImporter new];
    imp.grid = self.grid;
    imp.dir = kDIWallpaperRoot;   /* 2.7.32: 导入直接进总目录 */
    imp.allowImage = YES;
    [imp openPickerFrom:self];
}
@end
@implementation DIWallpaperPickerDark @end

/* 小岛素材选择页(键独立, 与主页展开岛素材分开) */
@implementation DIFrameFoldersMini
- (NSString *)prefKey { return @"smallAnimFolder"; }
@end
@implementation DIFrameFoldersAudio
- (NSString *)prefKey { return @"miniAudioFolder"; }
@end
@implementation DIFrameFoldersMask
- (NSString *)prefKey { return @"maskAnimFolder"; }
- (NSString *)rootDir { return kMaskDir; }  /* 2.6.4: 遮罩素材独立目录 */
@end


/* ===== 2.8.12: 歌词岛合并页回归(2.2.24 原版形态, 2.8.4/2.8.5 曾下架) =====
   上半=左侧专辑帧率, 下半=右侧音频帧率, 下面=专辑遮罩设置。
   遮罩素材行 2.8.12 起改链 DIMaskPicker(png 直选, 写 diAlbumMaskAsset) ——
   旧版链的是 DIFrameFoldersMask(文件夹, 写 maskAnimFolder), 与运行时读的键
   对不上, 这就是"遮罩选了却不生效"的根因。 */
@implementation DILyricsIslandSettings
- (NSArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    /* 左侧专辑 */
    [specs addObject:[self groupSpec:@"左侧专辑" footer:nil]];
    [specs addObject:[self switchSpec:@"启用动画" key:@"miniAnimOn" def:@NO]];
    [specs addObject:[self numSlider:@"帧率速度" key:@"miniFPS" def:50 mn:10 mx:200]];
    [specs addObject:[self numSlider:@"素材大小" key:@"miniScaleAdj" def:0 mn:-20 mx:20]];
    [specs addObject:[self numSlider:@"左右偏移" key:@"miniOffsetX" def:0 mn:-20 mx:20]];
    [specs addObject:[self numSlider:@"上下偏移" key:@"miniOffsetY" def:0 mn:-20 mx:20]];
    PSSpecifier *nameRow = [PSSpecifier preferenceSpecifierNamed:@"素材名称"
        target:self set:NULL get:@selector(readSmallAnimName:) detail:[DIFrameFoldersMini class] cell:PSLinkCell edit:nil];
    [nameRow setProperty:@"smallAnimFolder" forKey:@"nameKey"];
    [specs addObject:nameRow];
    /* 右侧音频 */
    [specs addObject:[self groupSpec:@"右侧音频" footer:nil]];
    [specs addObject:[self switchSpec:@"启用动画" key:@"miniAudioOn" def:@NO]];
    [specs addObject:[self numSlider:@"帧率速度" key:@"miniAudioFPS" def:50 mn:10 mx:200]];
    [specs addObject:[self numSlider:@"素材大小" key:@"miniAudioScaleAdj" def:0 mn:-20 mx:20]];
    [specs addObject:[self numSlider:@"左右偏移" key:@"miniAudioOffsetX" def:0 mn:-20 mx:20]];
    [specs addObject:[self numSlider:@"上下偏移" key:@"miniAudioOffsetY" def:0 mn:-20 mx:20]];
    PSSpecifier *nameRow2 = [PSSpecifier preferenceSpecifierNamed:@"素材名称"
        target:self set:NULL get:@selector(readAudioAnimName:) detail:[DIFrameFoldersAudio class] cell:PSLinkCell edit:nil];
    [nameRow2 setProperty:@"miniAudioFolder" forKey:@"nameKey"];
    [specs addObject:nameRow2];

    /* 2.8.12: 遮罩设置 —— 用自己的 png 抠岛上的专辑头像, 选中即自动生效
       2.8.23: 按用户要求删掉整段 footer 说明文字 */
    [specs addObject:[self groupSpec:@"遮罩设置" footer:nil]];
    [specs addObject:[self switchSpec:@"启用遮罩" key:@"maskOn" def:@NO]];
    PSSpecifier *maskRow = [PSSpecifier preferenceSpecifierNamed:@"遮罩素材"
        target:self set:NULL get:@selector(readAlbumMaskName:) detail:[DIMaskPicker class] cell:PSLinkCell edit:nil];
    [specs addObject:maskRow];
    /* 2.8.87: 展开定义 —— 按用户要求放在"遮罩素材"下面, 点进去是独立一页 */
    [specs addObject:[self linkSpec:@"歌词位置" detail:[DIExpandDefinePage class]]];
    /* 2.8.16: 遮罩尺寸可调 —— 用户反馈"加遮罩后专辑大了一点点, 边上被裁剪" */
    /* 2.8.41: 遮罩大小新刻度 —— 旧设定 115 为基准 100, 范围 50~150 */
    [specs addObject:[self numSlider:@"遮罩大小" key:@"diAlbumMaskScale2" def:100 mn:50 mx:150]];
    [specs addObject:[self switchSpec:@"启动旋转" key:@"maskRotateOn" def:@NO]];
    [specs addObject:[self switchSpec:@"反向旋转" key:@"maskRotateReverse" def:@NO]];
    [specs addObject:[self numSlider:@"旋转速度" key:@"maskRotateSpeed" def:45 mn:0 mx:360]];
    return specs;
}
@end

/* ===== 2.8.41: 控制中心页回归 —— 底包 DICC 实现零改动, 只恢复开关与入口 =====
   单素材(恒 wpLightAsset, 2.7.32 形态), 无深浅色分组 */
@implementation DIMiniBaseController (DIWallpaperName)
- (id)readWallpaperName:(PSSpecifier *)sp {
    NSString *cur = readPrefString([sp propertyForKey:@"nameKey"] ?: @"wpLightAsset");
    if (!cur.length || [cur isEqualToString:@"__none__"]) return @"未选择";
    return [cur.lastPathComponent.stringByDeletingPathExtension copy];
}
@end

/* 2.8.88: 展开定义页 —— 上面是帧率(与主页「帧率」组同一批键), 下面是展开岛文字 */
@implementation DIExpandDefinePage
- (id)readFrameName:(PSSpecifier *)sp {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("animFolder"), (__bridge CFStringRef)kDomain));
    if ([v isKindOfClass:NSString.class] && [(NSString *)v length]) return v;
    return @"默认(全部帧)";
}
- (NSArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    /* ---- 上: 帧率 ---- */
    [specs addObject:[self groupSpec:@"帧率" footer:nil]];
    [specs addObject:[self switchSpec:@"音频开关" key:@"spectrumOn" def:@NO]];
    [specs addObject:[self switchSpec:@"帧率开关" key:@"materialOn" def:@YES]];
    [specs addObject:[self numSlider:@"帧率速度" key:@"animFPS" def:50 mn:10 mx:200]];
    [specs addObject:[self numSlider:@"素材大小" key:@"animScaleAdj" def:0 mn:-20 mx:20]];
    [specs addObject:[self numSlider:@"左右偏移" key:@"animOffsetX3" def:0 mn:-50 mx:50]];
    [specs addObject:[self numSlider:@"上下偏移" key:@"animOffsetY3" def:0 mn:-50 mx:50]];
    PSSpecifier *animSet = [PSSpecifier preferenceSpecifierNamed:@"素材名称" target:self
        set:NULL get:@selector(readFrameName:) detail:[DIFrameFolders class] cell:PSLinkCell edit:nil];
    [specs addObject:animSet];
    /* ---- 下: 歌词位置 ---- */
    /* 2.8.92: 去掉说明文字; 左右/上下改成为"相对基准落点"的增量, 默认 0 就是
       用户自己调好的那个位置(120,45), 左右范围放宽到 ±200 */
    [specs addObject:[self groupSpec:@"歌词位置" footer:nil]];
    [specs addObject:[self switchSpec:@"开启位置" key:@"expandTextOn" def:@YES]];
    [specs addObject:[self numSlider:@"左右位置" key:@"expandTextX2" def:0 mn:-200 mx:200]];
    [specs addObject:[self numSlider:@"上下位置" key:@"expandTextY2" def:0 mn:-120 mx:120]];
    [specs addObject:[self numSlider:@"文字大小" key:@"expandTextScale" def:100 mn:50 mx:200]];
    /* 2.8.93: 隐藏投送 —— 右下角那颗 AirPlay/输出按钮 */
    [specs addObject:[self switchSpec:@"隐藏投送" key:@"hideRouteOn" def:@NO]];
    return specs;
}
@end

/* ===== 2.9.5: 专辑律动 =====
   数据链: MediaRemoteUI 内的系统 FFT(见 Tweak.mm diRhythmInstall)。
   效果: 小岛 / 岛展开 / 锁屏卡片的封面外圈飘几何粒子, 封面本身跟着鼓点缩放。
   点开专辑后的全屏大封面不挂(会拖死锁屏)。 */
@implementation DIRhythmPage

static void diSetNum(NSString *key, double v) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(v),
                             (__bridge CFStringRef)kDomain);
}

static double diGetNum(NSString *key, double def) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                       (__bridge CFStringRef)kDomain));
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : def;
}

- (void)diRGBA:(CGFloat *)out {
    out[0] = (CGFloat)(diGetNum(@"rhyR", 255) / 255.0);
    out[1] = (CGFloat)(diGetNum(@"rhyG", 255) / 255.0);
    out[2] = (CGFloat)(diGetNum(@"rhyB", 255) / 255.0);
}

- (NSString *)colorHexText {
    if (diGetNum(@"rhyTint", 1) > 0.5) return @"当前: 跟随封面取色";
    int r = (int)lrint(diGetNum(@"rhyR", 255));
    int g = (int)lrint(diGetNum(@"rhyG", 255));
    int b = (int)lrint(diGetNum(@"rhyB", 255));
    return [NSString stringWithFormat:@"当前: #%02X%02X%02X", r, g, b];
}

- (NSString *)colorRowTitle {
    int r = (int)lrint(diGetNum(@"rhyR", 255));
    int g = (int)lrint(diGetNum(@"rhyG", 255));
    int b = (int)lrint(diGetNum(@"rhyB", 255));
    return [NSString stringWithFormat:@"自定义颜色     #%02X%02X%02X", r, g, b];
}

- (void)applyPickedColor:(UIColor *)color {
    if (!color) return;
    CGFloat r = 1, g = 1, b = 1, a = 1;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0;
        if ([color getWhite:&w alpha:&a]) { r = g = b = w; }
    }
    diSetNum(@"rhyR", round(r * 255.0));
    diSetNum(@"rhyG", round(g * 255.0));
    diSetNum(@"rhyB", round(b * 255.0));
    diSetNum(@"rhyTint", 0);          /* 选了自定义色 = 不跟封面 */
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
}

- (void)openColorPicker:(PSSpecifier *)sp {
    if (@available(iOS 14.0, *)) {
        UIColorPickerViewController *p = [UIColorPickerViewController new];
        CGFloat c[3]; [self diRGBA:c];
        p.selectedColor = [UIColor colorWithRed:c[0] green:c[1] blue:c[2] alpha:1.0];
        p.supportsAlpha = NO;
        p.delegate = self;
        [self presentViewController:p animated:YES completion:nil];
    }
}

- (void)colorPickerViewController:(UIColorPickerViewController *)vc
                   didSelectColor:(UIColor *)color
                     continuously:(BOOL)continuously API_AVAILABLE(ios(15.0)) {
    /* 拖色轮时连续回调 —— 0.2 秒写一次, 页面能实时跟着变又不把 cfprefsd 顶死 */
    static CFAbsoluteTime last;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (continuously && now - last < 0.2) return;
    last = now;
    [self applyPickedColor:color];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)vc API_AVAILABLE(ios(15.0)) {
    [self applyPickedColor:vc.selectedColor];
    [self dismissViewControllerAnimated:YES completion:nil];
    [self reloadSpecifiers];
}

- (NSArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    [specs addObject:[self groupSpec:@"专辑律动"
        footer:@"取的是系统自己算好的频谱(MediaRemoteUI 内), 不抓录音、不额外解码。\n"
               @"作用位置: 小岛封面、岛展开封面、锁屏播放器卡片封面。点开专辑后的全屏大封面不生效。\n"
               @"每记鼓点(低频上冲)封面会放大→回弹→缩一点→归位, 同时外圈粒子被震散一下。"]];

    [specs addObject:[self switchSpec:@"启用律动" key:@"rhyOn" def:@NO]];
    [specs addObject:[self switchSpec:@"粒子" key:@"rhyDots" def:@YES]];
    [specs addObject:[self numSlider:@"粒子数量" key:@"rhyCount" def:10 mn:4 mx:20]];
    [specs addObject:[self numSlider:@"鼓点强度" key:@"rhyKick" def:100 mn:20 mx:300]];

    [specs addObject:[self groupSpec:@"颜色" footer:[self colorHexText]]];
    [specs addObject:[self switchSpec:@"跟随封面颜色" key:@"rhyTint" def:@YES]];
    [specs addObject:[self buttonSpec:[self colorRowTitle] action:@selector(openColorPicker:)]];

    return specs;
}

@end

@implementation DICCSettings
- (NSArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    [specs addObject:[self groupSpec:@"控制中心" footer:@"控制中心播放器背景素材(图片/视频), 素材目录: /var/mobile/灵动岛/壁纸素材"]];
    [specs addObject:[self switchSpec:@"启用背景" key:@"wpOn" def:@NO]];
    PSSpecifier *wpRow = [PSSpecifier preferenceSpecifierNamed:@"浅色素材"
        target:self set:NULL get:@selector(readWallpaperName:) detail:[DIWallpaperPicker class] cell:PSLinkCell edit:nil];
    [wpRow setProperty:@"wpLightAsset" forKey:@"nameKey"];
    [specs addObject:wpRow];
    PSSpecifier *darkRow = [PSSpecifier preferenceSpecifierNamed:@"深色素材"
        target:self set:NULL get:@selector(readWallpaperName:) detail:[DIWallpaperPickerDark class] cell:PSLinkCell edit:nil];
    [darkRow setProperty:@"wpDarkAsset" forKey:@"nameKey"];
    [specs addObject:darkRow];
    [specs addObject:[self switchSpec:@"循环播放" key:@"wpLoopOn" def:@NO]];
    [specs addObject:[self numSlider:@"背景模糊" key:@"wpBlur" def:0 mn:0 mx:100]];
    [specs addObject:[self switchSpec:@"声音" key:@"ccSoundOn" def:@NO]];
    [specs addObject:[self switchSpec:@"长按换素材" key:@"ccLongPressOn" def:@YES]];
    return specs;
}

@end


