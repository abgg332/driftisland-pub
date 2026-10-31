#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <spawn.h>

/* 2.2.25: 字体颜色相关页面统一背景 —— 之前色块页/预览卡/调色页各用各的灰白,
   视觉上"分裂"。现在统一: 页面 = 分组灰底, 卡片 = 白底圆角, 输入框 = 浅灰。 */
#define DI_PAGE_BG   [UIColor systemGroupedBackgroundColor]
#define DI_CARD_BG   [UIColor secondarySystemGroupedBackgroundColor]
#define DI_FIELD_BG  [UIColor tertiarySystemGroupedBackgroundColor]

static NSString *const kDomain = @"com.abgg332.driftisland";
static NSString *const kNotifyStr = @"com.abgg332.driftisland.reload";
static NSString *const kMaterialDir = @"/var/mobile/灵动岛";
static NSString *const kFrameDir = @"/var/mobile/灵动岛/帧率素材";

static NSString *const kRecDir = @"/var/mobile/灵动岛/录屏素材"; // 2.2.50: 录屏岛素材目录(录屏时替换小岛背景)

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
static NSArray<NSString *> *videoFilesIn(NSString *dir) {
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL] ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *f in files) {
        NSString *ext = f.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [ext isEqualToString:@"m4v"])
            [out addObject:f];
    }
    [out sortUsingSelector:@selector(localizedCompare:)];
    return out;
}
static NSArray<NSString *> *videoFiles(void) { return videoFilesIn(kMaterialDir); }

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
static void postReload(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kNotifyStr, NULL, NULL, YES);
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
@end
@interface DILyricsIslandSettings : DIMiniBaseController @end /* 2.2.24: 歌词岛合并页 = 上半左侧专辑 + 下半右侧音频 */
@interface DIFrameFoldersMini : DIFrameFolders @end  /* 左侧(mini)帧率素材选择(键 smallAnimFolder) */
@interface DIFrameFoldersAudio : DIFrameFolders @end /* 右侧音频素材(键 miniAudioFolder) */
@interface DIPrefsController (ZoneLinkFwd)
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls;
@end

static BOOL diGridPicked = NO; // 网格选中标记: 主页据此刷新按钮标题
@class DIPreviewGrid;
/* 2.2.22: 字体颜色面板走独立窗口(定义在文件末尾), 这里先声明 */
static void diOpenGradientPanelWindow(void);
/* 2.2.67: 流光风格面板(定义在文件后部) */
static NSArray *diStyleDefs(void);
static void diOpenStylePanelWindow(void);

static void diPrefsReloadCB(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    BOOL isColor = (name && CFStringCompare(name, CFSTR("com.abgg332.driftisland.colorchanged"), 0) == kCFCompareEqualTo);
    if (!diGridPicked && !isColor) return; // 颜色变更始终刷新(更新渐变预览条)
    diGridPicked = NO;
    id self_ = (__bridge id)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self_ respondsToSelector:@selector(reloadSpecifiers)]) [(id)self_ reloadSpecifiers]; // 刷新按钮标题/渐变条
    });
}

@implementation DIPrefsController

