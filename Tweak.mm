// 漂流岛 Drift Island —— 灵动岛视频背景
// 素材目录: /var/mobile/灵动岛 (mp4/mov/m4v, 按文件名排序, 设置里按序号选用)
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>   /* 2.5.6: CAGradientLayer 横条渐变/流光 */
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CMTime.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <substrate.h>
#import <os/log.h>
#import "DIAlbumMask.h"   /* 2.6.10: 专辑光晕遮罩 */
#include <vector>

static NSString *const kDomain = @"com.abgg332.driftisland";
static NSString *const kNotifyStr = @"com.abgg332.driftisland.reload";
static NSString *const kMaterialDir = @"/var/mobile/灵动岛";
static NSString *const kFrameDir = @"/var/mobile/灵动岛/帧率素材";
static NSString *const kMaskDir = @"/var/mobile/灵动岛/遮罩素材"; // 2.6.4: 遮罩素材(图片, 不需要帧率)
static NSString *const kRecDir = @"/var/mobile/灵动岛/录屏素材"; // 2.2.50: 录屏岛素材目录 // 频谱序列帧目录(png/jpg, 按文件名数字排序)

static BOOL logEnabled; // 日志开关
static BOOL gLocked = NO; // 锁屏状态: 锁屏期间所有岛视频/帧率动画全停(锁屏界面组件也是岛视图, 不停会一直亮屏)
/* ===== 2.6.1: 歌词岛(2.2.45 原版完整移植, 键名/逻辑一模一样, 录屏岛不带) ===== */
static BOOL gFramesDirty;    // 素材文件夹变更标志: 立即重扫
/* 2.2.35: 歌词岛参数基准 —— 画面位置(大小-5/左-14/右+15)保留为基准偏移, 滑杆 0 = 用户调好的效果 */
static double miniScaleBase = -5, miniOffsetXBase = -14;
static double miniAudioScaleBase = -5, miniAudioOffsetXBase = 15;
static BOOL miniAnimOn = YES; // 左侧专辑启用动画
static double miniFPS = 50, miniScale = 0, miniOffsetX, miniOffsetY;
static BOOL miniAudioOn = YES; static double miniAudioFPS = 50, miniAudioScale = 0, miniAudioOffsetX, miniAudioOffsetY;
static NSString *smallAnimFolder; // 左侧(mini)素材文件夹
static NSString *miniAudioFolder; // 右侧音频素材独立键
static NSString *gMusicIslandId;  // 已确认音乐岛的 identifier(2.2.29 校验)
static NSString *gMusicIslandCls; // 2.6.3: 音乐岛宿主类名(强校验, 排除充电/人脸等其它岛)
/* 2.6.3: 遮罩 —— 贴合在左侧专辑上的序列帧层(跟随专辑位置/尺寸), 带旋转 */
static BOOL maskOn = NO;          // 启用遮罩素材
static BOOL maskRotateOn = NO;    // 启用素材旋转
static BOOL maskRotateReverse = NO; // 素材旋转反转
static double maskRotateSpeed = 4.0; // 旋转速度
static NSString *maskAnimFolder;  // 遮罩素材文件夹(帧率素材下的子目录)
static BOOL gRecordingActive = NO; // 2.6.1: 不带录屏岛, 恒 NO(保留 stepMini 原条件结构)
static void migrateLyricsParamsBase(void);
static NSString *diElementId(UIView *host);
static BOOL diMiniMusicActive(UIView *host); // 2.6.3: 前置(遮罩层使用)
static os_log_t logHandle;

// 运行日志: 写入 /var/mobile/Library/Logs/DriftIsland/driftisland.log (供"导出日志报告"抓取)
static void DLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void DLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:kMaterialDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:NULL];
        path = [kMaterialDir stringByAppendingPathComponent:@"driftisland.log"];
        [fm setAttributes:@{NSFilePosixPermissions: @0666} ofItemAtPath:path error:NULL]; // 跨进程守护进程也能写
    });
    if (!path) return;
    if (!logEnabled) return; // 日志开关关闭时不生成
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], line];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]; return; }
    [h seekToEndOfFile];
    [h writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
    // 单文件限 512KB, 防止无限增长
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (attr && [attr[NSFileSize] unsignedLongLongValue] > 512 * 1024) {
        [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
}

/* 现场日志: 不受 logEnabled 开关控制, 崩溃/进安全模式时也要留痕。
   固定写同一文件, 顶部标记 [现场], 排查时 grep "现场" 即可。 */
static void RLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void RLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:kMaterialDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:NULL];
        path = [kMaterialDir stringByAppendingPathComponent:@"driftisland.log"];
        [fm setAttributes:@{NSFilePosixPermissions: @0666} ofItemAtPath:path error:NULL];
    });
    if (!path) return;
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *out = [NSString stringWithFormat:@"[%@] [现场] %@\n", [df stringFromDate:[NSDate date]], line];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]; return; }
    [h seekToEndOfFile];
    [h writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}
#define DI_STEP(fmt, ...) RLog(fmt, ##__VA_ARGS__)

static BOOL pBool(NSString *key, BOOL def) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return v ? [v boolValue] : def;
}
static NSInteger pInt(NSString *key, NSInteger def) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return v ? [v integerValue] : def;
}
static NSString *pString(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return [v isKindOfClass:NSString.class] ? v : nil;
}

#pragma mark - 素材扫描

static NSArray<NSString *> *materialList(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *all = [fm contentsOfDirectoryAtPath:kMaterialDir error:NULL] ?: @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *n in all) {
        NSString *ext = n.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [ext isEqualToString:@"m4v"])
            [out addObject:n];
    }
    [out sortUsingSelector:@selector(localizedCompare:)];
    return out;
}

static double pDouble(NSString *key, double def) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return v ? [v doubleValue] : def;
}

/* 偏好缓存: 供 displayLink 每帧读取(不直接读 CFPreferences), 由 refreshPrefs 定期刷新 */
static BOOL enabled, smallOn = YES, expandOn = YES, spectrumOn, materialOn = YES;
/* 2.2.59: 小岛边框流光 —— 把选中的小岛素材贴在外轮廓上循环跑 */
static BOOL smallEdgeOn = NO;
static CGFloat smallEdgeW = 3.0;       /* 流光带宽度(pt) */
/* 2.5.0: 系统底栏横条(Home Indicator)自定义 */
static BOOL homeBarOn = NO;
static double homeBarLen = 100.0;      /* 百分比: 10~200 */
static UIColor *homeBarColor = nil;    /* nil = 不改颜色 */
static BOOL homeBarFlowOn = NO;             /* 2.5.11: 流光动态(与文字流光同一套) */
static NSInteger homeBarFlowDir = 0;        /* 2.5.26: 流光方向 0=左→右 1=右→左 2=中间向两边散开 3=两边向中间收紧 */
static BOOL homeBarHideOn = NO;             /* 2.5.7: 隐藏底部横条 */
static NSString *homeBarHideMode = @"full"; /* 2.5.7: full 完全隐藏 / fade 渐变隐藏 */
static BOOL gestureProtectOn = NO;          /* 2.5.7: 手势保护(上滑二次确认) */
static int smallEdgeStyle = 0;         /* 2.2.67: 流光风格 0~5, 见 DIEdgeStyle */
/* 2.2.6: 岛上通知样式 —— 文字颜色自定义 + 通知岛不使用视频背景 */
static BOOL notifyColorOn, notifyBgOff;
static UIColor *gNotifyColor;
/* 2.2.8: 流光渐变 —— 多色数组, 沿文字从左到右循环流动 */
static BOOL notifyFlowOn;
static NSArray<UIColor *> *gNotifyColors;
static NSArray<UIColor *> *gNotifyColorsLast; // 上次构建渐变的色表(变化时重建)
/* 2.2.10: 锁屏通知宽度自定义(百分比, 0=不修改) */
static BOOL lockWOn;
static double lockWPercent = 100;
/* 2.2.17: 锁屏通知外观(边框/背景/阴影) + 锁屏播放器同步缩放 */
static BOOL lkBdOn, lkBgOn, lkShOn, lkPlayerOn;
static double lkBdW = 3.0;
static UIColor *lkBdColor;
static NSArray<UIColor *> *lkBdColors;   /* 2.2.24: 边框多色(呼吸轮流) */
static double lkBgAlpha = 1.0;
static UIColor *lkBgColor;
static double lkShR = 5.5;
static double lkShOp = 1.3;    /* 2.2.52: 回退 2.2.49, MrShi 同款硬编码(仅保留变量兼容旧偏好) */
static UIColor *lkShColor;
static NSArray<UIColor *> *lkShColors;   /* 2.2.24: 阴影多色(呼吸轮流) */
static NSString *lkBgVideo;   // 锁屏通知背景视频文件名(空=不用视频)

/* HEX 颜色解析: 支持 RRGGBB / #RRGGBB / RRGGBBAA */
static UIColor *diColorFromHex(NSString *hex) {
    if (!hex.length) return nil;
    NSMutableString *s = [NSMutableString stringWithString:hex];
    [s replaceOccurrencesOfString:@"#" withString:@"" options:0 range:NSMakeRange(0, s.length)];
    if (s.length < 6) return nil;
    unsigned v = 0;
    NSScanner *sc = [NSScanner scannerWithString:s];
    if (![sc scanHexInt:&v]) return nil;
    CGFloat r = ((v >> 16) & 0xFF) / 255.0;
    CGFloat g = ((v >> 8) & 0xFF) / 255.0;
    CGFloat b = (v & 0xFF) / 255.0;
    CGFloat a = 1.0;
    if (s.length >= 8) {
        unsigned av = 0;
        [[NSScanner scannerWithString:[s substringFromIndex:6]] scanHexInt:&av];
        a = (av & 0xFF) / 255.0;
    }
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

/* 2.2.24: 多色解析 —— 输入 "FF0000,00FF00" 这种就返回两个色; 单色返回 1 个 */
static NSArray<UIColor *> *diColorList(NSString *raw) {
    if (!raw.length) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *part in [raw componentsSeparatedByString:@","]) {
        NSString *h = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        UIColor *c = diColorFromHex(h);
        if (c) [out addObject:c];
    }
    return out.count ? out : nil;
}

/* 多色轮流动画: 颜色沿列表循环(呼吸效果由 opacity/radius 负责, 这里只换色) */
__attribute__((unused)) static CAKeyframeAnimation *diColorCycle(NSArray<UIColor *> *cols, CGFloat baseDuration) {
    if (cols.count < 2) return nil;
    NSMutableArray *vals = [NSMutableArray array];
    for (UIColor *c in cols) [vals addObject:(id)c.CGColor];
    [vals addObject:(id)((UIColor *)cols.firstObject).CGColor];
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"borderColor"];
    a.values = vals;
    a.duration = baseDuration * cols.count;
    a.repeatCount = HUGE_VALF;
    a.calculationMode = kCAAnimationLinear;
    return a;
}

/* 阴影版: 同一个色表, 但 keyPath 是 shadowColor */
/* 2.2.53: 多色阴影"呼吸式"切换。
   旧版是 values 直连 + kCAAnimationLinear → 颜色匀速插值、到点立刻换下一个,
   观感就是"啪"地跳一下, 很生硬(用户连提两次)。
   现在给每个颜色加一个**保持段**(纯色停留) + 一段缓入缓出过渡:
     关键帧 = [c0, c0, c1, c1, c2, c2, ..., c0]
     keyTimes = 保持段占 45%, 过渡段占 55%
     timingFunctions = 保持段 linear, 过渡段 easeInEaseOut
   这样颜色会"亮着停一下 → 柔和地滑到下一个", 像呼吸一样, 不再硬切。 */
static CAKeyframeAnimation *diShadowCycle(NSArray<UIColor *> *cols, CGFloat baseDuration) {
    if (cols.count < 2) return nil;
    NSUInteger n = cols.count;
    NSMutableArray *vals = [NSMutableArray array];
    NSMutableArray *kers = [NSMutableArray array];
    NSMutableArray *tfs  = [NSMutableArray array];

    /* 时间轴: n 个颜色平分成 n 片。每片 = 保持(hold, 纯色停留) + 过渡(fade, 滑向下一色)。
       关键帧序列(共 2n+1 个点, keyTimes 等长, timingFunctions 共 2n 个):
         t=0            c0        ← 片0 保持起点
         t=slot*0.45    c0        ← 片0 保持终点
         t=slot*1.0     c1        ← 片0 过渡终点 = 片1 保持起点 (同一个点, 不重复添加)
         ...
         最终回到 c0              ← 无缝循环
       由于"过渡终点"与"下一片保持起点"是同一个关键帧, 所以每片实际只新增
       两个关键帧(保持起点 + 保持终点), 最后一个再补一个回绕点。 */
    CGFloat holdFrac = 0.45;
    CGFloat slot = 1.0 / (CGFloat)n;
    for (NSUInteger i = 0; i < n; i++) {
        UIColor *c = cols[i];
        CGFloat t0 = slot * (CGFloat)i;
        /* 保持起点 */
        [vals addObject:(id)c.CGColor];
        [kers addObject:@(t0)];
        /* 保持终点 */
        [vals addObject:(id)c.CGColor];
        [kers addObject:@(MIN(1.0, t0 + slot * holdFrac))];
    }
    /* 回绕点: 最后一色的过渡终点 = 首色 */
    [vals addObject:(id)((UIColor *)cols.firstObject).CGColor];
    [kers addObject:@1.0];

    /* timingFunctions: 每两个相邻关键帧之间一段 → 共 vals.count - 1 段。
       片段构成: [保持段(linear), 过渡段(ease)] 交替。
       注意最后一色到回绕点是过渡段。 */
    NSUInteger segCount = vals.count - 1;
    for (NSUInteger k = 0; k < segCount; k++) {
        BOOL isHold = (k % 2 == 0);   /* 偶数段 = 保持, 奇数段 = 过渡 */
        [tfs addObject:[CAMediaTimingFunction functionWithName:
            isHold ? kCAMediaTimingFunctionLinear : kCAMediaTimingFunctionEaseInEaseOut]];
    }

    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"shadowColor"];
    a.values = vals;
    a.keyTimes = kers;
    a.timingFunctions = tfs;
    a.duration = baseDuration * cols.count * 1.4;   /* 比原来稍慢, 过渡更从容 */
    a.repeatCount = HUGE_VALF;
    a.calculationMode = kCAAnimationLinear;
    return a;
}
/* UIColor → HEX 字符串(仅用于日志, 失败返回 "----") */
static NSString *diHexFromUIColor(UIColor *c) {
    if (!c) return @"----";
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return @"----";
    return [NSString stringWithFormat:@"%02X%02X%02X",
            (int)lround(r * 255), (int)lround(g * 255), (int)lround(b * 255)];
}
static BOOL hideNoMusic; // 无音乐时隐藏小岛视频(开关控制)
static CFAbsoluteTime gVolumeUntil; // 音量键交互窗口截止时间: 按音量键后6秒内非音乐岛小岛层不挂视频(与开关/iOS版本完全解耦)
static id gVolumeObserver; // NSNotificationCenter 观察者 token: 必须持有否则观察者被释放收不到通知
static NSInteger smallIdx, expandIdx;
static BOOL recOn;              /* 2.2.50: 录屏素材开关(录屏时替换小岛背景) */
static NSInteger recIdx;        /* 2.2.50: 录屏素材序号 */
static double recScale = 1.0;   /* 2.2.54: 录屏素材大小(绕自身中心缩放, 1.0 = 铺满矩形) */
/* 频谱帧率动画参数 */
static double animFPS = 50, animScale = 1, animOffsetX, animOffsetY;
static NSString *animFolder; // 选中的素材文件夹名(帧率素材目录下的子文件夹)

// 帧图缓存: 序列帧可能几百张, NSCache 自动回收
static UIImage *frameImage(NSString *path) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 120; cache.totalCostLimit = 64 * 1024 * 1024; }); // 限内存: 最多120帧且总成本64MB
    UIImage *img = [cache objectForKey:path];
    if (!img) { img = [UIImage imageWithContentsOfFile:path]; if (img) [cache setObject:img forKey:path cost:(NSUInteger)(img.size.width * img.size.height * 4)]; }
    return img;
}

// 帧图缓存: 序列帧可能几百张, NSCache 自动回收
// 序列帧列表(2秒TTL): 目录优先级 = 选中的素材文件夹 → 帧率素材根目录(递归兜底)
static NSArray<NSString *> *framePathsFor(NSString *folderSel); // 前置: DIAnimView stepMini 使用
static NSArray<NSString *> *framePaths(void);
/* 序列帧列表(2秒TTL, 按文件夹分别缓存): 2.2.45 原版 framePathsFor */
static NSArray<NSString *> *framePathsImpl(NSString *folderSel) {
    static NSMutableDictionary<NSString *, NSArray *> *cache;
    static NSMutableDictionary<NSString *, NSNumber *> *times;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; times = [NSMutableDictionary new]; });
    NSString *ck = folderSel.length ? folderSel : @"(root)";
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gFramesDirty || (cache[ck] && now - [times[ck] doubleValue] > 2.0)) { gFramesDirty = NO; [cache removeObjectForKey:ck]; }
    if (cache[ck]) return cache[ck];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSString *base = folderSel.length ? [kFrameDir stringByAppendingPathComponent:folderSel] : nil;
    if (!base) {
        NSMutableArray *dirs = [NSMutableArray array];
        BOOL hasDirect = NO;
        for (NSString *n in [fm contentsOfDirectoryAtPath:kFrameDir error:NULL]) {
            NSString *pp = [kFrameDir stringByAppendingPathComponent:n];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:pp isDirectory:&isDir]) continue;
            if (isDir) [dirs addObject:n];
            else { NSString *ext = n.pathExtension.lowercaseString;
                   if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) hasDirect = YES; }
        }
        if (hasDirect || !dirs.count) base = kFrameDir;
        else { [dirs sortUsingSelector:@selector(localizedCompare:)]; base = [kFrameDir stringByAppendingPathComponent:dirs.firstObject]; }
    }
    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:base];
    while (stack.count) {
        NSString *dir = stack.firstObject; [stack removeObjectAtIndex:0];
        for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            NSString *pp = [dir stringByAppendingPathComponent:n];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:pp isDirectory:&isDir] && isDir) { [stack addObject:pp]; continue; }
            NSString *ext = n.pathExtension.lowercaseString;
            if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) [out addObject:pp];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a.lastPathComponent compare:b.lastPathComponent options:NSNumericSearch];
    }];
    cache[ck] = out; times[ck] = @(now);
    return out;
}
static NSArray<NSString *> *framePaths(void) { return framePathsImpl(animFolder); }
static NSArray<NSString *> *framePathsFor(NSString *folderSel) { return framePathsImpl(folderSel); }

// 素材列表缓存(2秒TTL): displayLink 每帧调用, 不能每次扫描目录
static NSArray<NSString *> *cachedMaterials(void) {
    static NSArray *l; static CFAbsoluteTime t;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!l || now - t > 2.0) { l = materialList(); t = now; }
    return l;
}

/* 2.2.50: 录屏素材列表(2秒TTL, 与 cachedMaterials 同款缓存节奏) */
static NSArray<NSString *> *cachedRecMaterials(void) {
    static NSArray *l; static CFAbsoluteTime t;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!l || now - t > 2.0) {
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kRecDir error:NULL] ?: @[];
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *f in files) {
            NSString *ext = f.pathExtension.lowercaseString;
            if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [ext isEqualToString:@"m4v"])
                [out addObject:f];
        }
        [out sortUsingSelector:@selector(localizedCompare:)];
        l = out; t = now;
    }
    return l;
}

/* 2.2.53: 录屏岛识别与挂载定位 —— 直接沿用 2.2.40 已验证的方案(用户指定"那个版本位置是对的")。
   实测结论: 录屏时 SpringBoard 会出现唯一的"方形指示岛", 约 39×39(宽高差 < 3),
   岛内有两个 _SAUIProvidedViewContainerView(左=录屏圆点, 右=倒计时"321"),
   素材应贴到**目标 accessory 的真实 frame** 上, 而不是按"岛宽-岛高"自己算圆。
   这台系统 SAUIElementView 没有 elementIdentifier, 所以只能靠形状判定。 */
static NSHashTable *hostTable = nil; // 2.2.53: 提前定义 —— diRecIslandHost 需要遍历宿主集合

__attribute__((unused)) static BOOL diOnScreen(UIView *v) {
    if (!v || v.hidden || v.alpha < 0.02 || v.window == nil) return NO;
    CGRect f = [v.superview convertRect:v.frame toView:v.window];
    return !CGRectIsEmpty(f) && CGRectIntersectsRect(f, v.window.bounds);
}

static BOOL diIsScreenRecording(void) {
    static Class uiScreen; static dispatch_once_t once;
    dispatch_once(&once, ^{ uiScreen = NSClassFromString(@"UIScreen"); });
    if (!uiScreen) return NO;
    UIScreen *ms = [UIScreen mainScreen];
    if (![ms respondsToSelector:@selector(isCaptured)]) return NO;
    return ms.isCaptured;
}

/* 找方形指示岛(录屏岛)。优先取真正在屏上的那颗。 */
static UIView *diRecIslandHost(void) {
    if (!hostTable) return nil;
    __block UIView *found = nil, *visibleFound = nil;
    for (UIView *h in hostTable) {
        if (!h || h.isHidden || h.window == nil) continue;
        CGFloat w = h.bounds.size.width, hh = h.bounds.size.height;
        if (w >= 30 && w <= 45 && hh >= 30 && hh <= 45 && fabs(w - hh) < 3) {
            if (!found) found = h;
            CALayer *pl = h.layer.presentationLayer;
            if (pl && h.alpha > 0.05 && !CGRectIsEmpty(pl.bounds)) { visibleFound = h; break; }
        }
    }
    return visibleFound ?: found;
}

/* 在指示岛里找左右 accessory 容器(_SAUIProvidedViewContainerView), 按 x 排序。
   onRight=YES 取最右(倒计时位), NO 取最左(录屏圆点位)。
   返回素材应贴的矩形(相对 island 坐标系); 找不到 accessory 时按实测比例回退。 */
static CGRect diRecSlotRect(UIView *island, BOOL onRight, UIView **outAcc) {
    if (outAcc) *outAcc = nil;
    if (!island) return CGRectZero;
    NSMutableArray<UIView *> *accs = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:island];
    int guard = 0;
    while (stack.count && guard++ < 300) {
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0];
        if ([NSStringFromClass(v.class) isEqualToString:@"_SAUIProvidedViewContainerView"]) {
            [accs addObject:v];
            continue;
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    [accs sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    UIView *target = nil;
    if (accs.count > 1) target = onRight ? accs.lastObject : accs.firstObject;
    else if (accs.count == 1) target = onRight ? nil : accs.firstObject;  // 单个 accessory 视为左侧圆点
    if (outAcc) *outAcc = target;

    CGSize bs = island.bounds.size;
    /* 实测回退几何(2.2.45 dump): 左点 accessory = {8.67, 8.67, 22, 22} */
    CGFloat accH = bs.height * 0.56, accY = bs.height * 0.22;
    CGFloat accLX = bs.width * 0.22, accW = bs.width * 0.56;
    CGFloat rightX = bs.width * 0.5;
    if (target) {
        CGRect tf = [island convertRect:target.frame fromView:target.superview];
        if (onRight) {
            if (tf.origin.x >= 0 && tf.origin.x < bs.width) rightX = tf.origin.x;
            if (tf.size.height >= 1) { accH = tf.size.height; accY = tf.origin.y; }
        } else {
            if (tf.size.width >= 1) { accLX = tf.origin.x; accY = tf.origin.y; accW = tf.size.width; accH = tf.size.height; }
        }
    }
    return onRight
        ? CGRectMake(rightX, accY, MAX(bs.width - rightX, bs.width * 0.2), accH)
        : CGRectMake(accLX, accY, accW, accH);
}

/* 录屏圆圈素材路径(录屏指示器圆圈的背景视频, 独立于小岛素材) */
static NSString *recVideoPath(void) {
    if (!recOn) return nil;
    NSArray<NSString *> *rlist = cachedRecMaterials();
    if (!rlist.count) return nil;
    NSInteger ridx = recIdx;
    if (ridx < 0) ridx = 0;
    if (ridx >= (NSInteger)rlist.count) ridx = rlist.count - 1;
    return [kRecDir stringByAppendingPathComponent:rlist[ridx]];
}

static NSString *materialPathFor(BOOL expanded) {
    NSArray<NSString *> *list = cachedMaterials();
    if (!list.count) return nil;
    NSInteger idx = expanded ? expandIdx : smallIdx;
    if (expanded ? !expandOn : !smallOn) return nil; // 对应形态的开关关闭 → 不显示视频
    if (idx < 0) idx = 0;
    if (idx >= (NSInteger)list.count) idx = list.count - 1;
    return [kMaterialDir stringByAppendingPathComponent:list[idx]];
}

static void refreshPrefs(void) {
    /* 2.6.3: 每次重载都清空音乐岛学习结果, 由下一次在播音乐时重新确认, 避免沿用旧的错误 id */
    gMusicIslandId = nil; gMusicIslandCls = nil;
    enabled = pBool(@"enabled", NO);
    notifyColorOn = pBool(@"notifyColorOn", NO);
    notifyBgOff = pBool(@"notifyBgOff", NO);
    notifyFlowOn = pBool(@"notifyFlowOn", NO);
    {
        /* 2.2.8: 多色数组(diNotifColors, 逗号分隔 HEX)。
           流光关 = 取第1个颜色单色固定; 流光开 = 沿文字从左到右循环流动。 */
        NSString *raw = pString(@"diNotifColors");
        NSMutableArray<UIColor *> *cols = [NSMutableArray array];
        if (raw.length) {
            for (NSString *h in [raw componentsSeparatedByString:@","]) {
                UIColor *c = diColorFromHex(h);
                if (c) [cols addObject:c];
            }
        }
        if (!cols.count) {
            /* 旧版兼容: notifyColorHex / 默认柔白 */
            UIColor *legacy = diColorFromHex(pString(@"notifyColorHex"));
            [cols addObject:legacy ?: [UIColor colorWithRed:1.0 green:0.937 blue:0.918 alpha:1.0]];
        }
        gNotifyColors = cols;
        gNotifyColor = cols.firstObject; // 单色模式/兜底色
        static BOOL lastOn = -1, lastFlow = -1; static NSUInteger lastCnt = 999; static BOOL lastBg = -1;
        if (lastOn != notifyColorOn || lastFlow != notifyFlowOn || lastCnt != cols.count || lastBg != notifyBgOff) {
            lastOn = notifyColorOn; lastFlow = notifyFlowOn; lastCnt = cols.count; lastBg = notifyBgOff;
            DLog(@"通知文字颜色: 开关=%d 流光=%d 颜色数=%lu 背景过滤=%d 首色=%@",
                 notifyColorOn, notifyFlowOn, (unsigned long)cols.count, notifyBgOff, diHexFromUIColor(cols.firstObject));
        }
    }
    hideNoMusic = pBool(@"hideNoMusic", NO); // 无音乐时隐藏小岛视频
    lockWOn = pBool(@"lockWOn", NO);
    lockWPercent = pDouble(@"lockWPercent", 85);
    if (lockWPercent < 30) lockWPercent = 30; if (lockWPercent > 100) lockWPercent = 100;
    /* 2.2.17: 锁屏通知外观 */
    lkBdOn = NO;   /* 2.3.0: 锁屏边框功能已移除, 恒关 */
    lkBdW = pDouble(@"lkBdW", 3.0);
    if (lkBdW < 0) lkBdW = 0; if (lkBdW > 12) lkBdW = 12;
    lkBdColors = diColorList(pString(@"lkBdHex"));
    lkBdColor = lkBdColors.firstObject ?: [UIColor colorWithRed:0.0 green:0.68 blue:0.96 alpha:1.0];
    lkBgOn = pBool(@"lkBgOn", NO);
    lkBgAlpha = pDouble(@"lkBgAlpha", 100) / 100.0;
    if (lkBgAlpha < 0) lkBgAlpha = 0; if (lkBgAlpha > 1) lkBgAlpha = 1;
    lkBgColor = diColorFromHex(pString(@"lkBgHex")) ?: [UIColor blackColor];
    lkShOn = NO;   /* 2.3.0: 锁屏阴影功能已移除, 恒关 */
    lkShR = pDouble(@"lkShR", 5.5);
    if (lkShR < 0) lkShR = 0; if (lkShR > 30) lkShR = 30;
    /* 2.2.50: 直接 0~100 → 0~1.0, 不再有 0.2 下限 / 2.0 上限那套。
       100 = 完全不透明, 0 = 完全透明(不显示)。 */
    lkShOp = pDouble(@"lkShOp", 130.0) / 100.0;
    if (lkShOp < 0.2) lkShOp = 0.2; if (lkShOp > 2.0) lkShOp = 2.0;
    lkShColors = diColorList(pString(@"lkShHex"));
    lkShColor = lkShColors.firstObject ?: [UIColor colorWithRed:0.71 green:0.44 blue:0.89 alpha:1.0];
    lkPlayerOn = pBool(@"lkPlayerOn", YES);
    lkBgVideo = pString(@"lkBgVideo");
    logEnabled = pBool(@"logging", NO);
    smallOn = pBool(@"smallOn", YES);
    expandOn = pBool(@"expandOn", YES);
    spectrumOn = pBool(@"spectrumOn", NO);   // 帧率开关: 只控制隐藏原生频谱
    materialOn = pBool(@"materialOn", YES);  // 帧率素材开关: 只控制序列帧素材显示
    animFPS = pDouble(@"animFPS", 50);
    double adj = pDouble(@"animScaleAdj", 0); // 大小调整量: 0=原始大小, 每+1放大0.1倍
    if (adj < -20) adj = -20; if (adj > 20) adj = 20;
    animScale = 1 + adj * 0.1;
    if (animScale < 0.1) animScale = 0.1;
    animOffsetX = pDouble(@"animOffsetX3", 0);
    animOffsetY = pDouble(@"animOffsetY3", 0);
    animFolder = pString(@"animFolder");
    if (animFPS < 10) animFPS = 10; if (animFPS > 200) animFPS = 200;
    if (animOffsetX < -50) animOffsetX = -50; if (animOffsetX > 50) animOffsetX = 50;
    if (animOffsetY < -50) animOffsetY = -50; if (animOffsetY > 50) animOffsetY = 50;
    // 兼容旧版单素材键 videoIndex: 未分别设置过时沿用旧值
    NSInteger none = -1000;
    NSInteger si = pInt(@"smallIndex", none), ei = pInt(@"expandIndex", none);
    NSInteger legacy = pInt(@"videoIndex", 0);
    smallIdx = (si == none) ? legacy : si;
    expandIdx = (ei == none) ? legacy : ei;
    /* 2.2.50: 录屏素材 */
    recOn = pBool(@"recOn", NO);
    recIdx = pInt(@"recIndex", 0);
    /* 2.2.54: 录屏素材大小 0~200 映射 0.5~2.0, 默认 100 = 1.0 铺满 */
    recScale = pDouble(@"recScale", 100.0) / 100.0;
    if (recScale < 0.5) recScale = 0.5;
    if (recScale > 2.0) recScale = 2.0;

    /* 2.2.59: 小岛边框流光 —— 复用"小岛素材"那一个选择,
       所以素材路径直接用 materialPathFor(NO); 路径变了要重载视频。 */
    BOOL wasEdgeOn = smallEdgeOn;
    /* 2.5.0: 底栏横条 */
    homeBarOn = pBool(@"homeBarOn", NO);
    homeBarLen = pDouble(@"homeBarLen", 100.0);
    if (homeBarLen < 10) homeBarLen = 10;    /* 2.5.6: 下限 50 → 10 */
    if (homeBarLen > 200) homeBarLen = 200;
    homeBarFlowOn = pBool(@"homeBarFlowOn", NO);   /* 2.5.11 */
    homeBarFlowDir = pInt(@"homeBarFlowDir", 0);   /* 2.5.26 */
    /* 2.6.1: 歌词岛参数(2.2.45 原样) */
    smallAnimFolder = pString(@"smallAnimFolder");
    miniAudioFolder = pString(@"miniAudioFolder");
    miniAnimOn = pBool(@"miniAnimOn", YES);
    miniFPS = pDouble(@"miniFPS", 50);
    if (miniFPS < 10) miniFPS = 10; if (miniFPS > 200) miniFPS = 200;
    double mAdj = pDouble(@"miniScaleAdj", 0);
    if (mAdj < -20) mAdj = -20; if (mAdj > 20) mAdj = 20;
    miniScale = mAdj + miniScaleBase;
    miniOffsetX = pDouble(@"miniOffsetX", 0) + miniOffsetXBase; if (miniOffsetX < -40) miniOffsetX = -40; if (miniOffsetX > 40) miniOffsetX = 40;
    miniOffsetY = pDouble(@"miniOffsetY", 0); if (miniOffsetY < -20) miniOffsetY = -20; if (miniOffsetY > 20) miniOffsetY = 20;
    miniAudioOn = pBool(@"miniAudioOn", YES);
    miniAudioFPS = pDouble(@"miniAudioFPS", 50);
    if (miniAudioFPS < 10) miniAudioFPS = 10; if (miniAudioFPS > 200) miniAudioFPS = 200;
    double aAdj = pDouble(@"miniAudioScaleAdj", 0);
    if (aAdj < -20) aAdj = -20; if (aAdj > 20) aAdj = 20;
    miniAudioScale = aAdj + miniAudioScaleBase;
    miniAudioOffsetX = pDouble(@"miniAudioOffsetX", 0) + miniAudioOffsetXBase; if (miniAudioOffsetX < -40) miniAudioOffsetX = -40; if (miniAudioOffsetX > 40) miniAudioOffsetX = 40;
    miniAudioOffsetY = pDouble(@"miniAudioOffsetY", 0); if (miniAudioOffsetY < -20) miniAudioOffsetY = -20; if (miniAudioOffsetY > 20) miniAudioOffsetY = 20;
    /* 2.6.3: 遮罩(贴合左侧专辑) */
    maskOn = pBool(@"maskOn", NO);
    maskRotateOn = pBool(@"maskRotateOn", NO);
    maskRotateReverse = pBool(@"maskRotateReverse", NO);
    maskRotateSpeed = pDouble(@"maskRotateSpeed", 4.0);
    if (maskRotateSpeed < -12) maskRotateSpeed = -12; if (maskRotateSpeed > 12) maskRotateSpeed = 12;
    maskAnimFolder = pString(@"maskAnimFolder");
    /* 2.5.7: 隐藏横条 / 渐隐模式 / 手势保护 */
    homeBarHideOn = pBool(@"homeBarHideOn", NO);
    homeBarHideMode = pBool(@"homeBarHideFade", NO) ? @"fade" : @"full";   /* 2.5.11: 子开关 */
    gestureProtectOn = pBool(@"gestureProtectOn", NO);
    {
        NSString *hx = pString(@"homeBarHex");
        if (hx.length == 6) {
            unsigned v = 0;
            [[NSScanner scannerWithString:hx] scanHexInt:&v];
            homeBarColor = [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                                           green:((v >> 8) & 0xFF) / 255.0
                                            blue:(v & 0xFF) / 255.0 alpha:1.0];
        } else homeBarColor = nil;
    }
    smallEdgeOn = NO;   /* 2.3.0: 小岛边框流光功能已移除, 恒关 */
    smallEdgeW = pDouble(@"smallEdgeW", 3.0);        /* 宽窄(pt), 默认 3 */
    if (smallEdgeW < 1) smallEdgeW = 1;
    if (smallEdgeW > 10) smallEdgeW = 10;
    smallEdgeStyle = (int)pDouble(@"smallEdgeStyle", 0);   /* 2.2.67: 风格 */
    if (smallEdgeStyle < 0) smallEdgeStyle = 0;
    if (smallEdgeStyle > 5) smallEdgeStyle = 5;
    if (!smallEdgeOn && wasEdgeOn) {
        /* 刚关掉: 让所有已挂的流光层在下一次 walk 时被摘掉 */
        DLog(@"边框流光: 关闭");
    }
}

#pragma mark - 视频覆盖视图

@interface DIVideoView : UIView
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, strong) CADisplayLink *syncLink;
@property (nonatomic, assign) BOOL expandedLayer; // YES=展开层(播展开素材), NO=小岛层
@property (nonatomic, assign) BOOL circleLayer; // 2.2.52: 录屏圆圈层(贴小岛右侧录屏指示器圆圈, 不做整岛同步)
@property (nonatomic, assign) BOOL edgeLayer;   // 2.2.59: 边框流光层(自己管几何, 不参与主同步)
@end

static char kWinVideoSmall, kWinVideoExpand, kWinVideoRec, kWinVideoSpec;

/* ===== 音频会话: 2.3.2 定稿(2.3.1 删错了一次, 这里写清楚为什么必须保留) =====

   事实链(逐条都有日志/用户反馈佐证):
     1) AVPlayer 即便播放"无音轨"的视频, 也会在它所在进程激活一个音频会话 ——
        muted=YES 和"剥掉音轨"都不会阻止这件事。这是 AVPlayer 的默认行为。
     2) SpringBoard 里的这个会话如果停留在默认类别(SoloAmbient 一类),
        它对外就是"正占着音频" → 用户打开任何视频/音乐 App 播放,
        系统立刻弹「有其他软件使用音频, 自动暂停播放」并把 App 暂停。
        (2.3.1 把 setupAudioSession 改成空函数后, 用户反馈"什么都播放不了", 就是这一条)
     3) 所以这个 setCategory(Ambient + MixWithOthers) **不能删** —— 它不是"为发声用的",
        而是"声明我不独占音频"的唯一手段。Ambient + MixWithOthers 的组合语义就是
        "我随便放放, 别人要放就让别人放", 系统因此不会让其他 App 让路。

   2.3.1 的遗留问题(通知声音变大)的真正解法, 不在"要不要设 category", 而在:
     · 只设 category, **绝不调用 setActive:YES/NO**
       —— setActive 才是真正"上线/下线"会话的动作, 也是向全系统广播路由变化、
          触发通知增益通道切换的那一下。只改 category 不激活, 影响面极小。
     · setActive:NO 保持删除(2.3.1 起), 播放器停播时不做任何"释放广播"。
     · 用 dispatch_once 只设一次, 不重复写入, 避免频繁扰动 AVAudioSession 全局状态。

   以后谁再看到"插件不发声, 为什么不把音频会话全删掉" —— 答案就是上面第 1、2 条:
   你没声音, 但你的播放器会把整个 SpringBoard 的音频会话类别拖成"独占"。 */
static void setupAudioSession(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *err = nil;
        BOOL ok = [[AVAudioSession sharedInstance]
                   setCategory:AVAudioSessionCategoryAmbient
                   withOptions:AVAudioSessionCategoryOptionMixWithOthers
                         error:&err];
        DLog(@"音频会话(Ambient+混音, 仅设类别不激活): %@ %@",
             ok ? @"成功" : @"失败", err ? err.localizedDescription : @"");
    });
}

/* 查询"正在播放音乐"(MediaRemote 动态加载): 0.5秒轮询, 音乐停止时帧率素材即刻隐藏 */
static BOOL musicPlaying = NO;
static BOOL mrQueryOK = NO;
static void queryMusicPlaying(void) {
    static void (*mrGet)(dispatch_queue_t, void (^)(BOOL)) = NULL;
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (h) mrGet = (void (*)(dispatch_queue_t, void (^)(BOOL)))dlsym(h, "MRMediaRemoteGetNowPlayingIsPlaying");
        if (mrGet) q = dispatch_queue_create("di.mediaremote", DISPATCH_QUEUE_SERIAL);
    });
    if (!mrGet) { // 只记一次, 否则 0.5s 轮询会把日志刷爆
        static BOOL logged;
        if (!logged) { logged = YES; DLog(@"MediaRemote 不可用(dlopen/符号缺失), 音乐检测走音频层兜底"); }
        return;
    }
    dispatch_async(q, ^{ mrGet(q, ^(BOOL playing) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!mrQueryOK || playing != musicPlaying) DLog(@"音乐播放状态: %@", playing ? @"播放中" : @"未播放");
            musicPlaying = playing; mrQueryOK = YES;
        });
    }); });
}

 // 每窗口视频层(小岛/展开/频谱)
// 频谱区域标定(相对展开岛比例, 用户截图校准, 已验证与原生音频位置吻合); 素材层外扩2pt
static CGRect diSpecRegion(CGFloat w, CGFloat h) {
    return CGRectMake(w * 0.41 + 134.83 - 8, h * 0.72 - 119.195 - 8, w * 0.18 + 16, h * 0.25 + 16);
}
// enabled 等偏好缓存已在 materialPathFor 上方声明
static void updateSingleVideo(UIWindow *win); // 前置声明
static UIView *diFindPlatter(UIView *v);         // 前向声明: diRefreshContour 用
static void diStylePlatter(UIView *platter);     // 前向声明: diRefreshContour 用
static void diSyncEdgeGlowAll(void);             // 前向声明: 边框流光同步
static void diEdgeGeometry(UIView *edge, UIView *island); // 前向声明: 浮层几何

static CALayer *diFindAudioLayer(UIView *host); // 前向声明: syncFrameToHost 的"无音乐隐藏"判据使用
static UIView *islandRoot(UIView *v); // 前向声明: applyNotifyStyle 用它定位胶囊容器
static char kHostIsNotif;      // 前向声明: 宿主是否判定为通知岛(NSNumber), 视频层逐帧复核用
static char kCapIsNotif;       // 前向声明: 胶囊容器是否判定为通知岛(NSNumber)
static BOOL diIsVolumeIsland(UIView *host);     // 前向声明: 音量岛识别(独立于 hideNoMusic 开关)

/* 音量岛识别: 递归扫描岛内视图树, 含 Volume 相关视图(音量滑条控件)即判定为音量岛。
   音量岛一律不挂视频(无论"隐藏小岛"开关状态) → 彻底消除音量回落卡屏,
   同时不影响人脸解锁/充电等其他临时岛的视频显示(与 hideNoMusic 开关完全解耦) */
static BOOL diIsVolumeIsland(UIView *host) {
    if (!host) return NO;
    /* CPU 优化: 结果缓存 + 0.25秒限频重扫(宿主释放后弱读 nil 自动重扫) */
    static __weak UIView *wHost; static BOOL cachedResult; static CFAbsoluteTime tScan;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    __strong UIView *cached = wHost;
    if (cached == host && now - tScan < 0.25) return cachedResult;
    BOOL found = NO;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:host];
    int guard = 0;
    while (stack.count && guard++ < 500) { // 深度防御: 节点数上限防异常树
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0];
        if ([NSStringFromClass(v.class) containsString:@"olume"]) { found = YES; break; }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    if (found && !cachedResult) DLog(@"音量岛识别: 宿主%@ 含 Volume 视图 → 禁挂视频(与隐藏小岛开关无关)", NSStringFromClass(host.class));
    wHost = host; cachedResult = found; tScan = now;
    return found;
}
@implementation DIVideoView {
    NSInteger _missCount; // 连续不可见帧计数, 攒够才暂停 displayLink(防瞬时抖动误停)
    NSInteger _stallCount; // 播放器起不来计数: 攒够自动重载素材, 保证无限循环不被打断
    BOOL _bgFiltered; // 2.2.11: 本层被"通知不使用视频背景"过滤(隐藏原因非形态切换)
}

+ (Class)layerClass { return AVPlayerLayer.class; }

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _player = [[AVQueuePlayer alloc] init];
        _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        _player.muted = YES; // 永远静音
        setupAudioSession(); // 2.3.2: Ambient+MixWithOthers, 只设类别不激活(不抢其他 App 音频)
        if ([_player respondsToSelector:@selector(setPreventsDisplaySleepDuringVideoPlayback:)]) _player.preventsDisplaySleepDuringVideoPlayback = NO; // 不阻止自动息屏
        AVPlayerLayer *l = (AVPlayerLayer *)self.layer;
        l.player = _player;
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = YES;
        // 逐帧同步: 岛收缩/展开是系统动画, 每帧把视频对齐到岛的实时呈现尺寸, 永不露底
        _syncLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(syncFrameToHost)];
        _syncLink.preferredFramesPerSecond = 60; // CPU 优化: ProMotion 120Hz 降到 60(贴合够用, 转码负担减半)
        [_syncLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}

// 每帧: 帧贴合始终进行(即使本层非当前形态, 切换瞬间 frame 已就位), 显示/播放只属于本形态层
// 无岛活动时两层连续 20 帧不可见才暂停循环(省电); 岛可见期间循环保持活跃
- (void)syncFrameToHost {
    UIView *host = self.superview;
    if (!host || host.window == nil) { _syncLink.paused = YES; return; }
    /* 2.2.59: 边框流光层 —— 几何完全由 diApplyEdgeGlow 自己算(mask 环 + 缩放),
       绝不能走下面的主同步(那会把 frame 改成宿主 bounds, 并把 mask 顶掉),
       所以这里只做"播放/隐藏"两件事。 */
    if (self.edgeLayer) {
        /* 2.2.62: 独立浮层 —— host 是 window, 岛从关联对象取, 每帧跟踪其位置 */
        UIView *island = objc_getAssociatedObject(self, "diEdgeIsland");
        BOOL show = enabled && smallEdgeOn && island && island.window
                 && island.bounds.size.width > 8 && self.currentPath.length > 0;
        if (self.hidden == show) self.hidden = !show;
        if (show) {
            if (!CATransform3DIsIdentity(self.layer.transform))
                self.layer.transform = CATransform3DIdentity;
            if (self.player.timeControlStatus != AVPlayerTimeControlStatusPlaying) [self.player play];
            diEdgeGeometry(self, island);        /* 每帧贴合岛的位置/尺寸 */
            if (self.superview && self.superview.subviews.lastObject != self)
                [self.superview bringSubviewToFront:self];   /* 永远最顶层 */
        } else if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
            [self.player pause];
        }
        return;
    }
    /* 2.2.53: 录屏素材层 —— 挂到**录屏指示岛**(方形 ~39×39)里, 贴左侧圆点 accessory
       的真实矩形(沿用 2.2.40 已验证的定位, 用户指定"那个版本位置是对的")。
       判据: 开关开 + 系统在录屏 + 宿主链上确实存在方形指示岛。 */
    if (self.circleLayer) {
        UIView *island = diRecIslandHost();
        BOOL onRec = NO;
        if (island) {
            for (UIView *p = host; p; p = p.superview) if (p == island) { onRec = YES; break; }
            if (!onRec) {   /* 宿主是胶囊、指示岛在它内部时反向判定 */
                NSMutableArray<UIView *> *st = [NSMutableArray arrayWithObject:host];
                int g0 = 0;
                while (st.count && g0++ < 300) {
                    UIView *v = st.firstObject; [st removeObjectAtIndex:0];
                    if (v == island) { onRec = YES; break; }
                    for (UIView *s in v.subviews) [st addObject:s];
                }
            }
        }
        UIView *acc = nil;
        CGRect slot = (onRec ? diRecSlotRect(island, NO, &acc) : CGRectZero);
        BOOL show = enabled && recOn && diIsScreenRecording() && onRec && slot.size.width > 2;

        /* 原生圆点层: 显示素材时隐藏, 隐藏素材时恢复(与 2.2.40 同款做法) */
        static char kRecHiddenLayer;
        CALayer *prevHidden = objc_getAssociatedObject(self, &kRecHiddenLayer);
        if (show && acc && acc.layer && !acc.layer.isHidden) {
            acc.layer.hidden = YES;
            objc_setAssociatedObject(self, &kRecHiddenLayer, acc.layer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (!show && prevHidden) {
            prevHidden.hidden = NO;
            objc_setAssociatedObject(self, &kRecHiddenLayer, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        if (show) {
            /* 2.2.55: 素材大小改为"直接算 frame", 不再用 layer.transform。
               原因: 本视图的 layerClass 是 AVPlayerLayer, 每次设 view.frame 时
               系统会重写 layer.transform, 所以之前一律被还原(用户反馈"调不了, 会还原")。
               现在把 slot 绕自身中心按 recScale 缩放后再作为 frame:
                 · 默认 1.0 = 正好铺满 accessory 矩形
                 · 大于 1 变大(可溢出, 母层不裁)
                 · 小于 1 变小, 露出原生圆点位置的外圈 */
            CGFloat s = recScale;
            CGRect sc2 = slot;
            sc2.size.width  = slot.size.width  * s;
            sc2.size.height = slot.size.height * s;
            sc2.origin.x = slot.origin.x + (slot.size.width  - sc2.size.width)  * 0.5;
            sc2.origin.y = slot.origin.y + (slot.size.height - sc2.size.height) * 0.5;
            if (!CGRectEqualToRect(self.frame, sc2)) self.frame = sc2;
            CGFloat cr2 = sc2.size.height * 0.5;
            if (fabs(self.layer.cornerRadius - cr2) > 0.5) self.layer.cornerRadius = cr2;
            if (!CATransform3DIsIdentity(self.layer.transform))
                self.layer.transform = CATransform3DIdentity;
            NSString *want = recVideoPath();
            if (want && ![want isEqualToString:self.currentPath]) [self loadVideo:want];
        }
        if (self.hidden == show) self.hidden = !show;
        if (show && self.player.timeControlStatus != AVPlayerTimeControlStatusPlaying
                  && self.player.timeControlStatus != AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate
                  && self.currentPath) [self.player play];
        if (!show && self.player.timeControlStatus != AVPlayerTimeControlStatusPaused) [self.player pause];
        return;
    }
    if (self.expandedLayer == NO) { /* 小岛/展开层通用走主同步 */ }
    CALayer *pl = host.layer.presentationLayer;    // 帧贴合: 对齐宿主实时呈现值(动画插值), 外扩2pt覆盖取整边缘缝隙
    CGRect b = pl ? pl.bounds : host.bounds;
    b = CGRectInset(b, -2, -2);
    if (!CGRectEqualToRect(self.frame, b)) self.frame = b;
    CGFloat cr = pl ? pl.cornerRadius : host.layer.cornerRadius;
    if (self.layer.cornerRadius != cr) self.layer.cornerRadius = cr;
    /* 视频也响应"素材大小/左右偏移/上下偏移"滑杆(默认 1/0/0 时恒等不作用); 帧率速度映射为播放速率 */
    {
        CGFloat sc = animScale, ox = animOffsetX, oy = animOffsetY;
        CATransform3D t = CATransform3DIdentity;
        if (sc != 1 || ox != 0 || oy != 0) {
            t = CATransform3DMakeScale(sc, sc, 1);
            t = CATransform3DTranslate(t, ox, oy, 0);
        }
        if (!CATransform3DEqualToTransform(self.layer.transform, t)) self.layer.transform = t;
    }
    BOOL hostVisible = enabled && !gLocked && !host.isHidden && host.alpha > 0.05 && host.bounds.size.width > 2;
    /* 僵尸岛防御: 音量岛等临时岛关闭后宿主属性可能仍"可见"但已不在渲染树(presentationLayer 为空),
       我们挂的视频层会冻结在最后一帧卡在屏幕上(音量回落不消失的根因) → 强制隐藏 */
    if (!host.layer.presentationLayer && host.superview) {
        if (!self.hidden) { self.hidden = YES; DLog(@"僵尸岛宿主检测: 强制隐藏视频层(防音量岛回落卡屏)"); }
        if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause];
        return;
    }
    /* 2.2.11: 通知背景过滤(每帧复核 → 开关一改立即生效, 不用注销)。
       胶囊容器/宿主被标记为"通知岛" → 本窗口视频层全部隐藏; 标记由 applyNotifyStyle 写入。 */
    if (notifyBgOff) {
        BOOL notif = [objc_getAssociatedObject(host, &kCapIsNotif) boolValue]
                  || [objc_getAssociatedObject(host, &kHostIsNotif) boolValue];
        if (notif) {
            if (!self.hidden) self.hidden = YES;
            if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause];
            if (!_bgFiltered) { _bgFiltered = YES; DLog(@"通知背景过滤: 视频层隐藏 (宿主=%@)", NSStringFromClass(host.class)); }
            return;
        }
        _bgFiltered = NO;
    } else if (_bgFiltered) {
        _bgFiltered = NO; // 开关刚关: 放开隐藏, 由下面的形态判定接管
    }
    if (!hostVisible) {
        if (!self.hidden) self.hidden = YES;
        if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause];
        if (++_missCount > 10) _syncLink.paused = YES; // 岛彻底消失后很快停循环
        return;
    }
    _missCount = 0;
    /* 2.6.6: 小岛层必须有"音乐岛结构特征"才显示 —— 只看尺寸会在充电/人脸岛弹出动画的
       中间帧误判(闪一下帧率再消失)。这里要求宿主内存在 407x488 级别的跨进程内容层,
       且连续 2 帧成立才显示(去掉 1 帧的过渡误差), 一旦不成立立即隐藏(无延时)。 */
    if (!self.expandedLayer) {
        static CFAbsoluteTime tMine;
        BOOL musicShape = NO;
        {
            NSMutableArray<CALayer *> *stk = [NSMutableArray arrayWithObject:host.layer];
            int g = 0;
            while (stk.count && g++ < 300) {
                CALayer *l = stk.firstObject; [stk removeObjectAtIndex:0];
                if ([NSStringFromClass(l.class) containsString:@"CALayerHost"] &&
                    l.bounds.size.height >= 200 && l.bounds.size.width >= 150) { musicShape = YES; break; }
                for (CALayer *x in l.sublayers) [stk addObject:x];
            }
        }
        if (!musicShape) {
            tMine = 0;
            if (!self.hidden) { self.hidden = YES; if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause]; }
            return;
        }
        if (tMine == 0) tMine = CFAbsoluteTimeGetCurrent();
        else if (CFAbsoluteTimeGetCurrent() - tMine < 0.03) {   /* 需连续成立约 2 帧 */
            if (!self.hidden) { self.hidden = YES; if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause]; }
            return;
        }
    }
    // 形态判定用呈现层高度: 动画收尾才越过阈值
    CGFloat ph = pl ? pl.bounds.size.height : host.bounds.size.height;
    BOOL expanded = ph > 60; // 小岛高约36, 展开高 51~223
    BOOL mine = (expanded == self.expandedLayer);
    NSString *want = mine ? materialPathFor(expanded) : nil;
    if (want && !self.expandedLayer) {
        BOOL isAudio = (diFindAudioLayer(host) != nil);
        BOOL volumeWindow = CFAbsoluteTimeGetCurrent() < gVolumeUntil; // 音量键后5秒窗口(不依赖类名, iOS16/17 通用)
        if (!isAudio && (volumeWindow || diIsVolumeIsland(host))) {
            want = nil; // 音量岛: 一律不显示视频(防回落卡屏), 与"隐藏小岛"开关解耦
            DLog(@"音量拦截: 小岛层不挂视频 (%@)", volumeWindow ? @"音量键窗口" : @"Volume类名命中");
        }
    }
    /* 无音乐隐藏开关: 开启且确认没有媒体活动时, 小岛层不显示视频(退出所有app后岛不再挂着视频)。
       判据: 音乐岛音频层(CALayerHost)存在 或 MediaRemote 报告在播 → 有媒体; 两者皆无 → 隐藏。
       (不依赖 mrQueryOK: 部分系统版本 MediaRemote 回调不可用, 靠音频层兜底) */
    if (want && !self.expandedLayer && hideNoMusic) {
        BOOL mediaActive = (diFindAudioLayer(host) != nil) || (mrQueryOK && musicPlaying);
        if (!mediaActive) want = nil;
    }
    if (mine && want) {
        if (self.hidden) self.hidden = NO;
        if (self.player.timeControlStatus != AVPlayerTimeControlStatusPlaying) {
            [self.player play];
            float spd = (float)(animFPS / 50.0); if (spd < 0.1) spd = 0.1; if (spd > 4) spd = 4; // 帧率速度滑杆映射为视频播放速率(50=原速)
            if (spd > 0 && fabsf(self.player.rate - spd) > 0.01f) [self.player setRate:spd];
            if (++_stallCount > 120) { _stallCount = 0; [self loadVideo:want]; DLog(@"播放器连续2秒起不来, 重载素材: %@", want); } // 看门狗: 约2秒仍不播则重载
        } else {
            _stallCount = 0;
        }
        if (![want isEqualToString:self.currentPath]) [self loadVideo:want];
    } else {
        // 非本形态层: 隐藏+暂停, 但 frame 已在上面持续贴合 → 切换瞬间无缝显示
        if (!self.hidden) self.hidden = YES;
        if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause];
    }
}

- (void)dealloc {
    [_syncLink invalidate];
}

// 频谱动画视图: 序列帧播放(替代视频), 支持帧率/旋转/反转/旋转速度/缩放/XY偏移, 全部由偏好实时驱动
// 区域沿用频谱标定(展开岛右上角), 用呈现层 bounds 实时计算不跑位; 开关关=隐藏(露出系统频谱)

- (void)loadVideo:(NSString *)path {
    self.currentPath = path;
    self.looper = nil;
    [self.player replaceCurrentItemWithPlayerItem:nil];
    if (!path.length) { self.hidden = YES; DLog(@"素材为空: /var/mobile/灵动岛 下没有 mp4/mov/m4v"); return; }
    /* 音频冲突根治: 用 AVMutableComposition 只保留视频轨(剔除音轨)。
       之前 muted=YES 但音轨仍存在, AVPlayer 播放时在 SpringBoard 激活音频会话,
       rootless iOS16.4.1 上打开视频/音乐类 app 会提示"有其他软件使用音频, 自动暂停播放"。
       无音轨 → 播放器完全不碰音频管道, 不激活任何会话, 顺带省掉音频解码 CPU */
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVPlayerItem *item = nil;
    @try {
        AVAssetTrack *vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (vt) {
            AVMutableComposition *comp = [AVMutableComposition composition];
            AVMutableCompositionTrack *cv = (AVMutableCompositionTrack *)[comp addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
            if ([cv insertTimeRange:CMTimeRangeMake(kCMTimeZero, asset.duration) ofTrack:vt atTime:kCMTimeZero error:NULL]) {
                item = [AVPlayerItem playerItemWithAsset:comp];
                DLog(@"素材已剥离音轨(纯视频, 不碰音频会话): %@", path.lastPathComponent);
            }
        }
    } @catch (NSException *e) { item = nil; }
    if (!item) item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]]; // 兜底: 剥离失败用原视频
    DLog(@"加载视频: %@", path);
    self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:item];
    // 跟随宿主的圆角
    UIView *host = (UIView *)self.superview;
    self.layer.cornerRadius = host ? host.layer.cornerRadius : 0;
    self.player.muted = YES; // 永远静音
    if ([self.player respondsToSelector:@selector(setPreventsDisplaySleepDuringVideoPlayback:)]) self.player.preventsDisplaySleepDuringVideoPlayback = NO; // 不阻止自动息屏
    if (enabled) {
        [self.player play];
        float spd0 = (float)(animFPS / 50.0); if (spd0 < 0.1) spd0 = 0.1; if (spd0 > 4) spd0 = 4; // 帧率速度滑杆映射为视频播放速率(50=原速)
        [self.player setRate:spd0];
        dispatch_async(dispatch_get_main_queue(), ^{ [self.player play]; }); // 下一轮再补一次, 防切换素材后偶发暂停
    }
}

@end

#pragma mark - 频谱帧率动画视图(序列帧)

@interface DIAnimView : UIView
@property (nonatomic, strong) UIImageView *iv;
@property (nonatomic, strong) CADisplayLink *link;
      // 当前旋转角
@property (nonatomic, assign) CFTimeInterval lastTS;
@property (nonatomic, assign) NSInteger idx;     // 当前帧号
@property (nonatomic, assign) double advAcc;     // 帧推进累加器
@property (nonatomic, assign) NSInteger miss;
@property (nonatomic, assign) BOOL miniMode;     // 2.2.14: YES=小岛专辑位置素材(帧率); NO=展开岛频谱位置素材
@property (nonatomic, assign) NSInteger side;    // 2.2.18: miniMode 下 0=专辑位(左) 1=音频位(右)
@property (nonatomic, assign) double lastSc;   // 2.2.22: 每层独立"上次应用参数"
@property (nonatomic, assign) double lastOx;
@property (nonatomic, assign) double lastOy;
@end

/* 定位原生音频层: 音乐岛的跨进程内容通过 CALayerHost 渲染(高约488, 只在音乐岛出现, 其他岛没有)。
   找到 = 当前是音乐岛展开(帧率素材允许显示 / 音频开关可隐藏它); 找不到 = 非音乐岛 */
static CALayer *diFindAudioLayer(UIView *host) {
    if (!host) return nil;
    /* CPU 优化: 结果缓存(弱引用) + 0.25秒限频重扫; 层被释放时弱读 nil 自动重扫 */
    static __weak CALayer *wCache; static CFAbsoluteTime tScan;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    __strong CALayer *cached = wCache;
    if (cached && now - tScan < 0.25) return cached;
    CALayer *found = nil;
    NSMutableArray<CALayer *> *stack = [NSMutableArray arrayWithObject:host.layer];
    while (stack.count) {
        CALayer *l = stack.firstObject; [stack removeObjectAtIndex:0];
        for (CALayer *s in l.sublayers) {
            [stack addObject:s];
            if ([NSStringFromClass(s.class) containsString:@"CALayerHost"] && s.frame.size.height > 300) { found = s; break; }
        }
        if (found) break;
    }
    if (found) { wCache = found; tScan = now; }
    return found;
}

@implementation DIAnimView
static void syncNativeSpectrum(UIView *bestRoot); // 前向声明: step 每帧同步音频掩码(展开过程即时隐藏波形)
- (instancetype)initWithFrame:(CGRect)frame {
    /* stepMini 依赖: 双 portal 判定 + 音乐岛 identifier 校验(2.2.29 原版) */

    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = NO; // 旋转/缩放后允许超出频谱区域
        _iv = [[UIImageView alloc] initWithFrame:self.bounds];
        _iv.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_iv];
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step)];
        _link.preferredFramesPerSecond = 60; // CPU 优化: ProMotion 120Hz 降到 60(帧推进由累加器保证速度不变)
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}


/* 2.6.4: 详细探针 —— 打印宿主内每个 portal 的来源类名/尺寸/位置,
   用于确认"哪些 portal 属于音乐岛(专辑图+波形), 哪些属于充电/人脸" */
static void diProbePortals(UIView *host, const char *tag) {
    if (!host) return;
    NSMutableString *buf = [NSMutableString string];
    [buf appendFormat:@"[portal探针 %s] 宿主=%@ %@\n", tag,
        NSStringFromClass(host.class), NSStringFromCGRect(host.bounds)];
    NSMutableArray<CALayer *> *stack = [NSMutableArray arrayWithObject:host.layer];
    int guard = 0;
    while (stack.count && guard++ < 400) {
        CALayer *l = stack.firstObject; [stack removeObjectAtIndex:0];
        NSString *cn = NSStringFromClass(l.class);
        if ([cn containsString:@"CAPortalLayer"] || [cn containsString:@"CALayerHost"]) {
            NSString *srcName = @"(无source)";
            SEL s0 = NSSelectorFromString(@"sourceLayer");
            if ([l respondsToSelector:s0]) {
                CALayer *src = ((id(*)(id, SEL))objc_msgSend)(l, s0);
                if (src) srcName = [NSString stringWithFormat:@"%@ %@", NSStringFromClass(src.class), NSStringFromCGRect(src.bounds)];
            }
            CGRect r = [host.layer convertRect:l.bounds fromLayer:l];
            [buf appendFormat:@"  %@ %@ @%@ 来源=%@\n", cn, NSStringFromCGRect(l.bounds), NSStringFromCGPoint(r.origin), srcName];
        }
        for (CALayer *x in l.sublayers) [stack addObject:x];
    }
    DLog(@"%@", buf);
}


/* 2.2.29: 音乐岛判定 —— 双 portal + 在播 + identifier 校验 */
/* 2.6.3: 音乐岛强校验 —— 记录音乐岛自身的 elementIdentifier 与宿主类名,
   stepMini / 原生隐藏 都只认这个 id, 充电/人脸/通话/录屏 等其他岛一律不认 */
static BOOL diMiniMusicActive(UIView *host) {
    if (!host) return NO;
    /* 2.6.4: 结构特征判据 —— 音乐岛(MediaRemoteUI)内部必有一个"接近满高的跨进程内容层"
       (CALayerHost, 高≈宿主高×0.85 以上, 宽≈宿主宽×0.4 以上)。这是专辑图/音频波形的来源。
       充电、人脸、来电、录屏等岛只有小尺寸图标 portal, 不会有这种满高内容层。 */
    CGFloat hh = host.bounds.size.height, ww = host.bounds.size.width;
    if (hh < 20 || hh > 60 || ww < 40) return NO;
    BOOL hasFullHost = NO;
    NSMutableArray<CALayer *> *stack = [NSMutableArray arrayWithObject:host.layer];
    int guard = 0;
    while (stack.count && guard++ < 300) {
        CALayer *l = stack.firstObject; [stack removeObjectAtIndex:0];
        NSString *cn = NSStringFromClass(l.class);
        /* 音乐岛核心特征(196 实测): 一个尺寸远大于宿主的内容层
           CALayerHost 407x488 挂在 133x39 的小岛上 —— 这是专辑图/波形来源。
           充电/人脸只有 26x22 级别的小图标 portal, 尺寸远小于此。 */
        if ([cn containsString:@"CALayerHost"] && l.bounds.size.height >= 200 && l.bounds.size.width >= 150) {
            hasFullHost = YES; break;
        }
        for (CALayer *x in l.sublayers) [stack addObject:x];
    }
    if (!hasFullHost) return NO;
    /* 在播校验 */
    BOOL playing = mrQueryOK ? musicPlaying : AVAudioSession.sharedInstance.isOtherAudioPlaying;
    if (!playing) return NO;
    /* identifier 若系统提供则一并校验(这台机 195 日志里为 nil, 不提供时跳过) */
    NSString *eid = diElementId(host);
    if (eid.length) {
        if (!gMusicIslandId) {
            gMusicIslandId = [eid copy];
            gMusicIslandCls = NSStringFromClass(host.class);
            DLog(@"确认音乐岛 identifier=%@ 宿主=%@", eid, gMusicIslandCls);
            diProbePortals(host, "音乐岛");
        }
        if (![eid isEqualToString:gMusicIslandId]) return NO;
    }
    return YES;
}

/* 2.2.14: 小岛专辑/音频位置帧率素材(2.2.45 stepMini 原版) */
- (void)stepMini {
    @try {
    UIView *host = self.superview;
    if (!host || host.window == nil) { self.hidden = YES; if (++_miss > 15) _link.paused = YES; return; }
    syncNativeSpectrum(host);
    BOOL mini = host.bounds.size.height > 20 && host.bounds.size.height <= 60 && host.bounds.size.width > 40;
    BOOL mediaActive = diMiniMusicActive(host);
    BOOL musicGate = AVAudioSession.sharedInstance.isOtherAudioPlaying || (diFindAudioLayer(host) != nil);
    NSArray<NSString *> *frames = framePathsFor((self.side == 1) ? miniAudioFolder : smallAnimFolder);
    BOOL sideOn = (self.side == 1) ? miniAudioOn : miniAnimOn;
    if (!mini || !enabled || gLocked || !sideOn || !frames.count || !mediaActive || !musicGate || gRecordingActive) {
        if (!self.hidden) self.hidden = YES;
        if (_iv.image) _iv.image = nil;
        if (++_miss > 15) _link.paused = YES;
        return;
    }
    _miss = 0;
    CALayer *pl = host.layer.presentationLayer;
    CGSize bs = pl ? pl.bounds.size : host.bounds.size;
    BOOL onRight = (self.side == 1);
    CGRect f = onRight ? CGRectMake(bs.width * 0.48, 0, bs.width * 0.52, bs.height)
                       : CGRectMake(0, 0, bs.width * 0.52, bs.height);
    if (!CGRectEqualToRect(self.frame, f)) { self.frame = f; }
    if (self.hidden) self.hidden = NO;
    CFTimeInterval now = self.link.timestamp;
    if (!_lastTS) _lastTS = now;
    double dt = now - _lastTS;
    _lastTS = now;
    if (dt > 0.5) dt = 0.5;
    double useFPS = onRight ? miniAudioFPS : miniFPS;
    double useScale = onRight ? miniAudioScale : miniScale;
    double useOx = onRight ? miniAudioOffsetX : miniOffsetX;
    double useOy = onRight ? miniAudioOffsetY : miniOffsetY;
    _advAcc += dt * useFPS;
    while (_advAcc >= 1.0) { _advAcc -= 1.0; _idx = (_idx + 1) % (NSInteger)frames.count; }
    UIImage *img = frameImage(frames[_idx]);
    if (img && _iv.image != img) _iv.image = img;
    static BOOL loggedMiniL, loggedMiniR;
    if (onRight && !loggedMiniR) { loggedMiniR = YES; DLog(@"小岛右侧音频素材显示: 共 %lu 帧 (目录 %@)", (unsigned long)frames.count, miniAudioFolder ?: @"默认第一个文件夹"); }
    if (!onRight && !loggedMiniL) { loggedMiniL = YES; DLog(@"小岛左侧专辑素材显示: 共 %lu 帧 (目录 %@)", (unsigned long)frames.count, smallAnimFolder ?: @"默认第一个文件夹"); }
    CGFloat unit = bs.height > 6 ? bs.height : 38.0;
    CGFloat k = 1.0 + (CGFloat)useScale * 0.06;
    if (k < 0.1) k = 0.1;
    CGFloat dx = (CGFloat)useOx * unit * 0.04;
    CGFloat dy = (CGFloat)useOy * unit * 0.04;
    CGSize base = self.bounds.size;
    CGSize wantSize = CGSizeMake(base.width * k, base.height * k);
    CGPoint wantCenter = CGPointMake(base.width * 0.5 + dx, base.height * 0.5 + dy);
    if (fabs(_iv.bounds.size.width - wantSize.width) > 0.5 || fabs(_iv.bounds.size.height - wantSize.height) > 0.5) {
        _iv.bounds = CGRectMake(0, 0, wantSize.width, wantSize.height);
    }
    if (fabs(_iv.center.x - wantCenter.x) > 0.3 || fabs(_iv.center.y - wantCenter.y) > 0.3) {
        _iv.center = wantCenter;
    }
    } @catch (NSException *e) { DLog(@"stepMini 异常(已忽略): %@", e); }
}

- (void)step {
    if (self.miniMode) { [self stepMini]; return; } // 2.2.14: 小岛专辑位置素材走独立分支
    UIView *host = self.superview;
    if (!host || host.window == nil) { self.hidden = YES; if (++_miss > 15) _link.paused = YES; return; }
    syncNativeSpectrum(host); // 无条件每帧同步音频掩码(即使帧率素材关闭/没放歌): 岛重新展开或层重建时波形立即被藏
    /* 帧率图只在播放音乐的展开岛显示(实测展开音乐岛约407x202); 其他一切形态全部禁用:
       锁屏大卡(高700+)/录屏岛/通话岛/小岛(高36)/视频展开岛(无音频层) 一律不显示 */
    BOOL expand = host.bounds.size.height > 100 && host.bounds.size.height < 300
               && host.bounds.size.width > 250 && host.bounds.size.width < 500;
    NSArray<NSString *> *frames = framePaths();
    CALayer *audioL = expand ? diFindAudioLayer(host) : nil; // 原生音频动态层: 在=音乐岛
    CALayer *apl = audioL ? (audioL.presentationLayer ?: audioL) : nil; // 必须真实可见: 隐藏/透明/过小都视为非音乐岛
    BOOL audioVisible = apl && !apl.isHidden && apl.opacity > 0.05 && apl.bounds.size.width > 10 && apl.bounds.size.height > 10;
    if (!expand || !enabled || gLocked || !materialOn || !frames.count || !audioVisible || (mrQueryOK && !musicPlaying)) {
        // 帧率开关关/收缩/非音乐岛(无音频层): 隐藏本层; 音频层显示与否由音频开关单独控制
        if (!self.hidden) self.hidden = YES;
        if (++_miss > 15) _link.paused = YES;
        return;
    }
    _miss = 0;
    // 显示层级与音频层一致: 只有音乐岛(存在 CALayerHost)才显示; 位置用校准烘焙区域盖住原生音频
    CALayer *pl = host.layer.presentationLayer;
    CGSize bs = pl ? pl.bounds.size : host.bounds.size;
    CGRect f = diSpecRegion(bs.width, bs.height);
    if (!CGRectEqualToRect(self.frame, f)) self.frame = f;
    // 内部图片视图: bounds/center 统一由下方"仅参数变化时"分支管理;
    // (旧代码每帧 _iv.frame=self.bounds 会把 position 归位, 调过大小时偏移每帧被清零 → "素材又归位" bug)
    if (self.hidden) self.hidden = NO;    // 帧推进: 按动画帧率
    CFTimeInterval now = self.link.timestamp;
    if (!_lastTS) _lastTS = now;
    double dt = now - _lastTS;
    _lastTS = now;
    if (dt > 0.5) dt = 0.5; // 切后台回来防跳帧
    _advAcc += dt * animFPS; // 累加器: 低帧率也能逐帧推进(旧版 adv>=1 门槛导致帧率<60 冻结)
    while (_advAcc >= 1.0) { _advAcc -= 1.0; _idx = (_idx + 1) % (NSInteger)frames.count; }
    UIImage *img = frameImage(frames[_idx]);
    if (img && _iv.image != img) _iv.image = img;
    static BOOL loggedFirst;
    if (!loggedFirst) { loggedFirst = YES; DLog(@"帧率动画首帧显示: 共 %lu 帧 (目录 %@)", (unsigned long)frames.count, animFolder ?: @"默认第一个文件夹"); }
    // 每600帧(约12s@50fps)输出一次状态: 排查"渲染了但看不见"
    static NSInteger diagCount;
    if (++diagCount % 600 == 1)
        DLog(@"帧率动画状态: idx=%ld hidden=%d frame=%@ 父视图=%@ 透明度=%.1f", (long)_idx, self.isHidden, NSStringFromCGRect(self.frame), NSStringFromClass(self.superview.class), self.layer.opacity);
    // 缩放(改bounds, 图片随边界拉伸) + 偏移: 仅参数或尺寸变化时刷新(CPU 优化: 避免每帧触发隐式布局)
    static CGSize lastIvSize; static CGFloat lastScale, lastOx, lastOy;
    CGSize wantSize = CGSizeMake(self.bounds.size.width * animScale, self.bounds.size.height * animScale);
    CGPoint wantC = CGPointMake(self.bounds.size.width / 2 + animOffsetX, self.bounds.size.height / 2 + animOffsetY);
    if (!CGSizeEqualToSize(lastIvSize, wantSize) || lastScale != animScale || lastOx != animOffsetX || lastOy != animOffsetY) {
        _iv.bounds = CGRectMake(0, 0, wantSize.width, wantSize.height);
        _iv.center = wantC;
        lastIvSize = wantSize; lastScale = animScale; lastOx = animOffsetX; lastOy = animOffsetY;
    }
}