- (instancetype)init {
    if ((self = [super init])) {
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
    /* 2.2.54: 录屏素材(mode=2)走独立目录 kRecDir, 其余走通用素材目录 */
    NSArray *files = (mode == 2) ? videoFilesIn(kRecDir) : videoFiles();
    NSString *key = (mode == 0) ? @"smallIndex" : (mode == 1 ? @"expandIndex" : @"recIndex");
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

/* 素材选择行: 左标题、右当前素材名(箭头位置), 点击进入二级页面 */
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        [specs addObject:[self groupSpec:@"漂流岛 · 灵动岛视频背景" footer:nil]];
        [specs addObject:[self switchSpec:@"总开关" key:@"enabled" def:@NO]];
        [specs addObject:[self switchSpec:@"隐藏小岛" key:@"hideNoMusic" def:@NO]]; // 开=没放音乐时小岛不显示视频
        /* 文字样式: 颜色列表(可增删) + 流光 + 预览 + 通知背景 */
        [specs addObject:[self groupSpec:@"文字样式" footer:nil]];
        [specs addObject:[self switchSpec:@"文字颜色" key:@"notifyColorOn" def:@NO]];
        PSSpecifier *gradRow = [self buttonSpec:@"字体颜色" action:@selector(diOpenGradientPanel:)];
        [gradRow setProperty:@"gradient" forKey:@"diKind"];
        [specs addObject:gradRow];
        [specs addObject:[self switchSpec:@"流光动态" key:@"notifyFlowOn" def:@NO]];
        [specs addObject:[self buttonSpec:@"预览文字效果" action:@selector(diPreviewTapped:)]];
        [specs addObject:[self switchSpec:@"通知背景" key:@"notifyBgOff" def:@NO]];
        /* 小岛素材: 开关 + 素材选择按钮(点击直接弹出平铺预览, 不进二级页) */
        [specs addObject:[self groupSpec:@"小岛素材" footer:nil]];
        PSSpecifier *smallMat = [self buttonSpec:@"素材选择" action:@selector(openSmallGrid:)];
        [specs addObject:[self switchSpec:@"小岛显示素材" key:@"smallOn" def:@YES]];
        [specs addObject:smallMat];
        /* 2.5.23-3: 歌词岛(老版 2.2.x 完整迁移, 只歌词岛不含录屏岛) */
        [specs addObject:[self groupSpec:@"歌词岛" footer:@"播放音乐的小岛: 左侧=专辑区域, 右侧=音频区域, 各自播放独立序列帧动画。素材取自 /var/mobile/灵动岛/帧率素材 下的文件夹。仅小岛(非展开)生效。"]];
        [specs addObject:[self linkSpec:@"歌词岛" detail:[DILyricsIslandSettings class]]];
        /* 展开素材: 开关 + 素材选择按钮 */
        [specs addObject:[self groupSpec:@"展开素材" footer:nil]];
        PSSpecifier *expandMat = [self buttonSpec:@"素材选择" action:@selector(openExpandGrid:)];
        [specs addObject:[self switchSpec:@"展开显示素材" key:@"expandOn" def:@YES]];
        [specs addObject:expandMat];

        /* 2.2.52: 录屏素材移到"展开素材"下面(用户指定位置)。
           放回小岛/展开之后, 恢复原有 section 索引(小岛=2/展开=3/帧率=4),
           willDisplayCell 里的 indexPath.section 硬编码全部重新对上 —— 帧率布局随之恢复。
           2.2.54: 去掉组尾描述文字(用户指定不要), 新增"素材大小"滑杆。 */
        [specs addObject:[self groupSpec:@"录屏素材" footer:nil]];
        PSSpecifier *recMat = [self buttonSpec:@"素材选择" action:@selector(openRecGrid:)];
        [specs addObject:[self switchSpec:@"录屏显示素材" key:@"recOn" def:@NO]];
        [specs addObject:recMat];
        [specs addObject:[self stepSlider:@"素材大小" key:@"recScale" def:100 mn:50 mx:200]];

        /* 帧(音频)率组: 音频开关=右上角原生音频动态(关=显示 开=隐藏); 帧率开关=序列帧素材(立即生效) */
        [specs addObject:[self groupSpec:@"帧率" footer:nil]];
        [specs addObject:[self switchSpec:@"音频开关" key:@"spectrumOn" def:@NO]];
        [specs addObject:[self switchSpec:@"帧率开关" key:@"materialOn" def:@YES]];
        if ([[self readPreferenceValue:[self switchSpec:@"materialOn" key:@"materialOn" def:@YES]] boolValue]) {
            /* 2.2.38: 帧率组彻底回到原样(numSlider + willDisplayCell 里的 diBox 自绘),
               用户明确要求"帧率保持以前的", 这里一行都不许改成 stepSlider。 */
            [specs addObject:[self numSlider:@"帧率速度" key:@"animFPS" def:50 mn:10 mx:200]];
            [specs addObject:[self numSlider:@"素材大小" key:@"animScaleAdj" def:0 mn:-20 mx:20]];
            [specs addObject:[self numSlider:@"左右偏移" key:@"animOffsetX3" def:0 mn:-50 mx:50]];
            [specs addObject:[self numSlider:@"上下偏移" key:@"animOffsetY3" def:0 mn:-50 mx:50]];
            PSSpecifier *animSet = [PSSpecifier preferenceSpecifierNamed:@"素材名称" target:self
                set:NULL get:@selector(readSpectrumName:)
                detail:[DIFrameFolders class] cell:PSLinkCell edit:nil];
            [animSet setProperty:[self frameStatusName] forKey:@"value"];
            [specs addObject:animSet];
        }

        /* 2.2.21: 锁屏通知 —— 一个总开关统一管理宽度/边框/阴影/播放器; 背景已移除
           2.5.0: "锁屏通知自定义"改名"锁屏定义"; 组下新增"系统底栏横条"自定义(长短+颜色) */
        [specs addObject:[self groupSpec:@"锁屏通知" footer:@"开关打开后统一管理通知与播放器; 所有参数拖动即时生效"]];
        [specs addObject:[self switchSpec:@"锁屏定义" key:@"lockWOn" def:@NO]];
        if ([[self readPreferenceValue:[self switchSpec:@"lockWOn" key:@"lockWOn" def:@NO]] boolValue]) {
            [specs addObject:[self stepSlider:@"宽度" key:@"lockWPercent" def:100 mn:50 mx:100]];
        }
        /* 2.5.10: 横条 —— 长短 + 颜色(独立面板: 模式/颜色一体);
           分段控件在本 PSListController 里不渲染, 故不用 */
        [specs addObject:[self switchSpec:@"底栏横条自定义" key:@"homeBarOn" def:@NO]];
        if ([[self readPreferenceValue:[self switchSpec:@"homeBarOn" key:@"homeBarOn" def:@NO]] boolValue]) {
            [specs addObject:[self stepSlider:@"横条长短" key:@"homeBarLen" def:100 mn:10 mx:200]];
            /* 2.5.11: 颜色改用与文字一致的行内编辑(多色, 逗号分隔); 不再放独立面板 */
            /* 2.5.13: 颜色统一在"横条颜色选择"面板里选预设或自定义, 行内编辑行删除 */
            [specs addObject:[self buttonSpec:@"横条颜色选择" action:@selector(diOpenHomeBarPick:)]];
            /* 2.5.11: 流光动态 —— 与文字流光同一套, 不再需要速度滑块 */
            [specs addObject:[self switchSpec:@"流光动态" key:@"homeBarFlowOn" def:@NO]];
            /* 2.5.26: 流光方向 —— 左→右/右→左/中间散开/两边收紧 */
            [specs addObject:[self buttonSpec:@"流光方向" action:@selector(diPickHomeBarFlowDir:)]];
        }
        /* 隐藏底部横条 / 手势保护 */
        [specs addObject:[self switchSpec:@"隐藏底部横条" key:@"homeBarHideOn" def:@NO]];
        if ([[self readPreferenceValue:[self switchSpec:@"homeBarHideOn" key:@"homeBarHideOn" def:@NO]] boolValue]) {
            /* 2.5.11: 渐变隐藏改为子开关(之前的弹出选择在本环境点不动) */
            [specs addObject:[self switchSpec:@"渐变隐藏" key:@"homeBarHideFade" def:@NO]];
        }
        [specs addObject:[self switchSpec:@"启用手势保护" key:@"gestureProtectOn" def:@NO]];
        {
            /* 说明并入上一个 group 的 footer, 不再用空标题 groupSpec(会破坏点击命中) */
            PSSpecifier *last = specs.lastObject;
            NSString *old = [last propertyForKey:@"footerText"];
            [last setProperty:[NSString stringWithFormat:@"%@\n隐藏底部横条: 桌面和应用底部的横条可完全隐藏或渐变隐藏。\n启用手势保护: ① 上滑需二次确认才退出; ② 横屏静置 2 秒后横条自动彻底隐藏, 随意滑动一下即可重新显示。", old ?: @""]
                       forKey:@"footerText"];
        }

        _smallRow = _expandRow = -1;
        NSInteger n = 0;
        for (PSSpecifier *s in specs) {
            if (s.cellType == PSGroupCell) continue;
            if (s == smallMat) _smallRow = n;
            if (s == expandMat) _expandRow = n;
            n++;
        }

        [specs addObject:[self groupSpec:@"工具" footer:@"视频素材目录: /var/mobile/灵动岛\n频谱帧率素材目录: /var/mobile/灵动岛/帧率素材"]];
        [specs addObject:[self buttonSpec:@"跳转素材目录" action:@selector(openMaterialDir)]];
        [specs addObject:[self buttonSpec:@"跳转帧率目录" action:@selector(openFrameDir)]];

        /* 日志开关放最下面 */
        [specs addObject:[self groupSpec:nil footer:@"日志开关打开后，运行日志自动生成在 /var/mobile/灵动岛/driftisland.log"]];
        [specs addObject:[self switchSpec:@"日志开关" key:@"logging" def:@NO]];

        _specifiers = specs;
    }
    return _specifiers;
}

- (void)reloadSpecifiers {
    _specifiers = nil;
    [super reloadSpecifiers];
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
    NSInteger secSmall = -1, secExpand = -1, secFrame = -1, secRec = -1;
    {
        NSInteger sec = -1;
        for (PSSpecifier *gs in self.specifiers) {
            if (gs.cellType != PSGroupCell) continue;
            sec++;
            NSString *gnm = gs.name ?: @"";
            if ([gnm isEqualToString:@"小岛素材"]) secSmall = sec;
            else if ([gnm isEqualToString:@"展开素材"]) secExpand = sec;
            else if ([gnm isEqualToString:@"录屏素材"]) secRec = sec;
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
    if (indexPath.section == secRec && secRec >= 0 && indexPath.row == 1) name = [self nameForMode:2];
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

- (NSArray<NSString *> *)folders {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *out = [NSMutableArray array];
    BOOL hasDirectFrame = NO;
    for (NSString *n in [fm contentsOfDirectoryAtPath:kFrameDir error:NULL]) {
        NSString *p = [kFrameDir stringByAppendingPathComponent:n];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&isDir]) continue;
        if (isDir) [out addObject:n];
        else {
            NSString *ext = n.pathExtension.lowercaseString;
            if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) hasDirectFrame = YES;
        }
    }
    [out sortUsingSelector:@selector(localizedCompare:)];
    if (hasDirectFrame || out.count == 0) [out insertObject:@"默认(全部帧)" atIndex:0];
    return out;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *g = [PSSpecifier preferenceSpecifierNamed:@"选择素材" target:nil
            set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
        [g setProperty:@"点击选择帧率素材文件夹。素材目录: /var/mobile/灵动岛/帧率素材" forKey:@"footerText"];
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
@property (nonatomic, assign) NSInteger matMode; /* 0=小岛 1=展开 2=录屏(2.2.50) */
+ (void)diRefreshHostingList;   /* 2.2.58: 选完素材后让主页那一行立刻刷新 */
@end

@implementation DIPreviewGrid
/* 2.2.50: 素材目录与偏好键按模式取 —— 小岛/展开共用主目录, 录屏独立目录 */
- (NSString *)dirForMode {
    return (self.matMode == 2) ? kRecDir : kMaterialDir;
}
- (NSString *)keyForMode {
    if (self.matMode == 0) return @"smallIndex";
    if (self.matMode == 1) return @"expandIndex";
    return @"recIndex";
}
- (NSArray<NSString *> *)filesForMode {
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
    self.title = (self.matMode == 0) ? @"小岛素材" : (self.matMode == 2 ? @"录屏素材" : @"展开素材");
    self.collectionView.backgroundColor = DI_PAGE_BG;
    [self.collectionView registerClass:[DIPreviewCell class] forCellWithReuseIdentifier:@"cell"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"相册导入" style:UIBarButtonItemStylePlain target:self action:@selector(importFromAlbum)]; // 右上角关闭改为相册导入
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(close)]; // 关闭挪到左侧, 保留退出途径
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
        if (v && [v integerValue] == (NSInteger)ip.item) { // 删的是当前选中项 → 归零并刷新岛
            CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@0, (__bridge CFStringRef)kDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            postReload();
        }
        [self.collectionView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)currentIndex {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)[self keyForMode], (__bridge CFStringRef)kDomain));
    return v ? [v integerValue] : 0;
}
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)[self filesForMode].count;
}
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    DIPreviewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:ip];
    if (ip.item >= (NSInteger)[self filesForMode].count) return cell;
    NSString *name = [self filesForMode][ip.item];
    cell.lb.text = name;
    cell.lb.textColor = (ip.item == [self currentIndex]) ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];
    cell.iv.layer.borderWidth = (ip.item == [self currentIndex]) ? 2 : 0;
    cell.iv.layer.borderColor = [UIColor systemBlueColor].CGColor;
    UIImage *thumb = [diThumbCache() objectForKey:name];
    if (thumb) { cell.iv.image = thumb; }
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
                [diThumbCache() setObject:ui forKey:name];
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
        NSString *title = (self.matMode == 0) ? @"小岛素材" : (self.matMode == 2 ? @"录屏素材" : @"展开素材");
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
@implementation DIPrefsController (Grid)
- (void)presentGridMode:(NSInteger)mode {
    DIPreviewGrid *g = [[DIPreviewGrid alloc] init];
    g.matMode = mode;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:g];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)openSmallGrid:(PSSpecifier *)s { [self presentGridMode:0]; }