- (void)dealloc { [_link invalidate]; }
@end

/* 2.6.10: 遮罩层改为"专辑光晕" —— 严格按规范实现(见 DIAlbumMask.m):
     · 封面本体 + 遮罩 png 作为 maskView(不是叠上去)
     · 素材从 /var/mobile/灵动岛/遮罩素材 读, 偏好键 diAlbumMaskAsset
     · 没有素材就直接不做(不兜底, 兜底就是黑块)
   这里只留一个"跟随宿主"的容器: 每帧把光晕框贴合到专辑位置, 尺寸 = 专辑宽 × 1.7。 */
@interface DIMaskView : UIView
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, assign) NSInteger miss;
@property (nonatomic, strong) UIView *haloContainer;
@property (nonatomic, weak) UIImage *lastCover;   /* 上一帧封面: 换歌才重建 */
@end

@implementation DIMaskView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = NO;
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step)];
        _link.preferredFramesPerSecond = 60;
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}

/* 从宿主子树里找专辑封面: 优先正方形 UIImageView(音乐岛封面就是方形), 其次任意有图的 UIImageView。
   2.6.11: 之前把 haloContainer 同时当 card 和 albumView 传, albumView.image 永远为 nil,
   于是永远拿不到封面 → 光晕根本画不出来(用户看到"没效果")。 */
static UIImage *diFindAlbumCover(UIView *host, CGRect inRect) {
    UIImage *bestImg = nil;
    CGFloat bestScore = -1;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:host];
    int g = 0;
    while (stack.count && g++ < 400) {
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0];
        for (UIView *s in v.subviews) [stack addObject:s];
        if (![v isKindOfClass:UIImageView.class]) continue;
        UIImage *img = ((UIImageView *)v).image;
        if (!img || img.size.width < 8) continue;
        CGRect r = [v convertRect:v.bounds toView:host];
        if (!CGRectIntersectsRect(r, inRect)) continue;
        /* 打分: 越接近正方形、越靠近左侧越像封面 */
        CGFloat ratio = img.size.width / MAX(1.0, img.size.height);
        CGFloat squareScore = 1.0 - MIN(1.0, fabs(ratio - 1.0));
        CGFloat leftScore = 1.0 - MIN(1.0, fabs(CGRectGetMidX(r) - CGRectGetMidX(inRect)) / MAX(1.0, host.bounds.size.width));
        CGFloat score = squareScore * 2.0 + leftScore;
        if (score > bestScore) { bestScore = score; bestImg = img; }
    }
    return bestImg;
}

- (void)step {
    @try {
        UIView *host = self.superview;
        if (!host || host.window == nil) { self.hidden = YES; if (++_miss > 15) _link.paused = YES; return; }
        BOOL mini = host.bounds.size.height > 20 && host.bounds.size.height <= 60 && host.bounds.size.width > 40;
        BOOL active = diMiniMusicActive(host);
        BOOL gate = mini && enabled && !gLocked && maskOn && active && !gRecordingActive;
        if (!gate) {
            if (!self.hidden) { self.hidden = YES; DLog(@"光晕隐藏: mini=%d active=%d maskOn=%d", mini, active, maskOn); }
            if (++_miss > 15) _link.paused = YES;
            return;
        }
        _miss = 0;

        /* 专辑区域: 宿主左端的一个正方形(边长≈宿主高) —— 原生专辑就贴在这里 */
        CALayer *pl = host.layer.presentationLayer;
        CGSize bs = pl ? pl.bounds.size : host.bounds.size;
        CGFloat side = bs.height;
        CGRect albumRect = CGRectMake(0, 0, side, side);
        CGFloat d = side * 1.7;                     /* 参考实现: 封面宽 × 1.7 */
        CGRect f = CGRectMake(CGRectGetMidX(albumRect) - d * 0.5,
                              CGRectGetMidY(albumRect) - d * 0.5, d, d);

        if (!CGRectEqualToRect(self.frame, f)) self.frame = f;
        if (!self.haloContainer) {
            self.haloContainer = [[UIView alloc] initWithFrame:self.bounds];
            self.haloContainer.userInteractionEnabled = NO;
            self.haloContainer.backgroundColor = [UIColor clearColor];
            [self addSubview:self.haloContainer];
        }
        self.haloContainer.frame = self.bounds;

        /* 2.6.11: 只在"封面变了 / 直径变了 / 素材变了"时重建, 不再每帧重建 UIImageView。
           原来 60fps 每帧 alloc 两个 UIImageView + maskView, 是视频卡顿的主因之一。 */
        UIImage *cover = diFindAlbumCover(host, albumRect);
        /* 缓存键 = 素材失效代数 + 直径: 换素材/换直径才重建 */
        NSString *assetKey = [NSString stringWithFormat:@"%ld@%.0f", (long)DIMaskGeneration(), d];
        NSString *prevKey = objc_getAssociatedObject(self, "diHaloKey");
        BOOL sameCover = (cover == _lastCover);
        if (!self.hidden && sameCover && prevKey && [prevKey isEqualToString:assetKey] && self.haloContainer.subviews.count) {
            return;   /* 什么都不用做 */
        }
        _lastCover = cover;
        objc_setAssociatedObject(self, "diHaloKey", assetKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (cover) {
            /* 直接按"封面图 + 遮罩 png 当 maskView"重建, 垫在容器底层。
               注意这里不能传 host 当 albumView —— DIApplyAlbumHalo 内部会 convertPoint,
               而 host 不在容器坐标系里, 会算歪。 */
            DIClearAlbumHalo(self.haloContainer);
            UIImage *mask = DIMaskCurrentImage();
            if (mask) {
                UIImageView *halo = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, d, d)];
                halo.tag = DIAlbumHaloTag;
                halo.image = cover;
                halo.contentMode = UIViewContentModeScaleAspectFill;
                halo.layer.cornerRadius = d / 2.0;
                halo.clipsToBounds = YES;
                halo.userInteractionEnabled = NO;
                UIImageView *mv = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, d, d)];
                mv.image = mask;
                mv.contentMode = UIViewContentModeScaleToFill;   /* 蒙版铺满 */
                mv.userInteractionEnabled = NO;
                halo.maskView = mv;                              /* 关键: maskView, 不是 addSubview */
                halo.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
                [self.haloContainer insertSubview:halo atIndex:0];
            }
        }
        if (self.hidden) {
            self.hidden = NO;
            DLog(@"光晕显示: 宿主=%.0fx%.0f 直径=%.0f 封面=%dx%d", bs.width, bs.height, d,
                 (int)cover.size.width, (int)cover.size.height);
        }
    } @catch (NSException *e) { DLog(@"光晕 step 异常(已忽略): %@", e); }
}
- (void)dealloc { [_link invalidate]; }
@end

/* 音频开关: 开→在音频门户层(CALayerHost)上用掩码挖洞, 只隐藏右上角波形, 按钮/专辑/歌词不受影响; 关→移除掩码
   注意: 只在展开稳定态应用(收缩态岛尺寸太小, 算出的洞坐标是乱值会遮到歌词); 洞用展开态实测固定坐标(波形 x≈353-381 y≈42-65) */