- (void)openExpandGrid:(PSSpecifier *)s { [self presentGridMode:1]; }
/* 2.2.50: 录屏素材(matMode=2, 目录 /var/mobile/灵动岛/录屏素材) */
- (void)openRecGrid:(PSSpecifier *)s {
    [[NSFileManager defaultManager] createDirectoryAtPath:kRecDir withIntermediateDirectories:YES attributes:nil error:NULL];
    [self presentGridMode:2];
}

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
@implementation DIPreviewGrid (Import)
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
        [self.collectionView reloadData]; // 网格页导入完立即刷新
    });
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
        NSArray *cs = diReadColors();
        NSString *hex = (idx >= 0 && idx < (NSInteger)cs.count) ? cs[idx] : @"FFFFFF";
        _curColor = diColorFromHexStr(hex, [UIColor whiteColor]);
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
    CGFloat r = 1, g = 1, b = 1, a = 1;
    [_curColor getRed:&r green:&g blue:&b alpha:&a];
    _preview.backgroundColor = _curColor;
    if (_rv) _rv.text = [NSString stringWithFormat:@"%d", (int)lround(r * 255)];
    if (_gv) _gv.text = [NSString stringWithFormat:@"%d", (int)lround(g * 255)];
    if (_bv) _bv.text = [NSString stringWithFormat:@"%d", (int)lround(b * 255)];
    if (_rs) { _rs.value = r * 255; _gs.value = g * 255; _bs.value = b * 255; }
    if (!_hexField.isFirstResponder) _hexField.text = diHexFromColor(_curColor);
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
    CGFloat topPad = 58, barH = 52;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, topPad, W, barH)];
    bar.backgroundColor = DI_PAGE_BG; /* 与页面底色全局统一, 不再分块 */
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
        [p refresh];
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
    NSInteger idx = b.tag - 100;
    diStep(@"面板: 点了色块 %ld", (long)(idx + 1));
    Class ec = NSClassFromString(@"DIColorEditor");
    if (!ec) { [self toast:@"调色页不可用"]; return; }
    UIViewController *vc = ((UIViewController *(*)(id, SEL, NSInteger))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(ec, @selector(alloc)), @selector(initWithIndex:), idx);
    if (!vc) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
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
    CGFloat topPad = 58, barH = 52;

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, topPad, W, barH)];
    bar.backgroundColor = DI_PAGE_BG;
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