static char kDiMaskOn;
static char kDiMaskW; // 记录掩码应用时的岛宽: 重新展开宽度变化>1pt 时重算洞位置
static void syncNativeSpectrum(UIView *bestRoot) {
    CALayer *audioL = diFindAudioLayer(bestRoot);
    if (!audioL) return;
    if (!spectrumOn || !enabled) {
        if (audioL.mask) { audioL.mask = nil; objc_setAssociatedObject(audioL, &kDiMaskOn, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); DLog(@"音频开关关: 移除波形掩码"); }
        return;
    }
    CALayer *pl = bestRoot.layer.presentationLayer;
    CGSize bs = pl ? pl.bounds.size : bestRoot.bounds.size;
    if (bs.width < 250 || bs.height < 150 || bs.height > 300) {
        // 收缩态(高36)或锁屏大卡等超大门户(高700+): 不动掩码, 防止洞坐标算错遮到别的内容
        return;
    }
    CGRect hole = CGRectMake(bs.width - 69, 26, 54, 50); // 波形实际范围外扩少许(实测波形 x 353-381 y 42-65), 跟随岛宽实时计算
    BOOL applied = [objc_getAssociatedObject(audioL, &kDiMaskOn) isEqual:@YES];
    CAShapeLayer *m = (CAShapeLayer *)audioL.mask;
    if (applied && m) {
        // 已应用: 岛宽变化超过1pt(重新展开/切换岛)才重算洞位置, 否则不动
        NSNumber *lastW = objc_getAssociatedObject(audioL, &kDiMaskW);
        if (lastW && fabs([lastW doubleValue] - bs.width) < 1.0) return;
        objc_setAssociatedObject(audioL, &kDiMaskW, @(bs.width), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIBezierPath *p = [UIBezierPath bezierPathWithRect:m.frame];
        UIBezierPath *h = [UIBezierPath bezierPathWithRoundedRect:hole cornerRadius:12];
        [p appendPath:h];
        m.path = p.CGPath;
        return;
    }
    CAShapeLayer *nm = [CAShapeLayer new];
    nm.frame = CGRectMake(0, 0, audioL.bounds.size.width, audioL.bounds.size.height);
    UIBezierPath *p = [UIBezierPath bezierPathWithRect:nm.frame];
    UIBezierPath *h = [UIBezierPath bezierPathWithRoundedRect:hole cornerRadius:12];
    [p appendPath:h];
    nm.fillRule = kCAFillRuleEvenOdd; // 洞里露出岛自己的内容, 洞外保留音乐门户
    nm.path = p.CGPath;
    audioL.mask = nm;
    objc_setAssociatedObject(audioL, &kDiMaskOn, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(audioL, &kDiMaskW, @(bs.width), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    DLog(@"音频开关开: 已挖洞隐藏波形 %@ (岛 %@)", NSStringFromCGRect(hole), NSStringFromCGSize(bs));
}

#pragma mark - 宿主挂载

/* 2.2.6: 岛上通知样式 —— 关联对象键 */
static char kLabelOrigColor;   // UILabel 原始颜色(恢复用)
static char kLabelFlowMask;    // UILabel 流光渐变图层(CAGradientLayer)
static char kLabelWidths;      // 2.6.11: 每个合成字符的显示宽度缓存(避免每帧测量文本)
static char kLabelWidthsKey;   // 2.6.11: 宽度缓存对应的文本, 文本变了才重算
static char kLabelAnyColored;  // 宿主上是否有标签被上过色(NSNumber, 关闭时判断要不要还原)

/* 流光渐变(2.2.8 最终方案): 逐字上色 attributedText。
   把当前文字按字符切片, 每个字符按"沿 x 轴位置 + 流动相位"取色 → 得到从左到右的渐变,
   相位随时间推进即形成"流动"效果。纯 UIKit 文本渲染, 不依赖 CA 蒙版/纹理, 兼容性最好。
   colors: 1~8 个颜色; phase: 0~1 循环相位。 */
static UIColor *diColorAt(NSArray<UIColor *> *colors, CGFloat t) {
    NSUInteger n = colors.count;
    if (!n) return [UIColor whiteColor];
    if (n == 1) return colors[0];
    t = t - floor(t);
    CGFloat pos = t * (CGFloat)n;
    NSUInteger i0 = (NSUInteger)pos % n;
    NSUInteger i1 = (i0 + 1) % n;
    CGFloat f = pos - floor(pos);
    CGFloat r0 = 1, g0 = 1, b0 = 1, a0 = 1, r1 = 1, g1 = 1, b1 = 1, a1 = 1;
    [colors[i0] getRed:&r0 green:&g0 blue:&b0 alpha:&a0];
    [colors[i1] getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
    return [UIColor colorWithRed:r0 + (r1 - r0) * f green:g0 + (g1 - g0) * f blue:b0 + (b1 - b0) * f alpha:1.0];
}

/* 逐字上色: 把文字按字符切片, 每个字符按"沿文字从左到右的位置 + 相位"取色。
   phase 只决定渐变的起点偏移: 关流光时固定 phase=0 → 得到静态的多色渐变(设几个颜色就显示几段);
   开流光时 phase 随时间推进 → 同一串颜色循环滚动, 看起来在流动。 */
/* 2.6.10: 流光上色(重写, 修两个老问题):
   ① 字体被放大 —— 旧版把 attributesAtIndex:0 的属性刷到全文, 而 UILabel 自己还会用
      font 属性再排一次, 两边字号打架; 现在**绝不写 NSFontAttributeName**,
      只继承段落样式/字距, 字号交给 UILabel.font 自己管。
   ② 表情乱码 —— 旧版 NSMakeRange(i,1) 按 UTF-16 单码元切, emoji 是代理对会被从中间切断;
      现在按 composed character sequence 切段, 一个表情一整段, 不拆。 */
static BOOL applyFlow(UIView *v, CGFloat phase) {
    UILabel *lb = [v isKindOfClass:UILabel.class] ? (UILabel *)v : nil;
    if (!lb) return NO;
    NSAttributedString *cur = lb.attributedText;
    NSString *text = cur.length ? cur.string : lb.text;
    if (!text.length) return NO;
    NSArray<UIColor *> *cs = gNotifyColors;
    if (!cs.count) cs = @[gNotifyColor ?: [UIColor whiteColor]];
    NSUInteger n = text.length;

    NSMutableAttributedString *as = cur.length ? [cur mutableCopy] : [[NSMutableAttributedString alloc] initWithString:text];
    /* 只继承非字体属性(段落样式/字距等), 字体保持系统原样。
       2.6.11: 必须顺手把上一帧写进去的 NSForegroundColorAttributeName 抹掉 ——
       否则 setAttributes 只留了"第一个色块"的颜色, 整串变成单色, 流光就"没效果"了。 */
    if (n) {
        NSDictionary *attrs = [as attributesAtIndex:0 effectiveRange:NULL];
        NSMutableDictionary *keep = [NSMutableDictionary dictionary];
        for (id k in attrs) {
            if ([k isEqual:NSFontAttributeName]) continue;
            if ([k isEqual:NSForegroundColorAttributeName]) continue;
            keep[k] = attrs[k];
        }
        [as setAttributes:keep range:NSMakeRange(0, n)];
    }
    if (cs.count == 1) {
        [as addAttribute:NSForegroundColorAttributeName value:cs[0] range:NSMakeRange(0, n)];
    } else {
        /* 按显示宽度分配渐变色, 并按合成字符切段(不破坏 emoji)。
           2.6.11: 宽度只算一次并缓存在标签上 —— 原来每帧对每个字符做 sizeWithAttributes,
           长文本下每帧上千次文本测量, 是视频/流光卡顿的主要来源。 */
        UIFont *f = lb.font ?: [UIFont systemFontOfSize:17];
        NSArray<NSNumber *> *ws = objc_getAssociatedObject(v, &kLabelWidths);
        NSString *wsKey = objc_getAssociatedObject(v, &kLabelWidthsKey);
        CGFloat total = 0;
        if (!ws || ![wsKey isEqualToString:text]) {
            NSDictionary *mAttr = @{NSFontAttributeName: f};
            NSMutableArray<NSNumber *> *tmp = [NSMutableArray array];
            __block CGFloat t2 = 0;
            [text enumerateSubstringsInRange:NSMakeRange(0, n) options:NSStringEnumerationByComposedCharacterSequences
                                  usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) {
                CGFloat w = [sub sizeWithAttributes:mAttr].width;
                if (w <= 0) w = 1;
                [tmp addObject:@(w)];
                t2 += w;
            }];
            ws = tmp;
            objc_setAssociatedObject(v, &kLabelWidths, ws, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(v, &kLabelWidthsKey, text, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            total = t2;
        } else {
            for (NSNumber *w in ws) total += w.doubleValue;
        }
        if (total <= 0) total = 1;
        __block CGFloat acc = 0;
        __block NSUInteger bi = 0;
        [text enumerateSubstringsInRange:NSMakeRange(0, n) options:NSStringEnumerationByComposedCharacterSequences
                              usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) {
            CGFloat w = (bi < ws.count) ? ws[bi].doubleValue : 1;
            CGFloat t = (acc + w * 0.5) / total + phase;
            [as addAttribute:NSForegroundColorAttributeName value:diColorAt(cs, t) range:r];
            acc += w; bi++;
        }];
    }
    lb.attributedText = as;
    objc_setAssociatedObject(v, &kLabelFlowMask, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

/* 2.2.7: 通知岛判定 —— 通知卡结构特征(长文本标题/正文 + 应用图标),
   排除音乐岛(有跨进程音频层)。判定结果同时挂到宿主与其胶囊容器上,
   供 updateSingleVideo 过滤视频背景。 */
static BOOL diHostLooksLikeNotification(UIView *host, BOOL *detail) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:host];
    int g = 0, longCount = 0, imgCount = 0;
    CGFloat hostH = host.bounds.size.height;
    while (stack.count && g++ < 500) {
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0];
        for (UIView *s in v.subviews) [stack addObject:s];
        if ([v isKindOfClass:UILabel.class]) {
            NSString *t = ((UILabel *)v).text ?: @"";
            if (!t.length) continue;
            if ([t containsString:@"%"] || [t containsString:@":"]) continue; // 电量/时钟/倒计时
            if (t.length >= 10) longCount++;
        } else if ([v isKindOfClass:UIImageView.class]) {
            if (v.bounds.size.width >= 12 && v.bounds.size.width <= 44) imgCount++;
        }
    }
    BOOL isMusic = (diFindAudioLayer(host) != nil);
    /* 通知岛: 有长文本(标题/正文), 且不是音乐岛; 有应用图标更确信 */
    BOOL notif = !isMusic && hostH > 25 && (longCount >= 1 && imgCount >= 1);
    if (!notif && !isMusic && longCount >= 2) notif = YES;
    if (detail) *detail = (longCount > 0);
    return notif;
}

/* 2.6.11: 流光白名单 —— 只有"通知卡"和"歌词岛"允许上流光。
   电话来电、NC 电池详情、音量/静音、灵动岛各种状态胶囊都不上, 用原色。
   判定靠宿主自己的类名/祖先类名 + 内部是否有歌词特征, 不做全局默认开。 */
static BOOL diHostWantsFlow(UIView *host) {
    if (!host) return NO;
    /* 0) 设置页里的"文字颜色预览"小窗: 单独打标记放行 */
    if (objc_getAssociatedObject(host, "diPreviewAllow")) return YES;
    /* 1) 通知卡: 结构判定(长文本 + 应用图标), 已有的判定函数直接用 */
    if (diHostLooksLikeNotification(host, NULL)) return YES;
    /* 2) 歌词岛: 宿主类名含 Lyrics / NowPlaying, 或子树里有歌词特征标签 */
    for (Class c = host.class; c && c != [UIView class]; c = class_getSuperclass(c)) {
        NSString *cn = NSStringFromClass(c);
        if ([cn containsString:@"Lyrics"] || [cn containsString:@"NowPlaying"]) return YES;
    }
    /* 3) 明确排除: 来电 / 电池 / 音量 / 计时 / 录屏等系统状态 */
    for (Class c = host.class; c && c != [UIView class]; c = class_getSuperclass(c)) {
        NSString *cn = NSStringFromClass(c);
        if ([cn containsString:@"Call"] || [cn containsString:@"Battery"]
            || [cn containsString:@"Volume"] || [cn containsString:@"Ringer"]
            || [cn containsString:@"Timer"] || [cn containsString:@"Recording"]
            || [cn containsString:@"Sensor"] || [cn containsString:@"Connect"]) return NO;
    }
    return NO;
}

static void applyNotifyStyle(UIView *host) {
    if (!host) return;
    /* 通知岛判定(只用于"通知不使用视频背景", 与是否开了颜色无关):
       必须无条件写, 否则开关组合不同时标记会残留/缺失。 */
    if (notifyBgOff || notifyColorOn) {
        BOOL isNotif = diHostLooksLikeNotification(host, NULL);
        NSNumber *prev = objc_getAssociatedObject(host, &kHostIsNotif);
        if (!prev || prev.boolValue != isNotif) {
            objc_setAssociatedObject(host, &kHostIsNotif, @(isNotif), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            DLog(@"通知岛判定: host=%@ frame=%@ → %@", NSStringFromClass(host.class), NSStringFromCGRect(host.bounds), isNotif ? @"通知岛" : @"非通知");
        }
        /* 同步到胶囊容器: 视频层在 syncFrameToHost 里按容器标记隐藏自己 */
        UIView *cap = islandRoot(host);
        if (cap) objc_setAssociatedObject(cap, &kCapIsNotif, @(isNotif), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!notifyColorOn && !objc_getAssociatedObject(host, &kLabelAnyColored)) {
        /* 着色关闭且本宿主从没被上过色 → 不需要遍历标签(省掉每秒数百次遍历) */
        return;
    }
    /* 2.6.11: 只有通知卡 / 歌词岛给流光, 其它界面(来电、NC 电池详情、音量等)保持原色。
       之前是全宿主上色, 所以每个界面都被染色, 且主线程忙 → 视频卡顿。
       关掉颜色开关时也走这里 → 会把之前上过的色还原干净。 */
    BOOL wantFlow = notifyColorOn && diHostWantsFlow(host);
    if (!wantFlow) {
        /* 撤流光 + 还原原始色, 只处理"曾被我们上过色"的标签 */
        int restored = 0;
        NSMutableArray<UIView *> *stack2 = [NSMutableArray arrayWithObject:host];
        int g2 = 0;
        while (stack2.count && g2++ < 400) {
            UIView *v = stack2.firstObject; [stack2 removeObjectAtIndex:0];
            for (UIView *s in v.subviews) [stack2 addObject:s];
            if (![v isKindOfClass:UILabel.class]) continue;
            UILabel *lb = (UILabel *)v;
            BOOL hadFlow = objc_getAssociatedObject(lb, &kLabelFlowMask) != nil;
            if (!hadFlow) continue;
            /* 还原时不能写 lb.text —— 那会把 attributedText 整个丢掉,
               系统通知里靠 attributedText 渲染的表情/行距/截断都会失效(乱码成因之一)。
               就地去掉我们加的颜色属性, 其余属性原样保留。 */
            NSAttributedString *cur = lb.attributedText;
            NSString *plain = cur.length ? cur.string : lb.text;
            objc_setAssociatedObject(lb, &kLabelFlowMask, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (cur.length) {
                NSMutableAttributedString *as = [cur mutableCopy];
                [as removeAttribute:NSForegroundColorAttributeName range:NSMakeRange(0, as.length)];
                lb.attributedText = as;
            } else if (plain.length) {
                lb.text = plain;
            }
            UIColor *orig = objc_getAssociatedObject(lb, &kLabelOrigColor);
            if (orig) { lb.textColor = orig; objc_setAssociatedObject(lb, &kLabelOrigColor, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
            restored++;
        }
        if (restored) objc_setAssociatedObject(host, &kLabelAnyColored, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    CGFloat phase = (CGFloat)fmod(CFAbsoluteTimeGetCurrent() / 2.5, 1.0); // 2.5秒一轮流光
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:host];
    int g = 0, colored = 0;
    while (stack.count && g++ < 400) {
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0];
        for (UIView *s in v.subviews) [stack addObject:s];
        if (![v isKindOfClass:UILabel.class]) continue;
        UILabel *lb = (UILabel *)v;
        if (!lb.text.length && !lb.attributedText.length) continue;
        if (wantFlow) {
            if (!objc_getAssociatedObject(lb, &kLabelOrigColor))
                objc_setAssociatedObject(lb, &kLabelOrigColor, lb.textColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            /* 关流光: phase 固定 0 → 静态多色渐变(设几个颜色显示几段);
               开流光: phase 随时间推进 → 同一串颜色滚动流动。
               两种情况都上色, 不再退化成"只用第一个颜色"。 */
            /* 2.6.10: 先 applyFlow 再兜底色。反过来会把 textColor 带进 attributedText,
               关流光时还原不干净, 也会让 UILabel 按两次不同字号重排(字体看起来变大)。 */
            if (applyFlow(lb, notifyFlowOn ? phase : 0)) {
                if (gNotifyColor) lb.textColor = gNotifyColor;
                colored++;
            }
        }
    }
    /* 2.2.11: 自检日志(每 5 秒最多一次) —— 用于确认着色是否真的落到标签上 */
    if (colored > 0) objc_setAssociatedObject(host, &kLabelAnyColored, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    else if (!notifyColorOn) objc_setAssociatedObject(host, &kLabelAnyColored, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    static CFAbsoluteTime lastSelfLog;
    CFAbsoluteTime nowT = CFAbsoluteTimeGetCurrent();
    if (notifyColorOn && nowT - lastSelfLog > 5) {
        lastSelfLog = nowT;
        DLog(@"着色自检: 宿主=%@ 标签数=%d 流光=%d 色数=%lu", NSStringFromClass(host.class), colored,
             notifyFlowOn, (unsigned long)gNotifyColors.count);
    }
}

static BOOL viewHasToken(UIView *v, NSString *token) {
    for (Class c = v.class; c && c != [UIView class]; c = class_getSuperclass(c))
        if ([NSStringFromClass(c) containsString:token]) return YES;
    return NO;
}

// 视频要铺满整颗岛: 向上取"最外层的岛尺寸小视图"(岛胶囊本体), 全屏大视图之前的那一层
static UIView *islandRoot(UIView *v) {
    UIView *best = v;
    CGFloat winW = v.window ? v.window.bounds.size.width : 0;
    CGFloat winH = v.window ? v.window.bounds.size.height : 0;
    for (UIView *p = v.superview; p; p = p.superview) {
        CGFloat w = p.bounds.size.width, h = p.bounds.size.height;
        if (winW > 0 && w >= winW * 0.95) break; // 顶部全屏容器, 停止
        if (winH > 0 && h >= winH * 0.6) break;
        if (w > 40 && h > 20) best = p;          // 岛尺寸: 继续向外, 取最外层
    }
    return best;
}

static void attach(UIView *host) {
    if (!host || host.bounds.size.width < 2 || host.bounds.size.height < 2) return;
    if (!hostTable) hostTable = [NSHashTable weakObjectsHashTable];
    if (![hostTable containsObject:host]) {
        [hostTable addObject:host];
        DLog(@"记录宿主 host=%@ frame=%@", NSStringFromClass(host.class), NSStringFromCGRect(host.bounds));
    }
}

// 每窗口双层视频: 小岛层 + 展开层, 各自加载各自素材持续循环;
// 形态切换只是两层 hidden 互换 → 零重载零黑屏; 不可见层暂停(省电)
/* nil 安全的层数组: @[] 字面量含 nil 会抛异常(安全模式根因) */
static NSArray *diLayers(DIVideoView *a, DIVideoView *b) {
    NSMutableArray *arr = [NSMutableArray array];
    if (a) [arr addObject:a];
    if (b) [arr addObject:b];
    return arr;
}

static void wakeLayer(DIVideoView *v, UIView *bestRoot) {
    if (!v) return;
    BOOL wasPaused = v.syncLink.paused;
    v.syncLink.paused = NO; // 有岛活动: 唤醒逐帧循环
    if (wasPaused && v.superview == bestRoot) {
        // 从暂停唤醒的第一帧来不及贴合 → 立即手动对齐一次当前呈现尺寸, 消除快速切换的右缘黑边
        CALayer *pl = bestRoot.layer.presentationLayer;
        CGRect b = pl ? pl.bounds : bestRoot.bounds;
        v.frame = CGRectInset(b, -2, -2);
        v.layer.cornerRadius = pl ? pl.cornerRadius : bestRoot.layer.cornerRadius;
    }
}

// CALayer 层树 dump: 频谱动画渲染在跨进程 scene 的 CA 层里, UIView dump 看不到
static void dumpLayers(CALayer *l, int depth) {
    if (!l || depth > 14) return;
    NSMutableString *ind = [NSMutableString string];
    for (int i = 0; i < depth; i++) [ind appendString:@"  "];
    NSString *cn = NSStringFromClass(l.class);
    NSString *nm = l.name ?: @"";
    DLog(@"%@%@ %@%@", ind, cn, NSStringFromCGRect(l.frame), nm.length ? [@" name=" stringByAppendingString:nm] : @"");
    for (CALayer *s in l.sublayers) dumpLayers(s, depth + 1);
}

/* 2.2.60: 边框/轮廓的周期性重算 —— 卡片收/展时 bounds 会变(301x66 → 301x125),
   但 diStylePlatter 只在若干时机被调用, 尺寸变了却没人通知它, 于是轮廓一直停在
   旧尺寸+旧圆角, 看起来就是"边框直角、没贴合"。这里每 0.25s 兜一次:
   尺寸或圆角一变就立刻重画, 保证永远贴合当前卡片。 */
static void diRefreshContour(void) {
    return;   /* 2.3.0: 边框/阴影/流光均已移除, 整条路径停用 */
    if (smallEdgeOn) diSyncEdgeGlowAll();   /* 流光独立于边框/阴影开关 */
    static CFAbsoluteTime lastRun;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastRun < 0.2) return;
    lastRun = now;
    for (UIView *h in hostTable) {
        if (!h.window || h.isHidden) continue;
        UIView *pl = diFindPlatter(h);
        if (!pl) continue;
        static char kLastGeom;
        NSString *key = [NSString stringWithFormat:@"%.0fx%.0f", pl.bounds.size.width, pl.bounds.size.height];
        NSString *prev = objc_getAssociatedObject(pl, &kLastGeom);
        if (prev && [prev isEqualToString:key]) continue;
        objc_setAssociatedObject(pl, &kLastGeom, key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        diStylePlatter(pl);
        DLog(@"轮廓重算: 卡片 %@ → 圆角 %.1f", key, pl.bounds.size.height * 0.5);
    }
}

static void updateSingleVideo(UIWindow *win) {
    if (!win) return;
    diRefreshContour();
    DIVideoView *smallV = objc_getAssociatedObject(win, &kWinVideoSmall);
    DIVideoView *expandV = objc_getAssociatedObject(win, &kWinVideoExpand);

    /* 2.2.53: 录屏素材层先处理 —— 它挂在独立的"方形录屏指示岛"上, 与小岛胶囊无关。
       放在函数最前面, 避免后面 bestRoot 为空时提前 return 导致这条路永远走不到。
       位置由 syncFrameToHost 每帧按指示岛内 accessory 的真实 frame 计算。 */
    {
        DIVideoView *recV = objc_getAssociatedObject(win, &kWinVideoRec);
        if (!recV) {
            recV = [[DIVideoView alloc] initWithFrame:CGRectZero];
            recV.circleLayer = YES;
            recV.hidden = YES;
            objc_setAssociatedObject(win, &kWinVideoRec, recV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        UIView *recHost = enabled ? diRecIslandHost() : nil;
        if (recHost && recHost.window == win) {
            if (recV.superview != recHost) {
                [recV removeFromSuperview];
                /* 2.2.56: 垫到指示岛最底层(用户反馈之前在最上面, 会盖住其他素材)。
                   原生圆点靠"隐藏它的 layer"让位, 不依赖层级 —— 所以放最底也能显示,
                   且不会遮挡岛内任何其它内容。 */
                [recHost insertSubview:recV atIndex:0];
                recHost.clipsToBounds = NO;
                static BOOL loggedMount;
                if (!loggedMount) {
                    loggedMount = YES;
                    DLog(@"录屏素材层挂载到指示岛(最底层) %@ %.0fx%.0f",
                         NSStringFromClass(recHost.class), recHost.bounds.size.width, recHost.bounds.size.height);
                }
            }
            /* 每轮重申保持在最底(系统重排可能把它提上来) */
            if (recHost.subviews.firstObject != recV) [recHost sendSubviewToBack:recV];
            recV.syncLink.paused = NO;
        } else if (recV.superview) {
            [recV removeFromSuperview];
            recV.hidden = YES;
        }
    }

    if (!enabled) {
        for (DIVideoView *v in diLayers(smallV, expandV)) {
            if (v && !v.hidden) { v.hidden = YES; if (v.player.timeControlStatus != AVPlayerTimeControlStatusPaused) [v.player pause]; }
        }
        return;
    }
    UIView *capRoot = nil, *bestRoot = nil; CGFloat bestA = 0;
    /* 2.2.11: 通知背景过滤 —— 逐个宿主判断。之前"窗口里只要有一个通知岛就不挂视频"会误杀音乐岛。
       这里只跳过"自身判定为通知岛"的宿主; 真正的隐藏由视频层在 syncFrameToHost 里按容器标记逐帧复核。 */
    for (UIView *h in hostTable) {
        if (h.window != win || h.isHidden) continue; // 不看 alpha: 岛淡入淡出期间仍要贴合
        if (h.bounds.size.width < 2 || h.bounds.size.height < 2) continue;
        if (notifyBgOff) {
            BOOL notif = [objc_getAssociatedObject(h, &kHostIsNotif) boolValue];
            if (!notif) notif = diHostLooksLikeNotification(h, NULL); // 兜底: applyNotifyStyle 还没跑过
            if (notif) continue;
        }
        UIView *root = islandRoot(h);
        if (!root) continue;
        // 锁定官方岛胶囊本体: 展开/收缩始终是同一视图, 视频永不搬迁 → 根除闪烁
        if ([NSStringFromClass(root.class) isEqualToString:@"SBSystemApertureContainerView"]) { capRoot = root; break; }
        CGFloat a = root.bounds.size.width * root.bounds.size.height;
        if (a > bestA) { bestA = a; bestRoot = root; }
    }
    if (capRoot) bestRoot = capRoot;
    if (!bestRoot) {
        for (DIVideoView *v in diLayers(smallV, expandV)) {
            if (v && !v.hidden) { v.hidden = YES; if (v.player.timeControlStatus != AVPlayerTimeControlStatusPaused) [v.player pause]; }
        }
        return;
    }
    if (!smallV) {
        smallV = [[DIVideoView alloc] initWithFrame:bestRoot.bounds];
        smallV.expandedLayer = NO;
        objc_setAssociatedObject(win, &kWinVideoSmall, smallV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!expandV) {
        expandV = [[DIVideoView alloc] initWithFrame:bestRoot.bounds];
        expandV.expandedLayer = YES;
        objc_setAssociatedObject(win, &kWinVideoExpand, expandV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (DIVideoView *v in diLayers(smallV, expandV)) {
        if (v.superview != bestRoot) {
            [v removeFromSuperview];
            [bestRoot insertSubview:v atIndex:0]; // 垫到底层: 文字/图标都在视频之上
            bestRoot.clipsToBounds = YES;
            v.frame = bestRoot.bounds; // 仅挂载时设初始尺寸; 动画中交给 displayLink
            v.layer.cornerRadius = bestRoot.layer.cornerRadius;
            [v loadVideo:materialPathFor(v.expandedLayer)]; // 挂载即加载各自素材, 首次展开零等待
            DLog(@"挂载视频层(%@) container=%@ frame=%@ 素材=%@", v.expandedLayer ? @"展开" : @"小岛", NSStringFromClass(bestRoot.class), NSStringFromCGRect(bestRoot.bounds), materialPathFor(v.expandedLayer) ?: @"(无)");
        }
        // 关键: 动画进行中不设 frame(打架会闪黑); 仅在暂停唤醒瞬间手动对齐一次
        wakeLayer(v, bestRoot);
        if (bestRoot.subviews.firstObject != v) [bestRoot sendSubviewToBack:v];
    }
    // 展开态: dump 跨进程 CALayer 层树(频谱动画在这里渲染), 2s 后再抓一次布局稳定版; 30s 窗口后重新计数
    static int dumpCount; static CFAbsoluteTime dumpStart;
    CFAbsoluteTime nowT = CFAbsoluteTimeGetCurrent();
    if (dumpStart == 0 || nowT - dumpStart > 30) { dumpCount = 0; dumpStart = nowT; }
    if (dumpCount < 1 && bestRoot.bounds.size.height > 60) {
        dumpCount++;
        __weak UIView *wr = bestRoot;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (wr && wr.bounds.size.height > 60) {
                DLog(@"===== 岛胶囊 CALayer 层树 dump (展开稳定后) =====");
                dumpLayers(wr.layer, 0);
            }
        });
    }
    // 频谱帧率动画层: 序列帧播放, 盖在展开岛右上角(跨进程频谱上方), 加在最顶层
    // 开关关/无帧素材: 隐藏本层 → 露出系统频谱(关闭=显示原生频谱)
    DIAnimView *animV = objc_getAssociatedObject(win, &kWinVideoSpec);
    if (!animV) {
        animV = [[DIAnimView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(win, &kWinVideoSpec, animV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        static BOOL logged;
        if (!logged) { logged = YES; DLog(@"帧率动画层创建, 帧素材=%lu 张 (目录 %@)", (unsigned long)framePaths().count, kFrameDir); }
    }
    if (animV.superview != bestRoot) {
        [animV removeFromSuperview];
        [bestRoot addSubview:animV]; // 最顶层: 盖住跨进程频谱
        animV.hidden = YES;
    }
    [bestRoot bringSubviewToFront:animV]; // 系统布局会把岛内容分支提到最前, 每轮重申动画层在最顶
    /* 2.6.1: 歌词岛两层(2.2.45 原版挂载) —— 左=专辑位 side0, 右=音频位 side1, 挂岛容器 bestRoot */
    static char kWinAnimMini, kWinAnimMiniAudio;
    DIAnimView *miniAnim = objc_getAssociatedObject(win, &kWinAnimMini);
    if (!miniAnim) {
        miniAnim = [[DIAnimView alloc] initWithFrame:CGRectZero];
        miniAnim.miniMode = YES;
        objc_setAssociatedObject(win, &kWinAnimMini, miniAnim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    DIAnimView *miniAudio = objc_getAssociatedObject(win, &kWinAnimMiniAudio);
    if (!miniAudio) {
        miniAudio = [[DIAnimView alloc] initWithFrame:CGRectZero];
        miniAudio.miniMode = YES;
        miniAudio.side = 1;
        objc_setAssociatedObject(win, &kWinAnimMiniAudio, miniAudio, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSArray<DIAnimView *> *miniLayers = @[miniAnim, miniAudio];
    for (DIAnimView *mv in miniLayers) {
        if (!enabled || gRecordingActive) {
            if (mv.superview) { [mv removeFromSuperview]; mv.hidden = YES; }
            if (mv.iv.image) mv.iv.image = nil;
            mv.link.paused = YES;
            continue;
        }
        if (mv.superview != bestRoot) {
            [mv removeFromSuperview];
            [bestRoot addSubview:mv];
            mv.hidden = YES;
            mv.iv.image = nil;
        }
        [bestRoot bringSubviewToFront:mv];
        mv.link.paused = NO;
    }
    /* 2.6.5: 遮罩层 —— 与专辑同寿命, 且叠在"专辑图层之下"(下一层):
       做法: 加到 bestRoot 后, 用 insertSublayer:below: 把它插到专辑内容层(CALayerHost)下面。
       左侧帧率素材层 miniAnim 保持在最前, 遮罩在它和专辑图之间, 视觉上是"专辑底衬"。 */
    static char kWinMask;
    DIMaskView *maskV = objc_getAssociatedObject(win, &kWinMask);
    if (!maskV) {
        maskV = [[DIMaskView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(win, &kWinMask, maskV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL maskMusic = diMiniMusicActive(bestRoot);
    BOOL maskWanted = enabled && !gRecordingActive && maskOn && maskMusic;
    {
        static CFAbsoluteTime tMLog; static NSString *lastMLog;
        NSString *now = [NSString stringWithFormat:@"遮罩挂载检查: 宿主=%@ %.0fx%.0f 音乐岛=%d 开关=%d 想要=%d 当前super=%@",
                         NSStringFromClass(bestRoot.class), bestRoot.bounds.size.width, bestRoot.bounds.size.height,
                         maskMusic, maskOn, maskWanted, maskV.superview ? NSStringFromClass(maskV.superview.class) : @"(无)"];
        if (![now isEqualToString:lastMLog] && CFAbsoluteTimeGetCurrent() - tMLog > 2) {
            tMLog = CFAbsoluteTimeGetCurrent(); lastMLog = now; DLog(@"%@", now);
        }
    }
    if (!maskWanted) {
        if (maskV.superview) { [maskV removeFromSuperview]; maskV.hidden = YES; }
        maskV.link.paused = YES;
    } else {
        /* 2.6.6: 用 layer 级插入(UIView addSubview + insertSublayer 混用会让 UIView 层级表错乱,
           遮罩会被系统重排到看不见的位置)。先 addSubview 建立 superview 关系,
           再对 layer 做"插到专辑内容层之下", 让 maskV.layer 与 UIView 保持一致。 */
        if (maskV.superview != bestRoot) {
            [maskV removeFromSuperview];
            maskV.frame = CGRectMake(0, 0, bestRoot.bounds.size.width, bestRoot.bounds.size.height);
            [bestRoot addSubview:maskV];
            maskV.hidden = YES;
        }
        CALayer *albumLayer = nil;
        NSMutableArray<CALayer *> *stk = [NSMutableArray arrayWithObject:bestRoot.layer];
        int g2 = 0;
        while (stk.count && g2++ < 300) {
            CALayer *l = stk.firstObject; [stk removeObjectAtIndex:0];
            if ([NSStringFromClass(l.class) containsString:@"CALayerHost"] &&
                l.bounds.size.height >= 200 && l.bounds.size.width >= 150) { albumLayer = l; break; }
            for (CALayer *x in l.sublayers) [stk addObject:x];
        }
        if (albumLayer && albumLayer.superlayer == bestRoot.layer) {
            NSInteger mi = [bestRoot.layer.sublayers indexOfObjectIdenticalTo:maskV.layer];
            NSInteger ai = [bestRoot.layer.sublayers indexOfObjectIdenticalTo:albumLayer];
            if (mi != NSNotFound && ai != NSNotFound && mi > ai) {
                [maskV.layer removeFromSuperlayer];
                [bestRoot.layer insertSublayer:maskV.layer below:albumLayer];
                /* 同步 UIView 的 subviews 顺序, 否则 UIKit 下一次 layout 会把 layer 挪回去 */
                [bestRoot bringSubviewToFront:maskV];
                [bestRoot sendSubviewToBack:maskV];
            }
        }
        maskV.link.paused = NO;
    }
    /* 2.6.5: 歌词岛隐藏原生内容 —— 判据按 196 日志实测(音乐岛结构):
         · 三个小图标 CAPortalLayer(26x22 / 26x22 / 22x22)  —— 是"左图标/右图标", 需要藏
         · 一个巨大的 CALayerHost(407x488, 原尺寸远大于宿主) —— 是专辑图/波形内容层, 需要藏
       只认"音乐岛"(diMiniMusicActive), 充电/人脸/来电/录屏 一律不碰。 */
    {
        static char kHiddenPortals;
        NSMutableArray *found = objc_getAssociatedObject(win, &kHiddenPortals) ?: [NSMutableArray array];
        BOOL isMusicIsland = diMiniMusicActive(bestRoot);
        BOOL wantL = isMusicIsland && miniAnimOn;
        BOOL wantR = isMusicIsland && miniAudioOn;
        /* 动画收尾的过渡期(宿主高度正在 36→55 之间变化)也视为音乐岛, 避免一闪一闪 */
        if (!isMusicIsland && wantL == NO) { /* 非音乐岛: 下面统一恢复 */ }
        for (CALayer *l in found) if (l.isHidden) l.hidden = NO;
        if (found.count) [found removeAllObjects];
        if (wantL || wantR) {
            CGFloat halfW = bestRoot.bounds.size.width * 0.5;
            NSMutableArray<CALayer *> *stack = [NSMutableArray arrayWithObject:bestRoot.layer];
            int guard = 0;
            while (stack.count && guard++ < 300) {
                CALayer *l = stack.firstObject; [stack removeObjectAtIndex:0];
                NSString *cn = NSStringFromClass(l.class);
                BOOL isPortal = [cn containsString:@"CAPortalLayer"] || [cn containsString:@"CALayerHost"];
                if (isPortal) {
                    CGRect r = [bestRoot.layer convertRect:l.bounds fromLayer:l];
                    BOOL isAudioSide = (CGRectGetMidX(r) >= halfW);
                    if ((isAudioSide && wantR) || (!isAudioSide && wantL)) {
                        l.hidden = YES;
                        [found addObject:l];
                    }
                }
                for (CALayer *s2 in l.sublayers) [stack addObject:s2];
            }
        }
        objc_setAssociatedObject(win, &kHiddenPortals, found, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    syncNativeSpectrum(bestRoot); // 音频开关开→隐藏原生音频层, 关→恢复
    animV.link.paused = NO; // 岛活动期间保持动画循环, 内部按开关自隐藏
}


#pragma mark - 歌词岛参数迁移(2.2.37 原版)

static NSString *diElementId(UIView *host) {
    if (!host) return nil;
    static SEL sel; static dispatch_once_t once;
    dispatch_once(&once, ^{ sel = NSSelectorFromString(@"elementIdentifier"); });
    if (![host respondsToSelector:sel]) return nil;
    id v = ((id(*)(id, SEL))objc_msgSend)(host, sel);
    return [v isKindOfClass:NSString.class] ? v : nil;
}

static void migrateLyricsParamsBase(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id f = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("paramsBase237"), (__bridge CFStringRef)kDomain));
    if (f) return;
    NSArray<NSString *> *keys = @[@"miniScaleAdj", @"miniOffsetX", @"miniOffsetY",
                                  @"miniAudioScaleAdj", @"miniAudioOffsetX", @"miniAudioOffsetY"];
    for (NSString *k in keys)
        CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)@(0), (__bridge CFStringRef)kDomain);
    CFPreferencesSetAppValue(CFSTR("paramsBase237"), (__bridge CFPropertyListRef)@"1", (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    DLog(@"歌词岛参数基准迁移完成: 读数归 0, 画面位置由基准(-5/-14 与 -5/+15)保持不变");
}

static void updateHost(UIView *host) {
    if (!viewHasToken(host, @"SAUIElementView")) {
        /* 探针(每类名只记一次): 记录"岛尺寸"但未被识别的视图类, 用于定位 iOS17 临时岛宿主特征 */
        CGFloat w = host.bounds.size.width, h = host.bounds.size.height;
        if (w > 40 && w < 520 && h > 20 && h < 320) {
            static NSMutableSet<NSString *> *seen;
            if (!seen) seen = [NSMutableSet set];
            NSString *cn = NSStringFromClass(host.class);
            if (![seen containsObject:cn]) { [seen addObject:cn]; DLog(@"未识别岛候选类: %@ frame=%@", cn, NSStringFromCGRect(host.bounds)); }
        }
        return;
    }    attach(host);
    if (NSThread.isMainThread && host.window) {
        /* 节流: 岛收/展动画期间 layoutSubviews 每帧触发, 全量扫描很重会卡顿;
           每 0.25 秒最多一次(逐帧贴合由视频层自己的 displayLink 负责, 不受影响) */
        static char kLastUpd;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        NSNumber *last = objc_getAssociatedObject(host.window, &kLastUpd);
        if (!last || now - [last doubleValue] > 0.25) {
            objc_setAssociatedObject(host.window, &kLastUpd, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            updateSingleVideo(host.window);
        }
        /* 2.2.6: 通知样式(文字颜色上色/关闭时恢复 + 通知岛判定)
           流光需要持续重绘 → 取 0.06s(约 16fps) 让文字真正流动; 不流光时 0.3s 足够 */
        {
            static char kLastStyle;
            NSNumber *lastS = objc_getAssociatedObject(host.window, &kLastStyle);
            CFTimeInterval gap = (notifyColorOn && notifyFlowOn) ? 0.06 : 0.3;
            if (!lastS || now - [lastS doubleValue] > gap) {
                objc_setAssociatedObject(host.window, &kLastStyle, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                applyNotifyStyle(host);
            }
        }
    }
}

/* 2.6.5: 几何守护 —— 宿主尺寸一变(sendEvent/layout 都可能晚一拍)立刻重跑 updateHost,
   让"离开音乐岛形态 → 立即隐藏素材"不再有 ~1 秒延时。0.2s 一轮, 开销只有几个 bounds 读取。 */
static void diInstallGeometryWatch(void) {
    static BOOL done = NO;
    if (done) return; done = YES;
    __block NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
        @try {
            if (!hostTable) return;
            for (UIView *h in hostTable.allObjects) {
                if (!h || h.window == nil) continue;
                NSString *key = [NSString stringWithFormat:@"%.1f,%.1f", h.bounds.size.width, h.bounds.size.height];
                NSString *last = objc_getAssociatedObject(h, "diGeoKey");
                if (![key isEqualToString:last]) {
                    objc_setAssociatedObject(h, "diGeoKey", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    updateHost(h);   /* 几何变化 → 立刻重判形态(隐藏/显示即时生效) */
                }
            }
        } @catch (__unused NSException *e) {}
    }];
    [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
}


/* 流光常驻驱动: 岛静止时 layoutSubviews 不再触发, 靠这个定时器推进相位 */
static void diFlowTick(void) {
    if (!(notifyColorOn && notifyFlowOn)) return;
    for (UIView *h in hostTable) {
        if (!h.window || h.isHidden || h.bounds.size.width < 2) continue;
        applyNotifyStyle(h);
    }
}
/* 预览(2.2.20): 只在灵动岛下方弹一个小窗, 3 秒自动消失, 右上角 ✕ 可提前关。
   尺寸从 74pt 缩到 56pt, 不再铺满整行; 去掉 UN 投递(SpringBoard 无 bundle 身份, 投了也被丢弃)。 */
static char kPreviewWrap;
static char kPreviewTimer;
/* 2.2.20: ✕ 的点击目标 —— 单独的轻量对象, 不依赖 SpringBoard 里任何类的选择器 */
@interface DIPreviewCloser : NSObject
@property (nonatomic, weak) UIView *target;
- (void)close;
@end
static char kCloserKey;
@implementation DIPreviewCloser
- (void)close {
    DI_STEP(@"预览: 点了 ✕, 关闭浮层");
    UIView *w = self.target;
    if (w) {
        [objc_getAssociatedObject(w, &kPreviewTimer) invalidate];
        [w removeFromSuperview];
    }
}
@end

/* 2.5.23-3: 偏好变化 → 歌词岛分区层统一重载素材/参数 */

static void diShowPreview(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ diShowPreview(); }); return; }
    (void)0; // 2.2.20: 小窗只显示正文, 不再需要标题
    NSString *body = @"文字颜色预览 ABC 123";
    DI_STEP(@"预览: 开始 (颜色开关=%d 流光=%d 色数=%lu)", notifyColorOn, notifyFlowOn, (unsigned long)gNotifyColors.count);

    UIWindow *win = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) { win = w; break; }
            if (!win) win = w;
        }
        if (win.isKeyWindow) break;
    }
    if (!win) { DI_STEP(@"预览: 找不到可用窗口, 浮层未显示"); return; }

    /* 清掉上一次的浮层 */
    UIView *old = objc_getAssociatedObject(win, &kPreviewWrap);
    if (old) {
        [objc_getAssociatedObject(old, &kPreviewTimer) invalidate];
        [old removeFromSuperview];
    }
    CGFloat W = win.bounds.size.width;
    CGFloat cw = MIN(W - 60, 300);          // 2.2.20: 小窗, 不再整行铺满
    UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake((W - cw) / 2.0, 66, cw, 56)];
    wrap.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.96];
    wrap.layer.cornerRadius = 16;
    wrap.clipsToBounds = NO;
    wrap.userInteractionEnabled = YES;
    [win addSubview:wrap];

    UILabel *bl = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, cw - 46, 36)];
    bl.font = [UIFont boldSystemFontOfSize:15];
    bl.textColor = gNotifyColor ?: UIColor.whiteColor;
    bl.numberOfLines = 2;
    bl.adjustsFontSizeToFitWidth = YES;
    bl.minimumScaleFactor = 0.6;
    bl.text = body;
    [wrap addSubview:bl];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeCustom];
    x.frame = CGRectMake(cw - 38, 4, 36, 36);   // 2.2.20: 触控区放大到 36×36, 之前 28 太小点不到
    [x setTitle:@"✕" forState:UIControlStateNormal];
    [x setTitleColor:[UIColor colorWithWhite:0.7 alpha:1] forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    DIPreviewCloser *closer = [DIPreviewCloser new];
    closer.target = wrap;
    objc_setAssociatedObject(wrap, &kCloserKey, closer, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // 持有, 否则会被释放
    [x addTarget:closer action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [wrap addSubview:x];

    objc_setAssociatedObject(win, &kPreviewWrap, wrap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    /* 2.6.11: 预览窗要上流光 → 打放行标记(diHostWantsFlow 只放行通知/歌词/预览) */
    objc_setAssociatedObject(wrap, "diPreviewAllow", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *ww = wrap;
    NSTimer *t = [NSTimer timerWithTimeInterval:0.06 repeats:YES block:^(NSTimer *_Nonnull tm) {
        UIView *w2 = ww; if (!w2) { [tm invalidate]; return; }
        UILabel *l2 = w2.subviews.firstObject;
        if (![l2 isKindOfClass:[UILabel class]]) return;
        l2.text = body;
        if (notifyColorOn) applyNotifyStyle(l2);
        else l2.textColor = gNotifyColor ?: UIColor.whiteColor;
    }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(wrap, &kPreviewTimer, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    /* 2.2.20: 固定 3 秒 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [t invalidate];
        UIView *w2 = ww; if (w2) [w2 removeFromSuperview];
    });
    DLog(@"文字预览: 浮层已弹出(3 秒, 小窗 %0.f×56), 右上角✕可提前关", cw);
}
static void diStartFlowTicker(void) {
    static NSTimer *t;
    if (t) return;
    t = [NSTimer timerWithTimeInterval:0.06 repeats:YES block:^(NSTimer *x) { diFlowTick(); }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}


#pragma mark - layoutSubviews hook（沿用已验证的防重复安装模式）

struct DIHook { Class cls; IMP original; };
static std::vector<DIHook> hooks;

/* 2.2.10: 锁屏通知宽度 —— 系统锁屏通知卡宽度由约束决定, 直接改 frame 会被下轮布局覆盖,
   因此改约束: 找到宽度相关约束把 constant 换成目标值; 无约束则改 frame 并居中。
   target = 父视图宽度 * 百分比。 */
/* 锁屏通知宽度(2.2.15 第三次重写):
   2.2.12 自建 width/centerX 约束 → 把系统 cell 拖进 Auto Layout, 崩。
   2.2.14 改成缩 layoutMargins → 不崩了, 但 cell 本身就是满宽(日志实测 401=父宽),
          缩 margin 对 platter 视觉无效 → 参数"没效果"。
   真正有效的做法(MrShi 同款): 系统锁屏通知是"列表容器 + 左边距"结构,
   全局的 horizontalInsetMargin 控制列表内容左右内缩。改它 → 整列卡片一起变窄,
   不需要碰任何 cell 的内部布局, 也就不会崩。
   兜底: 若拿不到列表容器, 才对 cell 做带容差的 frame 内缩(仅改 frame, 不加约束)。 */

/* ===== 锁屏宽度 2.2.23: 重写为"宽 + 高"双约束, 内容跟随重排 =====

   前几版为什么都不对(逐版复盘):
     2.2.19  用 CGAffineTransform 缩放 → 内容整体缩小, 字体也变小 ✗
     2.2.22  只改 platter.frame → 卡片变窄了(截图里看得到), 但 cell 内部子视图
             还按 401 宽度摆(缩略图/文字/进度条仍在原位) → "内容不跟随" ✗
     而"之前有一版生效"的那种, 是把 cell 自己变窄 → 但 cell 是满宽的容器,
             改它会让系统下轮布局拉回去 → 拉锯卡死(2.2.17/2.2.18)

   MrShi 的答案(从 dylib 属性表直接读出来的):
     它给 UIView 动态加了 innerwidth / borderwidth / ntwidthnum / ntshadow* 属性,
     实际写的是 platter 的「内宽」和「边框宽」—— 也就是只动 platter 自己,
     由系统自己的 layoutSubviews 把内容按新宽度重新摆一遍。
     这样内容天然跟随, 不需要我们算任何子视图坐标。

   本版做法(同样的思路, 但用显式 width + height 约束, 最稳):
     1) platter.translatesAutoresizingMaskIntoConstraints = NO
     2) 自建 width / height 两条约束(优先级 999, 可被系统 1000 顶掉但不冲突)
        - width  = 容器宽 * 百分比
        - height = 原始高 * (宽/原宽) 的比例(略收紧), 让卡片不要变高瘦
     3) 水平居中用 centerX 约束 → 不依赖任何父容器 frame
     4) 每次只在"目标值变了"的时候更新 constant, 绝不每帧写 → 不会拉锯
     5) 父容器宽度也一起看一眼: 容器本身比屏幕窄很多时(通知列表被内缩),
        以屏幕宽为百分比基准, 避免 81% 实际只有 76% 视觉差

   覆盖对象: 通知卡(PLPlatterView) + 播放器(nowPlaying 的 platter/背景) 共用同一套。 */

/* 找"卡片底板": 优先 platterView / summaryPlatterView / PLPlatterView */
static UIView *diFindPlatterForWidth(UIView *v) {
    NSString *cn = NSStringFromClass(v.class);
    if ([cn containsString:@"PlatterView"] || [cn isEqualToString:@"PLPlatterView"]
        || [cn isEqualToString:@"backgroundMaterialView"]) return v;
    for (UIView *sub in v.subviews) {
        UIView *r = diFindPlatterForWidth(sub);
        if (r) return r;
    }
    return nil;
}

static void diStylePlatter(UIView *platter);   /* 定义在后面 */

/* 通知卡 + 播放器宿主判定 */
static BOOL diIsNoticeOrPlayerView(NSString *cn) {
    static NSArray *keys = nil;
    if (!keys) keys = @[@"NCNotificationShortLookView", @"NCNotificationListCell",
                        @"NCNotificationListView", @"NCNotificationSummaryPlatterContainingView",
                        @"SBLockScreenNowPlayingView", @"NCNowPlayingView",
                        @"NPNowPlayingView", @"MTNowPlayingView", @"CSNotificationViewController",
                        @"CSAdjunctItemView"];   /* 2.2.30: 锁屏播放器宿主(Vide 源码确认) */
    for (NSString *k in keys) if ([cn isEqualToString:k]) return YES;
    return [cn containsString:@"NowPlaying"] || [cn containsString:@"AdjunctItem"];
}

/* 屏幕宽(锁屏列表容器常被系统内缩, 用它做百分比基准) */
static CGFloat diScreenWidth(void) {
    static CGFloat w;
    if (w < 100) w = [UIScreen mainScreen].bounds.size.width;
    return w > 100 ? w : 390;
}

/* ===== 2.2.27 锁屏宽度: 直接照 MrShi 的做法移植 =====

   MrShi 的 dylib 里这几个选择器/属性就是全部答案:
     innerwidth / setInnerwidth:      → 卡片"内宽"(float)
     ntwidthenable / ntwidthnum       → 开关 + 百分比
     ntborderwidth / ntbordercolor    → 边框
     ntshadow / ntshadowwidth / ntshadowcolor
     setBounds:  +  setBorderWidth:
     挂在 layoutSublayersOfLayer: 里

   核心: 它从不给外层加 Auto Layout 约束, 而是直接改 platter 的 **bounds**:
       platter.bounds = CGRectMake(0, 0, 目标宽, 原高)
   高度原样保留 → 按钮不会变形; 宽度变了系统自己 relayout 内部子视图 →
   内容跟着新宽度自适应, 不会外漏(之前用 width 约束硬压, 内部横向约束被挤爆才会外漏)。

   另外把"内宽"属性也写上去(innerwidth = 目标宽), 让 platter 自己的
   layoutSubviews 也按这个宽度重排, 双保险。 */

/* 安全写 KVC 属性: 类不支持就跳过, 绝不崩 */
static void diSetIfResponds(UIView *v, NSString *key, id val) {
    @try { if ([v respondsToSelector:NSSelectorFromString(key)]
              || [v valueForKey:key] != nil) [v setValue:val forKey:key]; }
    @catch (__unused NSException *e) {}
}

static CGFloat diTargetWidth(CGFloat hostW) {
    CGFloat base = MAX(hostW, diScreenWidth() * 0.62);
    CGFloat target = round(base * (lockWPercent / 100.0));
    if (target < 120) target = 120;
    if (target > hostW) target = hostW;
    return target;
}

/* ===== 2.2.29 内容收敛: 让 platter 内部所有子视图都待在卡片范围内 =====

   播放器外漏的真相: platter 的 bounds 被改窄了, 但 platter 内部那批子视图
   (进度条 / 播放键 / 封面) 是按"满宽 401"排的绝对 frame 或宽约束,
   系统并不会因为 bounds 变了就把它们重排 —— 于是右边一整块直接伸到卡片外。

   对策(两条一起做, 覆盖帧布局与 Auto Layout 两种写法):
     A. 帧布局子视图: 把 frame 等比收进 [0, W] 区间(不改高度, 不变形)
     B. 约束布局子视图: 给它的宽度/右边距约束打补丁 —— 优先改"常量型宽约束",
        其次追加 trailing <= 卡右 - 8 的软约束
   只在宽度真的变化时调用一次, 不做每帧扫描, 避免开销与抖动。 */

/* 子视图区间收敛: 只处理"明显越界"的, 轻微亚像素误差不碰 */
static void diClampChildrenToWidth(UIView *platter, CGFloat W) {
    if (!platter || W < 60) return;
    for (UIView *sub in platter.subviews) {
        if (sub.isHidden || sub.alpha < 0.01) continue;

        if (!sub.translatesAutoresizingMaskIntoConstraints) {
            /* ---- B. 约束布局 ---- */
            BOOL patched = NO;
            for (NSLayoutConstraint *c in platter.constraints) {
                if (c.firstItem != sub) continue;
                /* 常量型宽度约束(比如 progressBar width = 353) → 按比例缩到卡内 */
                if (c.firstAttribute == NSLayoutAttributeWidth && c.secondItem == nil) {
                    CGFloat maxW = W - 16;                 /* 左右各留 8 */
                    if (c.constant > maxW) { c.constant = maxW; patched = YES; }
                }
                /* 中心固定在父中心 → 保持, 不用动 */
            }
            /* 补一条"不许超出右边"的软约束, 兜住用 leading+width 排布的控件 */
            if (!patched) {
                BOOL hasTrail = NO;
                for (NSLayoutConstraint *c in platter.constraints) {
                    if (c.firstItem == sub && c.firstAttribute == NSLayoutAttributeTrailing) { hasTrail = YES; break; }
                }
                if (!hasTrail) {
                    NSLayoutConstraint *t = [sub.trailingAnchor constraintLessThanOrEqualToAnchor:platter.trailingAnchor constant:-6];
                    t.priority = UILayoutPriorityDefaultHigh;    /* 750: 不跟内部约束硬顶 */
                    t.active = YES;
                }
            }
            continue;
        }

        /* ---- A. 帧布局 ---- */
        CGRect f = sub.frame;
        CGFloat left = f.origin.x, right = f.origin.x + f.size.width;
        if (right <= W + 0.5 && left >= -0.5) continue;     /* 已经在卡内 */

        if (f.size.width > W) {
            /* 比卡片还宽(整条进度条那种): 按卡片宽度等比压窄, 并居中 */
            f.size.width = W - 12;
            f.origin.x = 6;
        } else {
            /* 只是偏出去了: 平移回来, 不压缩 */
            if (right > W) f.origin.x = W - f.size.width - 6;
            if (f.origin.x < 6 && f.size.width < W - 12) f.origin.x = 6;
        }
        if (f.size.width > 0 && f.size.height > 0) sub.frame = f;
    }
}

/* ===== 2.2.33 决定性改造: 用 MrShi 真正的做法 = horizontalInsetMargin =====

   彻底逆向 MrShi 1.0.0.2 的 hook 注册表(从 __text 0x72a8~0x7540 完整还原), 它一共只 hook 12 处:

     NCNotificationListSectionHeaderView      setTransform:
     NCNotificationListSupplementaryHostingView  layoutSubviews
     NCNotificationListView                  **horizontalInsetMargin**
     NCNotificationSummaryPlatterContainingView  layoutSubviews
     NCNotificationListCell                  **horizontalInsetMargin**
     NCNotificationListCell                  setTransform:
     CCUIModularControlCenterOverlayViewController  _beginPresentationAnimated:interactive:
     SparkCCMusicArtwork                     trackDidChange
     MRUControlCenterViewController          setState:
     SparkArtworkImageView                   layoutSublayersOfLayer:
     SBSystemApertureContainerView           layoutSubviews
     SBSystemApertureContainerView           _updateKeyLineStyle

   它**从来不给任何视图设 bounds/frame/约束**来改宽度。核心只有一句(反汇编 0x8ad4~0x8aec):

       d9 = 屏幕宽 ; d0 = ntwidthnum(百分比, float)
       fmul d0, d9, d0        ; 屏宽 * 百分比
       fsub d0, d8, d0        ; 屏宽 - 屏宽*百分比 = 屏宽*(1-百分比)
       fmul d8, d0, #0.5      ; ÷2  → 左右各一份
       → 返回 UIEdgeInsets(top, inset, bottom, inset)

   也就是说: **它只是告诉系统"列表两边各留多少边距"**, 剩下的布局全交给系统自己做。
   系统按这个边距把卡片排成目标宽度, 卡片内部的所有子视图(进度条/按钮/封面/文字)
   由系统自己的 layoutSubviews 重新算一遍 → **天然自适应, 不可能外漏, 也不需要裁剪**。

   这正是我们前面 8 个版本一直做错的地方:
     我们改 platter.frame / bounds → 卡片外壳变窄, 但内部子视图仍按旧宽度绝对定位
     → 右边一整块伸到卡外 → 只好 clipsToBounds 硬裁 → 裁掉底板/毛玻璃 → 背景消失。
     
   现在换成系统认可的入口, 一个 hook 解决宽度 + 内容自适应两件事。 */

/* UIEdgeInsets 返回值的函数指针类型(ARM64 上 32 字节结构体由调用方传缓冲区) */
typedef UIEdgeInsets (*DIInsetsMsgSend)(id, SEL);

/* 目标边距: 屏宽 * (1 - 百分比) / 2  —— 与 MrShi 完全一致的公式 */
static CGFloat diTargetInset(void) {
    if (!enabled) return -1;                       /* -1 表示"不接管, 返回原值" */
    if (!lockWOn) return -1;
    /* 2.2.39: 去掉 pct<0.40 的夹取。原来把最小值夹到 40% 会让用户拖到 50% 以下
       "感觉宽度不动"(滑杆读数是 50, 实际一直按 60 排) → 这就是"宽度被锁死"。
       现在滑杆范围 mn=50 已经保证不会太窄, 直接按真实百分比算。 */
    CGFloat pct = lockWPercent / 100.0;
    if (pct >= 0.999) return -1;                   /* 100% = 原样, 不接管 */
    if (pct < 0.30) pct = 0.30;
    CGFloat sw = diScreenWidth();
    CGFloat inset = sw * (1.0 - pct) * 0.5;
    if (inset < 0) inset = 0;
    return inset;
}

/* ===== 2.2.34: horizontalInsetMargin 的返回类型随系统版本不同 =====

   日志实证(116, 这台设备 iOS16): "NCNotificationListView horizontalInsetMargin 返回 8 字节"
   → 这台设备上是 `- (CGFloat)horizontalInsetMargin`, 单个左右边距值。

   而 MrShi 反汇编(0x88c8: stp q0,q0,[x23]; stp q0,q0,[x23,#0x20]) 是 32 字节,
   它在自己那台设备上拿到的是 `- (UIEdgeInsets)horizontalInsetMargin`。

   两种 ABI 完全不同:
     CGFloat      → 返回值在 d0
     UIEdgeInsets → 返回值缓冲区指针在 x0, 由调用方分配, 函数往里面写
   所以必须按实际签名分别生成 IMP, 否则会写坏调用方的栈。 */

static CGFloat    (*origInsetListViewF)(id, SEL);          /* CGFloat 版 */
static UIEdgeInsets (*origInsetListViewI)(id, SEL);        /* UIEdgeInsets 版 */

/* 2.2.60: iOS 17 起系统换了布局 —— 卡片原生就是 402x167, 系统自己的边距
   比我们算出来的目标边距还小, 于是 MAX(o, t) 永远返回 o, 自定义宽度完全失效
   (144 日志: 卡片 402x167 / m11=1.000, 说明系统根本没缩过, 一直是原宽)。

   分版本策略:
     · iOS 16 及更早: 系统边距偏大, 用 MAX 避免把列表反向放大(2.2.39 的结论)
     · iOS 17 及更新: 系统边距偏小/为 0, 直接用我们算的目标边距, 否则永远被系统值压住 */
static BOOL diIsIOS17OrLater(void) {
    static NSInteger maj = -1;
    if (maj < 0) {
        maj = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
        DLog(@"系统主版本: iOS %ld", (long)maj);
    }
    return maj >= 17;
}

static CGFloat hookInsetListViewF(id self, SEL _cmd) {
    CGFloat o = origInsetListViewF ? origInsetListViewF(self, _cmd) : 0;
    CGFloat t = diTargetInset();
    if (t < 0) return o;
    if (diIsIOS17OrLater()) return t;   /* iOS17+: 直接接管 */
    return MAX(o, t);
}

static UIEdgeInsets hookInsetListViewI(id self, SEL _cmd) {
    UIEdgeInsets o = origInsetListViewI ? origInsetListViewI(self, _cmd) : UIEdgeInsetsZero;
    CGFloat t = diTargetInset();
    if (t < 0) return o;
    if (diIsIOS17OrLater()) {
        return UIEdgeInsetsMake(o.top, t, o.bottom, t);
    }
    return UIEdgeInsetsMake(o.top, MAX(o.left, t), o.bottom, MAX(o.right, t));
}

/* 按真实返回类型装 hook: 8 字节 → CGFloat 版, 32 字节 → UIEdgeInsets 版 */
static BOOL diInstallInsetHookAuto(NSString *name, IMP impF, IMP impI) {
    Class c = NSClassFromString(name);
    if (!c) { DLog(@"%@ 类不存在", name); return NO; }
    SEL sel = NSSelectorFromString(@"horizontalInsetMargin");
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { DLog(@"%@ 没有 horizontalInsetMargin, 跳过", name); return NO; }
    NSMethodSignature *sig = [c instanceMethodSignatureForSelector:sel];
    NSUInteger sz = sig ? [sig methodReturnLength] : 0;
    IMP old = NULL;
    if (sz == 8) {
        MSHookMessageEx(c, sel, impF, &old);
        if (!old) return NO;
        origInsetListViewF = (CGFloat (*)(id, SEL))old;
        DLog(@"hook 安装成功: %@ (horizontalInsetMargin, CGFloat)", name);
        return YES;
    }
    if (sz == 32) {
        MSHookMessageEx(c, sel, impI, &old);
        if (!old) return NO;
        origInsetListViewI = (UIEdgeInsets (*)(id, SEL))old;
        DLog(@"hook 安装成功: %@ (horizontalInsetMargin, UIEdgeInsets)", name);
        return YES;
    }
    DLog(@"%@ horizontalInsetMargin 返回 %lu 字节, 类型未知, 跳过", name, (unsigned long)sz);
    return NO;
}

/* 对单个 platter: 改 bounds 宽度(高度不动) + 同步中心 + 写 innerwidth */
static BOOL diApplyBoundsWidth(UIView *platter, CGFloat targetW) {
    if (!platter || !platter.window || targetW < 80) return NO;

    CGRect b = platter.bounds;
    if (fabs(b.size.width - targetW) < 0.5) return NO;   /* 已经是目标宽, 不折腾 */

    CGRect fr = platter.frame;                         /* 先按当前 frame 推中心 */
    CGFloat cx = fr.origin.x + fr.size.width * 0.5;

    BOOL wasTranslate = platter.translatesAutoresizingMaskIntoConstraints;
    if (!wasTranslate) {
        /* 走 Auto Layout 的视图: bounds 会被下一次 layout 冲掉 →
           对它的宽度约束也跟着改, 但用最低优先级, 只做"倾向", 不和内部约束打架 */
        for (NSLayoutConstraint *c in platter.superview.constraints) {
            if (c.firstItem == platter && c.firstAttribute == NSLayoutAttributeWidth) {
                c.constant = targetW;
                break;
            }
        }
        for (NSLayoutConstraint *c in platter.constraints) {
            if (c.firstItem == platter && c.firstAttribute == NSLayoutAttributeWidth) {
                c.constant = targetW;
                break;
            }
        }
    }

    [CATransaction begin]; [CATransaction setDisableActions:YES];
    b.size.width = targetW;
    platter.bounds = b;
    [CATransaction commit];

    /* 中心保持: 帧布局视图直接把 frame 改到居中 */
    if (wasTranslate) {
        fr.size.width = targetW;
        fr.origin.x = cx - targetW * 0.5;
        platter.frame = fr;
    }

    /* MrShi 同款: 写内宽, 让 platter 自己的 layout 按新宽度重排内容 */
    diSetIfResponds(platter, @"innerwidth", @(targetW));
    [platter setNeedsLayout];

    /* 2.2.32 播放器(高卡 >100)内部收敛:
       A) 子容器比卡还宽 → 收进卡内并贴左
       B) 子视图的 clipsToBounds 打开, 溢出的像素直接切掉(视觉上绝不外漏)
       注意只裁"内部内容层", 绝不动 platter 自身 layer —— 那是背景消失的老坑。
       (上一版这段缩进错位/半途 return 掉了, 等于没执行, 现在独立成块) */
    if (b.size.height > 100) {
        for (UIView *sub in platter.subviews) {
            if (sub.isHidden) continue;
            CGRect f = sub.frame;
            CGFloat sw = f.size.width;
            /* 约束布局的容器: 直接改它的宽度约束 */
            if (!sub.translatesAutoresizingMaskIntoConstraints) {
                for (NSLayoutConstraint *c in platter.constraints) {
                    if (c.firstItem == sub && c.firstAttribute == NSLayoutAttributeWidth && !c.secondItem) {
                        if (c.constant > targetW) c.constant = targetW;
                    }
                }
                sub.clipsToBounds = YES;
                continue;
            }
            if (sw > targetW + 0.5) {
                f.size.width = targetW;
                f.origin.x = 0;                 /* 贴左, 与卡片左边缘对齐 */
                sub.frame = f;
                sub.clipsToBounds = YES;
                diClampChildrenToWidth(sub, targetW);
            } else if (sw > 1 && f.size.height > 1) {
                sub.clipsToBounds = YES;
            }
        }
    }

    /* 2.2.29: 系统不会因为 bounds 变窄就重排内部绝对布局 → 手动收敛一次 */
    diClampChildrenToWidth(platter, targetW);
    /* 内部若有自己的 layoutSubviews, 让它再跑一遍把结果坐实 */
    [platter layoutIfNeeded];
    diClampChildrenToWidth(platter, targetW);
    return YES;
}

/* 2.2.30 播放器专用: 缩宿主(CSAdjunctItemView), 让整棵子树(底板+进度条+按钮)
   被系统一起重排 —— 只缩 platter 时内容仍按宿主满宽排, 必然外漏。
   宿主在 UIStackView 里, 每轮 layout 校正一次(等效 MrShi 的 layoutSublayers 挂法)。 */
static BOOL diApplyWidthToHost(UIView *host, CGFloat targetW) {
    if (!host || !host.window || targetW < 80) return NO;
    CGRect b = host.bounds;
    if (fabs(b.size.width - targetW) < 0.5) return NO;

    /* 宿主自身常量型宽约束同步(stack 里可能是约束排布) */
    UIView *sup = host.superview;
    if (sup && !host.translatesAutoresizingMaskIntoConstraints) {
        for (NSLayoutConstraint *c in sup.constraints) {
            if (c.firstItem == host && c.firstAttribute == NSLayoutAttributeWidth && c.secondItem == nil) {
                c.constant = targetW;
                break;
            }
        }
    }

    CGRect fr = host.frame;
    CGFloat cx = fr.origin.x + fr.size.width * 0.5;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    b.size.width = targetW;
    host.bounds = b;
    [CATransaction commit];
    fr.size.width = targetW;
    fr.origin.x = cx - targetW * 0.5;
    host.frame = fr;

    diSetIfResponds(host, @"innerwidth", @(targetW));
    [host setNeedsLayout];
    return YES;
}

static void diApplyWidthToPlatter(UIView *platter) {
    if (!platter || !platter.window) return;
    UIView *host = platter.superview;
    if (!host) return;

    CGFloat hostW = host.bounds.size.width;
    if (hostW < 80) return;
    CGFloat target = diTargetWidth(hostW);

    /* 不做 mark 早退: 系统 layout 可能随时把 platter 重置回满宽,
       diApplyBoundsWidth 内部有"宽度没变就跳过"判断, 每轮都校正才稳 */
    BOOL changed = diApplyBoundsWidth(platter, target);

    if (lkShOn && lkShR > 0) diStylePlatter(platter);
    if (changed) [host setNeedsLayout];   /* 系统源码: 内容由宿主 layoutSubviews 按 platter bounds 重排 */

    static CFAbsoluteTime lastLog;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if (t - lastLog > 3) {
        lastLog = t;
        DLog(@"锁屏宽度(bounds): %@ %.0fx%.0f 容器 %.0f → 宽 %.0f (%.0f%%)",
             NSStringFromClass(platter.class), platter.bounds.size.width, platter.bounds.size.height,
             hostW, target, lockWPercent);
    }
}

/* ===== 2.2.39 锁屏播放器: 内容自适应宽度 =====

   复盘为什么 2.2.30~2.2.35 全部失败:

   118 日志铁证:
     NCNotificationListView  352x96   ← inset 生效了(目标边距 38.7)
     NCNotificationListCell  197x66   ← 只有 197?! 
     PLPlatterView           197x66

   cell 只有 197 宽, 而列表 352 宽、屏 430 宽。也就是说:
     · cell / platter 的 197 = 352 - 38.7*2 - 别的边距 —— inset 确实把整列缩到了 197
     · 上一版 diRealignPlayerPlatter 的判据是 "platter.bounds.w != cell.bounds.w",
       而这两个值都是 197 → 判据永远不成立 → 一次日志都没打出来 → 等于没执行

   所以问题从来不是"外框没跟上", 而是:
     platter 已经被系统压到 197, 但它内部的子视图(封面/标题/进度条/按钮)
     还在按上一次 401 的宽度摆位 → 右边整块伸到卡片外 = 用户说的"外漏"。

   正确做法(这次不再猜):
     1) 父宽可信: 取 platter.superview.bounds.width (197), 不再拿"屏幕宽 * 百分比"
        自己算 —— 自己算出来的 344 和系统真实排版 197 打架, 就会来回抖
     2) 内容重排: 给 platter 的每个内容子层做 "容器宽 = 父宽" 的收敛:
          · frame 布局的子视图: 宽度 > 可用宽 的, 收到可用宽, 并且贴左
          · 内有横向越界子的, 递归收敛一层
          · 约束布局的容器: 不改约束(会和系统打架), 只开 clipsToBounds
     3) 幂等: 只在宽度真的变化时动一次, 用关联对象记上次应用宽度, 不每帧写
     4) 绝不用 transform 缩放(会把字体/按钮一起缩小, 用户已明确否掉)

   这样 "宽度自定义" 由 horizontalInsetMargin 统一控制(通知+播放器一起),
   "内容自适应" 由这里按真实父宽收敛, 两件事互不干扰。 */

static char kDiAppliedW;    /* 上次应用的内容宽 */

/* 前置声明: diReflowChildren 在 diIsCardPlatter 定义之前用到它 */
static BOOL diIsCardPlatter(NSString *cn);

/* 打印 platter 内部结构(只对高卡, 每 5 秒一次), 用来定位真正外漏的那一层 */
static void diDumpTree(UIView *v, int depth, NSMutableString *out) {
    if (!v || depth > 5 || out.length > 3000) return;
    for (UIView *s in v.subviews) {
        CGRect f = s.frame;
        if (f.size.width < 2 || f.size.height < 2) continue;
        /* 2.2.40: 顺便打上 ta 和"视觉宽"(考虑 layer.transform), 
           这样场景宿主被缩放后, 日志里能直接看出视觉宽对不对 */
        CGFloat visW = f.size.width * s.layer.transform.m11;
        [out appendFormat:@"\n%@%@ %.0fx%.0f(视%.0f)@%.0f,%.0f ta=%d tf=%.2f",
         depth ? @"  " : @"", NSStringFromClass(s.class), f.size.width, f.size.height,
         visW, f.origin.x, f.origin.y,
         (int)s.translatesAutoresizingMaskIntoConstraints, s.layer.transform.m11];
        diDumpTree(s, depth + 1, out);
    }
}

/* ===== 2.2.39 跨进程场景宿主的等比适配 =====

   123 日志终于看清播放器内部:
     PLPlatterCustomContentView 288x167
       CSActivityItemContentView 288x167
       _UIScenePresentationView 401x167   ← 一直卡在 401

   `_UIScenePresentationView` 是 ActivityKit / MediaControls 的跨进程场景宿主,
   它内部由远端进程渲染, 外部改 frame 会被立刻写回(所以之前"改了跟没改一样")。
   它又是真正承载可点击控件的那一层 —— 裁剪掉 = 按钮点不到, 用户明确否掉了。

   对策(和前几版本质不同):
     不裁剪、不改它的 frame, 而是给它的 **layer 做等比缩放**:
       x = 目标宽 / 原生宽
       subview.layer.transform = scale(x, x)
     再把它自己的 frame 撑回"缩放后"的视觉矩形, 左上角对齐卡片左上角。
     因为缩放是作用在渲染层上的, 远端进程的视图树完全不受影响, 交互坐标
     由 UIKit 自动反算 —— 按钮照样点得到, 只是整体小了一号。

   只有"这一层是场景宿主且比卡片宽"时才做; 其它普通子视图仍走 frame 重排。 */

/* 识别跨进程场景宿主 */
static BOOL diIsSceneHost(UIView *v) {
    NSString *cn = NSStringFromClass(v.class);
    if ([cn containsString:@"ScenePresentationView"]) return YES;
    if ([cn containsString:@"SceneHost"]) return YES;
    if ([cn containsString:@"RemoteView"]) return YES;
    /* 注意: _UIPortalView 也在系统里大量出现(整套锁屏都是 portal),
       它同样由远端渲染, 但宽度本来就是满屏, 不在卡片里, 所以不纳入。 */
    return NO;
}

/* 让场景宿主按容器宽等比缩放显示

   2.2.40 两处关键修改(2.2.39 一行日志都没打出来, 就是这两处导致的):
     1) 原生宽不再"第一次就锁死"。125 日志显示宿主一直是 401 —— 但如果第一次
        抓到它时它还没被系统撑开(比如 0 或几十), 记录下来的伪原生值会让缩放比
        变成 NaN / 极大值, 后面全部算错。现在改成: 记录候选值, 只有连续两次读到
        同一个宽度且 >= 120 才认定它是原生宽。
     2) 日志去节流: 每变一次打一条, 同类最多重复 3 次。这样下次日志里一定能看到
        它到底有没有被调用、宿主类名是什么、算出来的缩放比是多少。 */
static void diFitSceneHost(UIView *host, CGFloat cardW, CGFloat *outVisH) {
    if (!host) return;
    NSString *hcn = NSStringFromClass(host.class);
    CGFloat bw = host.bounds.size.width;
    CGFloat bh = host.bounds.size.height;
    /* 2.2.41: 已经被我们缩过(transform != 1)时, bounds 读到的仍是原生值,
       但保险起见用 frame 兜一下 —— 有些系统会同步改 bounds。 */
    if (host.layer.transform.m11 < 0.999 && fabs(host.layer.transform.m11) > 0.01) {
        if (bw < 40) bw = host.frame.size.width;
    }

    /* ---- 原生宽探测 ----
       2.2.41: 阈值从 120 降到 40, 并且"连续两次读到同一个值"就认定。
       原因: 场景宿主刚插入时可能只有几十宽(还没撑开), 用 120 卡会把所有早期读数
       都当噪声丢掉, 后面它长到 401 时又因为"已有候选值"而不再认定 → 永远返回。 */
    NSNumber *natN = objc_getAssociatedObject(host, "di_natW");
    NSNumber *candN = objc_getAssociatedObject(host, "di_candW");
    if (!natN) {
        CGFloat cand = candN ? candN.doubleValue : -1;
        if (bw >= 40 && fabs(cand - bw) < 0.5) {
            natN = @(bw);
            objc_setAssociatedObject(host, "di_natW", natN, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            objc_setAssociatedObject(host, "di_candW", @(bw), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            /* 第一次见到: 无条件记一条, 保证日志里能看到它 */
            static int firstLog = 0;
            if (firstLog < 8) {
                firstLog++;
                DLog(@"场景宿主探宽: %@ %.0fx%.0f 卡片 %.0f (待二次确认)",
                     hcn, bw, bh, cardW);
            }
            return;
        }
    }

    CGFloat natW = natN.doubleValue;
    if (natW < 40) return;
    if (cardW < 40) return;

    CGFloat s = cardW / natW;
    if (s > 1.0) s = 1.0;            /* 卡片够宽就原样 */
    if (s < 0.30) s = 0.30;          /* 再小就没法点了 */

    /* 2.2.48: 用户指定回到 2.2.41 那一版 —— 纯等比缩放, 不做任何补偿放大。
       2.2.47 的「补偿放大」(s^0.45) 虽然字号变大, 但内容会撑出卡片, 显示不正常
       (截图可见进度条/按钮都顶到边)。2.2.41 的做法只有一条:
       按 s 等比缩到卡片宽, 贴左上角, 不平移、不放大 —— 布局完整、不溢出。
       字小一点但整体是对的, 这是用户认可的版本。 */
    BOOL changed = (fabs(host.layer.transform.m11 - s) > 0.001 ||
                    fabs(host.layer.position.x) > 0.5 ||
                    fabs(host.layer.position.y) > 0.5 ||
                    fabs(host.layer.anchorPoint.x) > 0.001);
    if (changed) {
        CATransform3D t = CATransform3DMakeScale(s, s, 1);
        t.m41 = 0; t.m42 = 0;
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        host.layer.transform = t;
        host.layer.anchorPoint = CGPointMake(0, 0);
        host.layer.position = CGPointMake(0, 0);
        [CATransaction commit];
    }
    host.clipsToBounds = NO;         /* 不裁: 裁了就点不到了(用户明确否过) */

    /* 视觉高 = 原生高 × s */
    if (outVisH) *outVisH = bh * s;

    static int fitLog = 0;
    if (fitLog < 40 && (changed || fitLog < 3)) {
        fitLog++;
        DLog(@"场景宿主等比适配: %@ 原生 %.0fx%.0f → 缩放 %.3f 视觉高 %.0f (卡片 %.0f) changed=%d",
             hcn, natW, bh, s, bh * s, cardW, (int)changed);
    }
}

/* 内容收敛: 把 v 的直接子视图按 W 重新排 —— 不裁剪、不缩放, 只"重新摆位"。

   为什么不用裁剪: 用户要的是"里面的东西跟随宽度显示", 裁掉等于看不见。
   为什么不用 transform: 字体/按钮会一起变小(用户明确否掉)。
   正确做法(MrShi 的 innerwidth 思路的显式实现):
     · 原本是"满宽铺开"的子层(宽 ≈ 旧宽) → 改成新的满宽
     · 原本是"贴右边"的子层(右边界 ≈ 旧宽) → 右边界改成新右边界, 宽度不变
     · 原本居中且不超过新宽的 → 只重设中心, 宽度不变
     · 约束布局的层 → 不改(会和系统打架), 只记录诊断
   用"旧宽 → 新宽"的映射一次算完, 不会累积误差。 */


static void diReflowChildren(UIView *v, CGFloat oldW, CGFloat newW, int depth) {
    if (!v || newW < 40 || fabs(oldW - newW) < 1.0) return;
    if (oldW < 40) oldW = newW;
    for (UIView *sub in v.subviews) {
        if (sub.isHidden || sub.alpha < 0.01) continue;
        CGRect f = sub.frame;
        if (f.size.width < 2 || f.size.height < 2) continue;

        /* 2.2.39: 跨进程场景宿主(_UIScenePresentationView 等)不走 frame 重排,
           它的尺寸由远端进程写回, 改 frame 无效 —— 改成等比缩放的渲染适配。
           ★ 这一层 ta 通常是 1, 但也可能是 0, 所以必须在 ta 判断之前处理。 */
        if (diIsSceneHost(sub)) {
            diFitSceneHost(sub, newW, NULL);
            continue;
        }

        /* 2.2.40: 内层若还是 platter, 交给它自己的流程, 这里不碰 ——
           否则外层会把内层当"满宽子层"直接压成外层宽, 叠起来就缩了两次。 */
        if (diIsCardPlatter(NSStringFromClass(sub.class))) continue;

        /* 约束布局的子视图: 改 frame 会被算回去, 跳过 */
        if (!sub.translatesAutoresizingMaskIntoConstraints) continue;

        CGFloat l = f.origin.x, r = CGRectGetMaxX(f), w = f.size.width;

        BOOL wasFull  = (fabs(l) < 1.5 && w > oldW * 0.9);          /* 满宽铺开 */
        BOOL wasRight = (fabs(r - oldW) < 2.0 && w < oldW * 0.9);   /* 贴右边 */
        BOOL overflows = (r > newW + 1.0);                           /* 溢出到卡外 */

        CGRect nf = f;
        if (wasFull) {
            nf.origin.x = 0;
            nf.size.width = newW;
        } else if (wasRight) {
            nf.origin.x = newW - w;
            if (nf.origin.x < 0) { nf.origin.x = 0; nf.size.width = newW; }
        } else if (overflows) {
            /* 居中或左边距固定的: 保持左边距, 宽度收到不溢出 */
            if (l + w > newW) {
                CGFloat maxW = newW - l;
                if (maxW < 20) { nf.origin.x = 0; maxW = newW; }
                nf.size.width = maxW;
            }
        }

        if (!CGRectEqualToRect(nf, f)) {
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            sub.frame = nf;
            [CATransaction commit];
            /* 容器内部也跟着按比例调一层 */
            if (nf.size.width > 2 && fabs(nf.size.width - w) > 1.0) {
                diReflowChildren(sub, f.size.width, nf.size.width, depth + 1);
            }
        }
    }
}

/* 2.2.41: 无条件补缩放 —— 每次 diRealignPlayerPlatter 都跑, 不看宽度有没有变。

   为什么必须有这一段(2.2.39/2.2.40 都栽在这):
     diFitSceneHost 原来只在 diReflowChildren 里、且只在"父宽变化"时才被调到。
     但远端进程在播放器刷新内容 / 切歌 / 息屏回来时会重新渲染场景宿主,
     某些路径会顺带把 layer.transform 清掉 —— 此时卡片宽度没有变化,
     重排逻辑整段跳过, 缩放就再也没补回去, 回弹成 401 溢出。
     所以把"补缩放"单独抽出来, 每帧无条件执行(纯幂等, 设了也不亏)。 */
static CGFloat diReapplySceneFit(UIView *root, CGFloat cardW, int depth) {
    if (!root || depth > 6 || cardW < 40) return 0;
    CGFloat foundH = 0;
    for (UIView *sub in root.subviews) {
        if (sub.isHidden) continue;
        if (diIsSceneHost(sub)) {
            CGFloat vh = 0;
            diFitSceneHost(sub, cardW, &vh);
            if (vh > foundH) foundH = vh;
            continue;                    /* 场景宿主内部是远端画面, 不再往下钻 */
        }
        CGFloat vh = diReapplySceneFit(sub, cardW, depth + 1);
        if (vh > foundH) foundH = vh;
    }
    return foundH;
}

static void diRealignPlayerPlatter(UIView *platter) {
    if (!platter || !platter.window) return;

    /* ===== 2.2.40 关键分叉: 通知卡 vs 播放器卡 =====

       125 日志里 2.2.39 只有两条重排, 都是:
         播放器重排: 400 → 340 高66 (父 NCNotificationShortLookView)
         播放器重排: 400 → 340 高66 (父 NCNotificationShortLookView)
       也就是说: 它把**通知卡**当播放器处理了。
       通知卡内部是系统自己的约束布局(ta=0), diReflowChildren 一个都改不了,
       反而是那行日志在骗人 —— 看着"处理过了", 实际什么都没动。

       而真正的播放器那一次(21:59:42 / 22:00:23):
         NCNotificationListSupplementaryHostingView 340x167
           _UIScenePresentationView 401x167   ← 只有它是宽的
       直属于 platter 的子层(CSActivityItemContentView / 三个 UIView)都是 340, 完全正常。
       所以对播放器**不能去动 platter 自己的宽度**(会把卡片缩窄而内部不变),
       唯一要做的是让那个 401 的场景宿主缩到 340。 */
    NSString *pcn = NSStringFromClass(platter.class);
    BOOL isNotificationCard = [pcn containsString:@"Notification"];

    if (isNotificationCard) {
        /* 通知卡: 内层全部交给 horizontalInsetMargin + 系统布局, 这里只做"场景宿主适配"
           (个别系统会把通知卡的图标/附件也放到 scene 里), 以及诊断。 */
        NSNumber *prevN = objc_getAssociatedObject(platter, &kDiAppliedW);
        CGFloat wN = platter.bounds.size.width;
        if (prevN == nil || fabs(prevN.doubleValue - wN) >= 1.0) {
            objc_setAssociatedObject(platter, &kDiAppliedW, @(wN), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            diReflowChildren(platter, (prevN ? prevN.doubleValue : diScreenWidth() - 30.0), wN, 0);
        }
        /* 2.2.41: 通知卡里通常没有场景宿主, 但个别系统会把附件放进去; 无条件补一次 */
        diReapplySceneFit(platter, wN, 0);
        return;
    }

    CGFloat availW = platter.superview ? platter.superview.bounds.size.width : 0;
    if (availW < 60) availW = platter.bounds.size.width;
    if (availW < 60) return;

    CGFloat curW = platter.bounds.size.width;

    /* platter 自身比父还宽 → 按父宽收(高度不动) */
    CGRect b = platter.bounds;
    if (curW > availW + 1.0) {
        b.size.width = availW;
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        platter.bounds = b;
        [CATransaction commit];
        if (platter.translatesAutoresizingMaskIntoConstraints) {
            CGRect fr = platter.frame;
            fr.size.width = availW;
            fr.origin.x = 0;
            platter.frame = fr;
        }
        diSetIfResponds(platter, @"innerwidth", @(availW));
    }

    /* 只在"上一次看到的宽度"变化时才重排内容。
       注意: 旧宽不能用 platter.bounds 取(可能已经被系统改成新值了),
       要用关联对象记的"上一次处理的宽度"。
       2.2.39: 首次(还没有记录)也要跑一次 —— 否则进锁屏这一轮永远不重排,
       日志里就一条都不出来。旧宽按"满宽 401"估, 保证内容会从旧坐标收敛。 */
    CGFloat finalW = platter.bounds.size.width;
    NSNumber *prevW = objc_getAssociatedObject(platter, &kDiAppliedW);
    CGFloat oldW = prevW ? prevW.doubleValue : (diScreenWidth() - 30.0);
    BOOL forceFirst = (prevW == nil);

    if (forceFirst || fabs(oldW - finalW) >= 1.0) {
        objc_setAssociatedObject(platter, &kDiAppliedW, @(finalW), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [platter setNeedsLayout];
        [platter layoutIfNeeded];
        diReflowChildren(platter, oldW, finalW, 0);
        [platter setNeedsLayout];

        static CFAbsoluteTime lastR;
        CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
        if (t - lastR > 3) {
            lastR = t;
            NSMutableString *tree = [NSMutableString string];
            diDumpTree(platter, 0, tree);
            DLog(@"播放器重排: %.0f → %.0f 高%.0f (父 %@)%@", oldW, finalW,
                 platter.bounds.size.height,
                 platter.superview ? NSStringFromClass(platter.superview.class) : @"-", tree);
        }
    }

    /* 2.2.41 核心: 无论宽度变没变, 每次都把场景宿主的缩放补一遍。
       远端进程刷新内容会清掉 layer.transform, 只补"宽度变化那次"根本补不住。
       这里不节流: diFitSceneHost 内部会先比对 m11, 没被顶掉就只做一次浮点比较,
       开销等同于几次内存读, 比"漏补一帧导致回弹 401"划算得多。

       2.2.42: 返回值是"缩放后内容的视觉高"。等比缩放会把高度也一起缩,
       卡片还按原生 167 留着, 下面就会空一截 —— 用户反馈的"高度有点高"。
       这里把卡片高度收成 exactly 这个视觉高。 */
    CGFloat visH = diReapplySceneFit(platter, finalW, 0);

    /* ---- 2.2.42 高度自适应 ---- */
    if (visH > 40) {
        CGFloat curH = platter.bounds.size.height;
        /* 只在明显偏差时改, 避免每帧写 bounds 和系统打架(2.2.28~31 就栽在这) */
        if (fabs(curH - visH) > 1.5) {
            CGRect hb = platter.bounds;
            hb.size.height = visH;
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            platter.bounds = hb;
            if (platter.translatesAutoresizingMaskIntoConstraints) {
                CGRect fr = platter.frame;
                fr.size.height = visH;
                platter.frame = fr;
            }
            [CATransaction commit];

            static CFAbsoluteTime lastH;
            CFAbsoluteTime th = CFAbsoluteTimeGetCurrent();
            if (th - lastH > 2.0) {
                lastH = th;
                DLog(@"播放器高度自适应: %.0f → %.0f (宽 %.0f 缩放后视觉高)", curH, visH, finalW);
            }
        }
    }

    /* 每 2 秒打一条"当前实际缩放状态", 用来看 transform 有没有被顶掉。
       m11 就是当前缩放比, 要和 diDumpTree 里的"视XXX"对上才算真生效。
       2.2.42: 找不到宿主就静默 —— 通知卡本来就没有场景宿主, 之前刷了一屏
       "宿主(未找到) ❌" 全是噪音, 和真正的失败混在一起看不出来。 */
    {
        static CFAbsoluteTime lastS;
        CFAbsoluteTime now2 = CFAbsoluteTimeGetCurrent();
        if (now2 - lastS > 2.0) {
            lastS = now2;
            CGFloat m11 = 1.0;
            CGFloat natW = 0;
            UIView *host = nil;
            {
                NSMutableArray *stack = [NSMutableArray arrayWithObject:platter];
                while (stack.count && !host) {
                    UIView *v = stack.firstObject;
                    [stack removeObjectAtIndex:0];
                    for (UIView *s in v.subviews) {
                        if (diIsSceneHost(s)) { host = s; break; }
                        [stack addObject:s];
                    }
                }
            }
            if (host) {
                m11 = host.layer.transform.m11;
                NSNumber *nN = objc_getAssociatedObject(host, "di_natW");
                natW = nN ? nN.doubleValue : host.bounds.size.width;

                DLog(@"场景缩放状态: 卡片 %.0fx%.0f 宿主 %@ 原生 %.0f m11=%.3f 视觉宽 %.0f 应达 %.0f %@",
                     finalW, platter.bounds.size.height, NSStringFromClass(host.class),
                     natW, m11, natW * m11, finalW,
                     (fabs(natW * m11 - finalW) < 2.0) ? @"✅" : @"❌");
            }
            /* 通知卡等没有场景宿主的: 静默, 不刷 ❌ 噪音 */
        }
    }
}

/* 2.2.40: 是不是"锁屏上的卡片 platter"(通知卡 / 播放器卡)。
   之前只用 containsString:@"PlatterView", 结果把系统长按菜单的
   _UIContextMenuPlatterTransitionView 也吞进来了 —— 125 日志里那条
   "播放器重排: 400 → 74 高74 (父 _UIContextMenuPlatterTransitionView)"
   就是它, 把菜单内容缩成 74 宽, 用户看到的就是"布局还是这个样子"。
   这里改成白名单 + 黑名单双保险。 */
static BOOL diIsCardPlatter(NSString *cn) {
    if (cn.length == 0) return NO;
    /* 黑名单: 长按菜单 / 拖拽预览 / 剪裁辅助层, 名字里都带 Platter 但绝不是卡片 */
    static NSArray *deny = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        deny = @[@"ContextMenu", @"PlatterClipping", @"PlatterTransform",
                 @"PlatterTransition", @"DragPreview", @"PlatterHighlight",
                 @"PlatterShadow", @"Window"];
    });
    for (NSString *d in deny) if ([cn containsString:d]) return NO;

    if ([cn isEqualToString:@"PLPlatterView"]) return YES;
    if ([cn isEqualToString:@"PLPlatterCustomContentView"]) return NO;  /* 内层, 不处理 */
    if ([cn containsString:@"PlatterView"]) return YES;                 /* NCNotificationShortLookView 等 */
    return NO;
}

static void applyLockWidth(UIView *v) {
    if (!lockWOn || !v.window) return;
    if (!NSThread.isMainThread) return;
    NSString *cn = NSStringFromClass(v.class);

    static BOOL insetActive = NO;
    static BOOL insetChecked = NO;
    if (!insetChecked) {
        insetChecked = YES;
        insetActive = (origInsetListViewF != NULL || origInsetListViewI != NULL);
        DLog(@"宽度模式: inset=%@", insetActive ? @"生效(系统排版)" : @"未装(走兜底)");
    }

    /* 播放器 / 通知卡: 交给 diRealignPlayerPlatter 按真实父宽做内容收敛。
       2.2.40: 判据换成 diIsCardPlatter(白名单+黑名单), 不再吞长按菜单。 */
    if (diIsCardPlatter(cn)) {
        diRealignPlayerPlatter(v);
        return;
    }

    if (insetActive) return;    /* 通知链: 一切交给系统布局(MrShi 同款) */

    /* ---- 以下仅在 inset 不可用时作为兜底(老系统/方法不存在) ---- */

    BOOL isAdjunctHost = ([cn containsString:@"Adjunct"] && [cn containsString:@"View"]);
    if (isAdjunctHost && v.bounds.size.width > diScreenWidth() * 0.62 + 2) {
        CGFloat hw = diScreenWidth();
        CGFloat t = diTargetWidth(hw);
        if (diApplyWidthToHost(v, t)) {
            diClampChildrenToWidth(v, t);
            static CFAbsoluteTime lastA;
            CFAbsoluteTime tn = CFAbsoluteTimeGetCurrent();
            if (tn - lastA > 3) { lastA = tn; DLog(@"播放器宿主缩放: %@ %.0f→%.0f", cn, v.bounds.size.width, t); }
        }
        return;
    }

    if (diIsNoticeOrPlayerView(cn)) {
        if ([cn containsString:@"AdjunctItem"]) {
            CGFloat hw2 = v.superview ? v.superview.bounds.size.width : 0;
            if (hw2 < 80) hw2 = diScreenWidth();
            CGFloat t2 = diTargetWidth(hw2);
            if (diApplyWidthToHost(v, t2)) diClampChildrenToWidth(v, t2);
            return;
        }
        UIView *pl = diFindPlatterForWidth(v);
        if (pl) { diApplyWidthToPlatter(pl); return; }
    }

    /* 走到这里说明 diIsCardPlatter 已经 return 过了, 这段是历史兜底, 不再重复处理 */
}

/* ===== 锁屏卡片外观 2.2.23: 边框 / 阴影(背后) / 呼吸 ====

   上一版阴影"没效果"的两个原因:
     1) backer 用的是 platter.frame, 但那时 platter 的 frame 已是旧值(约束还没算);
        而且 backer 插在 superview 里, platter 一旦走约束布局, backer 就再也没对齐过。
     2) 只覆盖通知卡, 播放器(nowPlaying)走的不是 NCNotificationShortLookView 这条链,
        所以播放器永远拿不到阴影。
   本版:
     · backer 用 Auto Layout 跟着 platter 的 4 条边 → 卡片变宽变高它自动跟
     · backer 一定插在 platter 的 superview 里、位于 platter 之下
     · 范围扩到 nowPlaying 各个候选类, 通知/播放器共用同一套
     · 呼吸: 多色时让阴影颜色也一起流动(色相循环), 单色时只做不透明度/半径起伏 */

static char kLkPlatter;
static char kDiBoxShadowV;   /* 2.2.56: 卡片专用投影层(垫在背景下层, 与边框同几何) */

/* 2.2.55: 边框/阴影"跟随模块大小"的最终方案 —— 抄 MrShi / 系统自己的做法:
   不要在卡片上盖一层自己算几何的环(算错一个坐标就错位), 
   而是**直接给卡片真实轮廓层设 borderWidth + borderColor + cornerRadius**,
   阴影也直接设在这个层的 layer 上, 用它的 bounds 生成 shadowPath。
   系统用什么尺寸/圆角画背景, 边框和阴影就自动用同一套 —— 天然 100% 跟随。

   137/138 日志实证的关键点:
     · platter 本身是 MTMaterialView, cornerRadius = 0, 尺寸也常和视觉底板不一致
       (例: platter 275x76, PLPlatterCustomContentView 275x80)
     · 所以必须找"真正画底板的那一层", 在它身上加边框/阴影。 */
static UIView *diCardFace(UIView *platter) {
    if (!platter) return nil;
    UIView *best = nil;
    CGFloat bestA = 0;
    for (UIView *sub in platter.subviews) {
        NSString *cn = NSStringFromClass(sub.class);
        BOOL isFace = [cn isEqualToString:@"PLPlatterCustomContentView"]
                   || [cn containsString:@"SeamlessContentView"]
                   || [cn containsString:@"PlatterContentView"];
        if (!isFace) continue;
        CGFloat a = sub.bounds.size.width * sub.bounds.size.height;
        if (a > bestA) { bestA = a; best = sub; }
    }
    return best;
}

/* 卡片真实轮廓: 相对 platter 的 rect + 真实圆角。
   2.2.56 修「边框出现内圈」:
   之前为了"保险"取子层最大 cornerRadius, 结果 275x115 的播放器卡取到 80.0
   (远超半高 57), 圆角一超限, border 的内轮廓和背景轮廓就分叉 → 视觉上多出一圈线。
   现在只用轮廓层自己的 cornerRadius; 它取不到才按半高推胶囊, 且一律夹到 h/2 以内。 */
__attribute__((unused)) static CGRect diCardFaceRect(UIView *platter, CGFloat *outRadius) {
    if (outRadius) *outRadius = 0;
    if (!platter) return CGRectZero;
    UIView *face = diCardFace(platter);
    CGRect f = face ? [platter convertRect:face.frame fromView:face.superview] : CGRectZero;
    if (!face || f.size.width <= 2 || f.size.height <= 2) {
        face = platter;
        f = platter.bounds;
    }
    CGFloat r = face.layer.cornerRadius;
    CGFloat maxR = f.size.height * 0.5;
    if (r < 1) r = maxR;                 /* 取不到 → 按胶囊推 */
    if (r > maxR) r = maxR;              /* 绝不能超过半高, 否则内轮廓分叉 */
    if (outRadius) *outRadius = r;
    return f;
}

/* 找 platter(通知 / 播放器通用) */
static UIView *diFindPlatter(UIView *v) {
    NSString *cn = NSStringFromClass(v.class);
    if ([cn containsString:@"PlatterView"] || [cn isEqualToString:@"PLPlatterView"]
        || [cn isEqualToString:@"backgroundMaterialView"]) return v;
    for (UIView *sub in v.subviews) {
        UIView *r = diFindPlatter(sub);
        if (r) return r;
    }
    return nil;
}

/* ===== 2.2.26: 样式完全回到 2.2.22 的写法(那时背景是好的) =====

   2.2.22 的做法很朴素, 但背景/底板一切正常:
     · 边框: 直接设 platter.layer.borderWidth/borderColor, 顺带把 cornerRadius 设成它原本的值
     · 阴影: 插一层与 platter.frame 同尺寸的 backer 在下面, 用它的 layer 画阴影
     · 全程不碰 platter.masksToBounds —— 这是"背景消失"的唯一开关
   2.2.23/2.2.24 我擅自加了 masksToBounds=YES、shadowPath=nil、边框 ring 层,
   反而把底板裁掉/盖掉。现在逐行退回, 只补两样你要的东西:
     1) 边框多色 → borderColor 关键帧轮流
     2) 阴影多色 → shadowColor 关键帧轮流 */

static char kShadowBacker;
static char kNeonRing;

/* ===== 2.2.49 霓虹动态描边 =====

   用户给的参考视频是「霓虹灯管」效果, 拆开看就三层:
     1) 一条有粗细的亮线, 贴着卡片轮廓走一圈
     2) 亮线外面一圈同色光晕(发光)
     3) 颜色沿轮廓流动, 冷暖交替循环

   实现方式:
     · 亮线: CAGradientLayer 画一个"只有边框"的环 —— 用两个子层做 mask:
       外面一个大矩形、里面一个小矩形挖掉中心, 剩下的就是等宽边框。
       渐变沿对角线铺(0,0)→(1,1), 配合 locations 动画就能让色带绕圈跑。
     · 光晕: 同一个渐变层再开 shadow, shadowPath 设成圆角矩形轮廓。
       因为它是"环", 所以发光位置正好贴着边框线, 不会糊到卡片内部。
     · 流动: 动画改 locations(色标位置) + startPoint/endPoint 缓移,
       让色带看起来在沿着四条边跑。

   关键: 这一层必须 userInteractionEnabled = NO 且放到最上层容器,
   只做视觉, 不参与命中测试, 不会影响拖动。 */

@interface DINeonRing : UIView
@property (nonatomic, strong) CAGradientLayer *grad;
@property (nonatomic, strong) CAShapeLayer *maskOuter;
@property (nonatomic, strong) CAShapeLayer *maskInner;
@property (nonatomic, assign) CGFloat lineWidth;
@property (nonatomic, assign) CGFloat cornerR;
@end

@implementation DINeonRing
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        _grad = [CAGradientLayer layer];
        _grad.startPoint = CGPointMake(0, 0);
        _grad.endPoint = CGPointMake(1, 1);
        _grad.type = kCAGradientLayerAxial;

        _maskOuter = [CAShapeLayer layer];
        _maskOuter.fillColor = [UIColor blackColor].CGColor;
        _maskOuter.fillRule = kCAFillRuleEvenOdd;
        _maskInner = [CAShapeLayer layer];
        _maskInner.fillColor = [UIColor blackColor].CGColor;
        _maskInner.fillRule = kCAFillRuleEvenOdd;
        [_maskOuter addSublayer:_maskInner];
        _grad.mask = _maskOuter;

        [self.layer addSublayer:_grad];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.grad.frame = self.bounds;
    /* 2.2.50: 旋转动画以图层中心为轴, frame 变了要同步 position, 否则会绕偏 */
    self.grad.anchorPoint = CGPointMake(0.5, 0.5);
    self.grad.position = CGPointMake(self.bounds.size.width * 0.5,
                                     self.bounds.size.height * 0.5);
    /* 2.2.53 修「边框偏了、没覆盖住卡片」:
       旧代码把环整体 inset lw/2 再画, 环的**外沿**落在 bounds 内 lw/2 处 ——
       宽度小时(275 宽 / 76 高)这点内缩肉眼就能看出"边框缩在里面, 四角没贴住卡片"。
       正确做法: 外沿**正好压在卡片边界上**(inset = 0), 线从边界往里长 lw。
         外框 = bounds(不缩)
         内框 = bounds 内缩 lw
       圆角半径按真实卡片圆角传进来, 这样四个角严格重合。 */
    CGFloat lw = self.lineWidth > 0 ? self.lineWidth : 2.0;
    CGRect outerRect = self.bounds;
    CGFloat cr = MAX(0, self.cornerR);
    UIBezierPath *outer = [UIBezierPath bezierPathWithRoundedRect:outerRect cornerRadius:cr];
    CGRect innerRect = CGRectInset(outerRect, lw, lw);
    UIBezierPath *innerP = [UIBezierPath bezierPathWithRoundedRect:innerRect
                                                       cornerRadius:MAX(0, cr - lw)];
    /* 外框路径 + 内框路径, evenOdd 挖空中心 → 得到等宽边框 */
    UIBezierPath *ring = [UIBezierPath bezierPath];
    [ring appendPath:outer];
    [ring appendPath:innerP];
    ring.usesEvenOddFillRule = YES;
    self.maskOuter.path = ring.CGPath;
    self.maskOuter.frame = self.bounds;
    self.maskInner.path = NULL;
    [CATransaction commit];
}
@end


/* ===== 2.2.58: 边框 + 阴影统一用「独立轮廓层」—— 照抄 MrShi 的手法 =====

   反汇编 MrShi 的 prefs 二进制, 它的参数是:
       borderwidth   / bordercolor     外框(岛外轮廓) 宽度 / 颜色
       innerwidth    / innercolor      内框(贴卡片)    宽度 / 颜色
       borderscale                     外框相对缩放
       ntshadowwidth / ntshadowcolor   阴影半径 / 颜色
   UI 文案原文:「灵动岛外框」「自定义灵动岛外框」「外框宽度」「外框颜色」
              「灵动岛内框」「增加内框宽度」「内框宽度」「内框颜色」
              「自定通知阴影」「阴影半径」「阴影颜色」

   **关键手法**: 它不往系统视图的 layer 上直接设 border —— 因为
   系统卡片的 geometry 有两套坐标系(platter 275x76 vs 内容层 275x80 @0,26),
   直接设 border 时 borderWidth 用 platter 的 bounds, 圆角却要取内容层的,
   两边对不上 → 边框直角 / 阴影错位(140/141 连续两版的问题就出在这里)。

   MrShi 的做法是: **自己建一个 CAShapeLayer 当"轮廓层"**,
   路径 = 卡片真实 frame 的圆角矩形(自己算, 唯一一套几何),
   然后这个轮廓层同时承担 border 和 shadow。这样:
     · 圆角、位置、尺寸全部来自同一条 path → 不可能错位
     · 阴影用同一个 path 当 shadowPath → 从边框外沿均匀向外散开
     · 轮廓层只画线(fillColor = clear), 不遮挡背景和内容 */

@interface DIContourLayer : CAShapeLayer
@end
@implementation DIContourLayer
- (instancetype)init {
    if ((self = [super init])) {
        self.fillColor = UIColor.clearColor.CGColor;
        self.masksToBounds = NO;
        self.allowsGroupOpacity = NO;
        self.contentsScale = UIScreen.mainScreen.scale;
    }
    return self;
}
@end

/* 轮廓层缓存: 每个 platter 一个 */
static char kDiContour;

/* 2.2.59: 彻底不做坐标系换算。

   142 日志实证:
     platter bounds = 301x125, frame = @0,21   ← 尺寸和偏移是两回事
     face(PLatterCustomContentView) frame = @0,0 301x125
   把 face.frame 用 convertRect 换进 platter 坐标系 → 得到 @0,-21 之类,
   再拿它当轮廓层 frame, 于是轮廓整体上移/下移 21pt, 而且尺寸被算错,
   画出来的就是「偏出去一圈直角框」。

   正确做法: 轮廓层**直接挂在 platter.layer 上, frame 用 platter.bounds**。
   这样它和卡片背景是同一套坐标、同一套尺寸, 天然 100% 重合;
   圆角只用 face 的 cornerRadius(纯标量, 不涉及坐标), 取不到就按半高(胶囊)。
   尺寸跟随由 platter 自身的 bounds 保证 —— platter 变多大轮廓就多大。 */
__attribute__((unused)) static CGRect diContourRect(UIView *platter, CGFloat *outR) {
    CGRect b = platter.bounds;
    CGFloat h = b.size.height;
    CGFloat maxR = h * 0.5;
    CGFloat r = 0;

    /* 143 日志实证: 同一个 platter 收起时 301x66、展开后 301x125,
       而 face.layer.cornerRadius 一直是 33(收起态的半高)。
       若原样拿来用, 展开到 125 时半径 33 相对 125 高度就只有"一点点圆",
       视觉上就是**直角框** —— 这是"边框还是直角"的真正原因。

       正确判据: 系统卡片的圆角永远是"胶囊"(半径 = 半高)。
       所以只要当前 h 变了, 半径就必须跟着变成 h/2, 不能沿用缓存值。 */
    r = maxR;
    if (outR) *outR = r;
    return b;
}

/* ===== 2.2.66: 边框该套在哪个矩形上 =====

   151 反馈: "要么大就直角, 要么小那么多, 你要跟随自定义宽度自适应"。

   根因: 用了「自定义宽度」以后, 卡片的三层尺寸**不再一致**:
     platter(bounds)  = 系统按满宽/自定义宽摆的外框, 高度可能比视觉卡片高
     MTMaterialView   = 材质底, 尺寸可能比 platter 大(日志里见过 430x360 的)
     PLPlatterCustomContentView(face) = **真正画出来的那张卡片**

   我前几版一直用 platter.bounds 做边框矩形:
     · platter 比卡片大 → 边框画在外面一大圈(用户说的"大")
     · 且 platter 高度更大时圆角 h/2 也跟着变大, 看起来更方(用户说的"直角")
     · 反过来 face 比 platter 小时, 边框又缩得太小(用户说的"小那么多")

   正确做法: **以 face 为准**(它就是用户眼睛看到的那张卡片),
   在 platter 坐标系里取 face 的实际矩形(只做一次坐标系换算, 不做多余套娃),
   再把 face 自己的 cornerRadius 夹到 h/2 以内。取不到 face 才退回 platter.bounds。 */
static UIView *diBorderFace(UIView *platter) {
    UIView *face = diCardFace(platter);
    if (!face || face == platter) return nil;
    if (face.bounds.size.width < 40 || face.bounds.size.height < 16) return nil;
    return face;
}

/* ===== 2.2.67: 真正读出系统那层的长宽与圆角 =====

   152 日志最关键的一行:
     卡片轮廓: platter 301x160 | 视觉卡片 301x160 @0,0 圆角 80.0
   301 宽、160 高、圆角 80 = 半高。**半高圆角在 160 的高度上就是一个大胶囊**
   —— 用户看到的"半圆/厚半圆"就是这么来的。

   问题不是算错 h/2, 而是"卡片本来就不是胶囊":
     · 系统通知卡/播放器卡的圆角是固定值(常见 20~28), 不是 h/2
     · 只有当卡片是"灵动岛那种胶囊"时圆角才等于 h/2
   我前几版无条件用 h/2, 卡片一高就变成巨大半圆; 一旦回到小尺寸又像直角,
   所以用户每次看到的都是"要么半圆、要么直角、要么小一圈"。

   正解: **不再推算, 直接读系统那一层的真实圆角**。
   做法: 从 platter 往下逐层找"真正做圆角的那一层", 优先级:
     1) 类名含 MaterialView / BackgroundView 且 cornerRadius > 0(系统底板, 圆角就在这里)
     2) 带 mask 子层(mask 的 cornerRadius 就是裁剪圆角)
     3) cornerRadius 最大且 < 半高*1.05 的层
   找到后同时读出它的 bounds(真实长宽); 一个都读不到才退回 h/2。
   **每一帧重新读**, 因为自定义宽度会改尺寸, 圆角跟着系统一起变。 */

static NSString *gCornerSrc = @"none";
static NSString *diLastCornerSource(void) { return gCornerSrc ?: @"none"; }

/* 在 platter 层树里找"真实圆角 + 真实矩形"(platter 坐标系) */
static CGRect diSystemCardRect(UIView *platter, CGFloat *outR) {
    if (!platter) { if (outR) *outR = 0; return CGRectZero; }

    CALayer *bestL = nil;
    CGRect bestRect = CGRectZero;
    CGFloat bestR = 0;
    int bestScore = -1;

    /* BFS 遍历最多 120 层 */
    NSMutableArray<CALayer *> *q = [NSMutableArray arrayWithObject:platter.layer];
    int guard = 0;
    while (q.count && guard++ < 400) {
        CALayer *l = q.firstObject; [q removeObjectAtIndex:0];
        CGRect b = l.bounds;
        CGFloat r = l.cornerRadius;
        CGFloat h = b.size.height, w = b.size.width;
        CGFloat maxR = h * 0.5;
        NSString *cn = NSStringFromClass([l class]);
        BOOL isMask = (l.mask != nil);

        /* 圆角层的判定: 必须真的有尺寸、且圆角有效(0 < r <= 半高*1.05) */
        CGFloat effR = r;
        if (isMask && l.mask.cornerRadius > effR) effR = l.mask.cornerRadius;
        BOOL valid = (w > 60 && h > 16 && effR > 0.5 && effR <= maxR * 1.05);

        if (valid) {
            int score = 0;
            /* 1) 系统底板: 圆角就写在这层, 最可信 */
            if ([cn containsString:@"MaterialView"] || [cn containsString:@"BackgroundView"]
                || [cn containsString:@"VisualEffect"]) score = 100;
            /* 2) 带 mask 裁剪的层: mask 圆角 = 视觉圆角 */
            else if (isMask) score = 80;
            /* 3) 普通圆角层: 取圆角最大的那个 */
            else score = 50 + (int)(effR);

            /* 面积越大越接近"整张卡片" */
            if (score >= bestScore) {
                if (score >= 100) gCornerSrc = [NSString stringWithFormat:@"%@", cn];
                else if (isMask) gCornerSrc = @"mask";
                else gCornerSrc = [NSString stringWithFormat:@"r%@", cn];
                /* 同分时取面积大的 */
                if (score > bestScore
                    || (score == bestScore && w * h > bestRect.size.width * bestRect.size.height)) {
                    bestScore = score;
                    bestL = l;
                    bestRect = b;
                    bestR = effR;
                }
            }
        }
        for (CALayer *sub in l.sublayers) [q addObject:sub];
    }

    if (!bestL || bestRect.size.width < 60) {
        gCornerSrc = @"fallback";
        /* 一层都没读到 → 退回旧策略(胶囊), 至少不会越界 */
        UIView *face = diBorderFace(platter);
        if (face) {
            CGRect f = [platter convertRect:face.bounds fromView:face];
            CGFloat maxR = f.size.height * 0.5;
            CGFloat r = face.layer.cornerRadius;
            if (r < 1 || r > maxR) r = maxR;
            if (outR) *outR = r;
            return f;
        }
        CGRect bb = platter.bounds;
        if (outR) *outR = bb.size.height * 0.5;
        return bb;
    }

    /* 把这一层在窗口里的矩形换算回 platter 坐标系:
       用 layer 的绝对位置差算, 避免 convertRect 多层套娃 */
    CGPoint p0 = [bestL convertPoint:CGPointZero toLayer:platter.layer];
    CGRect rect = CGRectMake(p0.x, p0.y, bestRect.size.width, bestRect.size.height);

    /* 圆角夹到半高, 绝不超过, 否则 border 内轮廓会分叉出双线 */
    CGFloat maxR2 = rect.size.height * 0.5;
    if (bestR > maxR2) bestR = maxR2;
    if (bestR < 0.5) bestR = maxR2;
    if (outR) *outR = bestR;
    return rect;
}

/* ===== 2.2.66: 边框跑马灯(内置动态) =====

   参考视频拆帧: 霓虹灯管贴合外框, 灯管本身发光, 亮色光团沿边框循环跑圈。
   已用静态渲染验证观感(胶囊 + 外发光 + 亮芯)。

   ✓ 2.2.65 崩溃教训(放歌即进安全模式):
     1) `(__bridge CGColorRef)cols.firstObject` —— cols 里装的是 **CGColorRef**,
        不是 id, 用 __bridge 强转是未定义行为, shadowColor 拿到野指针 → SpringBoard 立刻崩。
        正确写法: 直接取 CGColorRef 值, 或走 UIColor.CGColor, 绝不做 bridge 强转。
     2) 动画层挂在 window 上, 但岛可能已经被系统回收, 每帧 updateSingleVideo
        仍会拿关联对象去操作 → 对已释放的 window 做 addSubview/bringSubviewToFront 会崩。
        正确写法: 全程弱引用 + 每次用前校验 superview/window 一致, 不一致就重建。
     3) CAShapeLayer 的 strokeColor/shadowColor 用 CAKeyframeAnimation 循环时,
        values 必须是 CGColorRef 数组, 不能混入 UIColor。

   实现: 三层 CAShapeLayer(外发光 / 灯管 / 跑动光团), 全部在 window 顶层浮层内,
   浮层比岛大 pad, 保证光晕不被裁。path 用岛实时 bounds 的胶囊, 随岛尺寸自适应。 */

@interface DIEdgeOverlay : UIView
@property (nonatomic, strong) CAShapeLayer *glow;
@property (nonatomic, strong) CAShapeLayer *ring;
@property (nonatomic, strong) CAShapeLayer *comet;
@end

@implementation DIEdgeOverlay
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;
        self.layer.masksToBounds = NO;
        _glow = [CAShapeLayer layer];
        _glow.fillColor = UIColor.clearColor.CGColor;
        _glow.lineCap = kCALineCapRound;
        [self.layer addSublayer:_glow];
        _ring = [CAShapeLayer layer];
        _ring.fillColor = UIColor.clearColor.CGColor;
        _ring.lineCap = kCALineCapRound;
        [self.layer addSublayer:_ring];
        _comet = [CAShapeLayer layer];
        _comet.fillColor = UIColor.clearColor.CGColor;
        _comet.lineCap = kCALineCapRound;
        [self.layer addSublayer:_comet];
    }
    return self;
}
/* ===== 2.2.67: 6 套流光风格 =====

   0 霓虹跑马灯  黄粉绿蓝紫青 循环, 外发光最重 (默认, 参考视频那种)
   1 幻彩流沙    柔和粉紫青, 光团慢速, 内敛
   2 电光青蓝    青蓝双色交替, 光团快, 锐利
   3 烈焰红橙    红橙黄渐变, 暖色, 光团大
   4 极光绿紫    绿紫青, 冷色, 呼吸感强
   5 白金星轨    纯白偏冷, 极细光, 高级感 */

typedef struct { CGFloat r, g, b; } DIRGB;

static NSArray *diStyleColors(int style, CGFloat *outDur, CGFloat *outGlow, CGFloat *outRingA) {
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:7];
    NSArray *raw = nil;
    CGFloat dur = 5.0, glow = 0.95, ringA = 0.55;
    switch (style) {
        case 1:  /* 幻彩流沙 */
            raw = @[@[@1.00,@0.55,@0.78], @[@0.85,@0.55,@1.00], @[@0.55,@0.75,@1.00],
                    @[@0.65,@1.00,@0.90], @[@1.00,@0.55,@0.78]];
            dur = 7.0; glow = 0.70; ringA = 0.45;
            break;
        case 2:  /* 电光青蓝 */
            raw = @[@[@0.10,@0.95,@1.00], @[@0.15,@0.55,@1.00], @[@0.55,@0.95,@1.00],
                    @[@0.10,@0.95,@1.00]];
            dur = 2.0; glow = 1.0; ringA = 0.60;
            break;
        case 3:  /* 烈焰红橙 */
            raw = @[@[@1.00,@0.20,@0.15], @[@1.00,@0.45,@0.10], @[@1.00,@0.80,@0.20],
                    @[@1.00,@0.20,@0.15]];
            dur = 3.2; glow = 1.0; ringA = 0.65;
            break;
        case 4:  /* 极光绿紫 */
            raw = @[@[@0.20,@1.00,@0.55], @[@0.45,@0.20,@1.00], @[@0.20,@0.85,@1.00],
                    @[@0.20,@1.00,@0.55]];
            dur = 6.0; glow = 0.85; ringA = 0.50;
            break;
        case 5:  /* 白金星轨 */
            raw = @[@[@1.00,@1.00,@1.00], @[@0.85,@0.90,@1.00], @[@1.00,@0.95,@0.85],
                    @[@1.00,@1.00,@1.00]];
            dur = 3.6; glow = 1.0; ringA = 0.75;
            break;
        default: /* 0 霓虹跑马灯 */
            raw = @[@[@1.00,@0.78,@0.10], @[@1.00,@0.16,@0.62], @[@0.20,@0.95,@0.35],
                    @[@0.10,@0.62,@1.00], @[@0.66,@0.20,@1.00], @[@0.10,@0.95,@0.95],
                    @[@1.00,@0.78,@0.10]];
            dur = 5.0; glow = 0.95; ringA = 0.55;
            break;
    }
    for (NSArray *c in raw) {
        UIColor *u = [UIColor colorWithRed:[c[0] doubleValue]
                                     green:[c[1] doubleValue]
                                      blue:[c[2] doubleValue] alpha:1.0];
        [arr addObject:(__bridge id)u.CGColor];
    }
    if (outDur) *outDur = dur;
    if (outGlow) *outGlow = glow;
    if (outRingA) *outRingA = ringA;
    return arr;
}

- (void)applyWidth:(CGFloat)lw path:(CGPathRef)path {
    /* 幂等: 线宽/风格没变就不重挂动画(每帧调这个, 重挂会让光团一直闪回起点) */
    static char kLastW, kLastS;
    NSNumber *prevW = objc_getAssociatedObject(self, &kLastW);
    NSNumber *prevS = objc_getAssociatedObject(self, &kLastS);
    BOOL same = prevW && fabs(prevW.doubleValue - lw) < 0.01
                && prevS && prevS.intValue == smallEdgeStyle
                && self.ring.path != NULL;
    if (same) return;
    objc_setAssociatedObject(self, &kLastW, @(lw), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kLastS, @(smallEdgeStyle), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.glow.lineWidth  = lw * 3.0;
    self.ring.lineWidth  = lw;
    self.comet.lineWidth = lw * 1.6;
    self.glow.path  = path;
    self.ring.path  = path;
    self.comet.path = path;
    [CATransaction commit];
    [self startIfNeeded];
}
- (void)startIfNeeded {
    CGFloat dur = 5.0, glow = 0.95, ringA = 0.55;
    NSArray *cols = diStyleColors(smallEdgeStyle, &dur, &glow, &ringA);
    CGColorRef c0 = (__bridge CGColorRef)cols.firstObject;

    self.glow.strokeColor = c0;
    self.glow.shadowColor = c0;
    self.glow.shadowOpacity = glow;
    self.glow.shadowRadius = (smallEdgeStyle == 5) ? 4.0 : 7.0;
    self.glow.shadowOffset = CGSizeZero;
    self.glow.opacity = ringA;

    self.ring.strokeColor = c0;
    self.ring.shadowColor = c0;
    self.ring.shadowOpacity = 1.0;
    self.ring.shadowRadius = (smallEdgeStyle == 5) ? 2.0 : 3.0;
    self.ring.shadowOffset = CGSizeZero;
    self.ring.opacity = 1.0;

    self.comet.strokeColor = UIColor.whiteColor.CGColor;
    self.comet.shadowColor = c0;
    self.comet.shadowOpacity = 1.0;
    self.comet.shadowRadius = (smallEdgeStyle == 3) ? 9.0 : 6.0;
    self.comet.shadowOffset = CGSizeZero;

    /* 风格/时长变了 → 全部重挂(先清再挂, 保证换风格立刻生效) */
    [self.glow removeAllAnimations];
    [self.ring removeAllAnimations];
    [self.comet removeAllAnimations];

    CAKeyframeAnimation *c1 = [CAKeyframeAnimation animationWithKeyPath:@"strokeColor"];
    c1.values = cols; c1.duration = dur; c1.repeatCount = HUGE_VALF;
    [self.glow addAnimation:c1 forKey:@"diGC"];
    CAKeyframeAnimation *s1 = [CAKeyframeAnimation animationWithKeyPath:@"shadowColor"];
    s1.values = cols; s1.duration = dur; s1.repeatCount = HUGE_VALF;
    [self.glow addAnimation:s1 forKey:@"diGS"];

    CAKeyframeAnimation *c2 = [CAKeyframeAnimation animationWithKeyPath:@"strokeColor"];
    c2.values = cols; c2.duration = dur; c2.repeatCount = HUGE_VALF;
    [self.ring addAnimation:c2 forKey:@"diRC"];
    CAKeyframeAnimation *s2 = [CAKeyframeAnimation animationWithKeyPath:@"shadowColor"];
    s2.values = cols; s2.duration = dur; s2.repeatCount = HUGE_VALF;
    [self.ring addAnimation:s2 forKey:@"diRS"];

    CGFloat runDur = (smallEdgeStyle == 2) ? 1.4 : (smallEdgeStyle == 3 ? 1.8 : 2.4);
    CAKeyframeAnimation *st = [CAKeyframeAnimation animationWithKeyPath:@"strokeStart"];
    st.values = @[@(-0.22), @1.0]; st.duration = runDur;
    st.repeatCount = HUGE_VALF; st.calculationMode = kCAAnimationLinear;
    [self.comet addAnimation:st forKey:@"diCS"];
    CAKeyframeAnimation *en = [CAKeyframeAnimation animationWithKeyPath:@"strokeEnd"];
    en.values = @[@0.0, @1.22]; en.duration = runDur;
    en.repeatCount = HUGE_VALF; en.calculationMode = kCAAnimationLinear;
    [self.comet addAnimation:en forKey:@"diCE"];
}
@end

static char kDiEdgeView;

/* 几何: 浮层跟随岛实时位置/尺寸, path 为岛本地 bounds 的胶囊 */
static void diEdgeGeometry(UIView *edge, UIView *island) {
    if (!edge || !island) return;
    UIView *win = island.window;
    if (!win || edge.superview != win) return;
    CGRect rect = [island convertRect:island.bounds toView:win];
    if (rect.size.width < 8 || rect.size.height < 8) return;

    CGFloat pad = MAX(5.0, smallEdgeW * 2.0);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    CGRect box = CGRectInset(rect, -pad, -pad);
    edge.bounds = CGRectMake(0, 0, box.size.width, box.size.height);
    edge.center = CGPointMake(CGRectGetMidX(box), CGRectGetMidY(box));

    DIEdgeOverlay *ov = [edge isKindOfClass:DIEdgeOverlay.class] ? (DIEdgeOverlay *)edge : nil;
    if (ov) {
        CGRect local = CGRectMake(pad, pad, rect.size.width, rect.size.height);
        CGFloat cr = local.size.height * 0.5;   /* 胶囊, 跟随岛高自适应 */
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:local cornerRadius:cr];
        CGFloat lw = smallEdgeW;
        if (lw < 1) lw = 1;
        [ov applyWidth:lw path:p.CGPath];
    }
    [CATransaction commit];
}

/* 岛内是否**真的在放歌曲**, 只有这种岛才挂流光。

   152 反馈: "其他界面也会显示, 你只要锁死是播放歌曲的小岛上显示"。

   之前判据太松: 岛里出现任何 CALayerHost / MediaControls / Waveform 都算,
   于是来电话、录音、其他 App 的媒体岛、甚至临时提示岛都会被挂上。

   现在收紧成三条**同时成立**:
     1) 岛是灵动岛容器(SBSystemApertureContainerView), 尺寸在胶囊范围(已在调用侧过滤)
     2) 岛内确实存在系统的音乐播放层: CALayerHost 且高度 > 300(音频层特征),
        或类名含 "NowPlaying"/"MediaControls" 且 NOT 含 "Rec"/"Record"/"Phone"/"Call"
     3) 排除非音乐岛: 音量岛 / 录音岛 / 通话岛 / 通知岛 直接否掉 */
static BOOL diIslandPlayingMedia(UIView *island) {
    if (!island) return NO;
    /* 先排除明显不是音乐岛的 */
    if (diIsVolumeIsland(island)) return NO;
    NSString *myCN = NSStringFromClass(island.class);
    if ([myCN containsString:@"Notification"]) return NO;

    if (diFindAudioLayer(island) != nil) return YES;   /* 音频层(高>300 的 CALayerHost) */
    if (mrQueryOK && musicPlaying) return YES;

    NSMutableArray<UIView *> *st = [NSMutableArray arrayWithObject:island];
    int g = 0;
    while (st.count && g++ < 300) {
        UIView *v = st.firstObject; [st removeObjectAtIndex:0];
        NSString *cn = NSStringFromClass(v.class);
        if ([cn containsString:@"Rec"] || [cn containsString:@"Record"]
            || [cn containsString:@"Phone"] || [cn containsString:@"Call"]
            || [cn containsString:@"Volume"] || [cn containsString:@"Camera"]) {
            return NO;   /* 录音/通话/音量/相机岛, 一律不挂 */
        }
        if ([cn containsString:@"NowPlaying"]) return YES;
        for (UIView *sub in v.subviews) [st addObject:sub];
    }
    return NO;
}

/* 挂/更新跑马灯浮层。全程幂等 + 弱校验, 绝不 assume 岛还活着 */
static void diApplyEdgeGlow(UIView *island) {
    if (!island || !island.window) return;
    UIView *win = island.window;
    DIEdgeOverlay *edge = objc_getAssociatedObject(island, &kDiEdgeView);
    /* 浮层若已被系统从 window 上摘掉, 关联里留着的是死对象, 先丢掉 */
    if (edge && edge.superview != win) {
        [edge removeFromSuperview];
        objc_setAssociatedObject(island, &kDiEdgeView, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        edge = nil;
    }
    BOOL want = smallEdgeOn && smallOn && island.bounds.size.width > 8
                && diIslandPlayingMedia(island);
    if (!want) {
        if (edge) { [edge removeFromSuperview];
                    objc_setAssociatedObject(island, &kDiEdgeView, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        return;
    }
    if (!edge) {
        DIEdgeOverlay *v = [[DIEdgeOverlay alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(island, &kDiEdgeView, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [win addSubview:v];
        static CFAbsoluteTime lastLog;
        CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
        if (t - lastLog > 3) {
            lastLog = t;
            DLog(@"边框跑马灯: 挂上 (岛 %.0fx%.0f 宽窄%.1f)",
                 island.bounds.size.width, island.bounds.size.height, smallEdgeW);
        }
        edge = v;
    }
    diEdgeGeometry(edge, island);
    [win bringSubviewToFront:edge];
}

/// 遍历所有窗口找灵动岛容器并按需挂跑马灯
static void diSyncEdgeGlowAll(void) {
    NSMutableArray<UIView *> *islands = [NSMutableArray array];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
            int guard = 0;
            while (stack.count && guard++ < 4000) {
                UIView *v = stack.firstObject;
                [stack removeObjectAtIndex:0];
                if ([NSStringFromClass(v.class) isEqualToString:@"SBSystemApertureContainerView"]) {
                    CGFloat bw = v.bounds.size.width, bh = v.bounds.size.height;
                    if (bw > 60 && bw < 260 && bh >= 18 && bh <= 70) [islands addObject:v];
                }
                for (UIView *sub in v.subviews) [stack addObject:sub];
            }
        }
    }
    for (UIView *isl in islands) diApplyEdgeGlow(isl);
}

static void diStylePlatter(UIView *platter) {
    if (!platter) return;
    /* 2.5.3: 2.3.2 的媒体卡跳过已移除(恢复原版 2.3.0)。 */

    [CATransaction begin]; [CATransaction setDisableActions:YES];

    /* 边框矩形 = **视觉卡片(face)** 在 platter 坐标系里的实际矩形;
       圆角 = face 自己的 cornerRadius(夹到半高), 跟随自定义宽高自适应。 */
    CGFloat br = 0;
    CGRect brect = diSystemCardRect(platter, &br);
    static char kLastLog;
    {
        NSString *key = [NSString stringWithFormat:@"%.0fx%.0f@%.0f,%.0f r%.0f",
                         brect.size.width, brect.size.height,
                         brect.origin.x, brect.origin.y, br];
        NSString *prev = objc_getAssociatedObject(platter, &kLastLog);
        if (!prev || ![prev isEqualToString:key]) {
            objc_setAssociatedObject(platter, &kLastLog, key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            DLog(@"卡片轮廓: platter %.0fx%.0f | 卡片 %.0fx%.0f @%.0f,%.0f 圆角 %.1f (来源:%@)",
                 platter.bounds.size.width, platter.bounds.size.height,
                 brect.size.width, brect.size.height,
                 brect.origin.x, brect.origin.y, br, diLastCornerSource());
        }
    }

    /* ===== 2.2.66: 边框/阴影仍然画在 platter.layer 上(2.2.59 的位置, 阴影正常),
       但矩形和圆角改成跟随**视觉卡片(face)**。

       为什么必须跟 face 而不是 platter.bounds:
         用了自定义宽度后 platter 的高度/位置常和实际卡片不一致
         (151 日志: platter 301x110 / 301x76 与卡片视觉高度对不上),
         拿 platter.bounds 画 → 边框要么套在外面一大圈(显得"大"),
         要么因为半高变大而显得"直角"。以 face 为准才能严丝合缝。 */
    UIView *faceView0 = diBorderFace(platter);
    CALayer *FL = platter.layer;

    if (lkBdOn && lkBdW > 0) {
        FL.cornerRadius = br;
        FL.masksToBounds = NO;
        FL.borderWidth = lkBdW;
        NSArray<UIColor *> *bcols = lkBdColors.count ? lkBdColors
                                 : (lkBdColor ? @[lkBdColor] : @[]);
        [FL removeAnimationForKey:@"diBdCycle"];
        if (bcols.count) {
            UIColor *c0 = bcols.firstObject;
            CGFloat rr=0, gg=0, bb=0, aa=1;
            if ([c0 getRed:&rr green:&gg blue:&bb alpha:&aa])
                c0 = [UIColor colorWithRed:rr green:gg blue:bb alpha:1.0];   /* 不透明 */
            FL.borderColor = c0.CGColor;
            if (bcols.count >= 2) {
                CAKeyframeAnimation *bc = diShadowCycle(bcols, 1.6);
                if (bc) { bc.keyPath = @"borderColor"; [FL addAnimation:bc forKey:@"diBdCycle"]; }
            }
        }
        /* 边框如果和 platter.bounds 不完全重合, 必须在 face 上再补一圈内衬,
           否则 platter 比卡片大时边框会悬在卡片外。这里用 face 自身的 border,
           宽度/颜色与主线一致, 这样两层完全重合, 视觉上就一条线。 */
        if (faceView0 && !CGRectEqualToRect(brect, platter.bounds)) {
            CALayer *FLf = faceView0.layer;
            FLf.cornerRadius = br;
            FLf.masksToBounds = NO;
            FLf.borderWidth = lkBdW;
            FLf.borderColor = FL.borderColor;
            [FLf removeAnimationForKey:@"diBdCycle"];
            if (bcols.count >= 2) {
                CAKeyframeAnimation *bc2 = diShadowCycle(bcols, 1.6);
                if (bc2) { bc2.keyPath = @"borderColor"; [FLf addAnimation:bc2 forKey:@"diBdCycle"]; }
            }
        }
    } else {
        FL.borderWidth = 0;
        [FL removeAnimationForKey:@"diBdCycle"];
        if (faceView0) { faceView0.layer.borderWidth = 0;
                         [faceView0.layer removeAnimationForKey:@"diBdCycle"]; }
    }

    if (lkShOn && lkShR > 0) {
        /* 阴影: opacity 1.0 / offset (0,0) / radius 用户值直传 (2.2.59 的口径),
           shadowPath 用视觉卡片的圆角矩形 —— 这样阴影正好从卡片边缘散出去。 */
        UIColor *sc = lkShColor ?: [UIColor colorWithRed:0.71 green:0.44 blue:0.89 alpha:1.0];
        CGFloat sr=0, sg=0, sb=0, sa=1;
        if ([sc getRed:&sr green:&sg blue:&sb alpha:&sa])
            sc = [UIColor colorWithRed:sr green:sg blue:sb alpha:1.0];
        FL.shadowColor = sc.CGColor;
        FL.shadowRadius = lkShR;
        FL.shadowOpacity = 1.0f;
        FL.shadowOffset = CGSizeZero;
        FL.masksToBounds = NO;
        FL.allowsGroupOpacity = NO;
        FL.shadowPath = [UIBezierPath bezierPathWithRoundedRect:brect cornerRadius:br].CGPath;
        [FL removeAnimationForKey:@"diBreath"];
        [FL removeAnimationForKey:@"diBreathC"];
        if (lkShColors.count >= 2) {
            CAKeyframeAnimation *ca = diShadowCycle(lkShColors, 1.6);
            if (ca) { ca.keyPath = @"shadowColor"; [FL addAnimation:ca forKey:@"diBreathC"]; }
        }
    } else {
        FL.shadowOpacity = 0;
        FL.shadowRadius = 0;
        FL.shadowPath = nil;
        [FL removeAnimationForKey:@"diBreath"];
        [FL removeAnimationForKey:@"diBreathC"];
    }
    /* DIContourLayer 子层不再使用, 清掉 */
    {
        DIContourLayer *oldC = objc_getAssociatedObject(platter, &kDiContour);
        if (oldC) { [oldC removeFromSuperlayer];
                    objc_setAssociatedObject(platter, &kDiContour, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    }

    [CATransaction commit];

    /* 旧背板 / 旧投影层 / 旧自绘环, 一律清掉(它们就是"多出来的一圈") */
    UIView *oldB = objc_getAssociatedObject(platter, &kShadowBacker);
    if (oldB) {
        [oldB removeFromSuperview];
        objc_setAssociatedObject(platter, &kShadowBacker, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *oldS = objc_getAssociatedObject(platter, &kDiBoxShadowV);
    if (oldS) {
        [oldS removeFromSuperview];
        objc_setAssociatedObject(platter, &kDiBoxShadowV, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    DINeonRing *ring = objc_getAssociatedObject(platter, &kNeonRing);
    if (ring) {
        [ring.layer removeAllAnimations];
        [ring removeFromSuperview];
        objc_setAssociatedObject(platter, &kNeonRing, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    /* ---- 阴影需要祖先别裁剪(否则左右被切掉, 只剩上下) ---- */
    {
        static char kRestoreClip;
        UIView *p = platter.superview;
        int depth = 0;
        while (p && depth++ < 6) {
            NSNumber *orig = objc_getAssociatedObject(p, &kRestoreClip);
            if (!orig) {
                objc_setAssociatedObject(p, &kRestoreClip,
                    @{@"v" : @(p.clipsToBounds), @"l" : @(p.layer.masksToBounds)},
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (p.clipsToBounds) p.clipsToBounds = NO;
            if (p.layer.masksToBounds) p.layer.masksToBounds = NO;
            p = p.superview;
        }
    }

    [CATransaction commit];
}



static void applyLockStyle(UIView *v) {
    if (!NSThread.isMainThread) return;
    if (!lkBdOn && !lkShOn) return;
    NSString *cn = NSStringFromClass(v.class);
    if (!diIsNoticeOrPlayerView(cn)) return;
    UIView *platter = diFindPlatter(v);
    if (!platter) return;
    objc_setAssociatedObject(v, &kLkPlatter, platter, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    diStylePlatter(platter);
}

/* 遍历窗口 */
static void diForEachWindow(void (^blk)(UIWindow *w)) {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) blk(w);
    }
}

/* 2.2.23: 遍历时对"已识别的卡片宿主"上样式; 同时兜底扫一遍裸露的 platter
   (播放器的宿主类名不一定在清单里, 但它的 platter 一定在视图树里) */
static void diRestyleWalk(UIView *root) {
    if (!root) return;
    NSString *cn = NSStringFromClass(root.class);
    if (diIsNoticeOrPlayerView(cn)) {
        UIView *pl = diFindPlatter(root);
        if (pl) diStylePlatter(pl);
    }
    for (UIView *sub in root.subviews) diRestyleWalk(sub);
}

/* 兜底: 直接把锁屏上所有 platter 都按"卡片"处理(播放器不走通知链, 靠这条) */
static void diRestyleAllPlatters(UIView *root) {
    if (!root) return;
    NSString *cn = NSStringFromClass(root.class);
    if (([cn containsString:@"PlatterView"] || [cn isEqualToString:@"PLPlatterView"])
        && root.window && root.bounds.size.width > 120) {
        diStylePlatter(root);
    }
    for (UIView *sub in root.subviews) diRestyleAllPlatters(sub);
}

/* 2.2.24 诊断: 锁屏上"大 platter"的类名与父链, 用来定位播放器到底挂在哪
   只每 8 秒记一次, 不刷日志 */
static void diDiagPlatters(UIView *root, NSMutableSet *seen) {
    if (!root) return;
    NSString *cn = NSStringFromClass(root.class);
    BOOL isPlatter = [cn containsString:@"PlatterView"] || [cn isEqualToString:@"PLPlatterView"]
                  || [cn containsString:@"MaterialView"] || [cn containsString:@"NowPlaying"];
    if (isPlatter && root.window) {
        CGSize b = root.bounds.size;
        if (b.width > 120 && b.height > 30) {
            static CFAbsoluteTime lastLog;
            CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
            if (t - lastLog > 8) {
                lastLog = t;
                NSMutableString *chain = [NSMutableString string];
                UIView *p = root.superview;
                for (int i = 0; p && i < 5; i++, p = p.superview) {
                    [chain appendFormat:@" ← %@(%.0fx%.0f)", NSStringFromClass(p.class), p.bounds.size.width, p.bounds.size.height];
                }
                DLog(@"[诊断] platter %@ %.0fx%.0f 父链:%@ translates=%d",
                     cn, b.width, b.height, chain, (int)root.translatesAutoresizingMaskIntoConstraints);
            }
        }
    }
    for (UIView *sub in root.subviews) diDiagPlatters(sub, seen);
}

static void diWidthWalk(UIView *root) {
    if (!root) return;
    applyLockWidth(root);
    for (UIView *sub in root.subviews) diWidthWalk(sub);
}

/* 2.2.31 诊断: 把"锁屏上所有大卡片"和"任何播放器相关视图"的完整父链打出来。
   前几版一直没命中播放器, 必须先把真实类名/层级看清楚。 */
static void diDiagTree(UIView *v, int depth, NSMutableString *out) {
    if (!v || depth > 5 || out.length > 3000) return;
    for (UIView *s0 in v.subviews) {
        CGSize b = s0.bounds.size;
        if (b.width < 100 || b.height < 20) { diDiagTree(s0, depth, out); continue; }
        NSString *cn = NSStringFromClass(s0.class);
        BOOL interesting = (b.height > 100)                     /* 播放器那种高卡 */
                        || [cn containsString:@"Platter"]
                        || [cn containsString:@"NowPlaying"]
                        || [cn containsString:@"Adjunct"]
                        || [cn containsString:@"Media"]
                        || [cn containsString:@"Artwork"];
        if (interesting) {
            NSMutableString *chain = [NSMutableString string];
            UIView *pp = s0.superview;
            for (int i = 0; pp && i < 4; i++, pp = pp.superview)
                [chain appendFormat:@" ← %@(%.0fx%.0f)", NSStringFromClass(pp.class),
                 pp.bounds.size.width, pp.bounds.size.height];
            [out appendFormat:@"\n%@%@(%.0fx%.0f)@%.0f,%.0f 父:%@",
             (depth ? @"    " : @""), cn, b.width, b.height,
             s0.frame.origin.x, s0.frame.origin.y, chain];
        }
        diDiagTree(s0, depth + 1, out);
    }
}

static void diDiagPlayer(UIView *root, int depth) {
    if (!root || depth > 3) return;
    static CFAbsoluteTime lastLog;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if (t - lastLog < 10) return;
    lastLog = t;
    NSMutableString *out = [NSMutableString stringWithString:@"[锁屏卡片树]"];
    diDiagTree(root, 0, out);
    if (out.length > 12) DLog(@"%@", out);
}

static void diRestyleAllLockPlatters(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ diRestyleAllLockPlatters(); }); return; }
    diForEachWindow(^(UIWindow *w){
        diRestyleWalk(w);
        diRestyleAllPlatters(w);
        diDiagPlatters(w, nil);
        diDiagPlayer(w, 0);
    });
}

static void layoutHook(UIView *self, SEL selector) {
    Class concrete = object_getClass(self);
    for (Class c = concrete; c; c = class_getSuperclass(c)) {
        BOOL found = NO;
        for (const DIHook &h : hooks)
            if (h.cls == c) { ((void(*)(id,SEL))h.original)(self, selector); found = YES; break; }
        if (found) break;
    }
    if (lockWOn) applyLockWidth(self); // 2.2.10: 锁屏通知宽度(先于 updateHost, 避免岛相关开销)
    applyLockStyle(self);              // 2.2.17: 锁屏通知边框/背景/阴影
    if (NSThread.isMainThread) { diInstallGeometryWatch(); updateHost(self); }
}

static void installKnownHosts(void);
/* 2.2.32: 播放器/卡片类清单 —— 既用于 hook 安装, 也用于布局时的"真实宿主"判定 */
static NSArray *kDiPlayerHostClasses = @[
    @"CSAdjunctItemView", @"CSAdjunctListItemView", @"CSAdjunctListView",
    @"SBAdjunctView", @"SBLockScreenAdjunctView",
    @"NCNotificationViewControllerView", @"PLPlatterView", @"PLExpandedPlatterView",
    @"SBNotificationLongLookView", @"NCNotificationLongLookView",
    @"NCNotificationShortLookView", @"MediaControlsBackgroundView",
];

static BOOL install(NSString *name) {
    Class c = NSClassFromString(name); if (!c) return NO;
    for (const DIHook &h : hooks) if (h.cls == c) return YES;
    if (![c isSubclassOfClass:[UIView class]]) return NO;
    // 不 hook 继承链两侧, 避免重复调用
    for (const DIHook &h : hooks) {
        for (Class p = class_getSuperclass(c); p; p = class_getSuperclass(p)) if (p == h.cls) return YES;
        for (Class p = class_getSuperclass(h.cls); p; p = class_getSuperclass(p)) if (p == c) return YES;
    }
    Method m = class_getInstanceMethod(c, @selector(layoutSubviews));
    if (!m || method_getNumberOfArguments(m) != 2) return NO;
    char *ret = method_copyReturnType(m); BOOL ok = ret && !strcmp(ret, "v"); free(ret);
    if (!ok) return NO;
    IMP old = NULL;
    MSHookMessageEx(c, @selector(layoutSubviews), (IMP)layoutHook, &old);
    if (old) { hooks.push_back({c, old}); DLog(@"hook 安装成功: %@ (layoutSubviews)", name); return YES; }
    return NO;
}

static void installKnownHosts(void) {
    install(@"SAUIElementView");
    /* 2.2.10: 锁屏通知宽度 —— 锁屏通知卡(short look)与通知列表容器都按 layoutSubviews 调宽度 */
    install(@"NCNotificationShortLookView");
    install(@"NCNotificationListCell");
    install(@"NCNotificationListView");
    /* 2.2.17: 锁屏播放器跟随机缩放(候选类, 不存在会静默跳过) */
    install(@"SBLockScreenNowPlayingView");
    install(@"NCNowPlayingView");
    install(@"NPNowPlayingView");
    install(@"MTNowPlayingView");
    /* 2.2.32 关键: 播放器永远改不动, 是因为这些类一个都没被 hook ——
       播放器不在通知链上, 不会触发任何 layoutHook, 只能等 1 秒 tick 走路径 B;
       而路径 B 扫到的往往只是"内容 platter", 广度 401 的宿主没人改。
       这里把已知播放器/宿主/卡片类全量装上 (2.2.30 只给偏好清单加了名字, 忘了 install)。 */
    for (NSString *n in kDiPlayerHostClasses) install(n);

    /* 2.2.34 决定性: 照 MrShi 的 hook 表装 horizontalInsetMargin —— 这是唯一能让
       "宽度变窄 + 内容自适应"同时成立的入口, 系统自己排, 不需要裁剪。 */
    static BOOL insetInstalled = NO;
    if (!insetInstalled) {
        BOOL a = diInstallInsetHookAuto(@"NCNotificationListView",
                                         (IMP)hookInsetListViewF, (IMP)hookInsetListViewI);
        /* ListCell 上多数系统没有这个方法, 有就一起装(它也用同一个 IMP 表) */
        BOOL b = diInstallInsetHookAuto(@"NCNotificationListCell",
                                         (IMP)hookInsetListViewF, (IMP)hookInsetListViewI);
        if (a || b) {
            insetInstalled = YES;
            DLog(@"2.2.44 inset 宽度模式: ListView=%@ ListCell=%@ 目标边距=%.1f",
                 a?@"是":@"否", b?@"是":@"否", diTargetInset());
        }
    }
}

#pragma mark - 状态刷新

static BOOL lastLoggedEnabled = -1;
static void refreshAll(void) {
    refreshPrefs();
    if (enabled != lastLoggedEnabled) { DLog(@"总开关状态: %@, 声音=永远关闭", enabled ? @"开" : @"关"); lastLoggedEnabled = enabled; }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]])
            for (UIWindow *w in ((UIWindowScene *)s).windows)
                dispatch_async(dispatch_get_main_queue(), ^{ updateSingleVideo(w); });
}

// 0.5 秒轮询: 刷新偏好缓存 + 维持视频层; displayLink 负责逐帧贴合
static void diForEachWindow(void (^blk)(UIWindow *w));
static void diWidthWalk(UIView *root);
static void diRestyleWalk(UIView *root);
static void visibilityTick(void) {
    refreshPrefs();
    static CFAbsoluteTime tMR; // CPU 优化: MediaRemote 查询 1秒一次(检测音乐停止够快)
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - tMR > 1.0) { tMR = now; queryMusicPlaying(); }
    /* 音量轮询(2.2.5): 这台 16.2 上 AVSystemController 通知收不到(2.2.3/2.2.4 两次验证), 改为直接读系统音量。
       每 0.5s tick 读一次 outputVolume(纯属性读取, 不激活音频会话), 数值变化 = 按了音量键 → 开 6 秒拦截窗口 */
    /* 2.3.1 功耗: 音量轮询从 0.5s 放宽到 1s(与 MediaRemote 查询同步节拍);
       音量键拦截窗口 6s 不变, 6 秒粒度足够, 唤醒次数减半 */
    {
        static float lastVol = -1;
        static CFAbsoluteTime tVol;
        if (now - tVol > 1.0) {
            tVol = now;
            float v = AVAudioSession.sharedInstance.outputVolume;
            if (lastVol >= 0 && fabsf(v - lastVol) > 0.0001f) {
                gVolumeUntil = now + 6.0;
                DLog(@"音量变化轮询捕获: %.2f→%.2f → 6秒窗口内非音乐岛不挂视频", lastVol, v);
            }
            lastVol = v;
        }
    }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]])
            for (UIWindow *w in ((UIWindowScene *)s).windows) updateSingleVideo(w);
    /* 2.2.11: 设置项实时生效 —— 不需要注销/重启 SpringBoard。
       每 0.5s 直接对当前所有岛宿主重新应用颜色/流光/通知判定, 设置页一改 0.5s 内可见。 */
    if (notifyColorOn || notifyBgOff) {
        for (UIView *h in hostTable) {
            if (!h.window || h.isHidden || h.bounds.size.width < 2) continue;
            applyNotifyStyle(h);
        }
    }

    /* 2.2.29: 锁屏卡片"自愈" —— 系统会随时重建/重排卡片(播放器切歌、通知刷新都会),
       重建后它按满宽重算, 内容和边框就又跑出去了。
       这里每 1 秒把所有锁屏窗口的宽度/样式重新校正一遍, 用户不用注销也能稳定。 */
    {
        static CFAbsoluteTime tLock;
        if (now - tLock > 1.0) {
            tLock = now;
            if (lockWOn) diForEachWindow(^(UIWindow *w){ diWidthWalk(w); });
            if (lkBdOn || lkShOn) diForEachWindow(^(UIWindow *w){ diRestyleWalk(w); });
        }
    }

    /* 2.2.32 诊断常驻: 每 8 秒打一次锁屏卡片树, 把播放器真实类名/层级/宽度落盘。
       之前挂在 diRestyleAllLockPlatters 里, 只有"设置改动"才触发 → 用户日志里一行都没有。 */
    {
        static CFAbsoluteTime tDiag;
        if (now - tDiag > 8.0) {
            tDiag = now;
            diForEachWindow(^(UIWindow *w){ diDiagPlatters(w, nil); diDiagPlayer(w, 0); });
        }
    }
}

/* 锁屏状态变化: 锁→全停(不再挂载/播放, 根治锁屏界面常亮); 解锁→恢复 */
static dispatch_source_t gTickTimer; // 0.5s 轮询: 锁屏期间挂起 → 锁屏/后台零 CPU 唤醒
static BOOL gTickSuspended = NO;
static void pauseAllUnderWindows(void) { // 立即暂停所有视频层/帧率动画层的 displayLink 与播放器(不等 miss 计数)
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
            while (stack.count) {
                UIView *v = stack.lastObject; [stack removeLastObject];
                for (UIView *sub in v.subviews) [stack addObject:sub];
                if ([v isKindOfClass:[DIVideoView class]]) {
                    DIVideoView *dv = (DIVideoView *)v;
                    dv.syncLink.paused = YES;
                    if (dv.player.timeControlStatus != AVPlayerTimeControlStatusPaused) [dv.player pause];
                } else if ([v isKindOfClass:[DIAnimView class]]) {
                    ((DIAnimView *)v).link.paused = YES;
                }
            }
        }
    }
}
/* 2.5.18: 横条 pill 登记表/logic 在文件后段, 锁屏状态回调(前面)要用 → 前置声明 */
static void diStylePillView(UIView *pill);
static void di_guardPillLayers(UIView *pill);
static void diEnsureSwipeWatcherInWindow(UIWindow *w);
extern NSHashTable *gBarPills;

static void applyLockState(BOOL locked) {
    if (locked == gLocked) return;
    gLocked = locked;
    if (locked) {
        /* 2.3.1/2.3.2: 锁屏不做任何 setActive —— 只暂停我们自己的播放器。
           会话类别保持 Ambient+MixWithOthers 不动, 让系统音频路由完全不受扰动。 */
        pauseAllUnderWindows(); // 立即停掉所有 displayLink/播放器: 锁屏零渲染零解码
        if (gTickTimer && !gTickSuspended) { dispatch_suspend(gTickTimer); gTickSuspended = YES; } // 挂起 0.5s 轮询: 锁屏期间零唤醒
    } else {
        if (gTickTimer && gTickSuspended) { dispatch_resume(gTickTimer); gTickSuspended = NO; } // 恢复轮询, 内部 wakeLayer 自愈各层
        setupAudioSession(); // 2.3.2: 解锁后重申一次类别(dispatch_once 幂等, 只为兜住系统被其他组件改写的极端情况)
    }
    DLog(@"锁屏状态: %@", locked ? @"已锁定 → 全部暂停" : @"已解锁 → 恢复");
    /* 2.5.18: 锁屏/解锁都会重建锁屏那套视图, 横条 pill 可能被换新实例。
       这里主动把已登记的横条重涂一遍, 并立即挂上全局滑动监听。 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool {
            for (UIView *p in [gBarPills allObjects]) {
                if (!p.window) continue;
                diStylePillView(p);
                di_guardPillLayers(p);
            }
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if (![s isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)s;
                for (UIWindow *w in ws.windows) {
                    if ([w isKindOfClass:NSClassFromString(@"SBHomeGrabberView")]) continue;
                    if (w.isKeyWindow || w.windowLevel >= UIWindowLevelNormal - 1)
                        diEnsureSwipeWatcherInWindow(w);
                }
            }
        }
    });
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]])
            for (UIWindow *w in ((UIWindowScene *)s).windows) updateSingleVideo(w);
    if (!locked) refreshAll();
}
static void lockStateChanged(CFNotificationCenterRef, void *, CFStringRef, const void *, CFDictionaryRef) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL locked = NO;
        Class c = NSClassFromString(@"SBLockStateController");
        SEL sh = NSSelectorFromString(@"sharedInstance");
        if (c && [c respondsToSelector:sh]) {
            id inst = ((id(*)(id, SEL))objc_msgSend)(c, sh);
            SEL gs = NSSelectorFromString(@"currentState");
            if (inst && [inst respondsToSelector:gs]) locked = (((long(*)(id, SEL))objc_msgSend)(inst, gs) != 0);
        }
        applyLockState(locked);
    });
}

static void prefsChanged(CFNotificationCenterRef, void *, CFStringRef, const void *, CFDictionaryRef) {
    gFramesDirty = YES; // 偏好变更(可能换了素材文件夹): 立即重扫
    DIMaskInvalidateCache();   /* 2.6.11: 设置页刚换了遮罩素材 → 立刻重新读图 */
            dispatch_async(dispatch_get_main_queue(), ^{
                refreshAll(); installKnownHosts();
        /* 2.2.10: 锁屏通知宽度变更后立即重排(不必等下次通知弹出) */
        if (lockWOn) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
                if ([s isKindOfClass:[UIWindowScene class]])
                    for (UIWindow *w in ((UIWindowScene *)s).windows)
                        for (UIView *v in w.subviews) [v setNeedsLayout];
        }
    });
}

/* 2.2.11: 颜色变更(取色页/面板/预览按钮) 通知 —— 立即刷新色表并重绘岛上文字 */
static void colorChanged(CFNotificationCenterRef, void *, CFStringRef, const void *, CFDictionaryRef) {
    dispatch_async(dispatch_get_main_queue(), ^{
        refreshPrefs();
        for (UIView *h in hostTable) {
            if (!h.window || h.isHidden || h.bounds.size.width < 2) continue;
            applyNotifyStyle(h);
        }
        /* 2.2.21: 实时重刷锁屏卡片外观 + 宽度(不用注销) */
        diRestyleAllLockPlatters();
        diForEachWindow(^(UIWindow *w){ diWidthWalk(w); });
    });
}

/* 预览: 设置页点"预览" → 屏幕上方弹一颗示范岛, 8~10 秒后自动消失 */
static void diShowPreview(void);
static void diPreviewNotify(CFNotificationCenterRef, void *, CFStringRef, const void *, CFDictionaryRef) {
    dispatch_async(dispatch_get_main_queue(), ^{ refreshPrefs(); diShowPreview(); });
}


/* ===== 2.5.0: 系统底栏横条(Home Indicator)自定义 =====

   2.5.5 重写(参考其他插件通用做法):
   iOS16 SpringBoard 的横条 = SBHomeGrabberView(宿主), 本体是它内部的
   _pillView(MTLumaDodgePillView, 类名含 "Pill" 不含 "Home/Indicator",
   之前纯扫描永远抓不到)。系统按背景明暗(luma)自动决定颜色和样式,
   直接改 backgroundColor 会被 _updateStyle 覆盖。

   改长短: hook SBHomeGrabberView 的 grabberFrameForBounds: —— 系统每次
   布局都调它拿横条 frame, 返回按百分比缩放(中心对齐)的 frame, 长稳。
   改颜色: 打开 ignoresLuminance(关掉系统自动换色)后设 pill 背景。 */

static double diHomeBarScaleW(CGFloat w) {
    double target = w * homeBarLen / 100.0;
    if (target < 8) target = 8;   /* 2.5.8: 支持低到 10% */
    return target;
}

/* ===== 2.5.6: 横条上色(单色/多色渐变/流光) =====

   坑位记录: 2.5.5 用 UIWindow 扫描找 SBHomeGrabberView, 结果抓不到(pill 挂在
   SBFloatingDockView / 独立 window 层, 且系统频繁重建)。
   本版改为: 在 grabberFrameForBounds: hook 里拿到 self(必是 SBHomeGrabberView),
   直接取 _pillView 上色 —— 每次布局必定命中, 不依赖任何扫描。

   三种模式:
     single  单色: pill 背景直接设色
     gradient 多色渐变: 盖一层 CAGradientLayer(水平, 等距分布)
     flow    流光: 渐变基础上用颜色 keyframe 动画让色带持续平移 */

/* ===== 2.5.18: 横屏"2 秒后彻底隐藏"状态 =====
   为什么前几版看不见隐藏: 判定写在 di_pillLayout 里, 而横条静止时系统不再调用
   layoutSubviews, 计时判断根本没有机会执行第 2 次 → gLandHidden 永远起不来。
   本版把计时改成由 0.06s 心跳(diBarFlowTick)主动推进, 与布局解耦。 */
static CFAbsoluteTime gLandEnter = -1;   /* -1 = 尚未起算(非横屏) */
static BOOL gLandHidden = NO;            /* 横屏 2 秒后 = YES, 滑动唤醒置回 NO */
static CGSize gLandLastSize = CGSizeZero; /* 2.5.19: 横屏形态变化(切应用/换场景)重新计时 */
static void diResetLandscapeHide(void) { gLandHidden = NO; gLandEnter = -1; }
static void diRevealBarNow(const char *why);   /* 2.5.23-2: 前置声明(心跳呼回检测用) */

/* 2.5.19: 隐藏状态下"最外层可见容器"的引用 —— 横条外层可能有不透明背景,
   只把横条自己 alpha 置 0 时残留一条实色, 所以连同一并压掉。 */
static void diApplyBarAlpha(UIView *pill, BOOL hide, BOOL hard);

/* 2.5.18: 方向判定 —— 多依据。横屏时主屏幕 bounds 一定被系统转成宽>高,
   而游戏/视频的全屏窗口界面方向常仍是竖屏值, 所以屏幕比例优先于场景方向。 */
static BOOL diLandscapeNow(void) {
    UIDeviceOrientation o = UIDevice.currentDevice.orientation;
    CGSize scr = [UIScreen mainScreen].bounds.size;
    BOOL raw;
    if (UIDeviceOrientationIsLandscape(o)) raw = YES;
    else if (scr.width > scr.height + 1.0) raw = YES;
    else if (scr.height > scr.width + 1.0) raw = NO;
    else {
        raw = NO;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)s;
            if (![ws respondsToSelector:@selector(interfaceOrientation)]) continue;
            UIInterfaceOrientation io = ws.interfaceOrientation;
            if (io == UIInterfaceOrientationLandscapeLeft || io == UIInterfaceOrientationLandscapeRight) { raw = YES; break; }
            if (io == UIInterfaceOrientationPortrait || io == UIInterfaceOrientationPortraitUpsideDown) { raw = NO; break; }
        }
    }
    /* 2.5.23-2: 0.8s 防抖 —— 186 日志显示方向瞬时值会抖动, 一抖就把 gLandHidden
       重置了("已隐藏=1 → 又变回 0"即此因)。原始读数与稳定值不一致需持续 0.8s 才翻转。 */
    static BOOL sStable = NO;
    static BOOL sHave = NO;
    static CFAbsoluteTime tFlip = 0;
    if (!sHave || raw == sStable) { sStable = raw; sHave = YES; tFlip = 0; return sStable; }
    if (tFlip == 0) tFlip = CFAbsoluteTimeGetCurrent();
    if (CFAbsoluteTimeGetCurrent() - tFlip > 0.8) { sStable = raw; tFlip = 0; }
    return sStable;
}

/* 2.5.18: 横条"要隐藏"的唯一判定入口(布局与心跳共用, 保证两边结论一致)
   2.5.19: 加入"横屏形态变化"检测 —— 用户期望的是隐藏后滑动显示, 再静置 2 秒又隐藏。
   切应用/进出游戏时横屏尺寸会变, 用尺寸变化作为"新一轮显示窗口"的起点。 */
static BOOL diLandHideActive(void) {
    /* 手势保护没开 = 不做横屏强制隐藏; 开了"隐藏底部横条"则走全场景隐藏 */
    if (!gestureProtectOn || homeBarHideOn) return NO;
    if (!diLandscapeNow()) { gLandEnter = -1; gLandHidden = NO; gLandLastSize = CGSizeZero; return NO; }
    CGSize scr = [UIScreen mainScreen].bounds.size;
    if (!CGSizeEqualToSize(scr, gLandLastSize)) {
        gLandLastSize = scr;
        gLandEnter = CFAbsoluteTimeGetCurrent();
        gLandHidden = NO;
    }
    if (gLandEnter < 0) gLandEnter = CFAbsoluteTimeGetCurrent();
    if (!gLandHidden && CFAbsoluteTimeGetCurrent() - gLandEnter > 2.0) {
        gLandHidden = YES;
        DLog(@"横条: 横屏静置 2 秒 → 彻底隐藏(滑动可唤回)");
    }
    return gLandHidden;
}

static char kGradLayerKey;

static NSArray<UIColor *> *diHomeBarPalette(void) {
    /* 2.5.6: 不做缓存 —— 改色后立刻生效(解析 6 位 HEX 开销极小) */
    NSMutableArray<UIColor *> *pal = [NSMutableArray array];
    NSString *hex = pString(@"homeBarHexes");
    if (!hex.length) hex = pString(@"homeBarHex");
    for (NSString *h in [hex componentsSeparatedByString:@","]) {
        NSString *s = [h stringByReplacingOccurrencesOfString:@"#" withString:@""];
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].uppercaseString;
        if (s.length == 6) {
            unsigned v = 0; NSScanner *sc = [NSScanner scannerWithString:s];
            if ([sc scanHexInt:&v]) {
                [pal addObject:[UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                                               green:((v >> 8) & 0xFF) / 255.0
                                                blue:(v & 0xFF) / 255.0 alpha:1.0]];
            }
        }
    }
    return pal;
}

/* 2.5.11: 横条流光 —— 与文字流光同一套相位驱动 */
static CGFloat gBarPhase = 0.0;
NSHashTable *gBarPills = nil;   /* 2.5.18: 定义提到 applyLockState 之前(那里有前置声明) */
static void diRegisterBarPill(UIView *pill) {
    if (!gBarPills) gBarPills = [NSHashTable weakObjectsHashTable];
    [gBarPills addObject:pill];
}

/* 2.5.18: 隐藏作用到"真正可见的层级" —— 前置声明(心跳里先用) */
static void diApplyBarAlpha(UIView *pill, BOOL hide, BOOL hard);
static char kAlphaForced;   /* 2.5.13: 标记 alpha 是被我们设为 0 的(2.5.19 提前, 心跳要用) */

/* 2.5.18: 记录"用户亲手把横条设成了什么色", 用于处理系统在锁屏重建图层后
   颜色被清成透明(锁屏显示原生白色的典型成因) —— 见 di_guardPillLayers。 */
static char kWantColorKey;

/* 2.5.18: 处理后置的"原子上色"。
   原来在 diStylePillView 里直接 addSublayer 再设 colors/frame, 中间有窗口期;
   锁屏重建图层树后我们的渐变被清掉或透明度归零, 肉眼就是系统默认横条。 */
static void di_guardPillLayers(UIView *pill) {
    if (!pill || !homeBarOn || !homeBarOn) return;
    NSNumber *want = objc_getAssociatedObject(pill, &kWantColorKey);
    if (!want) return;
    CAGradientLayer *grad = objc_getAssociatedObject(pill, &kGradLayerKey);
    if (!grad) return;
    BOOL broken = (grad.superlayer != pill.layer) || (grad.colors.count == 0) ||
                  (grad.opacity < 0.99) || (grad.frame.size.height < 1) ||
                  (pill.layer.backgroundColor && CGColorGetAlpha(pill.layer.backgroundColor) < 0.01 &&
                   ![want boolValue]);
    if (!broken) return;
    static CFAbsoluteTime lastFix;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastFix > 1.0) {
        lastFix = now;
        DLog(@"底栏横条[修复]: 图层被系统重置, 重建上色 (层=%@ 色数=%lu op=%.2f)",
             grad.superlayer == pill.layer ? @"在" : @"已脱离", (unsigned long)grad.colors.count, grad.opacity);
    }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    if (!grad.superlayer || pill.layer.sublayers.lastObject != grad) {
        [grad removeFromSuperlayer];
        [pill.layer addSublayer:grad];
    }
    grad.frame = pill.bounds;
    grad.cornerRadius = MIN(pill.bounds.size.width, pill.bounds.size.height) * 0.5;
    grad.masksToBounds = YES;
    grad.opacity = 1.0;
    if (grad.colors.count == 0) {
        UIColor *c = diHomeBarPalette().firstObject;
        if (c) grad.colors = @[(id)c.CGColor, (id)c.CGColor];
    }
    grad.hidden = NO;
    [CATransaction commit];
}

/* 2.5.8: 上色核心 —— 直接作用于任意 pill 实例(桌面/锁屏/横屏通吃) */
static void diStylePillView(UIView *pill) {
    if (!pill) return;
    static char kStyleKey;
    NSArray<UIColor *> *pal = diHomeBarPalette();
    BOOL wantColor = homeBarOn && pal.count > 0;
    objc_setAssociatedObject(pill, &kWantColorKey, @(wantColor), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    /* 2.5.11: 模式自动推导 —— 1 个色=单色; 多色+流光开关=flow; 多色=静态渐变 */
    NSString *mode = (pal.count <= 1) ? @"single" : (homeBarFlowOn ? @"flow" : @"gradient");

    /* 关掉系统"按背景明暗自动换色"。2.5.13: 每次调用都重设 ——
       系统(尤其锁屏 _updateStyle)会把它改回去抢颜色 */
    if (wantColor && [pill respondsToSelector:@selector(setIgnoresLuminance:)])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(pill, @selector(setIgnoresLuminance:), YES);

    CAGradientLayer *grad = objc_getAssociatedObject(pill, &kGradLayerKey);

    if (!wantColor) {
        /* 恢复系统外观: 撤掉渐变层, 清掉我们设的色 */
        if (grad) {
            [grad removeFromSuperlayer];
            objc_setAssociatedObject(pill, &kGradLayerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if ([objc_getAssociatedObject(pill, &kStyleKey) boolValue]) {
            objc_setAssociatedObject(pill, &kStyleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            pill.backgroundColor = nil;
            pill.layer.backgroundColor = nil;
        }
        return;
    }

    [CATransaction begin]; [CATransaction setDisableActions:YES];
    pill.clipsToBounds = YES;

    if ([mode isEqualToString:@"single"]) {
        UIColor *c = pal.firstObject;
        pill.backgroundColor = c;
        pill.layer.backgroundColor = c.CGColor;
        /* 2.5.17: 单色也用顶层渐变(同色两端)覆盖 —— 系统 _updateStyle 会把
           backgroundColor 改回黑/白, 只在 backgroundColor 上设色不稳。
           顶层渐变不受系统 backgroundColor 影响, 单色因此稳定显示。 */
        if (!grad) {
            grad = [CAGradientLayer layer];
            grad.startPoint = CGPointMake(0, 0.5);
            grad.endPoint = CGPointMake(1, 0.5);
            grad.name = @"driftislandHomeBar";
            objc_setAssociatedObject(pill, &kGradLayerKey, grad, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (grad.superlayer != pill.layer || pill.layer.sublayers.lastObject != grad) {
            [grad removeFromSuperlayer];
            [pill.layer addSublayer:grad];
        }
        grad.colors = @[(id)c.CGColor, (id)c.CGColor];
        grad.locations = @[@0.0, @1.0];
        grad.frame = pill.bounds;
        grad.cornerRadius = MIN(pill.bounds.size.width, pill.bounds.size.height) * 0.5;
        grad.masksToBounds = YES;
        objc_setAssociatedObject(pill, &kStyleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        /* 渐变 / 流光 */
        pill.backgroundColor = [UIColor clearColor];
        pill.layer.backgroundColor = [UIColor clearColor].CGColor;
        if (!grad) {
            grad = [CAGradientLayer layer];
            grad.startPoint = CGPointMake(0, 0.5);
            grad.endPoint = CGPointMake(1, 0.5);
            grad.name = @"driftislandHomeBar";
            objc_setAssociatedObject(pill, &kGradLayerKey, grad, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        /* 2.5.17: 关键修复 —— 渐变必须压在 pill 自身内容层"上面"。
           之前 insertSublayer:atIndex:0 会把渐变塞到 luma-dodge 胶囊层下面,
           系统的黑色胶囊直接盖住渐变, 肉眼看就是"黑色横条里露一点彩",
           而滑动/重排后才短暂透出颜色。这里始终置于最顶层并保证唯一性。 */
        if (grad.superlayer != pill.layer || pill.layer.sublayers.lastObject != grad) {
            [grad removeFromSuperlayer];
            [pill.layer addSublayer:grad];
        }
        /* 圆角跟随 pill 自身 */
        grad.frame = pill.bounds;
        grad.cornerRadius = MIN(pill.bounds.size.height, pill.bounds.size.width) * 0.5;
        grad.masksToBounds = YES;

        NSMutableArray *cols = [NSMutableArray array];
        NSUInteger n = pal.count;
        for (UIColor *c in pal) [cols addObject:(id)c.CGColor];
        if (n == 1) [cols addObject:(id)pal.firstObject.CGColor];   /* 单色渐变退化为纯色 */
        if ([mode isEqualToString:@"flow"]) {
            /* 2.5.11: 流光与文字同一套 —— 相位驱动: 6 个采样点调 diColorAt(位置+相位)取色,
               相位由 diBarFlowTick 定时推进, 每拍重设 colors → 肉眼可见流动。
               不再用 CAAnimation 动 locations(实测在系统 pill 上不动)。 */
            NSMutableArray *fcols = [NSMutableArray array];
            NSMutableArray *flocs = [NSMutableArray array];
            NSUInteger k = 32;   /* 2.6.0: 8→32 采样点 —— 稀疏采样下散开/收紧的折叠映射
                                    在中点附近色带突变, 看着一卡一卡; 密采样后过渡平滑如流水 */
            for (NSUInteger i = 0; i < k; i++) {
                /* 2.5.26: 四种方向 —— 用"映射坐标 s"统一表达:
                   0 左→右: s=t;  1 右→左: s=t+phase;
                   2 中间向两边散开: s=|t-0.5|*2-phase;  3 两边向中间收紧: s=|t-0.5|*2+phase。 */
                double t = (double)i / (double)(k - 1);
                double s;
                switch (homeBarFlowDir) {
                    case 1:  s = t + gBarPhase; break;
                    case 2:  s = fabs(t - 0.5) * 2.0 - gBarPhase; break;
                    case 3:  s = fabs(t - 0.5) * 2.0 + gBarPhase; break;
                    default: s = t - gBarPhase; break;
                }
                UIColor *c = diColorAt(pal, (CGFloat)s);
                [fcols addObject:(id)c.CGColor];
                [flocs addObject:@((double)i / (double)(k - 1))];
            }
            grad.colors = fcols;
            grad.locations = flocs;
        } else {
            /* 静态渐变: 均匀分布 */
            [grad removeAnimationForKey:@"flow"];
            grad.colors = cols;
            NSMutableArray *locs = [NSMutableArray array];
            NSUInteger m = cols.count;
            for (NSUInteger i = 0; i < m; i++) [locs addObject:@(m == 1 ? 0.0 : (double)i / (m - 1))];
            grad.locations = locs;
        }
    }
    [CATransaction commit];
    objc_setAssociatedObject(pill, &kStyleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (homeBarOn && pal.count > 0) diRegisterBarPill(pill);   /* 2.5.13: 所有场景持续重涂 */

    static CFAbsoluteTime tLog;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - tLog > 5) {
        tLog = now;
        DLog(@"底栏横条[上色]: 模式=%@ 色数=%lu pill=%@ %.0fx%.0f",
             mode, (unsigned long)pal.count, NSStringFromClass(pill.class),
             pill.bounds.size.width, pill.bounds.size.height);
    }
}

/* ===== 2.5.19: 锁屏横条 —— 主动扫描发现 =====
   185 日志给出的铁证: 锁屏上系统从不调用 MTLumaDodgePillView 的 layoutSubviews
   (日志里锁屏时段只有桌面那条 85x5 在上色), 所以我们既没机会上色, 也登记不到它。
   锁屏横条不是靠 luma-dodge 而是靠另一套宿主画出来的, 因此本版改为:
   锁屏出现时, 在整个 SpringBoard 视图树里按几何找"横条形状"的视图 + 找 grabber 宿主,
   找到后与桌面走同一套上色/登记逻辑, 并在心跳里持续复查。 */
static void diScanLockBarInView(UIView *v, int depth, NSMutableArray<UIView *> *out) {
    if (!v || depth > 22) return;
    CGSize b = v.bounds.size;
    BOOL shapeOK = (b.height >= 3.0 && b.height <= 9.0 && b.width >= 40.0 && b.width <= 620.0);
    if (shapeOK && !v.isHidden && v.alpha > 0.01) {
        NSString *cn = NSStringFromClass(v.class);
        /* 明确排除状态栏/灵动岛里的细条, 只收"胶囊感"的视图 */
        BOOL bad = [cn containsString:@"StatusBar"] || [cn containsString:@"Aperture"] ||
                   [cn containsString:@"Separator"] || [cn containsString:@"Divider"];
        if (!bad) [out addObject:v];
    }
    if ([NSStringFromClass(v.class) containsString:@"HomeGrabber"]) {
        UIView *pill = nil;
        @try { pill = [v valueForKey:@"_pillView"]; } @catch (NSException *e) { pill = nil; }
        if (pill) [out addObject:pill];
    }
    for (UIView *sub in v.subviews) diScanLockBarInView(sub, depth + 1, out);
}

/* 2.5.19: 当前是否在锁屏界面(锁屏/通知中心下拉态都算) */
static BOOL diLockScreenShowing(void) {
    if (gLocked) return YES;
    return NO;
}

static void diScanAndStyleLockBars(void) {
    if (!homeBarOn) return;
    NSMutableArray<UIView *> *found = [NSMutableArray array];
    diForEachWindow(^(UIWindow *w) {
        if (w.isHidden || w.alpha < 0.01) return;
        diScanLockBarInView(w, 0, found);
    });
    if (!found.count) return;
    static CFAbsoluteTime lastLog;
    BOOL logged = (CFAbsoluteTimeGetCurrent() - lastLog < 4.0);
    for (UIView *v in found) {
        diStylePillView(v);
        diRegisterBarPill(v);      /* 登记后由心跳持续维持颜色 */
        di_guardPillLayers(v);
        if (!logged) {
            logged = YES;
            DLog(@"底栏横条[锁屏扫描]: %@ %.0fx%.0f 父=%@",
                 NSStringFromClass(v.class), v.bounds.size.width, v.bounds.size.height,
                 v.superview ? NSStringFromClass(v.superview.class) : @"-");
        }
    }
    if (logged) lastLog = CFAbsoluteTimeGetCurrent();
}

/* 2.5.11: 横条流光心跳 —— 推进相位并刷新所有可见 pill */
static void diBarFlowTick(void) {
    /* 2.5.13: 只要开了横条自定义就持续重涂 —— 锁屏的系统 _updateStyle
       会周期性把颜色抢回去, 只涂一次在锁屏上会被打回默认色 */
    if (!homeBarOn) return;

    /* 2.5.18: 横屏 2 秒隐藏由心跳主动推进 —— 横条静止时系统不再回调
       layoutSubviews, 计时判断没机会执行, 这是之前"2 秒后没隐藏"的根因。
       在心跳里算完后立刻同步一次 alpha, 并周期性复查(系统会重建视图冲掉 alpha)。 */
    BOOL landscape = diLandscapeNow();
    BOOL landHide = diLandHideActive();
    static int lastState = -1;    /* 0=横屏显示 1=横屏已隐藏 2=竖屏 */
    static CFAbsoluteTime tLandLog;
    int state = landHide ? 1 : (landscape ? 0 : 2);
    if (state != lastState) {
        lastState = state;
        tLandLog = 0;   /* 立刻打一条, 便于日志验证 */
    }
    if (CFAbsoluteTimeGetCurrent() - tLandLog > 1.5) {
        tLandLog = CFAbsoluteTimeGetCurrent();
        if (state != 2)
            DLog(@"横条[横屏]: 横屏=%d 已隐藏=%d 候选数=%lu", (int)landscape, (int)landHide,
                 (unsigned long)gBarPills.count);
    }

    if (homeBarFlowOn && !landHide) { gBarPhase += 0.02; if (gBarPhase >= 1.0) gBarPhase -= 1.0; }
    for (UIView *p in gBarPills) {
        if (!p.window) continue;
        /* 横屏强制隐藏: 彻底隐藏并**跳过重涂** —— 只要继续重涂就会反复把 alpha 置回,
           用户"滑动一下显示"永远看不到效果(这是 2.5.17 的隐藏死结)。
           唤回由 diSwiped / diTouched 重置 gLandHidden, 下一拍这里自然会走显示分支。 */
        /* 2.5.23-2: 呼回检测(修正版) —— 只认"我们压过(带 kAlphaForced 标记)且被
           抬回 >0.5"的层。隐藏期间我们跳过重涂、只会往下压, 此时 alpha 被抬回
           只能是系统 home 手势在显示横条(用户上滑呼出) → 重置 gLandHidden +
           重启 2 秒计时。旧版没查 kAlphaForced, 刚开始隐藏的第一拍横条还是
           alpha=1, 被误判成呼出, 每拍重置 → 永远藏不住(23-1 的"不会隐藏"即此因)。 */
        if (landHide) {
            BOOL external = objc_getAssociatedObject(p, &kAlphaForced) && p.alpha > 0.5;
            for (UIView *anc = p.superview; anc && anc.window == p.window && anc != anc.superview; anc = anc.superview) {
                if (objc_getAssociatedObject(anc, &kAlphaForced) && anc.alpha > 0.5) { external = YES; break; }
                CGSize ab = anc.bounds.size, pb = p.bounds.size;
                if (ab.height > MAX(pb.height * 3.0, 44.0)) break;   /* 与 diApplyBarAlpha 同一层级边界 */
            }
            if (external) {
                diRevealBarNow("系统唤出横条");
                landHide = NO;
            }
        }
        if (landHide) { diApplyBarAlpha(p, YES, YES); continue; }
        diApplyBarAlpha(p, homeBarHideOn, NO);   /* 普通"隐藏横条"设置 */
        diStylePillView(p);
        di_guardPillLayers(p);
        /* 2.5.19: 顺手把横屏/锁屏下的"半透明唤醒态"收回到全不透明 */
        if (!homeBarHideOn && p.alpha < 0.99 && objc_getAssociatedObject(p, &kAlphaForced))
            p.alpha = 1.0;
    }

    /* 2.5.19: 锁屏横条不在 luma-dodge 上 → 主动扫描(每 0.5s 一次, 只在锁屏/下拉时) */
    if (diLockScreenShowing()) {
        static CFAbsoluteTime tScan;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - tScan > 0.5) { tScan = now; diScanAndStyleLockBars(); }
    }
}
static void diStartBarFlowTicker(void) {
    static dispatch_source_t t;
    if (t) return;
    t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, DISPATCH_TIME_NOW, 0.06 * NSEC_PER_SEC, 0.01 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(t, ^{ @autoreleasepool { diBarFlowTick(); } });
    dispatch_resume(t);
}

/* diStyleGrabber: 找到 grabber 里的 pill 再上色(桌面主路径) */
static void diStyleGrabber(UIView *grabber) {
    if (!grabber) return;
    UIView *pill = nil;
    @try { pill = [grabber valueForKey:@"_pillView"]; }
    @catch (NSException *e) { pill = nil; }
    if (!pill) {
        for (UIView *sub in grabber.subviews) {
            if ([NSStringFromClass(sub.class) containsString:@"Pill"]) { pill = sub; break; }
        }
    }
    diStylePillView(pill);
}

/* ===== 2.5.8: hook MTLumaDodgePillView layoutSubviews —— 全场景兜底 =====
   桌面横条由 grabberFrameForBounds 管长短; 锁屏/横屏的 pill 不走那条路,
   这里在 pill 自己的布局回调里统一处理: 上色 + 隐藏 + (非 grabber 宿主时)长短。 */

/* 2.5.16: 横条轻量滑动监听 —— 横屏隐藏后"滑动一下"重新显示。
   2.5.18: 换成不依赖命中测试的全局监听。
   2.5.19: 手势"挂到哪个窗口"是 2.5.18 失效的根因 —— 185 日志里手势被反复挂到
   SBMainSwitcherWindow / SBCoverSheetWindow(都是覆盖层), 真正在前台接触摸的是
   SBSystemApertureWindow(灵动岛宿主, 全屏)。覆盖层不接收触摸, 手势就永远不触发。
   本版改为: 主监听 = 屏幕边缘平移(系统在边缘区域不会把触摸交给应用/游戏),
   并同时挂到所有全屏窗口上; 再加一条兜底 —— 隐藏状态下只要有触摸落下就唤回。*/
@interface DIBarSwipeWatcher : NSObject <UIGestureRecognizerDelegate>
@end
static DIBarSwipeWatcher *diSwipeWatcherShared(void) {
    static DIBarSwipeWatcher *w;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ w = [DIBarSwipeWatcher new]; });
    return w;
}
/* 隐藏期间只要屏幕被碰一下就唤回 —— 满足"滑动一下才显示出来", 且不拦截任何触摸 */
static void diRevealBarNow(const char *why) {
    BOOL wasHidden = gLandHidden;
    diResetLandscapeHide();
    gLandHidden = NO;
    if (wasHidden) {   /* 2.5.23-3: 原生同款 —— 呼出横条时轻震一下, 防误触感知 */
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [h impactOccurred];
        });
    }
    for (UIView *p in gBarPills) if (p.window) p.alpha = 1.0;
    if (!wasHidden) return;
    static CFAbsoluteTime lastLog;
    if (CFAbsoluteTimeGetCurrent() - lastLog > 0.5) {
        lastLog = CFAbsoluteTimeGetCurrent();
        DLog(@"横条: %s → 唤回显示, 2 秒计时重置", why);
    }
}
@implementation DIBarSwipeWatcher
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)o {
    return NO;
}
- (void)diTouched:(UIGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan && g.state != UIGestureRecognizerStateChanged) return;
    if (!gestureProtectOn || !gLandHidden || !diLandscapeNow()) return;
    diRevealBarNow("检测到触摸");
}
- (void)diSwiped:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan && g.state != UIGestureRecognizerStateChanged) return;
    CGPoint t = [g translationInView:g.view];
    if (fabs(t.y) < 5 && fabs(t.x) < 5) return;
    if (!gestureProtectOn) return;
    if (!diLandscapeNow()) return;
    diRevealBarNow("检测到滑动(边缘)");
}
@end

/* 2.5.19: 给一个窗口装上"边缘 pan + 轻点"两把 passive 监听(带去重) */
static void diAttachSwipeGesturesToWindow(UIWindow *w) {
    if (!w || !gestureProtectOn) return;
    DIBarSwipeWatcher *watcher = diSwipeWatcherShared();
    NSMutableArray *gs = [NSMutableArray array];
    for (UIGestureRecognizer *g in [w.gestureRecognizers copy]) {
        if (![g.delegate isKindOfClass:[DIBarSwipeWatcher class]]) continue;
        [gs addObject:g];
    }
    BOOL hasPan = NO, hasTap = NO;
    for (UIGestureRecognizer *g in gs) {
        if ([g isKindOfClass:[UIPanGestureRecognizer class]]) hasPan = YES;
        if ([g isKindOfClass:[UITapGestureRecognizer class]]) hasTap = YES;
    }
    if (!hasPan) {
        UIScreenEdgePanGestureRecognizer *p =
            [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:watcher action:@selector(diSwiped:)];
        p.edges = UIRectEdgeLeft | UIRectEdgeRight | UIRectEdgeBottom;
        p.maximumNumberOfTouches = 1;
        p.cancelsTouchesInView = NO;
        p.delaysTouchesBegan = NO;
        p.delaysTouchesEnded = NO;
        p.delegate = watcher;
        [w addGestureRecognizer:p];
        DLog(@"横条[手势]: 已挂边缘滑动监听到 %@", NSStringFromClass(w.class));
    }
    if (!hasTap) {
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:watcher action:@selector(diTouched:)];
        t.numberOfTapsRequired = 1;
        t.numberOfTouchesRequired = 1;
        t.cancelsTouchesInView = NO;
        t.delaysTouchesBegan = NO;
        t.delaysTouchesEnded = NO;
        t.delegate = watcher;
        [w addGestureRecognizer:t];
    }
}

/* 2.5.19: 挑出"真正在全屏接触摸"的窗口装监听。
   185 日志显示 2.5.18 只挂到了覆盖层(SBMainSwitcher/SBCoverSheet), 那两层的
   触摸根本到不了, 于是"滑动唤回"全程没触发过。 */
static void diEnsureSwipeWatcherInWindow(UIWindow *w) {
    if (!w || !gestureProtectOn) return;
    diAttachSwipeGesturesToWindow(w);
    /* 同时补齐所有全屏窗口(SBSystemApertureWindow 等) */
    static CFAbsoluteTime lastScan;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastScan < 1.0) return;
    lastScan = now;
    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGFloat need = MIN(scr.width, scr.height) * 0.85;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in ((UIWindowScene *)s).windows) {
            if (win.isHidden || win.alpha < 0.01) continue;
            if (win.windowLevel < UIWindowLevelNormal - 1) continue;
            CGSize bs = win.bounds.size;
            if (MAX(bs.width, bs.height) < need) continue;   /* 小窗/岛本身不要 */
            diAttachSwipeGesturesToWindow(win);
        }
    }
}

/* 2.5.18: 隐藏作用到"真正可见的层级" —— 之前只按祖先尺寸推 3 层, 有些场景
   3 层不够(横屏时横条外面还套了两层容器), 结果设了 alpha 也不隐形。
   现在沿祖先链一直走到窗口根视图, 只要尺寸没明显变大(不是整屏容器)就一起处理。 */
static void diApplyBarAlpha(UIView *pill, BOOL hide, BOOL hard) {
    if (!pill) return;
    BOOL fade = [homeBarHideMode isEqualToString:@"fade"];
    NSMutableArray<UIView *> *targets = [NSMutableArray arrayWithObject:pill];
    {
        UIView *anc = pill.superview;
        for (int d = 0; anc && d < 5; d++, anc = anc.superview) {
            if (anc.window != pill.window) break;
            CGSize ab = anc.bounds.size;
            CGSize pb = pill.bounds.size;
            /* 明显比横条大很多的容器(整屏/半屏)不能动, 否则会隐藏掉别的内容 */
            if (ab.height > MAX(pb.height * 3.0, 44.0)) break;
            if (ab.width > MAX(pb.width * 6.0, 240.0)) break;
            [targets addObject:anc];
        }
    }
    for (UIView *tv in targets) {
        if (hide) {
            tv.alpha = (fade && !hard) ? 0.25 : 0.0;
            objc_setAssociatedObject(tv, &kAlphaForced, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (objc_getAssociatedObject(tv, &kAlphaForced)) {
            tv.alpha = 1.0;
            objc_setAssociatedObject(tv, &kAlphaForced, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void (*orig_pillLayout)(id self, SEL _cmd);
static void di_pillLayout(id self, SEL _cmd) {
    if (orig_pillLayout) orig_pillLayout(self, _cmd);   /* 空指针保护 */
    @try {
        UIView *pill = (UIView *)self;
        if (!pill.window) return;
        CGFloat bw9 = pill.bounds.size.width, bh9 = pill.bounds.size.height;
        /* 2.5.15: 诊断 —— 锁屏横条若类/几何与桌面不同, 这里能抓到真实数据 */
        if (bh9 < 2 || bh9 > 14 || bw9 < 8 || bw9 > 600) {
            static NSMutableSet *seen;
            static int cnt;
            if (!seen) seen = [NSMutableSet set];
            if (cnt < 30) {
                NSString *sig = [NSString stringWithFormat:@"%@|%0.fx%0.f", NSStringFromClass(pill.class),
                                 bw9 / 10, bh9 / 10];
                if (![seen containsObject:sig]) {
                    [seen addObject:sig]; cnt++;
                    DLog(@"底栏横条[候选]: %@ %.0fx%.0f 父=%@ 可见=%d alpha=%.2f",
                         NSStringFromClass(pill.class), bw9, bh9,
                         pill.superview ? NSStringFromClass(pill.superview.class) : @"-",
                         (int)(!pill.isHidden), pill.alpha);
                }
            }
            return;
        }

        /* --- 2.5.16: 手势保护开启时, 给横条挂上"滑动唤醒"监听 --- */
        if (gestureProtectOn && pill.window) diEnsureSwipeWatcherInWindow(pill.window);

        /* --- 上色(全场景) ---
           2.5.16: 先上色再处理显隐 —— 之前顺序相反, 首帧先被设成 alpha=0/0.25,
           颜色要等下一轮布局才补上, 表现为"进横屏后要滑一下才出现自己的颜色"。 */
        diStylePillView(pill);
        di_guardPillLayers(pill);

        /* --- 隐藏(2.5.16): 静态半透明/全隐, 作用到真正可见的层级 --- */
        {
            BOOL hide = homeBarHideOn;
            BOOL landHide = diLandHideActive();   /* 2.5.18: 横屏 2 秒后彻底隐藏 */
            diApplyBarAlpha(pill, (hide || landHide), landHide);
        }

        /* --- 长短(2.5.13): transform 不改 bounds, bounds 始终是系统布的宽 →
           直接按百分比缩放, 竖屏/横屏/锁屏比例天然一致(2.5.12 记录一次原始宽,
           旋转后基线过期导致竖屏横屏长短不一致)。 */
        if (homeBarOn && !homeBarHideOn && fabs(homeBarLen - 100.0) > 0.5 &&
            [NSStringFromClass(pill.superview.class) rangeOfString:@"HomeGrabber"].location == NSNotFound) {
            CGFloat sc = homeBarLen / 100.0;
            if (sc < 0.05) sc = 0.05;
            if (fabs(pill.transform.a - sc) > 0.005)
                pill.transform = CGAffineTransformMakeScale(sc, 1.0);   /* 中心锚点, 幂等 */
        }
    } @catch (NSException *e) { /* 布局回调里绝不抛异常 */ }
}

static void diHookHomeGrabber(void);   /* 前置声明, init 里安装 */

static void diApplyHomeBarInView(UIView *v) {
    static char kBarKey;

    /* ---- 2.5.5 首选路径: SBHomeGrabberView / 其内部 _pillView ---- */
    NSString *cn = NSStringFromClass(v.class);
    if ([cn containsString:@"HomeGrabber"] || [cn containsString:@"GrabberView"]) {
        UIView *pill = nil;
        @try { pill = [v valueForKey:@"_pillView"]; }
        @catch (NSException *e) { pill = nil; }
        if (!pill) {   /* 兜底: 自己找胶囊子视图 */
            for (UIView *sub in v.subviews) {
                CGFloat sh = sub.bounds.size.height, sw = sub.bounds.size.width;
                if (sh >= 3 && sh <= 9 && sw > 60) { pill = sub; break; }
            }
        }
        if (pill) {
            objc_setAssociatedObject(v, &kBarKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (homeBarColor) {
                /* 关掉系统"根据背景明暗换色", 否则颜色会被 _updateStyle 抢回去 */
                if ([v respondsToSelector:@selector(setIgnoresLuminance:)])
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(v, @selector(setIgnoresLuminance:), YES);
                if ([pill respondsToSelector:@selector(setIgnoresLuminance:)])
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(pill, @selector(setIgnoresLuminance:), YES);
                [CATransaction begin]; [CATransaction setDisableActions:YES];
                pill.backgroundColor = homeBarColor;
                pill.layer.backgroundColor = homeBarColor.CGColor;
                [CATransaction commit];
            }
            static CFAbsoluteTime tLog;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - tLog > 3) {
                tLog = now;
                DLog(@"底栏横条: 命中 %@ pill=%@ 长%.0f%% 色%@",
                     cn, NSStringFromClass(pill.class), homeBarLen,
                     homeBarColor ? @"自定义" : @"不改");
            }
            return;
        }
    }

    /* ---- 2.5.4 几何兜底: 扁长胶囊本体(类名不可知时) ---- */

    /* 已改过的直接跳过(重申只发生在系统重建后: 关联对象跟着新视图走, 旧视图释放即清) */
    if ([objc_getAssociatedObject(v, &kBarKey) boolValue]) return;
    objc_setAssociatedObject(v, &kBarKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    /* 找横条本体: 内部最大的扁长圆角视图; 没有子视图时横条可能就是 v 自己 */
    UIView *bar = nil;
    CGFloat bestA = 0;
    for (UIView *sub in v.subviews) {
        CGFloat w = sub.bounds.size.width, h = sub.bounds.size.height;
        if (h >= 3 && h <= 9 && w > 60 && w * h > bestA) { bestA = w * h; bar = sub; }
    }
    if (!bar) {
        CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
        if (h >= 3 && h <= 9 && w > 60) bar = v;
    }
    if (!bar) return;

    CGFloat origW = bar.bounds.size.width;
    if (origW < 60) return;
    CGFloat targetW = origW * homeBarLen / 100.0;

    [CATransaction begin]; [CATransaction setDisableActions:YES];
    CGRect f = bar.frame;
    f.origin.x += (origW - targetW) * 0.5;    /* 中心对齐缩放 */
    f.size.width = targetW;
    bar.frame = f;
    if (homeBarColor) bar.backgroundColor = homeBarColor;
    [CATransaction commit];
    static CFAbsoluteTime tLog;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - tLog > 3) {
        tLog = now;
        DLog(@"底栏横条: 已应用 长%.0f%% 色%@ (本体 %.0fx%.0f)",
             homeBarLen, homeBarColor ? @"自定义" : @"不改", origW, bar.bounds.size.height);
    }
}


static void diHomeBarTick(void) {
    /* 2.5.2: 诊断与开关解耦 —— 只要日志开着, 每 10s 打一次候选类名,
       不再依赖"底栏横条自定义"是否打开(上一版没日志没法定位类名) */
    static CFAbsoluteTime tDiag;
    if (logEnabled) {
        CFAbsoluteTime nowD = CFAbsoluteTimeGetCurrent();
        if (nowD - tDiag > 10.0) {
            tDiag = nowD;
            /* 2.5.4: 关键词扫描(Home/Indicator/Grabber)在 iOS16.2 SpringBoard 零命中,
               说明横条类名不含这些词。改用几何特征: 任何 h∈[3,9] 且 w>=60 的视图/层
               都是横条候选 —— 不依赖类名。 */
            for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
                    int guard = 0;
                    while (stack.count && guard++ < 3000) {
                        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0];
                        CGFloat bh = v.bounds.size.height, bw = v.bounds.size.width;
                        if (bh >= 2.5 && bh <= 9.5 && bw >= 60) {
                            NSMutableString *chain = [NSMutableString string];
                            UIView *p = v.superview; int pc = 0;
                            while (p && pc++ < 4) {
                                [chain appendFormat:@"← %@(%0.fx%0.f)", NSStringFromClass(p.class), p.bounds.size.width, p.bounds.size.height];
                                p = p.superview;
                            }
                            DLog(@"底栏横条[候选]: %@ %.0fx%.0f@%0.f,%0.f bg=%@ hidden=%d alpha=%.2f %s%@",
                                 NSStringFromClass(v.class), bw, bh, v.frame.origin.x, v.frame.origin.y,
                                 v.backgroundColor ? [NSString stringWithFormat:@"%@", v.backgroundColor] : @"nil",
                                 v.hidden, v.alpha,
                                 "父链: ", chain);
                        }
                        for (UIView *sub in v.subviews) [stack addObject:sub];
                    }
                    NSMutableArray<CALayer *> *ls = [NSMutableArray arrayWithObject:w.layer];
                    int lg = 0;
                    while (ls.count && lg++ < 3000) {
                        CALayer *l = ls.firstObject; [ls removeObjectAtIndex:0];
                        CGFloat lh = l.bounds.size.height, lw = l.bounds.size.width;
                        if (lh >= 2.5 && lh <= 9.5 && lw >= 60 && l.superlayer && ![l isKindOfClass:[CATransformLayer class]]) {
                            DLog(@"底栏横条[候选-层]: %@ %.0fx%.0f@%0.f,%0.f 画布=%@ hidden=%d 父=%@",
                                 NSStringFromClass(l.class), lw, lh, l.frame.origin.x, l.frame.origin.y,
                                 l.contents ? @"有" : @"无", l.hidden, NSStringFromClass(l.superlayer.class ?: [CALayer class]));
                        }
                        for (CALayer *sl in l.sublayers) [ls addObject:sl];
                    }
                }
            }
        }
    }
    /* 2.5.8: 隐藏横条已移入 di_pillLayout(pill 布局回调), 全场景生效 */
    if (!homeBarOn) return;
    if (!homeBarColor && fabs(homeBarLen - 100.0) < 0.5) return;   /* 默认值不折腾 */
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            /* 2.5.4: 不再按类名找 —— 直接对所有"胶囊候选视图"(本体或子视图里
               有 h∈[3,9] w>60 的)调 diApplyHomeBarInView, 与几何诊断同一判据 */
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
            int guard = 0;
            while (stack.count && guard++ < 3000) {
                UIView *v = stack.firstObject; [stack removeObjectAtIndex:0];
                CGFloat bh = v.bounds.size.height, bw = v.bounds.size.width;
                UIView *pill = nil;
                NSString *cn = NSStringFromClass(v.class);
                if ([cn containsString:@"Grabber"]) {   /* 2.5.5: 颜色走 grabber 路径 */
                    diApplyHomeBarInView(v);
                } else {
                if (bh >= 3 && bh <= 9 && bw > 60) pill = v;
                if (!pill) {
                    for (UIView *sub in v.subviews) {
                        CGFloat sh = sub.bounds.size.height, sw = sub.bounds.size.width;
                        if (sh >= 3 && sh <= 9 && sw > 60) { pill = sub; break; }
                    }
                }
                if (pill) {
                    /* 2.5.4 限位: 横条必须贴近屏幕底部(距底 <30pt), 避免误伤分隔线等细长视图 */
                    CGRect rw = [pill convertRect:pill.bounds toView:w];
                    if (w.bounds.size.height - rw.origin.y - rw.size.height < 30 && rw.origin.y > w.bounds.size.height * 0.8)
                        diApplyHomeBarInView(v);
                }
                }   /* else(非 Grabber) */
                for (UIView *sub in v.subviews) [stack addObject:sub];
            }
        }
    }
}

/* ---- 2.5.5: hook SBHomeGrabberView grabberFrameForBounds: 控制横条长短 ---- */
static CGRect (*orig_grabberFrameForBounds)(id self, SEL _cmd, CGRect bounds);
static CGRect di_grabberFrameForBounds(id self, SEL _cmd, CGRect bounds) {
    CGRect f = orig_grabberFrameForBounds(self, _cmd, bounds);
    /* 2.5.6: 每次布局都顺手刷一次上色 —— 系统重建 pill 后能立刻恢复 */
    diStyleGrabber(self);
    /* 2.5.18: 锁屏横条不是这个宿主渲染的, 但 grabber 布局时机稳定 ——
       顺手把"不在任何 grabber 里"的游离 pill(桌面底栏/锁屏胶囊)也补一遍色。 */
    if (homeBarOn) {
        static CFAbsoluteTime lastScan;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastScan > 0.4) {
            lastScan = now;
            for (UIView *p in [gBarPills allObjects]) {
                if (!p.window || p.isHidden || p.alpha < 0.01) continue;
                if ([p.superview isKindOfClass:NSClassFromString(@"SBHomeGrabberView")]) continue;
                diStylePillView(p);
                di_guardPillLayers(p);
            }
        }
    }

    if (!homeBarOn || fabs(homeBarLen - 100.0) < 0.5) return f;
    if (f.size.width < 40 || f.size.height < 2 || f.size.height > 12) return f;
    CGFloat nw = diHomeBarScaleW(f.size.width);
    f.origin.x += (f.size.width - nw) * 0.5;   /* 中心对齐 */
    f.size.width = nw;
    return f;
}

/* ---- 2.5.7: 手势保护 —— 底部上滑第一次只提示, 短暂窗口内第二次才放行 ---- */

static BOOL (*orig_gestureBegin)(id self, SEL _cmd, id gesture);
static BOOL di_gestureBegin(id self, SEL _cmd, id gesture) {
    if (!gestureProtectOn) return orig_gestureBegin(self, _cmd, gesture);
    static CFAbsoluteTime lastWarn;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastWarn < 1.5) {   /* 1.5 秒内第二次上滑 → 放行 */
        lastWarn = 0;
        DLog(@"手势保护: 二次上滑确认, 放行");
        return orig_gestureBegin(self, _cmd, gesture);
    }
    lastWarn = now;
    DLog(@"手势保护: 首次上滑已拦截(1.5s 内再滑一次才退出)");
    /* 轻微震动提示 */
    UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [h impactOccurred];
    return NO;
}

/* 2.5.23-3: 横屏呼回主通道 —— hook UIApplication sendEvent。
   SpringBoard 能收到 home 手势区域的触摸(系统上滑退出就走这条通道, 186 实证
   窗口级手势识别器反而收不到 —— TouchPassThrough 根视图)。
   2.5.24 曾以为钩子会崩 SpringBoard, 后来 2.5.25(无钩子)同样崩, 证实真凶是
   扫描器的枚举突变, 钩子本身安全。 */
static void (*orig_sendEvent)(id self, SEL _cmd, UIEvent *e);
static void di_sendEvent(id self, SEL _cmd, UIEvent *e) {
    @try {
        if (gestureProtectOn && gLandHidden && diLandscapeNow() &&
            e && e.type == UIEventTypeTouches) {
            /* 关键事实(192 实测反推): 横屏时触摸坐标仍是竖屏(portrait)坐标系 ——
               视觉底部的 home 横条在竖屏坐标里是屏幕"左缘或右缘的中部"。
               用 statusBarOrientation 区分朝向, 只认横条真实所在的那一小块区域。 */
            CGSize scr = [UIScreen mainScreen].bounds.size;
            CGFloat pw = MIN(scr.width, scr.height), ph = MAX(scr.width, scr.height); // 竖屏宽高
            /* 2.6.2: statusBarOrientation 在 SpringBoard 不可靠(193 实测横条处无触发),
               改为不辨朝向: 左右两短缘(横条原长度) ∩ 竖屏高度中部 50% —— 其他区域一概不触发 */
            for (UITouch *t in e.allTouches) {
                if (t.phase != UITouchPhaseBegan && t.phase != UITouchPhaseMoved) continue;
                CGPoint p = [t locationInView:nil];
                BOOL inEdge = (p.x < pw * 0.18 || p.x > pw * 0.82);
                BOOL inMiddle = (fabs(p.y - ph * 0.5) < ph * 0.25);
                if (inEdge && inMiddle) {
                    diRevealBarNow("sendEvent 触摸");
                    break;
                }
            }
        }
    } @catch (NSException *ex) { /* 事件回调绝不抛 */ }
    if (orig_sendEvent) orig_sendEvent(self, _cmd, e);
}

static void diHookGestureProtect(void) {
    static BOOL done = NO;
    if (done) return;
    {   /* 2.5.23-3: sendEvent 钩子 —— 横屏"滑动呼出"主通道 */
        static BOOL seDone = NO;
        if (!seDone) {
            seDone = YES;
            MSHookMessageEx([UIApplication class], @selector(sendEvent:),
                            (IMP)di_sendEvent, (IMP *)&orig_sendEvent);
            DLog(@"横条[手势]: 已 hook UIApplication sendEvent (横屏呼回主通道)");
        }
    }
    /* 2.5.8: ① 枚举 SpringBoard 内所有手势相关类和方法(带类型编码), 一次打尽写日志,
       下一版按真实类名/方法名精确 hook。② 同时仍尝试 hook 已知候选。 */
    {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            unsigned int n = 0;
            Class *cls = objc_copyClassList(&n);
            int logged = 0;
            for (unsigned i = 0; i < n && logged < 60; i++) {
                NSString *cn = NSStringFromClass(cls[i]);
                if (![cn containsString:@"HomeGesture"] && ![cn containsString:@"HomeGrabber"]) continue;
                unsigned int cnt = 0;
                Method *ms = class_copyMethodList(cls[i], &cnt);
                for (unsigned j = 0; j < cnt && logged < 60; j++) {
                    const char *sn = sel_getName(method_getName(ms[j]));
                    if (!strstr(sn, "esture") && !strstr(sn, "wipe") && !strstr(sn, "xit")) continue;
                    DLog(@"手势保护[枚举]: %s (%s) type=%s",
                         cn.UTF8String, sn, method_getTypeEncoding(ms[j]));
                    logged++;
                }
                free(ms);
            }
            free(cls);
            if (!logged) DLog(@"手势保护[枚举]: 未发现含 HomeGesture 的类(可能延迟加载, 稍后重试)");
        });
    }
    NSArray *names = @[@"SBHomeGestureInteraction", @"SBHomeGestureRootSwitcherModifier",
                       @"SBFluidSwitcherGestureManager", @"SBHomeGestureArbiter",
                       @"SBHomeGestureRecognizer"];
    for (NSString *n in names) {
        Class c = NSClassFromString(n);
        if (!c) continue;
        unsigned int cnt = 0;
        Method *ms = class_copyMethodList(c, &cnt);
        for (unsigned i = 0; i < cnt; i++) {
            const char *sn = sel_getName(method_getName(ms[i]));
            const char *types = method_getTypeEncoding(ms[i]);
            BOOL nameOK = (strstr(sn, "estureBegan") || strstr(sn, "estureDidBegin"));
            BOOL sigOK = types && types[0] == 'B' && strcmp(types, "B@:@") == 0;
            if (nameOK && sigOK) {
                MSHookMessageEx(c, method_getName(ms[i]), (IMP)di_gestureBegin, (IMP *)&orig_gestureBegin);
                done = YES;
                DLog(@"手势保护: 已 hook %s(%s) type=%s", n.UTF8String, sn, types);
            }
        }
        free(ms);
    }
    if (!done) DLog(@"手势保护: 未找到可 hook 的手势方法(等枚举日志定位后下版修复)");
}

/* 2.5.14: 系统 _updateStyle 是"重涂抢色"的源头(尤其锁屏) ——
   它一跑完我们就把颜色/长短再压回去, 保证任何场景都是我们的样式 */
static void (*orig_pillUpdateStyle)(id self, SEL _cmd);
static void di_pillUpdateStyle(id self, SEL _cmd) {
    if (orig_pillUpdateStyle) orig_pillUpdateStyle(self, _cmd);
    @try {
        if (!homeBarOn) return;
        UIView *pill = (UIView *)self;
        if (!pill.window) return;
        CGFloat bw = pill.bounds.size.width, bh = pill.bounds.size.height;
        if (!(bh >= 2 && bh <= 12 && bw >= 8 && bw <= 420)) return;
        diStylePillView(pill);
        /* 长短同样补一遍(与 di_pillLayout 同一逻辑) */
        if (!homeBarHideOn && fabs(homeBarLen - 100.0) > 0.5 &&
            [NSStringFromClass(pill.superview.class) rangeOfString:@"HomeGrabber"].location == NSNotFound) {
            CGFloat sc = homeBarLen / 100.0;
            if (sc < 0.05) sc = 0.05;
            if (fabs(pill.transform.a - sc) > 0.005)
                pill.transform = CGAffineTransformMakeScale(sc, 1.0);
        }
    } @catch (NSException *e) { }
}

static void diHookHomeGrabber(void) {
    static BOOL done = NO;
    if (done) return;
    Class c = NSClassFromString(@"SBHomeGrabberView");
    if (!c) return;
    MSHookMessageEx(c, @selector(grabberFrameForBounds:),
                    (IMP)di_grabberFrameForBounds, (IMP *)&orig_grabberFrameForBounds);
    /* 2.5.8: pill 自己的布局回调 —— 锁屏/横屏的横条也走这里 */
    Class pc = NSClassFromString(@"MTLumaDodgePillView");
    if (pc) {
        MSHookMessageEx(pc, @selector(layoutSubviews),
                        (IMP)di_pillLayout, (IMP *)&orig_pillLayout);
        DLog(@"底栏横条: 已 hook MTLumaDodgePillView layoutSubviews (全场景上色/隐藏)");
        /* 2.5.14: hook _updateStyle(存在才挂), 系统重涂后立即夺回颜色 */
        SEL us = NSSelectorFromString(@"_updateStyle");
        if ([pc instancesRespondToSelector:us]) {
            MSHookMessageEx(pc, us, (IMP)di_pillUpdateStyle, (IMP *)&orig_pillUpdateStyle);
            DLog(@"底栏横条: 已 hook MTLumaDodgePillView _updateStyle (锁屏保色)");
        } else {
            DLog(@"底栏横条: MTLumaDodgePillView 无 _updateStyle, 跳过");
        }
    } else {
        DLog(@"底栏横条: MTLumaDodgePillView 不存在(异常)");
    }
    /* 2.5.15: 枚举所有"Pill"类 —— 锁屏横条在 iOS16 上可能不是 MTLumaDodgePillView */
    {
        int n = objc_getClassList(NULL, 0);
        if (n > 0) {
            Class *buf = (Class *)malloc(sizeof(Class) * n);
            n = objc_getClassList(buf, n);
            NSMutableString *found = [NSMutableString string];
            for (int i = 0; i < n; i++) {
                NSString *cn = NSStringFromClass(buf[i]);
                if ([cn containsString:@"Pill"] || [cn containsString:@"LumaDodge"]) {
                    if (found.length > 900) { [found appendString:@"...(截断)"]; break; }
                    [found appendFormat:@"%@ ", cn];
                }
            }
            free(buf);
            DLog(@"底栏横条[类枚举]: %@", found.length ? found : @"(无)");
        }
    }
    done = YES;
    DLog(@"底栏横条: 已 hook SBHomeGrabberView grabberFrameForBounds: (长短控制)");
    diHookGestureProtect();
}
/* 别名: 分阶段重试用(类晚加载时反复尝试安装) */
static void diHookHomeBarGrabberRetry(void) { diHookHomeGrabber(); }

__attribute__((constructor)) static void init(void) {
    migrateLyricsParamsBase(); // 2.6.1: 歌词岛基准一次性迁移
    @autoreleasepool {
        refreshPrefs();
        NSString *bid = NSBundle.mainBundle.bundleIdentifier.lowercaseString;
        if (![bid isEqual:@"com.apple.springboard"]) return;
        logHandle = os_log_create("com.abgg332.driftisland", "runtime");
        DLog(@"===== 漂流岛 tweak 加载 (SpringBoard) 版本 %@ =====", \
         [NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] description] ?: @"?");
        dispatch_async(dispatch_get_main_queue(), ^{
            refreshAll(); installKnownHosts();
            diStartFlowTicker(); // 流光常驻驱动(岛静止时也能流动)
            diStartBarFlowTicker(); // 2.5.11: 横条流光心跳(与文字同一套相位驱动)
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                prefsChanged, (__bridge CFStringRef)kNotifyStr, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            // 2.6.10: 设置页选完「专辑遮罩素材」后 post 这条, 让悬浮岛立刻换素材
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                prefsChanged, CFSTR("com.abgg332.driftisland/prefsChanged"), NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                colorChanged, CFSTR("com.abgg332.driftisland.colorchanged"), NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                diPreviewNotify, CFSTR("com.abgg332.driftisland.preview"), NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                lockStateChanged, CFSTR("com.apple.springboard.lockstate"), NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            // 音量键监听: AVSystemController 音量通知走进程内 NSNotificationCenter(SpringBoard 内有效)。
            // 注意: addObserverForName:usingBlock: 返回的观察者 token 必须持有, 否则立即释放、通知永远收不到(2.2.3 根因)
            gVolumeObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification" object:nil queue:nil
                usingBlock:^(NSNotification *n) {
                    gVolumeUntil = CFAbsoluteTimeGetCurrent() + 6.0;
                    DLog(@"音量键事件: 6秒窗口内非音乐岛不挂视频");
                }];
            // 播放状态轮询: 岛触发才加载/播放, 无通知(岛收回)即暂停; 锁屏期间整个 timer 挂起(零功耗)
            gTickTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(gTickTimer, DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC, 0.1 * NSEC_PER_SEC);
            dispatch_source_set_event_handler(gTickTimer, ^{ visibilityTick(); });
            dispatch_resume(gTickTimer);
            /* 2.5.0: 底栏横条 0.3s 重申(系统重建横条后 0.3s 内恢复自定义) */
            {
                dispatch_source_t hb = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
                dispatch_source_set_timer(hb, DISPATCH_TIME_NOW, 0.3 * NSEC_PER_SEC, 0.1 * NSEC_PER_SEC);
                dispatch_source_set_event_handler(hb, ^{ diHomeBarTick(); });
                dispatch_resume(hb);
            }
            // 私有类可能加载较晚, 分阶段重试
            for (int s : {2, 5, 15, 30, 60})
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)s * NSEC_PER_SEC),
                    dispatch_get_main_queue(), ^{ installKnownHosts(); refreshAll(); diHookHomeBarGrabberRetry(); });
        });
    }
}