static void diOpenStylePanelWindow(void) {
    if (gStyleWin && !gStyleWin.hidden) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    if (!scene) return;
    DIStylePanel *vc = [[DIStylePanel alloc] initWithNibName:nil bundle:nil];
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = scene.coordinateSpace.bounds;
    w.windowLevel = UIWindowLevelAlert + 1;
    w.rootViewController = vc;
    w.backgroundColor = DI_PAGE_BG;
    w.hidden = NO;
    gStyleWin = w;
}

/* 打开面板: 独立窗口, 与设置页视图树无关 */
static void diOpenGradientPanelWindow(void) {
    if (gPanelWin && !gPanelWin.hidden) return;

    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    if (!scene) { diStep(@"面板: 找不到 UIWindowScene, 无法打开"); return; }

    DIGradientPanel *vc = [[DIGradientPanel alloc] initWithNibName:nil bundle:nil];
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = scene.coordinateSpace.bounds;
    w.windowLevel = UIWindowLevelAlert + 1;
    w.rootViewController = vc;
    w.backgroundColor = DI_PAGE_BG;
    w.hidden = NO;
    gPanelWin = w;
    diStep(@"面板: 独立窗口已打开 %.0f×%.0f", w.frame.size.width, w.frame.size.height);
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


    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, W - 40, 34)];
    t.text = @"横条颜色";
    t.font = [UIFont boldSystemFontOfSize:26];
    [self.view addSubview:t];

    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"单色", @"多色渐变", @"流光"]];
    seg.frame = CGRectMake(20, 110, W - 40, 40);
    NSString *m = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("homeBarMode"), (__bridge CFStringRef)kDomain);
    seg.selectedSegmentIndex = [m isEqualToString:@"gradient"] ? 1 : ([m isEqualToString:@"flow"] ? 2 : 0);
    [seg addTarget:self action:@selector(diSegChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:seg];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, 162, W - 40, 40)];
    hint.text = @"多个颜色用英文逗号分隔(最多 8 色), 例: FF3B30,FF9500,FFCC00";
    hint.numberOfLines = 2;
    hint.font = [UIFont systemFontOfSize:13];
    hint.textColor = UIColor.secondaryLabelColor;
    [self.view addSubview:hint];

    NSString *cur = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("homeBarHexes"), (__bridge CFStringRef)kDomain);
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(20, 212, W - 40, 44)];
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.text = cur.length ? cur : @"FFFFFF";
    tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.tag = 1001;
    tf.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    [self.view addSubview:tf];

    UIView *pv = [[UIView alloc] initWithFrame:CGRectMake(20, 268, W - 40, 34)];
    pv.layer.cornerRadius = 17; pv.layer.masksToBounds = YES;
    pv.tag = 1002;
    pv.backgroundColor = UIColor.systemGray5Color;
    [self.view addSubview:pv];

    NSArray *presets = @[@"FFFFFF", @"000000", @"FF3B30", @"FF9500", @"FFCC00", @"34C759",
                         @"32ADE6", @"007AFF", @"AF52DE", @"FF2D55"];
    CGFloat bw = (W - 40 - 9 * 8) / 10.0, x = 20;
    for (NSString *hx in presets) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(x, 316, bw, bw);
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
    ok.frame = CGRectMake(20, 316 + bw + 24, W - 40, 48);
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

    CGFloat topPad = 58, barH = 52;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, topPad, W, barH)];
    bar.backgroundColor = DI_PAGE_BG;
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
        if (t.length == 6) [cols addObject:(id)diColorFromHexStr(t, [UIColor whiteColor]).CGColor];
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

- (void)tapCard:(UIButton *)b {
    NSUInteger i = b.tag - 200;
    NSArray *presets = diHomeBarPresets();
    if (i >= presets.count) return;
    NSString *joined = [presets[i][@"c"] componentsJoinedByString:@","];
    CFPreferencesSetAppValue(CFSTR("homeBarHexes"), (__bridge CFPropertyListRef)joined,
                             (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
    diColorChangedNotify();
    [self diRefreshPreview];
    diStep(@"横条配色: 已应用 %@", presets[i][@"name"]);
}

- (void)diClose {
    diStep(@"横条配色: 关闭");
    UIWindow *w = gBarWin;
    gBarWin = nil;
    [w setHidden:YES];
    w.hidden = YES;
    w.rootViewController = nil;
}
@end

static void diOpenHomeBarPickWindow(void) {
    if (gBarWin && !gBarWin.hidden) return;
    UIWindowScene *scene = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)sc; break; }
    if (!scene) { diStep(@"横条配色: 找不到 UIWindowScene"); return; }
    DIHomeBarPick *vc = [[DIHomeBarPick alloc] initWithNibName:nil bundle:nil];
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = scene.coordinateSpace.bounds;
    w.windowLevel = UIWindowLevelAlert + 1;
    w.rootViewController = vc;
    w.backgroundColor = DI_PAGE_BG;
    w.hidden = NO;
    gBarWin = w;
}

#pragma mark - 歌词岛(2.5.23-3 从老版 2.2.x 完整迁移, 只保留歌词岛, 录屏岛不用)


@implementation DIPrefsController (ZoneLink)
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:NULL get:NULL detail:cls cell:PSLinkCell edit:nil];
    return s;
}
@end

/* 2.6.1: 歌词岛(2.2.45 原版) —— 合并页 = 上半左侧专辑 + 下半右侧音频 */
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
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kNotifyStr, NULL, NULL, YES);
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
        NSDictionary *range0 = [sp propertyForKey:@"range"];
        if (!range0) {
            /* 素材名称行: 右侧显示当前文件夹名 */
            @try {
                NSString *nk = [sp propertyForKey:@"nameKey"];
                if (nk) {
                    NSString *nm = [self folderNameForKey:nk];
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

@implementation DILyricsIslandSettings
/* 2.2.24: 歌词岛合并页 —— 上半=左侧专辑设置, 下半=右侧音频设置, 一个页面管完 */
- (NSArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    /* 左侧专辑 */
    [specs addObject:[self groupSpec:@"左侧专辑" footer:nil]];
    [specs addObject:[self switchSpec:@"启用动画" key:@"miniAnimOn" def:@YES]];
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
    [specs addObject:[self switchSpec:@"启用动画" key:@"miniAudioOn" def:@YES]];
    [specs addObject:[self numSlider:@"帧率速度" key:@"miniAudioFPS" def:50 mn:10 mx:200]];
    [specs addObject:[self numSlider:@"素材大小" key:@"miniAudioScaleAdj" def:0 mn:-20 mx:20]];
    [specs addObject:[self numSlider:@"左右偏移" key:@"miniAudioOffsetX" def:0 mn:-20 mx:20]];
    [specs addObject:[self numSlider:@"上下偏移" key:@"miniAudioOffsetY" def:0 mn:-20 mx:20]];
    PSSpecifier *nameRow2 = [PSSpecifier preferenceSpecifierNamed:@"素材名称"
        target:self set:NULL get:@selector(readAudioAnimName:) detail:[DIFrameFoldersAudio class] cell:PSLinkCell edit:nil];
    [nameRow2 setProperty:@"miniAudioFolder" forKey:@"nameKey"];
    [specs addObject:nameRow2];
    return specs;
}
@end

/* 歌词岛素材选择页(键独立, 与主页展开岛素材分开) */
@implementation DIFrameFoldersMini
- (NSString *)prefKey { return @"smallAnimFolder"; }
@end
@implementation DIFrameFoldersAudio
- (NSString *)prefKey { return @"miniAudioFolder"; }
@end

