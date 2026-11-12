// 漂流岛 Drift Island —— 灵动岛视频背景
// 素材目录: /var/mobile/灵动岛 (mp4/mov/m4v, 按文件名排序, 设置里按序号选用)
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>   /* 2.5.6: CAGradientLayer 横条渐变/流光 */
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CMTime.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <mach-o/dyld.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <string.h>
#include <notify.h>
#include <fcntl.h>
#include <unistd.h>
#import <substrate.h>
#import <os/log.h>
#include <dispatch/dispatch.h>
#include "DIVersion.h"   /* 3.0.28: 版本号唯一来源(与 prefs 共用) */
#include <vector>

static NSString *const kDomain = @"com.abgg332.driftisland";
static NSString *const kNotifyStr = @"com.abgg332.driftisland.reload";
static NSString *const kMaterialDir = @"/var/mobile/灵动岛";
static NSString *const kFrameDir = @"/var/mobile/灵动岛/帧率素材";
static NSString *const kMaskDir = @"/var/mobile/灵动岛/遮罩素材"; // 2.6.4: 遮罩素材(图片, 不需要帧率)
static NSString *const kWallpaperDir = @"/var/mobile/灵动岛/壁纸素材"; // 2.7.0: 壁纸素材(png/jpg/mp4)

/* 2.6.12: 字符串排序统一走这里 —— sortUsingSelector:@selector(localizedCompare:)
   会对 __NSCFString 抛 unrecognized selector(设置页点素材闪退的根因) */
static NSArray *diSortedStrs(NSArray *arr) {
    if (![arr isKindOfClass:NSArray.class]) return @[];
    return [arr sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        NSString *sa = [a isKindOfClass:NSString.class] ? a : @"";
        NSString *sb = [b isKindOfClass:NSString.class] ? b : @"";
        return [sa compare:sb options:NSCaseInsensitiveSearch | NSNumericSearch];
    }];
}

static BOOL logEnabled; // 日志开关
static BOOL gLocked = NO; // 锁屏状态: 锁屏期间所有岛视频/帧率动画全停(锁屏界面组件也是岛视图, 不停会一直亮屏)
/* ===== 2.8.12: 歌词岛已回归(2.8.4/2.8.5 曾下架) —— "音乐岛识别"判据保留,
   遮罩/视频层还要用它排除充电/人脸等系统岛 ===== */
static BOOL gFramesDirty;    // 素材文件夹变更标志: 立即重扫
static NSString *gMusicIslandId;  // 已确认音乐岛的 identifier(2.2.29 校验)
static NSString *gMusicIslandCls; // 2.6.3: 音乐岛宿主类名(强校验, 排除充电/人脸等其它岛)
static __weak UIView *gMiniHost;  // 2.6.13: 最近一次被 diMiniMusicActive 认下的音乐岛宿主(弱引用, 用于视频层区分"音乐岛/系统岛")
/* 2.6.3: 遮罩 —— 贴合在左侧专辑上的序列帧层(跟随专辑位置/尺寸), 带旋转 */
static BOOL maskOn = NO;          // 启用遮罩素材
static BOOL maskRotateOn = NO;    // 启用素材旋转
static BOOL maskRotateReverse = NO; // 素材旋转反转
static double maskRotateSpeed = 45.0; // 旋转角速度 °/秒
/* 2.8.16: 遮罩大小比例(%) —— 286 反馈"加遮罩后专辑大了一点点, 边上被裁剪,
   岛显示不了那么大"。玻璃边长 = 能放下的最大边长 × 这个比例, 设置页可调 50~115。 */
static double maskScale = 88.0;
static NSString *maskAnimFolder;  // 遮罩素材文件夹(帧率素材下的子目录)
/* ===== 2.8.85: 展开定义 —— 展开岛歌词/歌名的自定义位置与大小 =====
   展开岛(407x202 的 Now Playing)整块由 MediaRemoteUI 远程渲染, SpringBoard 只能看到
   一块门户, 拿不到里面的文字视图。所以参数由 SpringBoard 侧写进 MRU 容器的
   params.plist, 由 MRU 进程内的文字调整器读取并应用(见 diActivityTextApply)。 */
static BOOL expandTextOn = YES;       // 展开位置开关
static BOOL hideRouteOn = NO;        /* 2.8.93: 隐藏投送(AirPlay)按钮 */
/* 2.8.92: 基准落点 —— 用户自己调到满意的那一版就是 (120,45)。
   设置页的左右/上下现在是"相对这个基准"的增量, 滑杆默认 0 即这个位置, 左右 ±200。 */
#define DI_EXP_TEXT_BASE_X 120.0
#define DI_EXP_TEXT_BASE_Y 45.0
static double expandTextX = DI_EXP_TEXT_BASE_X;   // 左右偏移(pt, 右为正, 含基准)
static double expandTextY = DI_EXP_TEXT_BASE_Y;   // 上下偏移(pt, 下为正, 含基准)
static double expandTextScale = 100.0; // 文字大小(%, 100=原样)
/* 2.8.86: 构建戳 —— 之前横幅打的是 SpringBoard 自己的 CFBundleShortVersionString(恒 1.0),
   日志里根本看不出装的是哪一版。所有诊断行都带这个戳, 下轮日志一眼定位。 */
#define DI_BUILD_VER DI_VERSION   /* 3.0.28: 唯一来源 DIVersion.h */
static BOOL gRecordingActive = NO; // 保留: 岛素材总闸条件
static NSString *diElementId(UIView *host);
static BOOL diMiniMusicActive(UIView *host); // 2.6.3: 前置(遮罩层使用)
static os_log_t logHandle;

/* ===== 3.0.18: 日志核心重写 —— iOS 17 卡死的根因 =====
   旧实现每写一行日志都:
     ① 新建一个 NSDateFormatter(创建一次要毫秒级, 是 Foundation 里最贵的对象之一);
     ② fileHandleForWritingAtPath → seek → write → close(每行一次同步磁盘 I/O);
     ③ DLog 还要 stat 一次文件大小。
   在洪峰秒(iOS 17 上灵动岛相关路径一秒 60~190 行)里, 主线程全耗在日志 I/O 上,
   表现就是"卡死很久 → 看门狗杀掉 → 注销"。现在:
     · formatter 全局只建一个;
     · 文件句柄常驻(不再每行开/关), 写失败才重开;
     · 每秒最多落 25 行, 超出的只计数, 下一秒补一条"省略 N 行";
     · 大小上限只每 10 秒检查一次, 超限时保留末尾 200KB(旧实现会用单行覆盖整个文件,
       把引导判定等历史全冲掉 —— 之前几轮"日志被截断"的怪象就是它)。 */
static NSDateFormatter *diLogDF(void) {
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        df.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        df.timeZone = [NSTimeZone localTimeZone];
    });
    return df;
}
static NSString *diLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:kMaterialDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:NULL];
        path = [kMaterialDir stringByAppendingPathComponent:@"driftisland.log"];
        [fm setAttributes:@{NSFilePosixPermissions: @0666} ofItemAtPath:path error:NULL];
    });
    return path;
}
static NSFileHandle *gDILogHandle = nil;   /* 3.0.18: 常驻句柄(截断后置 nil 重开) */
static NSFileHandle *diLogHandle(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gDILogHandle = [NSFileHandle fileHandleForWritingAtPath:diLogPath()]; });
    if (!gDILogHandle) gDILogHandle = [NSFileHandle fileHandleForWritingAtPath:diLogPath()];   /* 文件被删后重开 */
    return gDILogHandle;
}
/* 限流: 每秒 25 行; 溢出计数, 秒切换时补一条汇总.
   3.0.22: 改成"先数数再格式化" —— 以前是先把整行拼出来再判断, 一旦某处在布局里刷屏
   (435 日志出现过一秒 30213 次), 光是拼字符串就能把主线程按死。 */
static void diLogWrite(NSString *out);   /* 下面定义 */
static BOOL diLogGate(void) {
    static int n = 0; static int dropped = 0;
    static CFAbsoluteTime sec = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - sec >= 1.0) {
        int d = dropped;
        dropped = 0;
        sec = now;
        n = 0;
        if (d > 0) {
            @try {
                NSString *line = [NSString stringWithFormat:@"[%@] [现场] (上一秒省略 %d 行重复日志)\n",
                                  [diLogDF() stringFromDate:[NSDate date]], d];
                diLogWrite(line);
            } @catch (__unused NSException *e) {}
        }
    }
    if (n >= 25) { dropped++; return NO; }
    n++;
    return YES;
}
static void diLogWrite(NSString *out) {
    NSFileHandle *h = diLogHandle();
    NSData *d = [out dataUsingEncoding:NSUTF8StringEncoding];
    if (!h) { [out writeToFile:diLogPath() atomically:YES encoding:NSUTF8StringEncoding error:NULL]; return; }
    @try { [h seekToEndOfFile]; [h writeData:d]; } @catch (__unused NSException *e) { gDILogHandle = nil; }
    /* 大小上限: 每 10 秒查一次; 超限保留末尾 200KB(不再用单行覆盖整个文件) */
    static CFAbsoluteTime tCap = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - tCap > 10.0) {
        tCap = now;
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:diLogPath() error:NULL];
        unsigned long long sz = attr ? [attr[NSFileSize] unsignedLongLongValue] : 0;
        if (sz > 512 * 1024) {
            unsigned long long keep = 200 * 1024;
            NSFileHandle *rh = [NSFileHandle fileHandleForReadingAtPath:diLogPath()];
            if (rh) {
                @try {
                    [rh seekToFileOffset:sz - keep];
                    NSData *tail = [rh readDataToEndOfFile];
                    [rh closeFile];
                    NSString *mark = @"[日志] 超过 512KB, 已截断保留末尾 200KB\n";
                    NSMutableData *nd = [NSMutableData data];
                    [nd appendData:[mark dataUsingEncoding:NSUTF8StringEncoding]];
                    if (tail) [nd appendData:tail];
                    [nd writeToFile:diLogPath() atomically:YES];
                    gDILogHandle = nil;   /* 旧句柄指向被替换的文件, 置空让下次重开 */
                } @catch (__unused NSException *e) {}
            }
        }
    }
}

// 运行日志: 写入 /var/mobile/Library/Logs/DriftIsland/driftisland.log (供"导出日志报告"抓取)
static void DLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void DLog(NSString *fmt, ...) {
    if (!logEnabled) return; // 日志开关关闭时不生成
    if (!diLogGate()) return;
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [diLogDF() stringFromDate:[NSDate date]], line];
    diLogWrite(out);
}

/* 现场日志: 不受 logEnabled 开关控制, 崩溃/进安全模式时也要留痕。
   固定写同一文件, 顶部标记 [现场], 排查时 grep "现场" 即可。 */
static void RLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void RLog(NSString *fmt, ...) {
    if (!diLogGate()) return;
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *out = [NSString stringWithFormat:@"[%@] [现场] %@\n", [diLogDF() stringFromDate:[NSDate date]], line];
    diLogWrite(out);
}
#define DI_STEP(fmt, ...) RLog(fmt, ##__VA_ARGS__)

/* ===== 3.0.21: 主线程停摆看门狗 + 阶段面包屑 =====
   iOS17 上"放歌就卡死、然后被 watchdog 注销"一直没有确凿证据(崩溃报告里查不到我们,
   卡死的那一分钟日志也没留下任何一行)。这里在后台线程每秒看一次主线程心跳, 连续 2 秒
   没跳就**直接追加一行**到同一个日志文件(绕过共享句柄和 25 行限流, 出问题也一定能写进去),
   并带上当时的阶段名 —— 下次日志里 [卡死] 那几行就是卡在哪一步的直接证据。 */
static volatile int64_t gDIMainTick = 0;
static volatile const char *gDIPhase = "启动";
static inline void diPhase(const char *p) { gDIPhase = p; }
static void diHangNote(NSString *msg) {
    @try {
        /* 3.0.23: 时间戳统一用本地时区(以前这里用 descriptionWithLocale 打的是 UTC,
           和前后行差 8 小时, 事后对时间线很容易错位)。 */
        static NSDateFormatter *df = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            df = [NSDateFormatter new];
            df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        });
        NSString *line = [NSString stringWithFormat:@"[%@] [卡死] %@\n",
                          [df stringFromDate:[NSDate date]], msg];
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        int fd = open(diLogPath().fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0666);
        if (fd >= 0) { ssize_t _ = write(fd, d.bytes, d.length); (void)_; close(fd); }
    } @catch (__unused NSException *e) {}
}
static void diStartWatchdog(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                    dispatch_get_main_queue());
        if (t) {
            dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0),
                                      200ull * NSEC_PER_MSEC, 40ull * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(t, ^{ gDIMainTick++; });
            dispatch_resume(t);
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int64_t last = -1;
            int stalled = 0, notes = 0;
            for (;;) {
                usleep(500 * 1000);
                int64_t tk = gDIMainTick;
                if (tk == last) stalled++; else { stalled = 0; last = tk; }
                if (stalled >= 4 && notes < 12) {   /* 连续 2 秒没心跳 */
                    notes++;
                    const volatile char *vp = gDIPhase;
                    NSString *ph = vp ? [NSString stringWithUTF8String:(const char *)vp] : @"?";
                    diHangNote([NSString stringWithFormat:@"主线程停摆约 %d 秒, 阶段=%@",
                                stalled / 2, ph ?: @"?"]);
                }
            }
        });
    });
}

/* 3.0.20: 自己的域同步一次就够了 —— refreshPrefs 一次要读几十个键, 以前每个键都
   Synchronize 一遍(几十次跨进程往返 + 落盘), iOS17 上叠加 cfprefsd 争用就会把
   主线程按住。现在 0.2 秒内只同步一次。 */
static void diPrefSyncOwn(void) {
    static CFTimeInterval ts = 0;
    static CFAbsoluteTime firstCall = 0;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    /* 3.0.27(iOS17 首装卡死): 441 实锤第一次装上/首次打开设置那一串
       [卡死] 阶段=prefs —— 设置进程首开在疯狂写偏好域, cfprefsd 被占住,
       我们主线程的 Synchronize 全部同步阻塞。注入后 15 秒内不做跨进程同步
       (走缓存默认值), 错开首开的写风暴; 之后恢复正常节流。 */
    if (firstCall == 0) firstCall = now;
    if (now - firstCall < 15.0) return;
    if (now - ts < 0.2) return;
    ts = now;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
}
static BOOL pBool(NSString *key, BOOL def) {
    diPrefSyncOwn();
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return v ? [v boolValue] : def;
}
static NSInteger pInt(NSString *key, NSInteger def) {
    diPrefSyncOwn();
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return v ? [v integerValue] : def;
}
static NSString *pString(NSString *key) {
    diPrefSyncOwn();
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
    return diSortedStrs(out);
}

static double pDouble(NSString *key, double def) {
    diPrefSyncOwn();
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return v ? [v doubleValue] : def;
}

/* 偏好缓存: 供 displayLink 每帧读取(不直接读 CFPreferences), 由 refreshPrefs 定期刷新 */
static BOOL enabled, smallOn = YES, expandOn = YES, spectrumOn, materialOn = YES;
/* 2.9.13: 录屏岛(加载视频 + 调大小)恢复 —— 2.9 误把整块删掉了, 用户要的只是
   删掉 2.8.95 新加的"左右两格帧率序列"那一套, 旧的录屏素材层必须留着。 */
static BOOL recOn;              /* 录屏素材开关(录屏时替换小岛背景) */
static NSInteger recIdx;        /* 录屏素材序号 */
static double recScale = 1.0;   /* 录屏素材大小(绕自身中心缩放, 1.0 = 铺满矩形) */
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
/* ===== 2.7.0: 换壁纸 (png/jpg 静态图 或 mp4 视频, 浅色/深色两套) ===== */
/* 2.7.26: 歌词岛左右帧率(2.7.0 被整段删除, 设置页开关因此失效 —— 现在补回)
   2.8.12: 歌词岛回归, 左右两层 + 开关恢复(默认关, 见 refreshPrefs 里的说明)
   左=专辑位 side 0, 键 smallAnimFolder 与 mini 系列;
   右=音频位 side 1, 键 miniAudioFolder 与 miniAudio 系列。 */
static double miniScaleBase = -5, miniOffsetXBase = -14;
static BOOL miniAnimOn = NO;           /* 2.8.12: 左侧专辑帧率(歌词岛页「启用动画」) */
static double miniFPS = 50, miniScale = 0, miniOffsetX, miniOffsetY;
static BOOL miniAudioOn = NO;          /* 2.8.12: 右侧音频帧率(歌词岛页「启用动画」) */
static double miniAudioFPS = 50, miniAudioScale = 0, miniAudioOffsetX, miniAudioOffsetY;
static NSString *smallAnimFolder;      // 左侧(mini)素材文件夹
static NSString *miniAudioFolder;      // 右侧音频素材独立键

static BOOL wpOn = NO;                 /* 启用壁纸 */
static BOOL gCCOverlayHooked;          /* 2.7.27: overlay 路径已成立 → MTMaterialView 旧路径让位 */
static void diCCInstallOverlayHook(void);   /* 2.8.41: 前置声明(prefsChanged/启动时补装) */
static void diCCInstallLayoutHook(void);    /* 2.8.42: 前置声明(overlay 失败退回旧路径) */
static void diCCInstallScrollHook(void);    /* 2.8.43: 前置声明(overlay 装好后压制滚动区白底) */
static void diCCTameScrollBackdrop(UIView *sv);   /* 2.8.46: 前置声明(layout 时也跑压制) */
static NSString *wpLightAsset;         /* 2.7.32: 壁纸改成**单素材**, 这是唯一生效的键 */
static NSString *wpDarkAsset;          /* 旧"深色"键, 只在新键为空时兜底, UI 已移除 */
static BOOL wpFollowDark = YES;        /* 旧"跟随深色", 不再参与控制中心判定 */
static BOOL wpLoopOn = NO;             /* 2.7.32: 循环播放(轮播目录下全部素材) */
static NSInteger wpBlur = 0;           /* 2.7.32: 背景模糊 0~100(0=不模糊, 100=纯透明) */
static BOOL wpMuted = YES;             /* 视频静音(旧键, 保留兼容) */
static NSString *diWallpaperResolveAny(NSString *rel);   /* 2.7.32 前向声明(实现在壁纸章节) */
static BOOL ccSoundOn = NO;            /* 2.7.28: 控制中心视频出声(ambient 混入, 不打断音乐) */
static BOOL ccLongPressOn = YES;       /* 2.7.28: 控制中心空白处长按换素材 */
/* 2.7.1: 去掉"填充位置"参数 —— 素材一律铺满整个控制中心背景 */
static int smallEdgeStyle = 0;         /* 2.2.67: 流光风格 0~5, 见 DIEdgeStyle */
/* 2.2.6: 岛上通知样式 —— 文字颜色自定义 + 通知岛不使用视频背景 */
static BOOL notifyColorOn, notifyBgOff;
static BOOL gThemeOn, gThemeDark;   /* 2.9.28: 模拟系统深/浅色(0=light 1=dark) */
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
/* 2.8.8: 锁屏通知/播放器发光 —— CALayer 的 shadow 即外发光:
   不透明发光色 + offset(0,0) + 用户半径, 光从卡片边缘均匀散出 */
static BOOL lkGlowOn;
static double lkGlowR = 10.0;
static UIColor *lkGlowColor;
static NSArray<UIColor *> *lkGlowColors;   /* 多色呼吸(与阴影/边框同一套动画) */
static char kGlowSig;   /* 2.8.9: 记录当前发光色表, 呼吸动画只在色表变了才重启 */
/* 2.8.35: 背景边框 —— 新键 lkFrameOn/lkFrameW/lkFrameHex 独立开关,
   刷新时镜像赋值给 lkBd* 全量复用底包边框绘制代码(2.3.0 移除功能时
   绘制整段保留, 只是 lkBdOn 恒 NO), 底包代码零改动 */
static BOOL lkFrameOn;
static double lkFrameW = 3.0;
static UIColor *lkFrameColor;
static NSArray<UIColor *> *lkFrameColors;
static char kBdSig;   /* 2.8.36: 边框色表签名, 呼吸动画只在色表变了才重启 */

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
/* ===== 2.8.31: 隐藏药丸(rascalblackpill 移植, 总开关下方独立开关) ===== */
static BOOL hideBlackPillOn = NO; // 开=摘除灵动岛两类黑层: HDR 增益图(_SBGainMapView) + 展开态 platter(MTMaterialView)
void diGainRestoreAll(void);
static void diGainInstallHook(void);
static void diGainTriggerVisible(void);
static void diGainScanAperture(void);
static BOOL gDIGainScanForce;   /* 3.0.25: 拨开关的那次扫描强制立即跑(定义在扫描函数前) */
static CFAbsoluteTime gVolumeUntil; // 2.9.12: 音量变化后 4 秒"我们让位"窗口(见 syncFrameToHost)
static BOOL gVolHUDActive;            // 2.9.12: 音量 HUD 窗口是否在屏(仅供日志, 不参与任何写入)
static id gVolumeObserver; // NSNotificationCenter 观察者 token: 必须持有否则观察者被释放收不到通知
static NSInteger smallIdx, expandIdx;
/* 频谱帧率动画参数 */
static double animFPS = 50, animScale = 1, animOffsetX, animOffsetY;
static NSString *animFolder; // 选中的素材文件夹名(帧率素材目录下的子文件夹)

// 帧图缓存: 序列帧可能几百张, NSCache 自动回收
/* 2.6.39: 帧目录缓存 + 目录整体签名(文件名+修改时间)。
   之前只有 2 秒 TTL, 且 gFramesDirty 是"任一次查询就清零"的全局标志 ——
   小岛左右两侧、展开岛同时查的时候, 只要有人先查了一次, 标志就被吃掉,
   换了素材也不会重扫, 一直用旧的那份(日志里表现为"改了素材没反应")。
   这里改成: 每个(目录键)各自记 signature, 文件真有变化才重扫。 */
static NSString *diDirSignature(NSString *dir) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *items = [[fm contentsOfDirectoryAtPath:dir error:NULL] sortedArrayUsingSelector:@selector(compare:)];
    if (!items.count) return @"";
    NSMutableString *sig = [NSMutableString stringWithFormat:@"%lu", (unsigned long)items.count];
    NSInteger n = 0;
    for (NSString *it in items) {
        NSDictionary *at = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:it] error:NULL];
        if (!at) continue;
        [sig appendFormat:@"|%@:%.0f", it, [at[NSFileModificationDate] timeIntervalSince1970]];
        if (++n >= 40) break;      /* 只取前 40 个, 够判断变没变 */
    }
    return sig;
}

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
static NSArray<NSString *> *framePathsFor(NSString *folderSel); // 前置: framePathsImpl 分目录缓存
static NSArray<NSString *> *framePaths(void);
/* 序列帧列表(2秒TTL, 按文件夹分别缓存): 2.2.45 原版 framePathsFor */
static NSArray<NSString *> *framePathsImpl(NSString *folderSel) {
    static NSMutableDictionary<NSString *, NSArray *> *cache;
    static NSMutableDictionary<NSString *, NSNumber *> *times;
    static NSMutableDictionary<NSString *, NSString *> *sigs;
    static NSMutableDictionary<NSString *, NSNumber *> *sigTs;   /* 2.8.22: 每个键上次算签名的时间 */
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary new]; times = [NSMutableDictionary new];
        sigs = [NSMutableDictionary new]; sigTs = [NSMutableDictionary new];
    });
    NSString *ck = folderSel.length ? folderSel : @"(root)";
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSString *dirForSig = folderSel.length ? [kFrameDir stringByAppendingPathComponent:folderSel] : kFrameDir;
    /* 2.8.22 功耗: 目录签名(列目录 + 最多 40 次 stat)以前每次查询都重算 ——
       stepMini 每帧调 framePathsFor, 两层素材 60fps 就是每秒上万次系统调用,
       放歌卡顿掉帧的头号元凶。现在: 只有 gFramesDirty(换素材/偏好变更)或
       距上次算签名 >1s 才重算; 文件真变了才丢列表缓存。 */
    if (gFramesDirty || now - [sigTs[ck] doubleValue] > 2.0) {
        sigTs[ck] = @(now);
        NSString *sig = diDirSignature(dirForSig);
        BOOL changed = ![sigs[ck] isEqualToString:sig];
        sigs[ck] = sig;
        if (gFramesDirty) gFramesDirty = NO;
        if (changed || (cache[ck] && now - [times[ck] doubleValue] > 8.0)) {
            [cache removeObjectForKey:ck];
        }
    }
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
        else { base = [kFrameDir stringByAppendingPathComponent:[diSortedStrs(dirs) firstObject]]; }
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
__attribute__((unused)) static NSArray<NSString *> *framePathsFor(NSString *folderSel) { return framePathsImpl(folderSel); }

// 素材列表缓存(2秒TTL): displayLink 每帧调用, 不能每次扫描目录
static NSArray<NSString *> *cachedMaterials(void) {
    static NSArray *l; static CFAbsoluteTime t;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!l || now - t > 2.0) { l = materialList(); t = now; }
    return l;
}

/* 2.9.13: 录屏素材列表(2秒TTL, 与 cachedMaterials 同款缓存节奏) */
static NSArray<NSString *> *cachedRecMaterials(void) {
    static NSArray *l; static CFAbsoluteTime t;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!l || now - t > 2.0) {
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kMaterialDir error:NULL] ?: @[];
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *f in files) {
            NSString *ext = f.pathExtension.lowercaseString;
            if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [ext isEqualToString:@"m4v"])
                [out addObject:f];
        }
        out = [diSortedStrs(out) mutableCopy];
        l = out; t = now;
    }
    return l;
}

/* 2.2.53: 灵动岛宿主表 */
/* 2.2.53: 灵动岛宿主表 —— 所有挂过的 SAUIElementView 都记在这里 */
static NSHashTable *hostTable = nil;

__attribute__((unused)) static BOOL diOnScreen(UIView *v) {
    if (!v || v.hidden || v.alpha < 0.02 || v.window == nil) return NO;
    CGRect f = [v.superview convertRect:v.frame toView:v.window];
    return !CGRectIsEmpty(f) && CGRectIntersectsRect(f, v.window.bounds);
}

/* ===== 2.9.13: 录屏岛(旧版录屏素材层)完整恢复 =====
   2.9 当时删的是"2.8.95 新加的录屏岛左右帧率图层", 结果把更早的录屏素材层
   (recOn/recIndex/recScale, 贴到录屏指示岛圆点那一格播视频、可调大小)也一起删了。
   这里按 2.8.101 原样恢复这一套; 2.8.95 的帧率序列(左右两格)不再带回。

   实测结论(2.2.40 起一直沿用): 录屏时 SpringBoard 会出现唯一的"方形指示岛",
   约 39×39(宽高差 < 3), 岛内有两个 accessory(左=录屏圆点, 右=倒计时"321"),
   素材应贴到**目标 accessory 的真实 frame** 上, 而不是按"岛宽-岛高"自己算圆。 */
static BOOL diIsScreenRecording(void) {
    /* 三条来源: UIScreen.isCaptured / SBRecordingIndicatorWindow / 指示器子视图类名。
       SpringBoard 自己就是录屏发起方, 有些系统上它自己的 isCaptured 是 NO。 */
    UIScreen *ms = [UIScreen mainScreen];
    if ([ms respondsToSelector:@selector(isCaptured)] && ms.isCaptured) return YES;
    static CFAbsoluteTime t; static BOOL v;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - t < 0.5) return v;
    t = now; v = NO;
    Class iw = NSClassFromString(@"SBRecordingIndicatorWindow");
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (iw && [w isKindOfClass:iw]) {
                if (!w.hidden && w.alpha > 0.05) { v = YES; break; }
                continue;
            }
            for (UIView *sub in w.subviews) {
                NSString *cn = NSStringFromClass(sub.class).lowercaseString;
                if ([cn containsString:@"recordingindicator"] || [cn containsString:@"recordingdot"]
                    || [cn containsString:@"recordingcountdown"] || [cn containsString:@"recordingcapsule"]) {
                    v = YES; break;
                }
            }
            if (v) break;
        }
        if (v) break;
    }
    return v;
}

/* 找方形指示岛(录屏岛)。优先取真正在屏上的那颗。 */
static UIView *diRecIslandHost(void) {
    if (!hostTable) return nil;
    UIView *found = nil, *visibleFound = nil;
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

/* 在指示岛里找 accessory 容器(_SAUIProvidedViewContainerView), 按 x 排序取最左(录屏圆点位)。
   返回素材应贴的矩形(相对 island 坐标系); 找不到 accessory 时按实测比例回退。
   2.9.16: 完全回到 2.8.75/2.8.78 的做法(不优先 leadingView), 与旧版一致。 */
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
    return [kMaterialDir stringByAppendingPathComponent:rlist[ridx]];
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
    /* 2.9.28: 模拟系统外观 —— 开=深色, 关=浅色; 总开关关=跟随系统 */
    gThemeOn = pBool(@"themeMasterOn", NO);
    gThemeDark = pBool(@"themeForceDark", NO);
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
    /* 2.8.8: 发光(默认关, 颜色不填就用天蓝) */
    lkGlowOn = pBool(@"lkGlowOn", NO);
    lkGlowR = pDouble(@"lkGlowR", 8);
    if (lkGlowR < 0) lkGlowR = 0; if (lkGlowR > 24) lkGlowR = 24;   /* 2.8.9: 上限 40→24, 再大就外溢到卡片外一大片 */
    lkGlowColors = diColorList(pString(@"lkGlowHex"));
    lkGlowColor = lkGlowColors.firstObject ?: [UIColor colorWithRed:0.0 green:0.68 blue:0.96 alpha:1.0];
    /* 2.8.35: 背景边框 —— 读新键, 再镜像给 lkBd*。
       必须放在上面 `lkBdOn = NO`(2.3.0 恒关)之后执行, 才覆盖得掉。
       镜像之后 diStylePlatter 的边框分支、applyLockStyle 的门闸、
       每秒自愈 tick 全部自动生效, 无需改底包任何一行。 */
    lkFrameOn = pBool(@"lkFrameOn", NO);
    lkFrameW = pDouble(@"lkFrameW", 3.0);
    if (lkFrameW < 0) lkFrameW = 0; if (lkFrameW > 12) lkFrameW = 12;
    lkFrameColors = diColorList(pString(@"lkFrameHex"));
    lkFrameColor = lkFrameColors.firstObject ?: [UIColor colorWithRed:0.0 green:0.68 blue:0.96 alpha:1.0];
    lkBdOn = lkFrameOn;
    lkBdW = lkFrameW;
    lkBdColors = lkFrameColors;
    lkBdColor = lkFrameColor;
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
    /* 2.9.13: 录屏素材(独立的 recIndex/recScale, 目录与主素材相同) */
    recOn = pBool(@"recOn", NO);
    recIdx = pInt(@"recIndex", 0);
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
    /* 2.7.26: 歌词岛左右帧率参数(2.7.0 误删, 补回 —— 设置页开关靠这些才生效)
       2.8.12: 歌词岛回归, 恢复从偏好读取; 默认关(2.8.7 教训: 无 UI 时默认开
       会导致看视频时岛上冒素材), 想显示素材到「歌词岛」页打开「启用动画」 */
    smallAnimFolder = pString(@"smallAnimFolder");
    miniAudioFolder = pString(@"miniAudioFolder");
    miniAnimOn = pBool(@"miniAnimOn", NO);
    miniFPS = pDouble(@"miniFPS", 50);
    if (miniFPS < 10) miniFPS = 10; if (miniFPS > 200) miniFPS = 200;
    miniScale = pDouble(@"miniScaleAdj", 0) + miniScaleBase;
    if (miniScale < -30) miniScale = -30; if (miniScale > 30) miniScale = 30;
    miniOffsetX = pDouble(@"miniOffsetX", 0) + miniOffsetXBase;
    if (miniOffsetX < -40) miniOffsetX = -40; if (miniOffsetX > 40) miniOffsetX = 40;
    miniOffsetY = pDouble(@"miniOffsetY", 0);
    if (miniOffsetY < -20) miniOffsetY = -20; if (miniOffsetY > 20) miniOffsetY = 20;
    miniAudioOn = pBool(@"miniAudioOn", NO);   /* 2.8.12: 歌词岛回归, 恢复读取(默认关) */
    miniAudioFPS = pDouble(@"miniAudioFPS", 50);
    if (miniAudioFPS < 10) miniAudioFPS = 10; if (miniAudioFPS > 200) miniAudioFPS = 200;
    miniAudioScale = pDouble(@"miniAudioScaleAdj", 0) + miniScaleBase;
    if (miniAudioScale < -30) miniAudioScale = -30; if (miniAudioScale > 30) miniAudioScale = 30;
    miniAudioOffsetX = pDouble(@"miniAudioOffsetX", 0) - miniOffsetXBase;
    if (miniAudioOffsetX < -40) miniAudioOffsetX = -40; if (miniAudioOffsetX > 40) miniAudioOffsetX = 40;
    miniAudioOffsetY = pDouble(@"miniAudioOffsetY", 0);
    if (miniAudioOffsetY < -20) miniAudioOffsetY = -20; if (miniAudioOffsetY > 20) miniAudioOffsetY = 20;
    /* 2.7.0: 换壁纸 */
    wpOn = pBool(@"wpOn", NO);   /* 2.8.41: 控制中心壁纸恢复(用户要求, 单素材=浅色键) */
    wpLightAsset = pString(@"wpLightAsset");
    wpDarkAsset = pString(@"wpDarkAsset");
    wpFollowDark = pBool(@"wpFollowDark", YES);
    wpMuted = pBool(@"wpMuted", YES);
    /* 2.7.28: 控制中心声音 / 长按换素材 */
    ccSoundOn = pBool(@"ccSoundOn", NO);
    ccLongPressOn = pBool(@"ccLongPressOn", YES);
    /* 2.7.32: 循环播放 / 背景模糊 */
    wpLoopOn = pBool(@"wpLoopOn", NO);
    wpBlur = (NSInteger)pInt(@"wpBlur", 0);
    if (wpBlur < 0) wpBlur = 0; if (wpBlur > 100) wpBlur = 100;
    /* 2.6.3: 遮罩(贴合左侧专辑) */
    maskOn = pBool(@"maskOn", NO);
    maskRotateOn = pBool(@"maskRotateOn", NO);
    maskRotateReverse = pBool(@"maskRotateReverse", NO);
    maskRotateSpeed = pDouble(@"maskRotateSpeed", 45.0);
    if (maskRotateSpeed < -720) maskRotateSpeed = -720; if (maskRotateSpeed > 720) maskRotateSpeed = 720;
    /* 2.8.41: 遮罩大小新刻度 —— 用户旧设定 115 为新基准 100, 滑杆 50~150, 实际缩放 = 显示值 × 1.15 */
    {
        double shown = pDouble(@"diAlbumMaskScale2", -1.0);
        if (shown < 0) shown = pDouble(@"diAlbumMaskScale", 115.0) / 1.15;   /* 旧键迁移: 115 → 100 */
        if (shown < 50.0) shown = 50.0;
        if (shown > 150.0) shown = 150.0;
        maskScale = shown * 1.15;
    }
    maskAnimFolder = pString(@"maskAnimFolder");
    /* 2.8.85: 展开定义(展开岛歌词/歌名的位置与大小) */
    expandTextOn = pBool(@"expandTextOn", YES);   /* 2.8.86: 默认开, 0/100% 时无任何视觉变化 */
    /* 2.8.92: 键换成 X2/Y2(含义是相对基准的增量) —— 老键里存的是 120/45 绝对值,
       直接沿用会变成 120+120; 新键缺省 0, 正好落在用户调好的那个位置。 */
    expandTextX = DI_EXP_TEXT_BASE_X + pDouble(@"expandTextX2", 0.0);
    expandTextY = DI_EXP_TEXT_BASE_Y + pDouble(@"expandTextY2", 0.0);
    expandTextScale = pDouble(@"expandTextScale", 100.0);
    if (expandTextX < DI_EXP_TEXT_BASE_X - 200) expandTextX = DI_EXP_TEXT_BASE_X - 200;
    if (expandTextX > DI_EXP_TEXT_BASE_X + 200) expandTextX = DI_EXP_TEXT_BASE_X + 200;
    if (expandTextY < DI_EXP_TEXT_BASE_Y - 120) expandTextY = DI_EXP_TEXT_BASE_Y - 120;
    if (expandTextY > DI_EXP_TEXT_BASE_Y + 120) expandTextY = DI_EXP_TEXT_BASE_Y + 120;
    if (expandTextScale < 50) expandTextScale = 50; if (expandTextScale > 200) expandTextScale = 200;
    hideRouteOn = pBool(@"hideRouteOn", NO);      /* 2.8.93: 隐藏投送 */
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
    /* 2.8.31: 隐藏药丸 —— 总开关下方独立开关(默认关)。
       开: 装 _SBGainMapView hook、主动扫一遍在屏黑块、再触发一次布局;
       关(或总开关关): 把所有摘除的黑块原位插回, 恢复系统原样。
       注意: refreshPrefs 被 0.5s tick 反复调用, 所以只在开关状态**变化时**
       触发一次( hook 自身会在系统每次布局时补摘新出现的黑块)。
       2.8.32: 补「主动扫描」—— 2.8.31 只靠 layoutIfNeeded, 而视图没有待重排
       需求时它是 no-op(301 实测: 静态音乐岛下开关开了黑块不动)。 */
    hideBlackPillOn = pBool(@"hideBlackPill", NO);
    {
        static BOOL pillWantLast = NO, pillHasLast = NO;
        BOOL wantPill = enabled && hideBlackPillOn;
        if (!pillHasLast || wantPill != pillWantLast) {
            pillHasLast = YES; pillWantLast = wantPill;
            /* 这条不受日志开关控制: 开关每次变化都留痕, 现场一眼确认有没有生效 */
            RLog(@"隐藏药丸: %@ (总开关=%@)", wantPill ? @"开" : @"关", enabled ? @"开" : @"关");
            dispatch_async(dispatch_get_main_queue(), ^{
                diGainInstallHook();
                if (wantPill) { gDIGainScanForce = YES; diGainScanAperture(); diGainTriggerVisible(); }
                else diGainRestoreAll();
            });
        } else if (wantPill) {
            /* 2.8.33: 开关开着期间每 10s 补扫一次(扫描内含视图树 dump, 自身节流)。
               两个用处: ① hook 偶发没兜住的新建黑层自动补摘;
               ② 用户任何时候抓日志都能拿到视图树 dump —— 黑圈没去干净时,
               日志里直接看到黑圈的类名/尺寸, 下一版精准处理。 */
            static CFAbsoluteTime lastScan;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - lastScan > 15.0) {
                lastScan = now;
                dispatch_async(dispatch_get_main_queue(), ^{ diGainScanAperture(); });
            }
        }
    }
}

#pragma mark - 视频覆盖视图

@interface DIVideoView : UIView
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, strong) CADisplayLink *syncLink;
@property (nonatomic, assign) BOOL expandedLayer; // YES=展开层(播展开素材), NO=小岛层
@property (nonatomic, assign) BOOL edgeLayer;   // 2.2.59: 边框流光层(自己管几何, 不参与主同步)
@property (nonatomic, assign) BOOL circleLayer; // 2.9.13: 录屏圆圈层(贴录屏指示岛圆点那一格, 不做整岛同步)
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
/* 2.7.5 附注: 上面这套"剥音轨 + muted + Ambient/MixWithOthers + 不 setActive"的组合,
   结果是**视频本来就没有声音可放** —— 这是设计如此:
     · 用户要的是"放视频不要影响其他音频", 岛的视频一直是这样, 控制中心壁纸视频同理;
     · "视频静音"开关因此没有实际作用, 2.7.5 已从控制中心页移除, 免得用户以为打开就有声。 */
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
static char kHostSeenT;        // 2.8.22: 宿主首次出现的时间戳(CFAbsoluteTime), "最新岛优先拿背景视频"用它
static char kCapIsNotif;       // 前向声明: 胶囊容器是否判定为通知岛(NSNumber)
static BOOL diIsVolumeIsland(UIView *host);     // 前向声明: 音量岛识别(独立于 hideNoMusic 开关)
static char kVolOnce;  // 2.6.28: 每层独立记账"曾在音量岛里", 用于回落立即撤层

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
    /* 2.6.28: iOS16 音量岛内部视图类名里根本没有 "olume"(219 日志 0 命中, 所以音量条一直
       被视频层盖住缩不回去)。判据改成三条并集:
         ① 类名含 Volume / Slider / HUD  (老系统/其他版本)
         ② 树里出现 UISlider / MPVolumeView / 圆点滑条控件
         ③ 几何特征: 岛内有 ≥2 个"细长横条"(音量/亮度档位), 或者细横条宽度比基线
            缩短了 ≥15%(2.6.30 新增: 缩回过程本身就是要拦的时机)
       2.6.30 关键修正: 219/220 日志里 0 命中说明连"细横条"都没抓到 —— 因为 iOS16 的
       音量档位条宽度会随音量变化, 静态阈值(>=60pt)在低音量时抓不到。现在改成:
       先记一个"最宽细横条"基线, 之后只要出现比基线短 15% 以上的细横条, 就认定
       这是"正在缩回的音量条" → 立刻禁挂。 */
    static CGFloat gThinMaxW = 0;   /* 本宿主历史上见过的最宽细横条 */
    NSInteger thinBars = 0;
    CGFloat thinMaxW = 0, thinMinH = 99;
    while (stack.count && guard++ < 600) { // 深度防御: 节点数上限防异常树
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0];
        NSString *cn = NSStringFromClass(v.class);
        if ([cn containsString:@"olume"] || [cn containsString:@"Volume"] ||
            [cn containsString:@"Slider"] || [cn containsString:@"HUD"]) { found = YES; break; }
        if ([v isKindOfClass:UISlider.class]) { found = YES; break; }
        if ([cn containsString:@"MPVolume"]) { found = YES; break; }
        CGSize b = v.bounds.size;
        if (b.height >= 1.5 && b.height <= 8.0 && b.width >= 20.0) {
            thinBars++;
            if (b.width > thinMaxW) thinMaxW = b.width;
            if (b.height < thinMinH) thinMinH = b.height;
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    if (!found && thinBars >= 2) found = YES;   /* 多条细横条 = 音量/亮度档位条 */
    /* 2.6.30: 单条细横条 + 宽度明显缩水 → 判定为正在缩回的音量条 */
    if (!found && thinBars >= 1) {
        if (thinMaxW > gThinMaxW) gThinMaxW = thinMaxW;
        if (gThinMaxW > 60.0 && thinMaxW < gThinMaxW * 0.85) {
            found = YES;
            DLog(@"音量岛识别(缩回): 细横条 %.0f→%.0fpt 缩水%.0f%% → 禁挂视频",
                 gThinMaxW, thinMaxW, (1.0 - thinMaxW / gThinMaxW) * 100);
        }
    }
    if (found && !cachedResult) DLog(@"音量岛识别: 宿主%@ %.0fx%.0f 细横条=%ld → 禁挂视频",
                                     NSStringFromClass(host.class), host.bounds.size.width,
                                     host.bounds.size.height, (long)thinBars);
    wHost = host; cachedResult = found; tScan = now;
    return found;
}

/* ===== 2.9.11: 音量条(HUD)收不掉 =====
   iOS16 的音量 HUD 不是"岛里的一个控件", 而是一个独立的 HUD 窗口(内部挂着
   CCUIContentModuleContentContainerView + MTMaterialView)。所以上面那套"在岛容器里
   找音量控件"的判据永远命中不了 —— 视频层照旧每帧贴着岛做布局, 音量条就缩不回去。
   做法只有一条: 按音量键之后的几秒内, 我们自己的视频层全部让位(见 syncFrameToHost),
   岛恢复成系统内容, 系统自己按原生节奏淡出音量条。
   2.9.12 更正: 绝不能去改 HUD 窗口的 alpha(2.9.11 干过, 结果窗口复用时整块看不见,
   而且瞬间归零=没有淡出动画)。这里的 diHUDWindows 只用于"看一眼", 一个像素都不碰。 */
static NSArray<UIWindow *> *diHUDWindows(void) {
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
    @try {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (![w isKindOfClass:UIWindow.class] || w.hidden) continue;
                NSString *cn = NSStringFromClass(w.class);
                /* 2.9.12: 只按窗口类名认 HUD。2.9.11 那条"窗口里有细高 ContentModule 就当 HUD"
                   的猜测太宽 —— 控制中心/展开的通知容器都长这样, 会把它误判成音量条,
                   进而连累小岛素材被无谓隐藏(用户反馈"有时候显示不了了")。 */
                if ([cn rangeOfString:@"HUD"].location == NSNotFound &&
                    [cn rangeOfString:@"Volume"].location == NSNotFound) continue;
                if ([cn containsString:@"CoverSheet"]) continue;
            }
        }
    } @catch (__unused NSException *e) {}
    return out;
}
/* 诊断: 按音量键那一刻把所有窗口列一遍 —— 下一份日志就能确认 HUD 到底在哪个窗口里 */
static void diDumpWindowsForVolume(void) {
    NSMutableString *s = [NSMutableString string];
    int n = 0;
    @try {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (n++ >= 12) break;
                [s appendFormat:@"%@(%.0fx%.0f,a%.2f%@,L%.0f) ",
                 NSStringFromClass(w.class), w.frame.size.width, w.frame.size.height,
                 (double)w.alpha, w.hidden ? @",H" : @"", (double)w.windowLevel];
            }
        }
    } @catch (__unused NSException *e) {}
    RLog(@"[音量条] 窗口清单: %@", s);
}

@implementation DIVideoView {
    NSInteger _missCount; // 连续不可见帧计数, 攒够才暂停 displayLink(防瞬时抖动误停)
    NSInteger _idleFrames; // 2.8.4: 几何静止帧计数, 攒够把贴合循环降到 30fps 省电
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
    if (!host || host.window == nil) {
        _syncLink.paused = YES;
        /* 2.8.48: 未挂岛(含解锁预载的待命层)也必须停播 —— 否则 loadVideo 里的
           延迟补播会让播放器空转解码, 白耗电。 */
        if (self.player.timeControlStatus != AVPlayerTimeControlStatusPaused) [self.player pause];
        return;
    }
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
    /* 2.9.13: 录屏素材层 —— 挂到**录屏指示岛**(方形 ~39×39)里, 贴左侧圆点 accessory
       的真实矩形。判据: 开关开 + 系统在录屏 + 宿主链上确实存在方形指示岛。 */
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
        /* 2.9.16 诊断: 只在 show 翻转时打一条, 用来确认"挂上了但没显示"卡在哪一步 */
        {
            static int sPrevShow = -1; static CFAbsoluteTime sT;
            CFAbsoluteTime n = CFAbsoluteTimeGetCurrent();
            if ((int)show != sPrevShow && n - sT > 0.5) {
                sT = n; sPrevShow = (int)show;
                RLog(@"[录屏] show=%d 岛=%@ slot=%@ acc=%@ 本层=%@ hidden=%d 原生可见=%d 播放器=%ld",
                     (int)show, island ? NSStringFromClass(island.class) : @"无",
                     NSStringFromCGRect(slot),
                     acc ? NSStringFromClass(acc.class) : @"无",
                     NSStringFromCGRect(self.frame), (int)self.hidden,
                     acc.layer ? (int)!acc.layer.isHidden : -1,
                     (long)self.player.timeControlStatus);
            }
        }

        /* 2.9.17: 不再隐藏原生指示层 —— 361 反馈"系统的东西不显示了"。
           素材层只是垫底的背景图层(insertSubview atIndex:0), 原生圆点/倒计时
           照常画在素材上面, 与音乐岛"素材只当背景、不碰原生"同一思路。 */

        if (show) {
            /* 素材大小直接算 frame(不用 layer.transform —— AVPlayerLayer 会在设 frame 时
               重写 transform, 之前那样调完就还原)。绕 slot 中心按 recScale 缩放。 */
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
            if (want && ![want isEqualToString:self.currentPath]) {
                [self loadVideo:want];
                DLog(@"录屏素材: 加载 %@ (slot=%@)", want.lastPathComponent, NSStringFromCGRect(slot));
            }
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
    /* 2.8.4 功耗: 动态帧率 —— 岛静止 1 秒后贴合循环降到 30fps(省一半 CPU/功耗),
       几何一动(展开/收起/移动/动画中)立即回 60fps, 流畅性不受影响 */
    if (!CGRectEqualToRect(self.frame, b)) {
        self.frame = b;
        _idleFrames = 0;
        if (_syncLink.preferredFramesPerSecond != 60) _syncLink.preferredFramesPerSecond = 60;
    } else if (++_idleFrames > 60 && _syncLink.preferredFramesPerSecond != 30) {
        _syncLink.preferredFramesPerSecond = 30;   /* 60fps 下约 1 秒无几何变化 */
    }
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
       且连续 2 帧成立才显示(去掉 1 帧的过渡误差), 一旦不成立立即隐藏(无延时)。
       2.8.22: needShape 从"本岛是音乐岛 或 窗口里还有别的音乐岛"收紧成
       "本岛就是音乐岛"。旧写法的第二子句会把放歌时后出现的充电/人脸岛一起连坐
       —— 那些岛没有 407x488 内容层, 小岛背景视频被整层毙掉(292 反馈
       "人脸解锁 充电岛背景不显示")。过渡交接的抢占由选主逻辑负责, 不劳这道判官。 */
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
        BOOL needShape = (gMiniHost == host);
        if (needShape && !musicShape) {
            tMine = 0;
            if (!self.hidden) { self.hidden = YES; if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause]; }
            return;
        }
        if (needShape) {
            if (tMine == 0) tMine = CFAbsoluteTimeGetCurrent();
            else if (CFAbsoluteTimeGetCurrent() - tMine < 0.03) {   /* 需连续成立约 2 帧 */
                if (!self.hidden) { self.hidden = YES; if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause]; }
                return;
            }
        }
    }
    // 形态判定用呈现层高度: 动画收尾才越过阈值
    // 2.8.6 回退: 2.8.4 把 host.bounds 也纳入判定后, 充电/人脸解锁这类宿主模型
    // 尺寸偏高的岛被误判成"展开", 小岛素材层被隐藏(用户反馈: 充电/人脸/退 app
    // 背景都没了)。恢复只用呈现层高度 —— 切换流畅性的收益不值得这个误判。
    CGFloat ph = pl ? pl.bounds.size.height : host.bounds.size.height;
    BOOL expanded = ph > 60; // 小岛高约36, 展开高 51~223
    BOOL mine = (expanded == self.expandedLayer);
    NSString *want = mine ? materialPathFor(expanded) : nil;
    /* 2.6.28: 音量岛先于形态判定处理 —— 音量岛高度 52~72 会被 "ph>60" 误判成展开岛,
       之前小岛层压根走不到拦截分支(219 日志 "音量拦截" 0 次)。这里前置拦掉。
       2.6.30: 去掉 !diFindAudioLayer(host) 前置条件 —— 音量岛出现时音乐岛层可能
       还挂在树上(系统没拆), 旧的与运算直接把拦截整个短路掉, 这就是"音量条还是不缩回"
       的直接原因。现在无条件判定: 只要几何/类名像音量岛, 一律禁挂。 */
    if (diIsVolumeIsland(host)) {
        if (!self.hidden) { self.hidden = YES; DLog(@"音量岛: 撤掉视频层(本层%@)", self.expandedLayer ? @"展开" : @"小岛"); }
        if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause];
        objc_setAssociatedObject(self, &kVolOnce, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    /* 音量岛特征消失 → 本层立即撤掉并销毁(每层各自记账, 不与他人互清) */
    if ([objc_getAssociatedObject(self, &kVolOnce) boolValue]) {
        objc_setAssociatedObject(self, &kVolOnce, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!self.hidden) self.hidden = YES;
        if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause];
        DLog(@"音量岛回落: 撤掉视频层, 让音量条正常缩回");
        return;
    }
    if (want && !self.expandedLayer) {
        /* 2.6.30: 与开头拦截保持一致, 去掉 !isAudio 短路 */
        if (diIsVolumeIsland(host)) want = nil;
    }
    /* 2.9.12: 音量让位窗口 —— 按了音量键之后 4 秒内, 小岛层无条件让位。
       iOS16 的音量 HUD 是独立 HUD 窗口(挂在 CCUIContentModuleContentContainerView 下),
       diIsVolumeIsland 抓不到它。2.9.11 的让位条件是"宿主没有 CALayerHost 音频层",
       可是放歌时这个条件永远不成立 → 视频一直贴着岛 → 岛一直"有内容" → 音量条收不回。
       现在小岛层不看宿主, 直接退出, 岛恢复成纯系统内容, 系统自己按原生节奏淡出。
       展开层保持原判据(宿主无音频层才让位), 免得大岛按音量键时整块黑掉。
       判据每秒最多算一次(diFindAudioLayer 是 300 节点 BFS, 不能每帧跑)。 */
    {
        CFAbsoluteTime vn = CFAbsoluteTimeGetCurrent();
        if (gVolumeUntil > vn) {
            BOOL mustYield = !self.expandedLayer;
            if (!mustYield) {
                static CFAbsoluteTime tAud;
                static BOOL audOK;
                if (vn - tAud > 0.5) { tAud = vn; audOK = (diFindAudioLayer(host) != nil); }
                mustYield = !audOK;
            }
            if (mustYield) {
                if (!self.hidden) {
                    self.hidden = YES;
                    DLog(@"音量让位: 本层%@ 隐藏, 让音量条缩回", self.expandedLayer ? @"展开" : @"小岛");
                }
                if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause];
                return;
            }
        }
    }
    /* 无音乐隐藏开关: 开启且确认没有媒体活动时, 小岛层不显示视频(退出所有app后岛不再挂着视频)。
       判据: 音乐岛音频层(CALayerHost)存在 或 MediaRemote 报告在播 → 有媒体; 两者皆无 → 隐藏。
       (不依赖 mrQueryOK: 部分系统版本 MediaRemote 回调不可用, 靠音频层兜底) */
    if (want && !self.expandedLayer && hideNoMusic) {
        BOOL mediaActive = (diFindAudioLayer(host) != nil) || (mrQueryOK && musicPlaying);
        /* 2.8.48: 用户要求"解锁即加载, 不需要放歌触发" —— 已解锁即视为有素材活动;
           锁屏/息屏仍全停(gLocked=YES 时这里依旧隐藏), 功耗策略不变。 */
        if (!mediaActive && !gLocked) mediaActive = YES;
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

#pragma mark - 2.7.0 换壁纸视图

/* DIWallpaperView —— 铺在 SpringBoard 图标层下方的一整屏背景。
   · 静态素材(png/jpg): UIImageView + ScaleAspectFill
   · 视频素材(mp4): AVPlayerLayer + AVPlayerLooper 循环, 音轨剥掉(不碰音频会话)
   · 浅色/深色: 由 traitCollection 决定用哪一套, 换素材/换外观都即时生效, 不注销
   层级: 直接挂到 SBRootFolderView 的最底层(sendSubviewToBack)。这样图标、Dock、
   状态栏全在它上面, 它就是"真壁纸"。 */
/* 2.7.13: 磨砂层组名路线的前置状态 —— 壁纸类要在很前面判断这条路通不通 */
static BOOL gCCGroupHooked;
/* 2.7.23: 本机 UIBlurEffect 没有组名 setter(iOS 16 真机实测) → 整条"组名采样"
   路线永久关闭, 不再每秒重试。一次性判定, 省掉每秒 2 次日志 + 2 次对象分配。 */
static BOOL gCCGroupUnavailable;
static BOOL gCCWindowSeen;   /* 2.7.14: 控制中心窗口上一拍是否可见(诊断节流用) */
static int  gCCGeneration;   /* 2.7.19: 控制中心"每展开一次"递增, 用于诊断只打一遍 */
static BOOL diInFrameAttachLogged; /* 2.7.20: 帧内挂载成功日志只记一次 */
/* 2.7.22: 启动静默期起点。hook 内部据此在 SpringBoard 刚起来时完全不参与
   (2.7.20 就是启动早期在布局热路径里初始化 AVFoundation 导致卡白苹果)。 */
static CFAbsoluteTime gDiLaunchTime;
static id diCCHookedGroupGetter(id self, SEL _cmd);
static void diCCHookedGroupSetter(id self, SEL _cmd, id name);

@interface DIWallpaperView : UIView
+ (instancetype)shared;            /* 单例: 全 SpringBoard 只有一层 */
- (void)reload;                    /* 重读偏好 + 重扫素材, 立刻切图/换片 */
- (void)attachIfNeeded;            /* 找到 SBRootFolderView 就挂上去, 找不到就等下一次 */
- (void)refreshGeometry;           /* 跟着屏幕尺寸/旋转对齐 */
+ (NSString *)resolveCurrentPath;  /* 2.7.13: 按当前外观/偏好算出该用哪张壁纸 */
- (void)diWatchSuperviewOf:(UIView *)v;  /* 2.7.9: 盯住挂载父级, 它一被移出屏幕立刻撤壁纸 */
- (void)diWatchPresentation:(UIView *)v; /* 2.7.12: 盯住父级的显示条件(hidden/alpha), 跟随系统转场 */
- (void)diAttachToBackdrop:(UIView *)mv; /* 2.7.20: 帧内挂载(布局回调里直接挂) */
@end

/* 2.7.28: 抽出"扫某个根目录"的版本 —— 浅色/深色各扫自己的子目录要用。
   原来的 diWallpaperList 退化成"扫总目录", 行为和之前完全一致(向下钻 3 层)。 */
static NSArray<NSString *> *diWallpaperListIn(NSString *base, NSInteger maxDepth) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (!base.length) return out;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:base isDirectory:&isDir] || !isDir) return out;
    NSMutableArray<NSString *> *queue = [NSMutableArray arrayWithObject:@""];
    int guard = 0;
    while (queue.count && guard++ < 200) {
        NSString *rel = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSInteger depth = rel.length ? ([rel componentsSeparatedByString:@"/"].count) : 0;
        NSString *full = rel.length ? [base stringByAppendingPathComponent:rel] : base;
        for (NSString *name in diSortedStrs([fm contentsOfDirectoryAtPath:full error:NULL])) {
            if (![name isKindOfClass:NSString.class] || [name hasPrefix:@"."]) continue;
            NSString *childRel = rel.length ? [rel stringByAppendingPathComponent:name] : name;
            NSString *childFull = [base stringByAppendingPathComponent:childRel];
            BOOL d = NO;
            if (![fm fileExistsAtPath:childFull isDirectory:&d]) continue;
            if (!d) {
                NSString *e = name.pathExtension.lowercaseString;
                if ([e isEqualToString:@"png"] || [e isEqualToString:@"jpg"] ||
                    [e isEqualToString:@"jpeg"] || [e isEqualToString:@"mp4"]) [out addObject:childRel];
            } else if (depth < maxDepth) {
                [queue addObject:childRel];
            }
        }
    }
    return out;
}

static NSArray<NSString *> *diWallpaperList(void) { return diWallpaperListIn(kWallpaperDir, 3); }

/* 把偏好里的相对路径解析成绝对路径; 该文件不存在则返回 nil。
   顺手做一层"容错": 用户只填了文件名也能命中目录里的同名文件。 */
static NSString *diWallpaperResolve(NSString *rel) {
    if (!rel.length || [rel isEqualToString:@"__none__"]) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *p = [kWallpaperDir stringByAppendingPathComponent:rel];
    if ([fm fileExistsAtPath:p]) return p;
    /* 只给了文件名: 在扫描列表里按 lastPathComponent 找 */
    for (NSString *it in diWallpaperList()) {
        if ([[it lastPathComponent] isEqualToString:rel]) {
            NSString *q = [kWallpaperDir stringByAppendingPathComponent:it];
            if ([fm fileExistsAtPath:q]) return q;
        }
    }
    return nil;
}

static BOOL diWallpaperIsVideo(NSString *path) {
    return [[path.pathExtension lowercaseString] isEqualToString:@"mp4"];
}

@interface DIWallpaperView ()
- (void)detachAndStop:(NSString *)why;
@property (nonatomic, strong) UIImageView *imgV;
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, weak) UIView *attachedHost;
@property (nonatomic, copy) NSString *curPath;
@property (nonatomic, copy) NSString *curTraitKey;   /* light / dark, 变了就重读素材 */
@property (nonatomic, assign) BOOL curMuted;
@property (nonatomic, weak) UIView *watchedSuper;    /* 2.7.9: KVO 盯住的挂载父级 */
@property (nonatomic, weak) UIView *watchedPres;     /* 2.7.12: KVO 盯住的"显示条件"层 */
@property (nonatomic, assign) CGFloat diLastAlpha;   /* 避免 alpha 与 hidden 重复处理 */
@property (nonatomic, assign) BOOL diLastHidden;
- (void)diSyncToHost;
- (void)diAttachToBackdrop:(UIView *)mv;   /* 2.7.20: 帧内挂载 */
@end

@implementation DIWallpaperView

+ (NSString *)resolveCurrentPath {
    NSString *light = diWallpaperResolve(wpLightAsset);
    NSString *dark = diWallpaperResolve(wpDarkAsset);
    BOOL isDark = NO;
    if (wpFollowDark) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)sc;
            for (UIWindow *w in ws.windows) {
                if (!w.isKeyWindow) continue;
                isDark = (w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
                break;
            }
        }
    }
    if (isDark && dark.length) return dark;
    if (!isDark && light.length) return light;
    return dark.length ? dark : light;
}

+ (instancetype)shared {
    static DIWallpaperView *v;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        v = [[DIWallpaperView alloc] initWithFrame:CGRectZero];
    });
    return v;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;   /* 绝不吃触摸: 壁纸要能被划动翻页穿透 */
        self.backgroundColor = [UIColor clearColor];   /* 2.7.2: 没素材时保持系统默认(透明), 不能黑底 */
        self.clipsToBounds = YES;
        _imgV = [[UIImageView alloc] initWithFrame:self.bounds];
        _imgV.contentMode = UIViewContentModeScaleAspectFill;
        _imgV.clipsToBounds = YES;
        _imgV.userInteractionEnabled = NO;
        [self addSubview:_imgV];
        _player = [[AVQueuePlayer alloc] init];
        _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        _player.muted = YES;
        _player.volume = 0.0f;   /* 2.7.4: 双保险, 视频绝不贡献任何声音 */
        /* 2.7.5: 壁纸播放器是纯静音(剥音轨 + muted + volume 0), 不需要它去动全局音频会话;
           会话类别由岛上那套统一维持, 这里不再重复写入, 进一步降低对其他 App 音频的扰动 */
        if ([_player respondsToSelector:@selector(setPreventsDisplaySleepDuringVideoPlayback:)])
            _player.preventsDisplaySleepDuringVideoPlayback = NO;
        _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
        _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        _playerLayer.hidden = YES;
        [self.layer addSublayer:_playerLayer];
    }
    return self;
}

/* 找 SpringBoard 的图标容器 —— 壁纸要垫在它下面 */
/* 2.7.1: 找"控制中心"的挂载点。
   之前的版本挂的是 SBRootFolderView(桌面根视图) —— 那是错的, 用户要的是控制中心背景。
   控制中心窗口类名是 SBControlCenterWindow, 它里面再找 CCUIControlCenterViewController 的根视图,
   把壁纸垫到那一层的最底下即可。找不到特征类时退化为"窗口里最外层的容器视图"。

   注意: 控制中心不是一直存在的 —— 收起时窗口 hidden 或者根本没有内容视图。
   所以这里返回 nil 的时候调用方什么都不做, 等展开后的 tick 再挂。 */

/* 2.7.5: 找"控制中心"窗口 —— 必须是**正在作为控制中心展示**的那个窗口。
   上一版(2.7.4)只按类名匹配 SBControlCenterWindow, 但真机上这个窗口是常驻的:
   控制中心收起后窗口还在, alpha 也不一定掉到 0 → 于是壁纸一直挂在窗口里,
   用户从控制中心退出(划掉/回桌面)时还能看到素材闪一下, 而他要的是"只有背景时才显示素材"。
   现在改为三重判定, 任何一条不满足都当作"没在展示":
     1. 窗口类名是控制中心窗口, 且不是锁屏/状态栏/灵动岛窗口
     2. 窗口必须 visible, 且真正处于界面最上层(不是被别的窗口盖住)
     3. 控制中心那个"抓手指"/内容层真的是全屏且 alpha 正常(展开动画中算展示, 收起时不算) */
- (BOOL)diIsControlCenterWindow:(UIWindow *)w {
    if (!w) return NO;
    NSString *cn = NSStringFromClass(w.class);
    if (![cn isEqualToString:@"SBControlCenterWindow"] && ![cn containsString:@"ControlCenter"]) return NO;
    static NSArray<NSString *> *blocked;
    if (!blocked) blocked = @[@"SBSystemApertureWindow", @"SBStatusBarWindow", @"SBWallpaperWindow",
                              @"SBLockScreenWindow", @"SBNotificationCenterWindow"];
    for (NSString *b in blocked) if ([cn isEqualToString:b]) return NO;
    if (w.bounds.size.width < 100) return NO;
    if (w.isHidden) return NO;
    return YES;
}

- (UIWindow *)controlCenterWindow {
    UIWindow *best = nil;
    CGFloat bestLevel = -1e9;
    NSMutableArray<UIWindow *> *all = [NSMutableArray array];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        [all addObjectsFromArray:((UIWindowScene *)sc).windows];
    }
    /* 2.7.7: 真机实测 —— 控制中心**收起后** SBControlCenterWindow 依然 !isHidden、alpha=1.0,
       而且里面那套内容层还完整保留(SBBarSwipeAffordanceView / MTMaterialView / 模块全在),
       所以"窗口可见"根本区分不出开/关, 237 日志里才会"挂上→判不可见→撤下"来回抖。
       真正的开关信号在视图树里: 展开时 SBBarSwipeAffordanceView 是 {{0,0},{430,932}},
       收起时它会被缩小/移出(高度或宽度掉到窗口尺寸的一半以下)。
       这里用"抓手指层占比"作主判据, 窗口可见性只做初筛。
       抓手指层按类名 + "尺寸排第一"来认(SBHomeGrabberView 也是它子级, 不会认错)。 */
    for (UIWindow *w in all) {
        if (![self diIsControlCenterWindow:w]) continue;
        if (w.isHidden || w.alpha <= 0.01) continue;
        if (w.windowLevel > bestLevel) { bestLevel = w.windowLevel; best = w; }
    }
    /* 2.7.9: 这里**不再**因"看着像收起"就返回 nil ——
       239 日志里 16:42:50 明明挂上了壁纸, 16:43:19 起却连续输出 "controlCenterWindow=nil",
       说明收起后这个窗口被系统从 scene.windows 里摘掉了。既然它会被摘掉,
       "窗口还在 = 控制中心开着" 本身就是最可靠的信号, 不需要再加尺寸判定。
       只在"确实拿不到窗口"时才认为是收起。 */
    return best;
}

/* 2.7.7: 控制中心是否真正"摆在屏幕上"(而不是收起后残留的窗口) */
- (BOOL)controlCenterLooksOpen:(UIWindow *)w {
    CGRect wb = w.bounds;
    if (wb.size.width < 100) return NO;
    /* 找尺寸最大的 SwipeAffordance 层(展开时它就是整屏) */
    UIView *aff = nil; CGFloat bestArea = 0;
    for (UIView *v in w.subviews) {
        if (![NSStringFromClass(v.class) containsString:@"SwipeAffordance"]) continue;
        CGFloat a = v.bounds.size.width * v.bounds.size.height;
        if (a > bestArea) { bestArea = a; aff = v; }
    }
    UIView *root = w.rootViewController.view;
    if (aff) {
        CGFloat rw = aff.bounds.size.width / MAX(wb.size.width, 1);
        CGFloat rh = aff.bounds.size.height / MAX(wb.size.height, 1);
        /* 真机: 展开时 ≈ 1.0/1.0; 收起后 0.0~0.5 之间摇摆 */
        BOOL open = (rw > 0.75 && rh > 0.75);
        if (!open) {
            static CFAbsoluteTime tN; CFAbsoluteTime nn = CFAbsoluteTimeGetCurrent();
            if (nn - tN > 1.0) { tN = nn; DLog(@"[壁纸诊断] 抓手指层比值 w=%.2f h=%.2f 实际 %.0fx%.0f → 判收起", rw, rh, aff.bounds.size.width, aff.bounds.size.height); }
            return NO;
        }
    } else if (!root || root.alpha < 0.5) {
        return NO;
    }
    /* 内容层透明度: 收起后 root 仍可能是 1.0, 所以只在"有 root"时做兜底, 不做主判据 */
    return YES;
}

/* 控制中心是否真的展开:
   窗口有内容 + 内容层 alpha 正常 + "抓手指"层真的是全屏(收起过程中它会被缩到很小/移出屏外) */
- (BOOL)isControlCenterPresented:(UIWindow *)w {
    if (!w) return NO;
    return [self controlCenterLooksOpen:w];
}

/* 首次进入打一次视图树, 便于按真机结构校准 */
- (void)dumpControlCenterTree:(UIWindow *)w {
    /* 2.7.19: 原来 static dumped 导致每个进程只打一次, 且广度优先 300 个节点就把
       CCControlCenterBackgroundView 挤掉了(它藏在手势层深处)。现在改成:
         · 只打"从窗口到 CCControlCenterBackgroundView"的这条链 + 它内部的直接子视图;
         · 每次控制中心**重新展开**都打一遍(见 gCCGen 计数), 因为每次重建的层级可能不同;
         · 附带全局搜索统计, 直接告诉我们这个类到底在不在。 */
    static int dumpedGen = -1;
    if (dumpedGen == gCCGeneration) return;
    dumpedGen = gCCGeneration;

    DLog(@"[控制中心视图树] 窗口=%@ %@", NSStringFromClass(w.class), NSStringFromCGRect(w.bounds));

    /* 1) 全局搜一遍 CCControlCenterBackgroundView, 记录命中数 */
    UIView *target = nil;
    int hits = 0, total = 0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
    int guard = 0;
    while (stack.count && guard++ < 3000) {
        UIView *v = stack.firstObject;
        [stack removeObjectAtIndex:0];
        total++;
        if (diIsCCBackgroundView(v)) {
            hits++;
            if (!target) target = v;
        }
        for (UIView *c in v.subviews) [stack addObject:c];
    }
    DLog(@"[控制中心视图树] 遍历 %d 个视图, CCControlCenterBackgroundView 命中 %d 个", total, hits);

    if (target) {
        /* 2) 打出从窗口到它的完整父子链 —— 这决定了它到底该挂在哪一层 */
        NSMutableArray<UIView *> *chain = [NSMutableArray array];
        for (UIView *v = target; v; v = v.superview) [chain insertObject:v atIndex:0];
        for (NSUInteger i = 0; i < chain.count; i++) {
            UIView *v = chain[i];
            NSMutableString *ind = [NSMutableString string];
            for (NSUInteger k = 0; k < i; k++) [ind appendString:@"  "];
            DLog(@"%@└%@%@ %@ alpha=%.2f 层序=%lu/共%lu",
                 ind, NSStringFromClass(v.class), v.isHidden ? @"[H]" : @"",
                 NSStringFromCGRect(v.bounds), v.alpha,
                 (unsigned long)[v.superview.subviews indexOfObject:v],
                 (unsigned long)v.superview.subviews.count);
        }
        /* 3) 它自己的子视图 —— 壁纸要插成第 0 层, 得先看清里面有什么 */
        DLog(@"[控制中心视图树] ★ CCControlCenterBackgroundView 内部子视图 (共 %lu):",
             (unsigned long)target.subviews.count);
        for (NSUInteger i = 0; i < target.subviews.count; i++) {
            UIView *c = target.subviews[i];
            DLog(@"       [%lu] %@%@ %@ alpha=%.2f userInteraction=%d",
                 (unsigned long)i, NSStringFromClass(c.class), c.isHidden ? @"[H]" : @"",
                 NSStringFromCGRect(c.bounds), c.alpha, (int)c.userInteractionEnabled);
        }
    } else {
        /* 没命中 —— 打前 3 层结构, 方便对真机层级 */
        DLog(@"[控制中心视图树] !! 未找到 CCControlCenterBackgroundView, 打前 3 层");
        NSMutableArray<UIView *> *st2 = [NSMutableArray arrayWithObject:w];
        NSMutableArray<NSNumber *> *dep = [NSMutableArray arrayWithObject:@0];
        int g2 = 0;
        while (st2.count && g2++ < 120) {
            UIView *v = st2.firstObject; [st2 removeObjectAtIndex:0];
            int d = [dep.firstObject intValue]; [dep removeObjectAtIndex:0];
            NSMutableString *ind = [NSMutableString string];
            for (int k = 0; k < d; k++) [ind appendString:@"  "];
            DLog(@"%@%@%@ %@ alpha=%.2f", ind, NSStringFromClass(v.class),
                 v.isHidden ? @"[H]" : @"", NSStringFromCGRect(v.bounds), v.alpha);
            if (d < 3) for (UIView *c in v.subviews) { [st2 addObject:c]; [dep addObject:@(d + 1)]; }
        }
    }
}

/* 找控制中心里"铺满整屏的那层背景容器"。
   2.7.4 是找 MTMaterialView 然后插到它上面(同一父视图里)。做法没错, 但壁纸那时候
   挂在内容层内部, 退出控制中心时会跟着内容层一起露一下脸 —— 2.7.5 改为挂到窗口直属层级,
   所以这里只用来判断"控制中心的内容层建好了没有"。 */
/* 2.7.11: 找控制中心里那张**真正铺满全屏**的磨砂底, 壁纸插在它上面。
   2.7.10 的判据是"尺寸 ≥ 窗口 90%x80%", 结果把 CCUIScrollView 里那个 430x932 的**内容底**
   也认成候选, 于是壁纸被插在模块前面 —— 用户截图里开关全被盖住了。
   真机 241 视图树里同一帧有两个 430x932 的 MTMaterialView:
     · 外层那个: 祖先是用户能看到的那个全屏 UIView(磨砂背景)
     · 里层那个: 祖先落在 CCUIScrollView 里(滚动内容区的底色)
   这里改成: 必须**直接挂在用户可见的内容容器下**(不被任何 UIScrollView 包住), 且全屏。
   这样只可能命中外层那张, 壁纸就在模块之下、背景之上。 */
static BOOL diAncestorInScrollView(UIView *v, UIView *stop) {
    UIView *p = v.superview;
    int guard = 0;
    while (p && p != stop && guard++ < 40) {
        if ([p isKindOfClass:[UIScrollView class]]) return YES;
        p = p.superview;
    }
    return NO;
}

/* 2.7.18: 是否是控制中心真正的背景容器类。
   2.7.19 结论修正: 251 日志遍历真机整棵树, 这个类 **命中 0 次** —— iOS 16 上不存在。
   (开发者文档/旧资料里它属于更早或更晚的版本; 当前系统只有 CCUIContentModuleBackgroundView,
   而那是每个模块自己的 77x77 圆角小卡片, 不是整屏背景。)
   代码保留: 将来换系统若真有这个类, 自动走"插进它内部第 0 层"这条更优路径。 */
static BOOL diIsCCBackgroundView(UIView *v) {
    return (v && [NSStringFromClass(v.class) isEqualToString:@"CCControlCenterBackgroundView"]);
}

- (UIView *)controlCenterBackdropIn:(UIView *)host {
    if (!host) return nil;
    CGSize hs = host.bounds.size;
    if (hs.width < 10 || hs.height < 10) return nil;

    /* 2.7.18: 若系统真有 CCControlCenterBackgroundView(某些版本), 优先用它 —— 它是整屏背景容器,
       壁纸插进内部第 0 层, 层级与系统完全一致。 */
    UIView *bgView = nil;
    NSMutableArray<UIView *> *stack2 = [NSMutableArray arrayWithObject:host];
    int guard2 = 0;
    while (stack2.count && guard2++ < 800) {
        UIView *v = stack2.firstObject;
        [stack2 removeObjectAtIndex:0];
        if (diIsCCBackgroundView(v)) { bgView = v; break; }
        for (UIView *c in v.subviews) [stack2 addObject:c];
    }
    if (bgView) return bgView;

    /* 2.7.19: 251 真机日志确认 —— iOS 16 控制中心的**唯一全屏背景**是
       `MTMaterialView (430x932)`, 它直接挂在 SBBarSwipeAffordanceView 下那个
       `UIView (430x932)` 容器里, 是容器的第 0 个子视图。

       真机完整层级(BFS 还原):
         SBControlCenterWindow (430x932)
           ├ SBBarSwipeAffordanceView (430x932)
           │    ├ UIView (430x932)                  ← 背景容器
           │    │    ├ MTMaterialView (430x932)     ← ★ 全屏磨砂底 = 唯一的背景
           │    │    ├ CCUIScrollView (430,-155)    ← 模块区
           │    │    │    └ UIView (430x788) → CCUIModuleCollectionView
           │    │    │         └ MTMaterialView (430x932)  ← 滚动区里的, 不能碰
           │    │    ├ UIView[hidden] (430x932)
           │    │    └ CCUIHeaderPocketView (430x155)
           │    └ SBHomeGrabberView (430x932)
           └ UIView (96x30) alpha=0

       2.7.11～2.7.18 一直把壁纸插在这张磨砂底的**上层**(日志: 层序=2/共8)。
       磨砂玻璃会把它上面的所有内容都做模糊处理, 所以壁纸永远发虚、发暗。
       正确做法是插进 **MTMaterialView 内部**:
         MTMaterialView 的 subviews[0] 是 _UIBackdropEffectView(真正干磨砂活的那层),
         壁纸插在 index 0 = 磨砂效果层**之下** → 壁纸清晰可见, 而上面的模块不受影响。 */
    UIView *best = nil; CGFloat bestArea = 0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:host];
    int guard = 0;
    while (stack.count && guard++ < 1200) {
        UIView *v = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if ([v isKindOfClass:NSClassFromString(@"MTMaterialView")] && !v.isHidden && v.alpha > 0.01) {
            CGSize bs = v.bounds.size;
            BOOL fullScreen = (bs.width >= hs.width * 0.95 && bs.height >= hs.height * 0.95);
            if (fullScreen && !diAncestorInScrollView(v, host)) {
                CGFloat a = bs.width * bs.height;
                if (a > bestArea) { best = v; bestArea = a; }
            }
        }
        for (UIView *c in v.subviews) [stack addObject:c];
    }
    return best;
}



- (NSString *)traitKey {
    if (!wpFollowDark) return @"light";
    if (@available(iOS 12.0, *)) {
        return (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark" : @"light";
    }
    return @"light";
}

- (void)attachIfNeeded {
    if (!wpOn) {
        [self detachAndStop:@"壁纸开关关闭"];
        return;
    }
    /* 2.7.2: 一条素材都没选 → 什么都不做, 让控制中心保持系统原样(透明) */
    NSString *qLight = diWallpaperResolve(wpLightAsset);
    NSString *qDark = diWallpaperResolve(wpDarkAsset);
    if (!qLight.length && !qDark.length) {
        [self detachAndStop:@"未选素材, 保持系统默认(透明)"];
        return;
    }
    /* 2.7.6: 判定顺序改了 —— 先看"窗口还在不在", 再看"展开没展开"。
       2.7.5 把"必须抓手指层全屏"当成硬条件, 结果控制中心明明开着也一直判成未展开,
       壁纸因此一次都没挂上(用户录屏里控制中心整个是空的, 素材全没了)。
       现在的三级判定:
         1) 窗口能被找到(isHidden=NO, alpha>0.01, 类名匹配) → 再往下
         2) 窗口不可见 / alpha 趋 0 → 立即撤下, 保持原生(解决"退出还闪一下")
         3) 可见但还在展开/收起动画中(抓手指层没全屏) → **保持现状不动**, 既不挂也不撤,
            等动画结束后的下一拍再按真实状态处理。这样既不会闪, 也不会误判成"没开"。 */
    UIWindow *w = [self controlCenterWindow];
    if (!w) {
        /* 2.7.21: 这一整段旁路**删除**。
           2.7.20 在这里加了 `if (diInFrameAttach) return;`, 本意是"帧内挂载时窗口
           还在 alpha=0 的展开动画里, 别把刚挂好的壁纸撤掉"。但它 return 的是**整个
           函数**, 连上面那些"开关关了就撤""没选素材就撤"的判定都一起跳过了 ——
           而 diInFrameAttach 又由布局回调在启动期反复置位, 结果 SpringBoard 启动时
           这条路径被无限走通, 一路走到 detachAndStop: / 创建单例, 是卡白苹果的推手。
           现在帧内模式已经不用这个标志了(见 2.7.21 hook 实现), 行为回到 2.7.19:
           窗口不可见 → 干净撤下, 保持系统原生。 */
        /* 2.7.14: 原来这不带任何节流, 收起状态下每 0.5s 刷一条 —— 247 日志 797 行里
           635 行全是这句, 真正有用的时序全被挤掉了。改成只在"打开→收起"翻转时记一条。 */
        if (gCCWindowSeen) { gCCWindowSeen = NO; DLog(@"[壁纸诊断] 控制中心窗口不可见 → 判定收起"); }
        [self detachAndStop:@"控制中心窗口不可见, 壁纸撤下(保持原生)"];
        return;
    }
    if (!gCCWindowSeen) {
        gCCWindowSeen = YES;
        gCCGeneration++;          /* 2.7.19: 每次重新展开 = 新一代, 诊断重新打一遍 */
    }
    [self dumpControlCenterTree:w];

    /* 2.7.22: **UIView 挂载路径正式停用**。
       252 日志证明这条路在当前系统上活不下来 —— MTMaterialView 展开期间是个空壳,
       我们 insertSubview 进去的视图会在系统填充时被清理, 于是"挂上→被踢→再挂"
       一秒循环一次, 这就是用户看到的 1 秒延迟。
       现在改由 MTMaterialView 的 layoutSubviews hook 用 CALayer 挂载(见文件后段),
       CALayer 不在系统清理范围内, 挂一次就一直在。
       这里直接返回, 避免两条路径互相覆盖、也避免每 1.5s 做无用功。 */
    {
        static BOOL sTold;
        if (!sTold) { sTold = YES; DLog(@"[壁纸图层] UIView 挂载路径已停用, 统一走 CALayer(参考 CCBackgroundMod 实现)"); }
    }
    return;
#if 0   /* 以下为 2.7.21 及以前的 UIView 挂载实现, 保留备查 */
    /* 2.7.9: 走 2.7.3/2.7.4 那套「能拿到窗口就挂」的判定 —— 那两版用户确认显示正确。
       窗口被系统摘掉(收起)= 拿不到 w = 上面已经撤下, 所以这里不必再加尺寸门槛。 */
    BOOL fullyOpen = YES;
    BOOL attached = (self.superview == w);
    if (!fullyOpen) {
        if (!attached) {
            /* 没挂过 + 没完全展开 → 本轮什么都不做, 等它开完 */
            return;
        }
        /* 已经挂着, 但抓手指层不满屏: 可能是"正在收起" 也可能是系统把层临时缩了。
           用动画状态区分: 窗口/内容层在动画中就先留着(下一拍再判), 不在动画中说明确实收起了。 */
        UIView *root = w.rootViewController.view;
        BOOL animating = ((self.layer.animationKeys.count > 0) || (root.layer.animationKeys.count > 0));
        if (!animating) { [self detachAndStop:@"控制中心已收起, 壁纸撤下(保持原生)"]; }
        return;
    }

    /* 2.7.11: 挂载点定案 —— 挂在**磨砂背景的父容器**里、紧跟在磨砂底后面。
       241 真机视图树的层级(缩进即父子):
         SBControlCenterWindow
           ├ SBBarSwipeAffordanceView (430x932)          ← 手势层, 全屏
           │    ├ UIView (430x932)                        ← ★ 用户看到的背景容器
           │    │    ├ MTMaterialView (430x932)           ← 磨砂背景: 壁纸要压它
           │    │    ├ CCUIScrollView (430x932)           ← 开关/模块: 壁纸不能盖它
           │    │    ├ UIView[hidden] (430x932)
           │    │    └ CCUIHeaderPocketView (430x155)
           │    └ SBHomeGrabberView (430x932)
           └ UIView (96x30) alpha=0
       之前两版错在两处:
         · 2.7.9 挂进容器后插在"名字最大的 MTMaterialView"上面 —— 它在 CCUIScrollView 里,
           是滚动内容区的底, 把人家的磨砂链路搞乱了 → 整片不显示;
         · 2.7.10 挂到窗口直属层、插在整个 SBBarSwipeAffordanceView 上面 → 盖住了开关。
       现在直接落在容器内部、磨砂底的正后面: 压住背景, 又在开关之下。 */
    /* 2.7.13: 若磨砂层组名路线可用, 壁纸由系统材质自己渲染, **不再插任何图层** ——
       这条路径天然解决"进入先出底色"和"退出多留一秒", 且绝不可能压住开关。
       2.7.18: 但 247 日志证明这条路线在真机上从没生效过(组名 hook 找不到 getter/setter),
       所以这里加一道保险: 只要真机存在 CCControlCenterBackgroundView, 就走它, 不认组名。 */
    /* 2.7.19: 251 日志给了铁证 —— 组名路线 **212 次全部失败**:
         [壁纸图层] UIBlurEffect 没有可用的组名 setter, 采样源放弃
         [壁纸图层] 采样源构建失败, 退回插图层老路
       不仅 MTMaterialView 上没有组名 setter, 连 UIBlurEffect 上也没有。
       这条路线在当前系统就是死路, 而它每次失败都要走一遍完整 BFS + 建 UIVisualEffectView,
       白耗性能。直接强制关闭, 只走"插进 MTMaterialView 内部"这一条确定能显示的路。 */
    if (gCCGroupHooked) {
        static BOOL sWarned;
        if (!sWarned) { sWarned = YES; DLog(@"[壁纸图层] 组名渲染路线已停用(真机无 setter), 统一走 MTMaterialView 内部挂载"); }
        gCCGroupHooked = NO;
    }
    UIView *backdrop = [self controlCenterBackdropIn:w];
    /* 2.7.22: 旧的 gCCBackdropHint 旁路已删除 —— 现在挂载由 MTMaterialView 的
       layoutSubviews hook 用 CALayer 方式完成(见文件后段), 这里的 UIView 挂载
       只作为"hook 没生效"时的兜底。 */
    CGSize ws = w.bounds.size;
    /* 2.7.19: 挂载方式三档 ——
       · CCControlCenterBackgroundView(系统若有) → 插进它内部第 0 层;
       · MTMaterialView → **插进它内部第 0 层**(磨砂效果层之下), 壁纸才清晰;
         2.7.18 及以前是插在它旁边的"上面一层", 会被磨砂玻璃糊掉。 */
    BOOL intoCCBg   = diIsCCBackgroundView(backdrop);
    BOOL intoMT     = (backdrop && !intoCCBg);
    UIView *targetParent = (intoCCBg || intoMT) ? backdrop : backdrop.superview;
    CGSize mySize = targetParent ? targetParent.bounds.size : ws;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    BOOL needReparent = targetParent ? (self.superview != targetParent) : (self.superview != w);
    if (needReparent) {
        [self removeFromSuperview];
        if (backdrop && (intoCCBg || intoMT)) {
            /* 插进背景层内部最底层:
               · CCControlCenterBackgroundView → 磨砂材质、模块都在其上
               · MTMaterialView               → 位于 _UIBackdropEffectView 之下, 不被模糊 */
            [backdrop insertSubview:self atIndex:0];
        } else if (backdrop) {
            [backdrop.superview insertSubview:self aboveSubview:backdrop];
        } else {
            /* 没找到磨砂底(视图树还没建好) → 先挂窗口里等下一拍, 但绝不能盖在手势层上面 */
            UIView *wrapper = [self controlCenterWrapperIn:w];
            UIView *into = wrapper ?: w;
            self.frame = CGRectMake(0, 0, into.bounds.size.width, into.bounds.size.height);
            [into addSubview:self];
            self.attachedHost = into;
            DLog(@"控制中心壁纸暂挂容器 %@ (磨砂底未就绪)", NSStringFromClass(into.class));
            [self diWatchSuperviewOf:w];
            [self diWatchPresentation:into];
            [self refreshGeometry];
            return;
        }
        self.frame = CGRectMake(0, 0, mySize.width, mySize.height);
        self.attachedHost = targetParent;
        if (intoCCBg) {
            DLog(@"控制中心壁纸已挂入 CCControlCenterBackgroundView 内部 (%.0fx%.0f) 层序=%lu/共%lu, 材质与模块均在其上",
                 mySize.width, mySize.height,
                 (unsigned long)[targetParent.subviews indexOfObject:self],
                 (unsigned long)targetParent.subviews.count);
        } else if (intoMT) {
            DLog(@"控制中心壁纸已挂入 MTMaterialView 内部 (%.0fx%.0f) 层序=%lu/共%lu [磨砂效果层之下, 不再被模糊]",
                 mySize.width, mySize.height,
                 (unsigned long)[targetParent.subviews indexOfObject:self],
                 (unsigned long)targetParent.subviews.count);
            /* 2.7.19: 把 MTMaterialView 内部结构打一次, 便于确认壁纸确实在 _UIBackdropEffectView 之下 */
            static BOOL sMTDumped;
            if (!sMTDumped) {
                sMTDumped = YES;
                DLog(@"[壁纸图层] MTMaterialView 内部子视图 (共 %lu):", (unsigned long)targetParent.subviews.count);
                for (NSUInteger i = 0; i < targetParent.subviews.count; i++) {
                    UIView *c = targetParent.subviews[i];
                    DLog(@"       [%lu] %@%@ %@ alpha=%.2f", (unsigned long)i,
                         NSStringFromClass(c.class), c.isHidden ? @"[H]" : @"",
                         NSStringFromCGRect(c.bounds), c.alpha);
                }
            }
        } else {
            DLog(@"控制中心壁纸已挂入背景容器 %@ (%.0fx%.0f) 磨砂底之上一层=%lu/共%lu, 开关层在其后",
                 NSStringFromClass(targetParent.class), mySize.width, mySize.height,
                 (unsigned long)[targetParent.subviews indexOfObject:self],
                 (unsigned long)targetParent.subviews.count);
        }
        [self diWatchSuperviewOf:w];
        /* 2.7.12: 一开始就跟随父级的显示条件, 平铺/淡入的整个过程都不会出现"素色底" */
        [self diWatchPresentation:targetParent];
        if (self.curPath.length && diWallpaperIsVideo(self.curPath)) [self.player play];
    } else {
        if (!CGRectEqualToRect(self.frame, CGRectMake(0, 0, mySize.width, mySize.height)))
            self.frame = CGRectMake(0, 0, mySize.width, mySize.height);
        [self diWatchSuperviewOf:w];
        if ((intoCCBg || intoMT) && self.superview == backdrop) {
            /* 系统重排把它压上去了 → 重新拉回最底层 */
            NSInteger mi = [backdrop.subviews indexOfObject:self];
            if (mi != NSNotFound && mi != 0) [backdrop insertSubview:self atIndex:0];
        }
        /* 系统重排把它压到磨砂底下面了 → 重新提回磨砂底正后面 */
        if (backdrop && !intoCCBg && !intoMT && self.superview == backdrop.superview) {
            NSInteger bi = [backdrop.superview.subviews indexOfObject:backdrop];
            NSInteger mi = [backdrop.superview.subviews indexOfObject:self];
            if (bi != NSNotFound && mi != NSNotFound && mi < bi)
                [backdrop.superview insertSubview:self aboveSubview:backdrop];
        }
    }
    [self refreshGeometry];
#endif  /* 2.7.22: 以上 UIView 挂载实现已停用, 改走 CALayer */
}

/* 2.7.20: 帧内挂载专用 —— 直接挂到指定的磨砂层内部第 0 层。
   与 attachIfNeeded 的挂载分支完全同一套层级规则, 只是省掉了"找窗口/找磨砂层"这一步,
   因为 layoutSubviews 回调里 mv 就是那张磨砂层本身。 */
- (void)diAttachToBackdrop:(UIView *)mv {
    if (!mv || !wpOn) return;
    NSString *qLight = diWallpaperResolve(wpLightAsset);
    NSString *qDark  = diWallpaperResolve(wpDarkAsset);
    if (!qLight.length && !qDark.length) { [self detachAndStop:nil]; return; }

    BOOL sameParent = (self.superview == mv);
    CGSize ms = mv.bounds.size;
    if (ms.width < 10 || ms.height < 10) return;

    if (!sameParent) {
        [self removeFromSuperview];
        /* 插进 MTMaterialView 内部第 0 层 = 位于 _UIBackdropEffectView 之下, 不被模糊 */
        [mv insertSubview:self atIndex:0];
        self.attachedHost = mv;
        if (!diInFrameAttachLogged) {
            diInFrameAttachLogged = YES;
            DLog(@"[壁纸图层] 帧内挂载成功: 直接挂入 MTMaterialView 内部 (%.0fx%.0f) 层序=%lu/共%lu —— 与系统动画同帧, 零延迟",
                 ms.width, ms.height,
                 (unsigned long)[mv.subviews indexOfObject:self],
                 (unsigned long)mv.subviews.count);
        }
    }
    if (!CGRectEqualToRect(self.frame, CGRectMake(0, 0, ms.width, ms.height)))
        self.frame = CGRectMake(0, 0, ms.width, ms.height);
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    /* 保持在第 0 层: 系统排版可能把新子视图塞进来 */
    NSInteger mi = [mv.subviews indexOfObject:self];
    if (mi != NSNotFound && mi != 0) [mv insertSubview:self atIndex:0];

    [self diWatchSuperviewOf:mv.window];
    [self diWatchPresentation:mv];
    /* 素材/主题变化时换片 —— 直接调 loadPath:, 不能再走 reload(它内部会再调 attachIfNeeded, 递归) */
    NSString *key = [self traitKey];
    BOOL keyChanged = !(_curTraitKey && [_curTraitKey isEqualToString:key]);
    _curTraitKey = key;
    /* 2.7.32: 单素材 —— 不再分深浅两套 */
    NSString *path = diWallpaperResolveAny(wpLightAsset);
    if (!path) path = diWallpaperResolveAny(wpDarkAsset);
    if (path.length && (keyChanged || ![path isEqualToString:_curPath ?: @""])) {
        [self loadPath:path];
    } else if (self.curPath.length && diWallpaperIsVideo(self.curPath)) {
        if (self.player.timeControlStatus != AVPlayerTimeControlStatusPlaying) [self.player play];
    }
    [self refreshGeometry];
}

/* 2.7.11: 手势层里那个"全屏的裸 UIView", 也就是用户看到的背景容器 */
- (UIView *)controlCenterWrapperIn:(UIWindow *)w {
    for (UIView *v in w.subviews) {
        if (![NSStringFromClass(v.class) containsString:@"SwipeAffordance"]) continue;
        CGSize bs = v.bounds.size;
        if (bs.width < w.bounds.size.width * 0.9 || bs.height < w.bounds.size.height * 0.9) continue;
        UIView *pick = nil; CGFloat pa = 0;
        for (UIView *c in v.subviews) {
            if ([c isKindOfClass:NSClassFromString(@"SBHomeGrabberView")]) continue;
            CGSize cs = c.bounds.size;
            if (cs.width < bs.width * 0.9 || cs.height < bs.height * 0.9) continue;
            CGFloat a = cs.width * cs.height;
            if (a > pa) { pa = a; pick = c; }
        }
        if (pick) return pick;
    }
    return nil;
}

- (void)detachAndStop:(NSString *)why {
    BOOL had = (self.superview != nil);
    [self diWatchSuperviewOf:nil];      /* 2.7.9: 撤下就不必再盯父级了 */
    [self diWatchPresentation:nil];     /* 2.7.12: 同上 */
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.alpha = 1.0;
    [CATransaction commit];
    if (had) {
        [self removeFromSuperview];
        self.attachedHost = nil;
    }
    [self.player pause];
    if (had && why.length) DLog(@"%@", why);
}

/* 2.7.9: 退出控制中心"还会闪一下背景"的根治办法 —— 不再靠 0.1s 轮询撞时机。
   壁纸挂在系统内容层里, 收起时系统会把 **内容层的父级整个移除/隐藏**,
   这个事件的到达时刻比下一拍轮询早得多。所以直接 KVO 那个父级的 window / hidden / alpha:
   一旦父级脱离窗口(或隐藏), 当场撤下壁纸, 一帧都不外露。 */
- (void)diWatchSuperviewOf:(UIView *)v {
    UIView *cur = _watchedSuper;
    if (cur == v) return;
    if (cur) {
        @try {
            [cur removeObserver:self forKeyPath:@"window"];
            [cur removeObserver:self forKeyPath:@"hidden"];
            [cur removeObserver:self forKeyPath:@"alpha"];
        } @catch (__unused NSException *e) {}
    }
    _watchedSuper = v;
    if (v) {
        NSKeyValueObservingOptions o = NSKeyValueObservingOptionNew;
        @try {
            [v addObserver:self forKeyPath:@"window" options:o context:NULL];
            [v addObserver:self forKeyPath:@"hidden" options:o context:NULL];
            [v addObserver:self forKeyPath:@"alpha"  options:o context:NULL];
        } @catch (__unused NSException *e) {}
    }
}

- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj change:(NSDictionary *)ch context:(void *)ctx {
    if (_watchedPres && obj == _watchedPres) {
        /* 2.7.12: 透明/显示变化 —— 同步覆盖层透明度, 淡出则同时撤 */
        [self diSyncToHost];
        return;
    }
    if (obj != _watchedSuper) { [super observeValueForKeyPath:kp ofObject:obj change:ch context:ctx]; return; }
    /* 父级一脱离窗口就说明控制中心正在被系统收走 → 立刻撤, 保持原生 */
    if (!_watchedSuper.window || _watchedSuper.hidden || _watchedSuper.alpha <= 0.01) {
        [self detachAndStop:@"父级已离开屏幕, 壁纸立刻撤下(保持原生)"];
    }
}
- (void)refreshGeometry {
    UIView *host = self.superview ?: self.attachedHost;
    if (!host) return;
    if (!CGRectEqualToRect(self.frame, host.bounds)) self.frame = host.bounds;
    _imgV.frame = self.bounds;
    /* 2.7.1: 一律铺满, 不做任何偏移/缩放微调 */
    _imgV.frame = self.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _playerLayer.frame = self.bounds;
    [CATransaction commit];
    /* 2.7.12: 尺寸变了也要立刻跟一次宿主状态, 避免首帧还是"可见但素色" */
    [self diSyncToHost];
}

/* 2.7.12: 把"我在屏幕上多亮"对齐到宿主等级。
   原因(242/243 日志 + 录屏):
     · 进入时控制中心是一层"系统底色"先铺满、再淡入磨砂与模块; 我的壁纸已经是可见的,
       所以它**在磨砂之下被压暗**, 前 1 秒看到的是深色底而不是素材;
     · 退出时我比系统动画更早撤, 又留下了"素材多留一下"的错位。
   做法: 让壁纸的 alpha 永远等于宿主 alpha, 宿主一淡出我同一帧跟着淡出,
   系统还原到桌面时绝不会还看得见素材。 */
- (void)diSyncToHost {
    UIView *p = _watchedPres;
    if (!p) return;
    CGFloat a = p.alpha;
    BOOL h = p.isHidden;
    if (h != _diLastHidden) {
        _diLastHidden = h;
        if (h) { [self detachAndStop:@"宿主已隐藏, 壁纸同时撤下(保持原生)"]; return; }
    }
    if (fabs(a - _diLastAlpha) > 0.001) {
        _diLastAlpha = a;
        if (a <= 0.01) { [self detachAndStop:@"宿主已淡出, 壁纸同时撤下(保持原生)"]; return; }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.alpha = a;
        [CATransaction commit];
    }
}

- (void)diWatchPresentation:(UIView *)v {
    UIView *cur = _watchedPres;
    if (cur == v) return;
    if (cur) {
        @try {
            [cur removeObserver:self forKeyPath:@"alpha"];
            [cur removeObserver:self forKeyPath:@"hidden"];
        } @catch (__unused NSException *e) {}
    }
    _watchedPres = v;
    _diLastAlpha = v ? v.alpha : 1.0;
    _diLastHidden = v ? v.isHidden : NO;
    if (v) {
        NSKeyValueObservingOptions o = NSKeyValueObservingOptionNew;
        @try {
            [v addObserver:self forKeyPath:@"alpha"  options:o context:NULL];
            [v addObserver:self forKeyPath:@"hidden" options:o context:NULL];
        } @catch (__unused NSException *e) {}
    }
}

- (void)stopVideo {
    [_looper disableLooping];
    _looper = nil;
    [_player replaceCurrentItemWithPlayerItem:nil];
    _playerLayer.hidden = YES;
}

- (void)reload {
    /* 2.7.37: overlay(ccvideobg)路径成立后, 这套老 UIView 壁纸永远不再上屏
       (attach 早已停用), 但 reload 还在照样建播放器解码视频 —— 隐形播放器白白吃 CPU,
       日志里那 11 条"壁纸已加载(视频)"全是它。直接停掉内容加载。 */
    if (gCCOverlayHooked) {
        [self stopVideo];
        _imgV.image = nil;
        _curPath = nil;
        return;
    }
    if (!wpOn) {
        [self stopVideo];
        _imgV.image = nil;
        _curPath = nil;
        [self attachIfNeeded];
        return;
    }
    [self attachIfNeeded];

    NSString *key = [self traitKey];
    BOOL keyChanged = !(_curTraitKey && [_curTraitKey isEqualToString:key]);
    _curTraitKey = key;

    /* 2.7.32: 单素材 —— 不再分深浅两套 */
    NSString *path = diWallpaperResolveAny(wpLightAsset);
    if (!path) path = diWallpaperResolveAny(wpDarkAsset);

    if (!path.length) {
        [self stopVideo];
        _imgV.image = nil;
        _imgV.hidden = NO;
        _curPath = nil;
        static BOOL loggedOnce;
        if (!loggedOnce) { loggedOnce = YES; DLog(@"壁纸已开启但没选素材(目录 %@)", kWallpaperDir); }
        return;
    }

    if (keyChanged || ![path isEqualToString:_curPath] || (_player.rate == 0 && diWallpaperIsVideo(path))) {
        [self loadPath:path];
    }
    if (diWallpaperIsVideo(path)) {
        if (self.player.muted != wpMuted) self.player.muted = wpMuted;
        _curMuted = wpMuted;
        if (self.window && self.player.timeControlStatus != AVPlayerTimeControlStatusPlaying)
            [self.player play];
    }
    [self refreshGeometry];
}

- (void)loadPath:(NSString *)path {
    _curPath = path;
    [self stopVideo];
    if (!diWallpaperIsVideo(path)) {
        _imgV.hidden = NO;
        UIImage *im = [UIImage imageWithContentsOfFile:path];
        _imgV.image = im;
        _playerLayer.hidden = YES;
        if (!im) DLog(@"壁纸图片读取失败: %@", path);
        else DLog(@"壁纸已加载(图片): %@ 原始尺寸 %.0fx%.0f, 按原图比例铺满(不拉伸)",
                  path.lastPathComponent, im.size.width, im.size.height);
        [self refreshGeometry];
        return;
    }
    /* 视频: 剥掉音轨再播 —— 与岛上视频同一套做法, 避免 SpringBoard 激活音频会话把别人打断 */
    _imgV.hidden = YES;
    _imgV.image = nil;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path]
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVPlayerItem *item = nil;
    @try {
        AVAssetTrack *vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (vt) {
            AVMutableComposition *comp = [AVMutableComposition composition];
            AVMutableCompositionTrack *cv = (AVMutableCompositionTrack *)[comp addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                                   preferredTrackID:kCMPersistentTrackID_Invalid];
            if ([cv insertTimeRange:CMTimeRangeMake(kCMTimeZero, asset.duration) ofTrack:vt atTime:kCMTimeZero error:NULL])
                item = [AVPlayerItem playerItemWithAsset:comp];
        }
    } @catch (NSException *e) { item = nil; }
    if (!item) item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
    self.player.muted = YES;   /* 2.7.4: 壁纸视频一律静音, 不受"视频静音"开关影响, 绝不打扰其他音频 */
    self.player.volume = 0.0f;
    _looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:item];
    _playerLayer.hidden = NO;
    if (self.window) [self.player play];
    DLog(@"壁纸已加载(视频): %@", path.lastPathComponent);
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) { [self.player pause]; return; }
    [self refreshGeometry];
    BOOL isVideo = (_curPath.length && diWallpaperIsVideo(_curPath));
    if (wpOn && isVideo) [self.player play]; else [self.player pause];
}

- (void)traitCollectionDidChange:(UITraitCollection *)prev {
    [super traitCollectionDidChange:prev];
    if (!wpFollowDark) return;
    NSString *k = [self traitKey];
    if (!_curTraitKey || ![_curTraitKey isEqualToString:k]) {
        DLog(@"外观切换 → %@, 重载壁纸", k);
        [self reload];
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
@property (nonatomic, assign) double lastSc;   // 2.2.22: 每层独立"上次应用参数"
@property (nonatomic, assign) double lastOx;
@property (nonatomic, assign) double lastOy;
@property (nonatomic, assign) BOOL miniMode;      // 2.7.26: 小岛模式(歌词岛左右帧率)
@property (nonatomic, assign) NSInteger side;     // miniMode 下 0=专辑位(左) 1=音频位(右)
/* 2.8.22 功耗: 动态帧率记账 —— 岛静止 1 秒链接 60→30fps(序列帧推进由累加器
   保证速度不变), 几何一动立即回 60fps。 */
@property (nonatomic, assign) CGFloat dynW;
@property (nonatomic, assign) CGFloat dynH;
@property (nonatomic, assign) NSInteger dynIdle;
@end

/* 定位原生音频层: 音乐岛的跨进程内容通过 CALayerHost 渲染(高约488, 只在音乐岛出现, 其他岛没有)。
   找到 = 当前是音乐岛展开(帧率素材允许显示 / 音频开关可隐藏它); 找不到 = 非音乐岛 */
static CALayer *diFindAudioLayer(UIView *host) {
    if (!host) return nil;
    /* CPU 优化: 结果缓存(弱引用) + 0.25秒限频重扫; 层被释放时弱读 nil 自动重扫 */
    static __weak CALayer *wCache; static CFAbsoluteTime tScan;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    __strong CALayer *cached = wCache;
    if (cached && now - tScan < 0.25) {
        /* 2.8.14: 缓存层必须还在这个宿主的树里才算数 —— 展开动画稳定那一刻系统会
           重建门户层, 旧层已脱落但弱引用还活着, 0.25s 内一直返回失效层 →
           掩码挖在没人看的旧层上, 新层没掩码 → 波形闪一帧(用户报的"展开后显示一帧")。
           发现不在树里立刻作废缓存重扫。 */
        CALayer *up = cached;
        while (up && up != host.layer) up = up.superlayer;
        if (up == host.layer) return cached;
        wCache = nil;
    }
    CALayer *found = nil;
    CGFloat hostArea = host.bounds.size.width * host.bounds.size.height;
    NSMutableArray<CALayer *> *stack = [NSMutableArray arrayWithObject:host.layer];
    while (stack.count) {
        CALayer *l = stack.firstObject; [stack removeObjectAtIndex:0];
        for (CALayer *s in l.sublayers) {
            [stack addObject:s];
            if ([NSStringFromClass(s.class) containsString:@"CALayerHost"] && s.frame.size.height > 300) { found = s; break; }
            /* 2.8.15: 系统默认展开岛(285 日志实测 330x72 / 333x65)没有高>300 的
               CALayerHost, App 内容门户是 CAPortalLayer 314x71.3 —— 旧判据对它全不命中,
               展开岛音频开关等于没开(用户原话"展开岛的音频你没有隐藏")。
               按"大面积门户"认它: 面积≥岛面积35% 且宽≥岛宽45%。
               小岛的门户只有 26x22/22x22(面积≈6%), 天然不命中, 各判定不受影响。 */
            if ([NSStringFromClass(s.class) containsString:@"CAPortalLayer"]) {
                CGRect pr = [host.layer convertRect:s.frame fromLayer:s.superlayer];
                if (pr.size.width * pr.size.height >= hostArea * 0.35
                    && pr.size.width >= host.bounds.size.width * 0.45) { found = s; break; }
            }
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
__attribute__((unused)) static BOOL diMiniMusicActive(UIView *host) {
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
    /* 2.6.13: 记下"这就是音乐岛", 视频层用它区分音乐岛与充电/人脸等系统岛 */
    if (gMiniHost != host) gMiniHost = host;
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

/* 2.7.26: 小岛专辑/音频位置帧率素材(2.2.45 stepMini 原版, 2.7.0 误删后补回) */
- (void)stepMini {
    @try {
    if (_link.preferredFramesPerSecond > 30) _link.preferredFramesPerSecond = 30;  /* 3.0.25 功耗: 小岛固定 30fps */
    UIView *host = self.superview;
    if (!host || host.window == nil) { self.hidden = YES; if (++_miss > 15) _link.paused = YES; return; }
    syncNativeSpectrum(host);
    BOOL mini = host.bounds.size.height > 20 && host.bounds.size.height <= 60 && host.bounds.size.width > 40;
    /* 2.8.22 功耗: diMiniMusicActive 每次全树遍历(300 节点), 以前每帧跑,
       两层素材 60fps = 每秒 240 次遍历。加 0.15s 同宿主缓存(与
       diIsNowPlayingHostCached 同思路), 放歌卡顿的第二元凶。 */
    static __weak UIView *sMMAHost; static BOOL sMMARes; static CFAbsoluteTime sMMAT;
    BOOL mediaActive;
    if (sMMAHost == host && CFAbsoluteTimeGetCurrent() - sMMAT < 0.15) {
        mediaActive = sMMARes;
    } else {
        mediaActive = diMiniMusicActive(host);
        sMMAHost = host; sMMARes = mediaActive; sMMAT = CFAbsoluteTimeGetCurrent();
    }
    BOOL musicGate;
    NSArray<NSString *> *frames;
    /* 3.0.25 功耗: 这两项以前每帧都算 —— AVAudioSession 查询 + 目录签名比对,
       两层素材 60fps 就是每秒 240 次。现在 0.25s/0.5s 缓存, 开关和换素材本来
       也允许半秒内生效; 放歌发热的 CPU 大头就在这类"每帧白干"上。 */
    {
        static BOOL sGate; static CFAbsoluteTime sGateT;
        static NSArray<NSString *> *sFrL, *sFrR; static CFAbsoluteTime sFrTL, sFrTR;
        CFAbsoluteTime nowS = CFAbsoluteTimeGetCurrent();
        if (nowS - sGateT > 0.25) {
            sGateT = nowS;
            sGate = AVAudioSession.sharedInstance.isOtherAudioPlaying || (diFindAudioLayer(host) != nil);
        }
        musicGate = sGate;
        if (self.side == 1) {
            if (!sFrR || nowS - sFrTR > 0.5) { sFrTR = nowS; sFrR = framePathsFor(miniAudioFolder); }
            frames = sFrR;
        } else {
            if (!sFrL || nowS - sFrTL > 0.5) { sFrTL = nowS; sFrL = framePathsFor(smallAnimFolder); }
            frames = sFrL;
        }
    }
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
    /* 3.0.25 功耗: 小岛素材链路固定 30fps —— 小岛只有 37pt 高, 序列帧推进靠累加器,
       视觉速度不变, CPU/功耗直接减半(用户反馈"听歌明显发热"的主力之一)。 */
    if (self.miniMode) { [self stepMini]; return; }   /* 2.7.26: 小岛左右两层走独立分支 */
    /* 2.8.22 功耗: 动态帧率 —— 宿主几何不动约 1 秒, 链接 60→30fps;
       序列帧推进用累加器(dt×fps), 视觉速度不变; 几何一动立即回 60fps。 */
    if (self.superview) {
        CGSize ds = self.superview.bounds.size;
        if (fabs(ds.width - self.dynW) > 0.5 || fabs(ds.height - self.dynH) > 0.5) {
            self.dynW = ds.width; self.dynH = ds.height; self.dynIdle = 0;
            if (_link.preferredFramesPerSecond != 60) _link.preferredFramesPerSecond = 60;
        } else if (++self.dynIdle > 45 && _link.preferredFramesPerSecond != 30) {
            _link.preferredFramesPerSecond = 30;
        }
    }
    UIView *host = self.superview;
    if (!host || host.window == nil) { self.hidden = YES; if (++_miss > 15) _link.paused = YES; return; }
    syncNativeSpectrum(host); // 无条件每帧同步音频掩码(即使帧率素材关闭/没放歌): 岛重新展开或层重建时波形立即被藏
    /* 帧率图只在播放音乐的展开岛显示(实测展开音乐岛约407x202); 其他一切形态全部禁用:
       锁屏大卡(高700+)/方形提示岛/通话岛/小岛(高36)/视频展开岛(无音频层) 一律不显示 */
    BOOL expand = host.bounds.size.height > 100 && host.bounds.size.height < 300
               && host.bounds.size.width > 250 && host.bounds.size.width < 500;
    /* 3.0.25 功耗: 帧列表 0.5s 缓存(以前每帧比对目录签名) */
    static NSArray<NSString *> *sFrE; static CFAbsoluteTime sFrTE;
    CFAbsoluteTime nowE = CFAbsoluteTimeGetCurrent();
    if (!sFrE || nowE - sFrTE > 0.5) { sFrTE = nowE; sFrE = framePaths(); }
    NSArray<NSString *> *frames = sFrE;
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

/* ── 遮罩公共件(2.6.14 重写时保留) ─────────────────────────────── */

static NSInteger gMaskGen = 0;   /* 遮罩素材换代计数, 设置页换素材时自增 */

/* 素材列表: 递归扫描(最多 4 层深), 支持 png/jpg/jpeg; 排序一律用 block 比较器,
   不用 localizedCompare(它对 __NSCFString 会抛 unrecognized selector)。
   2.7.45: 加 2 秒缓存。上一版是 step 里每 0.4 秒重扫一次(两个探针实例叠加),
   等于每秒 5 次递归遍历 — 展开动画期间卡顿、且可能扫到目录的中间态。 */
static NSArray<NSString *> *diMaskListAssets(void) {
    static NSArray<NSString *> *sCache = nil;
    static CFAbsoluteTime sT = 0;
    static NSInteger sGen = -1;
    if (sCache && CFAbsoluteTimeGetCurrent() - sT < 2.0 && sGen == gMaskGen) return sCache;
    sT = CFAbsoluteTimeGetCurrent();
    sGen = gMaskGen;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:kMaskDir isDirectory:&isDir] || !isDir) { sCache = @[]; return sCache; }

    NSMutableArray<NSString *> *queue = [NSMutableArray arrayWithObject:@""];
    int depthGuard = 0;
    while (queue.count && depthGuard++ < 200) {
        NSString *rel = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSInteger depth = rel.length ? ([rel componentsSeparatedByString:@"/"].count) : 0;
        NSString *full = rel.length ? [kMaskDir stringByAppendingPathComponent:rel] : kMaskDir;
        NSArray *items = [fm contentsOfDirectoryAtPath:full error:NULL];
        if (![items isKindOfClass:NSArray.class]) continue;
        items = [items sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            NSString *sa = [a isKindOfClass:NSString.class] ? a : @"";
            NSString *sb = [b isKindOfClass:NSString.class] ? b : @"";
            return [sa compare:sb options:NSCaseInsensitiveSearch | NSNumericSearch];
        }];
        for (NSString *n in items) {
            if (![n isKindOfClass:NSString.class]) continue;
            if ([n hasPrefix:@"."]) continue;
            NSString *childRel = rel.length ? [rel stringByAppendingPathComponent:n] : n;
            NSString *childFull = [kMaskDir stringByAppendingPathComponent:childRel];
            BOOL d = NO;
            if (![fm fileExistsAtPath:childFull isDirectory:&d]) continue;
            if (!d) {
                NSString *ext = n.pathExtension.lowercaseString;
                if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] ||
                    [ext isEqualToString:@"jpeg"]) [out addObject:childRel];
            } else if (depth < 3) {
                [queue addObject:childRel];
            }
        }
    }
    sCache = [out copy];
    return sCache;
}

/* ===== 2.6.39: 只做"小岛左侧专辑头像"一件事 =====

   用户要的: 小岛(收缩态)左边那个专辑头像, 按遮罩素材的形状抠出来。
             不要展开岛、不要歌词、不要整个岛转动。

   230 日志给出的确定信息:
     · 小岛宿主 166x37 / 185x52 / 189x53, 内容全压在 CALayerHost 407x489 里
       (位置 @(-436,0) / @(-421,0) —— 负数 x, 说明这块大画面是"以岛的中点为基准"摆的)
     · 展开态宿主 407x202, 同一个 CALayerHost 407x489 @(0,0), 只是 scale 不同

   所以本版的取值方式很硬:
     ① 只认"小岛": 高 26~62pt 且宽 > 高 * 1.6, 而且左边那块有内容(不是音量条那种细横条)
     ② 专辑头像 = 小岛的**左侧正方形**, 边长 = 岛高 h, 矩形 = (0,0,h,h)
        —— 不再去视图树里找图层(那里根本没有), 直接按"小岛布局"取。
     ③ 遮罩形状 = 素材铺满这个 h×h 方块(ScaleToFill)。素材多大都一样。
     ④ 用一块只覆盖 (0,0,h,h) 的小玻璃, 里面放"从 CALayerHost 里裁出来的那块画面",
        外面套素材蒙版。玻璃尺寸 == 专辑尺寸, 所以永远不会盖到歌词/右侧。

   这一版是否成立, 只看日志三行:
       遮罩小岛: 宿主=185x52 头像=52pt
       遮罩裁图: 源 407x489 → 52x52 @(-436,0)
       遮罩显示: 52x52 素材=Mask.png
   如果"遮罩裁图"失败(截不到画面), 会退到 MediaRemote 封面 —— 一样是圆的, 一样贴在这个位置。 */

/* ===== 2.7.24: 专辑图在哪 —— 用真机视图树定死, 不再靠"裁 CALayerHost"猜 =====

   用户抓的岛内容树(iOS 16, 音乐在播, 收缩态):
     _SBSystemApertureContainerViewContentView 167x36.67
       UIView 167x36.67                       ← 只在这里兜底
         SAUIElementView 167x36.67
           UIView 167x36.67  (alpha 0)        ← 系统自己的一层占位
             SBUIProudLockIconView 11.33x15   ← 左侧图标(灵动岛左小图标)
               BSUICAPackageView
             UIView {118,-0.33,37,37}         ← ★ 右侧那 37x37 就是专辑封面
               BSUICAPackageView 37x37          (CA 包, 跨进程渲染, 拿不到位图)
           _SAUIProvidedViewContainerView ×3  ← 都是 alpha 0 的占位/门户
       UIImageView {-127,-137,426.67,310.67} alpha 0  ← 全屏残留, 不是封面

   两个关键结论:
     ① 封面是 **BSUICAPackageView**(CA 动画包), 不是 UIImageView, 也没有 CALayerHost。
        旧版 diFindContentLayer 找的是 "类名含 Host" 的层 → 永远找不到 → 只能退封面。
     ② 封面在**岛右侧**, 不是左边; 尺寸约等于岛高(37 vs 36.67)。

   所以本版改成:
     · 按"BSUICAPackageView / 带 CA 包的视图"直接定位封面那块;
     · 按它在宿主里的**真实相对位置**摆玻璃 —— 左就左, 右就右, 不再假设左侧;
     · 玻璃里放遮罩形状(素材) + 真实封面照(MediaRemote), 两层一起做蒙版。
   日志会打出 "遮罩命中: 封面=xxx 宿主=... 位置=(x,y) 边长=h", 一看就知道对不对。 */
/* 2.7.40: 视图(或其子层树)里有没有"可见的 CAPortalLayer"。
   268 日志铁证 —— 本机专辑头像住在
     SBSystemApertureSceneElementAccessoryPortalView {26x22@8}
   里的 CAPortalLayer(跨进程门户) 后面; 旧打分只认 BSUICAPackageView,
   小岛上没有 CA 包 → 全部候选 <100 分门槛 → 遮罩"经常不生效"。
   这里给门户候选开一条直通路。 */
/* 2.8.17: "这一层是被我们自己 alpha=0 藏掉的" 标记 —— 提前声明,
   因为 diViewHasVisiblePortal(2513) 要用它。藏层时存原始 alpha, 还原时清掉。 */
static char kDIMaskOrigAlphaKey;

/* 2.8.21: 被我们 layer.hidden=YES 藏掉的层 —— 全局登记表(弱引用)。
   291 日志实锤的死锁: 歌词岛门户隐藏循环(左侧专辑动画开着时)把左专辑门户层
   hidden=YES → diViewHasVisiblePortal 判"没有可见门户" → diIsNowPlayingHost
   连锁失败 → musicHost=NO → 左右帧率素材被一起撤掉 + 遮罩也不挂 →
   用户看到"打开左侧专辑就整个隐藏了, 左右都隐藏了, 也不显示帧率了"。
   2.8.17 给"视图 alpha=0"加了 hiddenByUs 标记, 这里给"layer hidden"补同款:
   凡是我们自己藏的层, 判定时继续算"可见"(藏是我们干的, 不是岛变了)。 */
static NSHashTable *gDiOurHiddenLayers(void) {
    static NSHashTable *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSHashTable weakObjectsHashTable]; });
    return t;
}
static void diMarkLayerHiddenByUs(CALayer *l) { if (l) [gDiOurHiddenLayers() addObject:l]; }
static void diUnmarkLayerHiddenByUs(CALayer *l) { if (l) [gDiOurHiddenLayers() removeObject:l]; }

static BOOL diViewHasVisiblePortal(UIView *v) {
    if (!v) return NO;
    /* 2.8.17: 被我们藏掉的层仍然算"有门户"。
       287 日志铁证: 玻璃每帧在 (2.85,7.85) 和 (148.18,7.85) 之间横跳 ——
       diHideViewsNear 把左侧专辑层 alpha 置 0 → 下一帧重扫时这一层被判不可见 →
       候选落到右侧音频门户(22x22@155) → 藏右侧 → 再跳回左侧 …… 就是用户报的
       "两边闪"。藏是我们自己干的, 扫描时必须装看不见。 */
    BOOL hiddenByUs = (objc_getAssociatedObject(v, &kDIMaskOrigAlphaKey) != nil);
    NSMutableArray<CALayer *> *st = [NSMutableArray arrayWithObject:v.layer];
    int g2 = 0;
    while (st.count && g2++ < 60) {
        CALayer *l = st.firstObject; [st removeObjectAtIndex:0];
        if ([NSStringFromClass(l.class) containsString:@"CAPortalLayer"]
            && (!l.isHidden || [gDiOurHiddenLayers() containsObject:l])   /* 2.8.21: 我们藏的层仍算可见 */
            && (l.opacity > 0.05 || hiddenByUs) && l.bounds.size.width >= 12) return YES;
        for (CALayer *x in l.sublayers) [st addObject:x];
    }
    return NO;
}

/* 2.8.15: 音乐岛判定(遮罩专用) —— 只有"正在放歌的小岛"才给专辑上遮罩。
   285 日志铁证: 微信/短信等通知岛(本地 UIImageView 头像 28x28/36x36)也被挂了
   遮罩+旋转, 用户原话"我只需要播放歌曲的专辑封面头像"。
   2.8.18：结构判据改成"一对 accessory 门户"(左专辑 26x22 + 右音频 22x22),
   288 日志里充电岛/展开通知岛 330x72 的单块 314x71 内容门户再也过不了关。
   两条同时满足才放行:
   ① 在播: MRMediaRemote 在播(优先, 前台 App 放歌时 isOtherAudioPlaying 是 NO)
      或 其他 App 在放声;
   ② 结构: 左槽专辑门户 + 右槽音频门户同时存在(音乐岛独有结构)。
   通知岛/充电岛配不出这一对 → 不遮。暂停播放时也不遮。 */
static BOOL diIsNowPlayingHost(UIView *host) {
    if (!host) return NO;
    BOOL playing = mrQueryOK ? musicPlaying : AVAudioSession.sharedInstance.isOtherAudioPlaying;
    if (!playing) return NO;
    CGSize hs = host.bounds.size;
    if (hs.width < 20 || hs.height < 20) return NO;
    /* 2.8.18: 判据收敛成"一对 accessory 门户"。音乐岛的固定结构是
       左槽专辑门户(26x22) + 右槽音频门户(22x22), 两个都在、都落在 18~40pt 内。
       288 日志铁证: 充电岛 / 展开的通知岛 330x72 里只有一整块
       `_SAUIProvidedViewContainerView(314x71@8,0)` 内容门户 + 一个通知头像
       `UIImageView(28x28@13,22)`, 旧判据(① 任何可见门户 / ② 大面积门户层)
       两条都会命中 —— 于是头像被当成专辑套了遮罩还转起来, 用户原话
       "展开岛 充电岛都会显示小专辑旋转, 那个我不需要"。
       现在必须左右成对: 通知岛/充电岛永远配不出这一对, 一律不碰。
       注意音频门户只判"存在"不判可见 —— 音频开关把它们 hidden 之后,
       音乐岛仍然是音乐岛, 不能因此掉遮罩。 */
    BOOL hasAlbum = NO, hasAudio = NO, hasAlbumAnim = NO;
    NSMutableArray<UIView *> *vs = [NSMutableArray arrayWithObject:host];
    int gv = 0;
    while (vs.count && gv++ < 200) {
        UIView *v = vs.firstObject; [vs removeObjectAtIndex:0];
        CGFloat vw = v.bounds.size.width, vh = v.bounds.size.height;
        NSString *cn = NSStringFromClass(v.class);
        if (vw >= 18 && vw <= 40 && vh >= 14 && vh <= 34
            && [cn containsString:@"ProvidedViewContainer"]) {
            CGRect r = [v convertRect:v.bounds toView:host];
            CGFloat nx = (r.origin.x + r.size.width * 0.5) / MAX(1.0, hs.width);
            CGFloat ar = vw / MAX(1.0, vh);
            if (nx < 0.45) { if (diViewHasVisiblePortal(v)) hasAlbum = YES; }
            else if (nx > 0.55 && ar > 0.75 && ar < 1.35) hasAudio = YES;
        }
        /* 音乐岛的专辑动效层: 系统只在"音乐播放岛"里放 DynamicAnimationView 36x36,
           通知岛(NBXLddClassic3View + 头像)和充电岛都没有这层。 */
        if ([cn containsString:@"DynamicAnimationView"]
            && vw >= 30 && vw <= 44 && vh >= 30 && vh <= 44) hasAlbumAnim = YES;
        for (UIView *c in v.subviews) [vs addObject:c];
    }
    /* 音频门户在某些系统状态(调音量时)会被临时换掉, 那时音乐岛仍然要遮罩,
       所以"左专辑门户 + 专辑动效层"也算成立; 反过来只认动效层不行(必须真有专辑门户)。 */
    return (hasAlbum && (hasAudio || hasAlbumAnim));
}

/* 上面那个判定每帧全树遍历太贵, 加缓存; 岛尺寸变了(展开/收起/换岛)
   或换了宿主立刻重算。暂停/播放的切换最多延迟 0.12s, 肉眼无感。
   2.8.22: 单槽缓存 → 多槽弱键缓存。2.8.21 起 updateSingleVideo 每轮要问
   遍窗口里每个岛"你是不是音乐岛", 单槽缓存被问一个抖一次, 每次都全树遍历;
   syncNativeSpectrum / 遮罩探针也在用, 一起受益。条目上限 8, 防临时岛刷爆。 */
static BOOL diIsNowPlayingHostCached(UIView *host) {
    if (!host) return NO;
    static NSMapTable *sCache;   // key=宿主(弱) value=@[time, w, h, result]
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sCache = [NSMapTable weakToStrongObjectsMapTable]; });
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSArray *e = [sCache objectForKey:host];
    if (e && now - [e[0] doubleValue] < 0.12
        && fabs(host.bounds.size.width  - [e[1] doubleValue]) < 2.0
        && fabs(host.bounds.size.height - [e[2] doubleValue]) < 2.0) return [e[3] boolValue];
    BOOL result = diIsNowPlayingHost(host);
    if (sCache.count > 8) [sCache removeAllObjects];
    [sCache setObject:@[@(now), @(host.bounds.size.width), @(host.bounds.size.height), @(result)]
               forKey:host];
    return result;
}

/* 2.8.15: 在封面附近找"系统专辑方块层" —— 18~56pt 的本地方形视图,
   圆心与封面中心相距 <14pt。它才是真正画专辑的那层(门户只是容器),
   比门户大(展开态实测 36x36 vs 门户 26x22)。返回最大的那个, 找不到返回 nil。
   用途: ① 玻璃按它的尺寸画(完整盖住专辑, 不再露黑边/方角);
         ② 把它藏掉(alpha=0), 系统那张方形专辑才不会从玻璃后面露出来。 */
static UIView *diFindAlbumSquareNear(UIView *host, CGRect coverRect, CGRect *outRect) {
    if (!host) return nil;
    CGFloat ccx = coverRect.origin.x + coverRect.size.width * 0.5;
    CGFloat ccy = coverRect.origin.y + coverRect.size.height * 0.5;
    UIView *best = nil;
    CGRect bestRect = CGRectZero;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:host];
    int g = 0;
    while (stack.count && g++ < 300) {
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0];
        NSString *cn = NSStringFromClass(v.class);
        BOOL ourView = [cn isEqualToString:@"DIMaskView"] || [cn isEqualToString:@"DIAnimView"]
                    || [cn isEqualToString:@"DIVideoView"];
        if (!ourView) { for (UIView *c in v.subviews) [stack addObject:c]; }
        if (v == host || ourView) continue;
        if ([cn containsString:@"ProvidedViewContainer"] || [cn containsString:@"AccessoryPortal"]
            || [cn containsString:@"Portal"]) continue;   /* 门户容器不算, 要的是本地方块 */
        CGRect r = [v convertRect:v.bounds toView:host];
        if (r.size.width < 18 || r.size.height < 18) continue;
        /* 2.8.17: 上限按形态放开 —— 富展开(407x201)的专辑方块比小岛大得多,
           卡 56 会找不到, 玻璃就只能按 26x22 门户画(用户: "展开岛专辑没遮罩/太小")。 */
        CGFloat maxSq = (host.bounds.size.height > 90.0) ? 82.0 : 56.0;
        if (r.size.width > maxSq || r.size.height > maxSq) continue;
        CGFloat sq = 1.0 - MIN(1.0, fabs(r.size.width - r.size.height) / MAX(r.size.width, r.size.height));
        if (sq < 0.85) continue;                          /* 要正方形 */
        CGFloat dx = fabs(r.origin.x + r.size.width * 0.5 - ccx);
        CGFloat dy = fabs(r.origin.y + r.size.height * 0.5 - ccy);
        if (dx > 18.0 || dy > 18.0) continue;             /* 要与封面同心 */
        if (r.size.width * r.size.height > bestRect.size.width * bestRect.size.height) {
            best = v; bestRect = r;
        }
    }
    if (outRect) *outRect = bestRect;
    return best;
}

static UIImageView *diFindAlbumCoverView(UIView *host, CGRect *outFrame) {
    if (!host) return nil;
    CGSize hs = host.bounds.size;
    /* 2.7.45: 小岛态学到的"专辑在左槽还是右槽"。用户机 268/274 两份日志一致:
       小岛 166x37 / 185x52 时, 专辑门户都是左边 _SAUIProvidedViewContainerView(26x22@8,15),
       右槽 22x22 是音频。展开态 407x202 时两个门户搬到 (28,90) / (355,90), 分值几乎打平。
       把槽位记住, 展开态就不会再选错。 -1 = 还没学到。
       2.8.17: 上面这条"学习槽位"的老做法已废弃 —— 学习本身会被右侧音频门户抢先学走,
       且藏层后重扫会让候选漂移(两边闪)。现在固定"专辑在左半边", 右半边直接 0 分。 */
    UIImageView *best = nil;
    CGRect bestRect = CGRectZero;
    CGFloat bestScore = -1;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:host];
    int g = 0;
    /* 2.7.37: 把所有候选打一次日志(8s 节流) —— 遮罩挂错位置时一眼看出选中了谁 */
    NSMutableString *cand = nil;
    {
        static CFAbsoluteTime sLastCand;
        if (CFAbsoluteTimeGetCurrent() - sLastCand > 8.0) { sLastCand = CFAbsoluteTimeGetCurrent(); cand = [NSMutableString string]; }
    }
    while (stack.count && g++ < 400) {
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0];
        /* 2.8.14: 我们自己的注入视图(玻璃/帧率/视频)及其子树一律跳过 ——
           284 日志铁证: 展开态实例B把实例A画的玻璃(DIMaskView 28x28@13,22)当成
           "专辑封面"又画了一份 → 两个专辑 + 位置偏移(用户截图里大专辑左下那小方块)。
           不跳子树也不行: 玻璃内层 _artView 也是 18~48pt 方块, 会命中展开态兜底分支。 */
        NSString *cn0 = NSStringFromClass(v.class);
        BOOL ourView = [cn0 isEqualToString:@"DIMaskView"] || [cn0 isEqualToString:@"DIAnimView"]
                    || [cn0 isEqualToString:@"DIVideoView"];
        if (!ourView) { for (UIView *c in v.subviews) [stack addObject:c]; }
        if (v == host || ourView) continue;
        NSString *cn = cn0;
        BOOL isCA = [cn containsString:@"BSUICAPackage"] || [cn containsString:@"CAPackage"]
                 || [cn containsString:@"CAAnimation"];
        /* 2.7.40: 门户候选 —— 专辑头像所在的 accessory 门户(左 26x22) / 音频 accessory(右 22x22) */
        BOOL isPortal = ([cn containsString:@"AccessoryPortalView"] || [cn containsString:@"ProvidedViewContainer"]);
        CGRect r = [v convertRect:v.bounds toView:host];
        if (r.size.width < 8 || r.size.height < 8) continue;

        /* 打分。真机上候选通常是两个 CA 包:
             · 专辑  37x37    正方形, 边长≈岛高     ← 要它
             · 锁图标 12.8x16.9 不是正方形, 边长≈岛高的 1/3 ← 不要
           所以打分必须同时看"正方度"和"贴合岛高", 不能只看面积,
           否则小岛/充电岛上只剩锁图标时会被误当成专辑。
           2.7.37: 再加一条**靠右加分** —— 265 录屏里左侧方块是应用图标, 专辑在右(@123),
           之前左右两块打平按遍历顺序选中了左边 → 用户看到"遮罩在左边遮挡"。 */
        CGFloat side = MIN(r.size.width, r.size.height);
        CGFloat sq = 1.0 - MIN(1.0, fabs(r.size.width - r.size.height) / MAX(r.size.width, r.size.height));
        CGFloat ratio = side / MAX(1.0, hs.height);
        CGFloat fit = 1.0 - MIN(1.0, fabs(1.0 - ratio));
        /* 2.8.17: 靠左加分(原来靠右)。本机实测专辑固定在小岛左槽, 右侧是音频波形;
           旧代码"靠右加分"会去抢波形那一块, 是"两边闪"的帮手之一。 */
        CGFloat leftBias = (1.0 - MIN(1.0, r.origin.x / MAX(1.0, hs.width))) * 60.0;
        CGFloat score = -1;
        if (isPortal) {
            /* 2.7.45: 展开态两个 accessory 门户会打平(实测 26x22@28,90 得 223 / 22x22@355,90 得 222),
               差 1 分靠遍历顺序决定, 展开岛遮罩时有时无就是这么来的。
               现在用**形状记忆**定死: 小岛态专辑在左侧(_SAUIProvidedViewContainerView 26x22@8,15),
               音频/波形在右侧(22x22) —— 记住小岛学到的横向归一化位置, 展开态一律往那边靠。
               而且音频门户固定是 22x22 正方形、专辑门户 26x22 略宽, 宽度比也并入打分。 */
            CGFloat maxSide = MIN(96.0, hs.height * 1.1);
            if (r.size.width >= 16 && r.size.height >= 16
                && r.size.width <= maxSide && r.size.height <= maxSide
                && diViewHasVisiblePortal(v)) {
                CGFloat nx = (r.origin.x + r.size.width * 0.5) / MAX(1.0, hs.width);
                /* 2.8.17: 不再"学习"槽位, 也不再让右槽参与。
                   287 日志铁证: 玻璃每帧在左侧(2.85)和右侧(148.18)之间横跳 ——
                   右侧那个 22x22@(155,15) 是**音频波形门户**, 被当成专辑画了玻璃。
                   用户机小岛 185x52 的专辑门户实测固定在左侧
                   (_SAUIProvidedViewContainerView 26x22@8,15), 右侧永远是音频。
                   所以: 右半边(nx>0.52)的门户直接不给分; 左半边固定加分。
                   这样"关掉右侧音频开关"也不可能再影响专辑那一侧。 */
                if (nx >= 0.52) {
                    score = 0.0;
                } else {
                    CGFloat slotBonus = 30.0;
                    /* 音频门户是正方的 22x22; 专辑门户 26x22 → 宽高比 1.18, 给一点加分 */
                    CGFloat wideBonus = (r.size.width / MAX(1.0, r.size.height) > 1.10) ? 8.0 : 0.0;
                    score = 140.0 + slotBonus + wideBonus
                          + MIN(r.size.width, r.size.height) * 3.0 + sq * 20.0
                          - nx * 5.0;
                }
            } else {
                score = 5.0;
            }
        }
        else if (isCA && sq >= 0.8) score = 100.0 + sq * 40.0 + fit * 30.0 + side * 0.5 + leftBias;
        else if (isCA) score = 30.0 + fit * 10.0;      /* 细长/异形 CA 包: 图标/波形, 不是封面 */
        else if (sq > 0.65 && ratio > 0.5 && ratio < 1.8) score = 20.0 + sq * 10.0 + fit * 10.0;
        /* 2.8.13: 展开态专辑方块兜底 —— 展开岛的专辑画在 App 自己的门户里(远程像素,
           挂 mask 无效), 但系统会在原位放一个 20~44pt 的本地方块层(专辑底座)。
           按"正方形 + 左侧 + 垂直居中"认它, 用它定位我们的自绘玻璃。 */
        if (score < 100.0 && !isCA && sq >= 0.85
            && r.size.width >= 18 && r.size.height >= 18
            /* 2.8.17: 富展开(407x201)的专辑方块比小岛大不少, 上限按形态放开到 82,
               否则 60x60 的方块层进不来, 只能退到 26x22 门户 → 玻璃画得特别小。 */
            && r.size.width <= ((hs.height > 90.0) ? 82.0 : 48.0)
            && r.size.height <= ((hs.height > 90.0) ? 82.0 : 48.0)
            && r.size.width <= hs.width * 0.5
            /* 2.8.17: 只认左半边的方块 —— 右侧 22x22 是音频, 认了就会两边闪 */
            && ((r.origin.x + r.size.width * 0.5) / MAX(1.0, hs.width)) < 0.5) {
            CGFloat cyN = (r.origin.y + r.size.height * 0.5) / MAX(1.0, hs.height);
            CGFloat cxn = (r.origin.x + r.size.width * 0.5) / MAX(1.0, hs.width);
            CGFloat centerV = (1.0 - MIN(1.0, fabs(cyN - 0.5) * 2.0)) * 40.0;  /* 垂直居中加分 */
            CGFloat leftBias = (1.0 - MIN(1.0, cxn)) * 20.0;                   /* 靠左加分 */
            score = 60.0 + sq * 20.0 + MIN(r.size.width, r.size.height) * 0.6
                  + centerV + leftBias;
            /* 2.8.15: 展开态(富展开 407x202 / 系统默认展开 330x72)必须优先选这个
               本地方形专辑层, 而不是 26x22 的门户容器 —— 265 日志铁证: 展开态门户
               (140+30+8+78+18≈274)一直压着专辑方块(≈131), 玻璃按 26x22 画,
               系统那张 36x36 方形专辑四圈全露出来 → 用户看到"还是方的 + 多了一个显示"。
               展开态给方块层加分压过门户(门户最高 ~274), 且只加给左侧的
               (右侧 22x22 波形门户不能抢)。 */
            if (hs.height > 62 && cxn < 0.35) score += 220.0;
        }
        if (cand) [cand appendFormat:@" %@%@(%.0fx%.0f@%.0f,%.0f)分%.0f%@ |",
                       cn, isCA ? @"[CA]" : @"", r.size.width, r.size.height,
                       r.origin.x, r.origin.y, score,
                       (isPortal && score > 5.0) ? ((r.origin.x + r.size.width * 0.5) / MAX(1.0, hs.width) < 0.5 ? @"左槽" : @"右槽") : @""];
        if (score > bestScore) { bestScore = score; best = (UIImageView *)v; bestRect = r; }
    }
    if (cand.length) DLog(@"遮罩候选:%@", cand);
    /* 门槛: 太不像封面(比如只剩锁图标)就不认, 免得把遮罩挂在奇怪的地方 */
    if (bestScore < 100.0) { if (outFrame) *outFrame = CGRectZero; return nil; }
    if (best && outFrame) *outFrame = bestRect;
    return best;
}

/* 在小岛宿主里找"大内容层"(CALayerHost, 面积 > 宿主 30%), 返回它换算到宿主坐标的 frame */
__attribute__((unused)) static CALayer *diFindContentLayer(UIView *host, CGRect *outFrame) {
    if (!host) return nil;
    NSMutableArray<CALayer *> *stack = [NSMutableArray arrayWithObject:host.layer];
    int g = 0;
    while (stack.count && g++ < 800) {
        CALayer *l = stack.firstObject; [stack removeObjectAtIndex:0];
        for (CALayer *s in l.sublayers) [stack addObject:s];
        if (![NSStringFromClass(l.class) containsString:@"Host"]) continue;
        CGRect r = l.frame;
        CALayer *p = l.superlayer;
        while (p && p != host.layer) { r = [p convertRect:r toLayer:host.layer]; p = p.superlayer; }
        if (p != host.layer) continue;
        if (r.size.width * r.size.height < host.bounds.size.width * host.bounds.size.height * 0.3) continue;
        if (outFrame) *outFrame = r;
        return l;
    }
    return nil;
}

/* 从内容层里"抠"出指定矩形那块画面。
   两级:
     ① 真截取: 新开一个同尺寸的 CALayerHost, 把源层的 contextID / 尺寸对上,
        再把它渲染进位图 —— 这一步能拿到跨进程画面的真实像素。
     ② 失败: 返回 nil, 由调用方退到 MediaRemote 封面。 */
__attribute__((unused)) static UIImage *diGrabLayerRect(CALayer *content, CGRect srcRect, CGSize outSize) {
    if (!content || outSize.width < 6 || outSize.height < 6) return nil;
    @try {
        /* ① 复制一份 CALayerHost, 只显示源矩形那块 */
        CALayer *host2 = nil;
        NSData *d = [NSKeyedArchiver archivedDataWithRootObject:content requiringSecureCoding:NO error:NULL];
        if (d) host2 = [NSKeyedUnarchiver unarchivedObjectOfClass:[CALayer class] fromData:d error:NULL];
        if (!host2) return nil;

        CGRect src = content.bounds;
        if (src.size.width < 2 || src.size.height < 2) src = content.frame;
        host2.bounds = CGRectMake(0, 0, outSize.width, outSize.height);
        host2.position = CGPointMake(outSize.width * 0.5, outSize.height * 0.5);
        host2.anchorPoint = CGPointMake(0.5, 0.5);
        /* 把源矩形挪到 (0,0): 反向平移再缩放 */
        CGFloat sx = outSize.width / MAX(1.0, srcRect.size.width);
        CGFloat sy = outSize.height / MAX(1.0, srcRect.size.height);
        host2.transform = CATransform3DConcat(CATransform3DMakeScale(sx, sy, 1.0),
                                              CATransform3DMakeTranslation(-srcRect.origin.x, -srcRect.origin.y, 0));
        host2.opacity = 1.0;
        host2.hidden = NO;

        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.opaque = NO; fmt.scale = 1.0;
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:outSize format:fmt];
        UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
            @try { [host2 renderInContext:rc.CGContext]; } @catch (__unused NSException *e) {}
        }];
        if (img && img.size.width >= 6) return img;
    } @catch (__unused NSException *e) {}
    return nil;
}

/* 前置声明: DIMaskView 在下面, 这些工具函数在它之后定义 */
static NSString *diMaskCurrentPathV2(void);
static UIImage *diMaskAlphaCached(NSString *path);
static UIImage *diNowPlayingArtworkV2(void);
static CGFloat diShapeRadiusOf(UIImage *shape, CGPoint *outCenter);

/* 2.7.27 蒙版自检: 这几个变量/函数定义在后面, 但 DIMaskView 的 step 要用 */
static double gDiMaskCoverage = -1;    /* 最近一次蒙版的不透明覆盖率 0~1 */
static BOOL gDiMaskHasAlpha = NO;      /* 素材本身带不带透明通道 */
static int gDiMaskThreshold = 0;       /* Otsu 阈值 */
/* 2.7.46: 生成蒙版时的真实 alpha 分布 —— 这两个数是"这张蒙版到底能不能裁"的铁证,
   和 遮罩自检 一起写进日志, 不用再靠 ASCII 预览猜。 */
static double gDiMaskOpaquePct = 0;    /* alpha>223 的像素占比 */
static double gDiMaskClearPct = 0;     /* alpha<32 的像素占比 */
static BOOL gDiMaskBuiltin = NO;       /* 是否用了内置兜底形状 */
static BOOL gDiMaskBrightIsShape = YES;
static NSString *diMaskAscii(UIImage *m);
static UIImage *diBuiltinMaskImage(void);
static double diMaskCoverageOf(UIImage *m);
static UIImage *diInvertMaskImage(UIImage *m);

/* ===== 2.7.24 遮罩探针 =====

   上一版(2.6.39~2.7.23)在专辑位置盖一块不透明玻璃, 里面放自己截的画面图,
   外面套素材蒙版。三个硬伤, 全都命中了用户抓的那棵树:
     ① 封面是 BSUICAPackageView(跨进程 CA 包), 截图拿不到 → 退 MediaRemote 封面,
        于是封面永远是静态旧图, 系统的动态/自动取色全没了;
     ② 位置按"左侧正方形 (0,0,h,h)"硬算, 而真机封面在**右侧** x=118 → 完全错位;
     ③ 自己画的图和系统封面叠在一起, 差半点就露馅。

   本版改为: **直接给原生专辑那层套 CALayer.mask**。
   CoreAnimation 的 mask 取的是 mask layer 的 alpha 通道 —— 系统自己就是这么
   做圆角/抠图形的。这样做的好处:
     · 专辑画面仍然是系统原生那一张(会动、会随歌换、会自动取色);
     · 素材形状从外部把多余的裁掉, 不存在"两张图叠不齐";
     · 关掉开关 = 把 mask 还原成原值(通常是 nil), 立刻恢复原生, 不留残影。

   探针(DIMaskView)本身**不画任何东西**: 它只是挂在岛容器里的一根天线,
   负责每帧找到专辑那层并把 mask 挂上去。 */
@interface DIMaskView : UIView
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, assign) NSInteger miss;
@property (nonatomic, copy) NSString *loadedPath;
@property (nonatomic, strong) UIImage *maskImg;
@property (nonatomic, assign) CGFloat rotDeg;
@property (nonatomic, assign) double lastTS;
@property (nonatomic, assign) NSInteger lastSide;
@property (nonatomic, assign) BOOL loggedShow;
@property (nonatomic, weak) UIView *coverV;      /* 当前挂了 mask 的那张专辑 */
@property (nonatomic, strong) NSHashTable *targets;  /* weak: 实际挂了 mask 的那些层 */
/* 2.7.29: 自绘玻璃 —— 探针自己画一张"专辑图 + 形状蒙版", 不再依赖系统那层肯不肯被裁 */
/* 2.8.15: 被我们藏起来的系统专辑层(弱引用表 + 各层原始 alpha 挂关联对象)。
   小岛态藏门户(26x22), 展开态藏专辑方块层(36x36)/图片视图 ——
   Album 中心(玻璃半径+6pt)内、12~64pt 的本地方层全藏(含任何重复画专辑的层,
   即用户报的"多了一个显示"), teardown 时统一还原。
   2.8.14 的黑色盖布(coverLayer)已删除 —— 它本身就是用户看到的"多了一个显示",
   而且盖不死系统那张方形专辑。 */
@property (nonatomic, strong) NSHashTable *hiddenViews;
@property (nonatomic, strong) UIView *artView;
@property (nonatomic, strong) UIImage *artImg;
@property (nonatomic, assign) double artTS;
@property (nonatomic, assign) BOOL artBusy;
@property (nonatomic, assign) BOOL loggedPaint;
@property (nonatomic, assign) BOOL loggedNoArt;
/* 2.8.13: 自绘玻璃模式(拿到专辑图时) —— 玻璃 = 专辑图 + 遮罩形状,
   旋转由一个内部子视图承载(外层玻璃不转, 展开态靠盖布盖住远程专辑) */
@property (nonatomic, assign) BOOL glassOn;
@property (nonatomic, assign) NSInteger glassMiss;
@property (nonatomic, assign) BOOL loggedNoArtTip;

/* ===== 2.8.16: 流畅度 & 形态闸门 =====
   286 反馈: "小岛到展开明显掉帧, 一卡一卡"。
   根因是我们每帧(60fps × 两个探针实例)都在做全树遍历(找封面/找方块层/藏层)、
   每帧改 subview 顺序(bringSubviewToFront 会触发系统岛容器整棵重排)、
   每帧给玻璃设 transform(打断 CoreAnimation 合成)。这些在展开动画里叠加起来
   就是肉眼可见的卡顿, 而且会把系统那边的动画一起拽慢。
   2.8.16 的改法:
     · 展开态**完全不参与**(用户明确要求删掉展开岛遮罩) → 展开全程零开销;
     · 尺寸连续变化时(动画中)直接 return, 只做一次 bounds 比较;
     · 旋转交给 CABasicAnimation 无限循环(GPU 合成), 不再每帧写 transform;
     · 找封面/找方块层结果按宿主尺寸缓存, 尺寸不变就不重算。 */
@property (nonatomic, assign) BOOL expandLock;      /* 保留字段(2.8.17 起不再用于跳过展开态) */
@property (nonatomic, assign) NSInteger stableFrm;  /* 尺寸连续不变的帧数 */
@property (nonatomic, assign) CGFloat lastBW, lastBH;
/* ===== 2.8.20: 宿主内容指纹 =====
   290 反馈: "打电话岛第一时间还是显示那个蒙版, 后面才隐藏"。
   来电/充电/通知岛出现时系统是把这个宿主的内容整体换掉(尺寸可能仍停在
   小岛的 185x52 一小会儿), 玻璃贴在原地就会在来电卡片上闪一帧。
   指纹 = 除自己以外的子视图数量 + 首/末子视图指针, 每帧只做两次指针比较
   (零遍历、零字符串), 一变就立刻收玻璃并还原系统专辑。 */
@property (nonatomic, assign) NSUInteger fpCount;
@property (nonatomic, weak) UIView *fpFirst;
@property (nonatomic, weak) UIView *fpLast;
/* 2.8.20: 展开结构缓存(2.8.21 起停用 —— 该闸门对音乐岛自身恒成立, 已改
   "尺寸稳定帧 + 收紧窗口", 见 step 里 ① 形态闸门重写。字段保留兼容)。 */
@property (nonatomic, assign) CFAbsoluteTime bigT;
@property (nonatomic, assign) BOOL bigCache;
@property (nonatomic, assign) CFAbsoluteTime scanT;  /* 上次重扫封面的时间(实例级, 别用 static) */
@property (nonatomic, weak) UIView *cacheCoverV;
@property (nonatomic, weak) UIView *cacheSqView;
@property (nonatomic, assign) CGRect cacheCoverRect;
/* 2.9.70: 小岛态确认过的封面槽位 —— 收缩瞬间缓存里还是展开态的大框,
   照它画会把小圆铺到偏右 30pt 处(用户: "小岛专辑从其他地方显示再显示正常")。
   小岛态只接受"尺寸合理且在宿主内"的候选, 其余一律沿用这个槽位。 */
@property (nonatomic, assign) CGRect miniCoverRect;
@property (nonatomic, assign) CGRect cacheSqRect;
@property (nonatomic, assign) CGFloat cacheBW, cacheBH;
@property (nonatomic, assign) BOOL rotInstalled;    /* 旋转 CA 动画已装 */
@property (nonatomic, assign) CGFloat rotInstalledSpeed;
@property (nonatomic, assign) BOOL rotInstalledRev;
@property (nonatomic, assign) CGFloat lastGlassSide; /* 上次画玻璃的边长, 用于藏层节流 */
@property (nonatomic, assign) CGPoint lastGlassCenter;
/* 2.9.65: 过渡帧锁定的玻璃边长(0=不锁) —— 见 diPaintGlassAt 里的说明 */
@property (nonatomic, assign) CGFloat freezeSide;
/* 2.9.67: 连续"在变大"的帧数 —— 长按展开起手用, 见 isMini/挂载守卫 */
@property (nonatomic, assign) NSInteger growStreak;
@property (nonatomic, assign) CFAbsoluteTime paintT;     /* 上次真正画玻璃的时间, 稳定态短路用 */
/* 2.8.39: 上次确认"正在播放"的时间 —— 遮罩锁死用(308 反馈: 切歌/门户重建时
   判定瞬断就拆玻璃, 用户看到"先方形后遮罩"; 播放中或 30s 内播放过就永不拆)。 */
@property (nonatomic, assign) CFAbsoluteTime lastPlayT;
/* ===== 2.9.74: 交接给 MRU 之后的"闭嘴期" =====
   404 日志+视频实锤: 展开那一下这边确实按"MRU 已确认展开"让位了, 但**下一个
   layout 又把玻璃挂回来**了 —— 日志里"立即让位"之后还跟着四十多条
   "遮罩挂上(玻璃) … 旋转=开 角度-336°→-59°"。这颗 25pt 的圆还带着旋转动画,
   而它所在的小岛容器在展开时被系统淡出/放大 —— 用户看到的就是
   "展开大岛里有个小专辑在环绕转圈, 过一下才正常"。
   所以让位要记时间: 交接窗口内(mruHoldT>0)一律不再新挂, 直到 MRU 那边
   连续 0.3 秒都说"不是展开态"才放开。 */
@property (nonatomic, assign) CFAbsoluteTime mruHoldT;
@property (nonatomic, assign) CFAbsoluteTime mruClearT;
/* 2.7.45: 素材指纹状态改成实例属性 ——
   2.7.42~2.7.44 用函数内 static, 而小岛/展开岛各有一个 DIMaskView 实例,
   两个实例抢同一组 static: A 刚记录完指纹, B 立刻判"变了"→ 又重建,
   日志里"遮罩素材换图"每秒刷好几次就是这么来的, 遮罩自然挂不稳。
   状态归属到实例后, 每个探针各自记自己的, 只有真换了素材才会重建。 */
@property (nonatomic, copy) NSString *fpSel;
@property (nonatomic, assign) double fpMtime;
@property (nonatomic, assign) NSInteger fpGen;
@property (nonatomic, assign) NSInteger fpMiss;   /* 连续命中次数, 首次立即生效 */
- (NSInteger)diLiveTargetCount;
@end

/* 异步拿专辑封面 —— 2.8.13 起供自绘玻璃(旋转/展开态)使用 */
static void diNowPlayingArtworkAsync(void (^cb)(UIImage *, NSString *)) {
    static void (*mrGetInfo)(dispatch_queue_t, void (^)(NSDictionary *)) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (h) mrGetInfo = (void (*)(dispatch_queue_t, void (^)(NSDictionary *)))dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        if (!mrGetInfo) DLog(@"遮罩专辑图: MediaRemote.framework %@ / MRMediaRemoteGetNowPlayingInfo %@",
                            h ? @"已加载" : @"打不开", @"取不到");
    });
    if (!mrGetInfo) { if (cb) cb(nil, nil); return; }
    mrGetInfo(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(NSDictionary *d) {
        UIImage *img = nil;
        NSString *key = nil;
        if ([d isKindOfClass:NSDictionary.class]) {
            NSData *art = d[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if (art.length) img = [UIImage imageWithData:art];
            /* 2.8.13: 换歌识别键(标题+图长度) —— 只用长度太糙, 同名不同图会漏换 */
            key = [NSString stringWithFormat:@"%@|%@|%lu",
                   d[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"-",
                   d[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"-",
                   (unsigned long)art.length];
            static BOOL sTold;   /* 2.7.38: 专辑图为什么拿不到, 打一次就够 */
            if (!sTold) { sTold = YES; DLog(@"遮罩专辑图: NowPlayingInfo 键数=%lu artworkData=%@",
                                             (unsigned long)d.count, art.length ? @"有" : @"无"); }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (cb) cb(img, key); });
    });
}

/* 2.8.13: 进程级共享的"正在播放"专辑图。
   旋转开启时遮罩改走自绘玻璃(系统那张专辑是跨进程门户, 转不动),
   小岛/展开两个探针共用同一份图, 3 秒节流 + 换歌立即换。 */
static UIImage *gSharedArt = nil;
static NSString *gSharedArtKey = nil;
static CFAbsoluteTime gSharedArtT = 0;
static BOOL gSharedArtBusy = NO;

static UIImage *diDownscaleArt(UIImage *img, CGFloat maxSide) {
    if (!img) return nil;
    CGFloat w = img.size.width, h = img.size.height;
    if (w <= 0 || h <= 0) return nil;
    CGFloat s = MIN(maxSide / w, maxSide / h);
    if (s >= 1.0) return img;
    CGSize sz = CGSizeMake(MAX(1.0, floor(w * s)), MAX(1.0, floor(h * s)));
    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc] initWithSize:sz];
    return [rd imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull c) {
        [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
    }];
}

static void diFetchSharedArt(BOOL force) {
    if (gSharedArtBusy) return;
    if (!force && CFAbsoluteTimeGetCurrent() - gSharedArtT < 3.0) return;
    gSharedArtBusy = YES;
    diNowPlayingArtworkAsync(^(UIImage *img, NSString *key) {
        gSharedArtBusy = NO;
        gSharedArtT = CFAbsoluteTimeGetCurrent();
        if (!img || !key) return;
        if ([key isEqualToString:gSharedArtKey]) return;      /* 没换歌 */
        gSharedArt = diDownscaleArt(img, 192.0);
        gSharedArtKey = [key copy];
        DLog(@"遮罩专辑图: 已更新(%@)", key);
    });
}

/* 2.7.45: 素材文件的 mtime+大小, 0.5 秒节流(两个探针实例共用同一份, 内容完全一样, 不需要分开)。
   返回 NO 表示读不到 —— 此时调用方**不要**判定"文件变了", 否则一次读失败会让蒙版重建,
   日志里就是"遮罩素材换图"每秒刷十几条, 蒙版每帧重挂, 画面自然挂不稳。 */
static BOOL diMaskStatOf(NSString *path, double *outMtime, unsigned long long *outSize) {
    static NSString *sPath = nil;
    static double sMtime = 0;
    static unsigned long long sSize = 0;
    static CFAbsoluteTime sT = 0;
    static BOOL sOK = NO;
    if (sPath && [sPath isEqualToString:path] && CFAbsoluteTimeGetCurrent() - sT < 0.5) {
        if (outMtime) *outMtime = sMtime;
        if (outSize) *outSize = sSize;
        return sOK;
    }
    sPath = [path copy];
    sT = CFAbsoluteTimeGetCurrent();
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (at) {
        sOK = YES;
        NSDate *md = at[NSFileModificationDate];
        sMtime = md ? md.timeIntervalSince1970 : 0;
        sSize = [at[NSFileSize] unsignedLongLongValue];
    } else {
        sOK = NO;
    }
    if (outMtime) *outMtime = sMtime;
    if (outSize) *outSize = sSize;
    return sOK;
}


@implementation DIMaskView

static NSString *const kDIMaskLayerName = @"DriftIslandAlbumMask";
static char kCoverOrigMaskKey;
/* 2.7.45: 目标层归属谁的探针 —— 防止小岛/展开两个 DIMaskView 互相摘对方的蒙版 */
static char kMaskOwnerKey;
/* 2.8.15: 被藏专辑层的原始 alpha(关联对象 key, 见 diHideViewsNear)
   2.8.17: 定义已前移到 diViewHasVisiblePortal 之前(那里要读它判断"是不是我们自己藏的") */

/* 把 mask 从专辑层上摘掉并还原原值(通常原值就是 nil = 原生无蒙版)。
   必须在开关关闭 / 退出音乐 / 专辑换了 这三种情况下都调,
   否则会留一块永久的形状在系统封面上。 */
/* 2.7.45: 摘蒙版必须在关闭隐式动画的前提下做。
   否则系统那条 0.25s 的 mask 过渡会在我们刚摘掉后把旧 overlay 补回去,
   表现就是"关了开关还挂着, 再开一次就叠了两层" —— 这也是之前换素材看不出变化的原因之一。 */
static void diStripMaskFromCover(UIView *cover) {
    if (!cover) return;
    CALayer *target = cover.layer;
    if (!target || !target.mask) return;
    if ([target.mask.name isEqualToString:kDIMaskLayerName]) {
        CALayer *orig = objc_getAssociatedObject(cover, &kCoverOrigMaskKey);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        target.mask = orig;                 /* 没记录过就是 nil → 恢复原生 */
        [CATransaction commit];
        objc_setAssociatedObject(cover, &kCoverOrigMaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    /* 顺带清掉可能残留的"隐式动画补间"对象, 免得它把旧 mask 又推回来 */
    [target removeAnimationForKey:@"mask"];
}

/* ===== 2.8.85: 残留遮罩兜底清扫 =====
   遮罩是"挂上去就一直留在层上"的, 只要有一次挂到了错误的层(展开/收起动画的中间帧,
   或者用户从 2.8.84 及更早版本升上来时留下的旧层), 它就会一直显示 —— 这正是
   332 反馈"偶尔还是会显示"的来源。这里每 2~5 秒扫一遍窗口树, 把所有
   DriftIslandAlbumMask 的层收掉:
     · 遮罩关闭时 → 全摘;
     · 遮罩开启时 → 只摘 >80pt 的大层(小岛头像那 22~26pt 的保留)。 */
static NSString *diMruSharedDir(void);   /* 实现在下方导出段 */

static BOOL diIsIOS17Up(void);   /* 定义在 2.9.37 段(下方), 这里先用 */

/* ===== 2.9.38: 把小岛真实形态写给 MediaRemoteUI =====
   369~379 的死结: iOS17 上 MRU 里那个头像视图恒 66x66, 它按 bounds 判形态永远得到
   "展开" → ① 它自己在收缩态也铺 66pt 玻璃(被外层裁成一牙 = 用户说的"变形");
   ② 它把 expanded=YES 写进 state.plist, SpringBoard 这边的小岛玻璃(2.8.75 那套)
   看到"展开"就整棵退场 → 小岛专辑只剩 MRU 那块错的。
   宿主真实尺寸只有 SpringBoard 知道(小岛 ~189x37 / 展开 407x202), 这里写给它。 */
/* ===== 2.9.61: 容器可见性 —— 形态播报的准入门槛 =====
   392 日志实锤: MRU 读到的 island.plist 在"小岛 189x37"与"展开 407x197"之间
   每隔 10~20 秒被翻一次面 —— 写"展开"的是那块**离屏残留**的 407x198 NowPlaying
   容器(躺在 alpha=0 的 portal 里), 它也会 layout、也会被 diIsNowPlayingHostCached
   命中。后果: MRU 的展开确认期(连续 1.2 秒说展开)被打断 → 展开遮罩有时生效
   有时不生效; 小岛态被写成"展开" → 大玻璃迟迟不拆。 */
static BOOL diContainerVisiblyShown(UIView *v) {
    if (!v || !v.window || v.isHidden) return NO;
    for (UIView *a = v; a && a != v.window; a = a.superview)
        if (a.isHidden || a.alpha < 0.01) return NO;
    return YES;
}

/* ===== 2.9.68: SpringBoard 玻璃交接标志 =====
   399 日志 + 视频实锤: 展开起手(宿主 209x40 → 240x70 之间)SpringBoard 已经让位
   (它按小岛尺寸判的), 而 MRU 也读到"小岛/过渡"把 66 的大玻璃拆了 —— 两边同时
   放手 → 中间 0.1~0.3 秒岛上没有遮罩, 露出来的就是系统那颗很小的原生专辑;
   长到 240x70 后 MRU 重新铺 66 → 用户看到"小专辑然后变大 / 底闪一下"。
   谁在画谁负责: SpringBoard 正画着小岛玻璃时, MRU 的大玻璃就该让; SpringBoard
   不画了(让位/拆掉), MRU 必须立刻接手, 不能等播报变成"展开"。
   这个标志每帧随岛容器布局一起写, 变化时绕过节流立即落盘。 */
static volatile int gDISBGlassOn = 0;

/* 2.9.69: 交接信号必须零延迟送达 —— 展开起手时宿主 bounds 可能只跳一两帧,
   之后就不再 layout, 单靠 layout hook 写盘的话 MRU 会读到"上一帧的 sb=1",
   于是它一直让位(空窗)。这里把最近一次播报的宿主尺寸记下来, sb 一变就用它
   立刻重写一份, 不依赖宿主是否还在 layout。 */
static CGFloat gDISBPubW = 0, gDISBPubH = 0;
static int gDISBPubM = -1;      /* 1=小岛 2=展开 0=过渡 */

static void diWriteIslandPlist(void) {
    if (gDISBPubW < 1.0 || gDISBPubH < 1.0) return;
    NSString *dir = diMruSharedDir();
    if (!dir.length) return;
    NSDictionary *d = @{@"w": @(gDISBPubW), @"h": @(gDISBPubH),
                        @"mini": @(gDISBPubM == 1 ? 1 : 0),
                        @"expand": @(gDISBPubM == 2 ? 1 : 0),
                        @"sb": @(gDISBGlassOn ? 1 : 0),
                        @"t": @(CFAbsoluteTimeGetCurrent()), @"v": DI_BUILD_VER};
    @try { [d writeToFile:[dir stringByAppendingPathComponent:@"island.plist"] atomically:YES]; }
    @catch (__unused NSException *e) {}
}

static void diPublishIslandState(CGSize hostSize, BOOL mini, BOOL expand) {
    if (hostSize.width < 1.0 || hostSize.height < 1.0) return;
    static CGFloat lw, lh; static CFAbsoluteTime lt; static int lm = -1; static int lsb = -1;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    int m = mini ? 1 : (expand ? 2 : 0);
    int sbNow = gDISBGlassOn ? 1 : 0;
    /* 2.9.68: 交接标志一变就必须立刻落盘 —— 展开起手只有这一瞬间能救 */
    if (lsb != sbNow) { lt = 0; lm = -9; }
    /* 2.9.55: 岛容器布局 hook 每帧都会调进来, 写盘压到 5Hz, 免得展开动画期间狂写
       2.9.65: 形态"卡在中间"(m=0, 展开/收起动画途中)时放宽到 16Hz ——
       MRU 靠这份文件判形态, 过渡帧写慢了它就会读到"上一帧的小岛",
       表现为"展开后专辑先很小再变大"。0.4 秒的动画最多多写 5~6 次, 可忽略。 */
    if (lt > 0 && now - lt < (m == 0 ? 0.06 : 0.2)) return;
    if (fabs(hostSize.width - lw) < 0.5 && fabs(hostSize.height - lh) < 0.5
        && m == lm && now - lt < 2.0) return;
    lw = hostSize.width; lh = hostSize.height; lm = m; lt = now; lsb = sbNow;
    gDISBPubW = hostSize.width; gDISBPubH = hostSize.height; gDISBPubM = m;
    diWriteIslandPlist();
}

/* ===== 2.9.55: 17 专用 —— 岛容器布局即播报真实尺寸 =====
   17 上 SpringBoard 侧遮罩整体让位(2.9.47), 小岛专辑改由 MediaRemoteUI 自绘。
   但 MRU 只看得到头像自己的 bounds: 展开态那颗 66x66 在岛收回后还会被 layout 到,
   它就会以为"还在展开" → 玻璃一直按 66pt 铺 → 用户说的"切换下一首放大就回不去"。
   这里直接在岛容器布局时把真实尺寸写过去, 不依赖小岛视频/遮罩探针是否在跑。
   16 完全不装这个 hook(一个字节都不影响 16)。 */
static void (*gDIHostPubOrig)(id, SEL);
static void diHostPubLayout(id self, SEL _cmd) {
    if (gDIHostPubOrig) gDIHostPubOrig(self, _cmd);
    @try {
        UIView *v = (UIView *)self;
        /* 2.9.61: 离屏残留容器(alpha=0 的 portal 里那块 407x198)不许播报 ——
           它就是 island.plist 每 10~20 秒被翻成"展开"的污染源(392 日志)。 */
        if (!diContainerVisiblyShown(v)) return;
        CGSize s = v.bounds.size;
        if (s.width < 1.0 || s.height < 1.0) return;
        BOOL mini = (s.height >= 24 && s.height <= 62
                     && s.width >= 100 && s.width <= 208
                     && s.width > s.height * 1.55);
        BOOL exp = (s.height >= 120 && s.height <= 300
                    && s.width >= 280 && s.width <= 440);
        diPublishIslandState(s, mini, exp);
    } @catch (__unused NSException *e) {}
}
static void diHostPubInstall(void) {
    if (!diIsIOS17Up()) return;
    static BOOL done;
    if (done) return;
    Class c = NSClassFromString(@"SBSystemApertureContainerView");
    if (!c) return;
    gDIHostPubOrig = NULL;
    MSHookMessageEx(c, @selector(layoutSubviews), (IMP)diHostPubLayout, (IMP *)&gDIHostPubOrig);
    done = YES;
    RLog(@"[形态播报] iOS17 岛容器 layout hook 已装(orig=%@)", gDIHostPubOrig ? @"有" : @"无");
}

/* 2.9.40: 宿主自己写的形态(3 秒内有效) —— SpringBoard 侧判断用 */
static BOOL diIslandStateMini(void) {
    static CFAbsoluteTime lastCheck; static BOOL cached;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastCheck < 0.4) return cached;
    lastCheck = now;
    NSString *dir = diMruSharedDir();
    if (!dir.length) { cached = NO; return NO; }
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                       [dir stringByAppendingPathComponent:@"island.plist"]];
    if (![d isKindOfClass:NSDictionary.class]) { cached = NO; return NO; }
    if (now - [d[@"t"] doubleValue] > 3.0) { cached = NO; return NO; }
    cached = [d[@"mini"] boolValue] && ![d[@"expand"] boolValue];
    return cached;
}

/* 2.9.64: 播报新鲜(≤1 秒)且明确说"展开"、而宿主尺寸还够着小岛窗口 = 正在展开过渡。
   注意与 diIslandStateMini 的区别: 那个 3 秒新鲜度(暂停时播报过期也返回 NO),
   这个只认 1 秒内的明确 expand —— 暂停时播报过期, 这里返回 NO, 不影响暂停遮罩。 */
static BOOL diIslandFreshExpand(void) {
    static CFAbsoluteTime lastCheck; static BOOL cached;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastCheck < 0.3) return cached;
    lastCheck = now;
    NSString *dir = diMruSharedDir();
    if (!dir.length) { cached = NO; return NO; }
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                       [dir stringByAppendingPathComponent:@"island.plist"]];
    if (![d isKindOfClass:NSDictionary.class]) { cached = NO; return NO; }
    if (now - [d[@"t"] doubleValue] > 1.0) { cached = NO; return NO; }
    cached = [d[@"expand"] boolValue] && ![d[@"mini"] boolValue];
    return cached;
}

/* ===== 2.8.86: 展开态由 MRU 亲口告诉我们 =====
   332/333 日志的死结: 展开后 SpringBoard 这边宿主的 bounds 一直停在 198x55
   (展开的内容是它内部那块 407x489 的跨进程 scene), 所以 2.8.84 的
   "高>70 或宽>240 就退出" **从来没有触发过** —— 日志里 展开=0 一直是 0,
   小岛那块 25pt 玻璃在展开时继续画, 于是头像旁边多出一个心形。
   现在换个判据: MediaRemoteUI 每帧都知道自己的头像是不是 66x66,
   它把 expanded 写进 state.plist, 这边只读结果, 不再猜尺寸。
   文件超过 4 秒没更新(MRU 没在跑/退出了)即视为非展开, 不会永久压着。 */
static BOOL diMruSaysExpanded(void) {
    static CFAbsoluteTime lastCheck; static BOOL cached;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastCheck < 0.15) return cached;   /* 2.8.87: 335 反馈"首次展开会闪", 收窄到 150ms */
    lastCheck = now;
    NSString *dir = diMruSharedDir();
    if (!dir.length) { cached = NO; return NO; }
    NSString *p = [dir stringByAppendingPathComponent:@"state.plist"];
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL];
    NSDate *md = attr[NSFileModificationDate];
    if (!md || now - md.timeIntervalSince1970 > 4.0) { cached = NO; return NO; }
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    /* 2.8.87: 迟滞 —— 展开/收起动画里 MRU 的头像会在 23↔66 之间抖,
       状态文件跟着 0/1 翻, 这边就会"刚收掉又画回去", 表现就是闪好几次。
       见过展开后 1.5 秒内一律按展开处理, 动画期间不会再冒出一块玻璃。 */
    static CFAbsoluteTime lastExpandedAt;
    BOOL raw = [d[@"expanded"] boolValue];
    if (raw) lastExpandedAt = now;
    cached = raw || (lastExpandedAt > 0 && now - lastExpandedAt < 1.5);
    return cached;
}
/* 我们自己玻璃内部的形状层也叫 kDIMaskLayerName, 清扫时必须放过它,
   否则"清残留"会把正在旋转的玻璃削成方形。 */
static BOOL diInsideOwnMaskView(UIView *v) {
    for (UIView *a = v; a; a = a.superview)
        if ([a isKindOfClass:DIMaskView.class]) return YES;
    return NO;
}
static void diSweepMasks(BOOL onlyLarge) {
    NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
    @try {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class])
                [wins addObjectsFromArray:((UIWindowScene *)s).windows];
    } @catch (__unused NSException *e) {}
    if (!wins.count) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:wins];
    NSUInteger budget = 4000;
    while (stack.count && budget--) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        CALayer *m = v.layer.mask;
        if (m && [m.name isEqualToString:kDIMaskLayerName] && !diInsideOwnMaskView(v)) {
            CGSize sz = v.bounds.size;
            if (!onlyLarge || MAX(sz.width, sz.height) > 80.0) {
                diStripMaskFromCover(v);
                RLog(@"[遮罩清扫] 摘除残留蒙版 %@ %.0fx%.0f (仅大层=%d)",
                     NSStringFromClass(v.class), sz.width, sz.height, onlyLarge);
            }
        }
        for (UIView *c in v.subviews) [stack addObject:c];
    }
}

/* 2.7.26: 挂蒙版要挂哪些层。

   254 号日志铁证 ——
      遮罩挂上: 封面=BSUICAPackageView 37x37@(123,-0) 岛=166x37 素材=Mask.png
   日志说挂上了, 但用户画面**毫无变化**。原因: BSUICAPackageView 是 CA 动画包,
   它的画面由跨进程远程层渲染, 给它自己的 layer 设 mask 会被那层渲染绕过 ——
   mask 在不在树里都能读到, 但就是不参与裁剪。

   所以这里把**父容器**也列为目标: 父容器是普通 UIView, 它的 mask 会连同
   所有子层(含那个 CA 包)一起裁 —— 这条路必然生效。两者都挂, 谁生效都行。
   父容器尺寸不能比封面大太多(大太多说明抓到的是整岛容器, 裁的范围就错了)。 */
static NSArray<UIView *> *diMaskTargetsFor(UIView *cover) {
    if (!cover) return @[];
    /* ===== 2.8.85: 绝对尺寸硬闸门 =====
       332 反馈: 展开岛下方"偶尔还会显示"那块心形模糊底。根因与宿主形态判定无关 ——
       只要某一帧 cover/parent 抓到了展开态的大背景(几百 pt), 它就会被裁成心形。
       这里加一条和形态判定无关的死规则: 遮罩只挂在 ≤80pt 的小方块上,
       超过 80pt 的视图(岛背景/模糊底/整块内容视图)一律不碰。
       小岛专辑位 22~26pt、展开位 36~66pt 都在门内, 背景层全部在门外。 */
    CGSize csz0 = cover.bounds.size;
    if (MAX(csz0.width, csz0.height) > 80.0) return @[];
    NSMutableArray *out = [NSMutableArray array];
    UIView *pv = cover.superview;
    if (pv && pv.bounds.size.width > 6 && pv.bounds.size.height > 6) {
        CGFloat cw = MAX(8, cover.bounds.size.width), ch = MAX(8, cover.bounds.size.height);
        /* 2.7.42: 2.5 倍门槛对小岛够用, 但展开态专辑门户的父层可能是整块内容视图
           (407x202), 一刀切会丢掉父层 —— 而 CA 包恰恰只有挂父层才裁得动。
           所以再放一条: 父层是 *ProvidedViewContainer/Accessory* 这类"专属容器"时,
           即便大一些也收(它们是专辑自己的容器, 不会误伤岛的其他部分)。 */
        NSString *pcn = NSStringFromClass(pv.class);
        BOOL ownContainer = [pcn containsString:@"ProvidedViewContainer"]
                         || [pcn containsString:@"AccessoryView"]
                         || [pcn containsString:@"AccessoryPortalView"];
        /* 2.7.45: 专属容器也不能无限大 —— 展开态 407x202 的 contentView 也叫 *View,
           给它挂 mask 会把歌词/按钮一起裁掉, 用户看到的是"整个岛被挖空"。
           所以再加一条绝对上限: 父层面积不超过封面的 4 倍。 */
        CGFloat pw2 = pv.bounds.size.width, ph2 = pv.bounds.size.height;
        BOOL sizeOK = (pw2 <= cw * 2.5 && ph2 <= ch * 2.5);
        BOOL absOK  = (pw2 <= cw * 3.2 && ph2 <= ch * 3.2);
        /* 2.8.85: 父层同样受 80pt 绝对上限约束 —— 心形底就是从这里漏出去的 */
        BOOL smallOK = (MAX(pw2, ph2) <= 80.0);
        if ((sizeOK || (ownContainer && absOK)) && smallOK) [out addObject:pv];
    }
    [out addObject:cover];
    return out;
}

/* 给专辑层挂上形状蒙版。mask 用 **mask layer 的 alpha 通道**做裁剪,
   所以形状图必须是"实心=不透明 / 其余=透明", diMaskAlphaCached 产出的正是这种图。 */
/* 2.7.42: 蒙版旋转角(°), 由 step 每帧推进, 自绘玻璃的 transform 用它。
   2.8.13: 旋转只由玻璃(专辑图+遮罩同一视图)的 transform 实现 ——
   旧版"给 mask.contents 换旋转位图"的路子已删(真机上会把遮罩整个转没)。 */
static CGFloat gMaskRotDeg = 0;


/* 2.7.45: 旋转角推进(进程级, 两个探针实例共享一个时间基准) */
static CFTimeInterval gRotTS = 0;
static void diAdvanceMaskRotation(CFTimeInterval t) {
    if (t <= 0) return;
    if (gRotTS <= 0 || t < gRotTS) { gRotTS = t; return; }
    double dt = t - gRotTS;
    if (dt < 1.0 / 240.0) return;                 /* 同一帧被两个实例先后调用: 只推一次 */
    if (dt > 0.5) dt = 1.0 / 60.0;                /* 掉帧/后台回来: 不要一口气跳一大截 */
    gRotTS = t;
    gMaskRotDeg += (maskRotateReverse ? -1.0 : 1.0) * maskRotateSpeed * dt;
    if (gMaskRotDeg >= 360.0) gMaskRotDeg -= 360.0;
    if (gMaskRotDeg <= -360.0) gMaskRotDeg += 360.0;
}

static BOOL diApplyMaskToCover(UIView *cover, UIImage *shape) {
    if (!cover || !shape || !shape.CGImage) return NO;
    CALayer *target = cover.layer;
    if (!target) return NO;
    /* 2.8.85: 最后一道闸 —— 超过 80pt 的层绝不挂遮罩; 已挂的立刻摘掉还原。
       防止任何调用路径(旧缓存目标 / 展开动画中间帧)把背景裁成心形。 */
    CGSize tsz = cover.bounds.size;
    if (MAX(tsz.width, tsz.height) > 80.0) {
        diStripMaskFromCover(cover);
        return NO;
    }

    /* 第一次挂之前把系统原来的 mask 存起来, 摘的时候原样还回去 */
    if (!objc_getAssociatedObject(cover, &kCoverOrigMaskKey) && target.mask &&
        ![target.mask.name isEqualToString:kDIMaskLayerName]) {
        objc_setAssociatedObject(cover, &kCoverOrigMaskKey, target.mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CALayer *ml = target.mask;
    BOOL owned = [ml.name isEqualToString:kDIMaskLayerName];
    if (!owned) {
        ml = [CALayer layer];
        ml.name = kDIMaskLayerName;
    }
    /* 2.7.43: 用**呈现层**尺寸, 且 setFrame 与 transform 分开设置 ——
       CALayer 里设置 frame 会同时改写 position/bounds/transform, 顺序错了
       旋转会被下一次 frame 赋值抹掉(这就是"打开旋转完全没效果"的直接原因)。
       所以: 先定 position/bounds(不碰 frame), 最后再设 transform。
       2.8.13: 修"遮罩不圆" —— 283 日志铁证: 专辑门户是 26x22 的**非方形**容器
       (_SAUIProvidedViewContainerView 26x22@8,15), 而素材是 1100x1100 的方形图,
       kCAGravityResize 把方形直接拉进 26x22 → 圆被压成椭圆(宽高比 1.18)。
       修法: mask 层取被裁层的**中心正方形**(边长=短边), 素材只铺满这个方块 ——
       圆永远是圆的。正方形之外的部分被裁层照常隐藏, 不影响布局。 */
    CALayer *pl2 = target.presentationLayer ?: target;
    CGRect mb = pl2.bounds;
    if (mb.size.width < 4 || mb.size.height < 4) mb = target.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    ml.contentsScale = UIScreen.mainScreen.scale;
    ml.opaque = NO;
    ml.anchorPoint = CGPointMake(0.5, 0.5);

    /* mask 层的铁律(2.6.x~2.8.12 四版旋转 bug 换来的):
       ① 永远只是一张**平面** contents, 不加子层、不加 transform ——
          iOS 对 CALayer.mask 的处理是"整体 rasterize 到被裁层 bounds 里",
          带子层/transform 的 mask 在真机上会被退化成"整块实心"或"整块消失";
       ② 永远保持挂载状态, 任何分支都不能把它换成空层/空 contents;
       ③ 2.8.13 起旋转整体移出本函数 —— 改由自绘玻璃的 transform 实现,
         这条路只贴静态形状图。 */
    CGSize ms = mb.size;
    CGFloat sq2 = MIN(ms.width, ms.height);          /* 2.8.13: 中心正方形, 保圆 */
    ml.position = CGPointMake(ms.width * 0.5, ms.height * 0.5);
    ml.bounds = CGRectMake(0, 0, sq2, sq2);
    ml.transform = CATransform3DIdentity;
    ml.contentsGravity = kCAGravityResize;
    ml.contentsRect = CGRectMake(0, 0, 1, 1);
    ml.masksToBounds = NO;
    for (CALayer *s in [ml.sublayers copy]) [s removeFromSuperlayer];   /* 清掉旧版残留的子层 */

    /* 2.8.13: 旋转不再走这里 —— 位图旋转(旧方案)在真机上会把遮罩整个转没,
       用户原话"打开素材旋转直接隐藏了"。旋转现在只由自绘玻璃的 transform 实现
       (见 diPaintGlassAt), 系统 mask 这条路永远只贴静态形状图。 */
    CGImageRef use = shape.CGImage;
    /* 2.7.45: 只有 contents 真的换了才赋值 —— CALayer 只要被赋 contents 就会重新生成
       一张纹理, 60fps 无脑赋值会让专辑画面每帧重建, 掉帧/闪烁都由此而来。 */
    if (ml.contents != (__bridge id)use) ml.contents = (__bridge id)use;
    /* 关键: mask 必须**在挂载状态**。历史上"打开旋转 = 取消遮罩"
       是因为旧版在旋转分支里把 mask 换成了空层/空 contents, 系统就当成无蒙版。 */
    if (!owned || target.mask != ml) target.mask = ml;
    [CATransaction commit];
    return YES;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = YES;
        self.layer.anchorPoint = CGPointMake(0.5, 0.5);
        self.hidden = YES;                  /* 探针不画东西 */
        _targets = [NSHashTable weakObjectsHashTable];

        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step)];
        /* 2.8.16: 探针 60 → 30fps。旋转已经交给 CABasicAnimation 在渲染服务器上插值,
           探针这边只剩"看宿主尺寸变没变"这一件事, 30fps 完全够用(响应 33ms),
           CPU 占用直接减半。原先 60fps × 两个实例(岛 + 镜像)是掉帧主因之一。 */
        _link.preferredFramesPerSecond = 30;
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (NSInteger)diLiveTargetCount { return (NSInteger)_targets.count; }

- (void)dealloc {
    for (UIView *t in _targets.allObjects) diStripMaskFromCover(t);
    [_link invalidate];
}

/* 关开关 / 不是小岛 / 素材没了 —— 统一从这里撤, 保证一定把系统封面还原 */
- (void)diTeardown {
    for (UIView *t in _targets.allObjects) {
        diStripMaskFromCover(t);
        /* 2.7.45: 一并释放归属, 否则这块专辑会被"已销毁的探针"永久占着,
           另一个探针再也挂不上 (展开岛遮罩不生效的另一半原因)。 */
        DIMaskView *owner = objc_getAssociatedObject(t.layer, &kMaskOwnerKey);
        if (owner == self) objc_setAssociatedObject(t.layer, &kMaskOwnerKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    [_targets removeAllObjects];
    _coverV = nil;
    [self diRestorePainted];
    if (!self.hidden) { self.hidden = YES; self.loggedShow = NO; }
    _loggedPaint = NO;
    _lastSide = 0;
    _lastTS = 0;
    _rotDeg = 0;
    /* 2.7.45: 不再把 gMaskRotDeg 归零 —— 这个角度是全局共享的, 小岛实例 teardown
       (比如岛刚收回) 会把展开实例正在用的角度清零, 表现就是"旋转一卡一卡 / 突然不转"。
       角度只在"旋转开关关掉"时由 step 统一归零。 */
    /* 2.8.13: 玻璃模式标志一并清掉, 下次进来重新判定 */
    if (self.glassOn) { gDISBGlassOn = 0; diWriteIslandPlist(); }   /* 2.9.68: 我这边放手了, MRU 该接手 */
    _glassOn = NO;
    _glassMiss = 0;
    _freezeSide = 0;   /* 2.9.65: 边长锁一起清, 下次重新锁 */
    /* 2.8.16: 玻璃拆了就把旋转 CA 动画一起摘掉, 否则视图藏起来动画还在跑(白耗电) */
    if (self.rotInstalled) {
        [_artView.layer removeAnimationForKey:@"diSpin"];
        self.rotInstalled = NO;
    }
    self.cacheCoverV = nil;
    self.cacheSqView = nil;
    self.cacheSqRect = CGRectZero;
}

/* 2.8.15: 把被我们藏起来的系统封面层还原(统一走 hiddenViews 弱表) */
- (void)diRestorePainted {
    [self diRestoreHiddenViews];
}

/* 2.8.15: 藏掉专辑中心附近所有本地方层 —— 小岛态门户底座(26x22)、
   展开态方形专辑层(36x36)、以及任何重复画专辑的本地视图(用户报的"多了一个显示")。
   原始 alpha 用关联对象挂在层上, 弱表记录都藏了谁, teardown 统一还原。
   半径由调用方按玻璃边长给(side/2+6), 尺寸闸门 12~64pt 天然排除了:
     · 展开态的大门户容器(几百 pt, 藏了会连歌词一起没了);
     · 右侧音频门户(22x22, 圆心在岛另一侧, 距专辑中心远大于半径);
     · 歌词/按钮( bounds 超 64pt, 且不在 album 半径内)。
   注意门户视图(26x22)本身要藏 —— 小岛态专辑就画在它里面, 藏它的 alpha
   就是藏远程专辑画面(2.8.13/2.8.14 验证过 safe)。 */
- (void)diHideViewsNear:(CGPoint)center radius:(CGFloat)radius inHost:(UIView *)host glass:(CGRect)glass {
    if (!host) return;
    if (!self.hiddenViews) self.hiddenViews = [NSHashTable weakObjectsHashTable];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:host];
    int g = 0;
    while (stack.count && g++ < 300) {
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0];
        NSString *cn = NSStringFromClass(v.class);
        BOOL ourView = [cn isEqualToString:@"DIMaskView"] || [cn isEqualToString:@"DIAnimView"]
                    || [cn isEqualToString:@"DIVideoView"];
        if (!ourView) { for (UIView *c in v.subviews) [stack addObject:c]; }
        if (v == host || ourView) continue;
        CGSize s = v.bounds.size;
        if (s.width < 12 || s.height < 12 || s.width > 64 || s.height > 64) continue;
        /* 半径闸门: 中心距(换算到宿主坐标) */
        CGPoint vc = [v convertPoint:CGPointMake(s.width * 0.5, s.height * 0.5) toView:host];
        CGFloat dx = fabs(vc.x - center.x), dy = fabs(vc.y - center.y);
        if (dx > radius || dy > radius) continue;
        /* 2.8.21: 只藏"像专辑"的层 —— 291 日志实锤: 220x38 形态下专辑旁边那个
           58x17 的标题容器(中心只差 6pt)也被藏了, 用户看到标题没了。
           两条一起判: ① 接近正方形(专辑门户 26x22 / 方块 36x36 都是;
           标题条 58x17 宽高比 3.4, 不是); ② 与玻璃正方形的交叠 ≥ 自身面积 50%
           (玻璃都盖不住大多的, 本来就不是专辑)。 */
        CGRect r = [v convertRect:v.bounds toView:host];
        CGFloat sqv = 1.0 - MIN(1.0, fabs(s.width - s.height) / MAX(s.width, s.height));
        if (sqv < 0.6) continue;
        CGRect inter = CGRectIntersection(r, glass);
        if ((inter.size.width * inter.size.height) < (s.width * s.height) * 0.5) continue;
        /* 已经藏过就跳过(幂等, 别把已藏的 0 再当原始值存一遍) */
        if (objc_getAssociatedObject(v, &kDIMaskOrigAlphaKey)) continue;
        objc_setAssociatedObject(v, &kDIMaskOrigAlphaKey,
                                 @(v.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.hiddenViews addObject:v];
        v.alpha = 0.0;
        static CFAbsoluteTime sHideT;
        if (CFAbsoluteTimeGetCurrent() - sHideT > 2.0) {
            sHideT = CFAbsoluteTimeGetCurrent();
            DLog(@"遮罩藏专辑层: %@ %.0fx%.0f 中心距(%.0f,%.0f) (半径%.0f)",
                 cn, s.width, s.height, dx, dy, radius);
        }
    }
}

/* 2.8.15: 还原所有被藏起来的层(alpha 从关联对象读回来) */
- (void)diRestoreHiddenViews {
    for (UIView *v in self.hiddenViews) {
        NSNumber *orig = objc_getAssociatedObject(v, &kDIMaskOrigAlphaKey);
        if (orig) { v.alpha = orig.doubleValue; objc_setAssociatedObject(v, &kDIMaskOrigAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN); }
    }
    [self.hiddenViews removeAllObjects];
}

/* 2.7.29 自绘玻璃(2.8.13 重写为旋转主路径)。

   为什么旋转必须走自绘:
     系统那张专辑是跨进程门户(CAPortalLayer), 我们碰不到它的像素,
     给它挂 mask 已经要绕一大圈, 想让"专辑本身转起来"根本无解。
     所以旋转开启时改成自己画: MediaRemote 拿专辑图 → 放进我们自己的视图 →
     套遮罩形状蒙版 → 整个视图加旋转 transform。内容和蒙版都在同一棵
     我们自己的 layer 树上, 一起转, 圆也由我们自己保证(视图强制正方形)。

   2.8.13 修正 2.7.29 的两个老问题:
     ① 玻璃每帧用 center/bounds 定位(不再直接赋 frame) —— 带 transform 时
        赋 frame 是 undefined, 旋转会被抹掉;
     ② 遮罩层铺满正方形(视图本身就是方的), 素材不再被拉扁。 */
- (void)diPaintGlassAt:(CGRect)rect over:(UIView *)cover art:(UIImage *)art {
    /* 2.8.13: 玻璃强制成正方形并居中在原 rect —— 专辑封面是圆的,
       绝不能被一个 26x22 之类的细长候选压扁(283 日志里就是这么椭的)。
       2.8.16: 边长改成"岛里放得下"的算法 + 用户可调比例。
       286 反馈: "加上遮罩后专辑大了一点点, 边上会被裁剪, 岛显示不了那么大"。
       实测小岛 185x52、系统专辑 36x36 在 y=8..44 刚好; 而按并集算出来的
       44x44 @y=9.4 会顶到岛底(53.4 > 52), 被岛本身裁掉一圈。
       所以: 边长 = min(候选短边, 岛高-10, 46) × 遮罩大小%; 上下各留 5pt 呼吸位。
       比例在设置页「遮罩大小(%)」里 50~115 自己调, 不用等改代码。 */
    CALayer *hpl = self.superview.layer.presentationLayer;
    CGSize hs = hpl ? hpl.bounds.size : self.superview.bounds.size;
    CGFloat side = MIN(rect.size.width, rect.size.height);
    CGFloat hLimit = hs.height - 10.0;
    if (hLimit < 14.0) hLimit = 14.0;
    if (side > hLimit) side = hLimit;
    /* 2.8.17: 上限按形态分 —— 小岛(高≤84)最多 46, 展开岛最多 72
       (富展开 407x201 的专辑方块比小岛大, 卡 46 会明显偏小)。 */
    CGFloat cap = (hs.height > 90.0) ? 72.0 : 46.0;
    if (side > cap) side = cap;
    if (side < 14.0) side = 14.0;
    side = side * (maskScale / 100.0);
    if (side > 60.0) side = 60.0;
    if (side < 10.0) side = 10.0;
    /* ===== 2.9.65: 过渡帧锁定边长(修"从小岛展开时专辑抖一下") =====
       396 日志实锤: 小岛稳定态下宿主在 127x37 / 137x42 / 191x41 / 193x37 之间
       来回变(展开起手/波形进出), 封面候选跟着从 26x22@(8,7.3) 跳到
       31.2x26.4@(9.6,8.8) → 玻璃边长 25.3 ↔ 30.4 来回跳, 肉眼就是"抖一下"。
       尺寸还在变的那几帧沿用上一次稳定时的边长, 圆心照旧跟随(位置是平滑的,
       不会露出系统方角); 稳定 2 帧后自动解锁校准。
       差 >12pt 说明真的是换了形态(不是过渡抖动), 照常放行。 */
    if (self.freezeSide > 0 && fabs(side - self.freezeSide) < 12.0) side = self.freezeSide;
    CGFloat cx = rect.origin.x + rect.size.width * 0.5;
    CGFloat cy = rect.origin.y + rect.size.height * 0.5;
    CGRect square = CGRectMake(cx - side * 0.5, cy - side * 0.5, side, side);
    static CGRect sLastGlass;
    if (!CGRectEqualToRect(sLastGlass, square)) {
        sLastGlass = square;
        DLog(@"遮罩玻璃: 候选=%@ 岛=%.0fx%.0f 比例=%.0f%% → 正方形=%.1fx%.1f (专辑图%@ 旋转=%@)",
             NSStringFromCGRect(rect), hs.width, hs.height, maskScale, side, side,
             art ? @"有" : @"无", maskRotateOn ? @"开" : @"关");
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    /* 2.8.13: 外层玻璃永远不转, 用 bounds+center 定位。
       2.8.16: 只在真的变了才写 —— 每帧无脑赋值会触发 UIView 布局回调链。 */
    CGRect wantB = CGRectMake(0, 0, side, side);
    CGPoint wantC = CGPointMake(cx, cy);
    if (!CGRectEqualToRect(self.bounds, wantB)) self.bounds = wantB;
    if (!CGPointEqualToPoint(self.center, wantC)) self.center = wantC;
    if (self.hidden) self.hidden = NO;
    if (self.alpha != 1.0) self.alpha = 1.0;
    if (!CGAffineTransformIsIdentity(self.transform)) self.transform = CGAffineTransformIdentity;
    if (self.backgroundColor != [UIColor clearColor]) self.backgroundColor = [UIColor clearColor];

    /* 2.8.15: 2.8.14 的黑色盖布整条删除 —— 它本身就是用户看到的"多了一个显示"
       (黑色圆角块贴在专辑旁边), 而且盖布永远比系统专辑小, 该露的方角照样露。
       现在改成"把系统专辑那层直接藏掉": 专辑中心附近、12~64pt 的本地视图
       全部 alpha=0 —— 小岛态门户(26x22, 专辑就画在它里面)、方形专辑层(36x36)、
       以及任何重复画专辑的本地视图("多了一个显示")一并藏掉。
       2.8.16: 藏层是"遍历整棵树 + 改 alpha", 不能每帧做。改成
       边长/中心变化超过 1pt 才重算, 另外每 0.8s 兜底同步一次
       (系统重建专辑层时才会漏, 0.8s 内补上, 肉眼看不到)。 */
    if (!self.hiddenViews) self.hiddenViews = [NSHashTable weakObjectsHashTable];
    {
        static CFAbsoluteTime sHideSync;
        BOOL moved = (fabs(side - self.lastGlassSide) > 1.0
                      || fabs(cx - self.lastGlassCenter.x) > 1.0
                      || fabs(cy - self.lastGlassCenter.y) > 1.0);
        BOOL force = (CFAbsoluteTimeGetCurrent() - sHideSync > 0.8);
        if (moved || force) {
            self.lastGlassSide = side;
            self.lastGlassCenter = CGPointMake(cx, cy);
            if (force) sHideSync = CFAbsoluteTimeGetCurrent();
            [self diHideViewsNear:CGPointMake(cx, cy) radius:side * 0.5 + 5.0 inHost:self.superview
                            glass:CGRectMake(cx - side * 0.5, cy - side * 0.5, side, side)];
        }
    }

    /* 内层: 旋转载体。专辑图 + 遮罩形状都在这一棵我们自己的 layer 树上,
       加旋转 transform 就是"专辑跟遮罩一起 360° 转"; 反转由负角速度实现。 */
    if (!_artView) {
        _artView = [[UIView alloc] initWithFrame:CGRectZero];
        _artView.userInteractionEnabled = NO;
        _artView.backgroundColor = [UIColor clearColor];
        [self addSubview:_artView];
    }
    {
        CGRect artB = CGRectMake(0, 0, side, side);
        if (!CGRectEqualToRect(_artView.bounds, artB)) {
            _artView.bounds = artB;
            _artView.center = CGPointMake(side * 0.5, side * 0.5);
        }
    }
    _artView.layer.masksToBounds = YES;
    if (art && _artView.layer.contents != (__bridge id)art.CGImage) {
        _artView.layer.contents = (__bridge id)art.CGImage;
        _artView.layer.contentsGravity = kCAGravityResizeAspectFill;
    }

    CALayer *ml = _artView.layer.mask;
    if (![ml.name isEqualToString:kDIMaskLayerName]) {
        ml = [CALayer layer];
        ml.name = kDIMaskLayerName;
        _artView.layer.mask = ml;
    }
    /* 2.8.13: 蒙版层铺满正方形 —— 内层视图本身就是方的, 素材不再被拉扁 */
    if (!CGRectEqualToRect(ml.frame, _artView.bounds)) ml.frame = _artView.bounds;
    /* 2.8.13: contents 只在真的换了图时才赋值 —— 每帧无脑赋值会让 CA 重新生成
       纹理, 旋转时表现为闪烁/掉帧 */
    if (ml.contents != (__bridge id)self.maskImg.CGImage) {
        ml.contents = (__bridge id)self.maskImg.CGImage;
        ml.contentsGravity = kCAGravityResize;
        ml.contentsScale = UIScreen.mainScreen.scale;
        ml.opaque = NO;
    }
    /* ===== 2.8.16: 旋转交给 CoreAnimation 无限循环 =====
       286 反馈: "小岛到展开明显掉帧, 一卡一卡"。
       之前是每帧写 `_artView.transform = 角度` —— 60fps 下等于每秒 60 次
       提交渲染事务, 每次都打断 CA 合成, 旋转本身看着还行, 但整机 UI 掉帧。
       现在只装一次 CABasicAnimation(repeatCount=∞), 由渲染服务器按 VSync 插值,
       CPU 侧零开销; 速度/反向/开关变了才重装。 */
    BOOL wantRot = maskRotateOn && fabs(maskRotateSpeed) > 0.01;
    BOOL rotDirty = (wantRot != self.rotInstalled)
        || (wantRot && (fabs(self.rotInstalledSpeed - maskRotateSpeed) > 0.01
                        || self.rotInstalledRev != maskRotateReverse));
    if (rotDirty) {
        [_artView.layer removeAnimationForKey:@"diSpin"];
        self.rotInstalled = NO;
        if (wantRot) {
            CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
            spin.fromValue = @(0.0);
            spin.toValue = @(maskRotateReverse ? -2.0 * M_PI : 2.0 * M_PI);
            spin.duration = 360.0 / fabs(maskRotateSpeed);
            spin.repeatCount = HUGE_VALF;
            spin.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
            spin.removedOnCompletion = NO;
            [_artView.layer addAnimation:spin forKey:@"diSpin"];
            self.rotInstalled = YES;
            self.rotInstalledSpeed = maskRotateSpeed;
            self.rotInstalledRev = maskRotateReverse;
        }
    }
    if (!CGAffineTransformIsIdentity(_artView.transform))
        _artView.transform = CGAffineTransformIdentity;
    self.paintT = CFAbsoluteTimeGetCurrent();
    [CATransaction commit];
}

- (void)step {
    @try {
        UIView *host = self.superview;
        if (!host || host.window == nil) { [self diTeardown]; if (++_miss > 20) _link.paused = YES; return; }

        /* ===== 2.9.40: 形态必须先播报, 而且必须在"展开就退场"之前 =====
           2.9.38 把写 island.plist 放在了所有闸门之后, 结果死锁:
           SpringBoard 一进来就被 diMruSaysExpanded() 挡住退场 → 永远走不到写盘,
           MRU 读不到真实形态 → 继续按 66pt 判成展开 → 又写 expanded=1。
           现在把播报提到最前面, 环就解开了(宿主尺寸只有这边知道)。 */
        /* ===== 2.9.55: 16 完全回原样 —— 播报只给 17 =====
           2.9.54 把播报/否决权也开到了 16, 结果 16 上本来完美的画面被打乱。
           用户明确要求"16 一点都别动", 所以 16 走 2.9.48 原路: 不播报、不否决。 */
        if (diIsIOS17Up()) {
            CGSize hs = host.bounds.size;
            BOOL miniNow = (hs.height >= 24 && hs.height <= 62
                            && hs.width >= 100 && hs.width <= 208
                            && hs.width > hs.height * 1.55);
            BOOL expNow = (hs.height >= 120 && hs.height <= 300
                           && hs.width >= 280 && hs.width <= 440);
            diPublishIslandState(hs, miniNow, expNow);
            /* ===== 2.9.60: 撤掉 2.9.47 的"17 上整棵让位" =====
               用户定案: 2.8.40 只有 SpringBoard 侧的小岛遮罩, 怎么切换都正常;
               后面为了加"展开遮罩"(MRU 自绘)一步步把 SB 侧撤掉(2.8.84 展开退出、
               2.9.47 在 17 上整个退出), 17 的小岛遮罩被迫改由 MRU 画 —— 而 MRU 里
               躺着两颗头像(23 收缩 + 66 展开残留), 分不清收缩/展开, 这才有了
               "没遮罩/变大/错位"轮番出现。现在小岛遮罩恢复走 2.8.40 这条 SB 路
               (下面的 17 兜底放行是 2.9.40 就加好的); 展开态由两道本地闸门
               (>=180x46 / >70 高)加"MRU 确认过的展开信号"交给 MRU。 */
        }

        /* ===== 2.9.41: 展开态一律听 MRU 的 =====
           2.9.40 用"宿主说小岛"去覆盖 MRU 的展开信号 —— 但 17 展开后宿主 bounds
           仍停在 ~198x55(展开内容在内部 407x489 的 scene 里), 于是展开时被误判成小岛,
           SpringBoard 又画了一块玻璃 → 用户截图一里专辑下面那块模糊斑。
           收缩态的误报已经由 MRU 侧修掉(island.plist 判形态 + 让位时写 expanded=NO),
           这里直接恢复 2.8.86 原判据。 */
        /* ===== 2.9.61: 17 上不再读这个标志 —— 彻底分离两通道 =====
           392 日志实锤死法: 展开确认后 MRU 写 expanded=1 → 这边收掉小岛玻璃;
           用户缩回岛后, 那颗 66 大头像不再被 layout, MRU 的 apply 不跑 →
           expanded=1 没人清、心跳还在续期 → 这边被压住 10~20 秒不画玻璃
           (表现就是"展开生效时缩回来就变大; 展开没生效时缩回来正常")。
           17 上本地下闸门已齐: 宿主 ≥180x46(198x55 展开宿主)/高>70/宽>240
           全是本地判定, 不需要跨进程信号。 expanded 标志从此只给 16 用。 */
        if (!diIsIOS17Up() && diMruSaysExpanded()) {
            if (_glassOn || _targets.count || !self.hidden) {
                [self diTeardown];
                static CFAbsoluteTime sExpT;
                if (CFAbsoluteTimeGetCurrent() - sExpT > 2.0) {
                    sExpT = CFAbsoluteTimeGetCurrent();
                    DLog(@"遮罩退出: MRU 报展开态, 收掉小岛玻璃+系统蒙版(构建 %@)", DI_BUILD_VER);
                }
            }
            return;
        }

        /* 2.8.39: 遮罩锁死状态(308 反馈: "切歌变回方形然后才遮罩; 展开岛/切换歌曲
           不要影响, 一直显示遮罩")。播放中 → 记 lastPlayT; 玻璃在 + 30s 内播放过
           → lockMask=YES: 门户重建/指纹变化/判定瞬断/展开过渡一律不拆玻璃,
           只重扫校准位置。真停了 30s 以上或关开关才收(见下面各分支)。 */
        CFAbsoluteTime nowX = CFAbsoluteTimeGetCurrent();
        BOOL playingX = mrQueryOK ? musicPlaying : AVAudioSession.sharedInstance.isOtherAudioPlaying;
        if (playingX) self.lastPlayT = nowX;
        BOOL lockMask = self.glassOn && (nowX - self.lastPlayT < 30.0);
        /* ===== 2.9.42: 17 上取消"锁死玻璃" =====
           401 反馈: 展开时那块多出来的蒙版"偶尔还会出现", 要求彻底删掉。
           锁死(2.8.39)的本意是切歌/展开过渡时别闪一下方形, 但它让玻璃在宿主
           已经变成展开卡片后还要多停 0.3~1 秒 —— 那 0.3 秒就是用户看到的那块。
           17 上一律即时让位: 一旦判定不是小岛/正在形变, 立刻还原 + 收玻璃。
           16 保持原样(用户确认 16 正常, 不动)。 */
        if (diIsIOS17Up()) lockMask = NO;

        CALayer *pl = host.layer.presentationLayer;
        CGSize bs = pl ? pl.bounds.size : host.bounds.size;
        /* ===== 2.9.74.1: 宿主回到小岛原尺寸 = 已经收回来了 =====
           交接宽限(mruHoldT)本来只为"展开起手那一两拍 MRU 自己也会写 NO"而设。
           408 日志: 收回后这个探针宿主先回到 189x37, 这边却还要等 MRU 连说 0.3 秒
           NO 才肯挂玻璃 —— 那 0.3 秒岛上只有 MRU 那颗 23, 交回 SB 时尺寸/位置
           差一两像素, 就是"卡一下、专辑偏一下"。宿主既然已经回到小岛原尺寸,
           宽限立即作废, 当帧就能挂回去。 */
        if (diIsIOS17Up() && self.mruHoldT > 0 && bs.height < 46.0 && bs.width < 210.0) {
            self.mruHoldT = 0;
            self.mruClearT = 0;
        }
        /* ===== 2.9.73: "MRU 已经展开"这一条比宿主尺寸快得多 =====
           403 日志 + 视频逐帧实锤: 展开那一下我们探的这个宿主实例一直是 189x37
           (屏幕上的岛其实已经 407x197 了, 那是另一个容器实例), 它要等 0.5~1 秒后
           自己变成 407x197 才整棵退场。这中间小岛那颗 24.9pt 的玻璃一直画在
           左上角 —— 逐帧量过: 圆心 (17.5,19.5)、边长 18pt, 正好是小岛槽位
           (8,7)/22pt 的位置, 而展开态封面在 (17,26)/66pt。所以"展开时专辑小了
           一下然后变大"里那颗小圆就是它。
           MRU 一旦确认头像变成 66 就会把 expanded 写进 state.plist —— 这是"岛
           真的展开了"最快的信号, 直接照它让位, 不再等宿主尺寸。
           暂停时播放位为 NO, 不走这条(pauseMorph 要继续保住小岛玻璃)。 */
        if (diIsIOS17Up() && playingX && diMruSaysExpanded()) {
            /* 2.9.74: 不再要求 _glassOn —— 让位之后下一个 layout 会把玻璃重新挂上,
               402/404 日志里"立即让位"后面紧跟四十多条"遮罩挂上(玻璃)"就是这么来的。
               这里每次都记 mruHoldT, 交接窗口内挂载守卫一律不放行。 */
            self.mruHoldT = CFAbsoluteTimeGetCurrent();
            self.mruClearT = 0;
            if (_glassOn || _targets.count || !self.hidden) {
                static CFAbsoluteTime sMrueT;
                if (CFAbsoluteTimeGetCurrent() - sMrueT > 1.0) {
                    sMrueT = CFAbsoluteTimeGetCurrent();
                    DLog(@"遮罩[17]: MRU 已确认展开(宿主 %.0fx%.0f 还未跟上) → 立即让位", bs.width, bs.height);
                }
                [self diRestorePainted];
                self.glassOn = NO;
                if (gDISBGlassOn) { gDISBGlassOn = 0; diWriteIslandPlist(); }
                self.loggedShow = NO;
                self.bigT = CFAbsoluteTimeGetCurrent();
                self.stableFrm = 0;
            }
            return;
        }
        /* MRU 说"不是展开"要连续 0.12 秒才算数 —— 展开起手那一两拍它自己也会写 NO,
           单拍采信会把玻璃又挂回去(就是那颗转圈的小专辑)。
           2.9.74.1: 0.3 → 0.12 秒 —— 收回时这 0.3 秒就是小岛玻璃的空白窗口。 */
        if (self.mruHoldT > 0) {
            if (!diMruSaysExpanded()) {
                CFAbsoluteTime nw = CFAbsoluteTimeGetCurrent();
                if (self.mruClearT <= 0) self.mruClearT = nw;
                if (nw - self.mruClearT >= 0.12) { self.mruHoldT = 0; self.mruClearT = 0; }
            } else {
                self.mruClearT = 0;
            }
        }
        /* ===== 2.9.46: 删掉 2.9.42 的"形变中全程让位" =====
           那条判据是"模型层 vs 呈现层差 1pt 就算在形变", 但 17 的小岛**本身**一直在
           做宽度动画: 日志里 127x37 ↔ 179/189x37 每几秒一轮(波形/配件进出), 于是
           玻璃被反复拆掉又挂回 —— 用户看到的就是"要么显示回原来的, 要么就重叠"。
           收起时那块大黑块另用"明显缩小"判据处理(见下面 shrink17, 已限定只从大形态
           回缩才触发), 这里整段删除。 */
        /* ===== 2.9.42: 17 展开态宿主 = 198x55, 小岛 = 166x37 =====
           401 反馈: 展开时那块多出来的蒙版"偶尔还会出现"。17 上展开后宿主 bounds
           停在小岛样的 198x55(展开内容在内部 scene 里), 2.9.41 只靠 MRU 的
           state.plist 判形态, 而 MRU 那边写盘有延迟/被 66pt 判据干扰 —— 于是展开
           的前几百毫秒这边照样画了一块玻璃。
           这里补一条**本地**判据: 17 上宿主高 >=46 且宽 >=180 就是展开宿主
           (实测小岛恒为 166x37~189x37, 展开恒为 198x55), 立即整棵退场。 */
        if (diIsIOS17Up() && bs.height >= 46.0 && bs.width >= 180.0) {
            if (_glassOn || _targets.count || !self.hidden) {
                [self diTeardown];
                static CFAbsoluteTime sExp2T;
                if (CFAbsoluteTimeGetCurrent() - sExp2T > 3.0) {
                    sExp2T = CFAbsoluteTimeGetCurrent();
                    DLog(@"遮罩[17]: 宿主 %.0fx%.0f 判为展开(>=180x46) → 整棵退场", bs.width, bs.height);
                }
            }
            return;
        }
        /* 展开大专辑在跨进程内容中；当前探针只有小门户坐标。
           即使小岛的玻璃被播放锁定，也不能在展开宿主上重显 25pt 的副本。 */
        if (bs.width >= 280.0 && bs.height >= 120.0) {
            if (self.glassOn || !self.hidden) [self diTeardown];
            /* 2.8.86: 不再 pause display link —— pause 之后没有任何地方 resume,
               缩回小岛时这个实例就永远醒不过来(遮罩再也不出现)。 */
            return;
        }

        /* ===== 2.8.20: 宿主内容指纹 —— 来电/充电/通知岛出现瞬间立即收玻璃 =====
           290 反馈: "打电话岛第一时间还是显示那个蒙版, 后面才隐藏"。
           系统换岛时会整体替换宿主的子视图, 而尺寸可能还停在小岛值几帧,
           玻璃贴在原地就闪了出来。指纹=子视图数+首/末视图指针(排除自己),
           只做两次指针比较, 一变立刻还原系统专辑 + 收玻璃 + 重扫。 */
        {
            NSUInteger sc = host.subviews.count;
            UIView *f1 = nil, *f2 = nil;
            for (UIView *v in host.subviews) {
                if (v == self) { sc--; continue; }
                if (!f1) f1 = v;
                f2 = v;
            }
            if (self.fpCount > 0 && (sc != self.fpCount || f1 != self.fpFirst || f2 != self.fpLast)) {
                self.fpCount = sc; self.fpFirst = f1; self.fpLast = f2;
                /* 2.8.39: 锁死时门户重建(切歌/App 重建内容层)不再拆玻璃 ——
                   只重扫校准封面位置, 用户看不到"先方后遮罩"。 */
                if (lockMask) {
                    self.stableFrm = 0;
                    self.scanT = 0;          /* 立即重扫(重新定位封面) */
                    return;
                }
                if (self.glassOn || !self.hidden) {
                    [self diRestorePainted];
                    if (self.glassOn) { gDISBGlassOn = 0; diWriteIslandPlist(); }   /* 2.9.68: 收玻璃也算放手, MRU 该接手 */
                    self.glassOn = NO;
                    if (!self.hidden) self.hidden = YES;
                    self.stableFrm = 0;
                    self.scanT = 0;          /* 立即重扫(重新判定是不是音乐岛) */
                    return;
                }
            } else {
                self.fpCount = sc; self.fpFirst = f1; self.fpLast = f2;
            }
        }

        /* ===== 2.8.18: 过渡帧不再"收玻璃 + 还原系统专辑" =====
           288 反馈: "每次退出岛上的专辑就会先显示方的然后才显示遮罩"。
           根因就是这里 —— 岛尺寸一变(185x52↔197x55↔129x38 来回两三个点),
           旧代码立刻 `diRestorePainted`(系统方形专辑露出来) 并藏起玻璃,
           等尺寸稳定 3 帧后再重画, 于是每一跳都是"方形 → 遮罩"闪一次。
           现在: 过渡帧**保持玻璃、保持系统专辑被藏**, 位置沿用缓存(专辑尺寸
           本来就固定 36x36, 只有原点差 1~3pt), 稳定 1 帧后重扫精确校准。
           视觉上玻璃从头到尾都在, 不会再有中间那一下方形。
           2.8.20 补丁: 但**尺寸在变大**的帧除外 —— 那是展开起手
           (290 日志实锤 201x57 / 207x58 被当成小岛挂了玻璃, 就是用户看到的
           "展开岛偶尔还会显示那个蒙版"), 变大即立即收玻璃, 不等稳定。 */
        BOOL growing = (bs.width - self.lastBW > 2.0) || (bs.height - self.lastBH > 1.5);
        BOOL sizeChanged = (fabs(bs.width - self.lastBW) > 1.2 || fabs(bs.height - self.lastBH) > 1.2);
        /* 2.9.67: 连续变大帧数 —— "刚注销完第一次长按会变小"的判据。
           398 反馈: 重启后第一次长按展开, 小岛会先出现一颗 25pt 的小玻璃再变大。
           根因是 2.9.64 那道"播报说展开就别新挂小玻璃"的闸门依赖 island.plist,
           刚注销时文件还没被写过 → diIslandFreshExpand 返回 NO → 闸门失效,
           展开起手照样挂了一颗小圆。改成同时看物理信号: 连续 2 帧在变大 = 正在展开。 */
        if (growing) self.growStreak++; else self.growStreak = 0;
        /* ===== 2.9.46: 17 上只有"进出展开"才算形变 =====
           小岛自己在 127x37 与 189x37 之间来回(波形/配件进出), 旧判据把这当成
           "变大/明显缩小", 每几秒就拆一次玻璃 → 原图闪现/两份重叠。
           这里用高度 60pt 当分界(小岛 ≤41, 展开 ≥198), 小岛内部变化一律按"原地重画"。 */
        BOOL bigPrev = (self.lastBH >= 60.0);
        BOOL bigNow = (bs.height >= 60.0);
        BOOL bigChange = bigNow || bigPrev;
        /* 2.9.67: 17 上"宽度已经越过小岛上限(208)"也算形变 —— 398 反馈"刚注销完
           第一次长按会变小": 展开起手时小岛里那颗 25pt 小玻璃一直挂到 240 宽才让位,
           于是岛已经在长大, 专辑还是小小一颗。宽度 >212 就按"展开起手"处理, 直接
           让位给原生内容, 等 MRU 的 66 接管。小岛内部(≤208)的波形进出不受影响。 */
        if (diIsIOS17Up() && bs.width > 212.0) {
            /* 暂停/瞬断时不算展开起手 —— 那条路要让 pauseMorph 保住玻璃(见下)。 */
            BOOL playingNow = mrQueryOK ? musicPlaying
                                        : AVAudioSession.sharedInstance.isOtherAudioPlaying;
            /* 2.9.72: 展开变形段(208 < 宽 < 400, 高 < 192)不再一过 212 就让位。
               让位之后 MRU 的 66 要等宿主 407 才铺, 中间半秒多岛上只剩它那颗
               23pt 小头像 —— 402 视频里"先显示小的再变大"。这段由下面的
               morphExpand 接着画, 玻璃边长跟着宿主一起长。 */
            BOOL morphZone = self.glassOn && bs.width < 400.0 && bs.height < 192.0;
            if (playingNow && !morphZone) bigChange = YES;
        }
        /* 17 上"从大形态明显缩小"= 收起起手, 立即让位(小岛内部收缩不算) */
        BOOL shrink17 = diIsIOS17Up() && bigPrev
            && (self.lastBW - bs.width > 8.0 || self.lastBH - bs.height > 8.0);
        /* 2.9.72: 收起变形段(宽 208..400、高 <192)不整块让位 —— 旧代码一检测到
           "从大形态明显缩小"就 diTeardown, 让小岛专辑在半大不小的岛里闪一下原生
           方形再回位(用户: "收回小岛的专辑显示偏移然后才正常")。这段改由下面的
           morphExpand 接着画, 玻璃跟着岛体一起缩回小岛槽位。 */
        if (shrink17 && self.glassOn && bs.width >= 208.0 && bs.width < 400.0
            && bs.height < 192.0) {
            shrink17 = NO;
        }
        self.lastBW = bs.width; self.lastBH = bs.height;
        if (sizeChanged) self.stableFrm = 0;
        else if (self.stableFrm < 2) self.stableFrm++;
        if (shrink17) {
            /* 401 反馈: 收起时会先看到一大块再回原位。收起起手就把玻璃和被藏的
               系统专辑层全部还原, 让系统按它自己的内容做形变。 */
            if (self.glassOn || !self.hidden || self.hiddenViews.count) {
                [self diTeardown];
                static CFAbsoluteTime sShT;
                if (CFAbsoluteTimeGetCurrent() - sShT > 2.0) {
                    sShT = CFAbsoluteTimeGetCurrent();
                    DLog(@"遮罩[17]: 岛在收起(%.0fx%.0f) → 立即让位", bs.width, bs.height);
                }
            }
            return;
        }
        if (growing && (!diIsIOS17Up() || bigChange) && (self.glassOn || !self.hidden)) {
            /* 2.8.39: 锁死时展开起手也不拆 —— 玻璃保持在原位(展开动画结束后
               由展开态挂载路径重定位到展开方块层), 用户看到遮罩从头到尾不断。 */
            if (lockMask) {
                self.stableFrm = 0;
                self.bigT = CFAbsoluteTimeGetCurrent();
                return;
            }
            /* 展开起手: 立即收玻璃 + 还原系统专辑, 并记住"不再参与"直到缩回 */
            [self diRestorePainted];
            if (self.glassOn) { gDISBGlassOn = 0; diWriteIslandPlist(); }   /* 2.9.68: 展开起手放手 → MRU 必须立刻接手 */
            self.glassOn = NO;
            self.loggedShow = NO;
            if (!self.hidden) self.hidden = YES;
            self.bigT = CFAbsoluteTimeGetCurrent();
            self.stableFrm = 0;
            return;
        }

        /* ① 2.8.21: 形态闸门重写(291: "展开岛有时候还会触发显示那个白色蒙版")。
           旧代码两处病根:
             · 2.8.20 的"展开结构闸门"(CALayerHost 高≥150 即大内容)对音乐岛自己也
               恒成立 —— 音乐岛里挂着 407x489 的跨进程 scene 层, isMini 恒为 0,
               主闸门从未通过过, 全靠"找到封面就放行"的兜底在干活;
             · 兜底窗口(20~62 高 × 20~240 宽)太松, 展开/收起动画中间帧
               (201x57 / 204x57 / 206x52 / 220x38 / 233x38)全落在窗口内,
               而"尺寸变大即收玻璃"只抓单帧涨幅, 逐帧小步长大和收起(变小)都漏。
           现在: 窗口收紧到真实小岛形态(compact 126x37 ~ mini 205x56),
           **新挂载必须尺寸稳定 2 帧**(展开/收起动画的帧永远在变, 不可能稳定),
           离开窗口立即收玻璃(保留缓存, 缩回小岛第一帧就能画回去, 不闪方)。 */
        BOOL isMini = (bs.height >= 24 && bs.height <= 62
                       && bs.width >= 100 && bs.width <= 208
                       && bs.width > bs.height * 1.55);
        /* ===== 2.9.72: 展开变形段(小岛 → 展开)由 SB 接着画, 玻璃跟着长大 =====
           402 日志 + 视频逐帧实锤(首次展开, 22:07:43~44):
             · 宿主逐帧 197x37 → 201x38 → 205x38 → **210x39(gate=0)** → 232x42 …
               → 407x198, 整个过程 ~1 秒;
             · isMini 上限 208 → 一过 208 SB 就整块放手; 而 MRU 那边的 66 玻璃要等
               宿主到 407 才铺(它读的是展开态那颗 66 头像);
             · 中间这 0.6~0.9 秒, 岛上显示的是 MRU 里那颗 23pt 的小岛头像 ——
               视频实测直径 ≈24pt, 稳定展开后 0.3 秒才跳成 60pt。
           用户说的"首次展开专辑先显示小的然后变大"就是这一段。
           现在把这段"宽高连续变大"的过渡帧算进小岛形态: SB 继续画, 玻璃边长按宿主
           宽度从 25.3 线性长到 66(与 MRU 展开态的 66 对齐), 到 400 宽再交给 MRU。
           只在"本来就在画小岛玻璃"时接(`glassOn || cacheCoverV`), 冷启动不抢。 */
        BOOL morphExpand = NO;
        if (diIsIOS17Up() && !isMini && enabled && maskOn && !gRecordingActive
            && bs.width > 208.0 && bs.width < 400.0
            && bs.height >= 34.0 && bs.height < 192.0
            && bs.width > bs.height * 1.25
            && (self.glassOn || self.cacheCoverV != nil)) {
            morphExpand = YES;
            isMini = YES;          /* 走同一条小岛绘制路径(封面候选/藏层/绘玻璃) */
        }
        /* ===== 2.9.66: 暂停形变时保住小岛玻璃(修"暂停专辑变大"回归) =====
           397 日志实锤: 暂停瞬间小岛会加宽到 209x40 → 220x45(播放键换成暂停键那一帧),
           越过 isMini 的 208 上限 → gate=0 → shapeOnly 里 lockMask 在 17 上是 NO
           → diRestorePainted + glassOn=NO, SB 玻璃拆掉; 而 MRU 那颗 66 玻璃还在
           (island.plist 停在"展开"没人改), 于是 37pt 的小岛里嵌了一颗 66pt 的专辑
           —— 用户视频里"暂停专辑变大"就是这个。
           这里只在"17 + 已有玻璃 + 当前没在播放(暂停/切歌瞬断)"时放宽宽度上限到 236,
           让 SB 玻璃跟着形变活下来; 播放中的展开起手照旧按 208 收紧(展开仍归 MRU)。 */
        BOOL playingAtGate = mrQueryOK ? musicPlaying
                                       : AVAudioSession.sharedInstance.isOtherAudioPlaying;
        BOOL pauseMorph = diIsIOS17Up() && self.glassOn && !playingAtGate
                          && bs.height >= 24 && bs.height <= 70
                          && bs.width >= 100 && bs.width <= 236
                          && bs.width > bs.height * 1.55;
        /* 2.8.39: 展开态重新参与(308: "展开岛什么的不要影响, 一直显示遮罩")。
           窗口 = 媒体展开宿主实测 407x201 / 330x72 系; 收紧高度下限 120 挡掉
           来电展开(330x72 高 72)和一切过渡中间帧(259x98 / 313x131 都 < 120 或宽超),
           上限 300x440 挡掉 DriftIsland 全屏信息页(430x932)和充电岛(430x360 高 360)。
           充电岛虽然尺寸命中, 但下面音乐岛结构判定(diIsNowPlayingHostCached)会挡住。 */
        BOOL isExpand = (bs.height >= 120 && bs.height <= 300
                         && bs.width >= 280 && bs.width <= 440);
        {
            static CGFloat sLastW, sLastH; static CFAbsoluteTime sSzT;
            if ((fabs(bs.width - sLastW) > 6 || fabs(bs.height - sLastH) > 6)
                && CFAbsoluteTimeGetCurrent() - sSzT > 1.0) {
                sSzT = CFAbsoluteTimeGetCurrent(); sLastW = bs.width; sLastH = bs.height;
                DLog(@"遮罩宿主尺寸: %.0fx%.0f → %@ (小岛=%d 展开=%d 开关=%d)",
                     bs.width, bs.height,
                     (isMini || isExpand) ? @"参与" : @"跳过", isMini, isExpand, maskOn);
            }
        }
        BOOL gate = enabled && maskOn && !gRecordingActive && (isMini || isExpand || pauseMorph);
        if (diIsIOS17Up()) {
            static CFAbsoluteTime sGT; static int sLastGate = -1; static CGFloat sGW, sGH;
            CFAbsoluteTime gn = CFAbsoluteTimeGetCurrent();
            if ((int)gate != sLastGate || fabs(bs.width - sGW) > 3 || fabs(bs.height - sGH) > 3 || gn - sGT > 3.0) {
                sGT = gn; sLastGate = (int)gate; sGW = bs.width; sGH = bs.height;
                DLog(@"遮罩[17]: 宿主=%.0fx%.0f 小岛=%d 展开=%d 开=%d 掩码=%d 录屏=%d gate=%d",
                     bs.width, bs.height, isMini, isExpand, enabled, maskOn, gRecordingActive, gate);
            }
        }
        /* ===== 2.9.74: 已交接给 MRU → 这个实例闭嘴 =====
           展开/收起动画期间 SpringBoard 的小岛容器会被系统淡出并放大, 我们的玻璃
           是它的兄弟视图, 不会跟着淡 —— 留在原地就是"展开大岛里那颗环绕转圈的小专辑"。
           交接窗口内直接返回: 不新挂、不重画、不校准。 */
        if (diIsIOS17Up() && self.mruHoldT > 0) return;
        /* ===== 2.9.65: 过渡帧锁住玻璃边长(修"从小岛展开时专辑抖一下") =====
           396 日志实锤: 展开起手 + 波形进出时宿主会在 127x37 / 137x42 / 191x41 /
           193x37 之间来回跳, 每一跳封面候选都变(边长 25.3 ↔ 30.4, 圆心上下 3pt),
           玻璃跟着跳 = 用户看到的"小岛专辑抖一下"。
           这里在"尺寸还在变"的帧把当前边长锁住(圆心仍跟随, 位置是平滑的),
           稳定 2 帧后解锁, 让下一次校准照常生效。 */
        if (diIsIOS17Up() && isMini && !morphExpand) {
            if (self.glassOn && sizeChanged && self.lastGlassSide > 1.0) {
                if (self.freezeSide <= 0) {
                    self.freezeSide = self.lastGlassSide;
                    static CFAbsoluteTime sFzT;
                    if (CFAbsoluteTimeGetCurrent() - sFzT > 3.0) {
                        sFzT = CFAbsoluteTimeGetCurrent();
                        DLog(@"遮罩[17]: 过渡帧锁边长 %.1fpt (宿主 %.0fx%.0f)", self.freezeSide, bs.width, bs.height);
                    }
                }
            } else if (self.freezeSide > 0 && self.stableFrm >= 2) {
                self.freezeSide = 0;
            }
        } else if (self.freezeSide > 0) {
            self.freezeSide = 0;
        }
        /* ===== 2.8.84: 展开态彻底交给 MediaRemoteUI，SpringBoard 侧全部退出 =====
           331 反馈: 头像下方多出一个心形模糊光斑（用户圈出来的"多出来的蒙版"）。
           根因: 展开后宿主尺寸判定仍停在"小岛"（全部日志里从来没有 展开=1），
           于是这里继续按小岛路径干活；一旦 MediaRemote 取图瞬间为空，就会走下面
           的"系统层 mask 兜底"：diMaskTargetsFor 把封面**父容器**（展开态是更大的
           一块，里面是模糊背景）裁成心形 —— 那块背景就按遮罩形状露出来。
           展开岛的头像遮罩已由 MRU 内的自绘玻璃负责，这里必须彻底退出：
           宿主一旦超过小岛尺寸（高>70 或宽>240），摘 mask + 拆玻璃 + 隐藏探针，
           缩回小岛后再由正常流程重画。 */
        if ((bs.height > 70.0 || bs.width > 240.0) && !morphExpand) {
            if (!self.hidden || _glassOn || _targets.count) {
                static CFAbsoluteTime sBigT;
                if (CFAbsoluteTimeGetCurrent() - sBigT > 3.0) {
                    sBigT = CFAbsoluteTimeGetCurrent();
                    DLog(@"遮罩退出: 宿主 %.0fx%.0f 超出小岛, 展开态由 MRU 负责(不挂系统蒙版)",
                         bs.width, bs.height);
                }
            }
            [self diTeardown];
            return;
        }
        /* 尺寸还在变(展开/收起动画途中) → 不新挂玻璃; 已挂着的由上面 growing /
           下面的离开窗口逻辑收拾, 过渡期间保留(2.8.18: 不再"先方后遮罩")。
           等待期间把探针拨回 30fps —— 稳定态会被降到 8fps, 不拨回来
           "稳定 2 帧"要等 250ms, 挂载慢半拍。 */
        if (gate && !self.glassOn && self.stableFrm < 2) {
            if (_link.preferredFramesPerSecond != 30) _link.preferredFramesPerSecond = 30;
            return;
        }
        /* 2.9.64: 展开过渡期不再新挂小号玻璃 —— 395: 长按展开偶发"专辑很小然后正常":
           过渡中宿主还够着 isMini 窗口, 按 26x22 门户缓存画出一颗 25pt 小圆。
           展开态由 MRU 接管, 播报新鲜且说展开时 SB 别再新挂(已挂的玻璃照旧跟随)。 */
        if (diIsIOS17Up() && isMini && !self.glassOn
            && (diIslandFreshExpand() || self.growStreak >= 2)) return;
        /* 2.8.15: 音乐岛关卡 —— 只有"正在放歌"的岛才继续(通知岛/头像一律不遮)。 */
        if (gate && !diIsNowPlayingHostCached(host)) {
            /* ===== 2.9.40: 17 的结构兜底 =====
               379 日志实锤: 17 上小岛宿主是 SBSystemApertureContainerView 166x37,
               子视图全是 MRUActivity* —— 旧判据要找的 _SAUIProvidedViewContainerView
               一个都没有, 于是"音乐岛=否"恒成立、gate 永远关着,
               2.8.75 那套玻璃在 17 上从来没画过(这才是"改回去也不行"）。
               这里用一个几何兜底: 在播 + 宿主左侧能找到 14~50pt 的专辑封面视图 → 放行。 */
            BOOL ok17 = NO;
            if (diIsIOS17Up()) {
                BOOL playing17 = mrQueryOK ? musicPlaying
                                           : AVAudioSession.sharedInstance.isOtherAudioPlaying;
                if (playing17) {
                    CGRect cr17 = CGRectZero;
                    UIView *cv17 = diFindAlbumCoverView(host, &cr17);
                    CGFloat mn = MIN(cr17.size.width, cr17.size.height);
                    CGFloat mx = MAX(cr17.size.width, cr17.size.height);
                    if (cv17 && mn >= 14.0 && mx <= 50.0) {
                        ok17 = YES;
                        static CFAbsoluteTime sOkT;
                        if (CFAbsoluteTimeGetCurrent() - sOkT > 5.0) {
                            sOkT = CFAbsoluteTimeGetCurrent();
                            DLog(@"[17] 音乐岛兜底放行: 封面=%@ %.0fx%.0f 宿主=%.0fx%.0f",
                                 NSStringFromClass(cv17.class), cr17.size.width, cr17.size.height,
                                 bs.width, bs.height);
                        }
                    }
                } else {
                    /* 2.9.64: 暂停/切歌瞬断保持遮罩 —— 395 实锤: 16:30:11 与 16:30:42
                       暂停时 playing17=NO → 老逻辑 teardown: SB 玻璃拆掉 + 系统门户层
                       还原, 而 MRU 那颗 23 玻璃还挂着 → 两层专辑叠出"暂停变大偏移";
                       切歌瞬间播放态短暂为 NO → "切换先变回原来的"。
                       2.9.66: 放宽到"封面层还在就算音乐岛" —— 397 里暂停时玻璃已经被
                       前一步的形变拆掉过, 单靠 glassOn 救不回来, 小岛就裸着系统专辑。
                       已画着玻璃、或宿主里仍有 12~50pt 的专辑封面层 → 认定是音乐岛
                       (暂停不等于通知岛); 真被通知替换时封面层消失, glassMiss 自然收。 */
                    BOOL keepPause = self.glassOn;
                    if (!keepPause) {
                        CGRect crP = CGRectZero;
                        UIView *cvP = diFindAlbumCoverView(host, &crP);
                        CGFloat mnP = MIN(crP.size.width, crP.size.height);
                        CGFloat mxP = MAX(crP.size.width, crP.size.height);
                        keepPause = (cvP && mnP >= 12.0 && mxP <= 50.0);
                    }
                    if (keepPause) {
                        ok17 = YES;
                        static CFAbsoluteTime sPzT;
                        if (CFAbsoluteTimeGetCurrent() - sPzT > 5.0) {
                            sPzT = CFAbsoluteTimeGetCurrent();
                            DLog(@"[17] 暂停/瞬断: 封面层仍在, 保持遮罩 宿主=%.0fx%.0f 玻璃=%d",
                                 bs.width, bs.height, (int)self.glassOn);
                        }
                    }
                }
            }
            gate = ok17 ? gate : NO;
            if (!ok17) {
            static CFAbsoluteTime sNotT;
            if (CFAbsoluteTimeGetCurrent() - sNotT > 5.0) {
                sNotT = CFAbsoluteTimeGetCurrent();
                DLog(@"遮罩跳过: 宿主 %.0fx%.0f 不是正在播放的音乐岛(通知岛/暂停), 不遮罩",
                     bs.width, bs.height);
            }
            /* 2.8.39: 判定瞬断**永不拆玻璃**(锁死) —— 2.8.21 的"刚画过 1.0s 内保留"
               在切歌时不够: 门户重建经常超过 1s, 用户看到"先显示方的然后才显示遮罩"。
               播放中或 30s 内播放过 → 直接 return 保留玻璃, 等判定恢复自然续上。
               真停了 30s 以上 → 落到下面 diTeardown 正常收。 */
            if (lockMask) return;
            BOOL playing = mrQueryOK ? musicPlaying : AVAudioSession.sharedInstance.isOtherAudioPlaying;
            if (playing && self.glassOn && CFAbsoluteTimeGetCurrent() - self.paintT < 1.0) return;
            }
        }
        if (!gate) {
            /* 2.8.18: 分两种情况下岗 ——
               ①形态不对(展开岛 / 充电岛 / 大岛): 只把玻璃收起来、系统专辑还原,
                 但**保留封面/方块缓存**, 这样缩回小岛的第一帧就能直接按缓存画,
                 中间不会再有"系统方形专辑"露出来;
               ②根本不是音乐岛(暂停 / 通知岛): 才整体 teardown, 探针该歇就歇。
               2.8.39: 锁死(播放中/30s 内播放过 + 玻璃在)时①也不收 ——
               "切换歌曲、展开岛都不要影响, 一直显示遮罩"(308)。 */
            BOOL shapeOnly = (enabled && maskOn && !gRecordingActive
                              && !isMini && !isExpand
                              && (self.glassOn || self.cacheCoverV != nil));
            if (shapeOnly) {
                /* 锁死: 保持玻璃等待(展开态由 isExpand 分支接管, 充电/来电大岛
                   不锁死 —— 它们不是播放中的音乐岛, lockMask 不会为 YES)。 */
                if (lockMask) return;
                if (self.glassOn || !self.hidden) {
                    [self diRestorePainted];
                    if (self.glassOn) { gDISBGlassOn = 0; diWriteIslandPlist(); }   /* 2.9.68: 收玻璃也算放手, MRU 该接手 */
                    self.glassOn = NO;
                    self.loggedShow = NO;
                    self.hidden = YES;
                }
                self.stableFrm = 0;
                return;
            }
            [self diTeardown];
            if (++_miss > 20) _link.paused = YES;
            return;
        }
        _miss = 0;

        /* 2.7.43: 素材路径/列表每 0.4 秒重算一次 —— 之前每帧都递归扫目录 + 同步偏好,
           60fps 下等于每秒 60 次文件系统遍历, 又卡又可能读到中间态。
           gMaskGen 变了(设置页换了素材)就立即重算, 不用等那 0.4 秒。 */
        static NSString *sPathCache; static CFAbsoluteTime sPathT; static NSInteger sGenSeen = -1;
        NSString *path;
        if (CFAbsoluteTimeGetCurrent() - sPathT > 0.4 || !sPathCache || gMaskGen != sGenSeen) {
            sPathT = CFAbsoluteTimeGetCurrent();
            sGenSeen = gMaskGen;
            sPathCache = diMaskCurrentPathV2();
        }
        path = sPathCache;
        if (!path) {
            [self diTeardown];
            if (![self.loadedPath isEqualToString:@"-"]) { self.loadedPath = @"-"; DLog(@"遮罩素材为空: %@", kMaskDir); }
            return;
        }
        /* 2.7.45: 素材指纹 —— 全部挂在实例上(见 fpSel/fpMtime/fpGen)。
           换素材的三个触发源:
             · 路径变了(选了另一个文件)
             · 文件 mtime/大小变了(同名覆盖)
             · gMaskGen 变了(设置页点了选择, 强制重建)
           三条任一命中才重建蒙版; 否则保持现状, 不再每秒重建十几次。 */
        NSString *selNow = pString(@"diAlbumMaskAsset");
        BOOL genChanged = (gMaskGen != self.fpGen); /* 初始 0 是有效代数，首次由 !maskImg 触发 */
        /* 2.7.45: stat 也是共享资源, 但两个探针要的完全是同一份数据, 所以保留 static 缓存;
           只是把它挪到"每个实例都会读"的公共函数里, 见 diMaskStatOf */
        double mtimeVal = 0; unsigned long long sizeVal = 0; BOOL statOK = diMaskStatOf(path, &mtimeVal, &sizeVal);
        BOOL selChanged = !((selNow == self.fpSel) || [selNow isEqualToString:self.fpSel]);
        BOOL mtChanged = statOK && (llround(mtimeVal * 100.0) != llround(self.fpMtime * 100.0));
        BOOL pathChanged = ![self.loadedPath isEqualToString:path];
        BOOL needRebuild = pathChanged || !self.maskImg || selChanged || mtChanged || genChanged;
        {
            static CFAbsoluteTime sDbgT;
            if (CFAbsoluteTimeGetCurrent() - sDbgT > 3.0) {
                sDbgT = CFAbsoluteTimeGetCurrent();
                DLog(@"遮罩选择诊断: 偏好=%@ 解析=%@ 已加载=%@ 选择变=%d 文件变=%d 换代=%d 重建=%d 图=%@ 旋转=%@",
                     selNow ?: @"(空)",
                     [path stringByReplacingOccurrencesOfString:kMaskDir withString:@""],
                     [self.loadedPath stringByReplacingOccurrencesOfString:kMaskDir withString:@""],
                     selChanged, mtChanged, genChanged, needRebuild, self.maskImg ? @"有" : @"无",
                     maskRotateOn ? @"开" : @"关");
            }
        }
        if (needRebuild) {
            self.fpSel = [selNow copy];
            self.fpMtime = mtimeVal;
            self.fpGen = gMaskGen;
            /* 换代时把已挂的蒙版全部摘掉重建 —— 只换 mask.contents 时系统会沿用旧的
               位图引用, 用户看到的就是"换了素材形状没变"。整层重建最干净。 */
            if (genChanged || selChanged) {
                for (UIView *t in _targets.allObjects) diStripMaskFromCover(t);
                [_targets removeAllObjects];
            }
            UIImage *raw = diMaskAlphaCached(path);
            self.loadedPath = path;
            /* 2.7.46: 生成失败也**不能**让遮罩整个消失 —— 退回内置圆形, 并在日志里说清楚
               是哪张图出了问题。上一版这里直接 teardown, 用户看到的就是"连遮罩都没有了"。 */
            if (!raw) {
                raw = diBuiltinMaskImage();
                gDiMaskBuiltin = YES;
                static CFAbsoluteTime sFailT;
                if (CFAbsoluteTimeGetCurrent() - sFailT > 5.0) {
                    sFailT = CFAbsoluteTimeGetCurrent();
                    DLog(@"遮罩素材读取失败: %@ (文件存在=%@) —— 已用内置圆形顶上",
                         path, [[NSFileManager defaultManager] fileExistsAtPath:path] ? @"是" : @"否");
                }
                if (!raw) { [self diTeardown]; return; }
            }
            DLog(@"遮罩素材换图: %@ (mtime=%.0f 选择=%@) 重挂蒙版", path.lastPathComponent, mtimeVal, selNow ?: @"(未选)");
            /* 2.7.44: 把"到底用的哪张、内置还是用户的"直接写进日志 ——
               用户反复问"是内置遮罩还是我路径的素材", 一条日志答清楚。 */
            {
                CGPoint c0 = CGPointZero; CGFloat r0 = diShapeRadiusOf(raw, &c0);
                DLog(@"遮罩来源: %@ 文件=%@ 内置兜底=%@ 形状半径%.1f%%",
                     gDiMaskBuiltin ? @"内置圆形(你的素材被判无效)" : @"你的素材",
                     path.lastPathComponent, gDiMaskBuiltin ? @"是" : @"否", r0 * 100.0);
            }

            /* 2.7.27 自检: 覆盖率说明这张蒙版到底裁不裁得动 */
            double cov = gDiMaskCoverage;
            gDiMaskBuiltin = NO;
            /* 挖空型素材(形状是透明的洞, 四周实心): 反相一次再验 */
            if (gDiMaskHasAlpha && cov > 0.97) {
                UIImage *inv = diInvertMaskImage(raw);
                double ic = inv ? diMaskCoverageOf(inv) : -1;
                if (ic > 0.03 && ic < 0.97) {
                    raw = inv; cov = ic;
                    DLog(@"遮罩素材反相: 原覆盖率 %.1f%% → %.1f%%(挖空型素材)", gDiMaskCoverage * 100.0, ic * 100.0);
                }
            }
            if (cov < 0.03 || cov > 0.97) {
                UIImage *bi = diBuiltinMaskImage();
                if (bi) { raw = bi; gDiMaskBuiltin = YES; }
                DLog(@"遮罩素材无效: %@ 覆盖率 %.1f%%(自带透明=%@ Otsu阈值=%d) "
                     @"—— 已改用内置圆形顶上。请换一张「形状外完全透明」的 PNG, "
                     @"或「纯白背景 + 纯黑形状」的图。",
                     path.lastPathComponent, cov * 100.0,
                     gDiMaskHasAlpha ? @"是" : @"否", gDiMaskThreshold);
            } else {
                DLog(@"遮罩素材: %@ 覆盖率 %.1f%% 自带透明=%@ Otsu阈值=%d 亮部为形状=%@",
                     path.lastPathComponent, cov * 100.0,
                     gDiMaskHasAlpha ? @"是" : @"否", gDiMaskThreshold,
                     gDiMaskBrightIsShape ? @"是" : @"否");
            }
            self.maskImg = raw;

            CGPoint mc = CGPointZero;
            CGFloat mr = diShapeRadiusOf(self.maskImg, &mc);
            DLog(@"遮罩形状: 半径 %.1f%% 圆心(%.2f,%.2f) 素材=%@%@", mr * 100.0, mc.x, mc.y,
                 path.lastPathComponent, gDiMaskBuiltin ? @" (内置圆形兜底)" : @"");
            DLog(@"遮罩蒙版预览(█=保留 ·=裁掉):\n%@", diMaskAscii(self.maskImg));
            /* 2.7.45: 预览图里必须**同时**有 █ 和 (空格/·), 否则这张蒙版根本裁不动。
               历史上"挂上了但没变化"全是这一条不成立, 直接报出来省得再猜。 */
            {
                double c2 = diMaskCoverageOf(self.maskImg);
                DLog(@"遮罩自检: 覆盖率 %.1f%% (实心%.0f%% 透明%.0f%%) → %@",
                     c2 * 100.0, gDiMaskOpaquePct * 100.0, gDiMaskClearPct * 100.0,
                     (c2 < 0.02 || c2 > 0.98) ? @"⚠ 整张实心/全透, 裁不出形状, 请检查素材" : @"正常(会真正裁掉背景)");
            }
        }

        /* ② 找到真封面那层 —— 按视图树定位, 不假设左右。
           2.8.16: 全树打分遍历(几十个视图 + 类名比较)是每帧最贵的一步之一,
           小岛稳定态下结果不会变, 所以按宿主尺寸缓存: 尺寸差 >2pt 才重算,
           另外每 1.5s 强制重算一次(系统重建门户时不会漏)。 */
        CGRect coverRect = CGRectZero;
        UIView *coverV = nil;
        BOOL freshScan = NO;
        CGRect prevCover = self.cacheCoverRect;
        {
            /* 2.8.17: 缓存策略收紧 —— 以前 1.5s 重扫一次, 重扫时如果正好赶上
               我们刚把某层藏掉, 候选就会漂到别处(287 的"两边闪")。
               现在: 只有"缓存的封面失效(离开视图树/宿主尺寸变了)"才重扫,
               平时一律复用; 每 4 秒才做一次校验性重扫, 且优先沿用旧结果。
               scanT 改成实例属性 —— 两个探针实例共用 static 会互相把对方
               判成 stale, 导致扫描频率翻倍。 */
            BOOL cacheSizeDiff = (fabs(bs.width - self.cacheBW) > 2.0 || fabs(bs.height - self.cacheBH) > 2.0);
            BOOL stale = (CFAbsoluteTimeGetCurrent() - self.scanT > 4.0);
            BOOL alive = (self.cacheCoverV.superview != nil && self.cacheCoverV.window != nil);
            /* 2.8.18: 尺寸还在变(过渡帧)时不重扫 —— 过渡期直接沿用缓存画,
               稳定至少 1 帧后才扫一次校准。否则展开/收缩过程中每帧跑一遍
               全树(几十个视图 + 类名比较)就是之前"一卡一卡"的元凶。 */
            BOOL settled = (self.stableFrm >= 1);
            if (!self.cacheCoverV || !alive || stale || (cacheSizeDiff && settled)) {
                self.scanT = CFAbsoluteTimeGetCurrent();
                UIView *fresh = diFindAlbumCoverView(host, &coverRect);
                if (fresh) {
                    self.cacheCoverV = (UIImageView *)fresh;
                    self.cacheCoverRect = coverRect;
                } else if (!alive) {
                    self.cacheCoverV = nil;      /* 旧的真没了才清 */
                }
                self.cacheBW = bs.width;
                self.cacheBH = bs.height;
                self.cacheSqView = nil;          /* 尺寸变了, 方块层缓存一起作废 */
                self.cacheSqRect = CGRectZero;
                freshScan = YES;
            }
            if (!coverV) coverV = self.cacheCoverV;
            if (CGRectIsEmpty(coverRect)) coverRect = self.cacheCoverRect;
        }
        /* 2.9.70: 小岛态几何守卫 —— 修"小岛专辑从别的地方先显示一下再回正常"。
           收缩(展开→小岛)的第一帧, cacheCoverRect 里存的还是展开态那一大块
           (或者展开途中 MRU 的 66 框), 按它取中心画 24pt 小圆, 圆心会落在偏右
           二三十点的地方, 稳定 1~2 帧后才重扫校正 —— 用户看到的就是"小岛专辑
           从其他地方冒出来再跳回原位"。这里只在小岛态做廉价校验:
           短边 10~56、长边 ≤56、圆心在宿主内 → 接受并记为"小岛槽位";
           否则一律沿用上次合法槽位(没有就用左槽默认 8pt 内边距、垂直居中)。
           注意: 不拦 isExpand/过渡帧, 展开态走 MRU, 不受影响。 */
        if (diIsIOS17Up() && isMini && !CGRectIsEmpty(coverRect)) {
            CGFloat mnc = MIN(coverRect.size.width, coverRect.size.height);
            CGFloat mxc = MAX(coverRect.size.width, coverRect.size.height);
            CGPoint cc0 = CGPointMake(CGRectGetMidX(coverRect), CGRectGetMidY(coverRect));
            BOOL sane = (mnc >= 10.0 && mxc <= 56.0
                         && cc0.x >= 2.0 && cc0.y >= 2.0
                         && cc0.x <= bs.width - 2.0 && cc0.y <= bs.height - 2.0);
            /* ===== 2.9.73: 过渡帧"原位不动" =====
               403 视频逐帧实锤(第一次收回, 1.57~1.73 秒): 岛在 407x197 → 189x37 之间
               缩的那几帧里, 这里会按**当前还在半大的宿主高度**重算槽位
               (h=61 时 y=(61-30)/2=15, h=97 时 y=33), 玻璃就被摆到岛的偏下方、
               边长也按 30 取 —— 用户看到的"专辑显示大的在下面, 然后才正常"。
               系统的小岛槽位是固定的(左槽 x=8、垂直居中), 收缩过程中它并不会移动;
               所以尺寸还在变的帧一律沿用上次确认过的槽位, 只有稳定 2 帧后才接受新扫描。 */
            BOOL slotSettled = (!sizeChanged && self.stableFrm >= 2);
            if (sane && slotSettled) {
                self.miniCoverRect = coverRect;
            } else if (!CGRectIsEmpty(self.miniCoverRect)) {
                coverRect = self.miniCoverRect;
                self.cacheCoverRect = coverRect;
            } else {
                CGRect keep = self.miniCoverRect;
                if (CGRectIsEmpty(keep)) {
                    CGFloat d = MIN(bs.height - 10.0, 30.0);
                    if (d < 14.0) d = 14.0;
                    keep = CGRectMake(8.0, (bs.height - d) * 0.5, d, d);
                }
                static CFAbsoluteTime sKeepT;
                if (CFAbsoluteTimeGetCurrent() - sKeepT > 3.0) {
                    sKeepT = CFAbsoluteTimeGetCurrent();
                    DLog(@"遮罩[17]: 小岛候选不合理 %@ 岛=%.0fx%.0f → 沿用槽位 %@",
                         NSStringFromCGRect(coverRect), bs.width, bs.height,
                         NSStringFromCGRect(keep));
                }
                coverRect = keep;
                self.cacheCoverRect = keep;
            }
        }
        /* 2.9.63: 小岛态封面候选漂移守卫 —— 用户报"小岛暂停了会变大偏移"。
           小岛稳定后封面门户位置是固定的(左槽 26x22@8,7); 暂停/系统重建会触发
           重扫, 一旦挑到别的层(尺寸 >34pt 或中心挪了 >10pt), 玻璃就会画大/画偏。
           宿主尺寸没变时一律沿用旧位, 连续 3 次重扫仍漂移才接受新位
           (真换位置不会一直被拒, 假漂移最多错 12 秒)。 */
        if (freshScan && coverV && !CGRectIsEmpty(prevCover) && !CGRectIsEmpty(coverRect)
            && diIsIOS17Up() && isMini
            && fabs(bs.width - self.cacheBW) <= 2.0 && fabs(bs.height - self.cacheBH) <= 2.0) {
            CGPoint nc = CGPointMake(coverRect.origin.x + coverRect.size.width * 0.5,
                                     coverRect.origin.y + coverRect.size.height * 0.5);
            CGPoint oc = CGPointMake(prevCover.origin.x + prevCover.size.width * 0.5,
                                     prevCover.origin.y + prevCover.size.height * 0.5);
            BOOL bigger = (coverRect.size.width > 34.0 || coverRect.size.height > 34.0);
            BOOL moved = (fabs(nc.x - oc.x) > 10.0 || fabs(nc.y - oc.y) > 10.0);
            static int sDriftHits; static CFAbsoluteTime sDriftT;
            if (bigger || moved) {
                sDriftHits++;
                if (sDriftHits < 3) {
                    CGRect driftNew = coverRect;
                    coverRect = prevCover;
                    self.cacheCoverRect = prevCover;
                    if (CFAbsoluteTimeGetCurrent() - sDriftT > 5.0) {
                        sDriftT = CFAbsoluteTimeGetCurrent();
                        DLog(@"遮罩[17]: 小岛封面候选漂移 新%@ 旧%@ → 沿用旧位(连续%d次)",
                             NSStringFromCGRect(driftNew), NSStringFromCGRect(prevCover), sDriftHits);
                    }
                }
            } else {
                sDriftHits = 0;
            }
        }
        /* 2.8.18: 换封面视图**不再**整体 teardown。
           288 日志 16:01:21→16:01:22 就是活证据: 同一首歌唱着, 封面从
           `_SAUIProvidedViewContainerView 26x22` 切到 `UIImageView 36x36`(系统
           在小岛内部换了画专辑的那一层), 旧代码每次切换都拆玻璃 + 还原系统专辑,
           下一帧再盖回来 —— 用户看到的就是"先显示方的, 然后才显示遮罩"。
           现在只更新记录值, 玻璃原地重画(藏层由 diHideViewsNear 统一重算)。 */
        _coverV = coverV;
        if (!coverV) {
            /* 2.8.13: 玻璃模式下给几帧宽限 —— 展开/收起动画中途门户会重建,
               一找不到就还原系统封面会闪一下。10 帧内回来就保持现状。 */
            if (_glassOn && ++_glassMiss < 10) return;
            [self diTeardown];
            /* 2.7.45: 这里以前是静默返回 —— 用户日志里只看到"参与(展开=1)"却永远等不到
               "遮罩挂上", 完全无法判断卡在哪一步。补一条节流日志。 */
            static CFAbsoluteTime sNoT; static CGFloat sNoW, sNoH;
            if (CFAbsoluteTimeGetCurrent() - sNoT > 3.0 || fabs(bs.width - sNoW) > 12 || fabs(bs.height - sNoH) > 12) {
                sNoT = CFAbsoluteTimeGetCurrent(); sNoW = bs.width; sNoH = bs.height;
                DLog(@"遮罩未挂: 宿主 %.0fx%.0f 里没找到专辑封面(候选见上一条 遮罩候选)", bs.width, bs.height);
            }
            return;
        }
        _glassMiss = 0;

        /* 2.8.16: 稳定态零工作 —— 玻璃已经在、这一帧没重新扫描(尺寸没变),
           就什么都不用做直接返回: 旋转交给 CA 动画在渲染服务器上跑,
           探针这一帧唯一的工作本来是"确认没事", 30fps 下纯属浪费。
           每 1.2 秒放行一次做自愈(系统重建专辑层/顺序被顶掉时补上)。
           2.8.18: 尺寸变了必须放行 —— 玻璃要跟着新尺寸重画, 否则停在旧位置
           会露出系统专辑的边角(方块状), 视觉上就是"先方后遮罩"。
           2.8.20 功耗: 稳定态把探针降到 8fps(290 截图 SpringBoard CPU 92%)。
           玻璃已画好、旋转在渲染服务器上跑, 这边只剩"确认没事",
           8fps 完全够用(响应 125ms); 一旦尺寸/内容有变立即回 30fps。 */
        if (self.glassOn && !freshScan && !sizeChanged
            && CFAbsoluteTimeGetCurrent() - self.paintT < 1.2) {
            if (_link.preferredFramesPerSecond != 8) _link.preferredFramesPerSecond = 8;
            return;
        }
        if (_link.preferredFramesPerSecond != 30) _link.preferredFramesPerSecond = 30;

        CGSize cs = coverV.bounds.size;
        /* 2.8.18: 刚换上的封面视图还没布局(bounds 为 0)时不要拆玻璃 ——
           拆了就要还原系统专辑, 下一帧再盖回来, 又是一次"方形闪"。等下一帧即可。 */
        if (cs.width < 6 || cs.height < 6) return;

        /* ③ 2.7.43: 先推进旋转角度, 再挂蒙版 —— 上一版顺序反了,
           diApplyMaskToCover 用的永远是上一帧(首次则 0)角度, 表现就是"打开旋转没反应"。
           2.7.45: 时间基准改成**进程级静态**, 不再用实例的 _lastTS ——
           两个探针实例各推进一次, 后一个拿到 dt=0, 角度增速只有一半, 而且交替推进
           会让角度一顿一顿的。现在统一由 diAdvanceMaskRotation 推进, 谁先调到谁推,
           0.5ms 内重复调用直接返回。 */
        if (maskRotateOn && fabs(maskRotateSpeed) > 0.01) {
            diAdvanceMaskRotation(_link.timestamp);
        } else if (gMaskRotDeg != 0) {
            gMaskRotDeg = 0;
            gRotTS = 0;
        }

        /* ③-a 2.8.13: 专辑图(MediaRemote 共享份)。
           自绘玻璃是**唯一**显示路径(2.8.14 起): 系统那张专辑在两种形态下都搞不定 ——
             · 小岛态: 门户是 26x22 非方形, 本地 mask 只能裁出中间 22pt(用户报"关闭旋转专辑小");
             · 展开态: 专辑画在 App 自己的远程门户里, 本地 mask 完全无效
               (用户报"展开岛还是方形, 没有遮罩也不会旋转")。
           玻璃把「专辑图 + 遮罩形状」放进同一个我们自己的视图: 尺寸取 MAX(宽,高) 的
           正方形(圆永远是圆的), 小岛/展开/旋转开关切来切去都是同一条路、同一个大小,
           不会再出现"重开旋转才正常圆形"。旋转开关只决定加不加旋转 transform。
           只有拿不到专辑图(MediaRemote 无 artworkData)才退回系统 mask 老路兜底。 */
        diFetchSharedArt(genChanged);
        BOOL wantGlass = (gSharedArt != nil);
        if (!gSharedArt) {
            if (!_loggedNoArtTip) {
                _loggedNoArtTip = YES;
                DLog(@"遮罩玻璃: 暂未拿到专辑图(MediaRemote 无 artworkData), 先走系统蒙版");
            }
        } else {
            _loggedNoArtTip = NO;
        }

        /* 2.9.72: 展开/收起变形段拿不到新图时, 保持上一帧的玻璃就好, 绝不退回
           "系统蒙版" —— 那会在半大的岛上裁出一块模糊背景(331 的心形光斑)。 */
        if (morphExpand && !wantGlass) return;
        if (wantGlass) {
            /* 摘掉可能还挂在系统层上的旧蒙版, 玻璃全权接管 */
            if (_targets.count) {
                for (UIView *t in _targets.allObjects) diStripMaskFromCover(t);
                [_targets removeAllObjects];
            }
            /* 2.8.16: 离屏镜像宿主必须拒绝 —— 286 日志铁证同一时刻有两个实例在挂:
               一个封面 @(8,15) 在岛内, 另一个封面 @(187,18) 落在 185 宽的宿主**外面**
               (系统给锁屏/通知中心各准备了一份 185x52 的镜像岛)。镜像那份画上去
               用户看不到, 却照样参与"藏层 + 每帧重排", 既多一个遮罩又拖慢过渡。
               判据: 封面中心必须落在宿主 bounds 内(6pt 容差)。 */
            {
                CGPoint cc = CGPointMake(coverRect.origin.x + coverRect.size.width * 0.5,
                                         coverRect.origin.y + coverRect.size.height * 0.5);
                if (cc.x < -6 || cc.y < -6 || cc.x > bs.width + 6 || cc.y > bs.height + 6) {
                    static CFAbsoluteTime sMirT;
                    if (CFAbsoluteTimeGetCurrent() - sMirT > 4.0) {
                        sMirT = CFAbsoluteTimeGetCurrent();
                        DLog(@"遮罩跳过: 封面中心(%.0f,%.0f) 在宿主 %.0fx%.0f 之外, 判为镜像岛不遮",
                             cc.x, cc.y, bs.width, bs.height);
                    }
                    [self diTeardown];
                    return;
                }
            }
            /* 2.8.15: 找封面旁边的"系统专辑方块层" —— 它才是真正画专辑的那层,
               比门户容器大(展开态 36x36 vs 门户 26x22)。
               玻璃取"门户 ∪ 方块"的并集再放大成正方形: 展开态实测两者不同心
               (330x72 日志: 门户 26x22@(8,16) vs 方块 33.6x33.6@(15.6,26.4),
               中心差 11x16pt), 只按大的画会漏出另一块的边角 —— 那就是用户看到
               的"展开岛还是方的 + 多了一个显示"。并集一次盖全;
               藏层由 diHideViewsNear 统一做, 这里只取尺寸/位置。
               2.8.16: 同样走尺寸缓存, 尺寸没变就不重算(全树遍历很贵)。 */
            CGRect sqRect = self.cacheSqRect;
            UIView *sqView = self.cacheSqView;
            if (freshScan || !sqView) {
                sqRect = CGRectZero;
                sqView = diFindAlbumSquareNear(host, coverRect, &sqRect);
                self.cacheSqRect = sqRect;
                self.cacheSqView = sqView;
            }
            CGRect glassRect = coverRect;
            if (!CGRectIsEmpty(sqRect)) glassRect = CGRectUnion(glassRect, sqRect);
            /* ===== 2.9.41: 17 小岛态把玻璃夹进宿主 =====
               17 上报的封面视图常常是 66pt(跨进程 scene 的尺寸), 直接按它画玻璃会
               在小岛上铺一大块、被岛体裁掉一角 —— 就是截图二里那块粉红模糊斑。
               小岛态强制: 边长 ≤ 岛高(留 5%), 且整块必须落在宿主内。 */
            if (diIsIOS17Up() && isMini) {
                CGFloat maxSide = MIN(bs.width, bs.height) * 0.95;
                if (glassRect.size.width > maxSide || glassRect.size.height > maxSide) {
                    CGFloat side = MIN(MAX(glassRect.size.width, glassRect.size.height), maxSide);
                    CGPoint gc = CGPointMake(CGRectGetMidX(glassRect), CGRectGetMidY(glassRect));
                    glassRect = CGRectMake(gc.x - side * 0.5, gc.y - side * 0.5, side, side);
                    static CFAbsoluteTime sClampT;
                    if (CFAbsoluteTimeGetCurrent() - sClampT > 3.0) {
                        sClampT = CFAbsoluteTimeGetCurrent();
                        DLog(@"遮罩[17]: 玻璃夹紧 %.0fx%.0f → %.0fx%.0f 岛=%.0fx%.0f",
                             coverRect.size.width, coverRect.size.height,
                             glassRect.size.width, glassRect.size.height, bs.width, bs.height);
                    }
                }
                CGFloat minX = 2.0, maxX = bs.width - glassRect.size.width - 2.0;
                CGFloat minY = 2.0, maxY = bs.height - glassRect.size.height - 2.0;
                if (maxX >= minX) glassRect.origin.x = MIN(MAX(glassRect.origin.x, minX), maxX);
                if (maxY >= minY) glassRect.origin.y = MIN(MAX(glassRect.origin.y, minY), maxY);
            }
            /* ===== 2.9.72: 展开变形段按宿主宽度长大 =====
               两端都是实测值: 小岛 25.3pt(26x22 门户按 115% 取正方形) /
               展开 66pt(MRU 展开态那颗 66 头像)。中间按宿主宽度 208→400 线性插值,
               左上角锚定不变(小岛槽位 (8,7) 与展开封面左上角是同一个点)。
               这样展开全程只有一颗圆, 直径 25 → 66 连续变化, 不再"小的跳成大的"。 */
            if (morphExpand) {
                CGFloat prog = (bs.width - 208.0) / (400.0 - 208.0);
                prog = MIN(MAX(prog, 0.0), 1.0);
                CGFloat mside = 25.3 + (66.0 - 25.3) * prog;
                /* 垂直锚点: 小岛槽位 y=7, 展开封面 y≈7~13 —— 都贴岛顶。
                   槽位回退分支会把 y 算成"垂直居中"((h-d)/2), 宿主一变高就跑到
                   中间去, 这里夹到顶部。 */
                CGFloat my = MIN(glassRect.origin.y, 14.0);
                glassRect = CGRectMake(glassRect.origin.x, my, mside, mside);
            }
            [self diPaintGlassAt:glassRect over:coverV art:gSharedArt];
            /* 2.8.15: 系统布局会周期性把岛内容分支 bringSubviewToFront(动画层对抗旧行为),
               玻璃一旦被压到系统专辑下面就成了"遮罩没生效"。
               2.8.16: 改成每 0.5s 最多重申一次 —— 每帧改 subview 顺序会触发系统岛容器
               整棵重排, 是"一卡一卡"的主要来源, 而实际被压住的概率极低。 */
            {
                static CFAbsoluteTime sZTime; static __weak UIView *sZHost;
                if (sZHost != host || CFAbsoluteTimeGetCurrent() - sZTime > 0.5) {
                    sZHost = host; sZTime = CFAbsoluteTimeGetCurrent();
                    /* 2.8.21: 「左侧专辑」帧率素材(side=0)已经在玻璃上面时不抢最顶 ——
                       玻璃是不透明的专辑画, 顶上去就把素材盖住了(见 updateSingleVideo
                       里的 insertSubview:belowSubview:miniAnim, 两边保持一致)。 */
                    BOOL yield = NO;
                    if (miniAnimOn) {
                        for (UIView *sv in host.subviews) {
                            if (sv == self) break;                 /* 只看我上面的视图 */
                            if ([sv isKindOfClass:DIAnimView.class]
                                && ((DIAnimView *)sv).side == 0) { yield = YES; break; }
                        }
                    }
                    if (!yield) [host bringSubviewToFront:self];
                }
            }
            _coverV = coverV;
            _glassOn = YES;
            /* 2.9.68: 告诉 MRU"小岛这块我画着, 你别插手"; 2.9.69: 立即送达 */
            if (!gDISBGlassOn) { gDISBGlassOn = 1; diWriteIslandPlist(); }
            if (!self.loggedShow) {
                self.loggedShow = YES;
                DLog(@"遮罩挂上(玻璃): 封面=%@ %.0fx%.0f@(%.0f,%.0f) 方块=%@ %.0fx%.0f 岛=%.0fx%.0f 素材=%@ 旋转=%@(%.0f°/s 角度%.0f°)",
                     NSStringFromClass(coverV.class), cs.width, cs.height,
                     coverRect.origin.x, coverRect.origin.y,
                     sqView ? NSStringFromClass(sqView.class) : @"无", sqRect.size.width, sqRect.size.height,
                     bs.width, bs.height,
                     path.lastPathComponent,
                     maskRotateOn ? @"开" : @"关", maskRotateSpeed, gMaskRotDeg);
            }
            return;
        }

        /* ===== 2.9.41: 17 上不再走"系统层 mask 兜底" =====
           MediaRemote 取图失败的瞬间, 老路会把封面父容器(展开态是那块模糊背景)
           按遮罩形状裁出来 —— 用户截图一(展开)和截图二(小岛)里那块粉红模糊斑
           就是它。17 上宁可这一帧不画, 也不挂任何系统蒙版。 */
        if (diIsIOS17Up()) {
            if (_glassOn || _targets.count) [self diTeardown];
            static CFAbsoluteTime sNoArtT;
            if (CFAbsoluteTimeGetCurrent() - sNoArtT > 3.0) {
                sNoArtT = CFAbsoluteTimeGetCurrent();
                DLog(@"遮罩[17]: 未拿到专辑图, 不走系统蒙版兜底(让位) 宿主=%d 小岛=%d",
                     (int)diIslandStateMini(), (int)isMini);
            }
            return;
        }

        /* 没拿到专辑图: 退出玻璃模式 —— 还原系统封面, 回到系统层 mask 兜底 */
        if (_glassOn) {
            [self diRestorePainted];
            self.hidden = YES;
            self.transform = CGAffineTransformIdentity;
            _glassOn = NO;
            gDISBGlassOn = 0;          /* 2.9.68: 没图让位 → MRU 接手 */
            diWriteIslandPlist();
            self.loggedShow = NO;      /* 让下面重新打一条系统 mask 的挂上日志 */
        }

        /* ④ 挂蒙版 —— 父容器 + CA 包自己都挂, 见 diMaskTargetsFor 的说明。
           封面尺寸会跟着岛缩放, 所以这里每次都同步一次(纯赋值, 无副作用)。

           2.7.45 —— "只显示一个遮罩"的真正原因就在这里:
           小岛态和展开态是两个 DIMaskView 实例, 但它们抓到的 coverV 可能是**同一个视图**
           (展开动画中间态时, 宿主视图还没换, 只是 bounds 变了)。于是:
             实例A 每帧挂 mask → 实例B 每帧发现 mask 不是自己创建的就 diTeardown 摘掉
             → 再挂 → 再摘 …… 两个实例互抢, 谁先谁后取决于 displayLink 回调顺序,
           表现就是"遮罩时有时无 / 只有一个"。
           修法: 目标层上记住"归属实例", 谁先挂上谁拥有; 另一个实例看到归属不是自己就
           直接放弃这块(不摘!), 等原生视图换掉归属自然失效。 */
        NSArray<UIView *> *tg = diMaskTargetsFor(coverV);
        BOOL any = NO, blocked = NO;
        for (UIView *t in tg) {
            DIMaskView *owner = objc_getAssociatedObject(t.layer, &kMaskOwnerKey);
            if (owner && owner != self && [owner diLiveTargetCount] > 0) { blocked = YES; continue; }
            if (diApplyMaskToCover(t, self.maskImg)) {
                any = YES;
                objc_setAssociatedObject(t.layer, &kMaskOwnerKey, self, OBJC_ASSOCIATION_ASSIGN);
                [_targets addObject:t];
            }
        }
        if (!any) {
            if (blocked) {
                /* 这块专辑已经被另一个探针接管 —— 正常现象(小岛/展开共用), 不要打日志刷屏 */
                return;
            }
            [self diTeardown]; return;
        }
        _coverV = coverV;

        /* ③-b 2.8.14: 能走到这里说明没拿到专辑图, 上面已退出玻璃;
           系统层 mask 只是兜底(小岛态有效, 展开态远程门户无效)。 */

        /* ③-c 回读验证: 挂完立刻读回来, 一眼看出蒙版在不在、系统有没有把它清掉 */
        if (!_loggedPaint) {
            _loggedPaint = YES;
            NSMutableString *rd = [NSMutableString string];
            [rd appendFormat:@"接管系统层=只挂mask(2.8.14 无专辑图兜底)"];
            for (UIView *t in _targets.allObjects) {
                CALayer *tm = t.layer.mask;
                [rd appendFormat:@" | 系统层 %@ 掩码=%@", NSStringFromClass(t.class),
                    tm ? (tm.name.length ? tm.name : @"有(无名)") : @"无(被清掉)"];
            }
            DLog(@"遮罩回读: %@", rd);
        }

        /* ④ 旋转已在上面(挂蒙版之前)统一推进, 这里不再重复 */

        if (!self.loggedShow) {
            self.loggedShow = YES;
            NSMutableString *tn = [NSMutableString string];
            for (UIView *t in _targets.allObjects)
                [tn appendFormat:@"%@(%.0fx%.0f) ", NSStringFromClass(t.class),
                                 t.bounds.size.width, t.bounds.size.height];
            DLog(@"遮罩挂上: 封面=%@ %.0fx%.0f@(%.0f,%.0f) 岛=%.0fx%.0f 目标层=[%@] 素材=%@ 旋转=%@(%.0f°/s 角度%.0f°)",
                 NSStringFromClass(coverV.class), cs.width, cs.height,
                 coverRect.origin.x, coverRect.origin.y, bs.width, bs.height,
                 tn, path.lastPathComponent,
                 maskRotateOn ? @"开" : @"关", maskRotateSpeed, gMaskRotDeg);
        }
    } @catch (NSException *e) { DLog(@"遮罩 step 异常(已忽略): %@", e); }
}
@end

/* 素材 → 蒙版形状图。
   maskView 只读 alpha, 所以这里只需要决定"哪些像素在该透/该实"。

   三种素材都能处理, 判定顺序:
     ① png 自带透明(≥3% 像素 alpha<200)  → 用户已经抠好形状, 直接用
     ② 不透明图, 中间亮四周暗 / 中间暗四周亮 → 取"和四角不一样的那一块"当形状,
        也就是图里那个圆/圆环 —— 这类就是用户说的"遮罩是圆的"
     ③ 兜底: 整张图当形状(满屏不透明)
   注意: 输出的图**不做任何缩放**, 尺寸统一由 maskView 的 ScaleToFill 处理,
        所以 200x200 和 1100x1100 的素材最终结果完全一致。 */
/* ===== 2.7.27: 蒙版自检 =====

   255 号日志是铁证:
       遮罩转换: Mask.png 1100x1100 → 蒙版 成功
       遮罩形状: 半径 56.4% 圆心(0.50,0.50)
       遮罩挂上: 封面=BSUICAPackageView 37x37@(123,-0) 目标层=[... 两层 ...]
   三行都说成功, 画面却毫无变化。把 56.4% 反推回去:
       半径 = sqrt(不透明像素数 / π) / 短边 = 0.564
     → 不透明像素数 ≈ 0.564² × π × 短边² ≈ 整张图
   **蒙版整张都是不透明的** —— 一个像素都没裁掉, 所以"挂上了但没效果"。
   根因不在 CALayer.mask(那玩意儿是系统自己抠圆角用的, 必然生效),
   在**素材 → 蒙版这一步把图判成了实心**。

   本版三件事:
     ① 不透明素材改用 Otsu 自动阈值, 不再拿"四角亮度"当背景猜;
     ② 生成完立刻自检覆盖率, 并把蒙版打成 20x20 的 ASCII 写进日志,
        一眼看出素材到底是圆 / 星 / 还是一整块实心板;
     ③ 覆盖率 >97%(全实, 裁不掉) 或 <3%(全透, 专辑会消失) 判素材无效,
        自动改用内置的圆形蒙版顶上, 保证开关一开一定看得见变化。 */
/* Otsu 大津法: 在亮度直方图里找使类间方差最大的阈值, 0~255 */
static unsigned char diOtsuThreshold(const unsigned char *lum, size_t n) {
    if (!lum || n < 64) return 128;
    unsigned int hist[256] = {0};
    for (size_t i = 0; i < n; i++) hist[lum[i]]++;
    double total = (double)n, sumAll = 0;
    for (int i = 0; i < 256; i++) sumAll += (double)i * (double)hist[i];
    double sumB = 0, wB = 0, best = -1.0;
    int thr = 128;
    for (int t = 0; t < 256; t++) {
        wB += (double)hist[t];
        if (wB <= 0) continue;
        double wF = total - wB;
        if (wF <= 0) break;
        sumB += (double)t * (double)hist[t];
        double mB = sumB / wB, mF = (sumAll - sumB) / wF;
        double between = wB * wF * (mB - mF) * (mB - mF);
        if (between > best) { best = between; thr = t; }
    }
    return (unsigned char)thr;
}

/* 把蒙版打成 ASCII 图写进日志 —— 排查"素材到底是什么形状"的最快办法 */
static NSString *diMaskAscii(UIImage *m) {
    if (!m || !m.CGImage) return @"(无蒙版)";
    /* 2.7.46: alpha-only 蒙版直接按 alpha 打点阵, 与真实裁切结果一致 */
    {
        CGImageRef c0 = m.CGImage;
        if (CGImageGetBitsPerComponent(c0) == 8 && CGImageGetBitsPerPixel(c0) == 8) {
            CFDataRef dr = CGDataProviderCopyData(CGImageGetDataProvider(c0));
            if (dr) {
                const UInt8 *b = CFDataGetBytePtr(dr);
                size_t stride = CGImageGetBytesPerRow(c0);
                size_t W0 = CGImageGetWidth(c0), H0 = CGImageGetHeight(c0);
                if (b && W0 > 0 && H0 > 0) {
                    const size_t N2 = 20;
                    NSMutableString *s2 = [NSMutableString string];
                    for (size_t yy = 0; yy < N2; yy++) {
                        for (size_t xx = 0; xx < N2; xx++) {
                            size_t px2 = xx * W0 / N2, py2 = yy * H0 / N2;
                            unsigned char a = b[py2 * stride + px2];
                            [s2 appendString:(a >= 200 ? @"█" : (a >= 90 ? @"▒" : (a >= 25 ? @"·" : @" ")))];
                        }
                        [s2 appendString:@"\n"];
                    }
                    CFRelease(dr);
                    return s2;
                }
                CFRelease(dr);
            }
        }
    }
    size_t N = 20, bpr = N * 4;
    NSMutableData *buf = [NSMutableData dataWithLength:bpr * N];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf.mutableBytes, N, N, 8, bpr, cs,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!c) return @"(画不出)";
    CGContextSetBlendMode(c, kCGBlendModeCopy);
    CGContextDrawImage(c, CGRectMake(0, 0, N, N), m.CGImage);
    CGContextRelease(c);
    unsigned char *p = (unsigned char *)buf.mutableBytes;
    NSMutableString *s = [NSMutableString string];
    for (size_t y = 0; y < N; y++) {
        NSMutableString *row = [NSMutableString string];
        for (size_t x = 0; x < N; x++) {
            unsigned char a = p[(y * N + x) * 4 + 3];
            [row appendString:(a >= 200 ? @"█" : (a >= 90 ? @"▒" : (a >= 25 ? @"·" : @" ")))];
        }
        [s appendFormat:@"%@\n", row];
    }
    return s;
}

/* 内置兜底形状: 一个内切圆。素材无效时顶上, 保证"开关一开就有变化"。 */
static UIImage *diBuiltinMaskImage(void) {
    static UIImage *im = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        size_t S = 256, bpr = S * 4;
        NSMutableData *buf = [NSMutableData dataWithLength:bpr * S];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef c = CGBitmapContextCreate(buf.mutableBytes, S, S, 8, bpr, cs,
                                               kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs);
        if (!c) return;
        CGContextSetFillColorWithColor(c, [UIColor whiteColor].CGColor);
        CGContextFillEllipseInRect(c, CGRectMake(3, 3, S - 6, S - 6));
        CGImageRef ocg = CGBitmapContextCreateImage(c);
        CGContextRelease(c);
        if (ocg) { im = [UIImage imageWithCGImage:ocg]; CGImageRelease(ocg); }
    });
    return im;
}

/* 算一张蒙版的不透明覆盖率(0~1) */
static double diMaskCoverageOf(UIImage *m) {
    if (!m || !m.CGImage) return -1;
    /* 2.7.46: 我们的蒙版是 8 位 alpha-only, 直接读像素, 不需要再走一次绘制 */
    CGImageRef cg0 = m.CGImage;
    if (CGImageGetBitsPerComponent(cg0) == 8 && CGImageGetBitsPerPixel(cg0) == 8) {
        CFDataRef dref = CGDataProviderCopyData(CGImageGetDataProvider(cg0));
        if (dref) {
            const UInt8 *b = CFDataGetBytePtr(dref);
            size_t n = CFDataGetLength(dref);
            size_t stride = CGImageGetBytesPerRow(cg0);
            size_t W0 = CGImageGetWidth(cg0), H0 = CGImageGetHeight(cg0);
            if (b && n >= stride * H0 && W0 > 0) {
                NSInteger on = 0, tot = 0;
                size_t sx = MAX((size_t)1, W0 / 128), sy = MAX((size_t)1, H0 / 128);
                for (size_t y = 0; y < H0; y += sy) {
                    const UInt8 *row = b + y * stride;
                    for (size_t x = 0; x < W0; x += sx) { if (row[x] >= 128) on++; tot++; }
                }
                CFRelease(dref);
                if (tot > 0) return (double)on / (double)tot;
            }
            if (dref) CFRelease(dref);
        }
    }
    size_t N = 128, bpr = N * 4;
    NSMutableData *buf = [NSMutableData dataWithLength:bpr * N];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf.mutableBytes, N, N, 8, bpr, cs,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!c) return -1;
    CGContextSetBlendMode(c, kCGBlendModeCopy);
    CGContextDrawImage(c, CGRectMake(0, 0, N, N), m.CGImage);
    CGContextRelease(c);
    unsigned char *p = (unsigned char *)buf.mutableBytes;
    NSInteger n = 0;
    for (size_t i = 0; i < N * N; i++) if (p[i * 4 + 3] >= 128) n++;
    return (double)n / (double)(N * N);
}

/* 反相: 挖空型素材(形状是透明的洞, 四周实心)反过来才对 */
/* 2.7.47: 反相也回到预乘 RGBA 上下文 —— CG 会自动处理预乘, 手工只翻 alpha,
   然后把 RGB 统一写成新 alpha 值(白形状的预乘正确写法) */
static UIImage *diInvertMaskImage(UIImage *m) {
    if (!m || !m.CGImage) return nil;
    size_t w = 256, h = 256, bpr = w * 4;
    NSMutableData *buf = [NSMutableData dataWithLength:bpr * h];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf.mutableBytes, w, h, 8, bpr, cs,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!c) return nil;
    CGContextSetBlendMode(c, kCGBlendModeCopy);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), m.CGImage);
    unsigned char *p = (unsigned char *)buf.mutableBytes;
    for (size_t i = 0; i < w * h; i++) {
        unsigned char a = (unsigned char)(255 - p[i * 4 + 3]);
        p[i * 4 + 3] = a;
        p[i * 4] = p[i * 4 + 1] = p[i * 4 + 2] = a;   /* 预乘: RGB = alpha */
    }
    CGImageRef ocg = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    if (!ocg) return nil;
    UIImage *r = [UIImage imageWithCGImage:ocg];
    CGImageRelease(ocg);
    return r;
}

static UIImage *diShapeFromLuma(UIImage *src) {
    if (!src) return nil;
    @autoreleasepool {
        CGImageRef cg = src.CGImage;
        if (!cg) return nil;
        size_t W = CGImageGetWidth(cg), H = CGImageGetHeight(cg);
        if (W < 4 || H < 4 || W > 6000 || H > 6000) return nil;

        /* 降采样到 256 做分析(够判形状, 快) */
        size_t w = 256, h = 256, bpr = w * 4;
        NSMutableData *buf = [NSMutableData dataWithLength:bpr * h];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(buf.mutableBytes, w, h, 8, bpr, cs,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        if (!ctx) { CGColorSpaceRelease(cs); return nil; }
        CGContextSetBlendMode(ctx, kCGBlendModeCopy);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);

        unsigned char *px = (unsigned char *)buf.mutableBytes;
        size_t total = w * h;

        /* ① 自带透明 */
        NSInteger transparent = 0;
        for (size_t i = 0; i < total; i += 4) if (px[i + 3] < 200) transparent++;
        BOOL hasAlpha = (transparent * 100 > (NSInteger)total * 3);

        /* 2.7.27: 不透明图改用 Otsu 自动阈值, 不再拿"四角亮度"当背景。
           四角法在素材四角恰好落在形状里 / 素材是渐变或照片时会彻底判反,
           255 号日志那张 Mask.png 就是这样被判成"整张都是形状"的。 */
        unsigned char *lumBuf = (unsigned char *)malloc(total);
        if (!lumBuf) return nil;
        for (size_t i = 0; i < total; i++) {
            unsigned char *q = px + i * 4;
            unsigned char a = q[3];
            unsigned int r = q[0], g = q[1], b = q[2];
            if (a > 0 && a < 255) {
                r = MIN(255u, r * 255u / a);
                g = MIN(255u, g * 255u / a);
                b = MIN(255u, b * 255u / a);
            }
            lumBuf[i] = (unsigned char)(0.299 * r + 0.587 * g + 0.114 * b + 0.5);
        }

        /* 两种极性各算一次覆盖率, 取更"像一个形状"的那张:
             · 亮底暗形(白底黑圆) → 暗的那块是形状
             · 暗底亮形(黑底白圆) → 亮的那块是形状
           形状覆盖率通常在 20%~70%, 所以挑离 0.35 最近的那一侧。 */
        unsigned char thr = hasAlpha ? 128 : diOtsuThreshold(lumBuf, total);
        NSInteger cntBright = 0, cntAlpha = 0;
        for (size_t i = 0; i < total; i++) {
            if (lumBuf[i] > thr) cntBright++;
            if (px[i * 4 + 3] >= 128) cntAlpha++;
        }
        double covBright = (double)cntBright / (double)total;
        double covAlpha = (double)cntAlpha / (double)total;
        BOOL brightIsShape;
        if (hasAlpha) {
            brightIsShape = (lumBuf[0] > thr);   /* 有 alpha 时极性只影响日志, 实际用 alpha */
        } else {
            brightIsShape = (fabs(covBright - 0.35) <= fabs((1.0 - covBright) - 0.35));
        }

        /* 生成输出: 形状处 alpha=255(实), 背景处 alpha=0(透) */
        NSInteger solid = 0;
        for (size_t i = 0; i < total; i++) {
            unsigned char *q = px + i * 4;
            unsigned char outA;
            if (hasAlpha) {
                outA = q[3];                               /* ① 原 alpha */
            } else {
                unsigned int d = (unsigned int)labs((int)lumBuf[i] - (int)thr);
                BOOL isShape = brightIsShape ? (lumBuf[i] > thr) : (lumBuf[i] <= thr);
                if (!isShape) outA = 0;
                else if (d >= 20) outA = 255;
                else outA = (unsigned char)(d * 255 / 20);
            }
            if (outA >= 128) solid++;
            /* 2.7.47: 预乘格式的正确写法 —— RGB = alpha × 白 = alpha。
               绝不能写 255(会被 clamp) 也不能保留源像素(预乘后可能 > alpha)。 */
            q[0] = q[1] = q[2] = outA;
            q[3] = outA;
        }
        free(lumBuf);

        gDiMaskCoverage = hasAlpha ? covAlpha : ((double)solid / (double)total);
        gDiMaskHasAlpha = hasAlpha;
        gDiMaskThreshold = thr;
        gDiMaskBrightIsShape = brightIsShape;

        /* ===== 2.7.47: 输出用**预乘 RGBA** + RGB=alpha =====

           历史铁证:
             · 2.7.42~44 输出预乘图 → 用户**看到过形状**(贴上了), 说明这条格式 CA 认;
             · 2.7.45 换成非预乘上下文 → CGBitmapContextCreate 返回 NULL → 遮罩整个没了;
             · 2.7.46 换成 alpha-only 单通道图 → 生成成功、mask 也挂上了, 但 CA 对
               alpha-only contents 不做裁剪(276 日志: 回读 掩码=DriftIslandAlbumMask,
               画面毫无变化) → 还是没有遮罩。
           所以回到"确实显示过形状"的预乘格式, 像素按预乘的正确写法填:
           RGB = alpha × 白 = alpha 本身。分析照旧, 输出不再换格式。 */
        CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
        CGContextRef o = CGBitmapContextCreate(px, w, h, 8, bpr, cs2,
                                               kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs2);
        CGImageRef ocg = o ? CGBitmapContextCreateImage(o) : NULL;
        if (o) CGContextRelease(o);
        if (!ocg) return nil;
        UIImage *res = [UIImage imageWithCGImage:ocg scale:1.0 orientation:src.imageOrientation];
        CGImageRelease(ocg);
        return res;
    }
}

/* 把一张 png 读成用于蒙版的 alpha 图:
   · png 本身带透明 → 直接用它做形状(用户自己抠的形状)
   · png 不透明 → 素材里"暗的像素"当成形状本体, "亮的像素"挖掉。
     (常见的是黑底白圆 / 白底黑圆, 两种都能正确出圆, 见 diShapeFromLuma) */
static UIImage *diMaskAlphaCached(NSString *path) {
    static NSString *cKey = nil;      /* 2.7.43: 路径+mtime+大小 组合指纹 */
    static UIImage *cImg = nil;
    static NSLock *cLock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cLock = [NSLock new]; });
    [cLock lock];
    UIImage *res = nil;
    @try {
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        NSDate *md = at[NSFileModificationDate];
        unsigned long long sz = [at[NSFileSize] unsignedLongLongValue];
        double stamp = md ? md.timeIntervalSince1970 : 0;
        /* 2.7.43: 只用 mtime 不够 —— 同名文件快速覆盖时秒级 mtime 可能相同,
           用户看到的就是"换素材还是原来那张"。这里把 大小 也并进指纹。 */
        NSString *key = [NSString stringWithFormat:@"%@|%.3f|%llu", path, stamp, sz];
        if (cImg && [cKey isEqualToString:key]) {
            res = cImg;
        } else {
            UIImage *raw = [UIImage imageWithContentsOfFile:path];
            res = diShapeFromLuma(raw);
            cImg = res; cKey = [key copy];
            DLog(@"遮罩转换: %@ %dx%d (%.0f字节) → 蒙版 %@", path.lastPathComponent,
                 (int)raw.size.width, (int)raw.size.height, (double)sz, res ? @"成功" : @"失败");
        }
    } @catch (__unused NSException *e) { res = nil; }
    [cLock unlock];
    return res;
}

/* 当前选中的素材, 没有就 nil —— 绝不兜底 */
static NSString *diMaskCurrentPathV2(void) {
    NSArray<NSString *> *list = diMaskListAssets();
    if (!list.count) return nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("diAlbumMaskAsset"), (__bridge CFStringRef)kDomain));
    NSString *sel = [v isKindOfClass:NSString.class] ? v : nil;
    if ([sel isEqualToString:@"__none__"]) return nil;
    /* 2.7.42: 选了就必须用选中的那张。旧版在"选中项不在列表里"(文件被改名/删除/
       列表顺序变了) 时静默退回 list.firstObject —— 用户看到的就是"换素材没效果,
       还是显示原来那张"。现在只在真正没选过(sel 为空)时才用第一张。 */
    if (sel.length) {
        if ([list containsObject:sel]) return [kMaskDir stringByAppendingPathComponent:sel];
        return nil;   /* 选中的文件不在了: 不遮罩, 也不偷偷换成别的 */
    }
    return [kMaskDir stringByAppendingPathComponent:list.firstObject];
}

/* ===== 2.8.78: 给 MediaRemoteUI 进程的素材通道 =====
   MediaRemoteUI 是独立沙盒进程, 直接读 /var/mobile/灵动岛 很可能被沙盒拒绝
   (325 日志: 该进程 0 条记录 + 展开态遮罩从不生效, 两个症状同时指向跨进程不可达)。
   SpringBoard 这边把**选中的原始 png 字节**导出到三条通道, MediaRemoteUI 侧
   按同样顺序回读, 哪条通用哪条:
     ① /var/mobile/Library/Caches/com.abgg332.driftisland/mask.png
     ② 偏好域 com.abgg332.driftisland.mrumask 的 diMruMaskB64 (base64, 小于 512KB 才写)
     ③ 偏好域同上的 diMruActive —— 开关状态, 防止该进程读不到主偏好域时开关恒为关 */
static NSString *diMruCacheDir(void) {
    return @"/var/mobile/Library/Caches/com.abgg332.driftisland";
}
/* ===== 2.8.82: 唯一 100% 可用的跨进程通道 —— MRU 自己的容器 =====
   328 日志把前三条通道全部判死: shape.none 说明 MediaRemoteUI 读不到
   /var/mobile/Library/Caches(沙盒) 也读不到我们的偏好域(偏好被重定向到它自己的容器),
   于是素材永远拿不到, 遮罩从 2.8.77 起就没真正挂上过。
   沙盒进程**一定能读的只有它自己的容器**: 所以由 SpringBoard 把素材和旋转参数
   写进 <MRU容器>/Library/Caches/com.abgg332.driftisland/, MRU 侧从
   NSCachesDirectory 读同一个目录 —— 同一路径, 两边都合法。 */
static NSString *diMruOwnContainer(void) {
    static NSString *path; static BOOL tried;
    if (tried) return path;
    tried = YES;
    @try {
        Class proxyCls = NSClassFromString(@"LSApplicationProxy");
        if ([proxyCls respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
            id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyCls, @selector(applicationProxyForIdentifier:),
                                                          @"com.apple.MediaRemoteUI");
            SEL urlSel = NSSelectorFromString(@"dataContainerURL");
            if (proxy && [proxy respondsToSelector:urlSel]) {
                NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(proxy, urlSel);
                if (url.path.length) path = url.path;
            }
        }
    } @catch (__unused NSException *e) {}
    if (!path.length) {
        NSString *root = @"/var/mobile/Containers/Data/Application";
        for (NSString *uuid in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:NULL]) {
            NSString *dir = [root stringByAppendingPathComponent:uuid];
            NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:
                [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
            if ([meta[@"MCMMetadataIdentifier"] isEqual:@"com.apple.MediaRemoteUI"]) { path = dir; break; }
        }
    }
    return path;
}
static NSString *diMruSharedDir(void) {
    NSString *c = diMruOwnContainer();
    return c.length ? [c stringByAppendingPathComponent:@"Library/Caches/com.abgg332.driftisland"] : nil;
}
static void diExportMaskForMRU(void) {
    @autoreleasepool {
        NSString *path = diMaskCurrentPathV2();
        NSData *raw = path ? [NSData dataWithContentsOfFile:path] : nil;
        if (raw.length > 512 * 1024) raw = nil;   /* 太大的不塞偏好, 只走文件通道 */
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *err = nil;
        [fm createDirectoryAtPath:diMruCacheDir() withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions: @0777} error:&err];
        NSString *out = [diMruCacheDir() stringByAppendingPathComponent:@"mask.png"];
        BOOL fileOK = NO;
        if (raw) {
            fileOK = [raw writeToFile:out atomically:YES];
            if (fileOK) [fm setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:out error:NULL];
        } else {
            [fm removeItemAtPath:out error:NULL];
        }
        CFStringRef dom = CFSTR("com.abgg332.driftisland.mrumask");
        CFPreferencesAppSynchronize(dom);
        NSString *b64 = raw ? [raw base64EncodedStringWithOptions:0] : nil;
        CFPreferencesSetAppValue(CFSTR("diMruMaskB64"), (__bridge CFStringRef)b64, dom);
        BOOL active = pBool(@"enabled", NO) && pBool(@"maskOn", NO);
        CFPreferencesSetAppValue(CFSTR("diMruActive"), active ? CFSTR("1") : CFSTR("0"), dom);
        CFPreferencesAppSynchronize(dom);
        /* 2.8.82: 真正能被 MRU 读到的那一份 —— 它自己的容器 */
        NSString *own = diMruSharedDir();
        BOOL ownOK = NO;
        if (own.length) {
            [fm createDirectoryAtPath:own withIntermediateDirectories:YES
                            attributes:@{NSFilePosixPermissions: @0777} error:NULL];
            NSString *mine = [own stringByAppendingPathComponent:@"mask.png"];
            if (raw) {
                ownOK = [raw writeToFile:mine atomically:YES];
                if (ownOK) [fm setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:mine error:NULL];
            } else {
                [fm removeItemAtPath:mine error:NULL];
            }
            NSDictionary *params = @{@"rot": @(maskRotateOn), @"rev": @(maskRotateReverse),
                                     @"speed": @(maskRotateSpeed), @"active": @(active),
                                     @"mask": path.lastPathComponent ?: @"",
                                     /* 2.8.85: 展开定义 —— MRU 内的歌词/歌名位置与大小 */
                                     @"etOn": @(expandTextOn), @"etX": @(expandTextX),
                                     @"etY": @(expandTextY), @"etScale": @(expandTextScale),
                                     /* 2.8.93: 隐藏投送按钮 */
                                     @"hideRoute": @(hideRouteOn)};
            [params writeToFile:[own stringByAppendingPathComponent:@"params.plist"] atomically:YES];
        }
        RLog(@"[遮罩导出] → MediaRemoteUI: 素材=%@ 文件=%@ 偏好=%lu字节 开关=%d 容器=%@ 容器写入=%@ 错误=%@",
             path.lastPathComponent ?: @"(无)", fileOK ? @"OK" : @"FAIL",
             (unsigned long)b64.length, active, own.length ? own : @"(找不到MRU容器)",
             ownOK ? @"OK" : @"FAIL", err.localizedDescription ?: @"无");
    }
}

/* 2.8.93: 导出合并 —— 拖滑杆时每秒几十次偏好变更, 每次都整包导一遍
   (读图 + 写两个容器 + base64 塞进 CFPreferences), 几十个任务并发跑会把
   cfprefsd 顶死, 主线程跟着卡 → 看门狗杀 SpringBoard(用户看到"一拖就进安全模式")。
   现在改成串行队列 + 尾部去抖: 一轮拖动只在停下来 0.25s 后导一次。 */
static NSInteger gDIMaskExportGen;
static dispatch_queue_t diMaskExportQueue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.abgg332.di.maskexport", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static void diExportMaskSoon(void) {
    NSInteger gen = ++gDIMaskExportGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   diMaskExportQueue(), ^{
        if (gen != gDIMaskExportGen) return;   /* 后面还有更新的请求, 这次作废 */
        diExportMaskForMRU();
    });
}

/* 通过 MediaRemote 拿当前专辑封面 —— 裁图失败时的兜底, 保证"一定有一张专辑图" */
__attribute__((unused)) static UIImage *diNowPlayingArtworkV2(void) {
    static UIImage *cImg = nil;
    static NSString *cTitle = nil;
    static CFAbsoluteTime tGet = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (cImg && now - tGet < 3.0) return cImg;

    static void (*mrGetInfo)(dispatch_queue_t, void (^)(NSDictionary *)) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (h) mrGetInfo = (void (*)(dispatch_queue_t, void (^)(NSDictionary *)))dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    });
    if (!mrGetInfo) return cImg;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *info = nil;
    mrGetInfo(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(NSDictionary *d) {
        info = d;
        dispatch_semaphore_signal(sem);
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC))) != 0) return cImg;
    if (![info isKindOfClass:NSDictionary.class]) return cImg;

    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if (art.length) {
        UIImage *img = [UIImage imageWithData:art];
        if (img) { cImg = img; cTitle = title; tGet = now; return cImg; }
    }
    if (cImg && [title isEqualToString:cTitle]) { tGet = now; return cImg; }
    tGet = now;
    return cImg;
}

/* 读素材里的"形状半径"(单位: 相对短边)。
   只在首次转换时算一次, 用于日志与"素材是不是整个就是一个圆"的判断 */
static CGFloat diShapeRadiusOf(UIImage *shape, CGPoint *outCenter) {
    if (!shape) return 0;
    CGImageRef cg = shape.CGImage;
    if (!cg) return 0;
    size_t w = 128, h = 128, bpr = w * 4;
    NSMutableData *buf = [NSMutableData dataWithLength:bpr * h];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf.mutableBytes, w, h, 8, bpr, cs,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!c) { CGColorSpaceRelease(cs); return 0; }
    CGContextSetBlendMode(c, kCGBlendModeCopy);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(c);
    CGColorSpaceRelease(cs);
    unsigned char *px = (unsigned char *)buf.mutableBytes;
    double sx = 0, sy = 0; long n = 0;
    double minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9;
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) {
        if (px[(y * w + x) * 4 + 3] < 128) continue;
        sx += x; sy += y; n++;
        if ((double)x < minX) minX = x;
        if ((double)x > maxX) maxX = x;
        if ((double)y < minY) minY = y;
        if ((double)y > maxY) maxY = y;
    }
    if (n < (long)(w * h * 0.005)) return 0;
    if (outCenter) *outCenter = CGPointMake((sx / n) / w, (sy / n) / h);
    double rArea = sqrt((double)n / M_PI);
    double rBox = MIN(maxX - minX + 1, maxY - minY + 1) * 0.5;
    double r = (fabs(rArea - rBox) / MAX(1.0, rBox) < 0.4) ? rArea : rBox;
    return (CGFloat)(r / (double)MIN(w, h));
}

/* 音频开关: 开→彻底隐藏右侧原生波形, 按钮/专辑/歌词不受影响; 关→全部恢复。
   波形像素其实在 App 的远程内容里(CALayerHost), 本地视图树里只有一个代理层,
   所以"彻底隐藏" = 两件事一起做:
     ① 本地代理波形视图直接 hidden = YES(真正的开关, 不盖层, 切换瞬间生效);
     ② 远程门户层用掩码挖掉右上角那 54x50(本地 mask 管不到远程像素, 只能这样裁)。
   2.8.14 修旧版三个毛病(用户原话"隐藏也不彻底, 长按展开还是会显示一下,
   展开后会显示一帧才隐藏"):
     a. 旧守卫"岛高<150 不挖洞" → 长按展开整个过程波形都露着; 现在高≥90(动画中段)就挖;
     b. 洞坐标旧是固定值, 动画中段岛变小 → 挖错地方; 现在按岛宽等比缩放, 每帧跟随;
     c. 门户层在展开稳定瞬间会被系统重建, 旧缓存 0.25s 内还指着失效层 → 闪一帧;
        现在缓存层不在树里立刻重扫(diFindAudioLayer 内已修)。 */
static char kDiMaskOn;
static char kDiMaskW; // 记录掩码应用时的缩放系数 k: 变化<0.01 不动, 否则每帧跟随
static char kDiSpecHit; // 被我们 hidden 掉的本地波形视图(弱引用表, 恢复用)

/* 我们自己的注入视图(帧率素材/玻璃/视频)—— 音频扫描必须跳过,
   否则帧率素材那张 89x66 的 UIImageView 会被当成波形藏掉(用户素材消失) */
static BOOL diIsOurInjectedView(UIView *v) {
    NSString *cn = NSStringFromClass(v.class);
    return [cn isEqualToString:@"DIMaskView"] || [cn isEqualToString:@"DIAnimView"]
        || [cn isEqualToString:@"DIVideoView"];
}

/* 2.8.15: 在远程画布(audioL)里找"波形附件门户" —— 12~64pt 的 CAPortalLayer,
   且中心在画布宽度 60% 以右(波形在右侧, 专辑门户在左侧)。
   富展开岛(407x202)的波形门户(22x22)就在 CALayerHost(407x489)的画布里,
   洞精确挖在它身上; 系统默认展开岛的波形在 App 内容门户**内部**远程渲染,
   画布里找不到 → 返回 nil, 由调用方按"右侧垂直居中"公式兜底。 */
static CALayer *diFindWaveformPortalIn(CALayer *root) {
    if (!root) return nil;
    CGFloat w = root.bounds.size.width;
    if (w < 40) return nil;
    NSMutableArray<CALayer *> *st = [NSMutableArray arrayWithObject:root];
    int g = 0;
    while (st.count && g++ < 200) {
        CALayer *l = st.firstObject; [st removeObjectAtIndex:0];
        for (CALayer *s in l.sublayers) {
            [st addObject:s];
            if ([NSStringFromClass(s.class) containsString:@"CAPortalLayer"]) {
                CGSize sz = s.bounds.size;
                if (sz.width < 12 || sz.height < 12 || sz.width > 64 || sz.height > 64) continue;
                CGRect fr = [root convertRect:s.frame fromLayer:s.superlayer];
                if (fr.origin.x + fr.size.width * 0.5 > w * 0.6) return s;
            }
        }
    }
    return nil;
}

/* 2.8.22: syncNativeSpectrum 强制标志 —— 音乐岛消失时的"最后一次还原"要跳过
   0.25s 节流, 否则还原调用被节流挡掉, 藏起来的波形/挖的洞就永远留在最后一个
   音乐岛上(之后所有调用者都卸载了, 再也没有下次)。由 updateSingleVideo 置位。 */
static BOOL gSpecForceNext;
static BOOL diHostLooksLikeNotification(UIView *host, BOOL *detail); // 2.9.14: 前置声明(syncNativeSpectrum 用到)

static void syncNativeSpectrum(UIView *bestRoot) {
    if (!bestRoot) return;
    CALayer *pl = bestRoot.layer.presentationLayer;
    CGSize bs = pl ? pl.bounds.size : bestRoot.bounds.size;
    /* ===== 2.8.16: 节流 =====
       这个函数被 DIAnimView.step 无条件每帧调用, 一次跑两遍全树遍历
       (各最多 500 个视图) + diFindAudioLayer 再遍历一遍, 60fps 下
       每秒 180 次树遍历 —— "小岛到展开一卡一卡"的第二大来源。
       现在: 0.25s 最多跑一次; 岛尺寸跳 >8pt(展开/收起动画) 或开关状态变了立即跑,
       所以展开瞬间的波形照样当场消失, 稳定后零开销。 */
    {
        static CFAbsoluteTime sT; static CGFloat sW, sH; static NSInteger sSeenState = -1;
        NSInteger cur = (spectrumOn ? 1 : 0) | (enabled ? 2 : 0) | (hideRouteOn ? 4 : 0);
        BOOL sizeJump = (fabs(bs.width - sW) > 8.0 || fabs(bs.height - sH) > 8.0);
        BOOL stateJump = (sSeenState != cur);
        if (!gSpecForceNext && !sizeJump && !stateJump && CFAbsoluteTimeGetCurrent() - sT < 0.4) return;
        gSpecForceNext = NO;
        sT = CFAbsoluteTimeGetCurrent(); sW = bs.width; sH = bs.height; sSeenState = cur;
    }
    /* 展开态(含展开动画中段)才动手; 小岛/锁屏大卡(高700+)不碰。
       2.8.15: 高度门槛 90 → 60 —— 系统默认展开岛实测只有 330x72 / 333x65
       (285 日志), 旧门槛把它们全排除, 用户原话"展开岛的音频你没有隐藏"。
       小岛最高 207x58, 仍被 60 挡在外面, 小岛右侧波形不动。 */
    /* 2.9.15: 去掉 2.9.14 加的"非通知岛"判据 —— diHostLooksLikeNotification 靠"长文本+图标"
       猜, 展开音乐岛里歌名够长就会被它判成通知(359 日志: 407x84 正放歌 → 通知岛),
       结果展开岛的波形藏不掉, 素材底下一直透出原生波形。通知岛的问题已由"视频层只挂音乐岛"解决。 */
    BOOL expandedish = (bs.width >= 250 && bs.height >= 60 && bs.height <= 320)
                        && diIsNowPlayingHostCached(bestRoot);

    /* ① 本地代理波形视图: 直接 hidden( instantly 生效, 无动画无延迟) */
    NSHashTable *hits = objc_getAssociatedObject(bestRoot, &kDiSpecHit);
    if (!hits) {
        hits = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(bestRoot, &kDiSpecHit, hits, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!spectrumOn || !enabled || !expandedish) {
        for (UIView *v in hits.allObjects) if (v.hidden) v.hidden = NO;
        [hits removeAllObjects];
    } else {
        /* 右侧波形代理: 叶 UIImageView, 50~100 x 35~70, 中心在岛宽 70% 以右 */
        NSMutableArray<UIView *> *found = [NSMutableArray new];
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:bestRoot];
        int guard = 0;
        while (stack.count && guard++ < 500) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            if (diIsOurInjectedView(v)) continue;   /* 我们的素材不藏 */
            if (v != bestRoot && !v.hidden && v.alpha > 0.05
                && [v isKindOfClass:UIImageView.class] && v.subviews.count == 0) {
                CGSize s = v.bounds.size;
                if (s.width >= 50 && s.width <= 100 && s.height >= 35 && s.height <= 70) {
                    CGPoint c = CGPointMake(v.frame.origin.x + s.width * 0.5,
                                            v.frame.origin.y + s.height * 0.5);
                    if (c.x > bs.width * 0.7 && c.y > 0 && c.y < bs.height) {
                        [found addObject:v]; continue;
                    }
                }
            }
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
        if (found.count) {
            NSUInteger before = hits.count;
            for (UIView *v in found) { [hits addObject:v]; if (!v.hidden) v.hidden = YES; }
            if (hits.count != before || before == 0)
                DLog(@"音频开关开: 直接隐藏 %lu 个原生波形图层(岛 %.0fx%.0f)",
                     (unsigned long)found.count, bs.width, bs.height);
        }

        /* ①-b 2.8.15: 右侧本地音频动态图 + 右侧小门户层 —— 285 视频实锤:
           系统默认展开岛(330x72/333x65)右侧那个圆形波形动画是**本地**
           DynamicAnimationView(36x36) + 附件门户(22x22, 远程波形),
           既不在 ① 的"叶 UIImageView 50~100x35~70"滤波里, 挖洞也挖不到
           (它们在岛本地树里, 不在远程门户画布中)。用户原话"你也没隐藏音频动态图"。
           判据: 12~64pt 的本地视图、中心在岛宽 70% 以右、垂直中带(20%~80%),
           直接 hidden(与 ① 同一套 hits 表还原, 开关关/岛收缩时统一恢复)。
           专辑方块在左侧(x<70%), 歌词/标题在中间, 均不受影响。 */
        NSMutableArray<UIView *> *found2 = [NSMutableArray new];
        NSMutableArray<UIView *> *stack2 = [NSMutableArray arrayWithObject:bestRoot];
        int guard2 = 0;
        while (stack2.count && guard2++ < 500) {
            UIView *v = stack2.lastObject; [stack2 removeLastObject];
            if (diIsOurInjectedView(v)) { continue; }
            if (v != bestRoot && !v.hidden && v.alpha > 0.05) {
                CGSize s = v.bounds.size;
                if (s.width >= 12 && s.height >= 12 && s.width <= 64 && s.height <= 64) {
                    CGPoint c = CGPointMake(v.frame.origin.x + s.width * 0.5,
                                            v.frame.origin.y + s.height * 0.5);
                    if (c.x > bs.width * 0.7
                        && c.y > bs.height * 0.2 && c.y < bs.height * 0.8) {
                        [found2 addObject:v]; continue;
                    }
                }
            }
            for (UIView *sub in v.subviews) [stack2 addObject:sub];
        }
        if (found2.count) {
            NSUInteger before2 = hits.count;
            for (UIView *v in found2) { [hits addObject:v]; if (!v.hidden) v.hidden = YES; }
            if (hits.count != before2)
                DLog(@"音频开关开: 直接隐藏 %lu 个右侧音频动态图/门户层(岛 %.0fx%.0f)",
                     (unsigned long)found2.count, bs.width, bs.height);
        }
    }

    /* ② 远程门户层: 掩码挖洞
       2.8.94: 从"只挖波形一个洞"改成"洞表" —— 波形一个洞、投送按钮再一个洞,
       一次 mask 全画完; 两个开关各自独立, 都关就整块摘掉, 完全回原生。
       投送按钮的像素同样在远程内容里(本地树里只有门户), 所以只能挖, 挖掉就露出
       我们自己的视频/专辑背景, 视觉上等于给那一块单独贴了一层。 */
    CALayer *audioL = diFindAudioLayer(bestRoot);
    if (!audioL) return;
    NSMutableArray<NSValue *> *holes = [NSMutableArray array];
    BOOL wantSpec = (spectrumOn && enabled && expandedish);
    BOOL wantRoute = (hideRouteOn && enabled && expandedish);
    BOOL specExact = NO;
    if (wantSpec) {
        /* 波形洞: 三种布局, 精确优先(2.8.15 重写)
           (a) 画布里有波形门户层 → 洞精确挖在它身上;
           (b) 系统默认展开岛(门户只有 60~80pt 高) → 右侧垂直居中;
           (c) 都不命中 → 按实测 347x156 基准等比缩放的兜底公式。 */
        CALayer *wav = diFindWaveformPortalIn(audioL);
        CGRect hole = CGRectZero;
        if (wav) {
            CGRect wr = [audioL convertRect:wav.frame fromLayer:wav.superlayer];
            hole = CGRectInset(wr, -3.0, -3.0);   /* 外扩 3pt 盖住抗锯齿边缘 */
            specExact = YES;
        } else if (audioL.bounds.size.height <= 100) {
            CGFloat pw = audioL.bounds.size.width, ph = audioL.bounds.size.height;
            CGFloat hw = MIN(34.0, pw * 0.16), hh = MIN(34.0, ph * 0.5);
            hole = CGRectMake(pw - hw - 6.0, (ph - hh) * 0.5, hw, hh);
        } else {
            CGFloat k = bs.width / 347.0;
            if (k < 0.62) k = 0.62;
            if (k > 1.0) k = 1.0;
            hole = CGRectMake(bs.width - 69.0 * k, 26.0 * k, 54.0 * k, 50.0 * k);
        }
        [holes addObject:[NSValue valueWithCGRect:hole]];
    }
    if (wantRoute) {
        /* 投送洞: 照抄波形那套公式, 搬到右下角 —— 341 日志实测展开岛里那颗
           MRUTransportButton 中心在 (365,131)/401x167 ≈ 91% 宽、78% 高,
           所以洞取 54k 见方、右边留 15k、底边留 26k。矮岛(系统默认展开岛 330x72
           这种)没有底栏, 退化成"右侧垂直居中", 跟波形 (b) 一致。 */
        CGFloat k = bs.width / 347.0;
        if (k < 0.62) k = 0.62;
        if (k > 1.0) k = 1.0;
        CGFloat hw = 54.0 * k, hh = 54.0 * k;
        CGRect hole = (bs.height >= 120.0)
            ? CGRectMake(bs.width - 69.0 * k, bs.height - 80.0 * k, hw, hh)
            : CGRectMake(MIN(audioL.bounds.size.width, bs.width) - hw - 6.0,
                         (bs.height - hh) * 0.5, hw, hh);
        [holes addObject:[NSValue valueWithCGRect:hole]];
    }
    if (!holes.count) {
        if (audioL.mask) {
            audioL.mask = nil;
            objc_setAssociatedObject(audioL, &kDiMaskOn, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(audioL, &kDiMaskW, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            DLog(@"波形/投送掩码: 两个开关都关, 移除掩码");
        }
        return;
    }
    /* 尺寸/门户形态/洞表没变就不动(岛动画中每帧都重画 path 会很贵) */
    BOOL applied = [objc_getAssociatedObject(audioL, &kDiMaskOn) isEqual:@YES];
    NSMutableString *holeKey = [NSMutableString stringWithFormat:@"%.0fx%.0f/%.0fx%.0f/%d%d",
                                bs.width, bs.height,
                                audioL.bounds.size.width, audioL.bounds.size.height,
                                wantSpec, wantRoute];
    for (NSValue *hv in holes) [holeKey appendFormat:@"|%@", NSStringFromCGRect(hv.CGRectValue)];
    NSString *lastKey = objc_getAssociatedObject(audioL, &kDiMaskW);
    if (applied && [lastKey isEqualToString:holeKey]) return;
    CAShapeLayer *m = (CAShapeLayer *)audioL.mask;
    if (!applied || ![m isKindOfClass:CAShapeLayer.class]) {
        m = [CAShapeLayer layer];
        audioL.mask = m;
        objc_setAssociatedObject(audioL, &kDiMaskOn, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    m.frame = CGRectMake(0, 0, audioL.bounds.size.width, audioL.bounds.size.height);
    UIBezierPath *p = [UIBezierPath bezierPathWithRect:m.frame];
    for (NSValue *hv in holes)
        [p appendPath:[UIBezierPath bezierPathWithRoundedRect:hv.CGRectValue cornerRadius:8.0]];
    m.fillRule = kCAFillRuleEvenOdd; /* 洞里露出岛自己的内容, 洞外保留音乐门户 */
    m.path = p.CGPath;
    objc_setAssociatedObject(audioL, &kDiMaskW, holeKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    {
        NSMutableString *desc = [NSMutableString string];
        for (NSValue *hv in holes) [desc appendFormat:@"%@ ", NSStringFromCGRect(hv.CGRectValue)];
        DLog(@"掩码挖洞: %@(岛 %.0fx%.0f 门户 %.0fx%.0f 波形=%d精确%d 投送=%d)",
             desc, bs.width, bs.height, audioL.bounds.size.width, audioL.bounds.size.height,
             wantSpec, specExact, wantRoute);
    }
}

#pragma mark - 宿主挂载

/* 2.2.6: 岛上通知样式 —— 关联对象键 */
static char kLabelOrigColor;   // UILabel 原始颜色(恢复用)
static char kLabelFlowMask;    // UILabel 流光渐变图层(CAGradientLayer)
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
static BOOL applyFlow(UIView *v, CGFloat phase) {
    UILabel *lb = [v isKindOfClass:UILabel.class] ? (UILabel *)v : nil;
    if (!lb) return NO;
    NSAttributedString *orig = lb.attributedText;
    NSString *text = orig.length ? orig.string : lb.text;
    if (!text.length) return NO;
    NSArray<UIColor *> *cs = gNotifyColors;
    if (!cs.count) cs = @[gNotifyColor ?: [UIColor whiteColor]];
    NSUInteger n = text.length;

    /* 2.6.12: 只"加颜色", 绝不重排 —— 这是字体被放大的根因修复。
       老代码用 setAttributes:range: 把第 0 个字符的全部属性刷到全文,
       而通知里第 0 个字符常常是带 font 的富文本片段, 于是全文被套上那个字号,
       UILabel 再按自己的 font 排一次 → 字号打架、整块被撑大(来电/电池详情最明显)。
       现在保留原有每一个字符自己的属性, 只覆盖前景色。 */
    NSMutableAttributedString *as;
    if (orig.length == n) {
        as = [orig mutableCopy];
    } else {
        as = [[NSMutableAttributedString alloc] initWithString:text];
        if (lb.font) [as addAttribute:NSFontAttributeName value:lb.font range:NSMakeRange(0, n)];
        if (lb.textColor) [as addAttribute:NSForegroundColorAttributeName value:lb.textColor range:NSMakeRange(0, n)];
        if (lb.textAlignment != NSTextAlignmentNatural) {
            NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
            p.alignment = lb.textAlignment;
            [as addAttribute:NSParagraphStyleAttributeName value:p range:NSMakeRange(0, n)];
        }
    }
    if (cs.count == 1) {
        [as addAttribute:NSForegroundColorAttributeName value:cs[0] range:NSMakeRange(0, n)];
    } else {
        /* 按合成字符切段上色: 不破坏 emoji(原来按 UTF-16 单码元切, 代理对会被切断变乱码) */
        __block NSUInteger idx = 0;
        NSUInteger total = MAX((NSUInteger)1, n - 1);
        [text enumerateSubstringsInRange:NSMakeRange(0, n)
                                 options:NSStringEnumerationByComposedCharacterSequences
                              usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) {
            CGFloat t = (CGFloat)idx / (CGFloat)total + phase;
            [as addAttribute:NSForegroundColorAttributeName value:diColorAt(cs, t) range:r];
            idx += r.length;
        }];
    }
    /* 关键: 不碰 lb.textColor, 也不改 font / numberOfLines / lineBreakMode,
       标签的排版参数保持系统原样, 只有颜色在变 → 视觉上不会再被放大或拉伸。 */
    lb.attributedText = as;
    objc_setAssociatedObject(v, &kLabelFlowMask, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // 标记"已上色"
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
    CGFloat phase = (CGFloat)fmod(CFAbsoluteTimeGetCurrent() / 2.5, 1.0); // 2.5秒一轮流光
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:host];
    int g = 0, colored = 0;
    while (stack.count && g++ < 400) {
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0];
        for (UIView *s in v.subviews) [stack addObject:s];
        if (![v isKindOfClass:UILabel.class]) continue;
        UILabel *lb = (UILabel *)v;
        if (!lb.text.length && !lb.attributedText.length) continue;
        if (notifyColorOn) {
            if (!objc_getAssociatedObject(lb, &kLabelOrigColor))
                objc_setAssociatedObject(lb, &kLabelOrigColor, lb.textColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            /* 关流光: phase 固定 0 → 静态多色渐变(设几个颜色显示几段);
               开流光: phase 随时间推进 → 同一串颜色滚动流动。
               两种情况都上色, 不再退化成"只用第一个颜色"。 */
            if (gNotifyColor) lb.textColor = gNotifyColor; // 底色兜底(attributedText 未覆盖的片段)
            if (applyFlow(lb, notifyFlowOn ? phase : 0)) colored++;
        } else {
            /* 关颜色: 撤流光(还原纯文本)并按需还原原始色 */
            BOOL hadFlow = objc_getAssociatedObject(lb, &kLabelFlowMask) != nil;
            if (hadFlow) {
                NSString *plain = lb.attributedText.length ? lb.attributedText.string : lb.text;
                objc_setAssociatedObject(lb, &kLabelFlowMask, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (plain.length) lb.text = plain;
            }
            UIColor *orig = objc_getAssociatedObject(lb, &kLabelOrigColor);
            if (orig) { lb.textColor = orig; objc_setAssociatedObject(lb, &kLabelOrigColor, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
            if (hadFlow) colored++; // 触发一次重绘
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

static void diForEachWindow(void (^blk)(UIWindow *w));

/* ===== 2.9.33: 深色功能 —— 完全移植 GlobalFontSwitcher(GLFTextColorManager) =====
   原版做法(反汇编核实):
     · 锁屏   hook CSCoverSheetViewController viewWillAppear: → 整个锁屏 VC 套 overrideUserInterfaceStyle;
     · 桌面   hook _UIContextMenuView / UIInterfaceActionGroupView 的 initWithFrame:+didMoveToWindow、
              SBHIconViewContextMenuWrapperViewController 的 init+viewDidLoad → 3D 长按菜单整棵套同样式;
     · 记账   associated object 存「原样式 + 已托管」标记, 关闭时还原原样式;
              NSHashTable 弱引用登记, 改设置后对所有登记过的对象立即重刷。
   模式映射: 关=跟随系统(0), 强制深色开=深色(1), 关=浅色(2) —— 与原版 interfaceStyleForMode: 一致。 */
/* associated object 键: 用静态变量地址(NSString 串不能当 key) */
static char kGLFLockOrigKey, kGLFLockMgdKey;
static char kGLFMenuViewOrigKey, kGLFMenuViewMgdKey;
static char kGLFMenuVCOrigKey, kGLFMenuVCMgdKey;

static NSHashTable *gGLFLockControllers, *gGLFMenuViews, *gGLFMenuControllers;
static IMP gGLFOrigCSViewWillAppear, gGLFOrigMenuViewInit, gGLFOrigMenuViewMove,
           gGLFOrigActionGroupInit, gGLFOrigActionGroupMove, gGLFOrigMenuVCInit, gGLFOrigMenuVCViewDidLoad;

/* 模式: 0=跟随系统 1=深色 2=浅色 */
static NSInteger diGLFMode(void) {
    if (!gThemeOn) return 0;
    return gThemeDark ? 1 : 2;
}

static UIUserInterfaceStyle diGLFStyleForMode(NSInteger mode) {
    if (!gThemeOn || mode == 0) return UIUserInterfaceStyleUnspecified;
    return mode == 1 ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
}

static void diGLFApplyStyleToView(UIView *v, NSInteger mode, void *oKey, void *mKey) {
    if (!v) return;
    UIUserInterfaceStyle want = diGLFStyleForMode(mode);
    NSNumber *managed = objc_getAssociatedObject(v, mKey);
    if (want == UIUserInterfaceStyleUnspecified) {
        if (managed.boolValue) {                       /* 还原成接管前的原样式 */
            NSNumber *orig = objc_getAssociatedObject(v, oKey);
            if (orig && v.overrideUserInterfaceStyle != (UIUserInterfaceStyle)orig.integerValue)
                v.overrideUserInterfaceStyle = (UIUserInterfaceStyle)orig.integerValue;
            objc_setAssociatedObject(v, mKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (!managed.boolValue)                            /* 只在第一次接管时记原样式 */
        objc_setAssociatedObject(v, oKey, @(v.overrideUserInterfaceStyle), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (v.overrideUserInterfaceStyle != want) v.overrideUserInterfaceStyle = want;
    objc_setAssociatedObject(v, mKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void diGLFApplyStyleToController(UIViewController *c, NSInteger mode, void *oKey, void *mKey) {
    if (!c) return;
    UIUserInterfaceStyle want = diGLFStyleForMode(mode);
    NSNumber *managed = objc_getAssociatedObject(c, mKey);
    if (want == UIUserInterfaceStyleUnspecified) {
        if (managed.boolValue) {
            NSNumber *orig = objc_getAssociatedObject(c, oKey);
            if (orig && c.overrideUserInterfaceStyle != (UIUserInterfaceStyle)orig.integerValue)
                c.overrideUserInterfaceStyle = (UIUserInterfaceStyle)orig.integerValue;
            objc_setAssociatedObject(c, mKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (!managed.boolValue)
        objc_setAssociatedObject(c, oKey, @(c.overrideUserInterfaceStyle), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (c.overrideUserInterfaceStyle != want) c.overrideUserInterfaceStyle = want;
    objc_setAssociatedObject(c, mKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void diGLFRegisterLockScreenController(UIViewController *c) {
    if (!c) return;
    if (!gGLFLockControllers) gGLFLockControllers = [NSHashTable weakObjectsHashTable];
    [gGLFLockControllers addObject:c];
    diGLFApplyStyleToController(c, diGLFMode(), &kGLFLockOrigKey, &kGLFLockMgdKey);
}

static void diGLFRegisterHomeScreenMenuRoot(UIView *v) {
    if (!v) return;
    if (!gGLFMenuViews) gGLFMenuViews = [NSHashTable weakObjectsHashTable];
    [gGLFMenuViews addObject:v];
    diGLFApplyStyleToView(v, diGLFMode(), &kGLFMenuViewOrigKey, &kGLFMenuViewMgdKey);
}

static void diGLFRegisterHomeScreenMenuController(UIViewController *c) {
    if (!c) return;
    if (!gGLFMenuControllers) gGLFMenuControllers = [NSHashTable weakObjectsHashTable];
    [gGLFMenuControllers addObject:c];
    diGLFApplyStyleToController(c, diGLFMode(), &kGLFMenuVCOrigKey, &kGLFMenuVCMgdKey);
}

/* 注销后锁屏 VC 可能早已建好(不会再走 viewWillAppear), 主动扫一遍登记 */
static void diGLFScanLockVC(UIViewController *vc, NSMutableArray *out) {
    if (!vc) return;
    if ([NSStringFromClass(vc.class) isEqualToString:@"CSCoverSheetViewController"]) [out addObject:vc];
    for (UIViewController *ch in vc.childViewControllers) diGLFScanLockVC(ch, out);
}

static void diGLFAttachExisting(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ diGLFAttachExisting(); }); return; }
    NSMutableArray *found = [NSMutableArray array];
    diForEachWindow(^(UIWindow *w){ diGLFScanLockVC(w.rootViewController, found); });
    for (UIViewController *c in found) diGLFRegisterLockScreenController(c);
    if (found.count) DLog(@"[启动外观] 现存锁屏 VC 已登记 %lu 个", (unsigned long)found.count);
}

static void diGLFReloadAndReapply(void) {
    NSInteger mode = diGLFMode();
    for (UIViewController *c in gGLFLockControllers.allObjects)
        diGLFApplyStyleToController(c, mode, &kGLFLockOrigKey, &kGLFLockMgdKey);
    for (UIView *v in gGLFMenuViews.allObjects)
        diGLFApplyStyleToView(v, mode, &kGLFMenuViewOrigKey, &kGLFMenuViewMgdKey);
    for (UIViewController *c in gGLFMenuControllers.allObjects)
        diGLFApplyStyleToController(c, mode, &kGLFMenuVCOrigKey, &kGLFMenuVCMgdKey);
    DLog(@"[启动外观] 重刷 模式=%ld 锁屏VC=%lu 菜单视图=%lu 菜单VC=%lu",
         (long)mode, (unsigned long)gGLFLockControllers.count,
         (unsigned long)gGLFMenuViews.count, (unsigned long)gGLFMenuControllers.count);
    diGLFAttachExisting();
}

static void h_glfCSViewWillAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (gGLFOrigCSViewWillAppear)
        ((void(*)(id, SEL, BOOL))gGLFOrigCSViewWillAppear)(self, _cmd, animated);
    diGLFRegisterLockScreenController(self);
}

static UIView *h_glfMenuViewInit(UIView *self, SEL _cmd, CGRect frame) {
    UIView *r = gGLFOrigMenuViewInit
        ? ((UIView *(*)(id, SEL, CGRect))gGLFOrigMenuViewInit)(self, _cmd, frame) : self;
    diGLFRegisterHomeScreenMenuRoot(r ?: self);
    return r;
}

static void h_glfMenuViewMove(UIView *self, SEL _cmd) {
    if (gGLFOrigMenuViewMove)
        ((void(*)(id, SEL))gGLFOrigMenuViewMove)(self, _cmd);
    diGLFRegisterHomeScreenMenuRoot(self);
}

/* UIInterfaceActionGroupView 用自己的一对 trampoline(原实现各存一份, 不能共用) */
static UIView *h_glfActionGroupInit(UIView *self, SEL _cmd, CGRect frame) {
    UIView *r = gGLFOrigActionGroupInit
        ? ((UIView *(*)(id, SEL, CGRect))gGLFOrigActionGroupInit)(self, _cmd, frame) : self;
    diGLFRegisterHomeScreenMenuRoot(r ?: self);
    return r;
}

static void h_glfActionGroupMove(UIView *self, SEL _cmd) {
    if (gGLFOrigActionGroupMove)
        ((void(*)(id, SEL))gGLFOrigActionGroupMove)(self, _cmd);
    diGLFRegisterHomeScreenMenuRoot(self);
}

static id h_glfMenuVCInit(id self, SEL _cmd) {
    id r = gGLFOrigMenuVCInit ? ((id(*)(id, SEL))gGLFOrigMenuVCInit)(self, _cmd) : self;
    diGLFRegisterHomeScreenMenuController(r ?: self);
    return r;
}

static void h_glfMenuVCViewDidLoad(UIViewController *self, SEL _cmd) {
    if (gGLFOrigMenuVCViewDidLoad)
        ((void(*)(id, SEL))gGLFOrigMenuVCViewDidLoad)(self, _cmd);
    diGLFRegisterHomeScreenMenuController(self);
}

/* 装钩子: dispatch_once 幂等, 私有类晚加载时每次 installKnownHosts 都会再进来补装 */
static void diGLFInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cs = NSClassFromString(@"CSCoverSheetViewController");
        if (cs) {
            Method m = class_getInstanceMethod(cs, @selector(viewWillAppear:));
            if (m) {
                MSHookMessageEx(cs, @selector(viewWillAppear:), (IMP)h_glfCSViewWillAppear, &gGLFOrigCSViewWillAppear);
                DLog(@"[启动外观] hook CSCoverSheetViewController viewWillAppear:");
            }
        } else {
            DLog(@"[启动外观] CSCoverSheetViewController 未加载");
        }
        Class mv = NSClassFromString(@"_UIContextMenuView");
        if (mv) {
            Method m1 = class_getInstanceMethod(mv, @selector(initWithFrame:));
            if (m1) MSHookMessageEx(mv, @selector(initWithFrame:), (IMP)h_glfMenuViewInit, &gGLFOrigMenuViewInit);
            Method m2 = class_getInstanceMethod(mv, @selector(didMoveToWindow));
            if (m2) MSHookMessageEx(mv, @selector(didMoveToWindow), (IMP)h_glfMenuViewMove, &gGLFOrigMenuViewMove);
            DLog(@"[启动外观] hook _UIContextMenuView init=%d move=%d", m1 != NULL, m2 != NULL);
        }
        Class ag = NSClassFromString(@"UIInterfaceActionGroupView");
        if (ag) {
            Method m1 = class_getInstanceMethod(ag, @selector(initWithFrame:));
            if (m1) MSHookMessageEx(ag, @selector(initWithFrame:), (IMP)h_glfActionGroupInit, &gGLFOrigActionGroupInit);
            Method m2 = class_getInstanceMethod(ag, @selector(didMoveToWindow));
            if (m2) MSHookMessageEx(ag, @selector(didMoveToWindow), (IMP)h_glfActionGroupMove, &gGLFOrigActionGroupMove);
            DLog(@"[启动外观] hook UIInterfaceActionGroupView init=%d move=%d", m1 != NULL, m2 != NULL);
        }
        Class mc = NSClassFromString(@"SBHIconViewContextMenuWrapperViewController");
        if (mc) {
            Method m1 = class_getInstanceMethod(mc, @selector(init));
            if (m1) MSHookMessageEx(mc, @selector(init), (IMP)h_glfMenuVCInit, &gGLFOrigMenuVCInit);
            Method m2 = class_getInstanceMethod(mc, @selector(viewDidLoad));
            if (m2) MSHookMessageEx(mc, @selector(viewDidLoad), (IMP)h_glfMenuVCViewDidLoad, &gGLFOrigMenuVCViewDidLoad);
            DLog(@"[启动外观] hook SBHIconViewContextMenuWrapperViewController init=%d load=%d", m1 != NULL, m2 != NULL);
        }
        diGLFAttachExisting();
    });
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
        /* 2.8.22: 记下首次出现的时间戳 —— 放歌时人脸/充电岛后出现,
           "最新出现的岛"优先拿背景视频(音乐岛只管素材/遮罩)。 */
        objc_setAssociatedObject(host, &kHostSeenT,
                                 @(CFAbsoluteTimeGetCurrent()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

/* ===== 2.8.31: 隐藏药丸 —— rascalblackpill 0.1 原样移植 =====
   要藏的东西: 灵动岛底层那块 HDR 增益图(_SBGainMapView), 系统用它把
   挖孔区"增益"成纯黑 —— 放歌/录屏时截图录屏都会拍到它, 就是用户看到的
   "黑色遮挡黑块"。
   rbp 不是设 hidden(截图仍会渲染), 而是 hook 该类的 didMoveToWindow /
   layoutSubviews, 在开关打开时把它从视图树**摘除**(removeFromSuperview),
   并用弱引用记下父视图+原位置; 关闭开关时原位插回。系统每次把黑块挂回来
   或重新布局, hook 都会再摘一次 —— 比一次性扫描彻底。
   只作用于 SpringBoard 主线程、且该 view 位于 SBSystemApertureWindow 内。 */
@interface DIGainMapState : NSObject
@property (nonatomic, strong) UIView *view;
@property (nonatomic, weak)   UIView *parent;
@property (nonatomic, assign) NSUInteger index;
@end
@implementation DIGainMapState
@end

/* ===== 3.0.20: 隐藏药丸改成"只改渲染状态"(核心修复) =====
   2.8.x 起一直是 removeFromSuperview 摘除 + 原位插回。3.0.19 的日志(431/432)把
   代价摆得很清楚:
     · 每次摘/插都会让父视图重排一次 → 一次还原里 41 次 MRUTransportButton.setFrame,
       3×2 那条传送栏就"抖一下"(只有这个布局会在同窗里排 5 个按钮 + 标签)。
     · iOS17 上更狠: 摘掉 → 系统重建 → hook 再摘, 循环往复, 主线程 30~60 秒不返回,
       watchdog 直接把 SpringBoard 杀掉 = 用户说的"光卡死然后注销"。
   现在改成只写 hidden(纯渲染属性, 不改视图树、不触发任何重排), 记账用弱引用表,
   关开关时按原值还原。系统把黑块显示回来时, 下一轮扫描/hook 再写一次 hidden=YES 即可,
   幂等、零副作用、不可能递归。 */
static NSMapTable<UIView *, NSNumber *> *gGainHidden(void) {
    static NSMapTable *t; static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSMapTable weakToStrongObjectsMapTable]; });
    return t;
}
static BOOL gGainBusy = NO;
static const NSUInteger kGainMax = 64;
static int gDIGainHitLogs = 0;    /* 3.0.20: "隐藏了哪些 platter" 只记前 8 条, 免得刷屏 */

static BOOL diGainIsSB(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}
/* 2.8.33: 黑层判定一分为二 ——
   ① diIsGainView: HDR 增益图(铺满整岛的那层黑底, rbp 原版目标);
   ② diIsPlatter: 展开态中间的暗色圆角"内容衬底"(毛玻璃底板)。
      302/303 截图实证: 增益图摘除后中间仍有一圈黑色圆角。
      2.8.33 曾按"精确 MTMaterialView"判定, 303 日志实锤错了:
      16:56:25 原有功能定位到 `platter 301x76 圆角 23.5`(diRestyleWalk 同款路径),
      它的类名命中 PlatterView/MediaControlsBackground 系列, 不是裸 MTMaterialView;
      且它不在 SBSystemApertureWindow 的 BFS 可达子树里(被 _UIPortalView
      空子树截断, 303 里 window 下只扫到 8 个节点)。
      2.8.34 修正: 类名改清单制(复用底包 diFindPlatter 的匹配精神),
      位置判定放宽为"与任一灵动岛宿主同窗且大幅相交", 扫描根扩到所有窗口。 */
static BOOL diIsGainView(UIView *v) {
    return v && [NSStringFromClass(object_getClass(v)) isEqualToString:@"_SBGainMapView"];
}
/* 3.0.19: 3×2 的"内容衬底"和传送栏/封面在同一棵子树里。把它当黑底板摘掉再插回,
   会让整条传送栏重排一次(430 日志实锤: 一次还原里 40 次 MRUTransportButton.setFrame)
   —— 这就是"按一下按钮就抖一下 / 展开返回也抖一下"。凡在 now-playing 模块里的层,
   隐藏药丸一律不摘: 黑底由 _SBGainMapView 那条路照旧处理, 不影响效果。 */
static BOOL diInNowPlayingUI(UIView *v) {
    for (UIView *p = v; p; p = p.superview) {
        NSString *cn = NSStringFromClass(object_getClass(p));
        if ([cn containsString:@"MRU"] || [cn containsString:@"NowPlaying"]
            || [cn containsString:@"MediaControls"] || [cn containsString:@"Transport"]) return YES;
    }
    return NO;
}
static BOOL diIsPlatter(UIView *v) {
    if (!v) return NO;
    if (diInNowPlayingUI(v)) return NO;
    NSString *cn = NSStringFromClass(object_getClass(v));
    BOOL nameHit = [cn containsString:@"PlatterView"]
                || [cn isEqualToString:@"PLPlatterView"]
                || [cn containsString:@"MediaControlsBackground"]
                || [cn containsString:@"ControlsBackgroundView"]
                || [cn containsString:@"MRUNowPlaying"]
                || [cn containsString:@"MaterialView"];
    if (!nameHit) return NO;
    CGRect f = v.frame;
    if (f.size.width < 60 || f.size.width > 540) return NO;
    if (f.size.height < 20 || f.size.height > 240) return NO;
    return YES;
}
static BOOL diGainIsExact(UIView *v) {
    return diIsGainView(v) || diIsPlatter(v);
}
static BOOL diGainInAperture(UIView *v) {
    Class ap = NSClassFromString(@"SBSystemApertureWindow");
    if (!ap || ![ap isSubclassOfClass:[UIWindow class]]) return NO;
    if ([v.window isKindOfClass:ap]) return YES;
    for (UIView *p = v.superview; p; p = p.superview)
        if ([p isKindOfClass:ap]) return YES;
    return NO;
}
/* 2.8.34: platter 的位置判定放宽 —— 它可能挂在 _UIPortalView 或别的窗口里,
   硬性要求"在灵动岛窗口内"会漏掉(303 实测)。改为: 与 hostTable 里任一
   灵动岛宿主(SAUIElementView 等)同窗口, 且 frame 大幅相交(>=35% 较小者面积)。
   锁屏通知卡(PLPlatterView)与灵动岛宿主不相交, 不会被误摘。 */
static BOOL diPlatterNearHost(UIView *v) {
    if (diGainInAperture(v)) return YES;
    if (!hostTable || !v.window) return NO;
    CGRect a = v.frame;
    for (UIView *h in hostTable) {
        if (!h.window || h.window != v.window) continue;
        CGRect b = h.frame;
        CGRect in = CGRectIntersection(a, b);
        if (CGRectIsEmpty(in)) continue;
        CGFloat ia = in.size.width * in.size.height;
        CGFloat ma = MIN(a.size.width * a.size.height, b.size.width * b.size.height);
        if (ma > 0 && ia / ma > 0.35) return YES;
    }
    return NO;
}
/* 2.9.11: 音量 HUD 在 iOS16 里就是"控制中心的一个内容模块", 挂在
   CCUIContentModuleContentContainerView 下面。这块底板绝对不能摘 ——
   摘了系统就收不回去, 表现就是"按了音量键音量条一直挂在屏上"。 */
static BOOL diInCCModule(UIView *v) {
    for (UIView *p = v.superview; p; p = p.superview) {
        NSString *cn = NSStringFromClass(p.class);
        if ([cn containsString:@"ContentModule"]) return YES;
    }
    return NO;
}
/* 隐藏一个层(只写 hidden) —— 幂等: 已经记过账就只确保它还是隐藏的 */
static void diGainHideOne(UIView *v) {
    if (!v) return;
    NSNumber *orig = [gGainHidden() objectForKey:v];
    if (orig) {
        if (!v.hidden) v.hidden = YES;      /* 系统又把它显示了 → 再压回去 */
        return;
    }
    [gGainHidden() setObject:@(v.hidden) forKey:v];
    v.hidden = YES;
}
static void diGainUnhide(UIView *v) {
    if (!v) return;
    NSNumber *orig = [gGainHidden() objectForKey:v];
    if (!orig) return;
    v.hidden = orig.boolValue;
    [gGainHidden() removeObjectForKey:v];
}
/* ===== 增益图(_SBGainMapView)是唯一例外: 必须真摘 =====
   它不是普通视图, 而是被 HDR 增益链路单独采样的图层 —— 只设 hidden 的话系统照样
   把它算进画面/录屏(2.8.31 实测)。好在它只挂在灵明岛药丸里、是叶子节点, 摘/插不会
   牵动传送栏/内容卡片, 所以照旧用"记账+摘除"。platter 一律走 hidden 那条路。 */
static NSMutableArray<DIGainMapState *> *gGainRemoved(void) {
    static NSMutableArray *a; static dispatch_once_t once;
    dispatch_once(&once, ^{ a = [NSMutableArray array]; });
    return a;
}
static void diGainRemovedRestore(DIGainMapState *s) {
    UIView *v = s.view, *parent = s.parent;
    [gGainRemoved() removeObjectIdenticalTo:s];
    if (!parent || v.superview || parent == v || [parent isDescendantOfView:v]) return;
    NSUInteger idx = MIN(s.index, parent.subviews.count);
    if (idx == 0) {
        UIView *first = parent.subviews.firstObject;
        if (first && first != v && [NSStringFromClass(first.class) hasPrefix:@"DI"]) idx = 1;
    }
    [parent insertSubview:v atIndex:idx];
}
/* 清理失效记账: 视图已经不在任何窗口上(系统整块重建了卡片) → 先还原再销账,
   免得它回到屏上时永远保持隐藏。 */
static void diGainPrune(void) {
    NSMutableArray<UIView *> *gone = [NSMutableArray array];
    for (UIView *k in gGainHidden()) if (!k.window) [gone addObject:k];
    for (UIView *k in gone) diGainUnhide(k);
    for (NSInteger i = (NSInteger)gGainRemoved().count - 1; i >= 0; i--) {
        DIGainMapState *s = gGainRemoved()[(NSUInteger)i];
        if (!s.parent || s.view.superview) [gGainRemoved() removeObjectAtIndex:(NSUInteger)i];
    }
}
static void diGainUnhideAll(void) {
    NSMutableArray<UIView *> *keys = [NSMutableArray array];
    for (UIView *k in gGainHidden()) [keys addObject:k];
    for (UIView *k in keys) diGainUnhide(k);
    while (gGainRemoved().count) diGainRemovedRestore(gGainRemoved().lastObject);
}
/* 某一窗口内的记账全部还原(展开态用) */
static void diGainUnhideInWindow(UIWindow *win) {
    if (!win) return;
    NSMutableArray<UIView *> *keys = [NSMutableArray array];
    for (UIView *k in gGainHidden()) if (k.window == win) [keys addObject:k];
    for (UIView *k in keys) diGainUnhide(k);
}
/* 2.8.38: 展开态判定 —— 307 实测: 展开的媒体岛(407x489 门户)和 DriftIsland
   展开页(DIVideoView 411x228)里, 内容衬底被摘就会"一闪一闪甚至整页黑";
   系统每帧重建这些层, hook 每帧再摘, 循环打地鼠。只有紧凑态(304 验证的
   黑圈场景, 宿主实测 125x37~350x77)才需要摘 platter。
   判据任一命中即判展开(0.5s 缓存, 展开动画期间连续布局也不重复扫):
     ① 同窗灵动岛宿主最大高度 > 140(紧凑态实测 <= 77, 系统展开 202+);
     ② 可见层类名含 ScenePresentation/LayerHost 门户系且宽 >= 380(媒体展开);
     ③ DriftIsland 自己的 DIVideoView 大层(>=300x150, 小岛层只有 189x56);
     ④ 兜底: 任意可见 UIView >=380x250 且 origin 非 (0,0)(407x489@-141,0)。 */
static BOOL diWindowExpanded(UIWindow *win) {
    if (!win) return NO;
    static NSMapTable *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMapTable weakToStrongObjectsMapTable]; });
    NSNumber *hit = [cache objectForKey:win];
    if (hit) return hit.boolValue;
    BOOL expanded = NO;
    if (hostTable) {
        CGFloat maxH = 0;
        for (UIView *h in hostTable) {
            if (!h.window || h.window != win) continue;
            if (h.frame.size.height > maxH) maxH = h.frame.size.height;
        }
        if (maxH > 140) expanded = YES;
    }
    if (!expanded) {
        NSMutableArray<UIView *> *stk = [NSMutableArray arrayWithObject:win];
        int g = 0;
        while (stk.count && g++ < 500) {
            UIView *v = stk.firstObject; [stk removeObjectAtIndex:0];
            if (v != win && !v.hidden && v.alpha > 0.01) {
                NSString *cn = NSStringFromClass(v.class);
                CGSize fs = v.frame.size;
                if (fs.width >= 380 && fs.height >= 250 &&
                    (v.frame.origin.x != 0 || v.frame.origin.y != 0)) { expanded = YES; break; }
                if (fs.width >= 380 &&
                    ([cn containsString:@"ScenePresentationView"] ||
                     [cn containsString:@"SceneLayerHostContainerView"] ||
                     [cn containsString:@"ScenePresenterView"])) { expanded = YES; break; }
                if (fs.width >= 300 && fs.height >= 150 &&
                    [cn hasPrefix:@"DI"]) { expanded = YES; break; }
            }
            for (UIView *s2 in v.subviews) [stk addObject:s2];
        }
    }
    [cache setObject:@(expanded) forKey:win];
    return expanded;
}
/* 2.8.38: 展开时把该窗口内已记账的 platter 还原 —— 展开页里这些衬底必须可见,
   否则会缺层/黑屏。3.0.20 起只是把 hidden 还原, 不动视图树。 */
static void diPlatterRestoreInWindow(UIWindow *win) {
    if (!win || gGainBusy || ![NSThread isMainThread] || !diGainIsSB()) return;
    gGainBusy = YES;
    @try { diGainPrune(); diGainUnhideInWindow(win); }
    @finally { gGainBusy = NO; }
}
/* rbp 的 applyToView:enabled —— enabled = hideBlackPillOn(隐藏药丸开关) */
static void diGainApply(UIView *view) {
    if (![NSThread isMainThread] || gGainBusy || !diGainIsSB()) return;
    if (!(enabled && hideBlackPillOn)) return;
    if (!diGainIsExact(view)) return;
    /* ---- ① 增益图: 照旧"记账 + 摘除"(它是被 HDR 链路单独采样的层, hidden 无效) ---- */
    if (diIsGainView(view)) {
        for (DIGainMapState *s in gGainRemoved()) if (s.view == view) return;
        UIView *parent = view.superview;
        if (!parent || !view.window) return;
        if (gGainRemoved().count >= 8) return;   /* 药丸上的增益图最多几个, 防跑飞 */
        NSUInteger idx = [parent.subviews indexOfObjectIdenticalTo:view];
        if (idx == NSNotFound) return;
        gGainBusy = YES;
        @try {
            DIGainMapState *s = [DIGainMapState new];
            s.view = view; s.parent = parent; s.index = idx;
            [gGainRemoved() addObject:s];
            [view removeFromSuperview];
            DLog(@"隐藏药丸: 摘除 _SBGainMapView (记账%lu)", (unsigned long)gGainRemoved().count);
        } @finally { gGainBusy = NO; }
        return;
    }
    /* ---- ② 内容衬底(platter): 只写 hidden, 一根手指都不碰视图树 ----
       3.0.19 的 now-playing 豁免继续保留: 3×2 / 4×2 卡片里的一切(传送栏、内容衬底、
       封面底座)一律不碰 —— 那是"按钮抖一下"的另一半来源。 */
    if (diInNowPlayingUI(view)) return;
    UIWindow *w = view.window;
    if (!w) return;
    if (diWindowExpanded(w)) return;        /* 展开态全部放过 */
    if (diInCCModule(view)) return;
    if (!diGainInAperture(view) && !diPlatterNearHost(view)) return;
    if (![gGainHidden() objectForKey:view] && gGainHidden().count >= kGainMax) return;
    gGainBusy = YES;
    @try {
        BOOL first = ([gGainHidden() objectForKey:view] == nil);
        diGainHideOne(view);
        if (first && gDIGainHitLogs < 8) {
            gDIGainHitLogs++;
            NSMutableString *chain = [NSMutableString string];
            for (UIView *p = view.superview; p && chain.length < 160; p = p.superview)
                [chain appendFormat:@"← %@", NSStringFromClass(p.class)];
            DLog(@"隐藏药丸: 隐藏 platter %@ %.0fx%.0f 父链%@ (记账%lu)",
                 NSStringFromClass(object_getClass(view)), view.bounds.size.width, view.bounds.size.height,
                 chain, (unsigned long)gGainHidden().count);
        }
    } @finally { gGainBusy = NO; }
}
void diGainRestoreAll(void) {
    if (![NSThread isMainThread] || gGainBusy || !diGainIsSB()) return;
    gGainBusy = YES;
    @try { diGainPrune(); diGainUnhideAll(); }
    @finally { gGainBusy = NO; }
}
/* 3.0.20: 这里以前是"对所有窗口 layoutIfNeeded" —— 在 iOS17 上会强制整棵控制中心
   同步重排一次(我们自己还挂在 layoutSubviews 钩子里), 是"拨个开关就卡死几十秒"
   的直接推手。现在隐藏只改 hidden, 调用方前面的主动扫描已经足够, 不再逼布局。 */
static void diGainTriggerVisible(void) {
    /* no-op (保留符号: 上层调用点不动) */
}

/* 2.8.33: 把灵动岛窗口前 24 个视图 dump 出来(类名+frame+alpha+hidden+背景色),
   每行 8 个, 9s 节流。用途: 万一黑圈既不是增益图也不是 platter, 日志里直接
   看到它的类名/尺寸/透明度, 下一版精准处理; 只有开关开着且扫描时才打,
   平时不增加日志量。走 RLog 不受日志开关控制。 */
static void diDumpApertureTree(UIView *root) {
    if (!root) return;
    static CFAbsoluteTime last;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 9.0) return;
    last = now;
    NSMutableArray<UIView *> *stk = [NSMutableArray arrayWithObject:root];
    NSMutableString *out = [NSMutableString string];
    int n = 0;
    while (stk.count && n < 24) {
        UIView *v = stk.firstObject; [stk removeObjectAtIndex:0];
        if (n && n % 8 == 0) {
            RLog(@"隐藏药丸: 视图树| %@", out);
            out = [NSMutableString string];
        }
        n++;
        [out appendFormat:@"%@ %@ a%.2f%@%@ | ",
         NSStringFromClass(v.class), NSStringFromCGRect(v.frame), (double)v.alpha,
         v.hidden ? @"H" : @"-", v.backgroundColor ? @"B" : @"-"];
        for (UIView *s in v.subviews) [stk addObject:s];
    }
    if (out.length) RLog(@"隐藏药丸: 视图树| %@", out);
}

/* 2.8.32: 开关打开(或 hook 刚装上)时, 主动扫一遍窗口树, 把**已在屏上**的
   黑块直接摘掉。layoutIfNeeded 只在视图有待重排需求时才触发 layoutSubviews,
   静态岛下是 no-op —— 不扫就要等下一次自然布局(可能永远等不到)。
   2.8.34: 扫描根从"只扫 SBSystemApertureWindow"扩到**所有窗口** ——
   303 实测该窗口子树被 _UIPortalView 空子树截断(只扫到 8 个节点),
   platter 根本不在那 8 个节点里; 原有功能的定位路径(diRestyleWalk)也是
   遍历所有窗口才找到 platter 301x76。 */
/* 3.0.25: 文件级定义(前向声明在文件头) —— 这里不再重复初始化 */
static void diGainScanAperture(void) {
    diPhase("scan");
    if (![NSThread isMainThread] || !(enabled && hideBlackPillOn)) return;
    /* 3.0.25(iOS17 首开卡死): 439 日志里首开那一串 [卡死] 阶段=scan, 一次扫描
       1205~1287 个节点, 而且同一秒里扫了好几遍(hook 装上一次、容器布局节流到了
       但别的路径还会直接调)。BFS 本身不贵, 但 24 个 platter 的 hidden 写回会逼
       控制中心面板重排 —— 首开那一秒所有初始化活都在主线程上排队, 叠加起来就是
       几秒的停摆。现在全局限频 1.5 秒; 拨开关的调用点置 gDIGainScanForce 立即跑。
       3.0.27: 注入后 10 秒内的非强制扫描直接跳过(441: 首装第一次必卡死注销,
       后面就正常 —— 首开那一波系统自己的初始化最重, 我们的扫描纯添乱),
       代价只是首装后头 10 秒黑药丸隐藏晚一点, 肉眼无感。 */
    {
        static CFAbsoluteTime firstCall = 0;
        CFAbsoluteTime now0 = CFAbsoluteTimeGetCurrent();
        if (firstCall == 0) firstCall = now0;
        if (!gDIGainScanForce && now0 - firstCall < 10.0) return;
    }
    {
        static CFAbsoluteTime lastScan = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (!gDIGainScanForce && now - lastScan < 1.5) return;
        gDIGainScanForce = NO;
        lastScan = now;
    }
    int gTotal = 0, hitG = 0, hitP = 0;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in ((UIWindowScene *)s).windows) {
            /* 2.8.38: 展开态窗口先救活已记账 platter, 再扫描(新层也不会被摘) */
            if (diWindowExpanded(win)) diPlatterRestoreInWindow(win);
            NSMutableArray<UIView *> *stk = [NSMutableArray arrayWithObject:win];
            int g = 0;
            while (stk.count && g++ < 600) {
                UIView *v = stk.firstObject; [stk removeObjectAtIndex:0];
                if (diIsGainView(v)) { diGainApply(v); hitG++; }
                else if (diIsPlatter(v)) { diGainApply(v); hitP++; }
                for (UIView *s2 in v.subviews) [stk addObject:s2];
            }
            gTotal += g;
        }
    }
    if (hitG || hitP) DLog(@"隐藏药丸: 主动扫描 %d 节点, 命中 增益图%d platter%d", gTotal, hitG, hitP);
    /* dump 仍只 dump 灵动岛窗口(紧凑态浅树, 展开态深树都可能被 portal 截断,
       真正的定位信息靠 platter 命中时的父链日志)。 */
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in ((UIWindowScene *)s).windows)
            if ([win isKindOfClass:NSClassFromString(@"SBSystemApertureWindow")]) { diDumpApertureTree(win); break; }
    }
}

/* ---- hook 两个布局回调(底包 MSHookMessageEx 模式, 与 2.8.23 其它私有类 hook 一致) ---- */
static void (*diOrigGainLayout)(id, SEL);
static void (*diOrigGainDMW)(id, SEL);
static void diGainLayoutHook(id self, SEL _cmd) {
    if (diOrigGainLayout) diOrigGainLayout(self, _cmd);
    diGainApply((UIView *)self);
}
static void diGainDMWHook(id self, SEL _cmd) {
    if (diOrigGainDMW) diOrigGainDMW(self, _cmd);
    diGainApply((UIView *)self);
}
/* 2.8.33: platter(MTMaterialView) 单独一套 hook 函数 —— orig 必须指向它自己的
   原生实现, 与增益图的 diOrigGainLayout 混用会调错原生方法。判定逻辑(diGainApply)
   共用: 非灵动岛内的 MTMaterialView 会在 diGainInAperture 秒退, 零副作用。 */
static void (*diOrigPlatterLayout)(id, SEL);
static void (*diOrigPlatterDMW)(id, SEL);
static void diPlatterLayoutHook(id self, SEL _cmd) {
    if (diOrigPlatterLayout) diOrigPlatterLayout(self, _cmd);
    diGainApply((UIView *)self);
}
static void diPlatterDMWHook(id self, SEL _cmd) {
    if (diOrigPlatterDMW) diOrigPlatterDMW(self, _cmd);
    diGainApply((UIView *)self);
}
/* 2.8.34: 灵动岛容器(收/展/形态切换都经它布局) —— platter 在展开态被系统重建,
   容器一布局就补扫一次(2s 节流, 展开动画连续布局也不刷屏)。
   2.8.38: 展开动画进行中改为**立即**(不节流)救活该窗口已记账 platter ——
   等 2s 节流会让展开页缺层/黑屏一瞬, 用户看到就是"一闪"。 */
static void (*diOrigContLayout)(id, SEL);
static void (*diOrigContDMW)(id, SEL);
static void diContMaybeScan(UIView *self) {
    if (![NSThread isMainThread] || !(enabled && hideBlackPillOn)) return;
    UIWindow *win = self.window;
    if (win && diWindowExpanded(win)) { diPlatterRestoreInWindow(win); return; }
    static CFAbsoluteTime last;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    /* 3.0.20: 2s → 4s。扫描本身已经不再动视图树(只是写 hidden), 但 1500 节点的 BFS
       在 iOS17 的控制中心里也要几毫秒, 少扫一半是纯赚 —— 新建的黑层有 layoutSubviews/
       didMoveToWindow 两个钩子兜住, 扫描只是补漏。 */
    if (now - last < 4.0) return;
    last = now;
    diGainScanAperture();
}
static void diContLayoutHook(id self, SEL _cmd) {
    if (diOrigContLayout) diOrigContLayout(self, _cmd);
    diContMaybeScan((UIView *)self);
}
static void diContDMWHook(id self, SEL _cmd) {
    if (diOrigContDMW) diOrigContDMW(self, _cmd);
    diContMaybeScan((UIView *)self);
}
static void diGainInstallHook(void) {
    /* 2.8.33: 两类黑层各自一个 done 标志 —— 私有类加载有先后, 任一类晚到时
       下次调用继续尝试; 已装过的绝不重复装(重复 MSHookMessageEx 会叠加 hook)。
       2.8.34: 增至三类(增益图 / platter / 灵动岛容器)。 */
    static BOOL doneG = NO, doneP = NO, doneC = NO;
    SEL lay = @selector(layoutSubviews), dmw = @selector(didMoveToWindow);

    if (!doneG) {
        Class c = NSClassFromString(@"_SBGainMapView");
        /* 私有类可能加载较晚: 跳过 gain 继续尝试另两类(installKnownHosts 分阶段重试),
           不能整个 return —— 否则 platter/容器 hook 会被一起卡住。 */
        if (c) {
            IMP oL = NULL, oD = NULL;
            MSHookMessageEx(c, lay, (IMP)diGainLayoutHook, &oL);
        diOrigGainLayout = (void (*)(id, SEL))oL;
        /* didMoveToWindow: 仅本类覆写才 hook, 否则跳过(避免误动 UIView 全局实现);
           未覆写时靠 layoutSubviews + 开关切换的 layoutIfNeeded 兜底, 效果一致。 */
        BOOL own = NO;
        unsigned int cnt = 0;
        Method *list = class_copyMethodList(c, &cnt);
        if (list) {
            for (unsigned int i = 0; i < cnt; i++) if (method_getName(list[i]) == dmw) { own = YES; break; }
            free(list);
        }
        if (own) {
            MSHookMessageEx(c, dmw, (IMP)diGainDMWHook, &oD);
            diOrigGainDMW = (void (*)(id, SEL))oD;
        }
        doneG = YES;
        DLog(@"隐藏药丸: hook 就位 _SBGainMapView (layoutSubviews=%@ didMoveToWindow=%@)",
             oL ? @"是" : @"否", own ? @"是" : @"否(本类未覆写, 跳过)");
        /* 私有类可能到这时才加载(已有岛在屏): 装上立刻补扫一次, 不等下一次布局 */
        if (enabled && hideBlackPillOn) diGainScanAperture();
        }
    }

    /* 2.8.33: 再给 platter(MTMaterialView) 装 layoutSubviews/didMoveToWindow。
       展开态中间的暗色圆角背景(302 截图残留的黑圈)不是增益图, 是 MTMaterialView;
       rbp 原版只处理增益图, 这里用同一套"记账摘除"手法扩展到它。
       didMoveToWindow 同样只在本类覆写时才装。 */
    if (!doneP) {
        Class mc = NSClassFromString(@"MTMaterialView");
        if (mc) {
            IMP oL2 = NULL, oD2 = NULL;
            MSHookMessageEx(mc, lay, (IMP)diPlatterLayoutHook, &oL2);
            diOrigPlatterLayout = (void (*)(id, SEL))oL2;
            BOOL own2 = NO;
            unsigned int cnt2 = 0;
            Method *list2 = class_copyMethodList(mc, &cnt2);
            if (list2) {
                for (unsigned int i = 0; i < cnt2; i++) if (method_getName(list2[i]) == dmw) { own2 = YES; break; }
                free(list2);
            }
            if (own2) {
                MSHookMessageEx(mc, dmw, (IMP)diPlatterDMWHook, &oD2);
                diOrigPlatterDMW = (void (*)(id, SEL))oD2;
            }
            doneP = YES;
            DLog(@"隐藏药丸: hook 就位 MTMaterialView (layoutSubviews=%@ didMoveToWindow=%@)",
                 oL2 ? @"是" : @"否", own2 ? @"是" : @"否(本类未覆写, 跳过)");
        }
    }

    /* 2.8.34: 灵动岛容器布局 hook —— 303 实测 platter 不在 window BFS 可达子树,
       也不一定是 MTMaterialView 裸类, 类名清单+全窗口扫描才是可靠定位;
       容器 hook 负责"形态一切换立刻补扫", 周期扫描负责兜底。 */
    if (!doneC) {
        Class cc = NSClassFromString(@"SBSystemApertureContainerView");
        if (cc) {
            IMP oL3 = NULL, oD3 = NULL;
            MSHookMessageEx(cc, lay, (IMP)diContLayoutHook, &oL3);
            diOrigContLayout = (void (*)(id, SEL))oL3;
            BOOL own3 = NO;
            unsigned int cnt3 = 0;
            Method *list3 = class_copyMethodList(cc, &cnt3);
            if (list3) {
                for (unsigned int i = 0; i < cnt3; i++) if (method_getName(list3[i]) == dmw) { own3 = YES; break; }
                free(list3);
            }
            if (own3) {
                MSHookMessageEx(cc, dmw, (IMP)diContDMWHook, &oD3);
                diOrigContDMW = (void (*)(id, SEL))oD3;
            }
            doneC = YES;
            DLog(@"隐藏药丸: hook 就位 SBSystemApertureContainerView (layoutSubviews=%@ didMoveToWindow=%@)",
                 oL3 ? @"是" : @"否", own3 ? @"是" : @"否(本类未覆写, 跳过)");
        }
    }
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

/* 2.8.48: 解锁即预载两层素材 —— 用户反馈"注销后通知岛/展开岛没素材, 要放一次
   歌曲才有"。根因: 视频层要等岛出现才 loadVideo(建播放器+剥音轨+首帧解码
   有耗时), 展开层更是只挂音乐岛。现在解锁/启动后就把小岛+展开两层素材预加载
   好(播放器/循环建好、暂停待命), 岛一出现直接挂上即播, 不需要放歌触发。
   锁屏期间不预载(gLocked=YES 直接返回), 功耗策略不变。 */
static void diPreloadIslandVideos(void) {
    if (!enabled || gLocked) return;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            /* 只预载岛窗口(灵动岛/通知岛都住 SBSystemApertureWindow) —— 避免给
               状态栏/控制中心等无关窗口各建一套播放器, 白占内存和解码 */
            if (![NSStringFromClass(w.class) containsString:@"SystemAperture"]) continue;
            DIVideoView *smallV = objc_getAssociatedObject(w, &kWinVideoSmall);
            DIVideoView *expandV = objc_getAssociatedObject(w, &kWinVideoExpand);
            if (!smallV) {
                smallV = [[DIVideoView alloc] initWithFrame:CGRectZero];
                smallV.expandedLayer = NO;
                smallV.hidden = YES;
                objc_setAssociatedObject(w, &kWinVideoSmall, smallV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (!expandV) {
                expandV = [[DIVideoView alloc] initWithFrame:CGRectZero];
                expandV.expandedLayer = YES;
                expandV.hidden = YES;
                objc_setAssociatedObject(w, &kWinVideoExpand, expandV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            for (DIVideoView *v in diLayers(smallV, expandV)) {
                NSString *mp = materialPathFor(v.expandedLayer);
                if (!mp.length) continue;
                if ([mp isEqualToString:v.currentPath]) continue;   // 已就绪
                [v loadVideo:mp];
                [v.player pause];
                /* loadVideo 尾部有个 dispatch_async 延迟补播, 会在下一轮 runloop 再 play 一次;
                   预载层没挂岛, displayLink 已自停不会有人再停它 → 0.3s 后补一刀暂停,
                   压住那个延迟补播(挂上岛后 want 逻辑会重新 play, 不影响正常显示)。 */
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    __weak DIVideoView *wv = v;
                    if (wv && !wv.superview && wv.player.timeControlStatus != AVPlayerTimeControlStatusPaused)
                        [wv.player pause];
                });
                if (!v.hidden) v.hidden = YES;
                DLog(@"[解锁预载] %@素材已就绪: %@", v.expandedLayer ? @"展开" : @"小岛", mp.lastPathComponent);
            }
        }
    }
}

static void updateSingleVideo(UIWindow *win) {
    if (!win) return;
    diRefreshContour();
    DIVideoView *smallV = objc_getAssociatedObject(win, &kWinVideoSmall);
    DIVideoView *expandV = objc_getAssociatedObject(win, &kWinVideoExpand);

    /* 2.9.23: 录屏指示岛要在下面的宿主统计里排掉, 否则小岛素材会挂到
       30~45pt 的方岛上, 把录屏圆点盖住。 */
    UIView *recHostNow = nil;
    /* 2.9.13: 录屏素材层先处理 —— 它挂在独立的"方形录屏指示岛"上, 与小岛胶囊无关。
       放在函数最前面, 避免后面选主为空时提前 return 导致这条路永远走不到。 */
    {
        DIVideoView *recV = objc_getAssociatedObject(win, &kWinVideoRec);
        if (!recV) {
            recV = [[DIVideoView alloc] initWithFrame:CGRectZero];
            recV.circleLayer = YES;
            recV.hidden = YES;
            objc_setAssociatedObject(win, &kWinVideoRec, recV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        UIView *recHost = enabled ? diRecIslandHost() : nil;
        recHostNow = recHost;
        if (recHost && recHost.window == win) {
            if (recV.superview != recHost) {
                [recV removeFromSuperview];
                /* 2.2.56: 垫到指示岛最底层(原生圆点靠"隐藏它的 layer"让位, 不依赖层级) */
                [recHost insertSubview:recV atIndex:0];
                recHost.clipsToBounds = NO;
                static BOOL loggedMount;
                if (!loggedMount) {
                    loggedMount = YES;
                    DLog(@"录屏素材层挂载到指示岛(最底层) %@ %.0fx%.0f",
                         NSStringFromClass(recHost.class), recHost.bounds.size.width, recHost.bounds.size.height);
                }
            }
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
    /* ===== 2.8.21: 选主稳定化 =====
       291 反馈: "充电岛也是有些隐藏了""通知的岛背景也会一闪一闪的"。
       根因: 多岛并存(音乐+通知+音量+充电)时 hostTable 是 NSHashTable,
       枚举顺序不稳定, 旧代码"碰到第一个 SBSystemApertureContainerView 就 break",
       每轮(0.25s)可能 break 到不同容器 → 视频/素材/遮罩玻璃在几个岛之间
       搬来搬去(removeFromSuperview + addSubview), 用户看到的就是
       通知岛背景一闪一闪、充电岛视频时有时无("有些隐藏")。
       2.9.15: 现在只剩一个宿主 matRoot = 正在播放的音乐岛, 视频层与素材层都只跟它,
       不再有"最新岛/面积最大岛"这些会漂到通知、充电、来电岛上的分支。 */
    /* 2.9.15: 视频层也只认音乐岛 —— 359 反馈"录屏停止的通知右侧被一块东西挡住"。
       2.8.22 把小岛层挂到"最新出现的岛"(人脸/充电/来电/通知都有份), 于是通知横幅一出现
       就被小岛素材整块铺上, 通知的图标和文字全被盖掉。现在两层都只跟音乐岛
       (matRoot, 已含暂停粘滞); 其他岛 100% 原生, 我们一个像素都不碰。 */
    /* 2.9.15: 视频层也只认音乐岛 —— 359 反馈"录屏停止的通知右侧被一块东西挡住"。
       2.8.22 把小岛层挂到"最新出现的岛"(人脸/充电/来电/通知都有份), 于是通知横幅一出现
       就被小岛素材整块铺上, 通知的图标和文字全被盖掉。现在两层都只跟音乐岛
       (matRoot, 已含暂停粘滞); 其他岛 100% 原生, 我们一个像素都不碰。 */
    /* 2.9.23: 恢复 2.8.78 的宿主统计 —— 2.9.15 为修"通知被遮挡"把这里砍成只认音乐岛,
       结果人脸/充电/退出 App 返回时的岛都没有背景素材了(2.9.16 回退时漏了这一段)。
       现在: 音乐岛管素材(matRoot), 小岛视频层按"最新出现的岛"挑(bestRoot),
       人脸/充电/来电/通知都能拿到背景; 通知可用设置里的"通知背景"开关关掉。 */
    UIView *musicRoot = nil, *newestRoot = nil, *bigRoot = nil, *stickyAlive = nil;
    UIView *musicRootVis = nil;   /* 2.9.61: 可见的音乐岛(形态播报专用) */
    static __weak UIView *sStickyRoot;
    CFAbsoluteTime newestT = 0;
    CGFloat bestA = 0;
    for (UIView *h in hostTable) {
        if (h.window != win || h.isHidden) continue; // 不看 alpha: 岛淡入淡出期间仍要贴合
        if (h.bounds.size.width < 2 || h.bounds.size.height < 2) continue;
        if (recHostNow && h == recHostNow) continue;  // 录屏方岛: 素材归 recV, 小岛层不碰
        if (notifyBgOff) {
            BOOL notif = [objc_getAssociatedObject(h, &kHostIsNotif) boolValue];
            if (!notif) notif = diHostLooksLikeNotification(h, NULL); // 兜底: 通知样式还没跑过
            if (notif) continue;
        }
        UIView *root = islandRoot(h);
        if (!root) continue;
        if (diIsNowPlayingHostCached(root)) {
            if (!musicRoot) musicRoot = root;
            /* 2.9.61: 同一窗口里可能有两组音乐岛容器 —— 可见的那块 + 离屏残留
               (alpha=0 portal 里的 407x198)。播报只认可见那块, 否则 island.plist
               随枚举顺序在 189x37 与 407x197 之间翻面。 */
            if (!musicRootVis && diContainerVisiblyShown(root)) musicRootVis = root;
        }
        if (root == sStickyRoot) stickyAlive = root;
        NSNumber *seen = objc_getAssociatedObject(h, &kHostSeenT);
        CFAbsoluteTime t = seen ? [seen doubleValue] : 0;
        if (t > newestT) { newestT = t; newestRoot = root; }
        CGFloat a = root.bounds.size.width * root.bounds.size.height;
        if (a > bestA) { bestA = a; bigRoot = root; }
    }
    UIView *matRoot = musicRoot;                                    /* 素材: 只跟音乐岛 */
    /* 2.8.39: 音乐岛瞬断/暂停**粘滞**(308: "展开背景有时候暂停, 播放完就黑屏")。
       根因: 切歌/暂停时 diIsNowPlayingHostCached 断或系统 MediaRemote 报未播放,
       matRoot 置 nil → expandV 被 pause+hidden, 恢复后又重挂, 用户看到
       "暂停一下/黑一下"。背景素材是 DriftIsland 自己的循环视频, 不该跟着
       系统播放状态反复起停 —— 只要**宿主岛还活着**(还在窗口/树上)就一路用,
       只有岛真的消失(切 App/锁屏音乐岛注销)才撤。 */
    static __weak UIView *sStickyMat;
    if (matRoot) {
        sStickyMat = matRoot;
    } else if (sStickyMat && sStickyMat.window == win && sStickyMat.superview) {
        matRoot = sStickyMat;   /* 暂停/切歌/门户重建: 保持原宿主, 素材不断 */
    } else {
        sStickyMat = nil;
    }
    UIView *bestRoot = newestRoot ?: musicRoot ?: (stickyAlive ?: bigRoot);  /* 视频: 最新岛优先 */
    /* 2.8.39: 视频宿主切换宽限 —— smallV 已挂的 root 还活着就别搬
       (removeFromSuperview + insertSubview = 黑一下, 308 "循环播放会黑一下")。
       新 root 只是"更新"(hostTable 枚举顺序/新岛出现)时保持旧的, 2s 宽限。 */
    static __weak UIView *sVideoRoot; static CFAbsoluteTime sVideoT = 0;
    if (bestRoot != sVideoRoot && sVideoRoot && sVideoRoot.window == win && sVideoRoot.superview) {
        if (sVideoT == 0) sVideoT = CFAbsoluteTimeGetCurrent();
        if (CFAbsoluteTimeGetCurrent() - sVideoT < 2.0) bestRoot = sVideoRoot;
        else sVideoT = 0;
    } else {
        sVideoRoot = bestRoot; sVideoT = 0;
    }
    sStickyRoot = bestRoot;
    /* ===== 2.9.55: 17 专用通道 —— 宿主尺寸由 SpringBoard 播报 =====
       17 上 SpringBoard 的遮罩探针整体让位(2.9.47), 没有任何人写 island.plist,
       MRU 只能按头像自己的 bounds 猜形态 —— 展开残留的 66x66 会一直被当成"展开",
       用户看到的就是"切换下一首放大就回不去"。
       这里借已经常驻的宿主扫描把真实尺寸写过去(只 17 执行, 16 一行不加)。 */
    if (diIsIOS17Up()) {
        /* 2.9.61: 播报只认"可见的音乐岛"。旧代码 musicRoot ?: bestRoot 会命中
           离屏残留容器(hostTable 枚举顺序不定), 把 island.plist 翻成"展开":
           展开确认期被打断(展开有时生效)、小岛态被写成展开(缩回变大)。
           找不到可见音乐岛就干脆不写盘, 让旧值自然过期(3 秒) → MRU 按无信号处理。 */
        UIView *pubHost = musicRootVis;
        /* 2.9.66: 暂停粘滞播报 —— 暂停/切歌瞬断时 diIsNowPlayingHostCached 会断开,
           musicRootVis 变 nil, 播报整个停摆, island.plist 停在最后一次的"展开"。
           MRU 读到假展开就一直按 66 铺大玻璃(397: 暂停后小岛 189x37, MRU 仍
           apply 66x66 → 用户"暂停专辑变大")。这里记住上一次可见的音乐岛,
           只要它还活着就继续按它的真实尺寸播报(仅限小岛尺寸, 通知/充电岛不会进来)。 */
        static __weak UIView *sPubHost;
        if (pubHost) {
            sPubHost = pubHost;
        } else if (sPubHost && sPubHost.window == win && !sPubHost.isHidden) {
            CGSize ss = sPubHost.bounds.size;
            if (ss.height >= 24 && ss.height <= 70 && ss.width >= 100 && ss.width <= 236) pubHost = sPubHost;
            else sPubHost = nil;
        }
        if (pubHost) {
            CGSize ps = pubHost.bounds.size;
            /* 2.9.66: 宽度上限按播放态分开 —— 暂停形变会把小岛加宽到 220(播放键换成
               暂停键), 播放中的展开起手不能跟着放宽, 否则展开又会被当小岛。 */
            BOOL playingPub = mrQueryOK ? musicPlaying
                                         : AVAudioSession.sharedInstance.isOtherAudioPlaying;
            BOOL pMini = (ps.height >= 24 && ps.height <= 62
                          && ps.width >= 100 && ps.width <= (playingPub ? 208.0 : 236.0)
                          && ps.width > ps.height * 1.55);
            BOOL pExp = (ps.height >= 120 && ps.height <= 300
                         && ps.width >= 280 && ps.width <= 440);
            diPublishIslandState(ps, pMini, pExp);
        }
    }
    /* 2.9.23 诊断: 宿主切换打一条, 下一份日志能直接确认人脸/充电岛有没有拿到层 */
    {
        static __weak UIView *sLoggedBest;
        if (bestRoot != sLoggedBest) {
            sLoggedBest = bestRoot;
            DLog(@"[小岛视频] 宿主=%@ %.0fx%.0f (最新岛=%@ 音乐岛=%@ 兜底大岛=%@)",
                 bestRoot ? NSStringFromClass(bestRoot.class) : @"无",
                 bestRoot.bounds.size.width, bestRoot.bounds.size.height,
                 newestRoot ? @"是" : @"否", musicRoot ? @"是" : @"否", bigRoot ? @"是" : @"否");
        }
    }
    if (!bestRoot && !matRoot) {
        for (DIVideoView *v in diLayers(smallV, expandV)) {
            if (v && !v.hidden) { v.hidden = YES; if (v.player.timeControlStatus != AVPlayerTimeControlStatusPaused) [v.player pause]; }
        }
        return;
    }

    /* ===== 2.8.19~2.8.22: 分层挂载规则 =====
       289 反馈: "充电的界面你不要去遮挡, 把我充电原有的背景跟显示都没了"、
       "展开岛你做的那个遮挡在电话界面走显示了"、"不让小岛的东西在其他岛显示"。
       根因: 早期版本按"窗口里最大的岛"挑宿主, 来电卡片 / 充电岛 / 展开通知岛
       全都会被选中, 于是视频层、帧率素材层、遮罩玻璃被一起搬过去 ——
       来电那张卡片就被素材整块铺满, 充电岛的原生背景也没了。
       现在拆成两层, 各挂各的宿主(matRoot=音乐岛, bestRoot=最新出现的岛):
         · 小岛背景视频(smallV) → bestRoot: 人脸/充电/来电/通知都有份;
         · 展开素材(expandV) → matRoot: 只给确认的音乐岛(来电/充电的展开卡片
           是 330x72/430x360, 素材一铺就整块盖住, 必须挡);
         · 遮罩玻璃 / 左右帧率素材 / 展开频谱素材 / 原生门户隐藏 → matRoot:
           与 2.8.19 闸门一致, 音乐岛判定用结构特征(左专辑门户+右音频门户),
           来电/充电/通知/音量岛结构完全不符, 一律清场, 100% 原生。 */
    BOOL musicHost = (matRoot != nil);   /* 2.8.22: 素材闸门 = 有没有在放歌的音乐岛 */
    if (!smallV) {
        smallV = [[DIVideoView alloc] initWithFrame:(bestRoot ?: matRoot).bounds];
        smallV.expandedLayer = NO;
        objc_setAssociatedObject(win, &kWinVideoSmall, smallV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!expandV) {
        expandV = [[DIVideoView alloc] initWithFrame:(bestRoot ?: matRoot).bounds];
        expandV.expandedLayer = YES;
        objc_setAssociatedObject(win, &kWinVideoExpand, expandV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (DIVideoView *v in diLayers(smallV, expandV)) {
        if (!v) continue;
        /* ===== 2.8.22: 两层各挂各的宿主 =====
           292 反馈"人脸解锁 充电岛背景不显示": 放歌时人脸/充电岛后出现,
           旧逻辑整个 bestRoot 被音乐岛占据, 视频层全在音乐岛上。
           现在: 小岛背景视频(smallV)挂 videoRoot(最新出现的岛, 人脸/充电/
           来电/通知都有份); 展开素材(expandV)仍只给确认的音乐岛(matRoot)。 */
        UIView *target = v.expandedLayer ? matRoot : bestRoot;
        BOOL allow = v.expandedLayer ? (matRoot != nil) : YES;
        if (!allow || !target) {
            if (!v.hidden) v.hidden = YES;
            if (v.player.timeControlStatus != AVPlayerTimeControlStatusPaused) [v.player pause];
            continue;
        }
        if (v.superview != target) {
            [v removeFromSuperview];
            [target insertSubview:v atIndex:0]; // 垫到底层: 文字/图标都在视频之上
            target.clipsToBounds = YES;
            v.frame = target.bounds; // 仅挂载时设初始尺寸; 动画中交给 displayLink
            v.layer.cornerRadius = target.layer.cornerRadius;
            /* 2.8.22: 素材没变就不重载 —— 换岛(音乐岛→充电岛→音乐岛)时旧代码
               整个重建 player item, 背景视频会黑一下再从头播。同路径直接沿用。 */
            NSString *mp = materialPathFor(v.expandedLayer);
            if (![mp isEqualToString:v.currentPath]) [v loadVideo:mp];
            DLog(@"挂载视频层(%@) container=%@ frame=%@ 素材=%@", v.expandedLayer ? @"展开" : @"小岛", NSStringFromClass(target.class), NSStringFromCGRect(target.bounds), mp ?: @"(无)");
        }
        // 关键: 动画进行中不设 frame(打架会闪黑); 仅在暂停唤醒瞬间手动对齐一次
        wakeLayer(v, target);
        if (target.subviews.firstObject != v) [target sendSubviewToBack:v];
    }
    // 展开态: dump 跨进程 CALayer 层树(频谱动画在这里渲染), 2s 后再抓一次布局稳定版; 30s 窗口后重新计数
    static int dumpCount; static CFAbsoluteTime dumpStart;
    CFAbsoluteTime nowT = CFAbsoluteTimeGetCurrent();
    if (dumpStart == 0 || nowT - dumpStart > 30) { dumpCount = 0; dumpStart = nowT; }
    if (0 && dumpCount < 1 && bestRoot.bounds.size.height > 60) {  /* 2.8.20 功耗: 生产版关闭全层树 dump(每 30s 一次巨量 CPU+日志 IO) */
        dumpCount++;
        __weak UIView *wr = bestRoot;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (wr && wr.bounds.size.height > 60) {
                DLog(@"===== 岛胶囊 CALayer 层树 dump (展开稳定后) =====");
                dumpLayers(wr.layer, 0);
            }
        });
    }
    /* 2.7.29: 岛全量图层调试日志(开关打开才抓, 内部限频 4s/最多 12 次)。
       收缩态也要抓 —— 专辑遮罩只在小岛生效, 不知道收缩态长什么样就没法排查。 */
    // 频谱帧率动画层: 序列帧播放, 盖在展开岛右上角(跨进程频谱上方), 加在最顶层
    // 开关关/无帧素材: 隐藏本层 → 露出系统频谱(关闭=显示原生频谱)
    DIAnimView *animV = objc_getAssociatedObject(win, &kWinVideoSpec);
    if (!animV) {
        animV = [[DIAnimView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(win, &kWinVideoSpec, animV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        static BOOL logged;
        if (!logged) { logged = YES; DLog(@"帧率动画层创建, 帧素材=%lu 张 (目录 %@)", (unsigned long)framePaths().count, kFrameDir); }
    }
    if (!musicHost) {
        /* 2.8.19: 非音乐岛(来电/充电/通知)不挂帧率素材层, 已有的一并撤掉 */
        if (animV.superview) [animV removeFromSuperview];
        if (!animV.hidden) animV.hidden = YES;
        animV.link.paused = YES;
    } else {
    if (animV.superview != matRoot) {
        [animV removeFromSuperview];
        [matRoot addSubview:animV]; // 最顶层: 盖住跨进程频谱
        animV.hidden = YES;
    }
    [matRoot bringSubviewToFront:animV]; // 系统布局会把岛内容分支提到最前, 每轮重申动画层在最顶
    }

    /* ---- 2.7.26: 歌词岛两层(2.2.45 原版挂载) 左=专辑位 side0, 右=音频位 side1 ----
       2.7.0 把这两层连同 mini 系列参数一起删了, 设置页的"左侧专辑/右侧音频"开关
       从此没有任何代码去读 —— 这就是用户说的"左右帧率开关都失效"。 */
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
    /* 2.9.15: 闸门回到"是不是音乐岛"这一个判据。
       2.9.14 加的尺寸白名单反而把右侧素材自己挡死了: 小岛的音频位经常单独挂在
       37x37 的 accessory 容器上(359 日志有 SBSystemApertureContainerView 36.67x36.67
       @285.67), 宽 37 < 100 被判成"非小岛" → 左右两层每轮都被撤掉, 用户看到的就是
       "小岛右侧的素材都不显示了"。通知岛的问题改用"视频层只挂音乐岛"根治。 */
    BOOL cleanMusic = musicHost;
    for (DIAnimView *mv in @[miniAnim, miniAudio]) {
        /* 2.8.19: 非音乐岛(来电/充电/通知)不挂歌词岛的两层帧率素材 */
        if (!enabled || gRecordingActive || !cleanMusic) {
            if (mv.superview) { [mv removeFromSuperview]; mv.hidden = YES; }
            if (mv.iv.image) mv.iv.image = nil;
            mv.link.paused = YES;
            continue;
        }
        if (mv.superview != matRoot) {
            [mv removeFromSuperview];
            [matRoot addSubview:mv];
            mv.hidden = YES;
            mv.iv.image = nil;
        }
        mv.link.paused = NO;
    }

    /* ---- 2.7.26: 小岛左右原生内容层(专辑/波形)按需隐藏 ----
       帧率素材要盖在原生内容上, 所以对应那一侧的跨进程层必须先藏掉。
       判据: 层的中心 x 在宿主中线哪一侧。只认音乐岛(充电/人脸等岛一律不动)。
       2.8.21 三处修正(291 反馈"打开左侧专辑就整个隐藏了""通知岛背景一闪一闪"):
        ① 闸门从 diMiniMusicActive 改成 musicHost(本函数已算好的音乐岛判定) ——
           diMiniMusicActive 只查"树里有大跨进程层 + 在播", 通知岛的内容门户
           画布也很大, 会被误判成音乐岛, 右侧内容层被藏 → 通知岛一闪一闪;
        ② 藏层必须登记到 gDiOurHiddenLayers(diViewHasVisiblePortal 认登记层为可见) ——
           否则藏掉左专辑门户层后音乐岛判定连锁失败, musicHost=NO, 左右素材
           被一起撤掉, 整个岛空白(死锁);
        ③ 只藏"附件级"小门户(≤64pt) —— 407x489 的跨进程 scene 层里画着整个岛的
           内容(专辑+波形+歌词), 旧代码按左右半边把它也藏了, 同样整岛空白。 */
    {
        static char kHiddenPortals;
        NSMutableArray *found = objc_getAssociatedObject(win, &kHiddenPortals) ?: [NSMutableArray array];
        BOOL wantL = cleanMusic && miniAnimOn && miniAnim.superview && !miniAnim.hidden;
        BOOL wantR = cleanMusic && miniAudioOn && miniAudio.superview && !miniAudio.hidden;
        for (CALayer *l in found) {
            if (l.isHidden) l.hidden = NO;
            diUnmarkLayerHiddenByUs(l);   /* 还原后注销登记: 判定不再把它当可见 */
        }
        if (found.count) [found removeAllObjects];
        if (wantL || wantR) {
            CGFloat halfW = matRoot.bounds.size.width * 0.5;
            NSMutableArray<CALayer *> *stack = [NSMutableArray arrayWithObject:matRoot.layer];
            int guard = 0;
            while (stack.count && guard++ < 300) {
                CALayer *l = stack.firstObject; [stack removeObjectAtIndex:0];
                NSString *cn = NSStringFromClass(l.class);
                BOOL isPortal = [cn containsString:@"CAPortalLayer"] || [cn containsString:@"CALayerHost"];
                if (isPortal && l.bounds.size.width <= 64.0 && l.bounds.size.height <= 64.0) {
                    CGRect r = [matRoot.layer convertRect:l.bounds fromLayer:l];
                    BOOL isAudioSide = (CGRectGetMidX(r) >= halfW);
                    if ((isAudioSide && wantR) || (!isAudioSide && wantL)) {
                        if (!l.isHidden) {
                            l.hidden = YES;
                            diMarkLayerHiddenByUs(l);
                            static CFAbsoluteTime sPhT;
                            if (CFAbsoluteTimeGetCurrent() - sPhT > 4.0) {
                                sPhT = CFAbsoluteTimeGetCurrent();
                                DLog(@"专辑遮罩藏原生门户层: %@ %.0fx%.0f 侧=%@ (岛 %.0fx%.0f)",
                                     cn, l.bounds.size.width, l.bounds.size.height,
                                     isAudioSide ? @"右" : @"左",
                                     matRoot.bounds.size.width, matRoot.bounds.size.height);
                            }
                        }
                        [found addObject:l];
                    }
                }
                for (CALayer *s2 in l.sublayers) [stack addObject:s2];
            }
        }
        objc_setAssociatedObject(win, &kHiddenPortals, found, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    /* 2.6.16: 遮罩层挂载 —— 只做最普通的 addSubview, 不再手动搬 layer。
       v2.6.15 之前的写法是:
           [maskV.layer removeFromSuperlayer];
           [bestRoot.layer insertSublayer:maskV.layer below:albumLayer];
           [bestRoot bringSubviewToFront:maskV];   // 这句又把 layer 挪回去
           [bestRoot sendSubviewToBack:maskV];
       把 UIView 的 layer 手动移出再插入, UIKit 的 subview 索引表就和 layer 树错位了,
       系统下一次布局摸到野指针 → SpringBoard 崩 → 安全模式。这就是"触发安全模式"的根因。
       现在遮罩用普通视图层级(封面图 + maskView), 放在岛容器里最底层即可, 不需要任何 layer hack。 */
    /* 2.6.33: 遮罩探针 —— 只作为"挂在岛容器里的一根天线", 自己不画任何东西。
       真正的蒙版由 DIMaskView.step 以 CALayer 形式挂到原生专辑图层上(albumLayer.mask)。
       这里绝不做 addSubview 之外的任何层级操作, 也绝不 bringSubviewToFront。 */
    static char kWinMask;
    DIMaskView *maskV = objc_getAssociatedObject(win, &kWinMask);
    if (!maskV) {
        maskV = [[DIMaskView alloc] initWithFrame:CGRectZero];
        maskV.hidden = YES;
        objc_setAssociatedObject(win, &kWinMask, maskV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    /* 2.6.39: 遮罩只覆盖"小岛左侧专辑"那一块 (0,0,h,h), 自己算自己的 frame。
       挂载只做最普通 addSubview + 顶到最上 —— 因为这块玻璃本身就是"专辑的替代品",
       原生专辑被它整个盖住(玻璃内部是不透明的专辑画面), 所以不会出现两份。 */
    /* 2.8.19: 遮罩探针只允许挂在"音乐小岛"上。
       展开岛 / 来电 / 充电 / 通知 一律不挂 —— 之前这个探针按 window 复用、
       跟着 bestRoot 搬来搬去, 上一块玻璃(专辑画面+遮罩)会被原地搬到来电卡片上,
       就是用户 289 说的"展开岛你做的那个遮挡在电话界面走显示了"。
       2.8.22: 探针跟着 matRoot(音乐岛)走, 与"视频挂最新岛"彻底解耦。 */
    /* 2.8.57: 展开态封面实际在跨进程 CALayerHost 内；当前探针只认
       26x22 accessory，会额外叠一张小专辑。未找到真实大专辑前不挂展开探针。 */
    BOOL maskHost = musicHost && matRoot.bounds.size.width <= 240.0
        && matRoot.bounds.size.height <= 62.0;
    if (!maskHost) {
        /* 只隐藏、不 removeFromSuperview —— 拆了 superview 后探针会在下一帧
           判定"宿主没了"而整体 teardown, 把小岛那份缓存(封面/方块/尺寸)一起清掉,
           缩回小岛就得重新扫描两帧, 又会出现一次"方形 → 遮罩"。hidden 的视图
           在任何宿主上都不会画出来, 留着反而能让缩回时第一帧直接按缓存画回去。 */
        if (!maskV.hidden) maskV.hidden = YES;
        maskV.link.paused = YES;
    } else {
    if (maskV.superview != matRoot) {
        [maskV removeFromSuperview];
        [matRoot addSubview:maskV];
        maskV.hidden = YES;
    }
    /* 2.8.21: 玻璃和「左侧专辑」帧率素材都占专辑位。素材开着的时候玻璃让到素材
       下面 —— 否则不透明的玻璃会把素材整个盖住(用户开左侧专辑动画看不到素材)。
       素材不透明 → 素材赢; 素材半透明 → 两者叠加。step 里的 bringSubviewToFront
       有同样的让步(见 DIMaskView.step), 两边保持一致才不会被顶乱。 */
    if (miniAnimOn && miniAnim.superview == matRoot && maskV.superview == matRoot) {
        NSUInteger mi = [matRoot.subviews indexOfObject:miniAnim];
        NSUInteger gi = [matRoot.subviews indexOfObject:maskV];
        if (gi != NSNotFound && mi != NSNotFound && gi > mi) {
            [matRoot insertSubview:maskV belowSubview:miniAnim];
        }
    } else {
        [matRoot bringSubviewToFront:maskV];
    }
    maskV.link.paused = NO;
    }

    if (musicHost) animV.link.paused = NO;
    /* 2.8.19: 音频同步无条件调用 —— 函数内部会判音乐岛, 非音乐岛走"还原"分支,
       把之前挖的洞和被藏的波形放回去(来电/充电界面不能被我们的掩码影响)。
       2.8.22: 跟着 matRoot 跑; 音乐停了(matRoot 没了)对旧岛再跑一次还原,
       否则洞和藏层会留在最后一个音乐岛上。 */
    static __weak UIView *sSpecRoot;
    if (matRoot) { syncNativeSpectrum(matRoot); sSpecRoot = matRoot; }
    else if (sSpecRoot) { gSpecForceNext = YES; syncNativeSpectrum(sSpecRoot); sSpecRoot = nil; }
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
/* 2.8.4: 前向声明 —— SetInterval 实现在后面, tick 里要先调 */
static void diFlowTickerSetInterval(float sec);
static void diBarTickerSetInterval(float sec);

static void diFlowTick(void) {
    /* 2.8.4 功耗: 空闲自动降频(见 diFlowTickerSetInterval) */
    static int idle;
    BOOL active = NO;
    if (notifyColorOn && notifyFlowOn) {
        for (UIView *h in hostTable) {
            if (!h.window || h.isHidden || h.bounds.size.width < 2) continue;
            active = YES;
            applyNotifyStyle(h);
        }
    }
    if (active) idle = 0;
    else if (++idle > 50) diFlowTickerSetInterval(0.25f);
    else diFlowTickerSetInterval(0.06f);
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
static dispatch_source_t gFlowTicker;   /* 2.8.4: 全局持有, 供降频函数复用 */
static float gFlowTickerInterval = 0.06f;   /* 没有公开 getter, 自己记账 */
static void diFlowTickerSetInterval(float sec) {
    if (!gFlowTicker) return;
    if (fabsf(gFlowTickerInterval - sec) < 0.005f) return;   /* 值没变就不重设(重设会重置计时) */
    gFlowTickerInterval = sec;
    dispatch_source_set_timer(gFlowTicker, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                              (int64_t)(sec * NSEC_PER_SEC), 0.02 * NSEC_PER_SEC);
}

static void diStartFlowTicker(void) {
    if (gFlowTicker) return;
    gFlowTicker = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gFlowTicker, DISPATCH_TIME_NOW, 0.06 * NSEC_PER_SEC, 0.02 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(gFlowTicker, ^{ @autoreleasepool { diFlowTick(); } });
    dispatch_resume(gFlowTicker);
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
    return [cn containsString:@"NowPlaying"] || [cn containsString:@"AdjunctItem"]
        /* 2.8.10: iOS16+ 媒体控制底板(锁屏播放器背景), 不加它播放器永远吃不到样式 */
        || [cn containsString:@"MediaControlsBackground"] || [cn containsString:@"ControlsBackgroundView"];
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

    if (lkShOn || lkGlowOn) diStylePlatter(platter);
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
    host.clipsToBounds = NO;         /* 外层不裁: 裁了就点不到了(用户明确否过) */

    /* 2.9.24: 直角修复 —— 内容按 s 等比缩小后正好铺满整张卡, 四角是直角,
       而外层又为了点击不裁, 于是实时活动(美团配送)卡片的角戳出系统圆角外面。
       这里只给**场景宿主自身**补圆角遮罩:
         · 半径按 s 换算回宿主本地坐标(rr/s), 缩放后视觉半径正好 = 卡片圆角;
         · layer.masksToBounds 只影响绘制, 不参与 hitTest, 点击区域一个像素都不变;
         · 只作用于走这条路的卡片(_UIScenePresentationView/RemoteView),
           普通通知根本不进这个函数, 不会动到其他通知。 */
    CGFloat visH = bh * s;
    static char kSceneClipped;
    if (s < 0.999) {
        CGFloat rr = visH * 0.5;
        if (rr > 23.5) rr = 23.5;        /* iOS16 通知卡圆角 23.5 */
        CGFloat lr = rr / s;
        if (fabs(host.layer.cornerRadius - lr) > 0.2 || !host.layer.masksToBounds) {
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            host.layer.cornerRadius = lr;
            host.layer.cornerCurve = kCACornerCurveContinuous;
            host.layer.masksToBounds = YES;
            [CATransaction commit];
            objc_setAssociatedObject(host, &kSceneClipped, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            static int clipLog;
            if (clipLog < 6) { clipLog++; DLog(@"场景圆角: %@ 视觉 %.0fx%.0f → 圆角 %.1f (本地 %.1f)",
                                               hcn, cardW, visH, rr, lr); }
        }
    } else if ([objc_getAssociatedObject(host, &kSceneClipped) boolValue]) {
        /* 卡片够宽(没缩放)时还原, 避免残留圆角 */
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        host.layer.cornerRadius = 0;
        host.layer.masksToBounds = NO;
        [CATransaction commit];
        objc_setAssociatedObject(host, &kSceneClipped, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    /* 视觉高 = 原生高 × s */
    if (outVisH) *outVisH = visH;

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

    /* 2.8.11: 播放器发光 —— 挂在宽度逻辑正在处理的同一层(platter 就是被自定义宽度
       收敛过的那层)。放在这里是因为: 此时宽度/高度/场景宿主缩放全部收敛完,
       diStylePlatter 的 BFS 量到的就是视觉卡片矩形(2.8.11 起乘 transform 视觉缩放),
       光晕与自定义宽度严丝合缝, 不会像挂在别的层上那样按 401 原始宽外溢。
       不改动上面任何宽度逻辑, 只是复用同一条链路。 */
    if (lkGlowOn && lkGlowR > 0) diStylePlatter(platter);
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

/* 2.6.12: 系统"状态类"界面(来电 / 电池详情 / 音量 / 计时 / 录屏 / 传感器)一律不参与
   宽度收敛和场景缩放。这些界面里同样有 *PlatterView 的子视图, 老版 diIsCardPlatter
   把它们全当通知卡缩放, 结果就是来电、用 NC 打开电池详情时整块被拉大变形。
   这里在入口处直接按祖先链判断并放行, 比下面逐个加黑名单更彻底。 */
static BOOL diIsSystemStatusUI(UIView *v) {
    static NSArray *tokens = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tokens = @[@"Call", @"Battery", @"Volume", @"Ringer",
                   @"Timer", @"Recording", @"Sensor", @"Charging",
                   @"LowPower", @"Biometric", @"StatusBar"];
    });
    for (UIView *p = v; p; p = p.superview) {
        NSString *cn = NSStringFromClass(p.class);
        if (!cn.length) continue;
        for (NSString *t in tokens) if ([cn containsString:t]) return YES;
        if (p.superview == nil) break;
    }
    return NO;
}

static void applyLockWidth(UIView *v) {
    if (!lockWOn || !v.window) return;
    if (!NSThread.isMainThread) return;
    if (diIsSystemStatusUI(v)) return;   /* 2.6.12: 来电/电池详情等系统界面完全不碰 */
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
        || [cn isEqualToString:@"backgroundMaterialView"]
        || [cn containsString:@"MediaControlsBackground"]     /* 2.8.10: iOS16+ 播放器底板 */
        || [cn containsString:@"ControlsBackgroundView"]
        || [cn containsString:@"MRUNowPlaying"]) return v;
    for (UIView *sub in v.subviews) {
        UIView *r = diFindPlatter(sub);
        if (r) return r;
    }
    /* 2.8.10: 播放器宿主(CSAdjunctItemView 等)内部没有 Platter 层 ——
       它自己就是视觉卡片, 兜底返回自己, 否则发光/样式在播放器上永远挂不上。 */
    if (([cn containsString:@"AdjunctItem"] || [cn containsString:@"NowPlaying"])
        && v.bounds.size.width > 100 && v.bounds.size.height > 60) return v;
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
        /* 2.8.11: transform 等比缩放的层(播放器场景宿主), bounds 是缩放前的原始值,
           圆角/尺寸/面积统一按视觉值算, 否则打分和有效判定都会按 401 宽来 */
        CGFloat vs = l.transform.m11;
        if (vs < 0.01f || vs > 100.0f) vs = 1.0f;
        CGFloat h = b.size.height * vs, w = b.size.width * vs;
        CGFloat maxR = h * 0.5;
        NSString *cn = NSStringFromClass([l class]);
        BOOL isMask = (l.mask != nil);

        /* 圆角层的判定: 必须真的有尺寸、且圆角有效(0 < r <= 半高*1.05) */
        CGFloat effR = r * vs;
        if (isMask && l.mask.cornerRadius * vs > effR) effR = l.mask.cornerRadius * vs;
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
       用 layer 的绝对位置差算, 避免 convertRect 多层套娃。
       2.8.11: 播放器的场景宿主(_UIScenePresentationView)是 transform 等比缩放来
       适配自定义宽度的, bounds 还是原始的 401 —— 直接拿 bounds 画 shadowPath
       会按 401 散光, 而视觉卡片只有 340, 左右各溢 30pt(截图那种大幅外溢)。
       这里统一乘上 transform 的视觉缩放, 拿到真实视觉矩形。 */
    CGPoint p0 = [bestL convertPoint:CGPointZero toLayer:platter.layer];
    CGFloat vscale = bestL.transform.m11;   /* 均匀缩放时 m11 == m22 */
    if (vscale < 0.01f || vscale > 100.0f) vscale = 1.0f;
    CGRect rect = CGRectMake(p0.x, p0.y, bestRect.size.width * vscale, bestRect.size.height * vscale);

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

/* 2.8.39: 颜色 → 6 位 hex(签名早退用, 保证单色/多色切换都能被签名识别) */
static NSString *diColorHex(UIColor *c) {
    if (!c) return @"-";
    CGFloat r, g, b, a;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return @"-";
    return [NSString stringWithFormat:@"%02X%02X%02X",
            (int)(r * 255 + 0.5), (int)(g * 255 + 0.5), (int)(b * 255 + 0.5)];
}

/* 2.9.19: 只补"丢了的"呼吸动画, 一个属性都不重写 —— 361 反馈"注销后不呼吸,
   要进设置点一下颜色才动"。根因: 整块配置签名没变就早退, 而层上的
   CAKeyframeAnimation 在系统重建卡片/锁屏重新出现时会丢, 丢了没人补,
   layer 就永远停在第一色; 设置里点颜色 → 签名变了 → 走完整重绘才又动。
   现在每次自愈 tick 走到早退分支时先调这里, 动画在就退, 不在就补上。 */
/* 2.9.20: 给某一层补边框呼吸(只在它真的画着边框、且动画已丢时补) */
static void diAddBdCycleTo(CALayer *l, NSArray<UIColor *> *cols) {
    if (!l || l.borderWidth <= 0 || cols.count < 2) return;
    if ([l animationForKey:@"diBdCycle"]) return;
    CAKeyframeAnimation *a = diShadowCycle(cols, 1.6);
    if (a) { a.keyPath = @"borderColor"; [l addAnimation:a forKey:@"diBdCycle"]; }
}

static void diEnsureBreathAnim(UIView *platter, UIView *face) {
    if (!platter || !platter.layer) return;
    CALayer *FL = platter.layer;
    CALayer *FLf = (face.layer ?: FL);
    /* 2.9.20: 362 反馈"发光会呼吸了, 边框还是不会"。
       边框实际是画在两层上的(底包 platter.layer + 内衬 face.layer), 之前只补了
       face 那一层, 而真正外露、看得见的那条线常常在 platter.layer 上 —— 系统重建
       卡片时它上面的动画丢了没人补, 就永远停在第一个颜色。
       两层都补: 谁画着边框(borderWidth>0)就给谁挂动画, 同一轮挂相位也对得上。 */
    if (lkBdOn && lkBdW > 0) {
        NSArray<UIColor *> *bcols = lkBdColors.count ? lkBdColors
                                   : (lkBdColor ? @[lkBdColor] : @[]);
        diAddBdCycleTo(FL, bcols);
        if (FLf != FL) diAddBdCycleTo(FLf, bcols);
    }
    if (lkGlowOn && lkGlowR > 0 && lkGlowColors.count >= 2 && ![FL animationForKey:@"diBreathC"]) {
        CAKeyframeAnimation *a = diShadowCycle(lkGlowColors, 1.6);
        if (a) { [FL addAnimation:a forKey:@"diBreathC"]; }
    }
    if (lkShOn && lkShR > 0 && lkShColors.count >= 2 && ![FL animationForKey:@"diBreathC"]) {
        CAKeyframeAnimation *a = diShadowCycle(lkShColors, 1.6);
        if (a) { [FL addAnimation:a forKey:@"diBreathC"]; }
    }
}

static void diStylePlatter(UIView *platter) {
    if (!platter) return;
    /* 2.5.3: 2.3.2 的媒体卡跳过已移除(恢复原版 2.3.0)。 */

    [CATransaction begin]; [CATransaction setDisableActions:YES];

    /* 边框矩形 = **视觉卡片(face)** 在 platter 坐标系里的实际矩形;
       圆角 = face 自己的 cornerRadius(夹到半高), 跟随自定义宽高自适应。 */
    CGFloat br = 0;
    CGRect brect = diSystemCardRect(platter, &br);
    /* 2.8.39/2.8.40: 无效卡片帧不画(合并两类"先错后改"):
       ① 新 platter 前几帧子层还没布局好, diSystemCardRect 只能退回
          platter.bounds 猜圆角(来源=fallback) —— 画了等真卡片层量到又要改,
          用户看到"发光闪一下再适应"(308);
       ② 注销后第一次进锁屏, 系统给卡片内部形变层做入场动画, 过渡帧的
          bounds 是缩放前的原始值 —— 309 日志实锤: platter 301x106 时量到
          "卡片 401x167 / 401x142"(比视觉卡片宽 100pt), shadowPath 按它画,
          光晕从卡片两侧外溢一大团, 就是"第一次进锁屏发光外溢"(309 视频)。
       校验: 卡片宽超过 platter 宽 1.2 倍(+4pt 容差)、高超过 1.5 倍(+8pt)、
       或宽度 < 40, 判无效帧 → 跳过本次配置等稳定; 1.5s 兜底放行
       (保证最终一定生效, 不会永远不画)。 */
    {
        CGFloat pw0 = platter.bounds.size.width, ph0 = platter.bounds.size.height;
        BOOL invalidFrame = [diLastCornerSource() isEqualToString:@"fallback"]
            || brect.size.width > pw0 * 1.2 + 4
            || brect.size.height > ph0 * 1.5 + 8
            || brect.size.width < 40;
        static char kFaceWaitT;
        if (invalidFrame) {
            NSNumber *t0 = objc_getAssociatedObject(platter, &kFaceWaitT);
            if (!t0) {
                objc_setAssociatedObject(platter, &kFaceWaitT, @(CFAbsoluteTimeGetCurrent()),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [CATransaction commit];
                return;
            }
            if (CFAbsoluteTimeGetCurrent() - t0.doubleValue < 1.5) {
                [CATransaction commit];
                return;
            }
        } else {
            objc_setAssociatedObject(platter, &kFaceWaitT, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    /* 2.8.39: 整块配置签名早退 —— 0.5s 自愈 tick 反复重入本函数, 原来每 tick
       都重写 shadow/border/path(层属性反复赋值会触发隐式动画, 观感就是微闪)。
       签名含三个开关 + 色表(含单色, 306 的"颜色切换无效"不能复发) + 边框宽 +
       发光/阴影半径 + 卡片矩形圆角, 全同才跳过。 */
    {
        static char kStyleSig;
        NSMutableString *cs = [NSMutableString string];
        for (UIColor *c in lkBdColors)  [cs appendFormat:@"%@,", diColorHex(c)];
        if (lkBdColor)  [cs appendFormat:@"#%@", diColorHex(lkBdColor)];
        [cs appendString:@"|"];
        for (UIColor *c in lkShColors)  [cs appendFormat:@"%@,", diColorHex(c)];
        if (lkShColor)  [cs appendFormat:@"#%@", diColorHex(lkShColor)];
        [cs appendString:@"|"];
        for (UIColor *c in lkGlowColors) [cs appendFormat:@"%@,", diColorHex(c)];
        if (lkGlowColor) [cs appendFormat:@"#%@", diColorHex(lkGlowColor)];
        NSString *sig = [NSString stringWithFormat:@"%d|%d|%d|%.1f|%.1f|%.1f|%.0f,%.0f,%.0f,%.0f r%.0f|%@",
                         lkBdOn, lkShOn, lkGlowOn, lkBdW, lkShR, lkGlowR,
                         brect.origin.x, brect.origin.y, brect.size.width, brect.size.height, br, cs];
        NSString *prev = objc_getAssociatedObject(platter, &kStyleSig);
        if ([sig isEqualToString:prev]) {
            diEnsureBreathAnim(platter, diBorderFace(platter));   /* 2.9.19: 动画丢了就补 */
            [CATransaction commit]; return;
        }
        objc_setAssociatedObject(platter, &kStyleSig, sig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
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
        /* 2.8.36: 呼吸签名早退 —— 每秒自愈 tick 都会重入本块, 原来无条件
           remove+add 等于不停重启呼吸动画, 观感就是永远停在第一个颜色
           (305 实证"呼吸无效"; 与 2.8.9 发光修的是一模一样的坑)。
           色表没变且动画还在 → 整块跳过(含 remove); 变了/没加过才重画。 */
        NSString *bsig = lkBdColors.count >= 2 ? [lkBdColors componentsJoinedByString:@","] : nil;
        NSString *bsigPrev = objc_getAssociatedObject(FL, &kBdSig);
        if (!(bsig && [bsig isEqualToString:bsigPrev] && [FL animationForKey:@"diBdCycle"])) {
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
        objc_setAssociatedObject(FL, &kBdSig, bsig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }   /* 2.8.36: 签名早退闭合 */
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
    } else if (lkGlowOn && lkGlowR > 0) {
        /* 2.8.8: 发光。CALayer 的 shadow 机制本身就是"从 shape 边缘向外"的柔和光晕,
           把发光色设成不透明 + offset(0,0) + shadowRadius=用户值, 就是标准外发光;
           shadowPath 用视觉卡片的圆角矩形, 光正好从卡片边缘散出, 不会溢出到整块 platter。
           多色时复用 diShadowCycle(呼吸式: 每色停留一段再缓入缓出过渡, 不生硬)。
           2.8.9 修两个问题:
             ① 外溢 —— shadowPath 无效(face 量不到)时退回 platter.bounds,
                绝不让 shadow 在无 path 状态下沿图层内容轮廓乱扩散;
             ② 呼吸不动 —— 动画只加一次(色表签名没变就不重启),
                否则每秒的自愈 tick 反复 remove+add 等于不停重启呼吸。 */
        UIColor *gc = lkGlowColor ?: [UIColor colorWithRed:0.0 green:0.68 blue:0.96 alpha:1.0];
        CGFloat gr=0, gg=0, gb=0, ga=1;
        if ([gc getRed:&gr green:&gg blue:&gb alpha:&ga])
            gc = [UIColor colorWithRed:gr green:gg blue:gb alpha:1.0];   /* 不透明 */
        CGRect gpathRect = brect;
        if (gpathRect.size.width < 20 || gpathRect.size.height < 20)
            gpathRect = platter.bounds;   /* ①: path 兜底, 防止光晕失控外溢 */
        FL.shadowColor = gc.CGColor;
        FL.shadowRadius = lkGlowR;
        FL.shadowOpacity = 0.92f;         /* ①: 不满不透明, 光晕柔和一点不外溢发闷 */
        FL.shadowOffset = CGSizeZero;
        FL.masksToBounds = NO;
        FL.allowsGroupOpacity = NO;
        FL.shadowPath = [UIBezierPath bezierPathWithRoundedRect:gpathRect cornerRadius:br].CGPath;
        /* ②: 呼吸动画只在"没加过"或"色表变了"时才 add —— 每秒 remove+add 会
           把动画不断重启, 观感就是永远停在第一个颜色。 */
        NSString *gsig = lkGlowColors.count >= 2 ? [lkGlowColors componentsJoinedByString:@","] : nil;
        NSString *gsigPrev = objc_getAssociatedObject(FL, &kGlowSig);
        if (gsig) {
            if (![FL animationForKey:@"diBreathC"] || ![gsig isEqualToString:gsigPrev]) {
                [FL removeAnimationForKey:@"diBreathC"];
                CAKeyframeAnimation *ca = diShadowCycle(lkGlowColors, 1.6);
                if (ca) { ca.keyPath = @"shadowColor"; [FL addAnimation:ca forKey:@"diBreathC"]; }
                objc_setAssociatedObject(FL, &kGlowSig, gsig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } else {
            [FL removeAnimationForKey:@"diBreathC"];
            objc_setAssociatedObject(FL, &kGlowSig, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else {
        FL.shadowOpacity = 0;
        FL.shadowRadius = 0;
        FL.shadowPath = nil;
        [FL removeAnimationForKey:@"diBreath"];
        [FL removeAnimationForKey:@"diBreathC"];
        objc_setAssociatedObject(FL, &kGlowSig, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

/* 2.8.36: 锁屏窗口判定 —— 305 实证: diForEachWindow 会遍历到 SBControlCenterWindow,
   控制中心里的播放器底板(MediaControlsBackground/NowPlaying)同样命中样式清单,
   被一起染了色。用户只要锁屏, 所以三个样式入口(diRestyleWalk /
   diRestyleAllPlatters / applyLockStyle)统一加这道闸。
   锁屏窗口类名实证: SBCoverSheetWindow(305 日志横条手势挂载点)。 */
static BOOL diIsLockScreenWindow(UIWindow *w) {
    return [w isKindOfClass:NSClassFromString(@"SBCoverSheetWindow")];
}
static BOOL diInLockScreen(UIView *v) {
    return v && diIsLockScreenWindow(v.window);
}

static void applyLockStyle(UIView *v) {
    if (!NSThread.isMainThread) return;
    if (!lkBdOn && !lkShOn && !lkGlowOn) return;
    if (!diInLockScreen(v)) return;   /* 2.8.36: 控制中心等其它窗口不染色 */
    NSString *cn = NSStringFromClass(v.class);
    if (!diIsNoticeOrPlayerView(cn)) return;
    UIView *platter = diFindPlatter(v);
    if (!platter) return;
    objc_setAssociatedObject(v, &kLkPlatter, platter, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    diStylePlatter(platter);
}

/* ===== 2.9.19: 通知到达 → 立即重新起一次呼吸 =====
   361 要求"有通知了不管什么时候都自动呼吸动态效果"。新卡片虽然会走 layoutHook
   上样式, 但卡片是复用池里的, 层上残留的动画可能已停/已丢, 这时整块签名早退
   不会重建。这里在卡片进窗口(didMoveToWindow)时先把两条呼吸动画摘掉再让
   diStylePlatter 补回去 —— 等于强制从第一帧重新呼吸。 */
struct DIBreathHook { Class cls; IMP original; };
static std::vector<DIBreathHook> gBreathHooks;

static void diBreathKick(UIView *v) {
    if (!v || !v.window) return;
    if (!(lkGlowOn || lkShOn || lkBdOn)) return;
    if (!diInLockScreen(v)) return;
    UIView *pl = diFindPlatter(v);
    if (!pl || !pl.layer) return;
    [pl.layer removeAnimationForKey:@"diBreathC"];
    [pl.layer removeAnimationForKey:@"diBdCycle"];   /* 2.9.20: platter 上的边框也要重起 */
    UIView *face = diBorderFace(pl);
    if (face && face != pl) [face.layer removeAnimationForKey:@"diBdCycle"];
    diStylePlatter(pl);   /* 签名早退分支里会用 diEnsureBreathAnim 把动画补回来 */
}

static void diBreathHookIMP(UIView *self, SEL _cmd) {
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c)) {
        BOOL found = NO;
        for (const DIBreathHook &h : gBreathHooks) {
            if (h.cls == c) { ((void(*)(id, SEL))h.original)(self, _cmd); found = YES; break; }
        }
        if (found) break;
    }
    diBreathKick(self);
}

static void installBreathKick(void) {
    for (NSString *n in @[@"NCNotificationShortLookView", @"NCNotificationListCell"]) {
        Class c = NSClassFromString(n);
        if (!c) continue;
        BOOL dup = NO;
        for (const DIBreathHook &h : gBreathHooks) if (h.cls == c) dup = YES;
        if (dup) continue;
        IMP old = NULL;
        MSHookMessageEx(c, @selector(didMoveToWindow), (IMP)diBreathHookIMP, &old);
        if (old) { gBreathHooks.push_back({c, old}); DLog(@"呼吸: 已挂通知到达钩子 %@", n); }
    }
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
        if (!diInLockScreen(root)) return;   /* 2.8.36: 只锁屏 */
        UIView *pl = diFindPlatter(root);
        if (pl) diStylePlatter(pl);
    }
    for (UIView *sub in root.subviews) diRestyleWalk(sub);
}

/* 兜底: 直接把锁屏上所有 platter 都按"卡片"处理(播放器不走通知链, 靠这条) */
static void diRestyleAllPlatters(UIView *root) {
    if (!root) return;
    NSString *cn = NSStringFromClass(root.class);
    /* 2.8.10: 播放器没有 PlatterView, 把媒体控制底板也纳入, 否则路径 B 也漏它 */
    if (([cn containsString:@"PlatterView"] || [cn isEqualToString:@"PLPlatterView"]
         || [cn containsString:@"MediaControlsBackground"] || [cn containsString:@"ControlsBackgroundView"])
        && root.window && root.bounds.size.width > 120
        && diIsLockScreenWindow(root.window)) {   /* 2.8.36: 只锁屏 */
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
    if (NSThread.isMainThread) {
        diInstallGeometryWatch();
        updateHost(self);
    }
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
    diGainInstallHook();   /* 2.8.31: 隐藏药丸 hook(私有类晚加载时靠分阶段重试补装) */
    diGLFInstall();   /* 2.9.33: 锁屏VC + 桌面3D长按菜单 深/浅色(移植 GlobalFontSwitcher) */
    install(@"SAUIElementView");
    installBreathKick();   /* 2.9.19: 通知到达 → 重新起呼吸 */
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
    /* 2.7.0: 设置页一改壁纸(开关/素材/静音/位置), 这里立刻重建 */
    [[DIWallpaperView shared] reload];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]])
            for (UIWindow *w in ((UIWindowScene *)s).windows)
                dispatch_async(dispatch_get_main_queue(), ^{ updateSingleVideo(w); });
}

// 0.5 秒轮询: 刷新偏好缓存 + 维持视频层; displayLink 负责逐帧贴合
static void diForEachWindow(void (^blk)(UIWindow *w));
static void diWidthWalk(UIView *root);
static void diRestyleWalk(UIView *root);


#pragma mark - 2.7.13: 让控制中心"系统磨砂层自己显示壁纸"(彻底告别插图层)

/* 为什么放弃"插一个自己的图层":
     2.7.4~2.7.12 九版反复试的都是"把我的 UIView 塞进控制中心的某个位置"。
     结果永远是二选一:
       · 塞得太高 → 盖住开关(2.7.10);
       · 塞得太低 → 被磨砂链路压暗/吞掉, 前 0.5 秒只看得到底色(2.7.12)。
     241~245 的真机视图树给了根源: 控制中心那块 430x932 的背景是 MTMaterialView,
     它**自带模糊采样源**(UIKit 里是 `backgroundGroupName`), 系统先取桌面截图模糊,
     再叠一层深色 washi 底色 → 我插在它下面的任何视图都会先被压暗再被叠色。

   2.7.13 换思路: 不插图层, 直接给这个 MTMaterialView 换"采样源"。
     1) hook MTMaterialView 的 backgroundGroupName(和 setter), 记下控制中心那两块
        (整屏 430x932 的背景 / 顶部胶囊)的原始组名, 收尾能还原;
     2) 用户在设置里选了壁纸 → 把它们的组名指向一个我们自建的
        UIVisualEffectView(私有 UIVisualEffectViewBackdropGroupName + 里层放壁纸图);
     3) 于是这块系统磨砂层**自己的**模糊背景就是我们的壁纸。
     这样做的好处:
       · 系统"铺开模糊"和"我的壁纸出现"是同一个动画的同一个属性, 不存在先后 → 进入即显示,
         不会再有"先到底色、半秒后才出素材";
       · 收起时系统把这块材质一起撤, 壁纸跟着一帧不剩 → 直接退出, 不会有残留;
       · 层级完全没动过, 开关/模块/滑块永远在最上面, 不可能被挡。

   风险控制:
     · 只认"控制中心窗口里 + 全屏"的 MTMaterialView, 锁屏/通知/其他 App 的材质一概不碰;
     · 组名只在本进程内改, 卸载/关闭开关后调用 restore 回到原值;
     · 全程 @try 兜底, 任何一个私有方法不存在就安静退回旧路线(插图层)。 */

static NSMutableArray<NSString *> *gCCGroupTab;      /* 原组名(与 gCCGroupViews 一一对应) */
static NSMutableArray<NSValue *> *gCCGroupViews;     /* 被我们改过组名的磨砂层(非持有) */
static __weak NSObject *gCCGroupEffect;              /* 承载壁纸的 effect 对象(弱持有) */
static NSString *gCCOwnGroup;                        /* 我们自建的组名 */
static NSString *gCCCachedPath;                      /* 当前喂进去的素材路径 */
static IMP diOrigGroupGetter, diOrigGroupSetter;
static void diCCTrackMaterial(UIView *v);
/* 2.7.14: getter 不存在时的退路 —— 原组名记在关联对象里(setter 每次进来先存一份) */
static const void *diCCOrigGroupKey = &diCCOrigGroupKey;
static UIView *gCCSourceView;                        /* 2.7.14: 挂在屏幕上的采样源(全屏效果层), 强持有 */
static void diCCAttachSourceToScreen(void);

static id diCCHookedGroupGetter(id self, SEL _cmd) {
    id r = diOrigGroupGetter ? ((id (*)(id, SEL))diOrigGroupGetter)(self, _cmd) : nil;
    if ([r isKindOfClass:[NSString class]] && [r hasPrefix:@"DriftIslandCC"]) return nil;
    return r;
}

static void diCCHookedGroupSetter(id self, SEL _cmd, id name) {
    /* 2.7.14: 系统每次设组名, 先把"它想设成什么"记下来(关联对象),
       这样即使 MTMaterialView 根本没暴露 getter, 我们也知道原值, 收尾能原样还回去。 */
    if (!diOrigGroupGetter) {
        @try { objc_setAssociatedObject(self, diCCOrigGroupKey, [name copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        @catch (__unused NSException *e) {}
    }
    if (diOrigGroupSetter) ((void (*)(id, SEL, id))diOrigGroupSetter)(self, _cmd, name);
    /* 系统给这块材质设组名的瞬间就是"它要出现了" —— 此刻就换组, 不会晚一帧 */
    @try { diCCTrackMaterial((UIView *)self); } @catch (__unused NSException *e) {}
}


static IMP di_MethodImp(Class c, SEL sel) {
    if (!c) return NULL;
    Method m = class_getInstanceMethod(c, sel);
    return m ? method_getImplementation(m) : NULL;
}

/* 给一块磨砂层换组名(记录原值, 便于还原) */
static void diCCSetGroup(UIView *v, NSString *name) {
    if (!v || !diOrigGroupSetter) return;
    @try {
        ((void (*)(id, SEL, id))diOrigGroupSetter)(v, NSSelectorFromString(@"setBackgroundGroupName:"), name);
    } @catch (__unused NSException *e) {}
}

static BOOL diCCIsControlCenterWindow(UIWindow *w) {
    NSString *cn = NSStringFromClass(w.class);
    if (![cn containsString:@"ControlCenter"]) return NO;
    if ([cn containsString:@"SystemAperture"] || [cn containsString:@"StatusBar"]) return NO;
    if ([cn containsString:@"LockScreen"] || [cn containsString:@"NotificationCenter"]) return NO;
    return YES;
}

/* 找一个窗口里"全屏背景"那一块磨砂层(排除 CCUIScrollView 内容区的底色) */
__attribute__((unused)) static void diCCCollectFullscreenMaterials(UIView *root, NSMutableArray<UIView *> *out) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    CGSize rs = root.bounds.size;
    int guard = 0;
    while (stack.count && guard++ < 1200) {
        UIView *v = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if ([NSStringFromClass(v.class) isEqualToString:@"MTMaterialView"]) {
            CGSize bs = v.bounds.size;
            if (bs.width >= rs.width * 0.95 && bs.height >= rs.height * 0.95) {
                BOOL inScroll = NO;
                for (UIView *p = v.superview; p; p = p.superview) {
                    if ([p isKindOfClass:[UIScrollView class]]) { inScroll = YES; break; }
                }
                if (!inScroll) [out addObject:v];
            }
        }
        for (UIView *c in v.subviews) [stack addObject:c];
    }
}

/* 收到"用了我们的组"的磨砂层, 看它是否需要换组 */
static void diCCTrackMaterial(UIView *v) {
    if (!wpOn) return;
    if (![NSStringFromClass(v.class) isEqualToString:@"MTMaterialView"]) return;
    UIWindow *win = v.window;
    if (![win isKindOfClass:[UIWindow class]] || !diCCIsControlCenterWindow(win)) return;
    CGSize ws = win.bounds.size, bs = v.bounds.size;
    /* 2.7.14: 系统设组名时材质往往还没 layout 完(bounds 是 0), 用 frame 兜一层。
       这里只要"大致占满屏"就认 —— 判太严会把真正那块背景漏掉。 */
    CGRect fr = v.frame;
    CGFloat cw = MAX(bs.width, fr.size.width), chh = MAX(bs.height, fr.size.height);
    if (cw < ws.width * 0.90 || chh < ws.height * 0.90) return;
    for (UIView *p = v.superview; p; p = p.superview)
        if ([p isKindOfClass:[UIScrollView class]]) return;   /* 内容区底色不动 */

    NSString *own = gCCOwnGroup ?: @"DriftIslandCCWallpaper";
    NSString *cur = nil;
    if (diOrigGroupGetter) {
        @try { cur = ((id (*)(id, SEL))diOrigGroupGetter)(v, NSSelectorFromString(@"backgroundGroupName")); }
        @catch (__unused NSException *e) {}
    } else {
        /* 没有 getter: 取 setter 里存的"系统想设的那个值" */
        @try { cur = objc_getAssociatedObject(v, diCCOrigGroupKey); }
        @catch (__unused NSException *e) {}
    }
    if ([cur isEqualToString:own]) return;   /* 已经是我们的组 */

    NSValue *key = [NSValue valueWithNonretainedObject:v];
    NSUInteger idx = [gCCGroupViews indexOfObject:key];
    if (idx == NSNotFound) {
        if (!gCCGroupTab) gCCGroupTab = [NSMutableArray array];
        if (!gCCGroupViews) gCCGroupViews = [NSMutableArray array];
        [gCCGroupTab addObject:cur.length ? cur : @""];
        [gCCGroupViews addObject:key];
        RLog(@"[壁纸图层] 接管磨砂层 %@ (%.0fx%.0f) 原组名=%@", NSStringFromClass(v.class),
             cw, chh, cur.length ? cur : @"(空)");
    } else {
        gCCGroupTab[idx] = cur.length ? cur : @"";
    }
    diCCSetGroup(v, own);
}

/* 关闭开关 / 素材清空: 把组名还原成系统原来的值 */
static void diCCRestoreGroups(void) {
    if (!gCCGroupViews) return;
    for (NSUInteger i = 0; i < gCCGroupViews.count; i++) {
        UIView *v = [gCCGroupViews[i] nonretainedObjectValue];
        NSString *old = i < gCCGroupTab.count ? gCCGroupTab[i] : @"";
        if (v) diCCSetGroup(v, old.length ? old : nil);
    }
    [gCCGroupViews removeAllObjects];
    [gCCGroupTab removeAllObjects];
    DLog(@"[壁纸图层] 已把所有磨砂层的组名还原");}

/* 2.7.14: 组名这条路的关键前提 —— 名字对不对。真机 MTMaterialView 上可能是
   `backgroundGroupName` / `groupName` / `backdropGroupName` 之一, 每台系统版本不同。
   这里一次性把 MTMaterialView 和 UIBlurEffect 上所有含 group 的实例方法名扫出来落盘,
   下次日志就能直接看到该用哪个名字, 不用再靠猜。 */
static void diCCLogGroupSelectors(void) {
    Class mc = NSClassFromString(@"MTMaterialView");
    Class ec = NSClassFromString(@"UIBlurEffect");
    NSMutableArray<NSString *> *a = [NSMutableArray array], *b = [NSMutableArray array];
    unsigned int n = 0;
    if (mc) {
        Method *ms = class_copyMethodList(mc, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *s = NSStringFromSelector(method_getName(ms[i]));
            if ([s.lowercaseString containsString:@"group"]) [a addObject:s];
        }
        free(ms);
    }
    if (ec) {
        Method *ms = class_copyMethodList(ec, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *s = NSStringFromSelector(method_getName(ms[i]));
            if ([s.lowercaseString containsString:@"group"]) [b addObject:s];
        }
        free(ms);
    }
    RLog(@"[壁纸图层] MTMaterialView 含 group 的方法: %@", a.count ? [a componentsJoinedByString:@", "] : @"(无)");
    RLog(@"[壁纸图层] UIBlurEffect 含 group 的方法: %@", b.count ? [b componentsJoinedByString:@", "] : @"(无)");
}

/* 壁纸图 → 一层挂在控制中心窗口里(屏幕外)的 UIVisualEffectView,
   它的私有 backgroundGroupName 就是系统磨砂层的采样源名字。
   只要这层存在且铺着壁纸图, 控制中心那块 MTMaterialView 的模糊背景就是壁纸本身 ——
   系统"铺开模糊"和"壁纸出现"变成同一个动画的同一个属性, 不再有先后。 */
static UIView *diCCBuildEffectView(NSString *path, CGFloat alpha) {
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (!img) {
        RLog(@"[壁纸图层] 采样源建不出来: 图片读不到 %@", path.lastPathComponent);
        return nil;
    }

    /* 2.7.14: 到这一步的前提是 gCCGroupHooked 已为 YES, 也就是 MTMaterialView 上有
       setBackgroundGroupName:。现在要给"采样源"这边也挂上同一个组名,
       名字挑真机存在的那一个, 全都不在就让上层退回老路(返回 nil)。 */
    NSObject *effect = nil;
    BOOL set = NO;
    @try {
        SEL factory = NSSelectorFromString(@"effectWithStyle:");
        Class bc = NSClassFromString(@"UIBlurEffect");
        if (!bc || ![bc respondsToSelector:factory]) {
            RLog(@"[壁纸图层] UIBlurEffect 没有 effectWithStyle:, 采样源放弃");
            return nil;
        }
        effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(bc, factory, 4 /* 深色薄材质 */);
        if (!effect) return nil;
        NSString *own = gCCOwnGroup ?: @"DriftIslandCCWallpaper";
        for (NSString *sel in @[@"setBackgroundGroupName:", @"setGroupName:", @"setBackdropGroupName:"]) {
            SEL s = NSSelectorFromString(sel);
            if (![effect respondsToSelector:s]) continue;
            ((void (*)(id, SEL, id))objc_msgSend)(effect, s, own);
            set = YES;
            break;
        }
    } @catch (__unused NSException *e) { return nil; }
    if (!effect || !set) {
        /* 2.7.23: 这条路径在 iOS 16 上是**走不通的**(UIBlurEffect 没有组名 setter),
           以前每秒刷 2 条, 一轮日志 591 条, 把真正有用的信息全淹了。
           现在只打一次, 并且置死标志 gCCGroupUnavailable —— 之后 tick 直接跳过
           组名路线, 连函数都不进, 顺便省掉每秒 2 次 effectWithStyle: 的对象创建。 */
        static BOOL sTold;
        if (!sTold) {
            sTold = YES;
            RLog(@"[壁纸图层] UIBlurEffect 无组名 setter, 组名采样路线关闭(本机不支持, 不再重试)");
        }
        gCCGroupUnavailable = YES;
        return nil;
    }

    /* 采样源本体: 一个铺满屏幕尺寸的 effect view。
       系统采样时按**屏幕坐标系**取这块区域, 所以它必须和屏幕一样大, 不能是 1x1。 */
    UIVisualEffectView *evv = [[UIVisualEffectView alloc] initWithEffect:(UIVisualEffect *)effect];
    evv.userInteractionEnabled = NO;
    evv.frame = [UIScreen mainScreen].bounds;
    UIImageView *iv = [[UIImageView alloc] initWithFrame:evv.bounds];
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.clipsToBounds = YES;
    iv.image = img;
    [evv.contentView addSubview:iv];
    evv.alpha = alpha;
    gCCGroupEffect = effect;
    RLog(@"[壁纸图层] 采样源就绪: %@ (%.0fx%.0f)", path.lastPathComponent, img.size.width, img.size.height);
    return evv;
}

/* 2.7.14: 采样源必须真的在屏幕上(哪怕在屏幕外一点点), 系统才采得到它。
   挂在**独立的一层窗口**里: windowLevel 比控制中心低, 且 frame 整体移到屏幕外,
   这样它永远不会被用户看到, 也不会挡住任何东西 —— 但系统按组名采样时仍能取到它的画面。 */
static void diCCAttachSourceToScreen(void) {
    UIView *src = gCCSourceView;
    if (!src) return;
    if (src.window) return;   /* 已经在屏幕上 */
    UIWindow *base = nil;
    UIWindowScene *scene = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        scene = (UIWindowScene *)sc;
        base = scene.windows.firstObject;
        if (base) break;
    }
    if (!base || !scene) return;
    @try {
        /* 挂在**场景最底层窗口**的 rootViewController.view 里, 层序 0 ——
           这样它永远在所有可见内容之下, 只是给系统提供一块可采样的画面。 */
        UIView *host = base.rootViewController.view ?: base;
        [host insertSubview:src atIndex:0];
        src.userInteractionEnabled = NO;
        src.hidden = NO;
        src.alpha = 1.0;
        /* 关键: 尺寸必须是整屏(系统按屏幕坐标采样), 位置不能真的跑到屏幕外 ——
           跑出去就采不到了。所以用"整屏但是被 host 盖住"的做法:
           放在最底层, 上面有桌面/图标/控制中心层层遮着, 用户看不见。 */
        src.frame = [UIScreen mainScreen].bounds;
        RLog(@"[壁纸图层] 采样源已挂到 %@ (最底层, 供系统模糊采样)", NSStringFromClass(host.class));
    } @catch (__unused NSException *e) {}
}

/* 定时器里调用: 素材变了就重建采样源, 开关关了就把组名还回去 */
static void diCCRefreshFromTick(void) {
    /* 2.7.23: 本机没有 UIBlurEffect 组名 setter 时整条路线永久关闭, 连偏好读取
       和文件存在性检查都不做 —— 这个函数原来是每秒 2 次的文件 stat, 白耗。 */
    if (gCCGroupUnavailable) return;
    NSString *base = wpOn ? [DIWallpaperView resolveCurrentPath] : nil;
    NSString *path = base;
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) path = nil;

    if (!path) {
        if (gCCGroupViews.count) diCCRestoreGroups();
        if (gCCSourceView) { [gCCSourceView removeFromSuperview]; gCCSourceView = nil; }
        gCCCachedPath = nil;
        return;
    }
    BOOL needRebuild = !gCCCachedPath || ![gCCCachedPath isEqualToString:path] || !gCCGroupEffect;
    if (needRebuild) {
        /* 2.7.14: 建不出来 → 把 gCCGroupHooked 收回, 让 attachIfNeeded 退回插图层老路,
           不至于"组名都换了, 结果没有采样源"→ 控制中心变成纯色。 */
        UIView *src = diCCBuildEffectView(path, 1.0);
        if (src) {
            [gCCSourceView removeFromSuperview];
            gCCSourceView = src;
            diCCAttachSourceToScreen();
            gCCCachedPath = path;
        } else {
            /* 2.7.23: 组名路线本机不支持(UIBlurEffect 无 setter), 直接跳过,
               不再每秒重建一次 effect 对象 —— 以前这里每秒刷 2 条日志 +
               2 次对象分配, 日志被淹, 改成一次性判定后彻底安静。 */
            if (!gCCGroupUnavailable) {
                RLog(@"[壁纸图层] 采样源构建失败, 退回插图层老路");
                gCCGroupUnavailable = YES;
            }
            gCCGroupHooked = NO;
            if (gCCGroupViews.count) diCCRestoreGroups();
        }
    } else {
        /* 素材没换也要保证采样源还在屏幕上(控制中心每次收起, 窗口被摘掉, 我们的源也跟着没了) */
        diCCAttachSourceToScreen();
    }
}

/* 2.7.14: 绝不能再因为"少一个方法"就整套静默退出。
   246/247 两份日志里 `[壁纸图层]` 一条都没有 = 2.7.13 的这套逻辑压根没进过,
   原因就是这条判定: getter + setter 必须**同时**存在。iOS 16.2 的 MTMaterialView 上
   `backgroundGroupName` 只有 setter(或者名字根本不同), getter 拿不到 → 直接 return,
   连一行日志都不留。现在改成:
     · setter 存在就 hook(它是"材质即将出现"的唯一可靠信号, 有它就够用);
     · getter 有就 hook, 没有就靠关联对象自己记原组名, 不再依赖它;
     · 三个关键节点(类在不在 / 方法在不在 / hook 成没成)全部用 RLog 落盘,
       RLog 不受日志开关控制, 下次装完立刻能看到结论。 */
__attribute__((unused)) /* 2.8.5: 控制中心已下架, 不再调用, 留档 */
static void diCCInstallGroupHook(void) {
    if (gCCGroupHooked) return;
    Class c = NSClassFromString(@"MTMaterialView");
    if (!c) {
        RLog(@"[壁纸图层] 找不到 MTMaterialView 类, 本次走插图层老路");
        return;
    }
    SEL g = NSSelectorFromString(@"backgroundGroupName");
    SEL st = NSSelectorFromString(@"setBackgroundGroupName:");
    diOrigGroupGetter = di_MethodImp(c, g);
    diOrigGroupSetter = di_MethodImp(c, st);

    /* setter 是命脉: 系统给材质设组名的瞬间就是我们换组的时机。没有它这条路彻底走不通。 */
    if (!diOrigGroupSetter) {
        RLog(@"[壁纸图层] MTMaterialView 没有 setBackgroundGroupName: (getter=%@), 退回插图层老路",
             diOrigGroupGetter ? @"有" : @"无");
        return;
    }
    /* getter 可有可无: 没有就不 hook, 原组名改用关联对象记 */
    if (diOrigGroupGetter) {
        MSHookMessageEx(c, g, (IMP)diCCHookedGroupGetter, &diOrigGroupGetter);
    }
    MSHookMessageEx(c, st, (IMP)diCCHookedGroupSetter, &diOrigGroupSetter);
    gCCGroupHooked = YES;
    RLog(@"[壁纸图层] 组名 hook 已挂上 (getter=%@), 壁纸改由系统磨砂层自己渲染",
         diOrigGroupGetter ? @"有" : @"无");
    diCCLogGroupSelectors();
}

/* ============================================================================
   2.7.22: 真正移植 CCBackgroundMod 1.6 的机制
   ----------------------------------------------------------------------------
   252 日志把 2.7.19/2.7.20/2.7.21 失败的原因彻底钉死了:

     [21:14:59] 控制中心壁纸已挂入 MTMaterialView 内部 (430x932) 层序=0/共1
     [21:14:59] [壁纸图层] MTMaterialView 内部子视图 (共 1):
     [21:14:59]        [0] DIWallpaperView {{0, 0}, {430, 932}} alpha=1.00
     [21:15:00] 父级已离开屏幕, 壁纸立刻撤下(保持原生)
     [21:15:01] 控制中心壁纸已挂入 MTMaterialView 内部 (430x932) 层序=0/共1
     [21:15:02] 父级已离开屏幕, 壁纸立刻撤下(保持原生)

   注意"共1" —— **我们挂进去的那一刻, MTMaterialView 内部只有我们自己一个子视图,
   系统自己的 _UIBackdropEffectView 根本还没建出来。** 也就是说展开动画期间
   MTMaterialView 是个空壳, 系统在动画中后段才往里填东西; 填的时候会清理它不认识的
   子视图, 于是我们的 UIView 被踢出去 → "父级已离开屏幕" → 撤下 → 下一轮再挂。
   挂上→被踢→再挂, 一秒钟一个来回, 这就是用户看到的前后 1 秒延迟。
   问题根本不在"挂载快慢", 而在**挂上去活不下来**。

   反汇编参考插件 CCBackgroundMod.dylib 得到的真实机制(逐条核对过指令):
     · hook 目标: MTMaterialView 的 layoutSubviews(selref[0]) 与 didMoveToWindow;
     · 上下文判定(0x5a18): 从 self 沿 superview 上溯, 类名 containsString
       "CCUIModularControlCenter" 或 "CCUIContentModule" 才算数 —— 不是比尺寸!
     · 挂载方式(0x62cc): 取 view.layer, 然后 [layer addSublayer:playerLayer]。
       **不走 addSubview:, 所以系统清理 subviews 时根本扫不到它。**
     · 去重(0x4810): tag = 0x22c3, 用 viewWithTag: 查自己有没有已经在场;
     · 模糊(0x6254): CAFilter filterWithType:@"gaussianBlur" + inputRadius。

   本版完全照搬: 视频/图片都做成 CALayer 挂在磨砂层自己的 layer 上,
   而不是塞成子视图。这样它就在系统填充过程之外, 不会被踢掉,
   挂一次就一直在, 进出控制中心都是零延迟、零闪烁。
   ============================================================================ */

/* 参考实现用 viewWithTag: + tag 0x22c3 判断"我的层在不在场"。
   我们挂在 CALayer 上, 层没有 tag, 等价物是 layer.name —— 见 diCCApplyBackdropTo。 */

static IMP diOrigMTLayout;
static IMP diOrigMTDidMoveToWindow;

/* 沿父链找"控制中心上下文"。

   2.7.22 惨败的原因: 照抄了参考实现 0x5a18 的两条类名判定
   (CCUIModularControlCenter / CCUIContentModule), 但真机上那块**全屏底**
   MTMaterialView 的父链是:
       MTMaterialView → UIView → SBBarSwipeAffordanceView → SBControlCenterWindow
   一个都对不上 → 恒返回 NO → 一块都挂不上 → 用户看到"直接没背景了"。

   参考插件里那两个类名对应的是"模块容器"(每个开关卡片自己的背景),
   不是全域底色。所以这里换成对窗口的判定, 用项目里已有的
   diCCIsControlCenterWindow()(它已经在别的路径上验证过, 能正确认出
   SBControlCenterWindow 并排除 SystemAperture / LockScreen / 通知中心)。

   仍然只看类名, 不看尺寸/透明度 —— 展开动画期间这些都在变, 一帧判错就是抖动。 */
static BOOL diIsInControlCenterContext(UIView *v) {
    UIView *p = v;
    UIWindow *win = nil;
    int guard = 0;
    while (p && guard++ < 60) {
        if ([p isKindOfClass:[UIWindow class]]) { win = (UIWindow *)p; break; }
        NSString *cn = NSStringFromClass(p.class);
        if (cn.length) {
            /* 参考实现的两条: 模块容器上仍有效, 留着不吃亏 */
            if ([cn containsString:@"CCUIModularControlCenter"]) return YES;
            if ([cn containsString:@"CCUIContentModule"]) return YES;
        }
        p = p.superview;
    }
    if (win && diCCIsControlCenterWindow(win)) return YES;
    /* 保险: 还没来得及进窗口(刚创建、window 为 nil)时, 用父链上的
       CCUIScrollView / CCUIHeaderPocketView 这类只有控制中心才有的类名兜底 */
    p = v; guard = 0;
    while (p && guard++ < 60) {
        NSString *cn = NSStringFromClass(p.class);
        if ([cn hasPrefix:@"CCUI"]) return YES;
        p = p.superview;
    }
    return NO;
}

/* 建一个承载壁纸的 CALayer。与参考实现一致: 用 AVPlayerLayer 直接挂,
   不建 UIView —— 少一层视图层级, 也少了被系统当作子视图清理的可能。 */
static CALayer *diNewBackdropLayer(void) {
    CALayer *l = [CALayer layer];
    l.masksToBounds = YES;
    /* 与磨砂层同帧: 用 0 时长事务, 避免 lambda 自带隐式动画导致淡入淡出 */
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    l.opacity = 1.0f;
    [CATransaction commit];
    return l;
}

/* 2.7.22: 参考实现里的 CAFilter gaussianBlur 是它自己的可选功能(给壁纸加模糊)。
   我们的需求是"壁纸清晰显示", 不需要模糊, 所以这里不做 —— 也就避免了
   私有类 CAFilter 的声明问题与 ARC performSelector 警告。
   将来若要支持"壁纸模糊"开关, 在这里用 NSClassFromString + objc_msgSend 实现即可。 */

/* ---- 壁纸内容: 把一个 AVPlayerLayer / CALayer 作为内容层塞进背景层 ----------
   与参考实现一致 —— 内容本身也是 CALayer, 不建 UIView。
   素材路径每次进来都走缓存的"当前路径", 只有路径真的变了才重新建播放器,
   这样 layoutSubviews 每帧调用也不会反复创建 AVFoundation 对象。

   安全性(吸取 2.7.20 卡白屏的教训):
     · 建播放器这一步会触碰 AVFoundation, 所以**只在 gDiLaunchTime 之后 20 秒
       且 wpOn 且确实找到了控制中心上下文**时才会执行;
     · 建之前先看路径有没有变(纯字符串比较), 绝大多数帧在这里就返回了。 */
static AVQueuePlayer *gDICCPlayer;
static AVPlayerLooper *gDICCLooper;
static CALayer *gDICCContentLayer;       /* 内容层, 挂在背景层上 */
static NSString *gDICCCurPath;           /* 当前已加载的素材路径 */

/* 2.7.32: 壁纸不再分深浅, 原来的"外观判定"函数整体删除 */

static void diCCLoadContentInto(CALayer *host) {
    if (!host) return;
    /* 2.7.32: 单素材 —— 不再分深浅两套 */
    NSString *path = diWallpaperResolveAny(wpLightAsset);
    if (!path) path = diWallpaperResolveAny(wpDarkAsset);
    if (!path.length) {
        /* 没选素材: 保持系统原生(透明), 把自己撤掉即可 */
        [gDICCContentLayer removeFromSuperlayer];
        gDICCContentLayer = nil;
        [gDICCPlayer pause];
        gDICCCurPath = nil;
        return;
    }
    BOOL same = (gDICCCurPath && [gDICCCurPath isEqualToString:path]);
    if (same && gDICCContentLayer && gDICCContentLayer.superlayer == host) {
        if (gDICCPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying) [gDICCPlayer play];
        return;
    }

    /* 路径变了(或首次) → 重建内容层 */
    [gDICCContentLayer removeFromSuperlayer];
    gDICCContentLayer = nil;
    [gDICCLooper disableLooping];
    gDICCLooper = nil;
    [gDICCPlayer pause];
    [gDICCPlayer replaceCurrentItemWithPlayerItem:nil];
    gDICCPlayer = nil;
    gDICCCurPath = nil;

    if (!diWallpaperIsVideo(path)) {
        UIImage *im = [UIImage imageWithContentsOfFile:path];
        if (!im) return;
        CALayer *l = [CALayer layer];
        l.contents = (__bridge id)im.CGImage;
        l.contentsGravity = kCAGravityResizeAspectFill;
        l.masksToBounds = YES;
        l.frame = host.bounds;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [host addSublayer:l];
        [CATransaction commit];
        gDICCContentLayer = l;
        gDICCCurPath = path;
        DLog(@"[壁纸图层] 内容层(图片)已挂入: %@ %.0fx%.0f", path.lastPathComponent, im.size.width, im.size.height);
        return;
    }

    /* 视频: 剥音轨 + 静音, 与岛上视频同一套做法 */
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path]
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVPlayerItem *item = nil;
    @try {
        AVAssetTrack *vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (vt) {
            AVMutableComposition *comp = [AVMutableComposition composition];
            AVMutableCompositionTrack *cv = (AVMutableCompositionTrack *)[comp addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                                   preferredTrackID:kCMPersistentTrackID_Invalid];
            if ([cv insertTimeRange:CMTimeRangeMake(kCMTimeZero, asset.duration) ofTrack:vt atTime:kCMTimeZero error:NULL])
                item = [AVPlayerItem playerItemWithAsset:comp];
        }
    } @catch (__unused NSException *e) { item = nil; }
    if (!item) item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];

    AVQueuePlayer *pl = [[AVQueuePlayer alloc] init];
    pl.muted = YES;
    pl.volume = 0.0f;
    pl.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    if ([pl respondsToSelector:@selector(setPreventsDisplaySleepDuringVideoPlayback:)])
        pl.preventsDisplaySleepDuringVideoPlayback = NO;
    AVPlayerLooper *lo = [AVPlayerLooper playerLooperWithPlayer:pl templateItem:item];
    AVPlayerLayer *vl = [AVPlayerLayer playerLayerWithPlayer:pl];
    vl.videoGravity = AVLayerVideoGravityResizeAspectFill;
    vl.frame = host.bounds;
    vl.masksToBounds = YES;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [host addSublayer:vl];
    [CATransaction commit];

    gDICCPlayer = pl;
    gDICCLooper = lo;
    gDICCContentLayer = vl;
    gDICCCurPath = path;
    /* CALayer 没有 window 属性 —— 用 superlayer 判断"是否还在图层树里"即可:
       层一旦被移出树, superlayer 变 nil, 这时候就不要 play, 省电。 */
    if (host.superlayer) [pl play];
    DLog(@"[壁纸图层] 内容层(视频)已挂入: %@", path.lastPathComponent);
}

/* tick 里调用: 素材/外观变了把内容换掉(此时必然在主队列, 时机安全) */
static void diCCSyncBackdropContent(void) {
    if (!wpOn) return;
    if (!gDICCContentLayer) return;   /* 还没挂过, 等 layoutSubviews 那边去建 */
    diCCLoadContentInto(gDICCContentLayer.superlayer);
}


/* ---- 核心: 在 layoutSubviews 里把层挂到磨砂层自己的 layer 上 ----------------
   与 2.7.20 的根本差别:
     · 2.7.20 用 [mv insertSubview:atIndex:0]  → 系统填充时被清理 → 抖动
     · 本版   用 [mv.layer addSublayer:]        → 系统不扫 CALayer  → 稳定
   另外所有重活(读偏好/建播放器/载片)都做了"只在状态变化时做一次"的闸门,
   不再每帧进入 —— 2.7.20 卡白苹果就是每帧都进重活造成的。

   2.7.23 —— 从 252 号日志里揪出的真凶, 也是"前后延迟 1 秒"的真正来源:

     [21:14:59] 控制中心壁纸已挂入 MTMaterialView 内部 (430x932) 层序=0/共1
     [21:14:59]        [0] DIWallpaperView {{0, 0}, {430, 932}} alpha=1.00
     [21:15:00] 父级已离开屏幕, 壁纸立刻撤下(保持原生)
     [21:15:01] 控制中心壁纸已挂入 MTMaterialView 内部 (430x932) 层序=0/共1
     [21:15:02] 父级已离开屏幕, 壁纸立刻撤下(保持原生)

   三个字概括: **"共1"**。挂进去的那一刻, MTMaterialView 里除了我们自己什么
   都没有 —— 因为展开动画期间它还是个空壳, 系统的 _UIBackdropEffectView
   是动画中后段才填进来的。在此之前, 磨砂层的 backgroundColor 是 clear,
   我们挂在它下面的层跟着一起透明 → 视觉上"没有背景"; 系统填东西的时候
   顺带把视图清理一遍, 我们就被踢出去 → "父级已离开屏幕" → 撤下 → 下一轮
   再挂。挂上→看不见→被踢→再挂, 一秒一个来回 = 用户看到的 1 秒延迟。

   所以本版做两件事, 缺一不可:
     ① 壁纸层不再挂在磨砂层下面(会被它 0 alpha 拖累), 而是挂到**磨砂层
        的兄弟位置、层序 0** —— 兄弟层不受磨砂层透明度影响, 展开动画一开始
        就能看见, 这就是"零延迟"的来源;
     ② 一旦挂过就记住宿主视图, 之后每个 tick(60Hz) 只做亚毫秒级的
        "还在不在 + 尺寸对不对", 被系统踢掉立刻重挂 —— 即使又被踢,
        重挂是 0.01ms 的事, 肉眼看不到闪。

   宿主用 NSHashTable(weak) 存, 控制中心窗口销毁时自动出表, 不会留野指针。 */
static NSHashTable *gDICCHosts;          /* weak: 所有挂过壁纸的全屏磨砂层 */
static UIView *gDICCLastHost;            /* 最近一次成功挂载的宿主, 优先照顾 */
static BOOL gDICCDiagDone;               /* 诊断日志只打一次, 不刷屏 */

static void diCCRememberHost(UIView *mv) {
    if (!mv) return;
    if (!gDICCHosts) gDICCHosts = [NSHashTable weakObjectsHashTable];
    if (![gDICCHosts containsObject:mv]) [gDICCHosts addObject:mv];
    gDICCLastHost = mv;
}

/* 2.7.23: 把壁纸层挂到**磨砂层的父视图**上(层序 0), 而不是磨砂层自己下面。
   理由见上面那段注释 ①。同时把磨砂层自己的底色清成 clear —— 系统在动画
   期间不会主动设它, 留着不透明的旧值反而会盖住我们的壁纸。 */
static void diCCAttachLayerToHost(UIView *mv, CALayer *mine) {
    if (!mv || !mine) return;
    CALayer *host = mv.layer.superlayer ?: mv.layer;
    if (!host) return;
    if (mine.superlayer == host) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [mine removeFromSuperlayer];
    [host insertSublayer:mine atIndex:0];
    [CATransaction commit];
}

static void diCCApplyBackdropTo(UIView *mv) {
    if (!mv || !wpOn) return;
    if (gCCOverlayHooked) {
        /* 2.7.37: 新路径(ccvideobg 兄弟层)已成立, 旧 CALayer 路径永久让位 ——
           顺手把这条路径历史上挂过的残留层(及隐形播放器)清干净, 杜绝两层叠加 */
        CALayer *mvl = mv.layer;
        for (CALayer *s in [mvl.superlayer.sublayers copy])
            if ([s.name hasPrefix:@"DIWallpaperLayer-"]) [s removeFromSuperlayer];
        for (CALayer *s in [mvl.sublayers copy])
            if ([s.name hasPrefix:@"DIWallpaperLayer-"]) [s removeFromSuperlayer];
        if (gDICCPlayer) { [gDICCPlayer pause]; gDICCPlayer = nil; gDICCLooper = nil; }
        gDICCContentLayer = nil;
        gDICCCurPath = nil;
        return;
    }
    if (!diIsInControlCenterContext(mv)) {
        /* 诊断: 只在第一次遇到"大块磨砂层却判定不是控制中心"时打一次父链,
           方便下轮日志直接看出该用哪个类名, 不用再猜。 */
        if (!gDICCDiagDone && mv.bounds.size.width >= 200 && mv.bounds.size.height >= 200) {
            gDICCDiagDone = YES;
            NSMutableString *chain = [NSMutableString string];
            int guard = 0;
            for (UIView *p = mv; p && guard++ < 12; p = p.superview)
                [chain appendFormat:@" ← %@(%.0fx%.0f)", NSStringFromClass(p.class),
                                     p.bounds.size.width, p.bounds.size.height];
            RLog(@"[壁纸图层] 判定不是控制中心, 父链:%@", chain);
        }
        return;
    }

    CALayer *mvl = mv.layer;
    if (!mvl) return;

    /* 去重: 参考实现用 viewWithTag: 配合 tag 0x22c3。
       这里用 layer 的 name 做同样的事(层没有 tag, name 是等价物)。
       因为宿主是磨砂层的父视图, 一个父视图下可能有多个磨砂层,
       所以名字里带上磨砂层自己的地址做区分, 避免串台。 */
    NSString *myName = [NSString stringWithFormat:@"DIWallpaperLayer-%p", (__bridge void *)mv];
    CALayer *parent = mvl.superlayer ?: mvl;
    CALayer *mine = nil;
    for (CALayer *s in parent.sublayers) {
        if ([s.name isEqualToString:myName]) { mine = s; break; }
    }

    CGSize bs = mv.bounds.size;
    if (bs.width < 10 || bs.height < 10) return;
    CGRect want = CGRectMake(0, 0, bs.width, bs.height);

    if (!mine) {
        mine = diNewBackdropLayer();
        mine.name = myName;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        mine.frame = want;
        [parent insertSublayer:mine atIndex:0];
        [CATransaction commit];
        DLog(@"[壁纸图层] 已挂入 (%.0fx%.0f) 宿主=%@ 层序=0/共%lu —— 挂在磨砂层父级, 不受其 0 alpha 拖累",
             bs.width, bs.height, NSStringFromClass(parent.delegate.class),
             (unsigned long)parent.sublayers.count);
    } else if (!CGRectEqualToRect(mine.frame, want)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        mine.frame = want;
        [CATransaction commit];
    } else if (mine.superlayer != parent) {
        diCCAttachLayerToHost(mv, mine);   /* 被挪走了, 拉回来 */
    }

    mine.hidden = NO;
    mine.opacity = 1.0f;

    /* 内容(图片/视频层)挂在壁纸层上 —— 与参考实现同构: 宿主 → 背景层 → 内容层 */
    diCCLoadContentInto(mine);
    diCCRememberHost(mv);
}

/* 2.7.23: 每个 tick 调一次(主线程, 60Hz)。只做三件纯算术的事, 亚毫秒级:
   ① 宿主还在不在图层树里(系统踢掉/窗口销毁都会让它 superlayer 变 nil);
   ② 尺寸对不对(横竖屏切换/分屏);
   ③ 壁纸层还在不在。
   任何一条不满足就重挂 —— 这就是"零延迟"的兜底: 就算又被踢, 下一帧(16ms)
   就已经重新在场, 肉眼完全看不到空隙。
   重活(读偏好/建播放器)不在这里, 由 diCCLoadContentInto 的路径闸门挡住。 */
static void diCCTickBackdrop(void) {
    if (!wpOn) return;
    if (gCCOverlayHooked) return;      /* 2.7.27: 新路径已成立, 旧路径让位 */
    if (!gDICCHosts || gDICCHosts.count == 0) return;

    UIView *last = gDICCLastHost;
    if (last && last.window == nil) gDICCLastHost = nil;

    for (UIView *mv in gDICCHosts.allObjects) {
        if (!mv) continue;
        CALayer *mvl = mv.layer;
        if (!mvl) continue;
        /* 已经离开屏幕: 不动它, 等它回来由 didMoveToWindow / layoutSubviews 处理 */
        if (!mv.window) continue;
        CGSize bs = mv.bounds.size;
        if (bs.width < 10 || bs.height < 10) continue;

        NSString *myName = [NSString stringWithFormat:@"DIWallpaperLayer-%p", (__bridge void *)mv];
        CALayer *parent = mvl.superlayer ?: mvl;
        CALayer *mine = nil;
        for (CALayer *s in parent.sublayers) {
            if ([s.name isEqualToString:myName]) { mine = s; break; }
        }
        if (!mine) {
            /* 被系统清理掉了 → 立刻重挂(重建层比"找回来"简单且必然成功) */
            diCCApplyBackdropTo(mv);
            continue;
        }
        CGRect want = CGRectMake(0, 0, bs.width, bs.height);
        if (!CGRectEqualToRect(mine.frame, want) || mine.superlayer != parent) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            if (mine.superlayer != parent) [parent insertSublayer:mine atIndex:0];
            mine.frame = want;
            [CATransaction commit];
        }
        /* 视频被系统暂停(进过后台/掉帧)时把播放续上, 这一步只是状态比较 */
        if (gDICCPlayer && gDICCCurPath && gDICCContentLayer &&
            gDICCContentLayer.superlayer &&
            gDICCPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying) {
            [gDICCPlayer play];
        }
    }
}

static void diCCHookedMTLayoutSubviews(id self, SEL _cmd) {
    if (diOrigMTLayout) ((void (*)(id, SEL))diOrigMTLayout)(self, _cmd);

    /* 启动静默期: SpringBoard 刚起来时 MTMaterialView 会被大量创建(锁屏/状态栏),
       那段时间完全不参与, 让系统先起稳。这是 2.7.20 卡白苹果的直接教训。
       2.7.23: 从 20 秒缩到 3 秒 —— 20 秒太长, 用户越狱后马上拉控制中心会看到
       "没背景", 误以为坏了。3 秒足够躲开 SpringBoard 启动最疯狂的那一段,
       而且本版 hook 体已经是纯算术(不建对象/不读文件), 本身就不危险。 */
    if (!gDiLaunchTime) return;
    if (CFAbsoluteTimeGetCurrent() - gDiLaunchTime < 3.0) return;
    if (!wpOn) return;

    UIView *mv = (UIView *)self;
    if (!mv || mv.hidden) return;
    /* 只在"有足够面积"的磨砂层上干活, 避免给每个小卡片都建层。
       这一条是纯算术, 与上下文判定叠加使用。 */
    if (mv.bounds.size.width < 100 || mv.bounds.size.height < 100) return;

    @try {
        diCCApplyBackdropTo(mv);
    } @catch (NSException *e) {
        RLog(@"[壁纸图层] layoutSubviews 挂载异常: %@ — %@", e.name, e.reason);
    }
}

static void diCCHookedMTDidMoveToWindow(id self, SEL _cmd) {
    if (diOrigMTDidMoveToWindow) ((void (*)(id, SEL))diOrigMTDidMoveToWindow)(self, _cmd);
    if (!gDiLaunchTime) return;
    if (CFAbsoluteTimeGetCurrent() - gDiLaunchTime < 3.0) return;
    UIView *mv = (UIView *)self;
    if (!mv || !wpOn) return;
    if (!mv.window) {
        /* 2.7.23: 离开窗口时**不再**把层摘掉。
           摘了之后系统再把它放回窗口时, layoutSubviews 未必会立刻被调用,
           中间就是"空白"—— 这正是用户感觉到的"退出那一下闪一下"。
           现在改为: 层留着(反正窗口不可见, 不会被看到也不耗电, 视频由
           visibility 事件去暂停), 回来时立刻就在场, 零延迟。 */
        if (gDICCPlayer && gDICCPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying)
            [gDICCPlayer pause];
        return;
    }
    @try { diCCApplyBackdropTo(mv); } @catch (__unused NSException *e) {}
}

/* ============================================================================
   2.7.27: 控制中心壁纸 —— 移植 rascal/ccvideobg 0.5 的完整机制
   ============================================================================

   这套源码(Hooks/RascalCCVideoBGMain.xm + Sources/RascalCCVideoBGPlayer.m)
   给出了一个与本项目此前所有尝试都不同的答案。逐条对照:

     ┌ 环节        ┌ 本项目 2.7.20~2.7.26        ┌ ccvideobg 0.5
     ├ hook 目标   ├ MTMaterialView              ├ CCUIModularControlCenterOverlayViewController
     ├ 定位背景    ├ 猜哪块磨砂层是背景          ├ 控制器自己的 overlayBackgroundView 属性
     ├ 挂载方式    ├ addSublayer 到磨砂层        ├ insertSubview:aboveSubview: 兄弟层
     ├ 显隐时机    ├ 靠 window 可见性/每帧轮询  ├ _beginPresentation / _beginDismissal
     └ 结果        └ 挂了被踢、进出抖 1 秒       └ 一次挂上, 进出只切 hidden

   三个关键点:
     ① overlayBackgroundView 是控制中心自己的背景视图, 不用猜 ——
        之前按类名找 MTMaterialView 找了七个版本都没找对, 因为根本不用找;
     ② surface 挂在 background 的**兄弟位置、之上**, 不是在它内部 ——
        系统填充/清理 background 时碰不到兄弟层, 所以不会被踢;
     ③ 展开/收起由控制器自己的两个私有方法给出精确时机 ——
        不需要"每帧轮询在不在树上"那种补救, 也就没有 1 秒延迟。

   本版照搬这三条, 素材仍用本项目自己的浅色/深色两套(跟随深色模式)。
   旧路径(MTMaterialView CALayer)保留作兜底, 但本路径成立时自动让位,
   两层不会同时显示。 */

static UIView *gCCSurface;                 /* 承载壁纸的兄弟层 */
static AVQueuePlayer *gCCPlayer;
static AVPlayerLooper *gCCLooper;
static AVPlayerLayer *gCCLayer;
static NSString *gCCPath;
static BOOL gCCVisible;

static IMP diOrigCCViewDidLoad;
static IMP diOrigCCWillLayout;
static IMP diOrigCCBeginPres;
static IMP diOrigCCBeginDis;
static IMP diOrigCCDidDisappear;
static IMP diOrigCCWillPresent, diOrigCCWillDismiss;

/* 取控制器的 overlayBackgroundView。这是私有属性, 用 KVC 取最稳 ——
   respondsToSelector 先探, 探不到退 valueForKey, 都没有就返回 nil。 */
static UIView *diCCBackgroundOf(id vc) {
    if (!vc) return nil;
    UIView *bg = nil;
    @try {
        SEL s = NSSelectorFromString(@"overlayBackgroundView");
        if ([vc respondsToSelector:s]) {
            bg = ((id (*)(id, SEL))objc_msgSend)(vc, s);
        }
        if (![bg isKindOfClass:[UIView class]]) {
            id v = [vc valueForKey:@"overlayBackgroundView"];
            bg = [v isKindOfClass:[UIView class]] ? v : nil;
        }
    } @catch (__unused NSException *e) { bg = nil; }
    return bg;
}

/* 2.8.48: 白底根治 —— 316 深挖 + 录屏像素实锤: 滚动时整屏(除模块卡片)变亮
   (实测边缘像素 203~228), 而视图树里没有任何白色层(底色/opaque 全清过也没用)。
   结论: 系统磨砂层滚动时切到更厚更亮的配方, 经 backdrop 渲染通道盖在壁纸之上。
   壁纸静态时本就完全遮住磨砂层 → 直接把背景磨砂层透明化, 静态视觉零变化,
   白底根源拔掉; 收起/关开关时还原 alpha, 不污染系统其它场景。 */
/* 2.8.50: 只压制手势容器里有可验证浅色填充的独立背景层。
   不碰 SBBarSwipeAffordanceView 本体、对应 UIView 的 layer 或响应链。 */
static NSMapTable<CALayer *, NSNumber *> *gCCLightLayers;
static void diCCRestoreAffordanceLayers(void) {
    for (CALayer *l in gCCLightLayers) {
        NSNumber *old = [gCCLightLayers objectForKey:l];
        if (old) l.opacity = old.floatValue;
    }
    [gCCLightLayers removeAllObjects];
}
__attribute__((unused)) static void diCCTameAffordanceLayers(void) {
    if (!wpOn || !gCCVisible || !gCCSurface || gCCSurface.isHidden || !gCCSurface.window) return;
    UIView *parent = gCCSurface.superview;
    if (!parent) return;
    UIView *host = parent.superview;
    if (![NSStringFromClass(host.class) isEqualToString:@"SBBarSwipeAffordanceView"] ||
        host.window != gCCSurface.window) return;
    if (!gCCLightLayers) gCCLightLayers = [NSMapTable weakToStrongObjectsMapTable];
    for (CALayer *l in [host.layer.sublayers copy]) {
        if (l == parent.layer || l.delegate != nil || l.isHidden || l.opacity < 0.05) continue;
        if (l.bounds.size.width < host.bounds.size.width * 0.85 ||
            l.bounds.size.height < host.bounds.size.height * 0.4) continue;
        CGColorRef color = l.backgroundColor;
        if (!color) continue; /* 未确定颜色的渲染层不能盲目透明化 */
        UIColor *ui = [UIColor colorWithCGColor:color];
        CGFloat white = 0, alpha = 0;
        if (![ui getWhite:&white alpha:&alpha] || white < 0.70 || alpha < 0.8) continue;
        if (![gCCLightLayers objectForKey:l]) {
            [gCCLightLayers setObject:@(l.opacity) forKey:l];
            RLog(@"[控制中心] 手势容器浅色背景层命中 %@ %@ white=%.2f (保留手势视图)",
                 NSStringFromClass(l.class), NSStringFromCGRect(l.frame), white);
        }
        l.opacity = 0.0;
    }
}
/* 2.8.53: 52 在模块视图内部 insertSubview 后 SpringBoard 重启。
   回退到 ccvideobg 已验证的背景兄弟层；不在滚动 hook 中插入模块子视图。 */
static UIView *gCCHiddenMaterial;   /* 被我们透明化的背景磨砂层(收起时还原) */
__attribute__((unused)) static void diCCHideBackdropMaterial(void) {
    if (!wpOn || !gCCVisible || !gCCSurface) return;
    UIView *parent = gCCSurface.superview;
    if (!parent) return;
    Class mt = NSClassFromString(@"MTMaterialView");
    for (UIView *v in parent.subviews) {
        if (v == gCCSurface || ![v isKindOfClass:mt]) continue;
        if (v.alpha != 0.0) {
            v.alpha = 0.0;
            RLog(@"[控制中心] 背景磨砂层透明化(拔白底根源): %@ %.0fx%.0f",
                 NSStringFromClass(v.class), v.bounds.size.width, v.bounds.size.height);
        }
        gCCHiddenMaterial = v;
    }
}
static void diCCRestoreBackdropMaterial(void) {
    if (gCCHiddenMaterial) {
        if (gCCHiddenMaterial.alpha == 0.0) gCCHiddenMaterial.alpha = 1.0;
        gCCHiddenMaterial = nil;
    }
}

/* ===== 2.7.28 ① 浅色 / 深色素材彻底分开 =====

   之前: 浅色和深色共用同一个目录 /var/mobile/灵动岛/壁纸素材,
        两个选择器扫出来的列表一模一样, 挑的时候全靠文件名靠记忆区分。
   现在: 各自一个子目录 ——
          浅色 → /var/mobile/灵动岛/壁纸素材/浅色
          深色 → /var/mobile/灵动岛/壁纸素材/深色
        根目录里的老素材仍然会被扫到(列在后面), 所以**现有素材不用挪**。
        解析时"子目录优先, 根目录兜底", 之前选过的相对路径也不会失效。 */
static NSString *const kWallpaperDirLight = @"/var/mobile/灵动岛/壁纸素材/浅色";
static NSString *const kWallpaperDirDark  = @"/var/mobile/灵动岛/壁纸素材/深色";

static NSString *diWallpaperRootFor(BOOL dark) { return dark ? kWallpaperDirDark : kWallpaperDirLight; }

/* 当前外观该看的素材清单(绝对路径, 直接可用)。子目录在前, 根目录老素材在后。 */
static NSArray<NSString *> *diWallpaperPathsFor(BOOL dark) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSString *base = diWallpaperRootFor(dark);
    for (NSString *r in diWallpaperListIn(base, 3)) [out addObject:[base stringByAppendingPathComponent:r]];
    NSString *other = diWallpaperRootFor(!dark);
    NSString *bp = [base stringByAppendingString:@"/"], *op = [other stringByAppendingString:@"/"];
    for (NSString *r in diWallpaperListIn(kWallpaperDir, 3)) {
        NSString *full = [kWallpaperDir stringByAppendingPathComponent:r];
        if ([full hasPrefix:bp] || [full hasPrefix:op]) continue;   /* 两个子目录已单独列过 */
        [out addObject:full];
    }
    return out;
}

/* 按外观解析相对路径: 子目录 → 根目录 → 同名兜底 */
static NSString *diWallpaperResolveFor(NSString *rel, BOOL dark) {
    if (!rel.length || [rel isEqualToString:@"__none__"]) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *base = diWallpaperRootFor(dark);
    NSString *p = [base stringByAppendingPathComponent:rel];
    if ([fm fileExistsAtPath:p]) return p;
    p = [kWallpaperDir stringByAppendingPathComponent:rel];
    if ([fm fileExistsAtPath:p]) return p;
    NSString *want = rel.lastPathComponent;
    for (NSString *full in diWallpaperPathsFor(dark))
        if ([full.lastPathComponent isEqualToString:want]) return full;
    return nil;
}

/* ===== 2.7.32: 壁纸不再分深浅, 只有一个素材 =====
   之前 浅色/深色 各一套 + 跟随系统外观, 实测外观判定在 SpringBoard 里一直判不准,
   用户也嫌两套难打理。现在: 一个素材通吃, 目录照旧兼容 ——
   扫描 = 根目录 + 旧"浅色"子目录 + 旧"深色"子目录(按文件名去重, 老素材不丢),
   解析 = 三个位置都找一遍, 之前存的相对路径全部还认。 */
static NSArray<NSString *> *diWallpaperPathsAll(void) {
    static NSArray<NSString *> *cache = nil;
    static NSDate *stamp = nil;
    if (cache && stamp && -[stamp timeIntervalSinceNow] < 2.0) return cache;
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSArray<NSString *> *bases = @[kWallpaperDir, kWallpaperDirLight, kWallpaperDirDark];
    for (NSString *b in bases) {
        for (NSString *r in diWallpaperListIn(b, 3)) {
            NSString *full = [b stringByAppendingPathComponent:r];
            if ([seen containsObject:r]) continue;   /* 同名只留第一个(根目录优先) */
            [seen addObject:r];
            [out addObject:full];
        }
    }
    cache = [out copy];
    stamp = [NSDate date];
    return cache;
}

/* 只存了文件名时, 三个位置都找一遍(兼容 2.7.28 之前存的各种相对路径) */
static NSString *diWallpaperResolveAny(NSString *rel) {
    if (!rel.length || [rel isEqualToString:@"__none__"]) return nil;
    NSString *p = diWallpaperResolveFor(rel, NO);
    if (!p) p = diWallpaperResolveFor(rel, YES);
    if (!p) p = diWallpaperResolve(rel);
    if (!p) {
        NSString *want = rel.lastPathComponent;
        for (NSString *full in diWallpaperPathsAll())
            if ([full.lastPathComponent isEqualToString:want]) { p = full; break; }
    }
    return p;
}

/* 绝对路径 → 存储的相对路径(统一相对总目录, 一套就够) */
static NSString *diWallpaperRelAny(NSString *full) {
    if (!full.length) return @"__none__";
    NSString *rp = [kWallpaperDir stringByAppendingString:@"/"];
    if ([full hasPrefix:rp]) return [full substringFromIndex:rp.length];
    NSString *lp = [kWallpaperDirLight stringByAppendingString:@"/"];
    if ([full hasPrefix:lp]) return [[@"浅色" stringByAppendingString:@"/"] stringByAppendingString:[full substringFromIndex:lp.length]];
    NSString *dp = [kWallpaperDirDark stringByAppendingString:@"/"];
    if ([full hasPrefix:dp]) return [[@"深色" stringByAppendingString:@"/"] stringByAppendingString:[full substringFromIndex:dp.length]];
    return full.lastPathComponent;
}


/* ===== 2.7.28 ② 声音开关 =====

   要求: "音频跟视频不要跟其他冲突"。做法是三件事一起做 ——
     ① 出声时才**不剥音轨**(静音时仍然剥掉, 和岛上视频一样零音频占用);
     ② AVAudioSession 用 **Ambient + MixWithOthers**: 既不打断正在放的音乐,
        也不会被音乐/来电打断, 两边叠着放;
     ③ 控制中心**收起立刻 deactivate** 并带 NotifyOthersOnDeactivation,
        把音频会话完整还给系统, 不留残余。
   这样灵动岛视频(剥音轨 + muted, 独立 player)与控制中心声音互不干扰。 */
static BOOL gCCAudioActive = NO;

static void diCCAudioSession(BOOL on) {
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        if (on) {
            if (gCCAudioActive) return;
            [s setCategory:AVAudioSessionCategoryAmbient
               withOptions:AVAudioSessionCategoryOptionMixWithOthers
                     error:NULL];
            if ([s setActive:YES error:NULL]) {
                gCCAudioActive = YES;
                DLog(@"[控制中心] 音频会话已激活(ambient 混入, 不打断其它声音)");
            }
        } else {
            if (!gCCAudioActive) return;
            [s setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:NULL];
            gCCAudioActive = NO;
        }
    } @catch (__unused NSException *e) {}
}

/* ===== 2.7.32 循环播放 / 背景模糊 ===== */
/* 定时器的接收者(NSTimer 会 retain target, 用单例对象而不是视图, 免得把控制中心拖住) */
@interface DICCLoopTicker : NSObject
+ (instancetype)shared;
- (void)tick:(NSTimer *)t;
@end
static NSTimer *gCCLoopTimer = nil;
static NSInteger gCCLoopIdx = 0;
static NSTimeInterval gCCLoopIV = 0;
static UIVisualEffectView *gCCBlurFx = nil;   /* 2.7.35: 视频高斯覆盖层(不重建播放器, 所以不会闪) */
/* 前向声明(实现在 diCCReloadSurface 之后) */
static void diCCLoopSchedule(NSTimeInterval iv);
static void diCCLoopInvalidate(void);
static void diCCApplyBlur(void);
static NSTimeInterval diCCLoopIntervalFor(NSString *path);
static UIImage *diBlurredImage(UIImage *im, CGFloat radius);

static void diCCReleasePlayer(void) {
    [gCCPlayer pause];
    [gCCLooper disableLooping];
    [gCCPlayer removeAllItems];
    gCCLayer.player = nil;
    [gCCLayer removeFromSuperlayer];
    gCCLayer = nil;
    gCCLooper = nil;
    gCCPlayer = nil;
    gCCPath = nil;
    [gCCBlurFx removeFromSuperview]; gCCBlurFx = nil;   /* 2.7.35 */
    /* 2.7.37: 连带清掉 surface 上一切内容子层(图片分支的局部 CALayer 不归上面管,
       任何历史路径残留都在这里一次性扫干净 —— 用户截图里"右边多一块素材"的保险 */
    if (gCCSurface) for (CALayer *old in [gCCSurface.layer.sublayers copy]) [old removeFromSuperlayer];
    diCCAudioSession(NO);
}

/* 素材路径变了 / 开关变了 / 显隐变了 → 重建或释放播放器 */
static BOOL diCCDarkAppearance(void) {
    if (gCCSurface.window) return gCCSurface.window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows)
            if (w.isKeyWindow) return w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
}
static void diCCReloadSurface(void) {
    if (!wpOn) { diCCReleasePlayer(); diCCLoopInvalidate(); if (gCCSurface) gCCSurface.hidden = YES; diCCRestoreBackdropMaterial(); diCCRestoreAffordanceLayers(); return; }

    /* 2.7.32: 单素材模式; 开了循环播放就轮播目录下全部素材 */
    NSString *path = nil;
    if (wpLoopOn) {
        NSArray<NSString *> *list = diWallpaperPathsAll();
        if (!list.count) { diCCReleasePlayer(); diCCLoopInvalidate(); if (gCCSurface) gCCSurface.hidden = YES; return; }
        if (gCCLoopIdx >= (NSInteger)list.count || gCCLoopIdx < 0) gCCLoopIdx = 0;
        path = list[gCCLoopIdx];
    } else {
        BOOL dark = diCCDarkAppearance();
        path = diWallpaperResolveAny(dark ? wpDarkAsset : wpLightAsset);
        if (!path) path = diWallpaperResolveAny(dark ? wpLightAsset : wpDarkAsset); /* 旧用户兜底 */
    }
    if (!path.length) { diCCReleasePlayer(); diCCLoopInvalidate(); if (gCCSurface) gCCSurface.hidden = YES; return; }

    /* 已经在播同一个文件 → 什么都不做(每帧/每次布局进来都走这里, 必须是廉价出口) */
    if (gCCPath && [gCCPath isEqualToString:path]) {
        gCCSurface.hidden = !gCCVisible;
        if (gCCPlayer) {
            BOOL wantSound = ccSoundOn;
            gCCPlayer.muted = !wantSound;
            gCCPlayer.volume = wantSound ? 1.0f : 0.0f;
            if (gCCVisible) {
                if (gCCPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying) [gCCPlayer play];
                diCCAudioSession(wantSound);
                if (!wantSound) diCCAudioSession(NO);
            }
        }
        diCCApplyBlur();
        /* 循环开着但控制中心已收起 → 不轮播, 展开时再排 */
        if (wpLoopOn && gCCVisible) diCCLoopSchedule(diCCLoopIntervalFor(path)); else diCCLoopInvalidate();
        return;
    }

    /* 2.8.54: 切素材前先确认新图片能解码；旧画面保持在原位置。
       不再先清空 surface 后读文件。 */
    if (![[NSFileManager defaultManager] isReadableFileAtPath:path]) return;
    if (!diWallpaperIsVideo(path)) {
        UIImage *im = [UIImage imageWithContentsOfFile:path];
        if (!im) return;
        if (wpBlur > 0) im = diBlurredImage(im, (CGFloat)wpBlur / 100.0 * 40.0);
        CALayer *l = [CALayer layer];
        l.contents = (__bridge id)im.CGImage;
        l.contentsGravity = kCAGravityResizeAspectFill;
        l.masksToBounds = YES;
        l.frame = gCCSurface.bounds;
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        [gCCSurface.layer addSublayer:l]; /* 先显示新内容，再释放旧播放器 */
        [CATransaction commit];
        diCCReleasePlayer();
        [gCCSurface.layer addSublayer:l];
        gCCPath = path;
        gCCSurface.hidden = !gCCVisible;
        diCCApplyBlur();
        if (wpLoopOn && gCCVisible) diCCLoopSchedule(diCCLoopIntervalFor(path)); else diCCLoopInvalidate();
        DLog(@"[控制中心] 壁纸就绪(图片): %@%@", path.lastPathComponent,
             wpBlur > 0 ? [NSString stringWithFormat:@" (模糊%d)", (int)wpBlur] : @"");
        return;
    }

    /* 视频: 默认剥音轨 + 静音 + 循环(和岛上视频同一套做法);
       开了"声音"就保留完整音轨走 ambient 混入, 见 diCCAudioSession 的说明。 */
    BOOL wantSound = ccSoundOn;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path]
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVPlayerItem *item = nil;
    if (!wantSound) @try {
        AVAssetTrack *vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (vt) {
            AVMutableComposition *comp = [AVMutableComposition composition];
            AVMutableCompositionTrack *cv = (AVMutableCompositionTrack *)[comp addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                                   preferredTrackID:kCMPersistentTrackID_Invalid];
            if ([cv insertTimeRange:CMTimeRangeMake(kCMTimeZero, asset.duration) ofTrack:vt atTime:kCMTimeZero error:NULL])
                item = [AVPlayerItem playerItemWithAsset:comp];
        }
    } @catch (__unused NSException *e) { item = nil; }
    /* 出声时 item 为 nil(上面整段跳过) → 直接用原 asset, 音轨完整保留 */
    if (!item) item = [AVPlayerItem playerItemWithAsset:asset];

    /* 2.7.29 性能: 限定解码分辨率。素材动辄 1080p/2K, 铺在控制中心其实
       用不到那么清楚, 但解码压力是实打实的掉帧来源。这里按屏幕短边 ×1.0
       封顶( retina 下仍够清晰), 解码量能降一大截。 */
    @try {
        CGFloat sc = MAX(UIScreen.mainScreen.bounds.size.width, UIScreen.mainScreen.bounds.size.height);
        CGFloat cap = sc * UIScreen.mainScreen.scale * 0.75;
        if ([item respondsToSelector:@selector(setPreferredMaximumResolution:)])
            item.preferredMaximumResolution = CGSizeMake(cap, cap);
    } @catch (__unused NSException *e) {}

    AVQueuePlayer *pl = [AVQueuePlayer queuePlayerWithItems:@[]];
    pl.muted = !wantSound;
    pl.volume = wantSound ? 1.0f : 0.0f;
    pl.automaticallyWaitsToMinimizeStalling = YES;
    if ([pl respondsToSelector:@selector(setPreventsDisplaySleepDuringVideoPlayback:)])
        pl.preventsDisplaySleepDuringVideoPlayback = NO;
    AVQueuePlayer *oldPlayer = gCCPlayer;
    AVPlayerLooper *oldLooper = gCCLooper;
    NSString *oldPath = gCCPath;
    NSArray<CALayer *> *oldLayers = [gCCSurface.layer.sublayers copy];
    gCCLooper = [AVPlayerLooper playerLooperWithPlayer:pl templateItem:item];
    gCCLayer = [AVPlayerLayer playerLayerWithPlayer:pl];
    gCCLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    gCCLayer.frame = gCCSurface.bounds;
    gCCLayer.masksToBounds = YES;
    /* 新帧未就绪时保留旧图层；readyForDisplay 后再一起撤下。 */
    gCCLayer.opacity = oldLayers.count ? 0.0f : 1.0f;
    [gCCSurface.layer addSublayer:gCCLayer];
    gCCPlayer = pl;
    gCCPath = path;
    gCCSurface.hidden = !gCCVisible;
    diCCApplyBlur();
    if (gCCVisible) {
        [pl play];
        if (wantSound) diCCAudioSession(YES);
    }
    /* 等新视频真的渲染出第一帧，再在同一 CATransaction 替换画面。
       不让空 AVPlayerLayer 提前盖住原画面；超时则继续显示旧画面。 */
    if (oldLayers.count) {
        AVPlayerLayer *nextLayer = gCCLayer;
        AVPlayerLooper *nextLooper = gCCLooper;
        __block int checks = 0;
        __block __weak void (^weakCheckFrame)(void) = nil;
        void (^checkFrame)(void) = ^{
            if (gCCLayer != nextLayer || !wpOn) {
                /* 新一次切换可能仍把这些旧层作为兜底，不抢先移除。 */
                if (!wpOn) { [oldPlayer pause]; [oldLooper disableLooping]; }
                return;
            }
            if (nextLayer.readyForDisplay || ++checks >= 90) {
                if (nextLayer.readyForDisplay) {
                    [CATransaction begin]; [CATransaction setDisableActions:YES];
                    nextLayer.opacity = 1.0f;
                    for (CALayer *l in oldLayers) [l removeFromSuperlayer];
                    [CATransaction commit];
                    [oldPlayer pause]; [oldLooper disableLooping];
                    DLog(@"[控制中心] 新视频首帧已显示，旧素材撤下");
                } else {
                    DLog(@"[控制中心] 新视频首帧超时，保留旧画面");
                    [pl pause]; [nextLooper disableLooping];
                    [nextLayer removeFromSuperlayer];
                    gCCPlayer = oldPlayer; gCCLooper = oldLooper;
                    gCCLayer = [oldLayers.firstObject isKindOfClass:[AVPlayerLayer class]] ? (AVPlayerLayer *)oldLayers.firstObject : nil;
                    gCCPath = oldPath; /* 继续显示旧画面 */
                }
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), weakCheckFrame);
        };
        weakCheckFrame = checkFrame;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), checkFrame);
    }
    if (wpLoopOn && gCCVisible) diCCLoopSchedule(diCCLoopIntervalFor(path)); else diCCLoopInvalidate();
    DLog(@"[控制中心] 壁纸就绪(视频): %@ (%@)%@", path.lastPathComponent, wantSound ? @"带声音" : @"静音",
         wpBlur > 0 ? [NSString stringWithFormat:@" (模糊%d)", (int)wpBlur] : @"");
}

/* ===== 2.7.32 循环播放 =====
   开"循环播放"后忽略单个素材的选择, 按目录顺序一个个往下放:
   图片固定 6 秒一张, 视频按其自身时长(3~20 秒封顶, 太短太长都不好看)。
   控制中心**收起时定时器直接注销**——收起了还换素材纯属白烧电, 展开再排。 */
static NSTimeInterval diCCLoopIntervalFor(NSString *path) {
    if (!diWallpaperIsVideo(path)) return 6.0;
    NSTimeInterval d = 6.0;
    @try {
        AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        if (CMTimeGetSeconds(a.duration) > 0) d = CMTimeGetSeconds(a.duration);
    } @catch (__unused NSException *e) {}
    if (d < 3.0) d = 3.0; if (d > 20.0) d = 20.0;
    return d;
}

static void diCCLoopSchedule(NSTimeInterval iv) {
    if (iv <= 0) return;
    if (gCCLoopTimer && gCCLoopTimer.isValid && fabs(gCCLoopIV - iv) < 0.5) return;   /* 已在跑, 不动 */
    diCCLoopInvalidate();
    gCCLoopIV = iv;
    gCCLoopTimer = [NSTimer scheduledTimerWithTimeInterval:iv target:[DICCLoopTicker shared]
        selector:@selector(tick:) userInfo:nil repeats:NO];
}

static void diCCLoopInvalidate(void) {
    if (gCCLoopTimer) { [gCCLoopTimer invalidate]; gCCLoopTimer = nil; }
    gCCLoopIV = 0;
}

/* ===== 2.7.37 背景模糊 0~100(真·高斯, 只糊素材本身) =====
   视频: 私有 CAFilter "gaussianBlur" 直接挂在 AVPlayerLayer.filters 上 ——
       糊的是素材画面本身, 0=清晰, 100=最糊, 全程不透明。
       (CCBackgroundMod 同款做法, 2.7.22 反汇编笔记里就记着这条)
   图片: CoreImage CIGaussianBlur 预渲染一次(只在换素材/松手时做)。
   2.7.35 的 UIVisualEffectView 毛玻璃盖层彻底弃用 —— 它自带白色半透明材质,
       用户看来就是"变透明/发白", 不是真模糊。 */
static void diCCSetGaussian(CALayer *layer, CGFloat radius) {
    if (!layer) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (radius <= 0.1) {
        if (layer.filters) layer.filters = nil;
    } else {
        static Class CAFilterCls;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ CAFilterCls = NSClassFromString(@"CAFilter"); });
        if (CAFilterCls) {
            id f = ((id(*)(id, SEL, id))objc_msgSend)(CAFilterCls,
                    NSSelectorFromString(@"filterWithType:"), @"gaussianBlur");
            [f setValue:@(radius) forKey:@"inputRadius"];
            layer.filters = @[f];
        }
    }
    [CATransaction commit];
}
static UIImage *diBlurredImage(UIImage *im, CGFloat radius) {
    if (radius < 0.5 || !im) return im;
    @try {
        CIContext *ctx = [CIContext contextWithOptions:nil];
        CIImage *ci = [CIImage imageWithCGImage:im.CGImage];
        /* 先缩到屏幕尺寸再糊: 全分辨率高斯在 A 系上要几百毫秒, 缩过就几十毫秒 */
        CGSize sc = UIScreen.mainScreen.bounds.size;
        CGFloat fit = MIN(1.0, MAX(sc.width, sc.height) / MAX(im.size.width, im.size.height));
        if (fit < 1.0) {
            ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(fit, fit)];
            ci = [ci imageByApplyingFilter:@"CIGaussianBlur" withInputParameters:@{kCIInputRadiusKey: @(radius * fit)}];
        } else {
            ci = [ci imageByApplyingFilter:@"CIGaussianBlur" withInputParameters:@{kCIInputRadiusKey: @(radius)}];
        }
        CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
        if (!cg) return im;
        UIImage *out = [UIImage imageWithCGImage:cg];
        CGImageRelease(cg);
        return out ?: im;
    } @catch (__unused NSException *e) { return im; }
}

static void diCCApplyBlur(void) {
    if (!gCCSurface) return;
    gCCSurface.alpha = 1.0;                   /* 2.7.36: 只控制素材模糊程度, 不再随模糊变透明 */
    [gCCBlurFx removeFromSuperview]; gCCBlurFx = nil;   /* 2.7.37: 毛玻璃盖层废弃 */
    /* 视频素材直接挂高斯滤镜; 图片在加载分支里已用 CIGaussianBlur 预渲染 */
    if (gCCLayer) diCCSetGaussian(gCCLayer, (CGFloat)wpBlur / 100.0 * 40.0);
}

@implementation DICCLoopTicker
+ (instancetype)shared {
    static DICCLoopTicker *s = nil;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [DICCLoopTicker new]; });
    return s;
}
/* 到点换下一个素材: 索引 +1 取模, 再走一次加载(路径变了 → 会重建) */
- (void)tick:(NSTimer *)t {
    gCCLoopTimer = nil;
    gCCLoopIV = 0;
    if (!wpOn || !wpLoopOn || !gCCVisible) return;
    NSArray<NSString *> *list = diWallpaperPathsAll();
    if (list.count < 2) return;
    gCCLoopIdx = (gCCLoopIdx + 1) % (NSInteger)list.count;
    diCCReloadSurface();
}
@end

/* ===== 2.7.28 ③ 控制中心空白处长按换素材 =====

   手势**挂在背景的父容器上**, 不新建覆盖层 —— 新建覆盖层会吃掉控制中心的
   点击和滚动, 挂在父容器上则只是"旁听": 命中任何子视图它都能收到触摸,
   但只有 gestureRecognizerShouldBegin 判定为"空白"时才真的触发。
   判定规则:
     · 命中 MTMaterialView(磨砂底) / CCUIScrollView 本身 → 空白, 允许
     · 命中 UIControl / 名字含 Module|Slider|Button / 其它 CCUI 组件 → 不是空白, 拒绝
   这样点开关、拖滑块、滑模块都完全不受影响。 */
static char kCCPressKey;
static char kCCPressViewKey;

@interface DICCPressTarget : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *owner;
@property (nonatomic, assign) BOOL diPickerDark;
@end

/* ===== 2.7.33: 面板素材缩略图(跟设置页素材列表同款) =====
   图片直接抽缩略帧, 视频用 AVAssetImageGenerator 抓第一帧。
   全部在后台线程算, 主线程只负责贴上; NSCache 缓存, 上下滑动不重复解码。 */
static NSCache *diCCThumbCache(void) {
    static NSCache *c = nil;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ c = [NSCache new]; c.countLimit = 60; });
    return c;
}
static void diCCThumbAsync(NSString *path, void (^cb)(UIImage *im)) {
    if (!path.length || !cb) return;
    UIImage *hit = [diCCThumbCache() objectForKey:path];
    if (hit) { cb(hit); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *im = nil;
        @try {
            if (diWallpaperIsVideo(path)) {
                AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
                AVAssetImageGenerator *g = [AVAssetImageGenerator assetImageGeneratorWithAsset:a];
                g.appliesPreferredTrackTransform = YES;
                g.maximumSize = CGSizeMake(160, 160);
                CGImageRef cg = [g copyCGImageAtTime:CMTimeMake(1, 10) actualTime:NULL error:NULL];
                if (cg) { im = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
            } else {
                CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
                if (src) {
                    NSDictionary *opts = @{(__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                           (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @160,
                                           (__bridge id)kCGImageSourceCreateThumbnailWithTransform: @YES};
                    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
                    if (cg) { im = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
                    CFRelease(src);
                }
            }
        } @catch (__unused NSException *e) {}
        if (im) [diCCThumbCache() setObject:im forKey:path];
        dispatch_async(dispatch_get_main_queue(), ^{ cb(im); });
    });
}

/* ===== 2.7.30: 控制中心中央素材面板 =====

   上一版用 UIAlertController(actionSheet) 有两个问题:
     ① present 到 overlay 控制器上, 偶尔和系统抢焦点(用户报"进插件设置/注销")
     ② actionSheet 素材一多就撑满屏幕, 也不是用户要的"中间显示框可上下滑动"
   这版直接**自己加一个 view 到控制中心窗口**上, 不 present、不碰响应链:
     全屏半透明遮罩(点一下关闭) + 居中卡片(圆角) + UITableView(天然支持滚动)。
   关闭、点击选择、点遮罩关闭三条出路, 收起控制中心时也会自动撤掉。 */
@interface DICCMatCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iv;
@property (nonatomic, strong) UILabel *lb;
@end
@implementation DICCMatCell
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    self.backgroundColor = [UIColor clearColor];
    CGFloat ih = f.size.height - 22.0;
    self.iv = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, f.size.width, ih)];
    self.iv.contentMode = UIViewContentModeScaleAspectFill;
    self.iv.clipsToBounds = YES;
    self.iv.layer.cornerRadius = 10;
    self.iv.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    [self.contentView addSubview:self.iv];
    self.lb = [[UILabel alloc] initWithFrame:CGRectMake(0, ih + 2, f.size.width, 18)];
    self.lb.font = [UIFont systemFontOfSize:11];
    self.lb.textColor = [UIColor whiteColor];
    self.lb.textAlignment = NSTextAlignmentCenter;
    self.lb.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.contentView addSubview:self.lb];
    return self;
}
@end

@interface DICCPickerPanel : UIView <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *titleL;
@property (nonatomic, strong) UICollectionView *grid;
@property (nonatomic, strong) UIView *btnRow;
@property (nonatomic, copy) NSArray<NSString *> *paths;
@property (nonatomic, copy) NSString *curPath;
@property (nonatomic, assign) BOOL dark;
@property (nonatomic, copy) void (^onChoose)(NSString *full);
/* 2.7.33: 标题区左右滑动调背景模糊 */
@property (nonatomic, strong) UILabel *blurL;
@property (nonatomic, assign) NSInteger panBase, panVal;
@end

static DICCPickerPanel *gCCPanel = nil;

@implementation DICCPickerPanel

+ (void)showInWindow:(UIWindow *)win dark:(BOOL)dark
              paths:(NSArray<NSString *> *)paths cur:(NSString *)cur
           onChoose:(void (^)(NSString *))cb {
    [DICCPickerPanel hideAll];
    if (!win) return;
    CGRect bf = win.bounds;
    DICCPickerPanel *p = [[DICCPickerPanel alloc] initWithFrame:bf];
    p.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    p.paths = paths;
    p.curPath = cur;
    p.dark = dark;
    p.onChoose = cb;
    p.userInteractionEnabled = YES;

    /* 2.7.31: 恒深色磨砂质感 + 窗口收小(不再按浅/深分两种外观)
       2.7.34: 两列网格预览(跟设置页素材同款), 卡片加高 */
    CGFloat cw = MIN(bf.size.width - 64.0, 300.0);
    CGFloat ch = MIN(bf.size.height * 0.48, 400.0);
    CGFloat cxx = (bf.size.width - cw) / 2.0;
    CGFloat cyy = (bf.size.height - ch) / 2.0 - 30.0;

    /* 中央卡片: 深色磨砂 */
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(cxx, cyy, cw, ch)];
    UIVisualEffect *blur = nil;
    if (@available(iOS 13.0, *)) {
        blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    } else { blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]; }
    UIVisualEffectView *fx = [[UIVisualEffectView alloc] initWithFrame:CGRectMake(0, 0, cw, ch)];
    fx.effect = blur;
    fx.userInteractionEnabled = NO;   /* 纯背景, 不拦触摸 */
    [card addSubview:fx];
    card.backgroundColor = [[UIColor colorWithWhite:0.05 alpha:0.35] colorWithAlphaComponent:0.35];
    card.layer.cornerRadius = 20;
    card.layer.masksToBounds = YES;
    p.card = card;
    [p addSubview:card];

    /* 标题 */
    p.titleL = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, cw - 32, 20)];
    p.titleL.text = @"背景素材";
    p.titleL.font = [UIFont boldSystemFontOfSize:16];
    p.titleL.textColor = [UIColor whiteColor];
    p.titleL.textAlignment = NSTextAlignmentCenter;
    [card addSubview:p.titleL];

    /* 2.7.33: 模糊调节带 —— 在标题区左右滑动调"背景模糊"(左滑减, 右滑加)
       2.7.34: "N 个素材 · 上下滑动"那行副标题按用户要求删除 */
    p.blurL = [[UILabel alloc] initWithFrame:CGRectMake(16, 38, cw - 32, 14)];
    p.blurL.font = [UIFont systemFontOfSize:10];
    p.blurL.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    p.blurL.textAlignment = NSTextAlignmentCenter;
    p.blurL.text = [NSString stringWithFormat:@"◀ 左右滑动调模糊 · 当前 %d ▶", (int)wpBlur];
    [card addSubview:p.blurL];
    /* 手势接收区: 盖住标题+模糊带(56pt), 不影响下面网格 */
    UIView *hz = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cw, 56)];
    hz.backgroundColor = [UIColor clearColor];
    hz.userInteractionEnabled = YES;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:p action:@selector(onBlurPan:)];
    pan.maximumNumberOfTouches = 1;
    [hz addGestureRecognizer:pan];
    [card addSubview:hz];

    /* 素材网格: 两列, 跟设置页素材列表同款(大图+下方文件名) */
    CGFloat bh = 42;
    UICollectionViewFlowLayout *fl = [UICollectionViewFlowLayout new];
    CGFloat iw = (cw - 16 * 2 - 10) / 2.0;         /* 两列, 间距 10 */
    fl.itemSize = CGSizeMake(iw, iw * 0.72 + 22);
    fl.minimumInteritemSpacing = 10;
    fl.minimumLineSpacing = 10;
    fl.sectionInset = UIEdgeInsetsMake(0, 16, 8, 16);
    p.grid = [[UICollectionView alloc] initWithFrame:CGRectMake(0, 58, cw, ch - 58 - bh - 6)
                                collectionViewLayout:fl];
    p.grid.dataSource = p;
    p.grid.delegate = p;
    p.grid.backgroundColor = [UIColor clearColor];
    [p.grid registerClass:[DICCMatCell class] forCellWithReuseIdentifier:@"mat"];
    [card addSubview:p.grid];

    /* 底部按钮行: 关闭背景 / 取消 */
    p.btnRow = [[UIView alloc] initWithFrame:CGRectMake(0, ch - bh, cw, bh)];
    [card addSubview:p.btnRow];
    CGFloat bw = (cw - 24) / 2.0;
    NSArray *titles = @[@"关闭背景", @"取消"];
    for (int i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(8 + i * (bw + 8), 6, bw, bh - 12);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14];
        b.tintColor = (i == 0) ? [UIColor systemRedColor] : [UIColor whiteColor];
        b.tag = 100 + i;
        [b addTarget:p action:@selector(onBtn:) forControlEvents:UIControlEventTouchUpInside];
        [p.btnRow addSubview:b];
    }

    /* 点遮罩关闭 —— 2.7.31: 加 delegate, 命中点在卡片内**不识别** */
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:p
        action:@selector(dismissPanel)];
    tap.delegate = p;
    [p addGestureRecognizer:tap];

    [win addSubview:p];
    gCCPanel = p;

    /* 进场动画: 卡片从 0.92 缩放弹到 1 */
    card.transform = CGAffineTransformMakeScale(0.92, 0.92);
    p.alpha = 0;
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut
        animations:^{ p.alpha = 1; card.transform = CGAffineTransformIdentity; }
        completion:nil];
    DLog(@"[控制中心] 中央素材面板已弹出(素材数=%d 循环=%@)", (int)paths.count, wpLoopOn ? @"开" : @"关");
}

+ (void)hideAll {
    if (gCCPanel) { [gCCPanel dismissPanel]; }
}

/* 2.7.31: 手指点在卡片(含网格/按钮)上 → "点遮罩关闭"手势不识别 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    UIView *v = t.view;
    return !(v && self.card && [v isDescendantOfView:self.card]);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
  shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return NO; }

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.paths.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    DICCMatCell *c = [cv dequeueReusableCellWithReuseIdentifier:@"mat" forIndexPath:ip];
    if (ip.item < (NSInteger)self.paths.count) {
        NSString *p = self.paths[ip.item];
        BOOL sel = (self.curPath && [self.curPath isEqualToString:p]);
        c.lb.text = p.lastPathComponent;
        c.lb.textColor = sel ? [UIColor systemBlueColor] : [UIColor whiteColor];
        c.iv.layer.borderWidth = sel ? 2 : 0;
        c.iv.layer.borderColor = [UIColor systemBlueColor].CGColor;
        /* 缩略图: 异步出图, 贴上时校验还是同一个素材(防复用错位) */
        c.iv.image = nil;
        c.tag = ip.item;
        __weak DICCMatCell *wc = c;
        diCCThumbAsync(p, ^(UIImage *im) {
            if (!im || !wc) return;
            if (wc.tag != ip.item) return;
            wc.iv.image = im;
        });
    }
    return c;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    if (ip.item >= (NSInteger)self.paths.count) return;
    DLog(@"[控制中心] 面板选中第 %ld 项: %@", (long)ip.item, self.paths[ip.item].lastPathComponent);
    if (self.onChoose) self.onChoose(self.paths[ip.item]);
    [self dismissPanel];
}

/* 2.7.33: 标题区左右拖动调"背景模糊"
   拖动中只改内存值 + 透明度(轻量, 60fps 不卡); 松手才写偏好 + 强制重建重算马赛克。 */
- (void)onBlurPan:(UIPanGestureRecognizer *)g {
    if (!wpOn) return;
    if (g.state == UIGestureRecognizerStateBegan) { self.panBase = wpBlur; self.panVal = wpBlur; }
    CGPoint t = [g translationInView:self.card];
    NSInteger v = self.panBase + (NSInteger)lrint(t.x / 6.0);   /* 6pt = 1 档 */
    if (v < 0) v = 0; if (v > 100) v = 100;
    if (v == self.panVal && g.state == UIGestureRecognizerStateChanged) return;
    self.panVal = v;
    self.blurL.text = [NSString stringWithFormat:@"◀ 左右滑动调模糊 · 当前 %d ▶", (int)v];
    /* 2.7.35: 轻微震动反馈(每 2 档一下, 别震成机关枪) */
    if (v / 2 != self.panBase / 2) [self buzzLight];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        wpBlur = v;
        CFPreferencesSetAppValue((__bridge CFStringRef)@"wpBlur", (__bridge CFPropertyListRef)@(v),
                                 (__bridge CFStringRef)kDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.abgg332.driftisland/prefsChanged"), NULL, NULL, YES);
        DLog(@"[控制中心] 模糊调整(左右滑动) → %d", (int)v);
    }
    /* 2.7.35: 拖动过程中**完全不碰背景** —— 上一版拖动中一直在改 alpha / 重建播放器,
       所以看起来"背景缩小一下、闪一下"。现在只在松手后由通知统一处理一次。 */
}

- (void)buzzLight {
    @try {
        static UISelectionFeedbackGenerator *gen = nil;
        if (!gen) gen = [UISelectionFeedbackGenerator new];
        [gen prepare];
        [gen selectionChanged];
    } @catch (__unused NSException *e) {}
}

- (void)onBtn:(UIButton *)b {
    if (b.tag == 100) { if (self.onChoose) self.onChoose(nil); }   /* 关闭背景 */
    [self dismissPanel];
}

- (void)dismissPanel {
    if (!self.superview) { gCCPanel = nil; return; }
    __weak DICCPickerPanel *ws = self;
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseIn
        animations:^{ ws.alpha = 0; ws.card.transform = CGAffineTransformMakeScale(0.94, 0.94); }
        completion:^(BOOL f) { [ws removeFromSuperview]; if (gCCPanel == ws) gCCPanel = nil; }];
}
@end

@implementation DICCPressTarget

/* 2.7.30: 改成**不与任何系统手势同时识别**。
   上一版返回 YES, 意味着我们的长按和系统手势(电源键长按=关机、模块长按=自定义等)
   会**同时**触发 —— 用户报的"偶尔注销/进设置"就是这么叠出来的。
   返回 NO 之后: 我们的长按一旦真正开始, 系统手势就被取消; 反之滚动/点击时
   系统手势先识别成功, 我们的长按自然失败, 双方互不干扰。 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return NO;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (!wpOn || !ccLongPressOn) return NO;
    UIView *root = g.view;
    UIWindow *w = root.window;
    if (!w) return NO;
    UIView *hit = [w hitTest:[g locationInView:w] withEvent:nil];
    if (!hit) return NO;

    /* 2.7.29: 改成"黑名单"判定。上一版是白名单(只认 MTMaterialView / CCUIScrollView),
       可模块之间的空隙命中的往往是一个普通 UIView, 直接被判成"非空白" → 长按没反应。
       现在反过来: 沿命中视图往上走, 链上**出现任何可交互特征**才算"不是空白",
       其余一律放行。这样模块(含 Module/Slider/Button)照旧不受影响,
       而所有空隙、状态栏下方、滑块旁边的空地都能触发。 */
    int guard = 0;
    for (UIView *v = hit; v && guard++ < 25; v = v.superview) {
        NSString *cn = NSStringFromClass(v.class);
        if ([v isKindOfClass:UIControl.class]) { [self note:hit why:[cn stringByAppendingString:@"(UIControl)"] ok:NO]; return NO; }
        if ([cn containsString:@"Module"] || [cn containsString:@"Slider"] ||
            [cn containsString:@"Button"] || [cn containsString:@"Switch"] ||
            [cn containsString:@"Toggle"] || [cn containsString:@"Segmented"] ||
            [cn containsString:@"Stepper"] || [cn containsString:@"Record"]) {
            [self note:hit why:[cn stringByAppendingString:@"(可交互类)"] ok:NO]; return NO;
        }
        if (v.accessibilityTraits & UIAccessibilityTraitButton) { [self note:hit why:[cn stringByAppendingString:@"(a11y=按钮)"] ok:NO]; return NO; }
        if ([v isKindOfClass:[UIScrollView class]]) break;   /* 滚动容器本身 = 空白, 到此为止 */
    }
    [self note:hit why:NSStringFromClass(hit.class) ok:YES];
    return YES;
}

/* 诊断: 只在"岛/控制中心调试日志"打开时打, 默认静默, 免得刷屏 */
- (void)note:(UIView *)hit why:(NSString *)why ok:(BOOL)ok {
    (void)hit; (void)why; (void)ok;
}

- (void)onPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (!wpOn || !ccLongPressOn) return;
    @try {
        UIImpactFeedbackGenerator *fb = [UIImpactFeedbackGenerator new];
        [fb prepare];
        [fb impactOccurred];
        [self showPicker];
    } @catch (NSException *e) { DLog(@"[控制中心] 长按弹窗异常: %@", e.reason); }
}

/* 按当前控制中心外观选择对应素材，面板打开后固定本次写入的键。 */
- (void)showPicker {
    self.diPickerDark = diCCDarkAppearance();
    NSString *curPath = diWallpaperResolveAny(self.diPickerDark ? wpDarkAsset : wpLightAsset);
    NSArray<NSString *> *paths = diWallpaperPathsFor(self.diPickerDark);
    UIWindow *w = gCCSurface.window ?: self.owner.view.window;
    if (!w) return;
    __weak DICCPressTarget *ws = self;
    [DICCPickerPanel showInWindow:w dark:self.diPickerDark paths:paths cur:curPath
        onChoose:^(NSString *full) {
            DICCPressTarget *ss = ws;
            if (ss) [ss chooseFull:full];
        }];
}

- (void)chooseFull:(NSString *)full {
    NSString *rel = full ? diWallpaperRelAny(full) : @"__none__";
    NSString *key = self.diPickerDark ? @"wpDarkAsset" : @"wpLightAsset";
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)rel,
                             (__bridge CFStringRef)kDomain);
    if (self.diPickerDark) wpDarkAsset = rel; else wpLightAsset = rel;
    /* 选了固定素材(或点"关闭背景") → 自动关掉"循环播放",
       否则选了也马上被轮播顶掉 / 关了背景还继续轮播, 看着像没反应 */
    if (wpLoopOn) {
        wpLoopOn = NO;
        CFPreferencesSetAppValue((__bridge CFStringRef)@"wpLoopOn", (__bridge CFPropertyListRef)@NO,
                                 (__bridge CFStringRef)kDomain);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    if (!full) {
        /* 2.7.36: 点"关闭背景" = 直接关掉"启用背景"开关 ——
           只清素材不够(循环播放/偏好刷新还会把素材带回来), 从开关层面断掉 */
        CFPreferencesSetAppValue((__bridge CFStringRef)@"wpOn", (__bridge CFPropertyListRef)@NO,
                                 (__bridge CFStringRef)kDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        wpOn = NO;
        wpLoopOn = NO;
        diCCLoopInvalidate();
        diCCReleasePlayer();
        [gCCBlurFx removeFromSuperview];
        gCCBlurFx = nil;
        if (gCCSurface) gCCSurface.hidden = YES;
        gCCPath = nil;
    }
    diCCReloadSurface();
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.abgg332.driftisland/prefsChanged"), NULL, NULL, YES);
    DLog(@"[控制中心] 长按切换素材: %@", full ? full.lastPathComponent : @"关闭背景");
}
@end

/* 给控制中心装长按手势(只装一次)。挂"背景的父容器", 不新建覆盖层。 */
static void diCCInstallPressGesture(id vc, UIView *background) {
    if (!vc || !background) return;
    if (objc_getAssociatedObject(vc, &kCCPressViewKey)) return;
    UIView *host = background.superview;
    if (!host) return;

    UILongPressGestureRecognizer *lp = objc_getAssociatedObject(vc, &kCCPressKey);
    if (!lp) {
        DICCPressTarget *t = [DICCPressTarget new];
        t.owner = (UIViewController *)vc;
        lp = [[UILongPressGestureRecognizer alloc] initWithTarget:t action:@selector(onPress:)];
        lp.minimumPressDuration = 0.45;
        lp.numberOfTouchesRequired = 1;
        lp.delegate = t;
        lp.cancelsTouchesInView = YES;      /* 判定为空白后才取消, 不影响点击模块 */
        objc_setAssociatedObject(vc, &kCCPressKey, lp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(lp, &kCCPressKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC); /* 保住 delegate */
    }
    if (![host.gestureRecognizers containsObject:lp]) [host addGestureRecognizer:lp];
    objc_setAssociatedObject(vc, &kCCPressViewKey, host, OBJC_ASSOCIATION_ASSIGN);
    DLog(@"[控制中心] 长按换素材手势已装在 %@ 上", NSStringFromClass(host.class));
}

/* 挂到背景视图的兄弟层(之上)。对应 ccvideobg 的 rascal_ccvideobg_attachTo: */
static void diCCAttachTo(id vc, UIView *background) {
    if (!background || !wpOn) return;
    if (!gCCSurface) {
        gCCSurface = [UIView new];
        gCCSurface.userInteractionEnabled = NO;   /* 不拦模块触摸 */
        gCCSurface.clipsToBounds = YES;
    }
    UIView *parent = background.superview;
    if (!parent) { DLog(@"[控制中心] 背景视图没有父级, 无法挂载"); return; }
    /* 3.0.22(iOS17 卡死): 这个函数是从布局钩子里调的, 而 removeFromSuperview +
       insertSubview 本身就会**再触发一次布局** —— 系统如果每次布局都把背景视图
       重建/换父级, 这里就成了"插入→布局→再插入"的死循环。435 日志里出现过
       "上一秒省略 30213 行重复日志", 就是它: 一秒三万次, 主线程被自己的日志和
       插视图占满, watchdog 直接注销。现在同一父级只挂一次, 0.5 秒内最多重挂一次。 */
    static CFAbsoluteTime lastAttach = 0;
    static __weak UIView *lastParent;
    if (gCCSurface.superview != parent) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (lastParent == parent && now - lastAttach < 0.5) {
            /* 刚挂过又不在树上了 = 系统正在重建, 这一轮不跟它抢 */
        } else {
            lastParent = parent;
            lastAttach = now;
            [gCCSurface removeFromSuperview];
            [parent insertSubview:gCCSurface aboveSubview:background];
            if (now - lastAttach > 0) {
                static CFAbsoluteTime lastLog = 0;
                if (now - lastLog > 5.0) {
                    lastLog = now;
                    DLog(@"[控制中心] 壁纸层已挂到 %@ 之上(兄弟层, 系统清理不到)", NSStringFromClass(background.class));
                }
            }
        }
    }
    if (!CGRectEqualToRect(gCCSurface.frame, background.frame)) gCCSurface.frame = background.frame;
    diCCReloadSurface();
    if (ccLongPressOn) diCCInstallPressGesture(vc, background);
}

static void diCCLayoutSurface(id vc) {
    UIView *bg = diCCBackgroundOf(vc);
    if (!bg || !gCCSurface) return;
    /* 与 ccvideobg 一致：只更新自己的 surface，不透明化/修改系统视图。 */
    gCCSurface.frame = bg.frame;
    if (gCCVisible && !wpLoopOn) diCCReloadSurface(); /* 外观切换时比较素材路径 */
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in gCCSurface.layer.sublayers) {
        l.frame = gCCSurface.bounds;
    }
    [CATransaction commit];
}

static int sCCDeepDumpN = 0;   /* 2.8.47: 每次展开前 2 次滚动打深 dump, 防爆日志 */
static void diCCSetVisible(BOOL visible) {
    gCCVisible = visible;
    if (visible) sCCDeepDumpN = 0;   /* 2.8.47: 每次展开重新计数, 深 dump 打前 2 次滚动 */
    else diCCRestoreBackdropMaterial();   /* 2.8.48: 收起时还原系统磨砂层 */
    if (!visible) { diCCRestoreAffordanceLayers(); }
    diCCReloadSurface();
    /* 收起时把中央素材面板一并撤掉(纯 removeFromSuperview, 不碰响应链) */
    if (!visible) [DICCPickerPanel hideAll];
    /* 2.7.29 性能: 收起只**暂停**, 不再销毁播放器。
       257 号日志里 01:31:13/15/23/29/31/32 反复出现"壁纸就绪(视频)" —— 说明每次
       展开都在重建 AVQueuePlayer + AVPlayerLooper + 重新解码, 这就是用户说的掉帧。
       现在改成: 收起 pause, 展开直接 play(零重建); 60 秒没再展开才真正释放。 */
    if (!visible) {
        [gCCPlayer pause];
        diCCAudioSession(NO);
        static BOOL scheduled = NO;
        if (!scheduled) {
            scheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)60.0 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                scheduled = NO;
                if (!gCCVisible) diCCReleasePlayer();
            });
        }
    }
}

static void diCCHookedCCViewDidLoad(id self, SEL _cmd) {
    if (diOrigCCViewDidLoad) ((void (*)(id, SEL))diOrigCCViewDidLoad)(self, _cmd);
    @try { diCCAttachTo(self, diCCBackgroundOf(self)); }
    @catch (__unused NSException *e) {}
}

static void diCCHookedCCWillLayout(id self, SEL _cmd) {
    if (diOrigCCWillLayout) ((void (*)(id, SEL))diOrigCCWillLayout)(self, _cmd);
    @try { diCCLayoutSurface(self); }
    @catch (__unused NSException *e) {}
}

/* 展开: 先让系统把视图准备好(%orig), 再挂上并立刻显示 —— 这就是"零延迟" */
static id diCCHookedCCBeginPres(id self, SEL _cmd, BOOL animated, BOOL interactive) {
    id r = nil;
    if (diOrigCCBeginPres) r = ((id (*)(id, SEL, BOOL, BOOL))diOrigCCBeginPres)(self, _cmd, animated, interactive);
    @try {
        diCCAttachTo(self, diCCBackgroundOf(self));
        diCCSetVisible(YES);
    } @catch (__unused NSException *e) {}
    return r;
}

/* 参考插件真正使用的展示/收起通知；签名均为 void、无额外参数。 */
static void diCCHookedCCWillPresent(id self, SEL _cmd) {
    if (diOrigCCWillPresent) ((void (*)(id, SEL))diOrigCCWillPresent)(self, _cmd);
    @try { diCCAttachTo(self, diCCBackgroundOf(self)); diCCSetVisible(YES); }
    @catch (__unused NSException *e) {}
}
static void diCCHookedCCWillDismiss(id self, SEL _cmd) {
    @try { diCCSetVisible(NO); } @catch (__unused NSException *e) {}
    if (diOrigCCWillDismiss) ((void (*)(id, SEL))diOrigCCWillDismiss)(self, _cmd);
}

/* 2.8.59: 仅交互式 beginDismissal 不预先藏背景；交互可能取消。
   非交互保留原行为。viewDidDisappear 作为真正离场时的清理入口。 */
static id diCCHookedCCBeginDis(id self, SEL _cmd, BOOL animated, BOOL interactive) {
    if (!interactive) { @try { diCCSetVisible(NO); } @catch (__unused NSException *e) {} }
    if (diOrigCCBeginDis) return ((id (*)(id, SEL, BOOL, BOOL))diOrigCCBeginDis)(self, _cmd, animated, interactive);
    return nil;
}

static void diCCHookedCCDidDisappear(id self, SEL _cmd, BOOL animated) {
    if (diOrigCCDidDisappear) ((void (*)(id, SEL, BOOL))diOrigCCDidDisappear)(self, _cmd, animated);
    @try {
        UIViewController *vc = (UIViewController *)self;
        if (!vc.view.window) diCCSetVisible(NO);
    } @catch (__unused NSException *e) {}
}

__attribute__((unused)) /* 2.8.5: 控制中心已下架, 不再调用, 留档 */
static void diCCInstallOverlayHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        /* ControlCenterUI 可能比 tweak 构造晚加载, 与 ccvideobg 一样先 dlopen */
        dlopen("/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI", RTLD_LAZY);
        Class c = NSClassFromString(@"CCUIModularControlCenterOverlayViewController");
        if (!c) { RLog(@"[控制中心] 找不到 overlay 控制器；保持系统原样"); return; }
        Method mWillPres = class_getInstanceMethod(c, NSSelectorFromString(@"_willPresentView"));
        Method mWillDis = class_getInstanceMethod(c, NSSelectorFromString(@"_willDismissView"));
        BOOL refLifecycle = (mWillPres && mWillDis);
        Method mPres = class_getInstanceMethod(c, NSSelectorFromString(@"_beginPresentationAnimated:interactive:"));
        Method mDis = class_getInstanceMethod(c, NSSelectorFromString(@"_beginDismissalAnimated:interactive:"));
        if (!refLifecycle && (!mPres || !mDis)) {
            RLog(@"[控制中心] 无可用展开/收起时机；不接管系统图层"); return;
        }

        SEL sVDL  = NSSelectorFromString(@"viewDidLoad");
        SEL sWill = NSSelectorFromString(@"viewWillLayoutSubviews");
        SEL sPres = NSSelectorFromString(@"_beginPresentationAnimated:interactive:");
        SEL sDis  = NSSelectorFromString(@"_beginDismissalAnimated:interactive:");
        SEL sDid  = NSSelectorFromString(@"viewDidDisappear:");

        if ([c instancesRespondToSelector:sVDL]) {
            diOrigCCViewDidLoad = di_MethodImp(c, sVDL);
            MSHookMessageEx(c, sVDL, (IMP)diCCHookedCCViewDidLoad, &diOrigCCViewDidLoad);
        }
        if ([c instancesRespondToSelector:sWill]) {
            diOrigCCWillLayout = di_MethodImp(c, sWill);
            MSHookMessageEx(c, sWill, (IMP)diCCHookedCCWillLayout, &diOrigCCWillLayout);
        }
        if (refLifecycle) {
            SEL pres = NSSelectorFromString(@"_willPresentView");
            SEL dis = NSSelectorFromString(@"_willDismissView");
            diOrigCCWillPresent = di_MethodImp(c, pres);
            MSHookMessageEx(c, pres, (IMP)diCCHookedCCWillPresent, &diOrigCCWillPresent);
            diOrigCCWillDismiss = di_MethodImp(c, dis);
            MSHookMessageEx(c, dis, (IMP)diCCHookedCCWillDismiss, &diOrigCCWillDismiss);
            RLog(@"[控制中心] 按参考插件装载 _willPresentView/_willDismissView");
        } else {
            diOrigCCBeginPres = di_MethodImp(c, sPres);
            MSHookMessageEx(c, sPres, (IMP)diCCHookedCCBeginPres, &diOrigCCBeginPres);
            diOrigCCBeginDis = di_MethodImp(c, sDis);
            MSHookMessageEx(c, sDis, (IMP)diCCHookedCCBeginDis, &diOrigCCBeginDis);
            RLog(@"[控制中心] 参考时机不存在，沿用 begin 生命周期");
        }
        if ([c instancesRespondToSelector:sDid]) {
            diOrigCCDidDisappear = di_MethodImp(c, sDid);
            MSHookMessageEx(c, sDid, (IMP)diCCHookedCCDidDisappear, &diOrigCCDidDisappear);
        }
        gCCOverlayHooked = YES;
        RLog(@"[控制中心] overlay hook 已就位(移植 ccvideobg: 兄弟层 + 展开/收起精确时机)");
        RLog(@"[控制中心] 2.8.55 使用参考插件纯兄弟层，未安装滚动区改层 hook");
    });
}

/* ===== 2.8.43: 压制 CCUIScrollView 内部的全屏磨砂底 =====
   311 视频实锤: 静态时壁纸整屏可见, 一交互(滚动/刷新), 上半部分(网络组+音乐大卡,
   即 CCUIScrollView 区域)被系统置成灰白, 盖住壁纸。scrollview 内部有一张全屏
   MTMaterialView 当滚动区背景, 交互时系统重设它(alpha/底色) → 白底。
   对策: hook CCUIScrollView 的 layoutSubviews, 每次布局都把内部全屏磨砂层
   alpha 清 0、底色清空, 让壁纸透出来。模块按钮自己的小磨砂卡不受影响
   (它们不是全屏, 且保持半透明反而更贴合系统观感)。 */
static void (*diOrigScrollLayout)(id, SEL);
static void (*diOrigScrollOffset)(id, SEL, CGPoint);   /* 2.8.45: setContentOffset: 原实现 */

/* 2.8.44: 312 日志证明白底不是 scrollview 的直接子层(压制日志 0 条, 白底依旧)。
   扩大范围: ① scrollview 自身 backgroundColor 也可能被系统设白;
   ② 递归两层, 对**任意**大面积(≥0.9 宽 × ≥0.5 高)层:
      MTMaterialView 类 → alpha 清 0(磨砂层, 只透明化不破坏);
      其余 UIView → backgroundColor 非 clear 就清空(纯色底才这么处理,
      带 _UIBackdropEffectView 的复合层不碰, 只打日志留证)。
   每个处理动作都打日志, 下一轮日志直接能看出白底真身是什么类。 */
static BOOL diCCTameOne(UIView *v, CGSize ws, int depth) {
    if (!v || depth > 2) return NO;
    BOOL found = NO;
    CGSize bs = v.bounds.size;
    BOOL big = (bs.width >= ws.width * 0.9 && bs.height >= ws.height * 0.5);
    if (big) {
        NSString *cn = NSStringFromClass(v.class);
        if ([v isKindOfClass:NSClassFromString(@"MTMaterialView")]) {
            found = YES;
            if (v.alpha != 0.0) {
                v.alpha = 0.0;
                DLog(@"[控制中心] 压制磨砂底 %@ (%.0fx%.0f) depth=%d", cn, bs.width, bs.height, depth);
            }
        } else if (![cn containsString:@"BackdropEffect"]) {
            /* 2.8.46: 314 日志实锤 —— 白底真身是 CCUIScrollView 里那个 430x974 opaque=1
               的模块内容容器 UIView: bg=null 逃过底色清理, 但 opaque=1, 交互时画白底。
               对策: 非 clear 底色清空 + opaque 清 NO(大面积层才动, 模块小卡不碰)。 */
            BOOL changed = NO;
            UIColor *bg = v.backgroundColor;
            if (bg && ![bg isEqual:UIColor.clearColor]) {
                v.backgroundColor = nil;
                changed = YES;
                DLog(@"[控制中心] 清除色底 %@ (%.0fx%.0f) bg=%@ depth=%d", cn, bs.width, bs.height, bg, depth);
            }
            if (v.isOpaque) {
                v.opaque = NO;
                changed = YES;
                DLog(@"[控制中心] 清除不透明标记 %@ (%.0fx%.0f) depth=%d", cn, bs.width, bs.height, depth);
            }
            if (changed) found = YES;
        } else {
            found = YES;
            DLog(@"[控制中心][诊断] 大面积复合底 %@ (%.0fx%.0f) alpha=%.2f bg=%@ depth=%d 未处理",
                 cn, bs.width, bs.height, v.alpha, v.backgroundColor, depth);
        }
    }
    for (UIView *c in v.subviews) found |= diCCTameOne(c, ws, depth + 1);
    return found;
}

/* 2.8.47: 深 dump —— 白底真身前四版都没猜中(2.8.46 清了 opaque 仍白), 不再猜了。
   滚动时把「壁纸层的父层完整层序 + 每层属性 + 纯 CALayer + backgroundView」
   全打出来, 白底是谁直接现形。每次展开只打 2 次, 防爆日志。 */
static void diCCDeepDump(UIView *sv) {
    @try {
        UIView *parent = sv.superview;
        RLog(@"[控制中心][深dump] scrollview=%@ %@ 父类=%@ 父节点=%lu",
             NSStringFromClass(sv.class), NSStringFromCGRect(sv.bounds),
             NSStringFromClass(parent.class), (unsigned long)parent.subviews.count);
        /* 1) 父层完整层序: 白底若在壁纸之上, 这里能看到它是哪一层 */
        if (parent) {
            for (NSUInteger i = 0; i < parent.subviews.count; i++) {
                UIView *v = parent.subviews[i];
                RLog(@"[深dump] 父层[%lu] %@%@ %@ a%.2f op=%d bg=%@%@",
                     (unsigned long)i, NSStringFromClass(v.class), v.isHidden ? @"[H]" : @"",
                     NSStringFromCGRect(v.bounds), v.alpha, (int)v.isOpaque,
                     v.backgroundColor, v == gCCSurface ? @" ←壁纸层" : @"");
            }
            /* 2) 父层 layer 上的纯 CALayer(不对应 UIView, 子视图遍历看不到) */
            for (NSUInteger i = 0; i < parent.layer.sublayers.count; i++) {
                CALayer *l = parent.layer.sublayers[i];
                BOOL pure = (l.delegate == nil);
                RLog(@"[深dump] 父层Layer[%lu] %@ %@ op=%.2f o=%d bg=%@%@",
                     (unsigned long)i, NSStringFromClass(l.class), NSStringFromCGRect(l.frame),
                     l.opacity, (int)l.opaque, l.backgroundColor, pure ? @" [纯层]" : @"");
            }
        }
        /* 3) scrollview 自身 layer 子层 */
        for (NSUInteger i = 0; i < sv.layer.sublayers.count; i++) {
            CALayer *l = sv.layer.sublayers[i];
            RLog(@"[深dump] 滚动Layer[%lu] %@ %@ op=%.2f o=%d bg=%@",
                 (unsigned long)i, NSStringFromClass(l.class), NSStringFromCGRect(l.frame),
                 l.opacity, (int)l.opaque, l.backgroundColor);
        }
        /* 3.5) 2.8.48: 壁纸层自己的内容子层(白底若是因为素材层丢了, 这里能看出) */
        RLog(@"[深dump] 壁纸层 hidden=%d alpha=%.2f z=%.1f 子层数=%lu",
             (int)gCCSurface.isHidden, gCCSurface.alpha, gCCSurface.layer.zPosition,
             (unsigned long)gCCSurface.layer.sublayers.count);
        for (NSUInteger i = 0; i < gCCSurface.layer.sublayers.count; i++) {
            CALayer *l = gCCSurface.layer.sublayers[i];
            RLog(@"[深dump] 壁纸子层[%lu] %@ %@ op=%.2f hidden=%d contents=%@",
                 (unsigned long)i, NSStringFromClass(l.class), NSStringFromCGRect(l.frame),
                 l.opacity, (int)l.isHidden, l.contents ? @"有" : @"无");
        }
        /* 3.6) 2.8.48: 壁纸父层之上(手势层/窗口)有没有盖住整屏的层 */
        for (UIView *p = parent.superview; p && ![p isKindOfClass:[UIWindow class]]; p = p.superview) {
            RLog(@"[深dump] 上层%@ %@ a%.2f hidden=%d", NSStringFromClass(p.class),
                 NSStringFromCGRect(p.bounds), p.alpha, (int)p.isHidden);
            for (NSUInteger i = 0; i < p.layer.sublayers.count; i++) {
                CALayer *l = p.layer.sublayers[i];
                if (l.isHidden || l.opacity < 0.05) continue;
                if (l.frame.size.width >= p.bounds.size.width * 0.9 && l.frame.size.height >= p.bounds.size.height * 0.4)
                    RLog(@"[深dump] 上层Layer[%lu] %@ %@ op=%.2f o=%d z=%.1f bg=%@",
                         (unsigned long)i, NSStringFromClass(l.class), NSStringFromCGRect(l.frame),
                         l.opacity, (int)l.opaque, l.zPosition, l.backgroundColor);
            }
        }
        /* 4) collectionView 的 backgroundView(不在 subviews 里, 专查) */
        if ([sv isKindOfClass:[UICollectionView class]]) {
            UIView *bv = ((UICollectionView *)sv).backgroundView;
            if (bv) RLog(@"[深dump] collectionView backgroundView=%@ %@ a%.2f op=%d bg=%@",
                         NSStringFromClass(bv.class), NSStringFromCGRect(bv.bounds), bv.alpha,
                         (int)bv.isOpaque, bv.backgroundColor);
        }
        /* 5) 滚动区子树递归(深度≤5, ≤60 个), 大面积层全标出 */
        NSMutableArray<NSArray *> *stk = [NSMutableArray array];
        [stk addObject:@[sv, @0]];
        NSUInteger n = 0;
        while (stk.count && n < 60) {
            NSArray *top = stk.firstObject; [stk removeObjectAtIndex:0];
            UIView *v = top[0]; int dep = [top[1] intValue];
            if (dep > 0) {
                n++;
                BOOL big = (v.bounds.size.width >= sv.bounds.size.width * 0.85);
                if (big || dep <= 2) {
                    RLog(@"[深dump] 树[%lu] %@%@%@ %@ %@ a%.2f op=%d bg=%@",
                         (unsigned long)n, dep <= 1 ? @"" : [@"  " stringByPaddingToLength:dep * 2 withString:@" " startingAtIndex:0],
                         NSStringFromClass(v.class), v.isHidden ? @"[H]" : @"",
                         big ? @"[大]" : @"", NSStringFromCGRect(v.bounds), v.alpha,
                         (int)v.isOpaque, v.backgroundColor);
                }
            }
            if (dep >= 5) continue;
            for (UIView *c in v.subviews) [stk addObject:@[c, @(dep + 1)]];
        }
    } @catch (__unused NSException *e) {}
}

/* 2.8.47: 全面压制 —— 除了 scrollview 子树, 再管三处:
   ① collectionView 的 backgroundView(不在 subviews, 前几版全漏)
   ② 壁纸层父层里的纯 CALayer(系统直接挂 layer, 不对应 UIView)
   ③ 层序: 壁纸层必须在所有兄弟 MTMaterialView 之上(系统滚动时会把磨砂层提到前面) */
__attribute__((unused)) static void diCCTameScrollBackdrop(UIView *sv) {
    if (!wpOn || !gCCSurface || !sv) return;
    CGSize ws = sv.bounds.size;
    if (ws.width < 10) return;
    @try {
        /* 先确认壁纸层还在容器里(滚动/布局若把它挤走, 露出的就是容器白底) */
        if (gCCSurface.superview != sv.superview) {
            RLog(@"[控制中心] 壁纸层被挤走, 重挂(原父=%@)", gCCSurface.superview ? NSStringFromClass(gCCSurface.superview.class) : @"nil");
            [gCCSurface removeFromSuperview];
            NSInteger idx = [sv.superview.subviews indexOfObject:sv];
            if (idx == NSNotFound) idx = 0;
            [sv.superview insertSubview:gCCSurface atIndex:idx];
        }
        /* 2.8.47③: 层序纠偏 —— 任何兄弟磨砂层排在壁纸前面, 立刻把壁纸提到它上面
           (2.8.48: 磨砂层已直接透明化, 这里兜底; 遍历用 copy 防枚举中 mutation) */
        UIView *parent = gCCSurface.superview;
        if (parent) {
            Class mt = NSClassFromString(@"MTMaterialView");
            for (UIView *v in [parent.subviews copy]) {
                if (v == gCCSurface) continue;
                if (![v isKindOfClass:mt]) continue;
                if ([parent.subviews indexOfObject:v] > [parent.subviews indexOfObject:gCCSurface]) {
                    RLog(@"[控制中心] 层序纠偏: %@ 盖住壁纸层, 重新置顶", NSStringFromClass(v.class));
                    [parent insertSubview:gCCSurface aboveSubview:v];
                }
            }
            /* 2.8.47②: 父层上的纯 CALayer(系统直接挂, 大面积且不透明 → 透明化) */
            for (CALayer *l in [parent.layer.sublayers copy]) {
                if (l == gCCSurface.layer) continue;
                if (l.delegate != nil) continue;               /* 有主的层归视图逻辑管 */
                if (l.isHidden || l.opacity < 0.05) continue;
                BOOL big = (l.frame.size.width >= parent.bounds.size.width * 0.85 &&
                            l.frame.size.height >= parent.bounds.size.height * 0.4);
                if (big) {
                    l.opacity = 0.0;
                    RLog(@"[控制中心] 压制父层纯层 %@ %@", NSStringFromClass(l.class), NSStringFromCGRect(l.frame));
                }
            }
        }
        /* 2.8.48: 滚动时重申透明化(系统重建磨砂层/改配方都在这拍压住) */
        diCCHideBackdropMaterial();
        diCCTameAffordanceLayers();
        /* scrollview 自身 */
        UIColor *sb = sv.backgroundColor;
        if (sb && ![sb isEqual:UIColor.clearColor]) {
            sv.backgroundColor = nil;
            DLog(@"[控制中心] 清除滚动区自身色底 %@ bg=%@", NSStringFromClass(sv.class), sb);
        }
        /* 2.8.47①: collectionView backgroundView(白底经典藏身处) */
        if ([sv isKindOfClass:[UICollectionView class]]) {
            UIView *bv = ((UICollectionView *)sv).backgroundView;
            if (bv) {
                BOOL big = (bv.bounds.size.width >= ws.width * 0.85);
                BOOL changed = NO;
                if (big && [bv isKindOfClass:NSClassFromString(@"MTMaterialView")] && bv.alpha != 0.0) {
                    bv.alpha = 0.0; changed = YES;
                }
                UIColor *bbg = bv.backgroundColor;
                if (big && bbg && ![bbg isEqual:UIColor.clearColor]) { bv.backgroundColor = nil; changed = YES; }
                if (big && bv.isOpaque) { bv.opaque = NO; changed = YES; }
                if (changed) RLog(@"[控制中心] 压制 backgroundView %@ (%.0fx%.0f)", NSStringFromClass(bv.class), bv.bounds.size.width, bv.bounds.size.height);
            }
        }
        BOOL found = NO;
        for (UIView *c in sv.subviews) found |= diCCTameOne(c, ws, 0);
        /* 2.8.47: 深 dump(每次展开前 2 次滚动), 白底真身直接现形 */
        if (sCCDeepDumpN < 2) { sCCDeepDumpN++; diCCDeepDump(sv); }
        /* 诊断: 没发现任何大面积层时, dump 前 6 个子视图找真身 */
        if (!found) {
            static CFAbsoluteTime tDiag;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - tDiag > 2.0) {
                tDiag = now;
                NSMutableString *d = [NSMutableString string];
                NSUInteger n = 0;
                for (UIView *c in sv.subviews) {
                    if (n++ >= 6) break;
                    [d appendFormat:@"\n    %@ %.0fx%.0f a%.2f opaque=%d bg=%@", NSStringFromClass(c.class),
                         c.bounds.size.width, c.bounds.size.height, c.alpha, c.isOpaque, c.backgroundColor];
                }
                RLog(@"[控制中心][诊断] 滚动区无大面积层(共%lu 子视图):%@", (unsigned long)sv.subviews.count, d);
            }
        }
    } @catch (__unused NSException *e) {}
}

static void diCCHookedCCScrollLayout(id self, SEL _cmd) {
    if (diOrigScrollLayout) diOrigScrollLayout(self, _cmd);
    @try { diCCTameScrollBackdrop((UIView *)self); }
    @catch (__unused NSException *e) {}
}

/* 2.8.45: 滚动时 layoutSubviews 不触发, 补 setContentOffset: 入口 */
static void diCCHookedCCScrollOffset(id self, SEL _cmd, CGPoint off) {
    if (diOrigScrollOffset) ((void (*)(id, SEL, CGPoint))diOrigScrollOffset)(self, _cmd, off);
    @try { diCCTameScrollBackdrop((UIView *)self); }
    @catch (__unused NSException *e) {}
}

__attribute__((unused)) static void diCCInstallScrollHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class c = NSClassFromString(@"CCUIScrollView");
        if (!c) { RLog(@"[控制中心] 找不到 CCUIScrollView, 滚动区白底压制跳过"); return; }
        SEL lay = NSSelectorFromString(@"layoutSubviews");
        if (![c instancesRespondToSelector:lay]) { RLog(@"[控制中心] CCUIScrollView 无 layoutSubviews, 白底压制跳过"); return; }
        diOrigScrollLayout = (void (*)(id, SEL))di_MethodImp(c, lay);
        MSHookMessageEx(c, lay, (IMP)diCCHookedCCScrollLayout, (IMP *)&diOrigScrollLayout);
        /* 2.8.45: setContentOffset: 入口(滚动时真正会走的路) */
        SEL off = NSSelectorFromString(@"setContentOffset:");
        if ([c instancesRespondToSelector:off]) {
            diOrigScrollOffset = (void (*)(id, SEL, CGPoint))di_MethodImp(c, off);
            MSHookMessageEx(c, off, (IMP)diCCHookedCCScrollOffset, (IMP *)&diOrigScrollOffset);
            RLog(@"[控制中心] CCUIScrollView hook 已就位(layoutSubviews + setContentOffset:, 修交互白底)");
        } else {
            RLog(@"[控制中心] CCUIScrollView hook 已就位(仅 layoutSubviews, 无 setContentOffset:)");
        }
    });
}

__attribute__((unused)) /* 2.8.5: 控制中心已下架, 不再调用, 留档 */
static void diCCInstallLayoutHook(void) {
    gDiLaunchTime = CFAbsoluteTimeGetCurrent();
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class c = NSClassFromString(@"MTMaterialView");
        if (!c) { RLog(@"[壁纸图层] CALayer 挂载: 找不到 MTMaterialView"); return; }
        SEL lay = NSSelectorFromString(@"layoutSubviews");
        SEL dmw = NSSelectorFromString(@"didMoveToWindow");

        if ([c instancesRespondToSelector:lay]) {
            diOrigMTLayout = di_MethodImp(c, lay);
            MSHookMessageEx(c, lay, (IMP)diCCHookedMTLayoutSubviews, &diOrigMTLayout);
        }

        /* didMoveToWindow 必须确认是本类实现, 否则会 hook 到 UIView 的全局实现 */
        BOOL ownDMW = NO;
        unsigned int cnt = 0;
        Method *list = class_copyMethodList(c, &cnt);
        if (list) {
            for (unsigned int i = 0; i < cnt; i++) {
                if (method_getName(list[i]) == dmw) { ownDMW = YES; break; }
            }
            free(list);
        }
        if (ownDMW) {
            diOrigMTDidMoveToWindow = di_MethodImp(c, dmw);
            MSHookMessageEx(c, dmw, (IMP)diCCHookedMTDidMoveToWindow, &diOrigMTDidMoveToWindow);
        }

        RLog(@"[壁纸图层] CALayer 挂载已就位 layoutSubviews=%@ didMoveToWindow=%@%@ (照搬 CCBackgroundMod: addSublayer 而非 addSubview)",
             diOrigMTLayout ? @"是" : @"否",
             diOrigMTDidMoveToWindow ? @"是" : @"否",
             ownDMW ? @"" : @"(本类未覆写, 已跳过)");
    });
}


static void visibilityTick(void) {
    refreshPrefs();
    static CFAbsoluteTime tMR; // CPU 优化: MediaRemote 查询 1秒一次(检测音乐停止够快)
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    /* 2.8.85: 残留遮罩清扫 —— 关着时全摘(2s), 开着时只摘大层(5s)
       2.8.86: 展开期间 0.5s 一次、不限大小地扫 —— 展开态任何一个
       SpringBoard 侧的形状层都会变成"多出来的心形", 一律不许留。 */
    {
        static CFAbsoluteTime tSweep;
        /* 2.9.61: 17 不再读 MRU 展开标志(可能与实际状态脱节) —— 17 展开期
           SB 侧玻璃已由本地闸门(≥180x46 等)收干净, 没有需要高频扫的残留。 */
        BOOL exp = diIsIOS17Up() ? NO : diMruSaysExpanded();
        CFAbsoluteTime gap = exp ? 0.25 : ((enabled && maskOn) ? 5.0 : 2.0);
        if (now - tSweep > gap) {
            tSweep = now;
            @try { diSweepMasks(exp ? NO : (enabled && maskOn)); } @catch (__unused NSException *e) {}
        }
    }
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
                gVolumeUntil = now + 4.0;
                DLog(@"音量变化轮询捕获: %.2f→%.2f → 4秒内我们让位, 让系统自己收音量条", lastVol, v);
                diDumpWindowsForVolume();
            }
            lastVol = v;
        }
    }
    /* 2.9.12: 音量 HUD 只"看"不"动"。
       2.9.11 在音量停止变化 1.5 秒后把 HUD 窗口 alpha 直接归零, 结果是:
         · HUD 窗口是复用的, 归零后系统下次要显示时窗口仍是 0 → "有时候显示不了了";
         · 归零是瞬间的(没有系统那 0.3 秒淡出) → "有时候一下就没了";
       系统本来就管得住自己的 HUD。我们唯一要做的是别占着岛的 portal ——
       也就是 syncFrameToHost 里的"让位", 让它恢复成纯系统内容即可。
       这里只记一个"HUD 在屏"的布尔量用于日志, 一个 alpha 都不写。 */
    {
        static CFAbsoluteTime tHUD;
        if (now - tHUD > 0.25) {
            tHUD = now;
            BOOL on = (diHUDWindows().count > 0);
            if (on != gVolHUDActive) {
                gVolHUDActive = on;
                RLog(@"[音量条] HUD 窗口%@", on ? @"在屏(只观察, 不动它)" : @"已离开");
            }
        }
    }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]])
            for (UIWindow *w in ((UIWindowScene *)s).windows) updateSingleVideo(w);
    /* 2.7.1: 控制中心壁纸保活。
       控制中心是"展开才有、收起就消失"的 —— 所以每 0.5s 探测一次:
         · 开着且控制中心在 → attachIfNeeded 保证挂在正确层级、素材正确
         · 收起 → attachIfNeeded 内部会把自己撤下并停播, 不空转 */
    {
        static CFAbsoluteTime tWp;
        /* 2.7.9: 撤下时机已交给 KVO(见 diWatchSuperviewOf:), 这里只做"保活"兜底,
           不必再 0.1s 空转 —— 放宽回 0.3s, 既省电又不会漏掉事件。
           2.7.22: 控制中心壁纸的主路径已经换成 CALayer 挂载(MTMaterialView 的
           layoutSubviews hook), 这个 tick 只做两件事:
             · 素材/开关变化时让 DIWallpaperView 重新解析并同步到我们的 CALayer;
             · hook 万一没装上时的兜底(走老的 UIView 挂载)。
           注意: 绝不能让这个 tick 去抢 CALayer 的挂/撤 —— 那样又会回到抖动。 */
        if (now - tWp > 1.5) {
            tWp = now;
            DIWallpaperView *wv = [DIWallpaperView shared];
            if (wpOn) [wv attachIfNeeded];
            else if (wv.superview) [wv reload];
            /* 2.7.13: 组名路线 —— 素材变了重建采样源, 开关关了还原系统组名 */
            diCCRefreshFromTick();
            /* 2.7.22: 素材变了就把内容重新灌进 CALayer */
            diCCSyncBackdropContent();
        }
        /* 2.7.23: 壁纸 CALayer 的自愈, 与上面 1.5s 那档解耦 —— 必须每帧跑。
           只做"层还在不在 / 尺寸对不对", 纯算术; 被系统清掉就在 16ms 内重挂。
           这是"后"延迟的根治手段: 以前要等 layoutSubviews 或 1.5s tick 才发现,
           那段时间就是用户看到的空档。 */
        diCCTickBackdrop();
    }
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
            if (lkBdOn || lkShOn || lkGlowOn) diForEachWindow(^(UIWindow *w){ diRestyleWalk(w); });
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
    /* 2.8.48: 解锁即预载两层素材(不需要放歌触发), 锁屏仍全停 */
    if (!locked) diPreloadIslandVideos();
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

static BOOL gDIPrefsRefreshPending;

/* ===== 3.0.20: 设置改动后的刷新改成"分步 + 计时" =====
   429/432 的现场是: iOS17 上随便拨哪个开关都卡死几十秒然后注销, iOS16 没事。
   整段刷新以前是一个大 @try 块一把梭 —— 哪一步慢/死循环都看不出来, 而且主线程被
   独占。现在拆成 6 步, 各自占一个 runloop 回合, 每步超过 120ms 就在日志里点名
   (日志是同步落盘的, 卡在哪一步最后一行的 [偏好] 就是答案)。 */
static const char *diPrefsStepName(int i) {
    switch (i) {
        case 0: return "偏好+壁纸+视频层";
        case 1: return "重新登记灵动岛宿主";
        case 2: return "遮罩导出+控制中心钩子";
        case 3: return "控制中心壁纸重载";
        case 4: return "锁屏通知宽度重排";
        case 5: return "锁屏卡片重绘";
        case 6: return "启动图/深色重刷";
        default: return "?";
    }
}
static void diPrefsRunStep(int idx);
static void diPrefsChainStep(int idx) {
    if (idx > 6) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.012 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ diPrefsRunStep(idx); });
}
static void diPrefsRunStep(int idx) {
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    @try {
        switch (idx) {
            case 0: refreshAll(); break;
            case 1: installKnownHosts(); break;
            case 2: diExportMaskSoon();
                    if (wpOn) diCCInstallOverlayHook();
                    break;
            case 3: {
                /* 2.7.32: 控制中心(循环/模糊/启用/声音)改了 → 立刻生效 */
                static NSInteger lastBlur = -1; static int lastLoop = -1;
                if (lastBlur != wpBlur || lastLoop != (int)wpLoopOn) {
                    if (lastBlur >= 0) gCCPath = nil;   /* 首次启动不强制重建 */
                    if (lastLoop == 0 && wpLoopOn) gCCLoopIdx = 0;
                    lastBlur = wpBlur; lastLoop = (int)wpLoopOn;
                }
                diCCReloadSurface();
                break;
            }
            case 4:
                /* 2.2.10: 锁屏通知宽度变更后立即重排 */
                if (lockWOn) {
                    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
                        if ([s isKindOfClass:[UIWindowScene class]])
                            for (UIWindow *w in ((UIWindowScene *)s).windows)
                                for (UIView *v in w.subviews) [v setNeedsLayout];
                }
                break;
            case 5: diRestyleAllLockPlatters(); break;
            case 6: diGLFReloadAndReapply(); break;
        }
    } @catch (NSException *e) {
        RLog(@"偏好刷新异常(已吞) 步骤%@: %@ — %@", @(diPrefsStepName(idx)), e.name, e.reason);
    }
    double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    if (ms > 120.0) RLog(@"[偏好] 步骤 %@ 耗时 %.0fms (慢)", @(diPrefsStepName(idx)), ms);
    diPrefsChainStep(idx + 1);
}
static void diPrefsRefreshNow(void) {
    gDIPrefsRefreshPending = NO;
    diPrefsChainStep(0);
}
static void prefsChanged(CFNotificationCenterRef, void *, CFStringRef, const void *, CFDictionaryRef) {
    gFramesDirty = YES; // 偏好变更(可能换了素材文件夹): 立即重扫
    gMaskGen++;         // 2.6.12: 让遮罩重新读图(设置页刚换了素材)
    diExportMaskSoon();
    /* 2.8.93: 一次拖动会连着来几十条通知, 以前每条都跑一遍全量刷新
       (全窗口走树 + 重建壁纸/视频层 + 重绘所有锁屏卡片) → 主线程堆死 → 安全模式。
       现在 0.18s 内只认一次, 停下来再刷; 开关/换素材的即时性不受影响。 */
    if (gDIPrefsRefreshPending) return;
    gDIPrefsRefreshPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ diPrefsRefreshNow(); });
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

/* 2.5.19: 当前是否在锁屏界面(锁屏/通知中心下拉态都算)
   2.6.28: 加上"锁屏视图真的在场"校验 —— 219 日志里 gLocked 残留导致横条被重复扫描缩放,
   宽度在 123x5 / 154x5 / 192x5 之间乱跳(用户: "横条又显示乱了")。
   现在要求 SBCoverSheetWindow / SBLockScreen 类视图存在且可见, 才认为锁屏真的在显示。 */
static BOOL diLockScreenShowing(void) {
    if (!gLocked) return NO;
    __block BOOL coverSheet = NO;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isHidden || w.alpha < 0.01) continue;
            NSString *cn = NSStringFromClass(w.class);
            if ([cn containsString:@"CoverSheet"] || [cn containsString:@"LockScreen"]) { coverSheet = YES; break; }
        }
        if (coverSheet) break;
    }
    return coverSheet;
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
        /* 2.6.30: 只收"真正贴在屏幕底部"的横条 —— 音量岛/亮度岛的档位条也是 h∈[3,9]
           的细横条, 219 日志里 154x5 / 192x5 在岛里乱跳就是它。这里加位置约束:
           横条中心必须在屏幕底部 15% 区域内, 否则跳过。 */
        UIWindow *pw = v.window;
        if (!pw) continue;
        CGRect rw = [v convertRect:v.bounds toView:pw];
        CGFloat screenH = pw.bounds.size.height;
        if (screenH > 10) {
            CGFloat cy = CGRectGetMidY(rw);
            if (cy < screenH * 0.85) continue;   /* 不在底部 → 不是底栏横条 */
            if (rw.size.width < 40.0) continue;  /* 太短 → 不是横条 */
        }
        /* 岛内视图直接排除(防止音量档位条被当成底栏横条去缩放) */
        BOOL inIsland = NO;
        for (UIView *a = v.superview; a && a != pw; a = a.superview) {
            NSString *acn = NSStringFromClass(a.class);
            if ([acn containsString:@"Aperture"] || [acn containsString:@"Island"]) { inIsland = YES; break; }
        }
        if (inIsland) continue;
        /* 2.6.28: 只上色, 不登记 —— 登记后 0.06s 心跳会按 homeBarLen 反复缩放这些
           宽泛几何候选(219 日志 154x5/192x5 即由此产生), 导致横条长度乱跳。 */
        diStylePillView(v);
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
    /* 2.8.4 功耗: 横条功能没开时空闲降频到 4fps(开着的横条仍在 60fps 心跳, 行为不变);
       开着时横屏态因为有"2 秒隐藏"计时在跑, 保守保持 60fps 不动 */
    if (!homeBarOn) {
        static int idle;
        diBarTickerSetInterval(++idle > 50 ? 0.25f : 0.06f);
        return;
    }
    diBarTickerSetInterval(0.06f);
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
static dispatch_source_t gBarTicker;   /* 2.8.4: 全局持有, 供降频函数复用 */
static float gBarTickerInterval = 0.06f;
static void diBarTickerSetInterval(float sec) {
    if (!gBarTicker) return;
    if (fabsf(gBarTickerInterval - sec) < 0.005f) return;
    gBarTickerInterval = sec;
    dispatch_source_set_timer(gBarTicker, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                              (int64_t)(sec * NSEC_PER_SEC), 0.02 * NSEC_PER_SEC);
}
static void diStartBarFlowTicker(void) {
    if (gBarTicker) return;
    gBarTicker = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gBarTicker, DISPATCH_TIME_NOW, 0.06 * NSEC_PER_SEC, 0.01 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(gBarTicker, ^{ @autoreleasepool { diBarFlowTick(); } });
    dispatch_resume(gBarTicker);
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
/* ===== 2.9.39: 横条"触摸唤醒"范围 —— 只留底部中间那一段 =====
   2.9.37/2.9.38 用 UITouch.window 去换算 pill 坐标, 但 SpringBoard 里那个属性经常
   是 nil, 整条 sendEvent 主通道直接 continue 掉了 —— 用户实测"滑动一下不显示"。
   这一版把判定恢复成 2.9.33 的取坐标方式([t locationInView:nil]), 显示/唤回/计时
   逻辑一字不改, 只把"能唤醒的区域"从"左右两侧各 18%宽 × 中部 50%高"收窄成:
     · 界面坐标: 屏幕底边中间 34% 宽 × 54pt 高(用户红框标的那一段);
     · 未旋转坐标: 左右两缘各 12% 深 × 中部 1/3 长(2.9.33 判据的居中收窄版)。
   两套任一套命中即唤回, 区域外一律不触发。 */
static BOOL diHitBottomMiddle(CGPoint p, CGSize size) {
    if (size.width < 1.0 || size.height < 1.0) return NO;
    CGFloat w = size.width * 0.34;
    CGRect hit = CGRectMake((size.width - w) * 0.5, size.height - 54.0, w, 54.0);
    return CGRectContainsPoint(CGRectInset(hit, 0, -10.0), p);
}

/* ===== 2.9.42: 17 上直接锁死"横条本体那一块" =====
   401 反馈: 16 上锁死正常了, 17 上还是到处误触。原因是 17 的触摸坐标空间与 16
   不同(横屏时有的窗口已经转过, 有的没转), 2.9.39 那两套"按屏幕比例猜"的矩形在 17
   上会大面积命中(底边 34% 宽那套在转过的坐标系里能框住左下/右下整片)。
   这一版在 17 上改成**不猜**: 拿横条(pill)自己的真实 frame 换算到当前坐标系,
   只有落在横条本体 + 少量容差里才唤醒, 其他一律不触发。找不到 pill 才退回老判据。 */
static BOOL diHitBarPillRect(CGPoint p, UIView *coordView, BOOL *sawPill) {
    if (sawPill) *sawPill = NO;
    if (!gBarPills) return NO;
    BOOL anyPill = NO;
    for (UIView *pill in [gBarPills allObjects]) {
        if (!pill.window) continue;
        CGRect r = [pill convertRect:pill.bounds toView:coordView];
        if (r.size.width < 24.0 || r.size.height < 1.5) continue;
        if (r.size.width > 520.0) continue;          /* 异常全宽层, 不参与 */
        anyPill = YES;
        CGRect hit = CGRectInset(r, -10.0, -18.0);
        if (CGRectContainsPoint(hit, p)) { if (sawPill) *sawPill = YES; return YES; }
    }
    if (sawPill) *sawPill = anyPill;
    return NO;
}

static BOOL diBarHitTest(CGPoint p, UIView *coordView) {
    /* 0. 2.9.42: 17 上只认横条本体 */
    if (diIsIOS17Up()) {
        BOOL saw = NO;
        if (diHitBarPillRect(p, coordView, &saw)) return YES;
        if (saw) return NO;      /* 有 pill 却没命中 = 明确不在横条上 → 锁死 */
    }
    /* A. 界面坐标: 底边中间一段 */
    if (coordView) { if (diHitBottomMiddle(p, coordView.bounds.size)) return YES; }
    /* A2. 拿不到宿主窗口时, 按横屏矩形也判一次(有无旋转都能兜住) */
    CGSize scr0 = [UIScreen mainScreen].bounds.size;
    CGSize land = CGSizeMake(MAX(scr0.width, scr0.height), MIN(scr0.width, scr0.height));
    if (diHitBottomMiddle(p, land)) return YES;
    /* B. 竖屏(未旋转)坐标: 横屏时视觉底部的横条在左/右缘中部 */
    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGFloat pw = MIN(scr.width, scr.height), ph = MAX(scr.width, scr.height);
    BOOL inEdge = (p.x < pw * 0.12 || p.x > pw * 0.88);
    BOOL inMid  = fabs(p.y - ph * 0.5) < ph * 0.167;   /* 中部 1/3 */
    return inEdge && inMid;
}

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
    /* 2.9.39: 只认底部中间那一段 */
    if (!diBarHitTest([g locationInView:g.view], g.view)) return;
    diRevealBarNow("检测到触摸(中间区域)");
}
- (void)diSwiped:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan && g.state != UIGestureRecognizerStateChanged) return;
    CGPoint t = [g translationInView:g.view];
    if (fabs(t.y) < 5 && fabs(t.x) < 5) return;
    if (!gestureProtectOn) return;
    if (!diLandscapeNow()) return;
    /* 2.9.39: 起点不在底部中间那一段就不唤醒 */
    if (!diBarHitTest([g locationInView:g.view], g.view)) return;
    diRevealBarNow("检测到滑动(中间区域)");
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
            /* 2.9.39: 取坐标方式回到 2.9.33([t locationInView:nil]) ——
               UITouch.window 在 SpringBoard 里常为 nil, 2.9.38 因此整条失效。
               只把区域换成底部中间那一小段。 */
            for (UITouch *t in e.allTouches) {
                if (t.phase != UITouchPhaseBegan && t.phase != UITouchPhaseMoved) continue;
                CGPoint p = [t locationInView:nil];
                if (diBarHitTest(p, nil)) {
                    diRevealBarNow("sendEvent 触摸(中间区域)");
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


// MRUActivityArtworkView is the actual artwork owner in MediaRemoteUI.
// No artwork replacement, no BlurMask, and no generic CALayerHost clipping.
// 2.8.77: 按 N95 4.4 逆向证据修正三处 ——
//   1) 生效闸门不再依赖 artwork.window (远程场景下 window 可能为空, N95 不看它);
//   2) 增加 N95 同款上下文校验: _viewControllerForAncestor 必须精确落在
//      MRUActivityNowPlayingViewController —— 只处理展开岛音乐活动头像,
//      充电/人脸等其它岛一律不碰;
//   3) 应用时对 self 和 artworkImageView 设 clipsToBounds=NO (N95 同款,
//      防止系统裁剪把 mask 形状切掉); 原值存 state, 停用时恢复。
@interface DIActivityMaskState : NSObject
@property(nonatomic,strong) UIImageView *mask;
@property(nonatomic,strong) UIView *originalMask;
@property(nonatomic,weak) UIView *shadow;
@property(nonatomic,assign) BOOL originalShadowHidden;
@property(nonatomic,weak) UIView *imageView;              // 2.8.77 artworkImageView 原值保存
@property(nonatomic,assign) BOOL originalImageClips;
@property(nonatomic,assign) BOOL originalSelfClips;
/* ===== 2.8.82: 自绘玻璃(与小岛同一套观感) =====
   328 反馈: "改到图层了, 变小了, 我要跟小岛一样用同样的遮罩跟旋转"。
   用 maskView 直接裁系统那张专辑有两个死结:
     ① 系统专辑图是**按原比例居中绘制**的, 用 artworkFrame 当遮罩区域就等于把
        形状缩到那个小矩形里 → 看起来"专辑变小了";
     ② 系统专辑层不跟着我们的角度转 → 只有形状转、图不转。
   所以改成小岛 2.8.13 的做法: 把专辑图取出来自己画一层(图+遮罩同一视图),
   转的是这整张玻璃; 系统那张层只负责藏起来。 */
@property(nonatomic,strong) UIView *glass;
@property(nonatomic,strong) UIImageView *glassImage;
@property(nonatomic,strong) UIImageView *glassMask;
@property(nonatomic,weak) CALayer *systemLayer;
@property(nonatomic,assign) BOOL systemLayerHidden;
/* ===== 2.8.83: 把系统那张专辑"彻底"藏掉 =====
   329 反馈: "有旋转有遮罩了, 但是还有个底的遮罩显示, 重复了; 下面还有个蒙版, 多余的"。
   日志实锤: `glass 创建 ... 系统层=无` —— MRUActivityArtworkView 没有 artworkLayer,
   2.8.82 的隐藏完全没生效, 系统原图(圆角方块)就一直留在我们玻璃底下,
   于是同一张头像被画了两遍。这里改成逐子视图隐藏 + 清系统 mask/圆角,
   teardown 时按原值全部还原(不动功能, 只动显示)。 */
@property(nonatomic,strong) NSMutableArray<UIView *> *hiddenViews;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *hiddenStates;
@property(nonatomic,assign) BOOL maskSaved;
@property(nonatomic,strong) UIView *savedMaskView;
@property(nonatomic,strong) CALayer *savedLayerMask;
@property(nonatomic,assign) BOOL savedClips;
@property(nonatomic,assign) CGFloat savedCorner;
@property(nonatomic,strong) UIImage *lastArt;
@property(nonatomic,assign) CGFloat spinSpeed;
@property(nonatomic,assign) BOOL spinRev;
/* 2.9.74: 这颗玻璃是否经历过"小岛↔展开"的半途(过渡区)。
   经历过 → 它已经淡到 0, 收缩态里就**保持隐藏**, 不走 teardown
   (还原系统层就是那块"多出来的蒙版"); 没经历过(冷启动/切歌残留) → 照旧拆。 */
@property(nonatomic,assign) BOOL wasMid;
@end
@implementation DIActivityMaskState @end
static char kDIActivityMaskState;
static NSHashTable<UIView *> *gDIActivityArtworks;
static UIImage *gDIActivityShape;
static BOOL gDIActivityEnabled;
static int gDIActivityHit;   /* 2.8.79: 成功接管次数, 0 说明整条链路没走到 */
static IMP gDIActivityOrigLayout, gDIActivityOrigMove, gDIActivityOrigVisibility, gDIActivityOrigInit;

/* ===== 2.8.78: MediaRemoteUI 进程自证通道 =====
   该进程是独立沙盒: 日志写 /var/mobile/灵动岛 可能失败, 读素材也可能被拒。
   于是给它三条出口, 只要有一条通, SpringBoard 侧就能看到它到底走到哪一步:
     ① 文件: 灵动岛目录 → Library/Caches/com.abgg332.driftisland → tmp 依次试探可写路径;
     ② Darwin 通知: 固定名字打点, SpringBoard 收到写进同一份日志(325 日志里
        该进程 0 条记录, 用这条就能区分"没注入"和"注入但写不了日志")。 */
static NSString *gDiMruLogPath;
/* 2.8.82: MRU 自己的缓存目录(= SpringBoard 写入的同一个路径), 读素材/参数/写日志都在这 */
static NSString *diMruSelfDir(void) {
    static NSString *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *c = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        if (c.length) d = [c stringByAppendingPathComponent:@"com.abgg332.driftisland"];
    });
    return d;
}
/* 2.8.82: 旋转参数 —— 与小岛同一份设置(SpringBoard 每次导出时写好) */
static void diMruRotParams(BOOL *on, BOOL *rev, double *speed) {
    static BOOL cOn; static BOOL cRev; static double cSpeed = 45.0;
    static CFAbsoluteTime last; static NSString *lastSig;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (last == 0 || now - last > 1.0) {
        last = now;
        NSString *p = [diMruSelfDir() stringByAppendingPathComponent:@"params.plist"];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL];
        NSString *sig = [NSString stringWithFormat:@"%@_%@", attr[NSFileModificationDate], attr[NSFileSize]];
        if (![sig isEqual:lastSig]) {
            lastSig = sig;
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
            if ([d isKindOfClass:NSDictionary.class]) {
                cOn = [d[@"rot"] boolValue];
                cRev = [d[@"rev"] boolValue];
                double s = [d[@"speed"] doubleValue];
                cSpeed = (s > 1.0) ? MIN(s, 720.0) : 45.0;
            }
        }
    }
    *on = cOn; *rev = cRev; *speed = cSpeed;
}
static void diMruFileLog(NSString *line) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray<NSString *> *cands = [NSMutableArray array];
        if (diMruSelfDir().length) [cands addObject:[diMruSelfDir() stringByAppendingPathComponent:@"mru.log"]];
        [cands addObject:[kMaterialDir stringByAppendingPathComponent:@"driftisland.log"]];
        [cands addObject:[diMruCacheDir() stringByAppendingPathComponent:@"mru.log"]];
        [cands addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:@"driftisland-mru.log"]];
        for (NSString *p in cands) {
            [fm createDirectoryAtPath:[p stringByDeletingLastPathComponent]
                withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:NULL];
            BOOL ok = [fm fileExistsAtPath:p] ? [fm isWritableFileAtPath:p]
                : [fm createFileAtPath:p contents:[NSData data] attributes:@{NSFilePosixPermissions: @0666}];
            if (ok) { gDiMruLogPath = p; break; }
        }
    });
    if (!gDiMruLogPath) return;
    /* 3.0.18: 与主日志同一套修复 —— 缓存 formatter + 常驻句柄 + 每秒 25 行限流。
       这个进程(MediaRemoteUI)也在主线程写日志, 洪峰一样会把它拖死。 */
    static NSDateFormatter *df = nil;
    static dispatch_once_t fonce;
    dispatch_once(&fonce, ^{
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
    NSString *out = [NSString stringWithFormat:@"[%@] [MRU] %@%@\n", [df stringFromDate:[NSDate date]], line,
                     dropNote ?: @""];
    static NSFileHandle *h = nil;
    h = [NSFileHandle fileHandleForWritingAtPath:gDiMruLogPath];   /* 该进程日志路径可能切换, 每次取 */
    if (!h) { [out writeToFile:gDiMruLogPath atomically:YES encoding:NSUTF8StringEncoding error:NULL]; return; }
    @try { [h seekToEndOfFile]; [h writeData:[out dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (__unused NSException *e) {}
    [h closeFile];
}
static void diMruReport(NSString *tag, NSString *detail) {
    /* 同 tag 3 秒内只报一次 —— 这些函数在每帧布局里被调用, 不能刷屏 */
    static NSMutableDictionary<NSString *, NSNumber *> *lastT;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lastT = [NSMutableDictionary dictionary]; });
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSNumber *prev = lastT[tag];
    if (prev && now - prev.doubleValue < 3.0) return;
    lastT[tag] = @(now);
    NSString *name = [@"com.abgg332.driftisland.mru." stringByAppendingString:tag];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)name, NULL, NULL, true);
    diMruFileLog(detail.length ? [NSString stringWithFormat:@"%@ %@", tag, detail] : tag);
}
/* 2.8.79: MediaRemoteUI 是沙盒进程, CFPreferences 读不到时不报错、只静默返回默认值
   (开关就被当成"关", 于是永不遮罩)。N95 在同一位置是**直接读 plist 文件**并带 /var/jb
   兼容分支, 这里照抄这个思路, 作为第二条通道。 */
static BOOL diMruReadFilePref(NSString *key, BOOL *out) {
    static NSArray<NSString *> *paths;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        paths = @[@"/var/mobile/Library/Preferences/com.abgg332.driftisland.plist",
                  @"/var/jb/var/mobile/Library/Preferences/com.abgg332.driftisland.plist"];
    });
    for (NSString *p in paths) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        id v = d[key];
        if (!v) continue;
        *out = [v respondsToSelector:@selector(boolValue)] ? [v boolValue]
             : ([v isEqual:@"1"] || [v isEqual:@"true"] || [v isEqual:@"YES"]);
        return YES;
    }
    return NO;
}
/* 2.8.79: 带载荷的回传 —— 达林通知名本身可以带字符串, 把"祖先类名/类枚举结果"
   塞进通知名, SpringBoard 侧用 NULL 名观察者收(不需要该进程写得进日志)。
   名字只用 [A-Za-z0-9._-], 超长截断, 避免非法字符。 */
static void diMruPostPayload(NSString *tag, NSString *payload) {
    NSString *safe = payload.length ? payload : @"-";
    if (safe.length > 240) safe = [safe substringToIndex:240];
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"] invertedSet];
    safe = [[safe componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    NSString *name = [NSString stringWithFormat:@"com.abgg332.driftisland.mru.%@.%@", tag, safe];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)name, NULL, NULL, true);
}
/* 2.8.79: 一次都没接管成功时, 把本进程里名字带 Artwork/NowPlaying/Activity 的类回传 ——
   下一轮就不用猜"是不是类名错了", 直接拿到这版系统的真实类名。 */
static void diMruDumpClasses(void) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *buf = (Class *)malloc(sizeof(Class) * n);
    n = objc_getClassList(buf, n);
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        NSString *cn = NSStringFromClass(buf[i]);
        if ([cn containsString:@"Artwork"] || [cn containsString:@"NowPlaying"] || [cn containsString:@"Activity"]) {
            [hits addObject:cn];
            if (hits.count >= 40) break;
        }
    }
    free(buf);
    if (!hits.count) { diMruPostPayload(@"classes.none", @"-"); return; }
    /* 分批, 每批 6 个, 名字别超过上限 */
    for (NSUInteger i = 0, part = 0; i < hits.count; i += 6, part++) {
        NSArray *slice = [hits subarrayWithRange:NSMakeRange(i, MIN((NSUInteger)6, hits.count - i))];
        diMruPostPayload([NSString stringWithFormat:@"classes%lu", (unsigned long)part],
                         [slice componentsJoinedByString:@","]);
    }
}
/* 开关三态: 主偏好域 → 主偏好 plist 文件 → SpringBoard 导出的 diMruActive */
static BOOL diMruPrefOn(void) {
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    CFPreferencesAppSynchronize(dom);
    Boolean eValid = false, mValid = false;
    Boolean e = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), dom, &eValid);
    Boolean m = CFPreferencesGetAppBooleanValue(CFSTR("maskOn"), dom, &mValid);
    if (eValid && mValid) return e && m;
    BOOL fe = NO, fm = NO;
    BOOL hasE = diMruReadFilePref(@"enabled", &fe);
    BOOL hasM = diMruReadFilePref(@"maskOn", &fm);
    if (hasE && hasM) {
        diMruFileLog([NSString stringWithFormat:@"CFPreferences 不可读, 改读 plist 文件: enabled=%d maskOn=%d", fe, fm]);
        return fe && fm;
    }
    CFStringRef dom2 = CFSTR("com.abgg332.driftisland.mrumask");
    CFPreferencesAppSynchronize(dom2);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("diMruActive"), dom2));
    if (v) {
        BOOL a = [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
        diMruFileLog([NSString stringWithFormat:@"主偏好域不可读, 走 diMruActive=%d", a]);
        return a;
    }
    /* 2.8.81: 三条通道全读不到时按"开"处理 —— 用户在 SpringBoard 侧已经开了遮罩并导出了素材,
       这里静默判成"关"就是 2.8.77~80 "什么都不发生" 的第二个成因。 */
    diMruFileLog(@"开关三通道都不可读, 按开启处理");
    return YES;
}
/* 素材多通道: 素材目录 → Caches 导出图(含 /var/jb 前缀) → 偏好 base64 */
static UIImage *diActivityLoadShape(void) {
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    /* 2.8.82: 第一优先 —— 自己容器里的那份(SpringBoard 直接写进来, 沙盒允许) */
    if (diMruSelfDir().length) [cands addObject:[diMruSelfDir() stringByAppendingPathComponent:@"mask.png"]];
    NSString *path = diMaskCurrentPathV2();
    if (path) [cands addObject:path];
    [cands addObject:[diMruCacheDir() stringByAppendingPathComponent:@"mask.png"]];
    [cands addObject:@"/var/jb/var/mobile/Library/Caches/com.abgg332.driftisland/mask.png"];
    for (NSString *p in cands) {
        UIImage *img = diMaskAlphaCached(p);
        if (img) {
            diMruReport([p isEqualToString:path ?: @""] ? @"shape.material" : @"shape.cache", p);
            return img;
        }
    }
    diMruFileLog([NSString stringWithFormat:@"素材各通道均不可读: %@", [cands componentsJoinedByString:@" | "]]);
    CFStringRef dom = CFSTR("com.abgg332.driftisland.mrumask");
    CFPreferencesAppSynchronize(dom);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("diMruMaskB64"), dom));
    if ([v isKindOfClass:NSString.class] && [v length]) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:v options:0];
        UIImage *raw = data.length ? [UIImage imageWithData:data] : nil;
        if (raw) {
            UIImage *shape = diShapeFromLuma(raw);
            if (shape) { diMruReport(@"shape.prefs", nil); return shape; }
        }
    }
    diMruReport(@"shape.none", nil);
    return nil;
}
/* 2.8.77: N95 同款上下文校验 —— 祖先 VC 必须是 MRUActivityNowPlayingViewController。
   所有私有访问器都先做 respondsToSelector/类存在性检查, 取不到就返回 NO
   (与 N95 一致: 严格匹配, 时序靠 layout/didMove 反复重入解决)。 */
static UIViewController *diActivityAncestorVC(UIView *view) {
    SEL vcSel = NSSelectorFromString(@"_viewControllerForAncestor");
    if (!vcSel || ![view respondsToSelector:vcSel]) return nil;
    @try {
        return ((UIViewController *(*)(id, SEL))objc_msgSend)(view, vcSel);
    } @catch (__unused NSException *e) { return nil; }
}
static BOOL diActivityInNowPlaying(UIView *view) {
    Class target = NSClassFromString(@"MRUActivityNowPlayingViewController");
    if (!target) return NO;
    UIViewController *vc = diActivityAncestorVC(view);
    return vc && [vc isKindOfClass:target];
}
/* 2.8.82: 取这张专辑视图正在显示的图 —— 优先 artworkImage, 再退 layer.contents */
static UIImage *diActivityArtworkImage(UIView *view) {
    SEL sel = NSSelectorFromString(@"artworkImage");
    if ([view respondsToSelector:sel]) {
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(view, sel);
            if ([v isKindOfClass:UIImage.class]) return (UIImage *)v;
        } @catch (__unused NSException *e) {}
    }
    SEL lsel = NSSelectorFromString(@"artworkLayer");
    if ([view respondsToSelector:lsel]) {
        @try {
            id l = ((id (*)(id, SEL))objc_msgSend)(view, lsel);
            if ([l isKindOfClass:CALayer.class]) {
                id c = ((CALayer *)l).contents;
                if (c && CFGetTypeID((__bridge CFTypeRef)c) == CGImageGetTypeID())
                    return [UIImage imageWithCGImage:(__bridge CGImageRef)c];
            }
        } @catch (__unused NSException *e) {}
    }
    return nil;
}
/* ===== 2.9.36: iOS 17 专辑图变形修复(第三版) =====
   377/378 的日志实锤: `hit MRUActivityArtworkView {{0,0},{66,66}}` + `glass 创建
   bounds=66x66` —— 17 上无论收缩还是展开, 这个头像视图的 bounds 永远是 66x66,
   真正把它裁成小圆的是上面某一层容器, 而那一层既没有 clipsToBounds 也没有圆角,
   2.9.34/2.9.35 按"裁剪标志"去找, 一个都没找到(所以 可见区域 那行日志一次没打过)。
   这一版不再看标志, 直接把祖先链每一层的 bounds 换算进头像坐标系求交:
   收缩态自然收敛成那颗小圆所在的窗口(约 26x34), 展开态交出来还是 66x66, 不受影响。
   玻璃按这块窗口铺, 形状图按比例居中缩放(不再拉伸填满), 小圆就不会被压成椭圆。 */
/* 2.9.37: 16 上 2.9.33 的观感是对的, 17 才需要"可见窗口"这套。
   所有新逻辑都挂在这道闸门后面, 16 走原来的 bounds 路径, 一个像素都不改。 */
static BOOL diIsIOS17Up(void) {
    static int major = -1;
    if (major < 0) major = (int)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    return major >= 17;
}

static CGRect diAspectFitRect(CGSize src, CGRect box) {
    if (src.width <= 0.5 || src.height <= 0.5 || box.size.width <= 0.5 || box.size.height <= 0.5)
        return box;
    CGFloat k = MIN(box.size.width / src.width, box.size.height / src.height);
    CGFloat w = src.width * k, h = src.height * k;
    return CGRectMake(box.origin.x + (box.size.width - w) * 0.5,
                      box.origin.y + (box.size.height - h) * 0.5, w, h);
}

static CGRect diActivityVisibleRect(UIView *artwork, NSMutableString *diag) {
    if (!artwork) return CGRectZero;
    CGRect rect = artwork.bounds;
    UIView *v = artwork.superview;
    int guard = 0;
    while (v && guard++ < 12) {
        if (v == artwork.window) break;
        CGRect r = [artwork convertRect:v.bounds fromView:v];
        CGRect i = CGRectIntersection(rect, r);
        BOOL ok = !CGRectIsNull(i) && !CGRectIsEmpty(i)
                  && i.size.width > 2 && i.size.height > 2;
        BOOL shrunk = ok && (rect.size.width - i.size.width > 1.0 || rect.size.height - i.size.height > 1.0);
        if (diag) {
            [diag appendFormat:@"%@[%.0fx%.0f%@%@]", NSStringFromClass(v.class),
             v.bounds.size.width, v.bounds.size.height,
             (v.clipsToBounds || v.layer.masksToBounds) ? @"C" : @"",
             v.layer.mask ? @"M" : @""];
            if (shrunk) [diag appendFormat:@"→%.0fx%.0f", i.size.width, i.size.height];
            [diag appendString:@" "];
        }
        if (shrunk) rect = i;
        v = v.superview;
    }
    if (CGRectIsNull(rect) || rect.size.width < 4 || rect.size.height < 4) return artwork.bounds;
    return rect;
}

static void diActivityTeardown(UIView *artwork, DIActivityMaskState *state) {
    if (!state) return;
    [state.glass.layer removeAllAnimations];
    state.glassImage.maskView = nil;
    [state.glass removeFromSuperview];
    state.glass = nil; state.glassImage = nil; state.glassMask = nil;
    if (state.systemLayer) state.systemLayer.hidden = state.systemLayerHidden;
    state.systemLayer = nil;
    if (state.shadow) state.shadow.hidden = state.originalShadowHidden;
    /* 2.8.83: 按原值还原被我们藏起来的系统子视图 / mask / 圆角 */
    for (NSUInteger i = 0; i < state.hiddenViews.count; i++) {
        UIView *v = state.hiddenViews[i];
        NSNumber *h = (i < state.hiddenStates.count) ? state.hiddenStates[i] : nil;
        if (h) v.hidden = h.boolValue;
    }
    state.hiddenViews = nil; state.hiddenStates = nil;
    if (state.maskSaved) {
        artwork.maskView = state.savedMaskView;
        artwork.layer.mask = state.savedLayerMask;
        artwork.clipsToBounds = state.savedClips;
        artwork.layer.cornerRadius = state.savedCorner;
        state.maskSaved = NO;
        state.savedMaskView = nil; state.savedLayerMask = nil;
    }
    if (artwork.maskView == state.mask) artwork.maskView = state.originalMask;
    objc_setAssociatedObject(artwork, &kDIActivityMaskState, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
/* 2.8.83: 藏掉系统那张专辑的一切可见载体。
   顺序要点:
     ① 子视图: 除了我们自己的 glass, 全部 hidden —— 系统原图 UIImageView/packageView
        都属于这一类。日志里 `artworkLayer` 取不到, 只有这条路是可靠的;
     ② maskView / layer.mask: 系统(或旧版残留)的形状蒙版全部摘掉,
        它就是 329 反馈里"下面那个多余的蒙版";
     ③ 圆角 + clipsToBounds: 系统给头像加了圆角裁剪, 不摘掉的话我们旋转的
        玻璃在 45° 时会被这个方框切掉四个角, 看起来像"底下还有一层遮罩"。 */
static void diActivityHideSystem(UIView *artwork, DIActivityMaskState *state) {
    if (!state) return;
    if (!state.hiddenViews) {
        state.hiddenViews = [NSMutableArray array];
        state.hiddenStates = [NSMutableArray array];
    }
    for (UIView *sub in artwork.subviews) {
        if (sub == state.glass) continue;
        if ([state.hiddenViews containsObject:sub]) continue;
        [state.hiddenViews addObject:sub];
        [state.hiddenStates addObject:@(sub.hidden)];
        sub.hidden = YES;
    }
    if (!state.maskSaved) {
        state.maskSaved = YES;
        state.savedMaskView = artwork.maskView;
        state.savedLayerMask = artwork.layer.mask;
        state.savedClips = artwork.clipsToBounds;
        state.savedCorner = artwork.layer.cornerRadius;
    }
    if (artwork.maskView) artwork.maskView = nil;
    if (artwork.layer.mask) artwork.layer.mask = nil;
    if (artwork.clipsToBounds) artwork.clipsToBounds = NO;
    if (artwork.layer.cornerRadius != 0) artwork.layer.cornerRadius = 0;
}
/* 2.8.86: MRU 自己记的形态标志 —— 头像 66pt 即展开 */
static BOOL gDIMruExpandedFlag;
static CGSize gDIMruLastBox;
/* 2.8.86: 把展开/小岛状态回传给 SpringBoard(见 diMruSaysExpanded)。
   判据 = 头像本身的边长: 小岛 22~26pt, 展开 66pt。用 MIN(宽,高)>=38
   避开两侧配件(45x22)和过渡帧。最多 0.8s 写一次, 内容没变不写。 */
static void diMruWriteExpandState(BOOL expanded, CGSize box) {
    static BOOL lastE; static int lastW = -1, lastH = -1; static CFAbsoluteTime lastT;
    gDIMruExpandedFlag = expanded;   /* 文字调整也用它判形态, 比 root 尺寸可靠 */
    if (box.width > 0) gDIMruLastBox = box;
    int w = (int)lround(box.width), h = (int)lround(box.height);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastT < 0.8 && expanded == lastE && w == lastW && h == lastH) return;
    lastT = now; lastE = expanded; lastW = w; lastH = h;
    NSString *dir = diMruSelfDir();
    if (!dir.length) return;
    NSDictionary *d = @{@"expanded": @(expanded), @"w": @(w), @"h": @(h),
                        @"t": @(now), @"v": DI_BUILD_VER};
    @try { [d writeToFile:[dir stringByAppendingPathComponent:@"state.plist"] atomically:YES]; }
    @catch (__unused NSException *e) {}
}
/* ===== 2.9.38: 17 上"现在是不是收缩态" =====
   377~379 实锤: iOS17 的 MRUActivityArtworkView 恒 66x66, 收缩态也是这样, 所以
   按 bounds 判形态永远是"展开" → 收缩态也铺 66pt 玻璃 + 告诉 SpringBoard"展开",
   小岛那边于是整棵退场, 只剩这块错的玻璃 → 用户看到的"变形"。
   形态以 SpringBoard 写的 island.plist 为准(宿主真实尺寸: 小岛 ~189x37 / 展开 407x202),
   文件 3 秒没更新(或没写过)才退回祖先链尺寸兜底。 */
static BOOL diMruIslandCompact(UIView *artwork) {
    static CGSize sSize; static BOOL sHave; static CFAbsoluteTime sAt, sChecked;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - sChecked > 0.5) {
        sChecked = now;
        NSString *dir = diMruSelfDir();
        NSDictionary *d = dir.length
            ? [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"island.plist"]]
            : nil;
        if ([d isKindOfClass:NSDictionary.class]) {
            CGFloat w = [d[@"w"] doubleValue], h = [d[@"h"] doubleValue];
            if (w > 1.0 && h > 1.0) { sSize = CGSizeMake(w, h); sHave = YES; sAt = now; }
        }
    }
    if (sHave && now - sAt < 6.0)
        return (sSize.height < 70.0 || sSize.width < 240.0);
    /* 兜底: 祖先链上先碰到"明显小于展开宿主"的容器 → 收缩态 */
    for (UIView *v = artwork.superview; v && v != artwork.window; v = v.superview) {
        CGSize sz = v.bounds.size;
        if (sz.height >= 120.0 && sz.width >= 240.0) return NO;
        if (sz.height > 0.0 && sz.height < 55.0) return YES;
    }
    return NO;
}

/* ===== 2.9.54: 形态以 SpringBoard 播报的宿主尺寸为准(所有版本通用) =====
   返回 1=小岛 0=展开 -1=过渡帧(文件新鲜但尺寸卡在形态中间) -2=没拿到/已过期。
   386 日志(iOS 16, 宿主 185x52)里 MRU 只看得到 23x23 的头像, 却把"展开"写回给
   SpringBoard, 小岛玻璃刚画上就被整棵收掉。宿主真实尺寸只有 SpringBoard 知道,
   它每 2 秒写一次 island.plist, 3 秒内有效就采信。 */
static CGFloat gDIFormW = 0, gDIFormH = 0;   /* 2.9.67: 播报的宿主尺寸(过渡帧判向用) */
/* 2.9.70: 上一次的播报尺寸 —— 用来判"这一拍是在缩小", 收缩途中立刻让位 */
static CGFloat gDIFormPW = 0, gDIFormPH = 0;
static int gDIFormSB = 0;                    /* 2.9.68: SpringBoard 是否正画着小岛玻璃 */
static int diMruFormFromIsland(void) {
    static int cForm = -2; static CFAbsoluteTime cChecked;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    /* 2.9.64: 读盘缓存 0.5 → 0.15 秒 —— 395: 展开第一帧可能还读到 0.5 秒前的
       "收缩", 白白拆一次玻璃("偶尔先方再圆"的残党)。
       2.9.65: 0.1 秒 —— 播报端过渡帧已经放到 16Hz, 这里跟上。
       2.9.68: 0.05 秒 —— sb 交接标志(SpringBoard 是否还画着)一变就要立刻看到,
       否则展开起手的 0.2 秒窗口会被读盘延迟吃掉。 */
    if (now - cChecked < 0.05) return cForm;
    cChecked = now;
    NSString *dir = diMruSelfDir();
    NSDictionary *d = dir.length
        ? [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"island.plist"]]
        : nil;
    if (![d isKindOfClass:NSDictionary.class]) { cForm = -2; gDIFormW = gDIFormH = 0; gDIFormSB = 0; return cForm; }
    double t = [d[@"t"] doubleValue];
    CGFloat w = [d[@"w"] doubleValue], h = [d[@"h"] doubleValue];
    if (w < 1.0 || h < 1.0 || fabs(now - t) > 3.0) { cForm = -2; gDIFormW = gDIFormH = 0; gDIFormSB = 0; return cForm; }
    gDIFormPW = gDIFormW; gDIFormPH = gDIFormH;
    gDIFormW = w; gDIFormH = h;
    gDIFormSB = [d[@"sb"] intValue] ? 1 : 0;
    /* ===== 2.9.62: 认播报的形态位, 不再按 w/h 反推 =====
       393 日志实锤: 展开动画中间帧(227x44 之类)按 w/h 反推会被判成"小岛",
       展开确认期被清零 → 玻璃要等动画结束再 +1.2 秒才铺(用户: "展开先显示
       一下方形的, 一会才显示圆的")。播报端本来就写了 mini/expand 两位:
       展开动画中间帧两位都是 0 → 返回 -1(未知), 不清确认期也不确认。
       2.9.65: 再细分一层 —— -2=文件缺失/过期(真没信号), -1=文件是新鲜的、
       但尺寸正好卡在形态中间(展开/收起的动画帧)。两种情况在 MRU 侧处理不同:
       过渡帧要"保留现有玻璃", 没信号才按"拆掉"处理。 */
    int mini = [d[@"mini"] intValue], exp = [d[@"expand"] intValue];
    if (exp == 1 && (h >= 70.0 && w >= 240.0)) { cForm = 0; return cForm; }
    if (mini == 1 && (h < 70.0 || w < 240.0))  { cForm = 1; return cForm; }
    cForm = -1;
    return cForm;
}

/* ===== 2.9.56: 17 收缩态的"活证据" —— 那颗 23x23 的小头像 =====
   388 日志实锤: 岛收起后 MRU 里同时躺着两颗头像 ——
     · MRUActivityAccessoryView[22x22] → MRUActivityNowPlayingView[189x37] → 头像 23x23
     · MRUActivityAccessoryView[66x66] → MRUActivityNowPlayingView[407x198] → 头像 66x66
   后一颗是展开态的残留(离屏), 但系统仍会 layout 它, 我们的扫描器每秒也重新接管一次,
   它会一直申请 66pt 玻璃。展开态只有 66 那颗、没有 23 那颗, 所以"23 那颗在不在"
   是比跨进程文件更硬的形态证据(文件会被多块岛容器反复改写)。 */
static BOOL diMruCompactSiblingExists(UIView *artwork) {
    if (!gDIActivityArtworks) return NO;
    for (UIView *v in gDIActivityArtworks.allObjects) {
        if (v == artwork || ![v isKindOfClass:UIView.class]) continue;
        if (!v.window || v.hidden || v.alpha < 0.05) continue;
        CGSize s = v.bounds.size;
        CGFloat side = MIN(s.width, s.height);
        if (side < 8.0 || side > 30.0) continue;
        BOOL sawHost = NO, hostCompact = NO;
        for (UIView *a = v.superview; a && a != v.window; a = a.superview) {
            if ([NSStringFromClass(a.class) containsString:@"NowPlaying"]) {
                sawHost = YES;
                hostCompact = (a.bounds.size.height < 70.0);
                break;
            }
        }
        /* 找不到 NowPlaying 宿主时也认(头像自己 ≤30 就是收缩那颗) */
        if (!sawHost || hostCompact) return YES;
    }
    return NO;
}
/* ===== 2.9.59: 撤掉 2.9.58 的"现场收缩宿主"判据 =====

   391 日志实锤: 真展开时那块 189x37 收缩宿主并没有被系统撤掉, 判据在展开态也成立,
   于是 66 的展开玻璃被夹成 23 —— 用户: "你怎么把展开的缩小了"。
   而且"文件说展开"和"现场有收缩宿主"在真展开与切歌瞬间两个场景下信号完全相同,
   靠这两个信号永远分不开。唯一稳定的差异是时间: 真展开会一直持续, 切歌瞬间
   island.plist 只被残留容器写成"展开" 1~2 秒(390 日志)。所以改用"展开确认期"。 */

/* 2.9.58: 2.9.56 的 diMruTearDownBigArtworks 已删除 —— 收缩态的大残留头像不再靠
   "拆"来消灭, 而是就地按 23pt 画(见 diActivityApply 里的 box 夹取), 拆了又重画只会闪。 */

/* 2.8.82: 自绘玻璃 —— 图 + 同一张遮罩 + 同速旋转, 系统那张层只藏起来。
   这是小岛 2.8.13 起一直在用、已验证有效的那套观感, 这里在 MediaRemoteUI 内复刻。 */
/* ===== 2.9.74: 宿主(NowPlaying 容器)当前高度 =====
   展开态宿主恒 ≥190 高, 小岛态 ≤45 高; 中间 48~172 只出现在"小岛↔展开"的
   动画途中, 过渡区的淡入淡出全部按这个高度算系数。 */
static CGFloat diActivityHostHeight(UIView *artwork) {
    for (UIView *a = artwork.superview; a && a != artwork.window; a = a.superview) {
        if ([NSStringFromClass(a.class) containsString:@"NowPlaying"]) {
            CALayer *pl = a.layer.presentationLayer;
            return pl ? pl.bounds.size.height : a.bounds.size.height;
        }
    }
    return 0;
}
static void diActivityApply(UIView *artwork) {
    if (!NSThread.isMainThread || ![artwork isKindOfClass:UIView.class]) return;
    DIActivityMaskState *state = objc_getAssociatedObject(artwork, &kDIActivityMaskState);
    BOOL sized = artwork.bounds.size.width > 20 && artwork.bounds.size.height > 20;
    BOOL ios17 = diIsIOS17Up();
    /* ===== 2.9.48: 17 上小岛态 MRU 一律不参与 —— 用头像自身尺寸做硬判据 =====
       383 日志实锤: 小岛态 MRUActivityArtworkView 是 23x23(noart 行), 展开态才是 66x66。
       2.9.38 起靠 island.plist 判形态, 但它 6 秒没更新就退回祖先链兜底; 而祖先链里
       永远挂着那块 407x200 的离屏 NowPlayingView → 兜底判成"展开" → 在小岛左侧铺一块
       66pt 玻璃, 被岛体裁成一牙 = 用户看到的横向拉伸模糊图(视频 008/016/033 帧)。
       这里补一条不依赖跨进程文件的物理判据: 头像短边 <36pt 就是收缩态, MRU 立即让位。
       展开态头像恒 66x66, 不受影响。 */
    CGFloat artSide = MIN(artwork.bounds.size.width, artwork.bounds.size.height);
    /* 2.9.55: 形态只用 17 —— 16 走 2.9.48 原路(按宽高 38 判), 一行不改。
       2.9.56: 17 的形态判据改成"只认收缩, 不让文件否认收缩":
         · 头像自己 ≤30pt            → 收缩(这颗就是收缩态显示的那颗);
         · 同窗口里有收缩态小头像存活 → 收缩(见 diMruCompactSiblingExists);
         · island.plist 说收缩       → 收缩。
       以前是 island.plist 优先(-1/0/1 三态), 但 388 日志实锤 SB 侧多块岛容器
       (189x37 / 407x198 / 132x41)各自 layout 各自写盘, 同一秒内反复翻面, MRU 读到
       "展开"就按 66pt 铺玻璃, 读到"收缩"又拆 —— 于是岛收起后大字幕一直闪/留一块
       大玻璃(用户: "缩回去就回不去, 显示比较大")。文件只在"确认收缩"这一个方向上
       采信, 不再用它否决收缩。 */
    int formNow = ios17 ? diMruFormFromIsland() : -1;
    BOOL smallArt = (artSide <= 30.0);
    /* 2.9.59: 文件明确说展开时, "小头像在不在"不可采信(391: 展开前后 23 那颗仍在
       列表里), 否则展开态的 66 会被 sibling 判成收缩拆掉。 */
    BOOL sibling = (ios17 && !smallArt && formNow != 0) ? diMruCompactSiblingExists(artwork) : NO;
    /* ===== 2.9.70: 过渡帧先判方向, 再决定让不让位 =====
       展开只会变大, 收缩只会变小 —— 用"播报尺寸相对上一拍的变化"判向,
       比任何形态阈值都稳(小岛自己弹一下只有几个点, 不会误判)。 */
    BOOL growingForm = (gDIFormPW > 1.0 && gDIFormPH > 1.0 && gDIFormW > 1.0
                        && (gDIFormW - gDIFormPW > 24.0 || gDIFormH - gDIFormPH > 12.0));
    BOOL shrinkingForm = (gDIFormPW > 1.0 && gDIFormPH > 1.0 && gDIFormW > 1.0
                          && (gDIFormPW - gDIFormW > 24.0 || gDIFormPH - gDIFormH > 12.0));
    BOOL compact = ios17 && (smallArt || sibling || (formNow == 1 && !growingForm)
                             || (formNow < 0 && diMruIslandCompact(artwork)));
    /* ===== 2.9.66: 播报停摆 + 现场收缩 → 按收缩处理(修"暂停专辑变大") =====
       397 日志实锤: 暂停后 SpringBoard 的形态播报停摆(音乐岛结构判定断开,
       没人再写 island.plist), 文件停在最后一次的"展开"; MRU 于是继续按
       66x66 铺大玻璃, 而宿主早就缩回 189x37 —— 用户视频里小岛里嵌了一颗
       66pt 的专辑("暂停专辑变大")。
       现场证据比跨进程文件硬: 头像最近的 NowPlaying 宿主高度 <120 就是小岛
       (展开态恒 407x201)。真展开不会误伤 —— 只有"文件说展开、现场却说小岛"
       这种自相矛盾的情况才改判。 */
    if (ios17 && !smallArt && formNow == 0 && !growingForm) {
        for (UIView *a = artwork.superview; a && a != artwork.window; a = a.superview) {
            if ([NSStringFromClass(a.class) containsString:@"NowPlaying"]) {
                if (a.bounds.size.height > 0.5 && a.bounds.size.height < 120.0) compact = YES;
                break;
            }
        }
    }
    /* ===== 2.9.67: 过渡帧按"播报的宿主尺寸"判方向 =====
       398 日志实锤: 切歌/暂停那一瞬小岛会弹一下(209x40 → 219x45), 播报两位都是 0
       → formNow=-1; 2.9.65 为了修"展开时专辑先很小再变大", 把 -1 一律当成
       "展开动画中" → 按头像自身 66x66 铺玻璃。结果这块 45pt 高的小岛里被塞进
       一颗 66pt 的专辑 —— 用户三次反馈的"暂停专辑变大"。
       真展开在播报里是能看出尺寸的: 文件带着宿主 w/h。过渡帧里只要 w<240 或
       h<70, 岛还停在"小岛尺寸"上, 这颗 66 就不该铺 —— 按收缩处理, 交回小岛那颗
       23 头像 / SpringBoard 玻璃。只有宿主真的长到 ≥240x70(正在变大)才继续保留 66,
       2.9.65 修的"先小后大"不受影响。 */
    /* ===== 2.9.70: 过渡帧按方向决定让不让位 ===== */
    if (ios17 && !smallArt && formNow == -1 && gDIFormW > 1 && gDIFormH > 1
        && gDIFormW < 320.0 && gDIFormH < 90.0 && !growingForm) {
        /* 2.9.70: 240x70 → 320x90。400 日志里收缩中间帧是 268x60, 落在旧阈值外面
           → 66 大玻璃被 keepBig 留住 1.2 秒, 而它挂在展开态那颗残留头像上,
           位置在屏幕中间 —— 用户看到"小岛专辑从其他地方显示一下再回正常"。
           反过来, 正在变大(growingForm)时绝不能让位: 第一次展开时 SpringBoard
           的掩码可能还没加载(maskOn=0, gate 恒 0), 这边一让位就两边都没画,
           露出的就是系统那颗小专辑 —— 用户反复说的"第一次展开显示小专辑"。 */
        compact = YES;
    }
    /* ===== 2.9.68: 与 SpringBoard 的"谁在画"交接 —— 彻底分离, 互不干扰 =====
       399 日志 + 视频实锤: 展开起手那一刻**两边同时放手**——
         · SpringBoard 按小岛尺寸判, 宿主一到 213 宽就撤掉自己的玻璃;
         · MRU 这边播报还写着"小岛/过渡", 2.9.67 的规则把 66 判成收缩拆掉。
       于是 0.1~0.3 秒岛上什么都没有, 露出系统那颗很小的原生专辑, 等宿主长到
       240x70 才重铺 66 —— 用户: "展开又还是会触发小专辑然后变大 / 底闪一下"。
       现在用播报里的 sb 位(SpringBoard 当前是否正画着这块岛的玻璃)来分工:
         · sb=1 → 小岛归 SpringBoard, MRU 的 66 一律让位(不会叠出"变大");
         · sb=0 → SpringBoard 放手了, MRU 必须接手 —— 这时不再因为"宿主还小"
           就拆 66, 只有播报明确说"还停在 189x37 这种小岛原尺寸"才让位。 */
    static CFAbsoluteTime sNoSBSince = 0;
    static CFAbsoluteTime sMiniSince = 0;
    BOOL keepBig = NO;
    /* 2.9.69: 去掉 formNow>=-1 的限制 —— 399 里"展开先空白一下"最容易出现在
       播报还没写过的时刻(刚注销/刚重开屏), 那时 formNow=-2, 2.9.68 的交接逻辑
       整段被跳过, 66 照样被老规则拆掉。现在没播报也照样听 sb 的。 */
    if (ios17 && !smallArt) {
        if (gDIFormSB) {
            sNoSBSince = 0; sMiniSince = 0;
            if (formNow != 0) compact = YES;   /* SpringBoard 在画 → MRU 让位 */
        } else if (formNow != 0) {
            CGFloat fw = gDIFormW, fh = gDIFormH;
            BOOL stillMini = (formNow == 1 && fw > 1 && fh > 1 && fw < 200.0 && fh < 45.0);
            CFAbsoluteTime t68 = CFAbsoluteTimeGetCurrent();
            if (stillMini) {
                /* 2.9.72: 播报已经确认"还停在小岛原尺寸"就不再留 66 —— 只有还在
                   变大(展开起手)的 0.35 秒给一点宽限。旧版给满 1 秒, 暂停那一瞬
                   sb=0 时那颗 66 会在 37pt 的小岛里挂一整秒(用户: 暂停专辑那么大)。 */
                if (!sMiniSince) sMiniSince = t68;
                sNoSBSince = 0;
                if (growingForm && t68 - sMiniSince < 0.35) {
                    keepBig = YES;
                } else {
                    compact = YES;             /* 真还停在小岛原尺寸: 让位 */
                }
            } else {
                sMiniSince = 0;
                if (!sNoSBSince) sNoSBSince = t68;
                /* 兜底: 播报一直说 sb=0 却 1.2 秒都没有展开尺寸 → 别把 66 永挂 */
                keepBig = (t68 - sNoSBSince < 1.2);
            }
        } else { sNoSBSince = 0; sMiniSince = 0; }
    } else { sNoSBSince = 0; sMiniSince = 0; }
    if (keepBig) compact = NO;
    /* ===== 2.9.70: 收缩途中的"让位硬判据" =====
       400 日志实锤: 展开→小岛这段播报按 268x60 → 231x52 → 189x37 递减,
       而 2.9.69 的交接逻辑在 sb=0 时会给 66 最多 1.2 秒宽限, 这颗 66 挂在
       展开态残留头像上、位置在屏幕中间 —— 用户看到的就是"返回小岛时专辑
       先从别的地方显示, 过一下才回到正常位置"。
       判据: 播报尺寸比上一拍明显变小(宽 -24 或 高 -12) 且不是"确认展开" →
       立刻按收缩处理, 不让 keepBig 保留大玻璃。展开动画只会变大, 不会误伤。 */
    if (ios17 && !smallArt && formNow != 0 && shrinkingForm) {
        compact = YES;
        keepBig = NO;
    }
    /* ===== 2.9.71: 过渡途中"这颗大头像就是岛上正在显示的那颗" —— 一律不拆 =====
       401 日志 + 视频实锤(20:53:50 展开 / 20:53:10 收回):
         · 播报停在过渡帧(-1), 宿主只有 158x56 / 132x41(小岛尺寸);
         · MRU 里却有一颗 66x66 的大头像贴在展开位 {{21.67,24},{66,66}};
         · 2.9.70 的"过渡帧按宿主尺寸让位"把它判成收缩 → 拆玻璃。
       拆掉玻璃时系统那几层又被我们藏着, 岛上直接变全黑, 两秒后才重建 ——
       用户看到的"展开从小一下变大""收回小岛专辑偏一下才正常"就是这个空洞。
       现在: 只要是 66 的大头像、又没有可见的小头像(sibling=0), 它就是岛上
       正在显示的那颗, 让它跟着岛体动画走 —— 不拆、不重铺、不换尺寸。
       上限 0.9 秒: 真正的"展开态残留 66"最多多留 0.9 秒, 之后回到原来的规则。 */
    BOOL holdBig74 = NO;
    {
        static CFAbsoluteTime sHoldBigT = 0;
        static __weak UIView *sHoldBigV = nil;
        /* 2.9.72: 只在"播报缺失/过期/过渡帧"(formNow<0)时挂住。formNow==1(取消
           确认停在小岛)时绝不挂 —— 那会在暂停(小岛 189x37)里留一颗 66 的专辑。 */
        BOOL holdBig = (ios17 && compact && !smallArt && !sibling && artSide >= 56.0
                        && formNow < 0);
        if (holdBig) {
            if (sHoldBigV != artwork) { sHoldBigV = artwork; sHoldBigT = CFAbsoluteTimeGetCurrent(); }
            if (CFAbsoluteTimeGetCurrent() - sHoldBigT > 0.9) holdBig = NO;
        } else { sHoldBigV = nil; sHoldBigT = 0; }
        holdBig74 = holdBig;
        if (holdBig) { compact = NO; keepBig = YES; }
    }
    BOOL expConfirmed = (formNow == 0);
    /* ===== 2.9.74: 半途区(小岛 ↔ 展开) —— 只让"一颗圆"淡入淡出 =====
       404 反馈三连: "切回小岛多了一个图层""展开大岛有个小专辑环绕转圈"
       "那个多出来的蒙版又显示出来了"。逐帧看下来都是同一条:
       这段 0.2~0.4 秒里两边的玻璃各画各的 ——
         · 展开: 小岛容器的玻璃不跟着系统淡出, 停在原地转圈(旋转开着);
         · 收回: 66 那颗玻璃被"先别拆"留住, 岛已经缩成小胶囊, 它还挂在里面。
       现在按宿主高度算一个 0→1 的系数: 宿主还在小岛尺寸时圆不可见, 长到展开尺寸
       才完全显现; 收回时反过来。整段不拆、不还原系统层(还原出来的就是那块
       "多出来的蒙版"), 也就不存在"从别处飞过来"。 */
    CGFloat hostH74 = ios17 ? diActivityHostHeight(artwork) : 0;
    BOOL mid74 = (ios17 && !smallArt && hostH74 > 48.0 && hostH74 < 172.0);
    BOOL grow74 = NO;
    {
        static CGFloat sPrevH74 = 0;
        if (mid74) grow74 = (sPrevH74 > 1.0 && hostH74 > sPrevH74 + 4.0);
        sPrevH74 = hostH74;
    }
    /* 小岛那颗(23)也要跟着交班: 宿主在过渡区时它的 alpha 从 1 降到 0 ——
       两颗圆交错淡入淡出, 就不会出现"大岛里还挂着一颗小的在转"。 */
    BOOL midZone74 = (ios17 && hostH74 > 48.0 && hostH74 < 172.0);
    if (mid74) {
        compact = !grow74;      /* 变大半途当展开(写 YES, SB 闭嘴), 变小半途当收缩 */
        keepBig = grow74;
    }
    /* 2.9.74.1: "先别拆"(holdBig)只允许在**展开方向**报展开 —— 它本来就是为了
       展开起手别两边同时放手。收回方向(播报在缩小 / 宿主没在长)时, 这颗 66 只是
       淡出中的残影, 不能继续把 expanded 续成 YES: 408 日志实锤收回后 SB 侧还在
       "MRU 已确认展开 → 立即让位"整整 0.9 秒, 小岛玻璃被压着不画, 画面上就是
       MRU 那颗 23 顶上来再交回 SB —— 用户看到的"收回卡一下、专辑偏一下"。 */
    BOOL expWrite74 = sized && !compact && (expConfirmed || artSide >= 56.0);
    if (holdBig74 && !grow74 && shrinkingForm) expWrite74 = NO;
    else if (holdBig74 && !grow74 && !expConfirmed && hostH74 > 0.5 && hostH74 < 100.0) expWrite74 = NO;
    if (ios17)
        /* 2.9.60: 只有"确认过的展开"才向 SB 报展开 —— 切歌瞬间 66 残留被判
           非收缩但还没过确认期, 这时若报 YES, SB 16 侧刚恢复的小岛玻璃会被
           退场 + 1.5 秒迟滞压住(表现为切歌没遮罩)。17 侧已不读这个标志。 */
        diMruWriteExpandState(expWrite74, artwork.bounds.size);
    else
        diMruWriteExpandState(sized && artwork.bounds.size.width >= 38.0 && artwork.bounds.size.height >= 38.0,
                              artwork.bounds.size);
    /* 2.8.78: 判定过程必须可观测 —— 否则"没遮上"到底是没注入、没素材、还是
       上下文校验挡掉, 全靠猜(325 日志已经吃过这个亏)。
       2.8.79: 上下文校验保留退让档(类不存在时放行并把真实祖先打出来)。 */
    BOOL ctx = NO;
    if (gDIActivityEnabled && gDIActivityShape && sized) {
        BOOL strictExists = (NSClassFromString(@"MRUActivityNowPlayingViewController") != nil);
        if (strictExists) {
            ctx = diActivityInNowPlaying(artwork);
        } else {
            UIViewController *vc = diActivityAncestorVC(artwork);
            NSString *cn = vc ? NSStringFromClass(vc.class) : @"";
            ctx = (cn.length == 0) || [cn containsString:@"NowPlaying"] || [cn containsString:@"Activity"];
        }
    }
    BOOL want = gDIActivityEnabled && gDIActivityShape && sized && ctx;
    UIImage *art = (want || state) ? diActivityArtworkImage(artwork) : nil;
    if (want && !art && !state.lastArt) {
        diMruReport(@"noart", [NSString stringWithFormat:@"%@ %@",
            NSStringFromClass(artwork.class), NSStringFromCGRect(artwork.bounds)]);
        diMruPostPayload(@"noart", NSStringFromClass(artwork.class));
        want = NO;
    }
    if (!want) { diActivityTeardown(artwork, state); return; }

    /* ===== 2.9.55: 17 收缩态里有两颗头像, 按尺寸分开处理 =====
       387 日志实锤(17, 宿主 189x37):
         · 11:02:47	MRUActivityAccessoryView[22x22] → artwork 23x23  ← 小岛真正显示的那颗
         · 11:02:49	MRUActivityAccessoryView[66x66] → artwork 66x66  ← 展开态那颗
       岛收回后, 展开那颗(66x66)还会被 layout 到, 玻璃跟着铺 66pt —— 这就是用户说的
       "切换下一首放大就回不去了"。所以: 小岛态只给 23 那颗画, 大的立刻拆掉。
       16 完全不进这条分支(compact 恒 false)。 */
    if (compact) {
        diMruWriteExpandState(NO, artwork.bounds.size);   /* 别让旧 YES 续期 */
        if (!smallArt) {
            /* ===== 2.9.74: 收缩半途 —— 让这颗圆跟着缩、跟着淡 =====
               2.9.73 的"先别拆"是把它整颗 66 留在原地(用户: "多了一个图层/蒙版");
               直接拆又会还原系统层(那块按展开尺寸摆, "大的在下面")。
               现在折中: 不拆、不还原, 只按宿主高度把 alpha 从 1 淡到 0,
               岛缩到小胶囊时这颗大玻璃已经看不见了, 剩下的交给小岛那颗。 */
            if (state && state.glass && ios17 && (mid74 || state.wasMid)) {
                CGFloat t = 0.0;
                if (mid74) t = (hostH74 - 48.0) / (172.0 - 48.0);
                t = MIN(MAX(t, 0.0), 1.0);
                if (fabs(state.glass.alpha - t) > 0.02) state.glass.alpha = t;
                if (state.systemLayer && !state.systemLayer.hidden) state.systemLayer.hidden = YES;
                if (state.shadow && !state.shadow.hidden) state.shadow.hidden = YES;
                if (mid74) state.wasMid = YES;
                return;      /* 不拆、不还原 —— 一还原就是那块"多出来的蒙版" */
            }
            /* 2.9.59: 回到"拆掉"(2.9.58 的"就地画 23"会错位 —— 391 日志
               可见={{21.5,21.5},{23,23}}, 那是 66 残留框的居中点, 不是原生专辑位置)。
               小岛的遮罩由那颗 23 头像负责, 这颗大头像没有确认过的展开证据就还原。 */
            if (state) diActivityTeardown(artwork, state);
            static CFAbsoluteTime sBig17T;
            if (CFAbsoluteTimeGetCurrent() - sBig17T > 5.0) {
                sBig17T = CFAbsoluteTimeGetCurrent();
                CGRect inWin = artwork.window
                    ? [artwork convertRect:artwork.bounds toView:artwork.window] : CGRectZero;
                diMruFileLog([NSString stringWithFormat:
                              @"小岛态: 拆掉展开残留的大头像 头像 %.0fx%.0f 屏幕%@ (文件=%d 小头像=%d)",
                              artwork.bounds.size.width, artwork.bounds.size.height,
                              NSStringFromCGRect(inWin), formNow, (int)sibling]);
            }
            return;
        }
        /* 2.9.58: 不再"拆别人的大玻璃" —— 那颗 66 现在也按 23 画, 拆了又会被重画,
           只会造成一帧闪烁。各自按小岛尺寸画即可。 */
        static CFAbsoluteTime sCmp17T; static CGSize sCmp17Sz;
        if (CFAbsoluteTimeGetCurrent() - sCmp17T > 8.0 || !CGSizeEqualToSize(sCmp17Sz, artwork.bounds.size)) {
            sCmp17T = CFAbsoluteTimeGetCurrent(); sCmp17Sz = artwork.bounds.size;
            diMruFileLog([NSString stringWithFormat:
                          @"小岛态: 给可见头像铺玻璃 头像 %.0fx%.0f (宿主判据=%d)",
                          artwork.bounds.size.width, artwork.bounds.size.height, formNow]);
        }
    }

    /* 2.9.63: 这条分支现在只在"播报缺失/过期"(formNow<0)且大头像无收缩证据时走,
       属于保守让位, 不再发生在真展开的第一帧。 */
    /* ===== 2.9.65: 展开动画的"过渡帧"不再拆玻璃 =====
       396: 展开途中宿主经过 209x40 → 240x70 这一段时, 播报两端都不匹配
       (m=0), MRU 读到"未知" → 走下面这条保守让位 → 把 66 的玻璃拆掉,
       系统原生(很小)那张露出来; 等宿主长到 280x120 才重新铺 66 ——
       用户看到的就是"展开到大的时候专辑很小然后才变大"(396 日志里这段
       最长能拖 0.3~0.5 秒, 所以只是"偶尔")。
       现在: 文件新鲜但尺寸卡在中间(=-1) → 认定是展开/收起的动画帧,
       保留现有玻璃继续走, 玻璃按头像自身 bounds 铺(见下面 box 那段)。
       只有"文件根本没有/已过期"(=-2)才按保守让位拆掉。 */
    if (ios17 && !smallArt && !compact && !expConfirmed && formNow != -1 && !keepBig) {
        if (state) diActivityTeardown(artwork, state);
        static CFAbsoluteTime sHoldT;
        if (CFAbsoluteTimeGetCurrent() - sHoldT > 5.0) {
            sHoldT = CFAbsoluteTimeGetCurrent();
            diMruFileLog([NSString stringWithFormat:
                          @"无播报: 大头像暂不铺玻璃(文件缺/过期) 头像 %.0fx%.0f 文件=%d",
                          artwork.bounds.size.width, artwork.bounds.size.height, formNow]);
        }
        return;
    }

    /* 2.9.36: 算"窗口" —— 祖先链 bounds 求交。收缩态 = 小岛左边那颗小圆的口子,
       展开态 = 头像本身 66x66。玻璃只铺这块窗口, 不会再被外层裁成一牙。 */
    NSMutableString *chain = [NSMutableString string];
    CGRect box = ios17 ? diActivityVisibleRect(artwork, chain) : artwork.bounds;
    if (box.size.width < 4 || box.size.height < 4) box = artwork.bounds;
    /* ===== 2.9.65: 展开途中不再按"可见窗口"收玻璃 =====
       396 日志实锤: 展开动画途中祖先 bounds 还在 189x37 → 407x201 之间长,
       diActivityVisibleRect 求交出来的窗口很小(过渡帧), 玻璃就按小窗口铺;
       动画一结束窗口补满, 玻璃才"变大" —— 用户: "展开到大的时候会触发
       专辑很小然后才变大"。播报为"展开"(0)或"过渡帧"(-1)时,
       直接按头像自己的 bounds 铺(展开态恒 66x66), 玻璃跟岛体一起缩放, 不再重铺。 */
    if (ios17 && (formNow == 0 || formNow == -1 || keepBig)) box = artwork.bounds;
    BOOL collapsed = ios17 && (MIN(box.size.width, box.size.height) < 42);
    /* ===== 2.9.70: 收缩态直接铺头像自己(修"返回小岛时专辑先从别处显示") =====
       400 日志里收缩过渡帧的祖先窗口会在 189x37 ↔ 268x60 之间跳动, 求交出来的
       box 原点是偏的, 玻璃就先画在偏右/偏上的位置, 稳定后才被系统布局拉回原位。
       收缩态真正显示专辑的就是这颗 23pt 头像本身, 它的 bounds 就是最终位置 ——
       直接满铺, 系统怎么动画都跟着走, 不再自己算窗口。 */
    if (ios17 && collapsed
        && artwork.bounds.size.width > 4.0 && artwork.bounds.size.height > 4.0
        && MIN(artwork.bounds.size.width, artwork.bounds.size.height) < 42.0) {
        box = artwork.bounds;
    }
    /* 16 保持 2.9.33 的老判据(按 bounds), 不用窗口 */
    if (ios17) diMruWriteExpandState(!collapsed, box.size);
    if (collapsed && MIN(box.size.width, box.size.height) < 12) {
        /* 口子小到没法画(过渡帧) —— 这一帧撤掉, 免得留一条碎边 */
        if (state) diActivityTeardown(artwork, state);
        return;
    }
    static NSString *lastChain; static CGRect lastBox;
    if (ios17 && (!CGRectEqualToRect(lastBox, box) || ![lastChain isEqualToString:chain])) {
        lastBox = box; lastChain = [chain copy];
        diMruFileLog([NSString stringWithFormat:@"窗口 bounds=%@ 可见=%@ 收缩=%d 形=%d sb=%d 保大=%d 宿主=%.0fx%.0f | %@",
                      NSStringFromCGRect(artwork.bounds), NSStringFromCGRect(box),
                      (int)collapsed, formNow, gDIFormSB, (int)keepBig,
                      gDIFormW, gDIFormH, chain.length ? chain : @"(无收缩祖先)"]);
    }

    if (!state) {
        state = [DIActivityMaskState new];
        SEL shadowSel = NSSelectorFromString(@"artworkShadowView");
        if ([artwork respondsToSelector:shadowSel]) {
            id shadow = ((id (*)(id, SEL))objc_msgSend)(artwork, shadowSel);
            if ([shadow isKindOfClass:UIView.class]) {
                state.shadow = shadow;
                state.originalShadowHidden = [(UIView *)shadow isHidden];
            }
        }
        objc_setAssociatedObject(artwork, &kDIActivityMaskState, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIViewController *avc = diActivityAncestorVC(artwork);
        DLog(@"[真实专辑遮罩] 已接管 %@ %@ 祖先=%@",
             NSStringFromClass(artwork.class), NSStringFromCGRect(artwork.bounds),
             avc ? NSStringFromClass(avc.class) : @"(无)");
        diMruReport(@"hit", [NSString stringWithFormat:@"%@ %@ 祖先=%@",
            NSStringFromClass(artwork.class), NSStringFromCGRect(artwork.bounds),
            avc ? NSStringFromClass(avc.class) : @"(无)"]);
        diMruPostPayload(@"hit", [NSString stringWithFormat:@"%@_%@", NSStringFromClass(artwork.class),
            NSStringFromCGRect(artwork.bounds)]);
        diMruFileLog([NSString stringWithFormat:@"hit %@ %@ 祖先=%@",
            NSStringFromClass(artwork.class), NSStringFromCGRect(artwork.bounds),
            avc ? NSStringFromClass(avc.class) : @"(无)"]);
        gDIActivityHit++;
    }
    if (!state.glass) {
        /* 尺寸就是这张专辑视图自己的 bounds(不是 artworkFrame) —— 形状铺满整个头像,
           不会再出现"变小"的观感 */
        UIView *glass = [UIView new];
        glass.userInteractionEnabled = NO;
        glass.backgroundColor = UIColor.clearColor;
        glass.clipsToBounds = YES;
        glass.layer.allowsEdgeAntialiasing = YES;
        /* ===== 2.9.73: 玻璃"粘"在头像上, 跟着头像自己的 bounds 一起长/缩 =====
           403 视频逐帧: 展开时头像(和它的父容器 MRUActivityAccessoryView)是 22 → 66
           连续变大的, 但玻璃 frame 只在我们 0.1 秒一拍的扫描里改 —— 岛已经长满了,
           玻璃还停在 23, 下一拍才跳到 66: 用户看到的"专辑小了一下然后变大"。
           打开 autoresizing 后, 头像 bounds 每一帧变, UIKit 就在**同一次布局**里
           把玻璃一起缩放(和系统自己那些子视图一模一样), 玻璃再也不会慢半拍。 */
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        UIImageView *img = [UIImageView new];
        img.userInteractionEnabled = NO;
        img.contentMode = UIViewContentModeScaleAspectFill;
        img.clipsToBounds = YES;
        img.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        UIImageView *shape = [UIImageView new];
        shape.userInteractionEnabled = NO;
        shape.contentMode = UIViewContentModeScaleToFill;
        shape.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        img.maskView = shape;               /* 遮罩挂在图上: 转玻璃时图与形状一起转 */
        [glass addSubview:img];
        state.glass = glass; state.glassImage = img; state.glassMask = shape;
        SEL lsel = NSSelectorFromString(@"artworkLayer");
        if ([artwork respondsToSelector:lsel]) {
            @try {
                id l = ((id (*)(id, SEL))objc_msgSend)(artwork, lsel);
                if ([l isKindOfClass:CALayer.class]) {
                    state.systemLayer = (CALayer *)l;
                    state.systemLayerHidden = ((CALayer *)l).hidden;
                }
            } @catch (__unused NSException *e) {}
        }
        [artwork addSubview:glass];
        diMruFileLog([NSString stringWithFormat:@"glass 创建 bounds=%@ 系统层=%@",
            NSStringFromCGRect(artwork.bounds), state.systemLayer ? @"已找到" : @"无"]);
    }
    if (!CGRectEqualToRect(state.glass.frame, box)) {
        state.glass.frame = box;
        state.glass.layer.cornerRadius = 0;
        static CGFloat lastW, lastH; static NSString *lastCN;
        NSString *cn = NSStringFromClass(artwork.superview.class);
        if (fabs(lastW - box.size.width) > 0.5 || fabs(lastH - box.size.height) > 0.5 || ![lastCN isEqualToString:cn]) {
            lastW = box.size.width; lastH = box.size.height; lastCN = cn;
            diMruFileLog([NSString stringWithFormat:@"玻璃铺到 bounds=%@ 玻璃=%@ 父=%@",
                          NSStringFromCGRect(artwork.bounds), NSStringFromCGRect(box), cn]);
        }
    }
    if (!CGRectEqualToRect(state.glassImage.frame, state.glass.bounds)) state.glassImage.frame = state.glass.bounds;
    /* 2.9.36: 收缩态窗口是竖长条(约 26x34), 形状按比例居中缩放, 不把圆压成椭圆;
       展开态窗口就是正方形, 维持原来的铺满行为, 不动 16 上已经调好的观感。
       ===== 2.9.74.2: 这条保护对 16 也生效 =====
       16 上 collapsed 恒为 NO(判据带 ios17), 而 16 小岛右侧那颗专辑的窗口实测是
       45x22 / 26x22 —— 形状素材被 ScaleToFill 直接拉到窗口上, 圆就被横向拉成
       椭圆的"扁专辑"(用户 409 反馈, 16 也有)。现在不再看形态标志: 窗口不是正方形
       就取短边做正方形, 素材在其中等比居中(正圆素材 → 正圆, 任何素材都不会变形);
       正方形窗口(展开态)照旧铺满, 观感一点没变。 */
    CGRect mf = state.glassImage.bounds;
    if (collapsed || fabs(mf.size.width - mf.size.height) > 1.0) {
        CGFloat side = MIN(mf.size.width, mf.size.height);
        CGRect sq = CGRectMake(mf.origin.x + (mf.size.width - side) * 0.5,
                               mf.origin.y + (mf.size.height - side) * 0.5, side, side);
        mf = diAspectFitRect(state.glassMask.image ? state.glassMask.image.size : CGSizeZero, sq);
    }
    if (!CGRectEqualToRect(state.glassMask.frame, mf)) {
        static CFAbsoluteTime sShapeT;
        if (CFAbsoluteTimeGetCurrent() - sShapeT > 6.0) {
            sShapeT = CFAbsoluteTimeGetCurrent();
            diMruFileLog([NSString stringWithFormat:@"形状等比: 窗口 %@ → 形状 %@ (不拉扁)",
                          NSStringFromCGRect(state.glassImage.bounds), NSStringFromCGRect(mf)]);
        }
        state.glassMask.frame = mf;
    }
    if (art && state.glassImage.image != art) { state.glassImage.image = art; state.lastArt = art; }
    if (state.glassMask.image != gDIActivityShape) state.glassMask.image = gDIActivityShape;
    if (artwork.subviews.lastObject != state.glass) [artwork bringSubviewToFront:state.glass];
    /* 2.8.83: 彻底藏系统那张 —— 每次 apply 都做(系统会重建子视图), 只在新藏到东西时打日志 */
    {
        NSUInteger before = state.hiddenViews.count;
        BOOL maskBefore = state.maskSaved;
        UIView *sysMask = artwork.maskView;
        diActivityHideSystem(artwork, state);
        if (state.hiddenViews.count != before || (state.maskSaved && !maskBefore)) {
            diMruFileLog([NSString stringWithFormat:@"hide 系统子视图=%lu mask=%@ clips=%d 圆角=%.1f",
                (unsigned long)state.hiddenViews.count,
                sysMask ? NSStringFromClass(sysMask.class) : @"无",
                (int)state.savedClips, state.savedCorner]);
        }
    }
    if (state.systemLayer && !state.systemLayer.hidden) state.systemLayer.hidden = YES;
    if (state.shadow && !state.shadow.hidden) state.shadow.hidden = YES;

    BOOL rotOn = NO, rev = NO; double speed = 45.0;
    diMruRotParams(&rotOn, &rev, &speed);
    if (!rotOn) {
        if ([state.glass.layer animationForKey:@"di.spin"]) [state.glass.layer removeAnimationForKey:@"di.spin"];
        state.spinSpeed = 0;
    } else if (state.spinSpeed != speed || state.spinRev != rev
               || ![state.glass.layer animationForKey:@"di.spin"]) {
        [state.glass.layer removeAnimationForKey:@"di.spin"];
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        a.fromValue = @(rev ? 6.283185307179586 : 0.0);
        a.toValue   = @(rev ? 0.0 : 6.283185307179586);
        a.duration = 360.0 / MAX(fabs(speed), 1.0);
        a.repeatCount = HUGE_VALF;
        a.removedOnCompletion = NO;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [state.glass.layer addAnimation:a forKey:@"di.spin"];
        state.spinSpeed = speed; state.spinRev = rev;
        diMruFileLog([NSString stringWithFormat:@"spin 开=%@ 速度=%.0f°/s 反转=%d", rotOn ? @"是" : @"否", speed, rev]);
    }
    /* ===== 2.9.74.1: 半途区按宿主高度淡入, 但**展开方向恒全显** =====
       2.9.74 原来是 66 玻璃 alpha = t(0→1): 展开起手宿主刚过 48 时 alpha≈0,
       66 玻璃几乎透明, 后面那块系统原生模糊图就透出来了 —— 视频逐帧(408 的
       f43~f45)里"先显示空白/模糊专辑、然后才清晰"整段就是这么来的。
       现在: 展开(growing)方向 66 恒 alpha=1, 系统原生从一开始就被盖住;
       只有"确认在缩小"(shrinkingForm)时才按 t 淡出。小岛那颗(23)照旧随岛长大
       淡出, 它的位置本来就会被 66 取代。 */
    if (midZone74) {
        CGFloat t = (hostH74 - 48.0) / (172.0 - 48.0);
        t = MIN(MAX(t, 0.0), 1.0);
        CGFloat a;
        if (smallArt)          a = 1.0 - t;
        else if (shrinkingForm) a = t;
        else if (hostH74 >= 80.0) a = 1.0;   /* 卡片已够大: 66 全显, 原生模糊不透出 */
        else                   a = t;        /* 极小阶段由小岛那颗盖着, 不会空 */
        if (fabs(state.glass.alpha - a) > 0.02) state.glass.alpha = a;
        if (!smallArt) state.wasMid = YES;
    } else {
        if (state.glass.alpha < 0.999) state.glass.alpha = 1.0;
        if (!smallArt) state.wasMid = NO;
    }
    diMruReport(@"apply", [NSString stringWithFormat:@"%@ 旋转=%@", NSStringFromCGRect(box),
        rotOn ? [NSString stringWithFormat:@"%.0f°/s", speed] : @"关"]);
}

/* ===== 2.8.85: 展开定义 —— 展开岛的歌词/歌名位置与大小 =====
   为什么在 MRU 进程做: 展开音乐岛(407x202)整块是 MediaRemoteUI 的远程视图,
   SpringBoard 拿到的只有一块门户画面, 里面没有一个可操作的 UILabel。
   参数走 SpringBoard 导出的 params.plist(etOn/etX/etY/etScale), 这里读到后
   把控制器视图里的文字层统一做"整组缩放 + 平移":
     · 以整组文字的并集中心为锚点缩放(字号一起变, 相对位置不变);
     · 平移量就是设置页里的左右/上下偏移;
     · 每层都记录原始 center/transform, 关掉开关立刻还原。 */
typedef struct { BOOL on; CGFloat x, y, scale; BOOL hideRoute; } DIExpTextParams;
static void diMruExpandTextParams(DIExpTextParams *p) {
    static BOOL cOn; static CGFloat cX, cY, cScale = 100.0; static BOOL cHide;
    static CFAbsoluteTime last; static NSString *lastSig;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (last == 0 || now - last > 1.0) {
        last = now;
        NSString *path = [diMruSelfDir() stringByAppendingPathComponent:@"params.plist"];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        NSString *sig = [NSString stringWithFormat:@"%@_%@", attr[NSFileModificationDate], attr[NSFileSize]];
        if (![sig isEqual:lastSig]) {
            lastSig = sig;
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
            if ([d isKindOfClass:NSDictionary.class]) {
                cOn = [d[@"etOn"] boolValue];
                cX = [d[@"etX"] doubleValue];
                cY = [d[@"etY"] doubleValue];
                cScale = [d[@"etScale"] doubleValue];
                cHide = [d[@"hideRoute"] boolValue];
                if (cScale < 50) cScale = 50;
                if (cScale > 200) cScale = 200;
            }
        }
    }
    p->on = cOn; p->x = cX; p->y = cY; p->scale = cScale / 100.0;
    p->hideRoute = cHide;
}
/* 2.8.87: 不再记录 center —— 位置改成"以系统布局的左上角为锚点"换算进 transform,
   这样每次布局都从系统原值重算, 不会越积越偏, 也不会因为头部宽度变了而整体漂移。 */
static NSHashTable<UIView *> *gDIActivityTexts;
/* 2.8.89: 展开岛文字的固定落点 —— 第一次稳定展开时记下, 之后不再随系统布局变
   2.8.90: 落点落盘到 MRU 自己的容器 —— 软注销会重启这个进程, 只存内存的话
   重启后 anchor 丢失, 又按系统布局重记一次, 用户看到的就是"回原样"。 */
static CGPoint gDIExpAnchor;
static BOOL gDIExpAnchorValid;
static CGSize gDIExpAnchorRoot;
static NSString *diTextAnchorPath(void) {
    NSString *d = diMruSelfDir();
    return d.length ? [d stringByAppendingPathComponent:@"text_anchor.plist"] : nil;
}
static void diTextAnchorLoadOnce(void) {
    static BOOL tried;
    if (tried || gDIExpAnchorValid) return;
    tried = YES;
    NSString *p = diTextAnchorPath();
    NSDictionary *d = p ? [NSDictionary dictionaryWithContentsOfFile:p] : nil;
    if ([d isKindOfClass:NSDictionary.class]) {
        gDIExpAnchor = CGPointMake([d[@"x"] doubleValue], [d[@"y"] doubleValue]);
        gDIExpAnchorValid = YES;
    }
}
/* 时间戳(01:23 / -0:45)不是歌词, 不参与移动 */
static BOOL diTextIsClock(NSString *t) {
    if (!t.length) return NO;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^\\s*-?\\d{1,2}:\\d{2}\\s*$"
                                                       options:0 error:NULL];
    });
    return [re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)] != nil;
}
static BOOL diTextHasLabelChild(UIView *v, int depth) {
    if (depth < 0) return NO;
    for (UIView *c in v.subviews) {
        if ([c isKindOfClass:UILabel.class]) return YES;
        if (diTextHasLabelChild(c, depth - 1)) return YES;
    }
    return NO;
}
static BOOL diTextIsCandidate(UIView *v, UIView *root) {
    if (!v || v == root || v.hidden || v.alpha < 0.05 || !v.window) return NO;
    CGSize s = v.bounds.size;
    /* 2.8.86: 放宽到 12x6 ~ 90 高 —— 歌词常是 20~40 高的多行容器,
       上一版卡在 60, MRU 里稍微大一点的文字块整块被漏掉。 */
    if (s.width < 12 || s.height < 6 || s.height > 90) return NO;
    NSString *cn = NSStringFromClass(v.class);
    /* 2.8.91: 头部容器整块可能比 root 还宽(338 日志里 root 185 / header 231),
       以前这条"不能超过 root 96%"把它挡掉了, 于是整轮找不到头部, 一条 text 都不出。
       头部容器例外放行, 其余仍限制, 避免把整块背景当成文字。 */
    BOOL headerLike = [cn containsString:@"Header"];
    if (!headerLike && s.width > root.bounds.size.width * 0.96) return NO;
    BOOL isUILabel = [v isKindOfClass:UILabel.class];
    BOOL nameLike = [cn containsString:@"Label"] || [cn containsString:@"Text"]
                 || headerLike || [cn containsString:@"Marquee"];
    if (!isUILabel && !nameLike) return NO;
    /* 自定义容器(标题+歌词的竖排栈)也收 —— 但必须真的装着文字, 否则可能误伤图标容器 */
    if (!isUILabel && ![cn containsString:@"Label"] && !diTextHasLabelChild(v, 3)) return NO;
    if (isUILabel && diTextIsClock(((UILabel *)v).text)) return NO;
    return YES;
}
static void diActivityTextRestore(void) {
    if (!gDIActivityTexts) return;
    for (UIView *v in gDIActivityTexts.allObjects) {
        if (!CGAffineTransformIsIdentity(v.transform)) v.transform = CGAffineTransformIdentity;
    }
    [gDIActivityTexts removeAllObjects];
}
/* 2.8.88: 展开岛文字不再自动上色 —— 用户要求"颜色保持原样"。
   这里只保留还原: 早期版本给标签上过色的, 会把系统原色换回去。 */
static NSHashTable<UILabel *> *gDIExpColored;
static char kDIExpTextOrigKey;
static void diActivityTextColorRestore(void) {
    if (!gDIExpColored) return;
    for (UILabel *lb in gDIExpColored.allObjects) {
        NSDictionary *m = objc_getAssociatedObject(lb, &kDIExpTextOrigKey);
        if ([m isKindOfClass:NSDictionary.class]) {
            if (lb.attributedText.length) lb.text = lb.attributedText.string;
            id c = m[@"color"];
            if ([c isKindOfClass:UIColor.class]) lb.textColor = c;
        }
        objc_setAssociatedObject(lb, &kDIExpTextOrigKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [gDIExpColored removeAllObjects];
}
/* ===== 2.8.93: 隐藏投送(AirPlay / 输出设备)按钮 =====
   用户圈的是展开岛右下角那颗投送按钮。它和歌词一样活在 MediaRemoteUI 的远程内容里,
   SpringBoard 侧只有一块门户画面, 拿不到按钮, 所以在 MRU 进程里做:
   找到那颗按钮直接 hidden —— 它一透明, 底下自绘的视频/背景层就整块露出来,
   视觉上等于给那一块单贴了一层。关掉开关按原状恢复(记着原来是不是已经隐藏过)。 */
static NSHashTable<UIView *> *gDIRouteViews;
static char kDIRouteOrigHidden;
/* 341 日志: 名字先命中了 MPRouteLabel(36x13 的"设备名"小字), 把真正要藏的
   MRUTransportButton(44x44@365,131) 顶掉了 —— 结果那颗按钮还在。
   现在只认"按钮类"视图(UIControl / 类名带 Button / 带手势), 标签一律不算。 */
static BOOL diRouteIsButtonish(UIView *v) {
    if ([v isKindOfClass:UIControl.class]) return YES;
    if ([NSStringFromClass(v.class).lowercaseString containsString:@"button"]) return YES;
    if (v.gestureRecognizers.count > 0) return YES;
    return NO;
}
static BOOL diRouteNameHit(UIView *v) {
    if (!diRouteIsButtonish(v)) return NO;
    NSString *cn = NSStringFromClass(v.class).lowercaseString;
    NSString *lab = v.accessibilityLabel.lowercaseString ?: @"";
    BOOL nameYes = ([cn containsString:@"route"] || [cn containsString:@"airplay"]
                    || [cn containsString:@"airtunes"] || [cn containsString:@"outputdevice"]
                    || [lab containsString:@"airplay"] || [lab containsString:@"route"]
                    || [lab containsString:@"投送"] || [lab containsString:@"输出"]);
    if (!nameYes) return NO;
    CGSize sz = v.bounds.size;
    /* 只认"按钮大小"的 —— 免得把整行容器/标题一起藏了 */
    if (sz.width > 0 && sz.height > 0 && (sz.width > 90 || sz.height > 90)) return NO;
    return YES;
}
/* 3.0.23: 那颗投送按钮底下还有一层独立的"圆底"(半透明灰圆, 436 截图里箭头指的
   就是它)。它跟按钮是兄弟或包一层的轻量容器, 只把按钮 hidden 的话图标没了、圆还在。
   这里按"同中心 + 同量级"把光环一起带上; 判据很窄(中心差 ≤12pt, 边长 0.5~2.2 倍),
   整行容器/整卡不会被误伤。 */
static void diRouteHideHalo(UIView *hit) {
    if (!hit || !hit.superview) return;
    CGSize hs = hit.bounds.size;
    CGFloat side = MAX(hs.width, hs.height);
    if (side < 8.0) side = 44.0;
    CGPoint hcW = [hit convertPoint:CGPointMake(CGRectGetMidX(hit.bounds),
                                               CGRectGetMidY(hit.bounds)) toView:nil];
    NSMutableArray<UIView *> *extra = [NSMutableArray array];
    void (^consider)(UIView *, CGFloat) = ^(UIView *v, CGFloat cap) {
        if (!v || v == hit) return;
        if (!v.window || v.hidden) return;
        CGSize s = v.bounds.size;
        if (s.width < 8.0 || s.height < 8.0) return;
        CGFloat mx = MAX(s.width, s.height), mn = MIN(s.width, s.height);
        if (mx > side * cap) return;          /* 太大: 整行 / 整卡容器 */
        if (mn < side * 0.5) return;          /* 太扁: 分隔线 / 进度条 */
        CGPoint c = [v convertPoint:CGPointMake(CGRectGetMidX(v.bounds),
                                                CGRectGetMidY(v.bounds)) toView:nil];
        if (fabs(c.x - hcW.x) > 12.0 || fabs(c.y - hcW.y) > 12.0) return;
        if (![extra containsObject:v]) [extra addObject:v];
    };
    UIView *p = hit.superview;
    for (int i = 0; p && i < 3; i++, p = p.superview) {
        CGFloat cap = (i == 0) ? 2.2 : 1.6;
        for (UIView *sib in p.subviews) consider(sib, cap);
        consider(p, cap);
    }
    NSMutableString *names = [NSMutableString string];
    for (UIView *v in extra) {
        [names appendFormat:@"%@(%.0fx%.0f) ", NSStringFromClass(v.class),
         v.bounds.size.width, v.bounds.size.height];
        if ([gDIRouteViews containsObject:v]) { if (!v.hidden) v.hidden = YES; continue; }
        objc_setAssociatedObject(v, &kDIRouteOrigHidden, @(v.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [gDIRouteViews addObject:v];
        v.hidden = YES;
    }
    if (names.length) {
        static NSString *lastNames;
        if (![names isEqualToString:lastNames ?: @""]) {
            lastNames = [names copy];
            diMruFileLog([NSString stringWithFormat:@"route 光环一起隐藏: %@", names]);
        }
    }
}

static void diActivityHideRoute(UIView *root) {
    if (!NSThread.isMainThread || !root || !root.window) return;
    DIExpTextParams p; diMruExpandTextParams(&p);
    if (!gDIRouteViews) gDIRouteViews = [NSHashTable weakObjectsHashTable];
    if (!p.hideRoute) {
        if (gDIRouteViews.count) {
            for (UIView *v in gDIRouteViews.allObjects) {
                id o = objc_getAssociatedObject(v, &kDIRouteOrigHidden);
                v.hidden = o ? [o boolValue] : NO;
            }
            [gDIRouteViews removeAllObjects];
            diMruFileLog(@"route 恢复(开关=关)");
        }
        return;
    }
    /* 已经藏好了就别每帧重扫(展开动画里 layout 会连续触发) */
    if (gDIRouteViews.count) {
        BOOL alive = YES;
        for (UIView *v in gDIRouteViews.allObjects) if (!v.window) { alive = NO; break; }
        if (alive) return;
        for (UIView *v in gDIRouteViews.allObjects) v.hidden = NO;
        [gDIRouteViews removeAllObjects];
    }
    CGFloat W = root.bounds.size.width, H = root.bounds.size.height;
    if (W < 200 || H < 90) return;      /* 小岛/展开动画前段不动 */
    UIView *hit = nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger budget = 1200;
    NSMutableString *dump = [NSMutableString string];
    while (stack.count && budget--) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if (v != root) {
            CGPoint c = [v.superview convertPoint:v.center toView:root];
            CGSize sz = v.bounds.size;
            if (diRouteNameHit(v)) {
                hit = v;
                [dump appendFormat:@"名 %@(%.0fx%.0f@%.0f,%.0f) ", NSStringFromClass(v.class),
                    sz.width, sz.height, c.x, c.y];
                break;
            }
            /* 兜底: 右下角那颗 20~80pt 的按钮(实测投送在 78%~88% 宽度上, 下一首在 ~70%) */
            if (!hit && c.x > W * 0.73 && c.y > H * 0.52
                && sz.width >= 20 && sz.height >= 20 && sz.width <= 80 && sz.height <= 80
                && diRouteIsButtonish(v)) {
                hit = v;
                [dump appendFormat:@"位 %@(%.0fx%.0f@%.0f,%.0f) ", NSStringFromClass(v.class),
                    sz.width, sz.height, c.x, c.y];
            }
        }
        for (UIView *c in v.subviews) [stack addObject:c];
    }
    static NSString *lastSig; static CFAbsoluteTime lastT;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!hit) {
        if (now - lastT > 10.0) {
            lastT = now;
            diMruFileLog([NSString stringWithFormat:@"route 未找到按钮 (root %.0fx%.0f)", W, H]);
        }
        return;
    }
    if (![gDIRouteViews containsObject:hit]) {
        objc_setAssociatedObject(hit, &kDIRouteOrigHidden, @(hit.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [gDIRouteViews addObject:hit];
    }
    hit.hidden = YES;
    diRouteHideHalo(hit);
    NSString *sig = [NSString stringWithFormat:@"%p_%@", (__bridge void *)hit, dump];
    if (![sig isEqualToString:lastSig]) {
        lastSig = [sig copy];
        diMruFileLog([NSString stringWithFormat:@"route 隐藏 %@ (root %.0fx%.0f) %@",
            NSStringFromClass(hit.class), W, H, dump]);
    }
}
static void diActivityTextApply(UIView *root) {
    if (!NSThread.isMainThread) return;
    DIExpTextParams p; diMruExpandTextParams(&p);
    diTextAnchorLoadOnce();
    if (!gDIActivityTexts) gDIActivityTexts = [NSHashTable weakObjectsHashTable];
    /* 2.8.86: 每条分支都留痕 —— 上一版"没反应"和"根本没装"在日志里长得一模一样,
       333 日志里连一条 text 都没有, 根本没法判断卡在哪。 */
    static CFAbsoluteTime sSkipT; static NSString *sSkipWhy;
    NSString *why = nil;
    /* 2.8.90: 不再用"MRU 头像 <38pt"当硬闸门 —— 展开/收起动画里它会在 23/66 之间抖,
       一旦这一帧判成小岛就把刚摆好的文字还原, 于是"每次展开都回原样"。
       现在改成先看视图树里到底有没有展开态的头部容器(见下面的 header 判断)。 */
    if (!p.on) why = @"开关=关(params.plist etOn=0)";
    else if (!root || !root.window) why = @"root 不在窗口上";
    else if (root.bounds.size.width < 120) why = [NSString stringWithFormat:@"root 太窄 %.0f",
               root.bounds.size.width];
    if (why) {
        diActivityTextRestore();
        diActivityTextColorRestore();
        if (![why isEqualToString:sSkipWhy] || CFAbsoluteTimeGetCurrent() - sSkipT > 8.0) {
            sSkipT = CFAbsoluteTimeGetCurrent(); sSkipWhy = [why copy];
            diMruFileLog([NSString stringWithFormat:@"text 跳过 %@", why]);
        }
        return;
    }
    /* 收集文字层(最多 8 层/1200 节点, 展开岛层级很浅) */
    NSMutableArray<UIView *> *cands = [NSMutableArray array];
    UIView *header = nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger budget = 1200;
    while (stack.count && budget--) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if (v != root && diTextIsCandidate(v, root)) {
            [cands addObject:v];
            /* 2.8.86: 头部容器里就是歌名 + 歌词 + 歌手, 整块搬最稳 */
            if (!header && [NSStringFromClass(v.class) containsString:@"Header"]) header = v;
        }
        for (UIView *c in v.subviews) [stack addObject:c];
    }
    if (!cands.count) {
        diActivityTextRestore();
        if (CFAbsoluteTimeGetCurrent() - sSkipT > 8.0) {
            sSkipT = CFAbsoluteTimeGetCurrent();
            sSkipWhy = @"候选=0";
            diMruFileLog([NSString stringWithFormat:@"text 跳过 候选=0 (root %.0fx%.0f)",
                root.bounds.size.width, root.bounds.size.height]);
        }
        return;
    }
    NSMutableArray<UIView *> *targets = [NSMutableArray array];
    if (header) {
        [targets addObject:header];
    } else {
        /* 祖先已经进候选的, 不再单独转(转父层就够, 避免重复缩放) */
        for (UIView *v in cands) {
            BOOL covered = NO;
            for (UIView *a = v.superview; a && a != root; a = a.superview) {
                if ([cands containsObject:a]) { covered = YES; break; }
            }
            if (!covered) [targets addObject:v];
        }
    }
    if (!targets.count) { diActivityTextRestore(); return; }
    /* 2.8.89: 位置锁死 —— 不再拿"系统这次排在哪"当基准。
       337 日志: 同一次展开里头部会有 231x66@107,22 / 201x57@105,-16 / 136x57@17,-52
       好几份(展开副本、收起副本、动画快照), 每份 base 都不同; 按各自 base 摆,
       用户每次展开看到的位置自然跟着变。现在:
         · 只认"稳定展开态"(高度 >=50 且 y >=0), 收起/过渡副本保持系统原样;
         · 第一次稳定展开时把整组中心记下来(anchor), 之后固定用它 + 设置偏移;
         · 系统再重排、换歌、宽度变化, 都只围绕这个中心缩放, 落点不再动。 */
    NSMutableArray<UIView *> *stable = [NSMutableArray array];
    NSMutableString *dump = [NSMutableString string];
    CGRect unionRect = CGRectNull;
    CGRect unionPos = CGRectNull;      /* 只算 y>=0 的那份, 用来记首次落点(更接近真正展开的位置) */
    for (UIView *v in targets) {
        if (!v.superview) continue;
        v.transform = CGAffineTransformIdentity;          /* 先还原, 取系统布局值 */
        CGRect base = v.frame;
        /* 2.8.90: 只按"是不是展开态的头部"筛(宽>=100, 高>=45), 不再看 y>=0。
           337/338 里同一个头部会有 y=-16 / -52 的副本, 那其实是同一块文字的另一份
           快照; 以前把它们排除, 结果屏幕上显示的恰好是那份, 于是"怎么设都没动"。 */
        if (base.size.height < 45.0 || base.size.width < 100.0) {
            [dump appendFormat:@"%@(跳过 %.0fx%.0f@%.0f,%.0f) ", NSStringFromClass(v.class),
                base.size.width, base.size.height, base.origin.x, base.origin.y];
            continue;
        }
        CGPoint c = [v.superview convertPoint:v.center toView:root];
        CGRect r = CGRectMake(c.x - base.size.width * 0.5, c.y - base.size.height * 0.5,
                              base.size.width, base.size.height);
        unionRect = CGRectIsNull(unionRect) ? r : CGRectUnion(unionRect, r);
        if (base.origin.y >= 0.0) unionPos = CGRectIsNull(unionPos) ? r : CGRectUnion(unionPos, r);
        [stable addObject:v];
        [dump appendFormat:@"%@(%.0fx%.0f@%.0f,%.0f) ", NSStringFromClass(v.class),
            base.size.width, base.size.height, base.origin.x, base.origin.y];
    }
    if (!stable.count) {
        /* 没有展开态头部: 真·小岛(或还在动画前段), 还原成原生, 不做任何摆位 */
        diActivityTextRestore();
        diActivityTextColorRestore();
        return;
    }
    /* 目标集合变了(逐标签 <-> 头部容器)先把上一轮改过的全部还原, 否则旧目标会停在缩放态 */
    BOOL sameSet = (gDIActivityTexts.count == stable.count);
    if (sameSet) {
        for (UIView *v in stable) if (![gDIActivityTexts containsObject:v]) { sameSet = NO; break; }
    }
    if (sameSet) [gDIActivityTexts removeAllObjects];
    else diActivityTextRestore();

    CGPoint sysCenter = CGPointMake(CGRectGetMidX(unionRect), CGRectGetMidY(unionRect));
    CGRect anchorRect = CGRectIsNull(unionPos) ? unionRect : unionPos;
    CGPoint anchorCenter = CGPointMake(CGRectGetMidX(anchorRect), CGRectGetMidY(anchorRect));
    if (!gDIExpAnchorValid) {
        /* 只在"从来没有落点"时记一次(正常只在首次安装/首次开启时), 之后永远用同一个,
           不再因为 root 宽度变化而重记 —— 那正是布局一变位置就跳的原因。 */
        gDIExpAnchor = anchorCenter;
        gDIExpAnchorRoot = root.bounds.size;
        gDIExpAnchorValid = YES;
        NSString *ap = diTextAnchorPath();
        if (ap) {
            [@{@"x": @(anchorCenter.x), @"y": @(anchorCenter.y)} writeToFile:ap atomically:YES];
        }
        diMruFileLog([NSString stringWithFormat:@"text 锁定落点 (%.0f,%.0f) root %.0fx%.0f 落盘=%@",
            anchorCenter.x, anchorCenter.y, root.bounds.size.width, root.bounds.size.height,
            ap ? @"OK" : @"无路径"]);
    }
    CGPoint target = CGPointMake(gDIExpAnchor.x + p.x, gDIExpAnchor.y + p.y);
    CGFloat s = p.scale;
    for (UIView *v in stable) {
        UIView *sv = v.superview;
        CGPoint c0 = [sv convertPoint:v.center toView:root];
        CGPoint nRoot = CGPointMake(target.x + (c0.x - sysCenter.x) * s,
                                    target.y + (c0.y - sysCenter.y) * s);
        CGAffineTransform want = CGAffineTransformMakeScale(s, s);
        CGPoint wantC = [root convertPoint:nRoot toView:sv];
        /* 3.0.16: 只在"真的要变"时才写 —— 以前每次布局都写一遍 transform+center,
           而这两个属性一改就会把父视图标脏、触发它再排一次版(3×2 里就是整条按钮跟着
           抖一下)。值已经对上就一个字都不写。 */
        if (CGAffineTransformEqualToTransform(v.transform, want)
            && fabs(v.center.x - wantC.x) < 0.5 && fabs(v.center.y - wantC.y) < 0.5) {
            [gDIActivityTexts addObject:v];
            continue;
        }
        v.transform = want;
        v.center = wantC;
        [gDIActivityTexts addObject:v];
    }
    /* 2.8.88: 只摆位置/大小, 颜色一律保持系统原样 */
    diActivityTextColorRestore();
    static NSString *lastDump; static CFAbsoluteTime lastLogT;
    NSString *sig = [NSString stringWithFormat:@"%.0f_%.0f_%.0f_%@", p.x, p.y, p.scale * 100, dump];
    if (![sig isEqualToString:lastDump] || CFAbsoluteTimeGetCurrent() - lastLogT > 15.0) {
        lastDump = [sig copy];
        lastLogT = CFAbsoluteTimeGetCurrent();
        diMruFileLog([NSString stringWithFormat:@"text 移动 %lu 层(%@) 偏移(%.0f,%.0f) 缩放 %.0f%% 落点(%.0f,%.0f) [%@]",
            (unsigned long)stable.count, header ? @"头部容器" : @"逐标签",
            p.x, p.y, p.scale * 100, target.x, target.y, dump]);
        diMruReport(@"text", [NSString stringWithFormat:@"n%lu_%.0f_%.0f_%.0f_%@",
            (unsigned long)stable.count, p.x, p.y, p.scale * 100, header ? @"h" : @"l"]);
    }
}
/* 2.8.85: 控制器每次布局后重新应用一次 —— 系统会重排标签, 只在定时器里改会被覆盖 */
static IMP gDIActivityOrigTextLayout;
static void diActivityTextLayout(id self, SEL cmd) {
    if (gDIActivityOrigTextLayout) ((void (*)(id, SEL))gDIActivityOrigTextLayout)(self, cmd);
    @try {
        if ([self isKindOfClass:UIViewController.class]) {
            UIViewController *vc = (UIViewController *)self;
            if (vc.isViewLoaded) {
                diActivityHideRoute(vc.view);
                diActivityTextApply(vc.view);
            }
        }
    } @catch (__unused NSException *e) {}
}
/* ===== 2.8.86: 文字 hook 独立安装, 可重试 =====
   上一版的死结: `if (installed) return;` 在文字 hook **之前**, 而这个 hook 只在
   diActivityStart 调一次 —— 那时 MRUActivityNowPlayingViewController 往往还没被
   runtime 注册(要等展开过第一次), 于是 textHooked 永远是 NO, 之后再也不会重试。
   333 日志里一条 text 都没有, 就是这个原因。 */
static void diActivityInstallTextHook(void) {
    static BOOL hooked;
    if (hooked) return;
    Class vcCls = NSClassFromString(@"MRUActivityNowPlayingViewController");
    if (!vcCls) return;                 /* 类还没加载, 下一轮心跳再来 */
    SEL sel = @selector(viewDidLayoutSubviews);
    if (!class_getInstanceMethod(vcCls, sel)) return;
    MSHookMessageEx(vcCls, sel, (IMP)diActivityTextLayout, &gDIActivityOrigTextLayout);
    hooked = YES;
    diMruFileLog([NSString stringWithFormat:@"text hook 已装 %@ (orig=%@)",
        NSStringFromClass(vcCls), gDIActivityOrigTextLayout ? @"有" : @"无"]);
}

static void diActivityReload(void) {
    gDIActivityEnabled = diMruPrefOn();
    logEnabled = pBool(@"logging", NO);
    gMaskGen++;
    gDIActivityShape = gDIActivityEnabled ? diActivityLoadShape() : nil;
    diMruReport(@"reload", [NSString stringWithFormat:@"v%@ 开关=%d 形状=%@", DI_BUILD_VER,
        gDIActivityEnabled, gDIActivityShape ? [NSString stringWithFormat:@"%.0fx%.0f",
        gDIActivityShape.size.width, gDIActivityShape.size.height] : @"(无)"]);
    for (UIView *view in gDIActivityArtworks.allObjects) diActivityApply(view);
}
static void diActivityNotify(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        diActivityReload();
        /* 2.8.78: SpringBoard 的素材导出是异步的, 通知到达时可能还没写完 —— 1.5s 后补一次 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ diActivityReload(); });
    });
}
static void diActivityRegister(UIView *view) {
    if (!gDIActivityArtworks) gDIActivityArtworks = [NSHashTable weakObjectsHashTable];
    [gDIActivityArtworks addObject:view];
    diActivityApply(view);
}
static void diActivityLayout(id self, SEL cmd) {
    if (gDIActivityOrigLayout) ((void (*)(id, SEL))gDIActivityOrigLayout)(self, cmd);
    @try { diActivityRegister((UIView *)self); } @catch (NSException *e) { DLog(@"[真实专辑遮罩] 布局异常 %@", e.reason); }
    /* 2.8.86: 展开岛自己每次布局都补一次文字位置 —— 系统重排会把我们改过的
       center/transform 覆盖回去, 只在 1 秒心跳里改会出现"动一下就弹回"。 */
    @try {
        static CFAbsoluteTime tText;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - tText > 0.3) {
            UIViewController *vc = diActivityAncestorVC((UIView *)self);
            if (vc && vc.isViewLoaded) { tText = now; diActivityTextApply(vc.view); }
        }
    } @catch (__unused NSException *e) {}
}
static void diActivityMove(id self, SEL cmd) {
    if (gDIActivityOrigMove) ((void (*)(id, SEL))gDIActivityOrigMove)(self, cmd);
    @try { diActivityRegister((UIView *)self); } @catch (NSException *e) { DLog(@"[真实专辑遮罩] 挂载异常 %@", e.reason); }
}
static void diActivityVisibility(id self, SEL cmd) {
    if (gDIActivityOrigVisibility) ((void (*)(id, SEL))gDIActivityOrigVisibility)(self, cmd);
    @try { diActivityRegister((UIView *)self); } @catch (NSException *e) { DLog(@"[真实专辑遮罩] 显隐异常 %@", e.reason); }
}
/* 2.8.78: N95 也 hook 了 init(0x14608), 展开时新建的实例在 didMove 之前就能挂上,
   少一次"方形先露出"的窗口。原 init 必须先调用完再挂 mask。 */
static id diActivityInit(id self, SEL cmd) {
    id result = gDIActivityOrigInit ? ((id (*)(id, SEL))gDIActivityOrigInit)(self, cmd) : nil;
    @try { diActivityApply((UIView *)self); } @catch (__unused NSException *e) {}
    return result;
}
static BOOL diActivityVoidMethod(Class cls, SEL sel) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = type && !strcmp(type, "v"); free(type); return valid;
}
static BOOL diActivityObjectMethod(Class cls, SEL sel) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = type && !strcmp(type, "@"); free(type); return valid;
}
/* 2.8.81: iOS 17/18 的展开岛专辑**不是** MRUActivityArtworkView。
   依据 iOS 18.2 MediaControls 反编译(MRUActivityNowPlayingView.m):
     展开岛根视图 = MRUActivityNowPlayingView, 它的 artworkViews 是
     **两个 MRUFlippingArtworkView**(style=7, dimsWhenPaused=1),
     专辑位图由 MRUFlippingArtworkLayer 绘制;
   而 MRUActivityArtworkView 是 Live Activity 专用 —— 它在 init 里直接把
   artworkImageView / placeholderBackground 从父视图移除, 换成 CCUICAPackageView,
   在音乐展开岛里根本不会出现。
   这就是 2.8.77~2.8.80 "注入了、有 reload、却一条接管记录都没有" 的真正原因:
   hook 的目标类从 iOS 17 起就换人了(N95 只支持到 16.7.7, 所以它那套类名是对的)。 */
static NSArray<NSString *> *diActivityClassNames(void) {
    return @[@"MRUFlippingArtworkView", @"MRUActivityArtworkView", @"MRUArtworkView"];
}
static BOOL diActivityIsArtworkClass(UIView *view) {
    for (NSString *name in diActivityClassNames()) {
        Class c = NSClassFromString(name);
        if (c && [view isKindOfClass:c]) return YES;
    }
    return NO;
}
static IMP gDIActivityOrigSetImage;
static void diActivitySetImage(id self, SEL cmd, id img) {
    if (gDIActivityOrigSetImage) ((void (*)(id, SEL, id))gDIActivityOrigSetImage)(self, cmd, img);
    @try { diActivityApply((UIView *)self); } @catch (__unused NSException *e) {}
}
static void diActivityInstall(void) {
    static BOOL installed;
    /* 2.8.86: 文字 hook 放在最前面且可重试(不受 installed 影响) */
    diActivityInstallTextHook();
    if (installed) return;
    /* 2.8.82: 只 hook 一个类(按优先级取第一个存在的)。
       之前把三个类都挂到同一组 IMP 变量上 —— MSHookMessageEx 会覆盖同一个
       *result, 三个类同时存在时 orig 指向最后一个类, 转调就是错的/会递归。
       现在主类 hook(顺带拿到 setArtworkImage: 实时换图), 其余类靠扫描器接管。 */
    Class cls = nil; NSString *hitName = nil;
    for (NSString *name in diActivityClassNames()) {
        Class c = NSClassFromString(name);
        if ([c isSubclassOfClass:UIView.class] && diActivityVoidMethod(c, @selector(layoutSubviews))) { cls = c; hitName = name; break; }
    }
    if (!cls) {
        diMruReport(@"noclass", @"三个候选类都不存在");
        diMruPostPayload(@"install.end", @"hooked0");
        diMruFileLog(@"install 失败: 三个候选类都不存在");
        return;
    }
    MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)diActivityLayout, &gDIActivityOrigLayout);
    SEL move = @selector(didMoveToSuperview);
    if (diActivityVoidMethod(cls, move)) MSHookMessageEx(cls, move, (IMP)diActivityMove, &gDIActivityOrigMove);
    SEL visibility = NSSelectorFromString(@"updateVisibility");
    if (diActivityVoidMethod(cls, visibility)) MSHookMessageEx(cls, visibility, (IMP)diActivityVisibility, &gDIActivityOrigVisibility);
    SEL initSel = @selector(init);
    if (diActivityObjectMethod(cls, initSel)) MSHookMessageEx(cls, initSel, (IMP)diActivityInit, &gDIActivityOrigInit);
    SEL setImg = NSSelectorFromString(@"setArtworkImage:");
    if (class_getInstanceMethod(cls, setImg)) MSHookMessageEx(cls, setImg, (IMP)diActivitySetImage, &gDIActivityOrigSetImage);
    installed = YES;
    RLog(@"[真实专辑遮罩] 已安装 MediaRemoteUI hook: %@ (换图hook=%@)", hitName,
         gDIActivityOrigSetImage ? @"有" : @"无");
    diMruReport(@"install", hitName);
    diMruFileLog([NSString stringWithFormat:@"install %@ layout=%d move=%d vis=%d init=%d setImage=%d",
        hitName, gDIActivityOrigLayout != NULL, gDIActivityOrigMove != NULL,
        gDIActivityOrigVisibility != NULL, gDIActivityOrigInit != NULL, gDIActivityOrigSetImage != NULL]);
    // Register existing artwork views if the framework was already displaying them.
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
            for (NSUInteger n = 0; stack.count && n < 1500; n++) {
                UIView *view = stack.lastObject; [stack removeLastObject];
                if (diActivityIsArtworkClass(view)) diActivityRegister(view);
                for (UIView *child in view.subviews) [stack addObject:child];
            }
        }
    }
}
/* ===== 2.8.80: 不依赖 hook 的兜底通道 =====
   326 日志给出的结论: MediaRemoteUI **确实注入了**(收到了它发来的 reload 回传),
   但既没有 install 回传、也没有任何 apply —— 卡在"装 hook"这一环, 而不是素材/开关。
   于是补一条完全不依赖 hook 的路径: 定时扫本进程的窗口树, 按类名 + 尺寸认专辑视图,
   认到就直接挂 maskView。hook 装得上就更快, 装不上也照样裁。
   顺带把"扫到几个窗口/多少节点/命中几次"回传, 下一次日志能直接看到扫没扫到。 */
static NSTimer *gDIActivityScanTimer;
static void diActivityScanTree(UIView *root, NSUInteger *nodes, NSUInteger *matched) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger budget = 2500;
    while (stack.count && budget--) {
        UIView *view = stack.lastObject; [stack removeLastObject];
        (*nodes)++;
        BOOL match = diActivityIsArtworkClass(view);
        if (!match) {
            /* 三个候选类都不存在时的兜底: 按类名认(只认带 Artwork 的) */
            NSString *cn = NSStringFromClass(view.class);
            match = [cn containsString:@"Artwork"];
        }
        if (match && view.bounds.size.width >= 30 && view.bounds.size.height >= 30) {
            (*matched)++;
            diActivityRegister(view);   /* 里面会再走一遍上下文校验并挂 mask */
        }
        for (UIView *child in view.subviews) [stack addObject:child];
    }
}
static void diActivityScan(void) {
    /* 2.8.86: 心跳里补装文字 hook —— 展开过一次之后类才注册, 必须能重试 */
    @try { diActivityInstallTextHook(); } @catch (__unused NSException *e) {}
    /* 2.8.81: 心跳不再被开关/素材挡在前面 —— 之前"没遮上"和"根本没跑"在日志里长得一模一样 */
    NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
    @try {
        UIApplication *app = UIApplication.sharedApplication;
        for (UIScene *scene in app.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) [wins addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [wins addObjectsFromArray:app.windows];
#pragma clang diagnostic pop
    } @catch (__unused NSException *e) {}
    NSUInteger nodes = 0, matched = 0;
    if (gDIActivityShape) {
        for (UIWindow *w in wins) diActivityScanTree(w, &nodes, &matched);
    }
    static CFAbsoluteTime lastReport;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    /* 2.8.85: 展开定义兜底 —— layout hook 没装上/漏帧时, 每秒补一次 */
    @try {
        if (gDIActivityArtworks) {
            for (UIView *art in gDIActivityArtworks.allObjects) {
                UIViewController *vc = diActivityAncestorVC(art);
                if (vc && vc.isViewLoaded
                    && [NSStringFromClass(vc.class) containsString:@"NowPlaying"]) {
                    diActivityHideRoute(vc.view);
                    diActivityTextApply(vc.view);
                    break;
                }
            }
        }
    } @catch (__unused NSException *e) {}
    /* ===== 2.9.61: 收缩清理兜底 —— 岛收回后那颗 66 大头像常常不再被 layout,
       它自己的 apply 不会跑, 玻璃就一直留在原地(用户: "缩回来就变大")。
       文件明确说"小岛"(formNow==1, 已经过可见性过滤)时, 由 1 秒一拍的扫描器
       强制拆掉所有大头像上的玻璃。真展开时文件说"展开", 不进这条。 */
    @try {
        if (diIsIOS17Up() && diMruFormFromIsland() == 1 && gDIActivityArtworks) {
            for (UIView *a in gDIActivityArtworks.allObjects) {
                if (![a isKindOfClass:UIView.class] || !a.window) continue;
                CGFloat side = MIN(a.bounds.size.width, a.bounds.size.height);
                if (side <= 30.0) continue;   /* 23 那颗收缩头像的玻璃不动 */
                DIActivityMaskState *st = objc_getAssociatedObject(a, &kDIActivityMaskState);
                if (st) diActivityTeardown(a, st);
            }
        }
    } @catch (__unused NSException *e) {}
    /* 2.8.86: 一个活着的头像都没有(音乐停了/岛收了) → 明确告诉 SpringBoard"非展开",
       否则 state.plist 会一直停在 expanded=1, 小岛回来时那 4 秒没有遮罩。 */
    {
        BOOL anyLive = NO;
        for (UIView *a in gDIActivityArtworks.allObjects) if (a.window) { anyLive = YES; break; }
        if (anyLive) {
            /* 2.9.61: 文件明确说收缩时不再给旧 YES 续期 —— 否则展开标志一直停 1,
               SB 16 侧玻璃被压住(17 侧已不读这个标志)。 */
            if (diIsIOS17Up() && gDIMruExpandedFlag && diMruFormFromIsland() == 1)
                diMruWriteExpandState(NO, CGSizeZero);
            else
                diMruWriteExpandState(gDIMruExpandedFlag, gDIMruLastBox);
        }
        else diMruWriteExpandState(NO, CGSizeZero);
    }
    if (now - lastReport > 5.0) {
        lastReport = now;
        diMruPostPayload(@"hb", [NSString stringWithFormat:@"on%d_shape%d_win%lu_nodes%lu_match%lu_hit%d",
            gDIActivityEnabled, gDIActivityShape != nil, (unsigned long)wins.count,
            (unsigned long)nodes, (unsigned long)matched, gDIActivityHit]);
    }
}
static void diActivityStartScanner(void) {
    static BOOL started;
    if (started) return;
    started = YES;
    gDIActivityScanTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        @try { diActivityScan(); } @catch (__unused NSException *e) {}
    }];
    [NSRunLoop.mainRunLoop addTimer:gDIActivityScanTimer forMode:NSRunLoopCommonModes];
}
/* ===== 2.9.70: 形态变化即时触发扫描 =====
   兜底扫描是 1 秒一拍, 而小岛↔展开的动画只有 0.3~0.4 秒 —— 400 日志里
   "第一次展开"从小岛(23 小圆)切到展开(66)整整差了 2 秒, 用户看到的就是
   "展开先显示一下小专辑, 一会儿才变正常"; 收缩方向同理, 小岛头像已经回来了
   但玻璃还在按上一拍的位置画, 看着像"从别的地方显示再回原位"。
   这里加一个 0.1 秒的轻量监听: 只读 island.plist(几百字节, 不做全树遍历),
   形态位翻转或尺寸跳变 >40pt 时才真正跑一次完整扫描(0.08 秒节流)。
   平时零布局遍历, 开销可以忽略。 */
static void diActivityStartFormWatch(void) {
    static BOOL started;
    if (started) return;
    started = YES;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                              (int64_t)(0.1 * NSEC_PER_SEC), (int64_t)(0.02 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, ^{ @autoreleasepool {
        static int lf = -9; static CGFloat lw, lh; static CFAbsoluteTime ls;
        NSString *dir = diMruSelfDir();
        if (!dir.length) return;
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                           [dir stringByAppendingPathComponent:@"island.plist"]];
        if (![d isKindOfClass:NSDictionary.class]) return;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        double ts = [d[@"t"] doubleValue];
        CGFloat w = [d[@"w"] doubleValue], h = [d[@"h"] doubleValue];
        if (w < 1.0 || h < 1.0 || fabs(now - ts) > 3.0) return;
        int f = [d[@"expand"] boolValue] ? 2 : ([d[@"mini"] boolValue] ? 1 : 0);
        BOOL flip = (f != lf && f > 0 && lf > 0);
        BOOL jump = (lw > 1.0 && lh > 1.0
                     && (fabs(w - lw) > 40.0 || fabs(h - lh) > 40.0));
        BOOL fire = ((flip || jump) && now - ls > 0.08);
        lf = f; lw = w; lh = h;
        if (fire) {
            ls = now;
            @try { diActivityScan(); } @catch (__unused NSException *e) {}
        }
    }});
    dispatch_resume(t);
}
static void diActivityStart(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        diMruPostPayload(@"start", @"enter");
        @try { diActivityReload(); } @catch (__unused NSException *e) {
            diMruPostPayload(@"err.reload", e.reason ?: e.name);
        }
        @try { diActivityInstall(); } @catch (__unused NSException *e) {
            diMruPostPayload(@"err.install", e.reason ?: e.name);
        }
        diActivityStartScanner();
        diActivityStartFormWatch();
        diMruPostPayload(@"start", [NSString stringWithFormat:@"done_hook%d", (int)(gDIActivityOrigLayout != NULL)]);
        for (NSString *notification in @[kNotifyStr, @"com.abgg332.driftisland/prefsChanged"]) {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                diActivityNotify, (__bridge CFStringRef)notification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }
        /* 2.8.79: 拉长重试窗口 —— 目标类可能直到"第一次展开音乐岛"才被 dyld 载入,
           原 60 秒窗口在"锁屏放着音乐很久才展开"的场景会漏装。 */
        for (int seconds : {1, 3, 8, 20, 60, 120, 240, 480}) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC),
                /* 2.8.78: 同时重读素材 —— MediaRemoteUI 启动往往早于 SpringBoard 导出素材,
                   只 install 不 reload 会一直拿着空形状("没遮上"的另一种成因)。 */
                dispatch_get_main_queue(), ^{
                    diActivityReload(); diActivityInstall();
                    /* 2.8.79: 一直没接管成功, 就把本进程真实类名回传(两次机会, 类可能晚加载) */
                    if ((seconds == 20 || seconds == 120) && gDIActivityHit == 0) diMruDumpClasses();
                });
        }
    });
}

/* 2.8.5: 取进程名(版本日志用)。bundleIdentifier 为空时退回进程名。 */
static NSString *diProcName(void) {
    static NSString *n;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            NSString *bid = NSBundle.mainBundle.bundleIdentifier;
            if (bid.length) { n = bid; return; }
            NSString *exe = NSProcessInfo.processInfo.processName;
            if (exe.length) { n = exe; return; }
        } @catch (__unused NSException *e) {}
        if (!n) n = @"?";
    });
    return n;
}

/* 2.8.78: MediaRemoteUI 侧打点的接收端 —— 达林通知不支持前缀匹配, 固定名字逐个注册。
   325 日志里 MediaRemoteUI 一条记录都没有, 有了这组回传就能区分:
   有 install → 注入成功; 有 install 没 apply → 卡在素材/上下文; 什么都没有 → 没注入。 */
static void diMruPing(CFNotificationCenterRef c, void *o, CFStringRef name, const void *obj, CFDictionaryRef info) {
    NSString *n = (__bridge NSString *)name;
    NSString *prefix = @"com.abgg332.driftisland.mru.";
    NSString *tag = [n hasPrefix:prefix] ? [n substringFromIndex:prefix.length] : n;
    RLog(@"[MRU回传] %@", tag);
}
/* 2.8.79: 带载荷的回传(名字 = 前缀 + tag + "." + 载荷) */
static void diMruAny(CFNotificationCenterRef c, void *o, CFStringRef name, const void *obj, CFDictionaryRef info) {
    NSString *n = (__bridge NSString *)(name ?: CFSTR(""));
    NSString *prefix = @"com.abgg332.driftisland.mru.";
    if (![n hasPrefix:prefix]) return;
    RLog(@"[MRU回传·载荷] %@", [n substringFromIndex:prefix.length]);
}
static void diMruObserve(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        /* 2.8.79: 载荷通道 —— 名字里带祖先类名/类枚举, 用 NULL 名观察者全收, 只认本插件前缀 */
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, diMruAny,
            NULL, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        NSArray<NSString *> *tags = @[@"install", @"noclass", @"nohook", @"reload",
            @"shape.material", @"shape.cache", @"shape.prefs", @"shape.none",
            @"ctxreject", @"ctxrelaxed", @"hit", @"apply"];
        for (NSString *t in tags) {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, diMruPing,
                (__bridge CFStringRef)[@"com.abgg332.driftisland.mru." stringByAppendingString:t], NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    });
}

/* ===== 2.8.82: MRU 进程日志回读 =====
   MediaRemoteUI 是沙盒进程: 写不进我们的日志, 也读不到我们的文件; 但它能写**自己的容器**,
   SpringBoard 能读它的容器。于是它把日志写到 <自己Caches>/com.abgg332.driftisland/mru.log,
   这里按偏移量把新增行搬进主日志 —— 从此诊断不靠"通知名里塞载荷"这种不可靠通道。 */
static void diMruTailTick(void) {
    static unsigned long long offset;
    NSString *p = [diMruSharedDir() stringByAppendingPathComponent:@"mru.log"];
    if (!p.length) return;
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL];
    unsigned long long size = [attr[NSFileSize] unsignedLongLongValue];
    if (!size) return;
    if (size < offset) offset = 0;
    if (size == offset) return;
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:p];
    if (!h) return;
    @try {
        [h seekToFileOffset:offset];
        NSData *d = [h readDataToEndOfFile];
        offset += d.length;
        NSString *text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        for (NSString *line in [text componentsSeparatedByString:@"\n"])
            if (line.length) RLog(@"[MRU] %@", line);
    } @catch (__unused NSException *e) {} @finally { [h closeFile]; }
}
static void diMruTailInstall(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    NSTimer *t = [NSTimer timerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
        @try { diMruTailTick(); } @catch (__unused NSException *e) {}
    }];
    [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
    diMruTailTick();
}
/* ============ 3.0.3: 内置播放器(NativePlayerOriginal)接入自检 ============
   症状: 设置里改尺寸/开关都写进去了, 桌面一点变化都没有, 也不崩。
   根因: 播放器构造函数里有一道硬门槛(反编译 0.3.20 启动段确认):
        Enabled 必须是 NSNumber 且为 true,
        并且 ActivationVersion 必须字符串等于 "0.3.1";
   两道门槛任一不过就直接 return —— 一个 hook 都不装, 所以表现成"设置无效"。
   原版设置面板拨开关时会把这两个键一起写, 我们复刻的面板只写了 Enabled,
   ActivationVersion 从来没写过 → 播放器永远停在门外。
   这里在 SpringBoard 里: ①补写激活键(仅当用户没显式关闭) ②确认 dylib 是否真的注入,
   必要时按本 dylib 所在目录手动 dlopen, 结果全部写进主日志。 */
static NSString *const kNPPlayerDomain = @"com.local.playerexact";
static NSString *const kNPActivationVer = @"0.3.1";

static BOOL diNPImageLoaded(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "NativePlayerOriginal")) return YES;
    }
    return NO;
}

static void diNPHealPrefs(void) {
    CFStringRef dom = (__bridge CFStringRef)kNPPlayerDomain;
    CFPreferencesAppSynchronize(dom);
    NSNumber *en = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("Enabled"), dom));
    NSString *av = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("ActivationVersion"), dom));
    if (![av isKindOfClass:NSString.class]) av = nil;
    BOOL keyExists = [en isKindOfClass:NSNumber.class];
    BOOL on = keyExists ? en.boolValue : YES;   /* 键缺失=新装, 与设置页默认(开)保持一致 */
    if (!on) {
        RLog(@"[播放器] 总开关是关的(用户手动关过), 不补写激活键");
        return;
    }
    if (!keyExists || ![av isEqualToString:kNPActivationVer]) {
        CFPreferencesSetAppValue(CFSTR("Enabled"), kCFBooleanTrue, dom);
        CFPreferencesSetAppValue(CFSTR("ActivationVersion"), (__bridge CFPropertyListRef)kNPActivationVer, dom);
        CFPreferencesSetAppValue(CFSTR("StartupPendingVersion"), NULL, dom);
        CFPreferencesSetAppValue(CFSTR("StartupPendingToken"), NULL, dom);
        CFPreferencesAppSynchronize(dom);
        RLog(@"[播放器] 已补写激活键: Enabled=true ActivationVersion=%@ (原 Enabled=%@ 原 ActivationVersion=%@)",
             kNPActivationVer, en ?: @"(无)", av ?: @"(无)");
    } else {
        RLog(@"[播放器] 激活键正常: Enabled=true ActivationVersion=%@", av);
    }
}

static void diNPProbe(void) {
    if (diNPImageLoaded()) {
        RLog(@"[播放器] NativePlayerOriginal 已被注入本进程");
        return;
    }
    /* 没注入: 先按本 dylib 所在目录找, 再退回两种常见布局, 手动 dlopen 并把失败原因打出来 */
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    Dl_info info;
    if (dladdr((void *)&diNPProbe, &info) && info.dli_fname) {
        NSString *self0 = [NSString stringWithUTF8String:info.dli_fname];
        NSString *dir = [self0 stringByDeletingLastPathComponent];
        if (dir.length) [cands addObject:[dir stringByAppendingPathComponent:@"NativePlayerOriginal.dylib"]];
    }
    [cands addObject:@"/var/jb/Library/MobileSubstrate/DynamicLibraries/NativePlayerOriginal.dylib"];
    [cands addObject:@"/Library/MobileSubstrate/DynamicLibraries/NativePlayerOriginal.dylib"];
    for (NSString *p in cands) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
            RLog(@"[播放器] 候选路径不存在: %@", p);
            continue;
        }
        void *h = dlopen(p.UTF8String, RTLD_NOW);
        if (h) {
            RLog(@"[播放器] 手动 dlopen 成功: %@", p);
            return;
        }
        const char *err = dlerror();
        RLog(@"[播放器] dlopen 失败: %@ → %s", p, err ? err : "(无错误信息)");
    }
}

/* ============ 3.0.4: 播放器"到底走到哪一步"全链路诊断 ============
   3.0.3 的日志证明: 激活键对、主 dylib 也注入了, 但设置照样无效 —— 说明它卡在
   启动函数的后半段(runtime 校验 / hook 安装)。这几条日志一次把下列事实全部量化:
     ① Runtime/Layout 到底有没有被它 dlopen 上(镜像表);
     ② 我们按它的路径手动 dlopen 时能不能成功, 失败原因是什么;
     ③ 它该 hook 的那几个方法, IMP 现在指向系统镜像还是已被替换(判断 hook 装没装);
     ④ 整个偏好域的内容(看它有没有写 StartupPending, 即启动跑到哪一步)。 */
static NSString *diNPAppSupportDir(void) {
    Dl_info info;
    if (!dladdr((void *)&diNPProbe, &info) || !info.dli_fname) return nil;
    NSString *p = [NSString stringWithUTF8String:info.dli_fname];
    /* <root>/Library/MobileSubstrate/DynamicLibraries/xxx.dylib → 删 4 层回到 <root> */
    for (int i = 0; i < 4; i++) p = [p stringByDeletingLastPathComponent];
    if (!p.length) return nil;
    return [p stringByAppendingPathComponent:@"Library/Application Support/NativePlayerOriginal"];
}

static void diNPImages(void) {
    uint32_t n = _dyld_image_count();
    NSMutableArray *hit = [NSMutableArray array];
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && (strstr(nm, "NPROriginal") || strstr(nm, "NativePlayerOriginal")))
            [hit addObject:[NSString stringWithUTF8String:nm]];
    }
    RLog(@"[播放器][诊断] 已加载播放器镜像 %lu 个: %@", (unsigned long)hit.count,
         hit.count ? [hit componentsJoinedByString:@" | "] : @"无");
}

static void diNPProbeRuntime(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = diNPAppSupportDir();
    BOOL exist = dir && [fm fileExistsAtPath:dir];
    RLog(@"[播放器][诊断] 资源目录=%@ 存在=%@", dir ?: @"(nil)", exist ? @"是" : @"否");
    if (!exist) {
        RLog(@"[播放器][诊断] 资源目录不存在, 播放器必定在 dlopen 这一步失败");
        return;
    }
    NSArray *fs = [fm contentsOfDirectoryAtPath:dir error:NULL];
    RLog(@"[播放器][诊断] 目录内容=%@", [fs componentsJoinedByString:@","] ?: @"(空)");
    for (NSString *fn in @[ @"NPROriginalRuntime.dylib", @"NPROriginalRuntime3x2B.dylib",
                            @"NPROriginalLayout.dylib", @"NPROriginalLayout3x2B.dylib" ]) {
        NSString *full = [dir stringByAppendingPathComponent:fn];
        void *h = dlopen(full.UTF8String, RTLD_NOW);
        if (!h) {
            const char *e = dlerror();
            RLog(@"[播放器][诊断] dlopen %@ 失败: %s", fn, e ? e : "(无错误信息)");
            continue;
        }
        void *s1 = dlsym(h, "CCFAllowedSizesForModuleIdentifier");
        void *s2 = dlsym(h, "EVOPref");
        RLog(@"[播放器][诊断] dlopen %@ 成功 CCFAllowedSizes=%p EVOPref=%p", fn, s1, s2);
    }
}

/* 判断它的 hook 装没装: 没装 = IMP 还在系统镜像里; 装了 = IMP 会被换成不在任何镜像里的蹦床。
   返回值 = 已确认被替换的方法数(0 = 播放器一个 hook 都没装上)。 */
static int diNPHookCheck(void) {
    int hooked = 0;
    NSArray *pairs = @[ @[@"MRUNowPlayingViewController", @"layoutSubviews"],
                        @[@"MRUControlCenterViewController", @"layoutSubviews"],
                        @[@"MRUNowPlayingView", @"layoutSubviews"],
                        @[@"CCUIModuleCollectionViewController", @"willOpenExpandedModule:"] ];
    for (NSArray *p in pairs) {
        NSString *cn = p[0], *sn = p[1];
        Class c = NSClassFromString(cn);
        if (!c) { RLog(@"[播放器][hook] 类 %@ 不存在", cn); continue; }
        Method m = class_getInstanceMethod(c, NSSelectorFromString(sn));
        if (!m) { RLog(@"[播放器][hook] %@ 无方法 %@", cn, sn); continue; }
        IMP imp = method_getImplementation(m);
        Dl_info di;
        const char *img = "";
        if (dladdr((void *)imp, &di) && di.dli_fname) img = di.dli_fname;
        BOOL sys = (strstr(img, "/System/") != NULL) || (strstr(img, "SpringBoard.app") != NULL);
        if (!sys) hooked++;
        RLog(@"[播放器][hook] %@ %@ → %s%s", cn, sn, img[0] ? img : "(无镜像)",
             sys ? "" : " [已替换]");
    }
    return hooked;
}

static void diNPDumpDomain(void) {
    CFStringRef dom = CFSTR("com.local.playerexact");
    CFPreferencesAppSynchronize(dom);
    NSArray *keys = CFBridgingRelease(CFPreferencesCopyKeyList(dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    if (!keys.count) { RLog(@"[播放器][域] 空"); return; }
    RLog(@"[播放器][域] 共 %lu 个键", (unsigned long)keys.count);
    for (NSString *k in keys) {
        if (![k isKindOfClass:NSString.class]) continue;
        id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)k, dom));
        RLog(@"[播放器][域] %@ = %@", k, v ?: @"(nil)");
    }
}

/* ================= 3.0.6: 播放器封面「圆角头像」+ 3×2 按钮抖动 =================
   用户给的「音乐旋转」tweak(cn.zqbb.musicrotation) 整包只有 6 个 selector:
       layoutSubviews / bounds / bezierPathWithOvalInRect: / layer / CGPath
       setPath: / setMask: / animationForKey: / animationWithKeyPath: …
   它做的事就两件:
       ① layoutSubviews 里把封面的 layer.mask 换成"内切圆"的 CAShapeLayer;
       ② 同一层加一条 0→2π 的无限旋转动画(setRepeatCount/setFillMode:forwards)。
   这里按同样做法并进本 tweak —— 不再依赖那个 dylib 的 arm64e 架构和加载时机:
       · 目标 = 控制中心播放器 MRUNowPlayingView 里的封面(类名含 Artwork);
       · 开关 = com.local.playerexact / ArtworkRotationEnabled(面板同一个键);
       · 关掉时立刻摘蒙版(旋转由内置播放器按同一个键控制, 不重复加动画)。
   3×2 的按钮抖动: 内置播放器的旋转装配会对播放器子视图逐个挂动画, 3×2 布局下
   上/下一首和播放键的图层也会被带上, 每来一次 layout 就重新从 0 开始 → 看起来
   一抖一抖。这里在播放器 layout 之后把"传送按钮上的循环/自动往返动画"摘掉,
   只动按钮, 不碰封面。 */
@interface DIArtMaskState : NSObject
@property (nonatomic, strong) CAShapeLayer *mask;
@property (nonatomic, strong) CALayer *origMask;   /* 必须强引用: 换掉后系统层没人持有, 弱引用会变 nil 还原不回去 */
@property (nonatomic, assign) CGFloat origRadius;
@property (nonatomic, assign) BOOL origClip;
@property (nonatomic, assign) CATransform3D origTransform;
@property (nonatomic, assign) CGPoint origAnchor;      /* 3.0.19: 原始锚点(不居中会"绕外围转") */
@property (nonatomic, assign) CGSize lastSize;
@property (nonatomic, assign) CFTimeInterval spinTS;   /* 3.0.15: 旋转起始时刻, 重挂时按相位续上 */
@end
@implementation DIArtMaskState
@end

/* 每个播放器根视图的扫描缓存: CC 的 view 树很大, 不能每次 layout 都全量扫 */
@interface DIArtRootState : NSObject
@property (nonatomic, strong) NSArray<UIView *> *arts;
@property (nonatomic, assign) CFTimeInterval scanTS;
@property (nonatomic, assign) int recollects;   /* 3.0.13: 延迟二次收集的链式次数上限 */
@end
@implementation DIArtRootState
@end

static const void *kDIArtStateKey = &kDIArtStateKey;
static const void *kDIArtRootKey = &kDIArtRootKey;
static const void *kDIJitterFrameKey = &kDIJitterFrameKey;
static BOOL gDIArtOn = NO;
static CFTimeInterval gDIArtPrefTS = 0;
static BOOL gDIArtTreeLogged = NO;
static BOOL gDIArtHooked = NO;
static NSString *gDIArtLastDesc = nil;
static NSHashTable *gDIArtRoots = nil;
static void (*gDIArtOrigNPViewLayout)(id, SEL) = NULL;
static void (*gDIArtOrigCCVCLayout)(id, SEL) = NULL;

/* ===== 3.0.20(iOS17 卡死主修之二) =====
   3.0.7 起 diArtPrefOn 每次刷新都在**主线程**上
       CFPreferencesAppSynchronize(CFSTR("com.local.playerexact"))
   那是内置播放器(另一个进程)的域。用户在设置里连续拨开关时, 设置进程正在高频写这个
   域, cfprefsd 一侧就要排它锁 —— SpringBoard 主线程被按住几十秒, watchdog 直接注销。
   432 日志里两个 33 秒 / 66 秒的大空洞都发生在这条路径上。
   现在: 主线程只读内存缓存(纳秒级), 真正的 Synchronize 丢到后台串行队列去做, 1.2 秒
   最多一次; 开关变化本身还有 artwork-changed 通知会立刻触发一次后台刷新, 所以体感
   还是"一拨就变"。 */
static dispatch_queue_t diPrefQ(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.abgg332.driftisland.prefread", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(q, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return q;
}
static void diArtPrefReadNow(void) {
    @autoreleasepool {
        @try {
            CFPreferencesAppSynchronize(CFSTR("com.local.playerexact"));
            id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("ArtworkRotationEnabled"),
                                                              CFSTR("com.local.playerexact")));
            BOOL on = [v isKindOfClass:NSNumber.class] ? [v boolValue] : NO;
            if (on != gDIArtOn) {
                gDIArtOn = on;
                RLog(@"[封面] 开关 → %d", on);
            }
        } @catch (__unused NSException *e) {}
    }
}
static BOOL diArtPrefOn(void) {
    /* 只在主线程用; 返回缓存值, 顺带把刷新排进后台 */
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gDIArtPrefTS > 1.2) {
        gDIArtPrefTS = now;
        dispatch_async(diPrefQ(), ^{ diArtPrefReadNow(); });
    }
    return gDIArtOn;
}
static void diArtForceRefresh(void) {
    /* 已经在后台队列上调用(见 diArtChanged); 这里同步读一次, 保证紧接着的判断是新的 */
    gDIArtPrefTS = CFAbsoluteTimeGetCurrent();
    diArtPrefReadNow();
}

/* 内置播放器自己的旋转开关(导出 C++ 符号)。它的 flag 一旦为 1, 每次 update 都会给
   封面挂旋转动画, 我们写的偏好键它根本不看 —— 所以这里直接调它的 setter 关掉,
   旋转完全由本 tweak 负责, 开关才能真正控制"转 / 不转"。 */
static void (*gNPRSetRotation)(BOOL) = NULL;
static BOOL gNPRLooked = NO;
static void diArtDisableNPRSpin(void) {
    if (!gNPRLooked) {
        gNPRLooked = YES;
        void *h = dlopen(NULL, RTLD_NOW);
        gNPRSetRotation = (void (*)(BOOL))dlsym(h, "__Z28NPRSetArtworkRotationEnabledb");
        if (!gNPRSetRotation) gNPRSetRotation = (void (*)(BOOL))dlsym(h, "_Z28NPRSetArtworkRotationEnabledb");
        if (!gNPRSetRotation) {
            /* 播放器若是 RTLD_LOCAL 注入的, RTLD_DEFAULT 搜不到 —— 按镜像名再拿一次 handle */
            const char *found = NULL;
            for (int i = 0; i < _dyld_image_count(); i++) {
                const char *nm = _dyld_get_image_name(i);
                if (nm && strstr(nm, "NativePlayerOriginal")) { found = nm; break; }
            }
            if (found) {
                void *ph = dlopen(found, RTLD_NOW | RTLD_NOLOAD);
                if (ph) {
                    gNPRSetRotation = (void (*)(BOOL))dlsym(ph, "__Z28NPRSetArtworkRotationEnabledb");
                    if (!gNPRSetRotation)
                        gNPRSetRotation = (void (*)(BOOL))dlsym(ph, "_Z28NPRSetArtworkRotationEnabledb");
                }
                RLog(@"[封面] 播放器镜像 %s → 旋转开关 %@", found, gNPRSetRotation ? @"已接管" : @"未导出");
            }
        }
        if (!gNPRSetRotation) RLog(@"[封面] 播放器内置旋转开关未导出, 退化为逐帧清理动画");
    }
    if (gNPRSetRotation) {
        @try { gNPRSetRotation(NO); } @catch (__unused NSException *e) {}
    }
}

/* 递归摘掉图层树上的旋转/循环动画 —— 播放器的旋转不一定挂在封面自身,
   常常挂在里面那层 imageView 上, 只查 view.layer 会漏。 */
static void diArtStripSpin(CALayer *layer, int depth, int maxDepth) {
    if (!layer || depth > maxDepth) return;
    NSArray<NSString *> *keys = [layer.animationKeys copy];
    for (NSString *k in keys) {
        if ([k isEqualToString:@"di.art.spin"]) continue;   /* 3.0.14: 自己的旋转不清 */
        CAAnimation *a = [layer animationForKey:k];
        if (!a) continue;
        /* 3.0.19: 旧实现顺带把 repeatCount/autoreverses 的动画也清了 —— 4×2 展开格子的
           "翻转换图"(MRUFlippingArtworkView 的 rotation.y + autoreverses)就是被它拦腰
           掐断的: 掐断后图层停在半翻姿态, 用户看到的是"头像外围歪着转/显示不对"。
           现在只认"绕 z 轴的自转", 其它动画(翻转/呼吸/高亮)一个都不碰。 */
        if (![a isKindOfClass:CABasicAnimation.class]) continue;
        NSString *kp = ((CABasicAnimation *)a).keyPath;
        if ([kp isEqualToString:@"transform.rotation.z"] || [kp isEqualToString:@"transform.rotation"]) {
            [layer removeAnimationForKey:k];
        }
    }
    NSArray<CALayer *> *subs = [layer.sublayers copy];
    for (CALayer *s in subs) diArtStripSpin(s, depth + 1, maxDepth);
}

/* 3.0.15: 删除 3.0.14 的 diArtStripRotationOnly(全树只清 rotation)。它在运行中会把
   系统给"没有被我们收集到的格子"挂的原生旋转一并摘掉 —— 用户看到的小专辑"转着转着
   停住/闪一下"就是这个。旋转现在只由 diArtApply 内部管理, 全树一律不再动。 */

/* 3×2 / 3×2B: 变体键优先(B 档模块尺寸写的是 4x2), 没有变体再看 ModuleSizes */
static BOOL diArtIs3x2(void) {
    static NSString *cache = nil;
    static CFTimeInterval ts = 0;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (cache && now - ts < 2.0) return [cache hasPrefix:@"3x2"];
    NSString *cur = nil;
    id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("PlayerGridVariant"),
                                                      CFSTR("com.local.playerexact")));
    if ([v isKindOfClass:NSString.class] && [v length]) cur = v;
    if (!cur.length) {
        id dict = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("ModuleSizes"),
                                                             CFSTR("com.local.playerexact")));
        if ([dict isKindOfClass:NSDictionary.class]) {
            id s = dict[@"com.apple.mediaremote.controlcenter.nowplaying"];
            if ([s isKindOfClass:NSString.class]) cur = s;
        }
    }
    cache = cur ?: @"";
    ts = now;
    return [cache hasPrefix:@"3x2"];
}

/* ===== 3.0.29: 3×1 布局 —— 只把网格里这个模块的框收窄 =====
   3.0.28 是在 MRUNowPlayingView.layoutSubviews 里把内容压到 80%, 可那个视图在
   **展开态也存在**(356x568), 于是展开也被一起压小 —— 用户: "你把我展开里面都改了,
   我只需要我画的框那样缩短就行, 其他不要动"。
   现在:
     · 只碰"网格态"模块(容器高 20~130pt; 展开态高 300+ 一律跳过);
     · 目标宽 = 0.75 × 4格宽 − 4pt(格间隙修正)。实测满宽 356 → 263, 正好等于
       3×2 布局的模块宽(日志里 3 格模块就是 263) —— 即用户说的"取 3×2 的长,
       4×1 的高";
     · 改的是模块容器 CCUIContentModuleContainerView(含背景胶囊)的 frame: 左边缘
       不动(内容整体左移一点点), 高度不动, 内部由播放器按新宽度自己重排;
     · 网格布局会重设 frame, 所以在容器自己的 layoutSubviews(父级刚设完 frame、
       同一帧提交前)纠正, 集合控制器布局链尾再兜一次。
*/
/* 3.0.32: 3.0.31 曾把模块尺寸直接写成 "3x1", 但系统只认 2x2/2x3/3x2/4x1/4x2/4x3,
   非法值会被退化成最小的 2×2。这里做一次自愈: 域里若还留着 3x1, 后台(注入 5 秒后,
   避开首开初始化串)改回 4x1。模块宽度本来就靠下面的收窄钩子控制。 */
static void diNP31HealModuleSize(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CFStringRef dom = CFSTR("com.local.playerexact");
        id dict = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("ModuleSizes"), dom));
        if (![dict isKindOfClass:NSDictionary.class]) return;
        id v = dict[@"com.apple.mediaremote.controlcenter.nowplaying"];
        if (![v isKindOfClass:NSString.class] || ![v isEqualToString:@"3x1"]) return;
        NSMutableDictionary *m = [dict mutableCopy];
        m[@"com.apple.mediaremote.controlcenter.nowplaying"] = @"4x1";
        CFPreferencesSetAppValue(CFSTR("ModuleSizes"), (__bridge CFPropertyListRef)m, dom);
        CFPreferencesAppSynchronize(dom);
        dispatch_async(dispatch_get_main_queue(), ^{
            RLog(@"[3x1] 自愈: ModuleSizes 里遗留的 3x1 已改回 4x1");
        });
    });
}
static NSString *diNPLayoutKey(void) {
    static NSString *cache = nil;
    static CFTimeInterval ts = 0;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (cache && now - ts < 2.0) return cache;
    /* 3.0.32: 注入后 3 秒内不读跨进程域 —— 首开那一波 cfprefsd 争用是最有名的卡点
       (439/441 日志 [卡死] 阶段=prefs), 布局钩子会高频进来。3 秒后正常读(2 秒一次
       缓存), 既避开初始化尖峰, 又不会让用户注销后打开控制中心时读不到 3×1。 */
    {
        static CFTimeInterval boot = 0;
        if (boot == 0) boot = now;
        if (now - boot < 1.0) return @"";
    }
    NSString *cur = nil;
    /* 3.0.30: Size 是用户在设置页直接选的那一档(我们必写), 可信度最高。
       442 日志里 Size=4x1、ModuleSizes=4x1 但没有任何 PlayerGridVariant ——
       之前只认 Variant/ModuleSizes, 选了 3×1 也可能读不到。现在先看 Size。 */
    id sz = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("Size"),
                                                       CFSTR("com.local.playerexact")));
    if ([sz isKindOfClass:NSString.class] && [sz length]) cur = sz;
    if (!cur.length) {
        id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("PlayerGridVariant"),
                                                          CFSTR("com.local.playerexact")));
        if ([v isKindOfClass:NSString.class] && [v length]) cur = v;
    }
    if (!cur.length) {
        id dict = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("ModuleSizes"),
                                                             CFSTR("com.local.playerexact")));
        if ([dict isKindOfClass:NSDictionary.class]) {
            id s = dict[@"com.apple.mediaremote.controlcenter.nowplaying"];
            if ([s isKindOfClass:NSString.class]) cur = s;
        }
    }
    cache = cur ?: @"";
    ts = now;
    /* 3.0.32: 选了 3×1 → 顺手把域里可能残留的非法 "3x1" 模块尺寸改回 4x1 */
    if ([cache isEqualToString:@"3x1"]) diNP31HealModuleSize();
    return cache;
}

/* 3.0.30: 3×1 收窄改成"先认准播放器模块, 再改它"。
   442 日志: 模块是 356x77(430 机型), 两个钩子都装上了, 但 [3x1] 一条没打 ——
   "在容器子树里找 MRUNowPlayingView" 这条路在网格态走不通(播放器视图不在容器
   子树里, 或者类名不是那个前缀), 所以一个都没收。
   现在: diNPHandleModuleVC 早就用 moduleIdentifier=nowplaying 精确认出了播放器
   模块并且拿到了卡片, 那里直接给"卡片 + 外层模块容器"打标记(kDI3x1Player);
   布局钩子只负责把带标记的视图宽度摆正, 认不出的模块(天气/手电)一个都不碰。
   目标宽 = 满宽 × 0.75 − 4pt(= 3 格宽; 430 机型实测 356 → 263, 与 3×2 模块同宽);
   只改宽度: 左边缘不动(内容整体左移一点点), 高度不动(还是 4×1 的高);
   高度 > 130 的(展开态 300+)直接跳过 —— 展开一个像素都不动。 */
static char kDI3x1Player;    /* 标记: 这个视图属于播放器模块 */
static char kDI3x1FullW;     /* 首次见到的满宽, 之后按它算目标, 防越缩越短 */
static char kDI3x1NegTS;     /* 3.0.35: 上次"识别失败"的时间戳(2 秒 TTL 负缓存) */
static NSHashTable *gDI3x1Views;
static BOOL diNP31On(void) {
    return [diNPLayoutKey() isEqualToString:@"3x1"];
}
/* 3.0.34: "锁死"保险 —— 系统在任何时机把宽度摆回满宽(动画/重建/重排), 200ms 内
   收回来, 不依赖某个布局回调有没有跑到。只轮询几个已标记的视图, 开销可忽略。 */
static void diNP31StartWatch(void);
static void diNP31Mark(UIView *v) {
    if (!v) return;
    objc_setAssociatedObject(v, &kDI3x1Player, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    /* 3.0.32: 基准宽只认"满宽"(4×1 排出来的 356 这类)。以前宽 >200 就记, 若是先看到
       已经收窄过的 263 会把基准记成 263, 于是 263×0.75−4=193 越缩越短。 */
    NSNumber *fw = objc_getAssociatedObject(v, &kDI3x1FullW);
    CGFloat w = v.frame.size.width;
    /* 3.0.35: "只记一次"改成"单调取最大"。原规则只防住了覆盖, 没防住"第一次就收到
       动画中间值": 若首次 setFrame: 拿到 320(≥300), 基准就永久锁在 320, 目标宽
       = 320×0.75−4 = 236, 整个会话都比 3 格窄 27pt。允许"更大才覆盖"既不会越缩越短,
       又能在随后真正的满宽 356 到来时把基准修正回来。 */
    if (w >= 300.0 && (!fw || w > fw.doubleValue + 20.0)) {
        objc_setAssociatedObject(v, &kDI3x1FullW, @(w), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!gDI3x1Views) gDI3x1Views = [NSHashTable weakObjectsHashTable];
    [gDI3x1Views addObject:v];
    diNP31StartWatch();
}
/* 3×1 的目标宽(满宽 × 0.75 − 4 = 3 格宽); 算不出来返回 0 */
static CGFloat diNP31TargetW(UIView *box) {
    NSNumber *fw = objc_getAssociatedObject(box, &kDI3x1FullW);
    CGFloat full = fw ? fw.doubleValue : 0;
    if (full < 300.0) return 0;
    CGFloat target = full * 0.75 - 4.0;
    return target >= 150.0 ? target : 0;
}
static void diNP31FitBox(UIView *box) {
    if (!box) return;
    CGRect f = box.frame;
    if (f.size.width < 200.0) return;                            /* 已经是窄的/占位 */
    if (f.size.height < 20.0 || f.size.height > 130.0) return;   /* 展开态(300+)不碰 */
    CGFloat target = diNP31TargetW(box);
    if (target <= 0) return;
    if (fabs(f.size.width - target) < 1.0) return;
    box.frame = CGRectMake(f.origin.x, f.origin.y, target, f.size.height);
    static CFAbsoluteTime sT = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - sT > 3.0) {
        sT = now;
        RLog(@"[3x1] 模块框 %.0fx%.0f → %.0fx%.0f", f.size.width, f.size.height,
             target, f.size.height);
    }
}
/* 3.0.36: 以"播放器视图"为锚点收窄 —— 它就是播放器本身, 不需要任何识别,
   不依赖 moduleIdentifier / KVC / ivar 扫描, 也就不存在"认不出来"这件事。
   只处理折叠态(宽>=300 且高 50~120); 展开态(430 机型高 568)直接返回,
   一个像素都不动 —— 用户明确要求"展开的全部不要动"。
   宽度只改 size.width, x/高度原样: 左边缘不动, 长度变短。 */
static void diNP31FitGroup(UIView *npv) {
    @try {
        if (!npv || !npv.window) return;
        if (!diNP31On()) return;
        UIView *box = nil;
        for (UIView *p = npv.superview; p; p = p.superview) {
            if ([NSStringFromClass(p.class) isEqualToString:@"CCUIContentModuleContainerView"]) {
                box = p; break;
            }
            if ([p isKindOfClass:UIWindow.class]) break;
            if (p.bounds.size.width > 500.0) break;                 /* 面板根 */
        }
        if (!box) return;                        /* 锁屏/小岛/桌面组件, 不归 3×1 管 */
        /* 用**容器**尺寸判定, 不用播放器视图自己的宽度: 4×1 时容器是 356 满宽, 而
           播放器视图可能本来就是 263(内容按 3 格画), 拿它当门槛会永远不触发。 */
        CGSize bs = box.bounds.size;
        if (bs.width < 300.0) return;                                /* 容器已经窄了 */
        if (bs.height < 50.0 || bs.height > 120.0) return;           /* 展开态/占位不碰 */
        /* 容器(背景框) → 内容容器(卡片) → 播放器视图, 三层一起收, 才不会一半宽一半窄 */
        diNP31Mark(box);
        diNP31FitBox(box);
        for (UIView *c in box.subviews) {
            if ([NSStringFromClass(c.class) isEqualToString:@"CCUIContentModuleContentContainerView"]) {
                diNP31Mark(c);
                diNP31FitBox(c);
            }
        }
        diNP31Mark(npv);
        diNP31FitBox(npv);
    } @catch (__unused NSException *e) {}
}

static void diNP31StartWatch(void) {
    static BOOL started = NO;
    if (started) return;
    started = YES;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_main_queue());
    if (!t) return;
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)),
                              (uint64_t)(200 * NSEC_PER_MSEC), (uint64_t)(50 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(t, ^{
        @try {
            if (!gDI3x1Views || !diNP31On()) return;
            for (UIView *v in gDI3x1Views.allObjects) {
                if (v.window && !v.hidden) diNP31FitBox(v);
            }
        } @catch (__unused NSException *e) {}
    });
    dispatch_resume(t);
}
static void diNP31ShiftButtons(UIView *tc);   /* 3.0.34: 定义在后面 */
static UIView *diNP31FindTC(UIView *v, int depth) {
    if (!v || depth > 5) return nil;
    if ([NSStringFromClass(v.class) containsString:@"TransportControls"]) return v;
    for (UIView *c in v.subviews) {
        UIView *r = diNP31FindTC(c, depth + 1);
        if (r) return r;
    }
    return nil;
}
/* 卡片(内容) + 外层模块容器(背景框)一起收 —— 只缩宽, 左边缘不动 */
static void diNP31ApplyModule(UIView *card) {
    if (!card || !diNP31On()) return;
    UIView *box = nil;
    /* 3.0.33: 未播放时卡片是 356x932 的整块占位, 以前遇到高 >200 就 break, 结果
       "外层=无", 容器永远收不到 → 用户看到"默认还是 4×1"。现在一路往上找, 只在
       到窗口/面板根时停。 */
    int guard = 0;
    for (UIView *p = card.superview; p && guard++ < 12; p = p.superview) {
        if ([NSStringFromClass(p.class) isEqualToString:@"CCUIContentModuleContainerView"]) {
            box = p;
            break;
        }
        if ([p isKindOfClass:UIWindow.class]) break;
        if (p.frame.size.width > 500 && p.frame.size.height > 500) break;   /* 面板根 */
    }
    static int sLog = 0;
    if (sLog < 6) {
        sLog++;
        RLog(@"[3x1][诊断] 键=%@ 卡片=%@ %.0fx%.0f 外层=%@",
             diNPLayoutKey(), NSStringFromClass(card.class),
             card.frame.size.width, card.frame.size.height,
             box ? [NSString stringWithFormat:@"%@ %.0fx%.0f", NSStringFromClass(box.class),
                    box.frame.size.width, box.frame.size.height] : @"无");
    }
    diNP31Mark(card);
    diNP31FitBox(card);
    if (box) { diNP31Mark(box); diNP31FitBox(box); }
    /* 3.0.34: 3×1 的传送栏不一定走 MRUNowPlayingTransportControlsView 的钩子,
       这里直接在卡片树里找到它, 主动把"播放/下一首"摆到位。 */
    if (diNP31On()) {
        UIView *tc = diNP31FindTC(card, 0);
        if (tc) diNP31ShiftButtons(tc);
    }
}

/* 容器自己的 layoutSubviews: 父级刚把 frame 设成满宽, 这里同一帧内改回来 */
static void (*gDIOrigCMCLayout)(id, SEL) = NULL;
static void (*gDIOrigCardLayout)(id, SEL) = NULL;
static void (*gDIOrigCMCFrame)(id, SEL, CGRect) = NULL;
static void (*gDIOrigCardFrame)(id, SEL, CGRect) = NULL;

/* 3.0.33: 容器/卡片自报身份 —— 未播放时播放器 VC 可能还没建, 靠 moduleIdentifier
   自己认。3.0.34: KVC 在私有类上经常取不到(键名不带下划线就抛异常), 改成直接扫
   ivar(名字里带 identifier 的 NSString), 再加 context / contentViewController 类名
   / 子树含 NowPlaying 三层兜底。 */
static NSString *diNP31ScanIdent(id obj) {
    if (!obj) return nil;
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList([obj class], &n);
    NSString *found = nil;
    for (unsigned i = 0; i < n && ivars; i++) {
        const char *nm = ivar_getName(ivars[i]);
        if (!nm) continue;
        if (!strstr(nm, "dentifier") && !strstr(nm, "Identifier")) continue;
        const char *ty = ivar_getTypeEncoding(ivars[i]);
        if (!ty || ty[0] != '@') continue;
        @try {
            id val = object_getIvar(obj, ivars[i]);
            if ([val isKindOfClass:NSString.class] && [(NSString *)val length]) { found = val; break; }
        } @catch (__unused NSException *e) {}
    }
    if (ivars) free(ivars);
    return found;
}
static BOOL diNP31IsNPIdent(NSString *s) {
    if (![s isKindOfClass:NSString.class] || !s.length) return NO;
    NSString *l = s.lowercaseString;
    return [l containsString:@"nowplaying"] || [l containsString:@"now-playing"];
}
static BOOL diNP31HasNPChild(UIView *v, int depth, int *budget) {
    if (!v || depth > 3 || (budget && *budget <= 0)) return NO;
    for (UIView *c in v.subviews) {
        if (budget) (*budget)--;
        NSString *cn = NSStringFromClass(c.class);
        if ([cn containsString:@"NowPlaying"] || [cn containsString:@"MediaControls"]) return YES;
        if (diNP31HasNPChild(c, depth + 1, budget)) return YES;
    }
    return NO;
}
static BOOL diNP31SelfIdentify(UIView *v) {
    if (!v) return NO;
    if (objc_getAssociatedObject(v, &kDI3x1Player)) return YES;
    /* 3.0.35: 负结果做 2 秒 TTL 缓存。以前只缓存"是播放器", 认不出来的视图
       (手电/天气/计时器容器)每次 setFrame: 都重跑全套四级识别 —— 包括会抛异常的
       KVC 和最多 80 节点的子树遍历。用 TTL 而不是永久缓存, 是因为第四级
       (子树里有没有 NowPlaying) 依赖子树此刻的构成, 永久缓存会把"晚一点才挂上
       播放器"的容器错误地永久排除。 */
    NSNumber *negTS = objc_getAssociatedObject(v, &kDI3x1NegTS);
    CFAbsoluteTime nowTS = CFAbsoluteTimeGetCurrent();
    if (negTS && nowTS - negTS.doubleValue < 2.0) return NO;
    NSString *ident = diNP31ScanIdent(v);
    if (!diNP31IsNPIdent(ident)) {
        @try { id x = [v valueForKey:@"moduleIdentifier"]; if ([x isKindOfClass:NSString.class]) ident = x; }
        @catch (__unused NSException *e) {}
    }
    if (!diNP31IsNPIdent(ident)) {
        @try {
            UIResponder *r = [v nextResponder];
            if ([r isKindOfClass:UIViewController.class]) {
                id x = diNP31ScanIdent(r);
                if (!x) { @try { x = [r valueForKey:@"moduleIdentifier"]; } @catch (__unused NSException *e) {} }
                if ([x isKindOfClass:NSString.class]) ident = x;
            }
        } @catch (__unused NSException *e) {}
    }
    if (!diNP31IsNPIdent(ident)) {
        /* 容器的 context 里带着标识 */
        @try {
            id ctx = nil;
            @try { ctx = [v valueForKey:@"contentModuleContext"]; } @catch (__unused NSException *e) {}
            if (!ctx) { @try { ctx = [v valueForKey:@"_contentModuleContext"]; } @catch (__unused NSException *e) {} }
            if (ctx) {
                id x = diNP31ScanIdent(ctx);
                if (!x) { @try { x = [ctx valueForKey:@"moduleIdentifier"]; } @catch (__unused NSException *e) {} }
                if ([x isKindOfClass:NSString.class]) ident = x;
            }
        } @catch (__unused NSException *e) {}
    }
    if (!diNP31IsNPIdent(ident)) {
        /* 内容控制器类名 */
        @try {
            id vc = nil;
            @try { vc = [v valueForKey:@"contentViewController"]; } @catch (__unused NSException *e) {}
            if (!vc) { @try { vc = [v valueForKey:@"_contentViewController"]; } @catch (__unused NSException *e) {} }
            NSString *cn = vc ? NSStringFromClass([vc class]) : nil;
            if (cn.length && [cn.lowercaseString containsString:@"nowplaying"]) ident = @"nowplaying";
        } @catch (__unused NSException *e) {}
    }
    if (!diNP31IsNPIdent(ident)) {
        /* 最后一层: 子树里已经挂着播放器 */
        int budget = 80;
        if (diNP31HasNPChild(v, 0, &budget)) ident = @"nowplaying";
    }
    if (diNP31IsNPIdent(ident)) {
        diNP31Mark(v);
        objc_setAssociatedObject(v, &kDI3x1NegTS, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        static int logs = 0;
        if (logs < 4) { logs++; RLog(@"[3x1] 识别: %@ → %@", NSStringFromClass(v.class), ident); }
        return YES;
    }
    objc_setAssociatedObject(v, &kDI3x1NegTS, @(nowTS), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return NO;
}
/* 3.0.32: 让"注销后第一次打开就是 3 格宽"。
   改在 setFrame:(网格给容器/卡片正式设 frame 的那一刻)而不是 layoutSubviews 之后:
   这里改完就在同一调用栈里设置, CA 提交前已经是窄的, 用户看不到 4×1 的中间态;
   而且系统后续读 frame 做排版时读到的就是窄值, 不会再摆回满宽。
   只动宽度: 左边缘(x)和高度不变。 */
static CGRect diNP31AdjustRect(UIView *v, CGRect f) {
    @try {
        /* 3.0.35: 顺序倒过来 —— 先判档位(2 秒缓存, 开销约等于一次字符串比较),
           再做识别。识别里有 class_copyIvarList 分配、多次 KVC(键不存在会抛
           NSUnknownKeyException, ObjC 异常很贵)、最深 80 节点的子树遍历;
           而这个函数挂在 CCUIContentModuleContainerView.setFrame: 上, 控制中心
           打开动画期间每帧几十次、每个模块(手电/天气/计时器)都过一次 ——
           非 3×1 用户白付这份开销, iOS 17 首开叠加 cfprefsd 争用就会主线程超时。 */
        if (!diNP31On()) return f;
        if (!diNP31SelfIdentify(v)) return f;
        if (f.size.height < 20.0 || f.size.height > 130.0) return f;   /* 展开态不碰 */
        if (f.size.width >= 300.0) {                                    /* 满宽 = 基准 */
            /* 3.0.34: 基准只记一次。以前每次都覆盖, 动画中间值 320/340 会被当成
               "满宽"记下来, 目标宽随之变成 236/251 —— 视觉上就是"闪一下、宽度乱跳"。 */
            NSNumber *fw = objc_getAssociatedObject(v, &kDI3x1FullW);
            /* 3.0.35: 同 diNP31Mark —— 允许更大值覆盖, 修"第一次就是动画中间值"锁死基准 */
            if (!fw || f.size.width > fw.doubleValue + 20.0) {
                objc_setAssociatedObject(v, &kDI3x1FullW, @(f.size.width),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            CGFloat t = diNP31TargetW(v);
            if (t > 0) f.size.width = t;
            return f;
        }
        CGFloat t = diNP31TargetW(v);
        if (t > 0 && f.size.width > 200.0 && fabs(f.size.width - t) >= 1.0) f.size.width = t;
    } @catch (__unused NSException *e) {}
    return f;
}
static void diNP31CMCFrame(id self, SEL cmd, CGRect f) {
    f = diNP31AdjustRect((UIView *)self, f);
    if (gDIOrigCMCFrame) gDIOrigCMCFrame(self, cmd, f);
}
static void diNP31CardFrame(id self, SEL cmd, CGRect f) {
    f = diNP31AdjustRect((UIView *)self, f);
    if (gDIOrigCardFrame) gDIOrigCardFrame(self, cmd, f);
}
static void diNP31CMCLayout(id self, SEL cmd) {
    if (gDIOrigCMCLayout) gDIOrigCMCLayout(self, cmd);
    @try {
        UIView *v = (UIView *)self;
        if (!diNP31On()) return;
        if (!objc_getAssociatedObject(v, &kDI3x1Player)) {
            /* 3.0.36: 识别一直没成功过(3.0.35 日志里 [3x1] 识别 一条都没有),
               所以收窄全靠 moduleIdentifier 那条路径, 首开晚了 6 秒。
               这里换成一个不可能失败的判据: 正在 layout 的容器里已经挂着播放器
               子树 = 这就是播放器模块。只在折叠尺寸下认(展开态一律不碰)。 */
            CGSize sz = v.bounds.size;
            if (sz.width < 300.0 || sz.height < 40.0 || sz.height > 130.0) return;
            int budget = 120;
            if (!diNP31HasNPChild(v, 0, &budget)) return;
            diNP31Mark(v);
        }
        diNP31FitBox(v);
    } @catch (__unused NSException *e) {}
}
/* 集合控制器布局链尾兜底: 覆盖"容器没被重新布局、但父级改了 frame"的情况 */
static void (*gDIOrigCVCViewLayout)(id, SEL) = NULL;
static void diNP31Walk(UIView *v, int depth) {
    if (!v || depth > 12) return;
    if (objc_getAssociatedObject(v, &kDI3x1Player)) {
        diNP31FitBox(v);
    } else if ([NSStringFromClass(v.class) isEqualToString:@"CCUIContentModuleContainerView"]) {
        /* 3.0.33: 没标记过的容器也认一次(未播放态没有播放器 VC, 只能靠容器自报身份) */
        if (diNP31SelfIdentify(v)) diNP31FitBox(v);
    }
    for (UIView *c in v.subviews) diNP31Walk(c, depth + 1);
}
static void diNP31CardLayout(id self, SEL cmd) {
    if (gDIOrigCardLayout) gDIOrigCardLayout(self, cmd);
    @try {
        UIView *v = (UIView *)self;
        if (!objc_getAssociatedObject(v, &kDI3x1Player)) return;
        if (!diNP31On()) return;
        diNP31FitBox(v);
    } @catch (__unused NSException *e) {}
}
static void diNP31VCViewLayout(id self, SEL cmd) {
    if (gDIOrigCVCViewLayout) gDIOrigCVCViewLayout(self, cmd);
    @try {
        if (!diNP31On()) return;
        UIViewController *vc = (UIViewController *)self;
        if (vc.isViewLoaded) diNP31Walk(vc.view, 0);
    } @catch (__unused NSException *e) {}
}
static void diTBInstallRowHook(void);   /* 3.0.34: 3×1 也要装(定义在传送栏那一节) */
static void diNPInstall3x1Hook(void) {
    static BOOL doneVC = NO;
    static BOOL doneBox = NO, doneCard = NO, doneFrame = NO;
    if (doneVC && doneBox && doneCard && doneFrame) return;
    /* 3.0.32: setFrame: 阶段就摆平(见 diNP31AdjustRect) —— 两个类都挂 */
    if (!doneFrame) {
        doneFrame = YES;
        Class cb = NSClassFromString(@"CCUIContentModuleContainerView");
        Class cc = NSClassFromString(@"CCUIContentModuleContentContainerView");
        if (cb) {
            @try {
                MSHookMessageEx(cb, @selector(setFrame:), (IMP)diNP31CMCFrame,
                                (IMP *)&gDIOrigCMCFrame);
                RLog(@"[3x1] 容器 setFrame 钩子 %@", gDIOrigCMCFrame ? @"已装" : @"失败");
            } @catch (__unused NSException *e) {}
        }
        if (cc) {
            @try {
                MSHookMessageEx(cc, @selector(setFrame:), (IMP)diNP31CardFrame,
                                (IMP *)&gDIOrigCardFrame);
                RLog(@"[3x1] 卡片 setFrame 钩子 %@", gDIOrigCardFrame ? @"已装" : @"失败");
            } @catch (__unused NSException *e) {}
        }
    }
    /* 两个类都挂: 不同 iOS 版本里"卡片"和"容器"是哪个类不固定 */
    if (!doneBox) {
        Class c = NSClassFromString(@"CCUIContentModuleContainerView");
        if (c) {
            doneBox = YES;
            @try {
                Method m = class_getInstanceMethod(c, @selector(layoutSubviews));
                IMP before = m ? method_getImplementation(m) : NULL;
                MSHookMessageEx(c, @selector(layoutSubviews), (IMP)diNP31CMCLayout,
                                (IMP *)&gDIOrigCMCLayout);
                if (!gDIOrigCMCLayout) gDIOrigCMCLayout = (void (*)(id, SEL))before;
                RLog(@"[3x1] 模块容器布局钩子 %@", gDIOrigCMCLayout ? @"已装" : @"失败");
            } @catch (__unused NSException *e) {}
        }
    }
    if (!doneCard) {
        Class c = NSClassFromString(@"CCUIContentModuleContentContainerView");
        if (c) {
            doneCard = YES;
            @try {
                Method m = class_getInstanceMethod(c, @selector(layoutSubviews));
                IMP before = m ? method_getImplementation(m) : NULL;
                MSHookMessageEx(c, @selector(layoutSubviews), (IMP)diNP31CardLayout,
                                (IMP *)&gDIOrigCardLayout);
                if (!gDIOrigCardLayout) gDIOrigCardLayout = (void (*)(id, SEL))before;
                RLog(@"[3x1] 卡片布局钩子 %@", gDIOrigCardLayout ? @"已装" : @"失败");
            } @catch (__unused NSException *e) {}
        }
    }
    if (!doneVC) {
        Class c = NSClassFromString(@"CCUIModuleCollectionViewController");
        if (c) {
            doneVC = YES;
            @try {
                Method m = class_getInstanceMethod(c, @selector(viewDidLayoutSubviews));
                IMP before = m ? method_getImplementation(m) : NULL;
                MSHookMessageEx(c, @selector(viewDidLayoutSubviews), (IMP)diNP31VCViewLayout,
                                (IMP *)&gDIOrigCVCViewLayout);
                if (!gDIOrigCVCViewLayout) gDIOrigCVCViewLayout = (void (*)(id, SEL))before;
                RLog(@"[3x1] 集合控制器布局钩子 %@", gDIOrigCVCViewLayout ? @"已装" : @"失败");
            } @catch (__unused NSException *e) {}
        }
    }
    /* 3.0.34: 3×1 也要装传送栏/按钮钩子 —— 以前只在 3×2 路径(diTBNormalizeFromRoot)
       里才装, 所以 3×1 下按钮位移一次都没跑(446 日志一条 [3x1] 按钮都没有)。 */
    diTBInstallRowHook();
}

static BOOL diArtNameIsArtwork(NSString *cn) {
    if (!cn.length) return NO;
    if ([cn containsString:@"Activity"] || [cn containsString:@"Flipping"]) return NO;
    if ([cn containsString:@"Blur"] || [cn containsString:@"Shadow"] || [cn containsString:@"Gradient"]) return NO;
    return [cn containsString:@"Artwork"] || [cn containsString:@"AlbumArt"];
}

/* 收集播放器里的所有封面: 3×2 展开态是四宫格, 会有 3~4 个封面同时存在,
   以前只取最大的那一个, 所以"图一那种布局"永远只有一张变圆。
   判据: 类名带 Artwork / 接近正方形 / 不能是铺满整块的背景图。 */
/* 3.0.12: 是不是播放器"控件壳"里的图标(上下首/滑块/音量/头部) —— 这些里的
   UIImageView 绝对不能当封面蒙(3.0.8 "有些圆有些不圆"就是这么来的)。 */
static BOOL diArtInChrome(UIView *v) {
    for (UIView *p = v.superview; p; p = p.superview) {
        NSString *cn = NSStringFromClass(p.class);
        if ([cn containsString:@"TransportButton"] || [cn containsString:@"TransportControls"]
            || [cn containsString:@"Stepper"] || [cn containsString:@"Slider"]
            || [cn containsString:@"TimeControls"] || [cn containsString:@"VolumeControls"]
            || [cn containsString:@"Header"] || [cn containsString:@"CAPackage"]
            || [cn containsString:@"Route"]) return YES;
    }
    return NO;
}

static BOOL gDIArtSawEmptyTile = NO;   /* 3.0.13: 这轮扫描里看到了"该当封面但图还没加载完"的格子 */
static NSHashTable *gDIArtKnown = nil; /* 3.0.17: 见过的封面(弱引用), 持续维护 */

static NSArray<UIView *> *diArtCollectIn(UIView *root) {
    NSMutableArray *out = [NSMutableArray array];
    if (!root) return out;
    CGFloat rootArea = root.bounds.size.width * root.bounds.size.height;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int budget = 1500;   /* 3×2 建议网格节点多, 800 会截断 */
    while (stack.count && budget-- > 0) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if (v != root && !v.hidden && v.alpha > 0.05) {
            CGSize s = v.bounds.size;
            if (s.width >= 18 && s.height >= 18 && s.width <= 600 && s.height <= 600) {
                CGFloat ratio = s.width / MAX(1.0, s.height);
                CGFloat area = s.width * s.height;
                BOOL tooBig = rootArea > 1 && area > rootArea * 0.55;
                BOOL named = diArtNameIsArtwork(NSStringFromClass(v.class));
                /* 3.0.12: 建议网格里没加载到封面的格子仍是普通视图, 有图的格子
                   也未必是 MRUArtworkView —— 补一条"够大的方形 UIImageView"兜底,
                   但必须排除控件壳里的图标(上面 diArtInChrome)。 */
                BOOL chrome = diArtInChrome(v);
                BOOL plain = ([v isKindOfClass:UIImageView.class]
                              && ((UIImageView *)v).image != nil
                              && s.width >= 38 && s.height >= 38
                              && !chrome);
                /* 3.0.13: 图还没异步加载完的格子会一直漏蒙 —— 记下来, 靠延迟
                   二次收集补蒙(见 diArtPlayerPost) */
                if (!tooBig && !chrome && ratio > 0.7 && ratio < 1.45
                    && [v isKindOfClass:UIImageView.class]
                    && ((UIImageView *)v).image == nil
                    && s.width >= 38 && s.height >= 38) {
                    gDIArtSawEmptyTile = YES;
                }
                if (!tooBig && ratio > 0.7 && ratio < 1.45 && (named || plain)) {
                    [out addObject:v];
                    if (out.count >= 9) break;
                    continue;   /* 命中封面就不再往里钻, 免得把它内部的 imageView 也当封面 */
                }
            }
        }
        for (UIView *c in v.subviews) [stack addObject:c];
    }
    return out;
}

/* 3.0.16: 图层改成"自带关闭隐式动画"的 actions, 不再用 CATransaction 包住写入 ——
   在 layoutSubviews 里手工 begin/commit 事务会把系统这一帧排好的动画提前提交,
   肉眼就是"整块内容闪一下/抖一下"。per-layer actions 只影响我们自己的层。 */
static void diNoImplicitActions(CALayer *l) {
    if (!l) return;
    l.actions = @{ @"contents": [NSNull null], @"frame": [NSNull null],
                   @"position": [NSNull null], @"bounds": [NSNull null],
                   @"cornerRadius": [NSNull null], @"hidden": [NSNull null],
                   @"opacity": [NSNull null], @"path": [NSNull null],
                   @"transform": [NSNull null], @"backgroundColor": [NSNull null] };
}

/* 3.0.17: 全局相位时钟 —— 旋转动画被系统摘掉、视图换实例、展开/折叠重建后重挂时,
   一律按"全局时间"算角度, 所以重挂那一刻画面不跳(不会从 12 点重来)。
   参考实现(用户给的 musicRotation.dylib)是 hook 类的 layoutSubviews 直接挂,
   天然每帧都在, 所以从不会"转着转着停了"; 这里把同样的覆盖能力做进 dress 里。 */
static CFTimeInterval gDISpinEpoch = 0;
static const CFTimeInterval kDISpinDur = 10.0;

/* 幂等: 尺寸没变、蒙版还是我们那片、旋转还在 → 一个字都不写。
   3.0.16 及以前每轮布局都重设 mask.frame/path, 3×2 网格里那张图每秒被重建两三次,
   肉眼就是"小专辑头像闪一下"。 */

static void diArtDress(UIView *v) {
    if (!v || !v.layer) return;
    CALayer *layer = v.layer;
    CGRect b = v.bounds;
    if (b.size.width < 8 || b.size.height < 8) return;
    DIArtMaskState *st = objc_getAssociatedObject(v, kDIArtStateKey);
    if (!st) {
        st = [DIArtMaskState new];
        st.origMask = layer.mask;
        st.origRadius = layer.cornerRadius;
        st.origClip = layer.masksToBounds;
        st.origTransform = layer.transform;
        st.origAnchor = layer.anchorPoint;
        objc_setAssociatedObject(v, kDIArtStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        /* 3.0.19: 锚点不在正中时, 绕 z 轴旋转会让整块头像"绕着外围某点转"(用户 4×2
           反馈的"外围旋转")。这里把锚点归中, 同时把 position 补偿回去, 保证这一帧
           视觉位置一动不动; 关掉时再还原。 */
        if (fabs(layer.anchorPoint.x - 0.5) > 0.001 || fabs(layer.anchorPoint.y - 0.5) > 0.001) {
            CGRect f = layer.frame;
            layer.anchorPoint = CGPointMake(0.5, 0.5);
            layer.position = CGPointMake(f.origin.x + f.size.width / 2.0,
                                         f.origin.y + f.size.height / 2.0);
        }
        /* 第一次接管这张封面时, 把播放器自己挂的旋转(常在内部 imageView 那层)清掉 ——
           不清就是"我们的 10 秒一圈 + 它的若干秒一圈"叠在一起, 转速翻倍还会卡顿。
           只清这一棵树(封面内部), 与传送栏/按钮无关。 */
        diArtStripSpin(layer, 0, 5);
    }
    if (!st.mask) {
        st.mask = [CAShapeLayer layer];
        st.mask.name = @"di.player.art.circle";
        diNoImplicitActions(st.mask);
    }
    /* 只有"尺寸真的变了"或"系统把我们那片 mask 换掉了"才重建 —— 其余情况跳过 */
    if (layer.mask != st.mask || !CGSizeEqualToSize(st.lastSize, b.size)) {
        st.lastSize = b.size;
        CGFloat side = MIN(b.size.width, b.size.height);
        CGRect circle = CGRectMake((b.size.width - side) / 2.0, (b.size.height - side) / 2.0, side, side);
        st.mask.frame = b;
        st.mask.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(circle, 0.5, 0.5)].CGPath;
        layer.mask = st.mask;
        NSString *desc = [NSString stringWithFormat:@"%@ %.0fx%.0f", NSStringFromClass(v.class),
                          b.size.width, b.size.height];
        if (![desc isEqualToString:gDIArtLastDesc]) {
            gDIArtLastDesc = desc;
            RLog(@"[封面] 圆形蒙版已挂 %@", desc);
        }
    }
    if (![layer animationForKey:@"di.art.spin"]) {
        CFTimeInterval tn = CACurrentMediaTime();
        if (gDISpinEpoch <= 0) gDISpinEpoch = tn;
        CABasicAnimation *sp = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        sp.fromValue = @0.0;
        sp.toValue = @(M_PI * 2.0);
        sp.duration = kDISpinDur;
        sp.repeatCount = HUGE_VALF;
        sp.removedOnCompletion = NO;
        sp.fillMode = kCAFillModeForwards;
        sp.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        sp.beginTime = tn - fmod(tn - gDISpinEpoch, kDISpinDur);   /* 相位续上 */
        [layer addAnimation:sp forKey:@"di.art.spin"];
    }
}

static void diArtApply(UIView *v, BOOL on) {
    if (!v || !v.layer) return;
    CALayer *layer = v.layer;
    DIArtMaskState *st = objc_getAssociatedObject(v, kDIArtStateKey);
    if (!on) {
        /* 关: 蒙版还原、圆角还原、旋转动画(含播放器自己挂的)全部摘掉 → 回到方形静止 */
        if (st) {
            [layer removeAnimationForKey:@"di.art.spin"];
            if (layer.mask == st.mask) layer.mask = st.origMask;
            layer.cornerRadius = st.origRadius;
            layer.masksToBounds = st.origClip;
            if (!CATransform3DIsIdentity(st.origTransform)) layer.transform = st.origTransform;
            else if (!CATransform3DIsIdentity(layer.transform)) layer.transform = CATransform3DIdentity;
            if (fabs(st.origAnchor.x - 0.5) > 0.001 || fabs(st.origAnchor.y - 0.5) > 0.001) {
                CGRect f = layer.frame;
                layer.anchorPoint = st.origAnchor;
                layer.position = CGPointMake(f.origin.x + f.size.width * st.origAnchor.x,
                                             f.origin.y + f.size.height * st.origAnchor.y);
            }
            objc_setAssociatedObject(v, kDIArtStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        /* 3.0.15: 删掉"没记录也要把 transform 拍回单位阵" —— 系统给没被我们收集到的
           格子挂的原生旋转就是这么被永久拍停的(用户反馈"旋转有时候会停")。 */
        diArtStripSpin(layer, 0, 5);
        return;
    }
    diArtDress(v);
}

/* ===== 3.0.9: 3×2 传送栏"瞬跳"修复 =====
   实测(把你发的录屏按 60fps 逐帧量): 上一首 / 播放暂停 / 下一首 三个按钮会整条同时
   上跳约 5pt, 停 1~2 帧又落回, 半秒到一秒一次 —— 这就是肉眼看到的"一抖一抖"。
   图层上没有任何动画, 按钮自身 frame 也一直没变; 变的是"传送容器"被某次布局改了
   一下 frame, 下一帧又改回去。所以不去猜播放器内部逻辑, 只把这一个容器的位置钉住:
     · 尺寸不变 + 位移 <= 12pt + 父视图尺寸没变  → 判为抖动, 回滚到稳定值;
     · 尺寸变了 / 位移更大 / 父视图尺寸变了(换布局、横竖屏) → 视为真的要挪, 更新基准。
   只作用于 3×2 档位, 其它布局和其它视图一律不碰。 */
static const void *kDITCStateKey = &kDITCStateKey;

@interface DITCState : NSObject
@property (nonatomic, assign) CGRect stable;      /* 稳定 frame(父坐标系) */
@property (nonatomic, assign) CGSize parentSize;  /* 基准时的父视图尺寸 */
@property (nonatomic, assign) int  fixed;
@end
@implementation DITCState
@end

static UIView *diArtTransportOf(UIView *root) {
    UIView *tc = nil;
    @try {
        id o = [root valueForKey:@"_transportControlsView"];
        if ([o isKindOfClass:UIView.class]) tc = o;
    } @catch (__unused NSException *e) {}
    if (tc) return tc;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int budget = 400;
    while (stack.count && budget-- > 0) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([NSStringFromClass(v.class) containsString:@"TransportControls"]) return v;
        for (UIView *c in v.subviews) [stack addObject:c];
    }
    return nil;
}

static __attribute__((unused)) void (*gDIOrigTCSetFrame)(id, SEL, CGRect) = NULL;

/* 3.0.10 无限注销的根因修复 —— 3.0.9 的拦截有三处致命伤:
     ① 启动早期传送栏还是 {0,-13.67},{0,44} 这种 0 宽占位 frame, 第一笔就被当成了
        "稳定基准"; 之后所有合法小位移全部被判成"瞬跳"钉回去, 系统布局和我们互相
        打架, 主线程高频空转, SpringBoard 被 watchdog 反复击杀 → 无限注销;
     ② diArtKillJitter 里还有一处"布局进行中直接写 frame"的兜底 —— 布局 pass 里改
        其它视图的 frame, 系统下一帧又改回来, 同样是打架源(本版整体删除);
     ③ 没有任何限流 —— 就算判断错了也会无限次跟布局系统死磕。
   本版三道保险:
     ① 基准只认"非零尺寸"的 frame(宽>=30 高>=20 且父视图>=50), 占位 frame 一律
        放行并更新基准, 永远不当基准;
     ② 拦截必须同时满足: 视图有 window + 未隐藏 + alpha>0.5 + 3×2 档位;
     ③ 全局 10 秒窗口最多拦 40 次, 超限一律放行 —— 判错了也磕不动布局系统。 */
static CFTimeInterval gDITCWindowTS = 0;
static int          gDITCWindowCount = 0;

static __attribute__((unused)) void diTCSetFrame(id self, SEL cmd, CGRect f) {
    @try {
        UIView *v = (UIView *)self;
        CGSize ps = v.superview ? v.superview.bounds.size : CGSizeZero;
        BOOL sizeOk = (f.size.width >= 30.0 && f.size.height >= 20.0
                       && ps.width >= 50.0 && ps.height >= 50.0);
        BOOL visOk  = (v.window != nil && !v.hidden && v.alpha > 0.5);
        if (sizeOk && visOk) {
            DITCState *st = objc_getAssociatedObject(v, kDITCStateKey);
            if (!st || st.stable.size.width < 30.0) {
                /* 首个合格 frame / 之前记的是占位 frame → 以本笔为基准, 不拦 */
                if (!st) {
                    st = [DITCState new];
                    objc_setAssociatedObject(v, kDITCStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                st.stable = f;
                st.parentSize = ps;
                st.fixed = 0;
            } else if (CGSizeEqualToSize(st.parentSize, ps) && CGSizeEqualToSize(st.stable.size, f.size)) {
                CGFloat dy = f.origin.y - st.stable.origin.y;
                CGFloat dx = f.origin.x - st.stable.origin.x;
                BOOL moved = (fabs(dy) > 0.05 || fabs(dx) > 0.05);
                CFTimeInterval now = CFAbsoluteTimeGetCurrent();
                if (now - gDITCWindowTS > 10.0) { gDITCWindowTS = now; gDITCWindowCount = 0; }
                if (moved && diArtIs3x2() && fabs(dy) <= 12.0 && fabs(dx) <= 12.0
                    && gDITCWindowCount < 40) {
                    gDITCWindowCount++;
                    if (st.fixed < 24) {
                        st.fixed++;
                        RLog(@"[抖动] 拦下传送栏瞬跳 dy=%.2f dx=%.2f → 保持 (%.1f,%.1f)",
                             dy, dx, st.stable.origin.x, st.stable.origin.y);
                    }
                    f = st.stable;
                } else if (moved) {
                    st.stable = f;      /* 真的换布局, 以新值为准 */
                    st.parentSize = ps;
                }
            } else {
                st.stable = f;
                st.parentSize = ps;
            }
        }
        /* 尺寸/可见性不合格 → 完全放行, 不建基准不拦截 */
    } @catch (__unused NSException *e) {}
    if (gDIOrigTCSetFrame) gDIOrigTCSetFrame(self, cmd, f);
}

/* ===== 3.0.11: 防死循环保险 =====
   3.0.9/3.1.0/3.0.10 三连"无限安全模式" —— 崩溃点日志上拿不准(缓冲日志崩了就丢),
   所以不再赌: 每次引导先看时间戳文件, 距上次引导 <90 秒 = 疑似刚崩过 → 本次启动
   跳过 3.x 全部新钩子(模块背景/隐藏/传送栏拦截/MediaRemote 取图), 封面圆角旋转
   (3.0.8 时代就稳定)照常。稳定 90 秒后再注销一次, 功能自动回来。
   代价: 手动连注两次才会偶发关一轮, 换来"永远不会再无限安全模式"。 */
static BOOL gDIPlayerSafeBoot = NO;

static void diCrumb(NSString *s) {
    /* 面包屑: 不走缓冲, 直接落盘 —— 崩了也在, 下次日志就能看到死在哪一步 */
    @try {
        RLog(@"[足迹] %@", s);
        NSString *p = @"/var/mobile/Library/Logs/driftisland-crumb.log";
        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                          [NSDate date], s];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        } else {
            [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
    } @catch (__unused NSException *e) {}
}

static int gDIStage = 3;              /* 功能档位: 3=全开 2=去掉传送栏setFrame钩子 1=再去掉模块背景/隐藏钩子 0=全关(旧保险态) */
static CFTimeInterval gDILoadTS = 0;   /* 引导时间戳: 高危钩子推迟到引导 8 秒后再装 */
static NSString *gDIBootVerdict = nil; /* 引导判定结论, 第2秒诊断时回放(躲开日志截断) */

static void diBootGuardCheck(void) {
    /* 3.0.13: 档位制防死循环 —— 引导#1 全功能若真崩, 下次引导自动降一档,
       崩到哪一档停, 日志立刻告诉我们罪魁是哪组钩子; 用户在设置里拨任意开关
       = 明确的"恢复全功能"动作, 档位回 3。 */
    @try {
        double now = [NSDate date].timeIntervalSince1970;
        CFStringRef dom = CFSTR("com.abgg332.driftisland");

        CFPreferencesSynchronize(dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        id mark = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("PendingRespringTS"), dom));
        BOOL userRespring = NO;
        if ([mark isKindOfClass:NSNumber.class]) {
            double mt = [mark doubleValue];
            userRespring = (now - mt >= 0 && now - mt < 600.0);
            CFPreferencesSetAppValue(CFSTR("PendingRespringTS"), NULL, dom);
            CFPreferencesAppSynchronize(dom);
        }

        /* 最近 SpringBoard 崩溃报告 */
        double crashAge = -1;
        BOOL crashHasUs = NO;
        for (NSString *dir in @[@"/var/mobile/Library/Logs/CrashReporter",
                                @"/var/jb/var/mobile/Library/Logs/CrashReporter"]) {
            NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
            for (NSString *f in files) {
                if (![f containsString:@"SpringBoard"]) continue;
                NSString *fp = [dir stringByAppendingPathComponent:f];
                NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:fp error:NULL];
                NSDate *d = at[NSFileModificationDate];
                if (!d) continue;
                double age = now - [d timeIntervalSince1970];
                if (age < 0 || age > 180.0) continue;
                if (crashAge < 0 || age < crashAge) {
                    crashAge = age;
                    NSString *txt = [NSString stringWithContentsOfFile:fp encoding:NSUTF8StringEncoding error:NULL];
                    crashHasUs = (txt && [txt containsString:@"DriftIsland"]);
                }
            }
        }

        /* 时间窗兜底: 距上次引导 <20 秒(崩溃 respawn 5~10 秒, 人为注销更久) */
        NSString *p = @"/var/mobile/Library/Preferences/com.abgg332.driftisland.bootguard.plist";
        double lastTS = 0;
        NSData *data = [NSData dataWithContentsOfFile:p];
        if (data) {
            NSDictionary *d = [NSPropertyListSerialization
                propertyListWithData:data options:0 format:NULL error:NULL];
            if ([d isKindOfClass:NSDictionary.class]) lastTS = [d[@"ts"] doubleValue];
        }
        BOOL quick = (lastTS > 0 && now - lastTS < 20.0);

        /* 当前档位 */
        int stage = 3;
        id sv = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("FeatureStage"), dom));
        if ([sv isKindOfClass:NSNumber.class]) {
            stage = [sv intValue];
            if (stage < 0) stage = 0;
            if (stage > 3) stage = 3;
        }

        BOOL crashed = !userRespring && (crashAge >= 0 || quick);
        if (crashed && stage > 0) {
            stage--;
            CFPreferencesSetAppValue(CFSTR("FeatureStage"), (__bridge CFPropertyListRef)@(stage), dom);
            CFPreferencesAppSynchronize(dom);
        }
        gDIStage = stage;
        gDIPlayerSafeBoot = (stage <= 0);

        gDIBootVerdict = [NSString stringWithFormat:
            @"[保险] 人为注销=%d 崩溃报告=%@ 含漂流岛=%d 距上次引导=%.0fs → 判定=%@ 功能档位=%d %@",
            userRespring,
            crashAge >= 0 ? [NSString stringWithFormat:@"%.0f秒前", crashAge] : @"无",
            crashHasUs, lastTS > 0 ? now - lastTS : -1,
            crashed ? @"崩过(降档)" : @"正常",
            stage,
            stage == 3 ? @"(全开)" : stage == 2 ? @"(无传送栏钩子)" :
            stage == 1 ? @"(无模块背景/隐藏钩子)" : @"(全关, 拨任意开关恢复)"];
        RLog(@"%@", gDIBootVerdict);
        diCrumb(gDIBootVerdict);

        NSData *out = [NSPropertyListSerialization
            dataWithPropertyList:@{@"ts": @(now)}
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        [out writeToFile:p options:NSDataWritingAtomic error:NULL];
    } @catch (__unused NSException *e) { gDIPlayerSafeBoot = NO; }
}

/* 3.0.13: 崩溃证据回放 —— 把最近一次 SpringBoard 崩溃报告的摘要和足迹日志
   打进主日志。日志文件有 512KB 截断, 引导最开头的内容会被冲掉, 所以放在
   第 2 秒诊断里打(那时内容能活到用户导出日志)。 */
static void diNPDumpCrashEvidence(void) {
    @try {
        if (gDIBootVerdict) RLog(@"[保险] 回放: %@", gDIBootVerdict);

        double now = [NSDate date].timeIntervalSince1970;
        NSString *best = nil; NSDate *bestD = nil; NSString *bestName = nil;
        for (NSString *dir in @[@"/var/mobile/Library/Logs/CrashReporter",
                                @"/var/jb/var/mobile/Library/Logs/CrashReporter"]) {
            NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
            for (NSString *f in files) {
                if (![f containsString:@"SpringBoard"]) continue;
                NSString *fp = [dir stringByAppendingPathComponent:f];
                NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:fp error:NULL];
                NSDate *d = at[NSFileModificationDate];
                if (!d) continue;
                if (now - [d timeIntervalSince1970] > 900) continue;
                if (!bestD || [d compare:bestD] == NSOrderedDescending) { bestD = d; best = fp; bestName = f; }
            }
        }
        if (!best) {
            RLog(@"[崩溃回放] 900 秒内没有 SpringBoard 崩溃报告");
        } else {
            double age = now - [bestD timeIntervalSince1970];
            RLog(@"[崩溃回放] 最近报告: %@ (%.0f 秒前)", bestName, age);
            NSString *txt = [NSString stringWithContentsOfFile:best encoding:NSUTF8StringEncoding error:NULL];
            if (txt.length) {
                /* .ips: 第一行是元数据 JSON, 后面是正文。抽出关键行 + 含 DriftIsland 的帧 */
                NSArray *lines = [txt componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet newlineCharacterSet]];
                int shown = 0;
                for (__strong NSString *ln in lines) {
                    BOOL key = [ln containsString:@"Exception Type"] || [ln containsString:@"Exception Codes"]
                            || [ln containsString:@"Termination Reason"] || [ln containsString:@"Termination Description"]
                            || [ln containsString:@"Triggered by Thread"] || [ln containsString:@"crashed"];
                    BOOL ours = [ln containsString:@"DriftIsland"];
                    if ((key || ours) && shown < 14) {
                        if (ln.length > 300) ln = [[ln substringToIndex:300] stringByAppendingString:@"…"];
                        RLog(@"[崩溃回放] %@", ln);
                        shown++;
                    }
                }
                if (shown == 0) RLog(@"[崩溃回放] 报告里没有匹配行(可能整篇 JSON, 长度 %lu)", (unsigned long)txt.length);
            } else {
                RLog(@"[崩溃回放] 报告读不出来(可能权限/格式)");
            }
        }

        /* 足迹回放: 崩溃前最后 30 步 */
        NSString *crumb = [NSString stringWithContentsOfFile:@"/var/mobile/Library/Logs/driftisland-crumb.log"
                                                    encoding:NSUTF8StringEncoding error:NULL];
        if (crumb.length) {
            NSArray *lines = [crumb componentsSeparatedByCharactersInSet:
                              [NSCharacterSet newlineCharacterSet]];
            NSUInteger n = lines.count;
            NSUInteger from = n > 30 ? n - 30 : 0;
            for (NSUInteger i = from; i < n; i++) {
                if (((NSString *)lines[i]).length) RLog(@"[足迹回放] %@", lines[i]);
            }
        } else {
            RLog(@"[足迹回放] 足迹文件为空/不存在");
        }
    } @catch (__unused NSException *e) {}
}

/* 3.1.0: 定义在后面, 这里先声明 —— 播放器每次 layout 顺手把「未在播放」收掉 */
static void diNPApplyHideForRoot(UIView *root);
/* 3.0.13: 高危钩子(模块背景/隐藏 + 传送栏 setFrame)延迟安装, 定义在后面 */
static void diArtInstallGated(void);
static void diArtInstallAVHook(void);   /* 3.0.17: 类级接管(定义在后) */

static void diArtKillJitter(UIView *root) {
    if (!diArtIs3x2()) return;
    /* 首轮 diArtInstall 时 MediaRemoteUI 可能还没加载, 这里补挂一次
       3.0.11: 保险引导下不补挂 */
    static BOOL tcTried = NO;
    if (!tcTried) {
        tcTried = YES;
        diArtInstallGated();   /* 3.0.13: 内部自带档位/引导满8秒门控 */
    }
    /* 3.0.15: 这里以前会递归清传送栏子树上的循环/自反动画(diArtStripSpin), 每轮布局都来
       一次 —— 系统的按钮出现/高亮动画被拦腰摘掉, 就是用户看到的"3×2 按钮一抖一下"。
       已经全部删除: 传送栏的图层动画一律不碰。 */
    UIView *tc = diArtTransportOf(root);
    if (!tc) return;
    static NSMutableSet *logged = nil;
    if (!logged) logged = [NSMutableSet set];
    NSString *key = NSStringFromClass(tc.class);
    if (![logged containsObject:key]) {
        [logged addObject:key];
        RLog(@"[抖动] 3×2 传送容器 %@ 动画=%@ frame=%@ 父=%@ (3.0.15 起不清理)",
             key, [tc.layer.animationKeys componentsJoinedByString:@","] ?: @"(无)",
             NSStringFromCGRect(tc.frame), NSStringFromClass(tc.superview.class));
    }
    /* 3.0.16: 被动记录(只读不改) —— 3×2 里传送栏和每个按钮的 frame 一变就记一行,
       最多 60 行。下次日志里如果出现 A→B→A 的来回, 就是系统自己在抖; 一直不动,
       说明看到的"抖"不是 frame 变化, 而是图层/动画层面的重绘。 */
    {
        static int flowLogs = 0;
        static NSString *lastSig = nil;
        if (flowLogs < 60) {
            NSMutableString *sig = [NSMutableString stringWithFormat:@"root=%@ tc=%@",
                NSStringFromCGRect(tc.superview ? tc.superview.bounds : CGRectZero),
                NSStringFromCGRect(tc.frame)];
            for (UIView *c in tc.subviews) {
                [sig appendFormat:@" | %@ %@", NSStringFromClass(c.class), NSStringFromCGRect(c.frame)];
            }
            if (!lastSig || ![lastSig isEqualToString:sig]) {
                lastSig = [sig copy];
                flowLogs++;
                RLog(@"[抖动2] %@", sig);
            }
        }
    }
}

/* 开关打开却一个封面候选都没找到时, 把播放器视图树记一次 —— 下一版按这个类名改 */
static void diArtLogTree(UIView *root) {
    if (gDIArtTreeLogged) return;
    gDIArtTreeLogged = YES;
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@ %.0fx%.0f |",
                          NSStringFromClass(root.class), root.bounds.size.width, root.bounds.size.height];
    NSMutableArray *stack = [NSMutableArray array];
    for (UIView *c in root.subviews) [stack addObject:@[c, @1]];
    int n = 0;
    while (stack.count && n < 60) {
        NSArray *pair = stack.lastObject; [stack removeLastObject];
        UIView *v = pair[0]; int d = [pair[1] intValue];
        [s appendFormat:@" %@(%.0fx%.0f)", NSStringFromClass(v.class),
                       v.bounds.size.width, v.bounds.size.height];
        n++;
        if (d < 4) for (UIView *c in v.subviews) [stack addObject:@[c, @(d + 1)]];
    }
    RLog(@"[封面] 播放器视图树| %@", s);
}

/* 3.0.12: 展开态导出一次完整视图树 —— 只为定位"有些封面没覆盖/未在播放找不到"
   到底差在哪个类上。写盘一份, 日志只报节点数, 不刷屏。 */
static void diDumpExpandedTreeOnce(UIView *root) {
    static BOOL done = NO;
    if (done || !root) return;
    if (root.bounds.size.width < 200 || root.bounds.size.height < 150) return;
    done = YES;
    /* 3.0.25(iOS17 首开): 400 节点类名+frame 拼字符串再落盘, 是首开那一秒的
       "主线程连续活"之一。往后放 3 秒, 完全错开初始化串; 只为定位问题, 晚没影响。 */
    __weak UIView *weakRoot = root;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *r = weakRoot;
        if (!r || !r.window) return;
        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"=== 播放器展开树 %@ %.0fx%.0f 3x2=%d ===\n", NSStringFromClass(r.class),
            r.bounds.size.width, r.bounds.size.height, diArtIs3x2()];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:@[r, @0]];
        int n = 0;
        while (stack.count && n < 400) {
            NSArray *pr = stack.lastObject; [stack removeLastObject];
            UIView *v = pr[0]; int d = [pr[1] intValue];
            NSString *ind = [@"" stringByPaddingToLength:(NSUInteger)(d * 2) withString:@" " startingAtIndex:0];
            NSString *extra = @"";
            if ([v isKindOfClass:UIImageView.class]) {
                UIImage *im = ((UIImageView *)v).image;
                extra = im ? [NSString stringWithFormat:@" img=%.0fx%.0f", im.size.width, im.size.height]
                           : @" img=nil";
            } else if ([v isKindOfClass:UILabel.class]) {
                NSString *t = ((UILabel *)v).text;
                if (t.length) extra = [NSString stringWithFormat:@" text=%@", t];
            }
            [s appendFormat:@"%@%@ %@ h=%d a=%.2f cr=%.1f%@\n", ind, NSStringFromClass(v.class),
                NSStringFromCGRect(v.frame), v.hidden, v.alpha, v.layer.cornerRadius, extra];
            n++;
            if (d < 7) for (UIView *c in v.subviews) [stack addObject:@[c, @(d + 1)]];
        }
        NSString *path = @"/var/mobile/Library/Logs/driftisland-tree.log";
        [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        RLog(@"[树] 已导出展开态视图树 %d 节点 → %@", n, path);
    });
}

static void diNPBackgroundTick(UIView *root);   /* 3.0.15: 定义在下面的 3.1.0 段 */

/* ===== 3.0.22: 3×2 传送栏"行对齐"(找到真凶了) =====
   435 日志把五个按钮的坐标原样打了出来, 一共有两组状态在来回切:

     tc={{24, 87.333}, {215, 44}}  按钮 y = 26.9007 / 30.1347
     tc={{24, 71},     {215, 44}}  按钮 y = 43.234  / 46.468

   关键: 26.9007 与 30.1347 相差 **3.234pt**, 而 3.234 = (44 − 44×0.853)/2 ——
   正是"按钮带着 0.853 缩放(37.532/44)时又被写了一次 frame"产生的偏移。
   也就是说: 系统对这条 5 按钮传送栏的布局每跑一次, 就有一次机会把三个中间按钮
   (上一首/播放/下一首)**整体上抬 3.234pt**, 下一次又落回 —— 半秒到一秒一次,
   跟用户从 3.0.9 就在说的"整条上跳几 pt、停一两帧又落回"完全一致。
   容器自己在 87.333 / 71 之间来回是带补偿的(绝对位置不变), 所以看不见; 看得见的
   只有这 3.234。

   前面的做法(关隐式动画、事后回正)都不对: 关动画只让跳变更生硬, 事后回正发生在
   CA 提交之后, 那一帧错的已经显示出来了。真正该做的是**在布局里、提交之前**把这行
   摆平, 而且只写图层(CALayer.position) —— 层属性不会触发 UIKit 再排一次版, 也就
   不会把上一帧的错位带到下一帧。

   做法: 每个按钮记一个"稳定中心"(窗口坐标)。窗口坐标下容器那 16.33pt 的来回会互相
   抵消, 只剩真正跳的 3.234pt; 偏离 0.75~6pt 就按稳定值写回(只写 layer.position),
   偏得多说明是展开/收起这类真变化, 认它并重建基准。系统排对了就一个数都不写。 */
static NSArray<UIView *> *diTBBtns(UIView *tc) {
    NSMutableArray<UIView *> *a = [NSMutableArray array];
    for (UIView *c in tc.subviews)
        if ([NSStringFromClass(c.class) containsString:@"TransportButton"]) [a addObject:c];
    return a;
}
@interface DITBRowState : NSObject
@property (nonatomic, assign) CGFloat stable;   /* 稳定中心(传送栏坐标系) */
@end
@implementation DITBRowState
@end
static const void *kDITBRowKey = &kDITBRowKey;

static void diTBNormalizeRow(UIView *tc) {
    if (!tc || !tc.window) return;
    if (!enabled || !diArtIs3x2()) return;
    NSArray<UIView *> *btns = diTBBtns(tc);
    if (btns.count < 3) return;
    if (tc.bounds.size.height < 8) return;
    int fixed = 0; CGFloat lastDy = 0;
    for (UIView *b in btns) {
        if (!b.window || b.hidden || !b.layer || !b.superview || b == tc) continue;
        /* 3.0.22: 必须在**窗口坐标**里量。容器自己会在 87.333 / 71 之间来回 16.33pt,
           而按钮在容器内的偏移正好反向补偿 —— 在容器坐标里看是"整体移动 16pt",
           在窗口坐标里才看得出真正跳的那 3.234pt。 */
        CGRect r = [b convertRect:b.bounds toView:nil];
        CGFloat cur = CGRectGetMidY(r);
        DITBRowState *st = objc_getAssociatedObject(b, kDITBRowKey);
        if (!st) {
            st = [DITBRowState new];
            st.stable = cur;
            objc_setAssociatedObject(b, kDITBRowKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            continue;
        }
        /* 差得更多 = 展开/收起/换排布这类真变化, 认它并重建基准 */
        if (fabs(cur - st.stable) > 6.0) { st.stable = cur; continue; }
        /* 那个 3.234 = (44 − 44×0.853)/2 的"多算一次居中"只会让按钮往上跑;
           所以看到更低(更对齐)的一版就记下来当基准, 然后永远对着基准摆平。 */
        if (cur > st.stable + 0.4) st.stable = cur;
        CGFloat dy = cur - st.stable;
        if (fabs(dy) < 0.6) continue;
        CGPoint mid = CGPointMake(CGRectGetMidX(r), st.stable);
        CGPoint tInSp = [[b window] convertPoint:mid toView:b.superview];
        CGPoint p = b.layer.position;
        p.y += (tInSp.y - b.center.y);
        b.layer.position = p;      /* 只写图层: 不触发 UIKit 再排一次版 */
        fixed++; lastDy = dy;
    }
    if (fixed > 0) {
        static int logs = 0;
        if (logs < 6) { logs++; RLog(@"[抖动7] 3×2 行对齐: 修正 %d 个按钮 dy=%.2f (容器 %.0fx%.0f)",
                                     fixed, lastDy, tc.bounds.size.width, tc.bounds.size.height); }
    }
}
/* ===== 3.0.31: 3×1 —— 播放/下一首两颗按钮右移一点点 =====
   用户圈的就是横向展开条右侧那三颗: 上一首(不动) / 播放(右移) / 下一首(右移)。
   系统每次布局都会把它们摆回原位, 所以按"基准 + 位移"摆:
     基准 = 系统第一次排出来的中心(窗口坐标), 目标 = 基准 + 9pt;
     cur≈applied(系统没动) → 不写;  cur≈base(系统摆回原位) → 推回目标;
     |cur−base|>40(换布局了) → 认新基准再推。不会越推越远。 */
static const void *kDI31ShiftKey = &kDI31ShiftKey;
@interface DI31ShiftState : NSObject
@property (nonatomic, assign) CGFloat base;      /* 系统原始中心 x(传送栏坐标系) */
@property (nonatomic, assign) CGFloat applied;   /* 我们摆好后的中心 x */
@property (nonatomic, assign) CGFloat rowW;      /* 3.0.35: 记基准时的栏宽, 栏宽真变了才重认 */
@end
@implementation DI31ShiftState
@end
/* 3.0.35: 只算"真的看得见、真的有宽度"的按钮。
   原来把 hidden / 0 宽占位也算进来再按 x 排序, 索引会随状态漂移 ——
   未播放时占位按钮多一颗, 位移落到别的按钮上(用户: "没播放时播放按钮乱跳");
   播放后内容重建、可见按钮数变少, 位移又落回原位(用户: "两个按钮又变回原位")。 */
static NSArray<UIView *> *diTBVisibleBtns(UIView *tc) {
    NSMutableArray<UIView *> *a = [NSMutableArray array];
    for (UIView *c in tc.subviews) {
        if (![NSStringFromClass(c.class) containsString:@"TransportButton"]) continue;
        if (c.hidden || c.alpha < 0.05) continue;
        if (c.frame.size.width < 10.0 || c.frame.size.height < 10.0) continue;
        [a addObject:c];
    }
    return [a sortedArrayUsingComparator:^NSComparisonResult(UIView *x, UIView *y) {
        if (x.center.x < y.center.x) return NSOrderedAscending;
        if (x.center.x > y.center.x) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}
/* 3.0.36: 只认"折叠的 3×1 模块"。祖先模块容器高 77 = 折叠态; 展开态是 568。
   用户明确要求"展开的全部不要动", 而 3.0.35 只看档位, 展开后那个传送栏也被推了 12pt。 */
static BOOL diNP31IsFoldedModule(UIView *v) {
    for (UIView *p = v; p; p = p.superview) {
        if ([NSStringFromClass(p.class) isEqualToString:@"CCUIContentModuleContainerView"]) {
            CGFloat h = p.bounds.size.height;
            return (h > 20.0 && h < 130.0);
        }
        if ([p isKindOfClass:UIWindow.class]) break;
    }
    return NO;
}
static void diNP31ShiftButtons(UIView *tc) {
    if (!tc || !tc.window || !enabled) return;
    if (![diNPLayoutKey() isEqualToString:@"3x1"]) return;
    if (!diNP31IsFoldedModule(tc)) return;      /* 展开态/锁屏/小岛: 一颗都不碰 */
    NSArray<UIView *> *btns = diTBVisibleBtns(tc);
    if (btns.count < 3) return;
    const CGFloat kShift = 12.0;
    NSUInteger n = btns.count;
    /* 播放键 = 离栏中心最近的那颗; 它右边第一颗就是"下一首"。
       3 颗(上一首/播放/下一首)和 5 颗(随机/上一首/播放/下一首/循环)两种形态都对。 */
    CGFloat mid = tc.bounds.size.width * 0.5;
    NSUInteger playIdx = 0;
    CGFloat best = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < n; i++) {
        CGRect ri = [btns[i] convertRect:btns[i].bounds toView:tc];
        CGFloat d = fabs(CGRectGetMidX(ri) - mid);
        if (d < best) { best = d; playIdx = i; }
    }
    NSUInteger targets[2] = { playIdx, playIdx + 1 };
    int moved = 0; CGFloat lastDx = 0;
    for (int t = 0; t < 2; t++) {
        NSUInteger i = targets[t];
        if (i >= n) continue;
        UIView *b = btns[i];
        if (!b.window || !b.layer) continue;
        /* 只避开"position 本身在动画"的时机(按下高亮)。以前是任何动画都跳过,
           而播放键常驻形变动画, 于是这帧不推、下帧推 —— 一帧原位一帧右移就是"乱跳"。 */
        BOOL posAnim = NO;
        for (NSString *k in b.layer.animationKeys) {
            if ([k isEqualToString:@"position"]) { posAnim = YES; break; }
        }
        if (posAnim) continue;
        CGRect rInTc = [b convertRect:b.bounds toView:tc];
        CGFloat cur = CGRectGetMidX(rInTc);
        DI31ShiftState *st = objc_getAssociatedObject(b, &kDI31ShiftKey);
        if (!st) {
            st = [DI31ShiftState new];
            st.base = cur;
            st.applied = cur;
            st.rowW = tc.bounds.size.width;
            objc_setAssociatedObject(b, &kDI31ShiftKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        /* 只有"整排真的换了布局"(偏差 >60)才重认基准。3.0.35 是按栏宽变化重认,
           而展开/收起动画里栏宽是连续变的, 每次变都把"已推过的位置"当成新基准再加
           12pt —— 越推越远, 这就是用户看到的乱跳。 */
        if (fabs(cur - st.base) > 60.0) { st.base = cur; st.applied = cur; }
        CGFloat target = st.base + kShift;
        CGFloat dx = target - cur;
        if (fabs(dx) < 0.5) continue;
        CGPoint p = b.layer.position;
        p.x += dx;                                  /* 只写图层: 不触发 UIKit 再排一次版 */
        b.layer.position = p;
        st.applied = target;
        moved++; lastDx = dx;
    }
    if (moved > 0) {
        static int logs = 0;
        if (logs < 6) { logs++; RLog(@"[3x1] 按钮右移 %d 个 dx=%.1f (栏 %.0fx%.0f, 可见 %lu)",
                                     moved, lastDx, tc.bounds.size.width, tc.bounds.size.height,
                                     (unsigned long)n); }
    }
}
/* 3.0.35: 从按钮往上找传送栏。原实现直接拿 b.superview 当传送栏, 按钮只要不是
   栏的直接子视图(嵌在 stack/容器里)就会 btns.count<3 直接跳过 —— 日志里表现为
   "[3x1] 按钮右移跳过: 只找到 N 个按钮", 看起来像"钩子没装", 其实是参数传错了。 */
static UIView *diNP31TCOf(UIView *b) {
    for (UIView *p = b.superview; p; p = p.superview) {
        if ([NSStringFromClass(p.class) containsString:@"TransportControls"]) return p;
        if ([p isKindOfClass:UIWindow.class]) break;
    }
    return nil;
}
/* 传送栏自己的 layoutSubviews: 系统排完立刻摆平(同一帧、提交前, 用户看不到中间态) */
static void (*gDIOrigTCRowLayout)(id, SEL) = NULL;
static void diTCRowLayout(id self, SEL cmd) {
    if (gDIOrigTCRowLayout) gDIOrigTCRowLayout(self, cmd);
    @try {
        diTBNormalizeRow((UIView *)self);
        diNP31ShiftButtons((UIView *)self);
    } @catch (__unused NSException *e) {}
}

/* ===== 3.0.25: 按钮残留抖动 —— 谁写错就当场纠正谁 =====
   438 日志: 行对齐只在 layoutSubviews 里跑已经不够了。[抖动3] 证明系统(以及
   NPROriginalRuntime/MediaControls)在 layoutSubviews **之外**还会对传送栏和按钮
   直接 setFrame/setTransform(按下按钮的 highlighted 动画就是一条典型路径) ——
   错的 frame 在两次布局之间要显示一两帧, 我们下一轮布局才纠正, 用户看到的就是
   "按下按钮抖一下, 比以前轻了但还是抖"。
   现在: 直接 hook 按钮(MRUTransportButton)和传送栏的 setFrame/setTransform,
   错的那一笔写完立刻在同一事务里摆平 —— 永远在 CA 提交之前, 中间态一帧都不会有。
   仍然是"只写 layer.position": 不触发 UIKit 重排, 也不会和系统抢 frame。
   基准(DITBRowState)只在行对齐跑过之后才有, 没基准 = 不归我们管, 零开销秒退。 */
static CGFloat diTBfixBtn(UIView *b) {
    if (!b || !b.window || b.hidden || !b.superview) return 0;
    if (!enabled || !diArtIs3x2()) return 0;
    DITBRowState *st = objc_getAssociatedObject(b, kDITBRowKey);
    if (!st) return 0;
    CGRect r = [b convertRect:b.bounds toView:nil];
    CGFloat cur = CGRectGetMidY(r);
    CGFloat dy = cur - st.stable;
    if (fabs(dy) > 6.0) { st.stable = cur; return 0; }   /* 真变化: 认它 */
    if (fabs(dy) < 0.6) return 0;
    CGPoint mid = CGPointMake(CGRectGetMidX(r), st.stable);
    CGPoint tInSp = [b.window convertPoint:mid toView:b.superview];
    CGPoint p = b.layer.position;
    p.y += (tInSp.y - b.center.y);
    b.layer.position = p;
    return dy;
}
static void (*gDIOrigBtnFrame)(id, SEL, CGRect) = NULL;
static void (*gDIOrigBtnTransform)(id, SEL, CGAffineTransform) = NULL;
static void diBtnFrameHook(id self, SEL cmd, CGRect f) {
    gDIOrigBtnFrame(self, cmd, f);
    @try {
        UIView *b = (UIView *)self;
        if (diArtIs3x2()) diTBfixBtn(b);
        else { UIView *tc = diNP31TCOf(b); if (tc) diNP31ShiftButtons(tc); }   /* 3.0.35: 从祖先找栏 */
    } @catch (__unused NSException *e) {}
}
static void diBtnTransformHook(id self, SEL cmd, CGAffineTransform t) {
    gDIOrigBtnTransform(self, cmd, t);
    @try {
        UIView *b = (UIView *)self;
        if (diArtIs3x2()) diTBfixBtn(b);
        else { UIView *tc = diNP31TCOf(b); if (tc) diNP31ShiftButtons(tc); }   /* 3.0.35: 从祖先找栏 */
    } @catch (__unused NSException *e) {}
}
static void (*gDIOrigTBFrame)(id, SEL, CGRect) = NULL;
static void (*gDIOrigTBTransform)(id, SEL, CGAffineTransform) = NULL;
static void diTBFrameHook(id self, SEL cmd, CGRect f) {
    gDIOrigTBFrame(self, cmd, f);
    @try {
        diTBNormalizeRow((UIView *)self);
        diNP31ShiftButtons((UIView *)self);
    } @catch (__unused NSException *e) {}
}
static void diTBTransformHook(id self, SEL cmd, CGAffineTransform t) {
    gDIOrigTBTransform(self, cmd, t);
    @try {
        diTBNormalizeRow((UIView *)self);
        diNP31ShiftButtons((UIView *)self);
    } @catch (__unused NSException *e) {}
}
static void diTBInstallRowHook(void) {
    static BOOL doneTC = NO, doneBtn = NO;
    if (doneTC && doneBtn) return;
    Class c = NSClassFromString(@"MRUNowPlayingTransportControlsView");
    if (c && !doneTC) {
        doneTC = YES;
        @try {
            Method m = class_getInstanceMethod(c, @selector(layoutSubviews));
            IMP before = m ? method_getImplementation(m) : NULL;
            MSHookMessageEx(c, @selector(layoutSubviews), (IMP)diTCRowLayout, (IMP *)&gDIOrigTCRowLayout);
            if (!gDIOrigTCRowLayout) gDIOrigTCRowLayout = (void (*)(id, SEL))before;
            /* 3.0.25: setFrame/setTransform 是 layoutSubviews 之外的第二个写入口 */
            MSHookMessageEx(c, @selector(setFrame:), (IMP)diTBFrameHook, (IMP *)&gDIOrigTBFrame);
            MSHookMessageEx(c, @selector(setTransform:), (IMP)diTBTransformHook, (IMP *)&gDIOrigTBTransform);
            RLog(@"[抖动7] 传送栏行对齐钩子已装(+setFrame/setTransform)");
        } @catch (__unused NSException *e) {}
    }
    Class bc = NSClassFromString(@"MRUTransportButton");
    if (bc && !doneBtn) {
        doneBtn = YES;
        @try {
            MSHookMessageEx(bc, @selector(setFrame:), (IMP)diBtnFrameHook, (IMP *)&gDIOrigBtnFrame);
            MSHookMessageEx(bc, @selector(setTransform:), (IMP)diBtnTransformHook, (IMP *)&gDIOrigBtnTransform);
            RLog(@"[抖动7] 按钮 setFrame/setTransform 纠正钩子已装");
        } @catch (__unused NSException *e) {}
    }
}
/* 播放器根视图这一侧再补一次(有些布局路径不走传送栏自己的 layoutSubviews) */
static void diTBNormalizeFromRoot(UIView *root) {
    if (!root || !root.window || !enabled || !diArtIs3x2()) return;
    diTBInstallRowHook();
    UIView *tc = diArtTransportOf(root);
    if (tc) diTBNormalizeRow(tc);
}

/* ===== 3.0.20: 所有"改东西"的动作搬出 layoutSubviews =====
   431/432 日志把 3×2 抖动的时序摆出来了: 每一次 [抖动3] 的 setFrame/setTransform
   爆发, 都紧跟在 [封面] 挂蒙版 / 隐藏未在播放 / 铺背景 之后 —— 因为这些都是在我们
   自己的 layoutSubviews 钩子里同步写的。写图层/写 hidden/挂子层都会让系统在**同一帧
   内**再排一次版, 那条 5 按钮的传送栏就被排了两遍: 视觉上就是"抖一下"。
   现在 layoutSubviews 里只做记账 + 投递一次 flush; 真正的写操作全部落到主队列,
   同一个 runloop 内合并成一次, 而且一定发生在系统这一次布局**之后**、CA 提交**之前**
   —— 画面效果完全一样, 但绝不会把布局重排插进系统的排版过程里。 */
static NSHashTable *gDIArtPending = nil;        /* 待处理的播放器根视图 */
static NSHashTable *gDIArtDressPending = nil;   /* 待挂蒙版的封面 */
static BOOL gDIArtFlushQueued = NO;

static void diArtPostFlush(UIView *root);
static BOOL diArtInControlCenter(UIView *v);   /* 定义在后面 */
static CFTimeInterval gDIArtLastFlush = 0;
static void diArtFlushRun(void) {
    gDIArtFlushQueued = NO;
    gDIArtLastFlush = CFAbsoluteTimeGetCurrent();
    NSArray<UIView *> *roots = gDIArtPending.allObjects;
    [gDIArtPending removeAllObjects];
    NSArray<UIView *> *arts = gDIArtDressPending.allObjects;
    [gDIArtDressPending removeAllObjects];
    for (UIView *r in roots) { @try { diArtPostFlush(r); } @catch (__unused NSException *e) {} }
    for (UIView *a in arts) {
        @try {
            if (!a.window || a.hidden || a.alpha < 0.05) continue;
            if (!diArtInControlCenter(a)) continue;
            if (diArtPrefOn()) diArtDress(a);
        } @catch (__unused NSException *e) {}
    }
}
static void diArtFlushQueue(void) {
    if (gDIArtFlushQueued) return;
    gDIArtFlushQueued = YES;
    /* 3.0.21(iOS17 卡死): 布局钩子每帧都来, 以前每次就排一个 flush —— 120Hz 动画期间
       主队列里同时压着上百个"重活块"(走树/挂蒙版/铺背景/隐藏标签), 主线程被自己的任务
       占满, SpringBoard 直接被 watchdog 判死。现在最多 12Hz, 多出来的合并成一次,
       晚到的那一帧仍然在 CA 提交前完成, 观感不变。 */
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    CFTimeInterval wait = 0;
    if (gDIArtLastFlush > 0) {
        CFTimeInterval dt = now - gDIArtLastFlush;
        if (dt < 0.08) wait = 0.08 - dt;
    }
    if (wait > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ diArtFlushRun(); });
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ diArtFlushRun(); });
    }
}
static void diArtScheduleDress(UIView *v) {
    if (!v) return;
    if (!gDIArtDressPending) gDIArtDressPending = [NSHashTable weakObjectsHashTable];
    [gDIArtDressPending addObject:v];
    diArtFlushQueue();
}
static void diArtPlayerPost(UIView *root) {
    /* ---- 轻量部分: 只记账 + 排一次 flush, 不碰任何图层/视图属性 ---- */
    if (![root isKindOfClass:UIView.class]) return;
    /* 灵动岛那套(MRUActivityNowPlayingView)可能继承自 MRUNowPlayingView, 会顺带命中
       这个 hook —— 岛上的头像是用户自己的遮罩素材在管, 这里绝不能碰。 */
    if ([NSStringFromClass(root.class) containsString:@"Activity"]) return;
    if (!gDIArtRoots) gDIArtRoots = [NSHashTable weakObjectsHashTable];
    [gDIArtRoots addObject:root];
    diArtInstallAVHook();   /* 3.0.17: 类晚出现时在这里补装, 幂等 */
    /* 无论开还是关, 都把播放器内置旋转关掉: 它不看我们的偏好键, 开着就会
       "开关关了照样转"。旋转统一由 diArtApply 负责。只做一次。 */
    {
        static BOOL nprDone = NO;
        if (!nprDone) { nprDone = YES; diArtDisableNPRSpin(); }
    }
    if (!gDIArtPending) gDIArtPending = [NSHashTable weakObjectsHashTable];
    [gDIArtPending addObject:root];
    diArtFlushQueue();
}

/* ---- 真正的刷新(在主队列、布局之外执行) ---- */
static void diArtPostFlush(UIView *root) {
    if (!root || !root.window) return;
    diPhase("art");
    BOOL on = diArtPrefOn();
    /* 3.0.15: 专辑背景跟着"播放器视图"走 —— 播放器视图本身就是各尺寸下的可见卡片
       (3×2 小卡 / 展开卡), 背景铺在它的 bounds 上, 换尺寸自动跟随, 不用再去猜卡片。
       只在图层层面插子层, 不动任何视图/约束。 */
    diPhase("bgput");
    @try { diNPBackgroundTick(root); } @catch (__unused NSException *e) {}
    diPhase("art");
    DIArtRootState *rs = objc_getAssociatedObject(root, kDIArtRootKey);
    if (!rs) {
        rs = [DIArtRootState new];
        objc_setAssociatedObject(root, kDIArtRootKey, rs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    /* 3.0.15: 删掉 3.0.14 那句"每 2 秒全树只清 rotation 动画" —— 它清的是系统给
       没被收集到的格子挂的原生旋转, 也是"专辑转着转着停了"的直接原因。 */
    gDIArtSawEmptyTile = NO;
    NSArray<UIView *> *arts = rs.arts;
    /* 3.0.21: 扫不到封面时以前是"每次 flush 都重扫全树"(没有 arts 就恒真) —— 12Hz ×
       1500 节点的 BFS, 主线程直接被自己占满。现在扫不到也要间隔 0.4 秒。 */
    CFTimeInterval scanGap = (!arts || !arts.count) ? 0.4 : 1.0;
    if (!arts || now - rs.scanTS > scanGap) {
        diPhase("collect");
        arts = diArtCollectIn(root);
        /* 3.0.15: 这一轮没收集到的旧封面不再"还原"(diArtApply:NO) —— 3×2 换页/换曲时
           视图会短暂离开收集结果, 一还原一重挂就是"转圈从起点重来 + 闪一下"。 */
        rs.arts = arts;
        rs.scanTS = now;
        if (!gDIArtSawEmptyTile) rs.recollects = 0;   /* 这轮没空格子, 重置重扫链 */
        /* 3.0.13: 有格子图还没加载完 → 0.8 秒后强制重扫一次(最多链 4 次),
           图片异步加载完成是布局系统不感知的, 不重扫就永远漏蒙 */
        if (gDIArtSawEmptyTile && rs.recollects < 4) {
            rs.recollects++;
            __weak UIView *w = root;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    if (!w.window) return;
                    DIArtRootState *rs2 = objc_getAssociatedObject(w, kDIArtRootKey);
                    if (rs2) rs2.scanTS = 0;   /* 强制重扫 */
                    diArtPlayerPost(w);
                } @catch (__unused NSException *e) {}
            });
        }
    }
    if (on) {
        /* 3.0.17: 累积"见过的封面" —— 3×2 换页/换曲时视图会短暂离开收集结果,
           以前一离开就没人再管它(或下一轮重挂 mask 闪一下)。现在只要见过一次就
           一直维护, 直到视图真的离开窗口。dress 是幂等的, 尺寸没变什么都不写。 */
        if (!gDIArtKnown) gDIArtKnown = [NSHashTable weakObjectsHashTable];
        for (__strong UIView *a in arts) [gDIArtKnown addObject:a];
        diPhase("mask");
        for (__strong UIView *a in gDIArtKnown.allObjects) {
            if (!a.window || a.hidden || a.alpha < 0.05) continue;
            @try { diArtDress(a); } @catch (__unused NSException *e) {}
        }
    } else {
        for (__strong UIView *a in arts) diArtApply(a, NO);
    }
    if (on && !arts.count) diArtLogTree(root);
    diArtKillJitter(root);
    /* 3.0.12: 「隐藏未在播放」恢复 —— 但不再在布局 pass 里同步走树:
       异步丢到主队列下一轮, 1 秒节流。模块容器钩子在本机(layout=0x0 那种早期
       形态)不一定命中, 播放器根视图这条路径才是稳的。 */
    {
        static CFTimeInterval lastHideTS = 0;
        CFTimeInterval hn = CFAbsoluteTimeGetCurrent();
        if (hn - lastHideTS > 1.0) {
            lastHideTS = hn;
            dispatch_async(dispatch_get_main_queue(), ^{
                diPhase("hidetext");
                @try { diNPApplyHideForRoot(root); } @catch (__unused NSException *e) {}
                diPhase("art");
            });
        }
    }
    /* 3.0.12: 展开态自动导出一次完整视图树(只为定位"有些封面没覆盖"), 写盘不刷屏 */
    /* 3.0.35: 只在开了日志时导出 —— 400 节点拼字符串 + 落盘是首开那一秒的"主线程
       连续活"之一, 交付版本不该无条件跑(交接文档 P1 也要求"交付前关掉")。 */
    if (logEnabled) diDumpExpandedTreeOnce(root);
    /* 3.0.20: 3×2 传送栏兜底回正 —— 布局已经跑完, 这里改几何不会插进系统的排版过程,
       写回去的这一下跟本帧一起提交, 用户看不到。 */
    diPhase("tb");
    @try { diTBNormalizeFromRoot(root); } @catch (__unused NSException *e) {}
    diPhase("idle");
    /* 3.0.17: 删掉"0.1 秒后再补一次(每 0.25s 触发)"。它在布局回调之后再往图层写一遍,
       等于把系统这一帧排好的排版动画打断重来 —— 3×2 那条传送栏的按钮就是这样
       "抖一下"。现在旋转/蒙版全部由 MRUArtworkView 的 layoutSubviews 钩子负责,
       天然每帧都在, 不需要事后补。 */
}

static void diArtNPLayout(id self, SEL cmd) {
    if (gDIArtOrigNPViewLayout) gDIArtOrigNPViewLayout(self, cmd);
    /* 3.0.36: 播放器视图自己排完就检查一次 3×1 收窄 —— 这是最靠前的时机:
       视图存在 = 模块已建好, 不再依赖"卡片有没有 window / 容器认不认得出"。 */
    @try { diNP31FitGroup((UIView *)self); } @catch (__unused NSException *e) {}
    @try { diArtPlayerPost((UIView *)self); } @catch (__unused NSException *e) {}
}
static void diArtCCLayout(id self, SEL cmd) {
    if (gDIArtOrigCCVCLayout) gDIArtOrigCCVCLayout(self, cmd);
    @try { diArtPlayerPost((UIView *)self); } @catch (__unused NSException *e) {}
}

/* ===== 3.1.0: 控制中心「专辑背景」+「隐藏未在播放」 =====
   参照 CCUIPlayer(com.susu.ccuiplayer) 的做法:
     · 挂 CCUIContentModuleContainerViewController 的 viewWillLayoutSubviews,
       认 moduleIdentifier == com.apple.mediaremote.controlcenter.nowplaying;
     · 专辑图不走播放器自己的渐变层, 而是从 MediaRemote 取
       kMRMediaRemoteNowPlayingInfoArtworkData, 铺成整块背景;
     · 「未在播放」是模块里的一条 UILabel, 按文字内容找出来直接隐藏。
   关键: 背景层插在"模块卡片视图"上(播放器视图的兄弟), 不插进播放器自己的
   视图树 —— 3.0.8 插进播放器里导致它每次 layout 都被重新排列, 整块布局都乱了。 */
static const void *kDIBgIVKey  = &kDIBgIVKey;
static const void *kDIBgDimKey = &kDIBgDimKey;
static const void *kDIBgLastKey = &kDIBgLastKey;   /* 3.0.10: 模块 VC 处理节流 */
static const void *kDIBgRKey    = &kDIBgRKey;      /* 3.0.15: 缓存圆角 */
static const void *kDIBgSizeKey = &kDIBgSizeKey;   /* 3.0.15: 缓存 host 尺寸 */
static const void *kDIBgRectKey = &kDIBgRectKey;   /* 3.0.15: 缓存背景矩形 */

static NSHashTable *gDIBgHosts = nil;       /* 模块内容容器(隐藏未在播放用) */
static NSHashTable *gDIBgPlayers = nil;     /* 3.0.15: 背景宿主 = 播放器视图(各尺寸的可见卡片) */
static UIImage *gDIBgImage = nil;
static NSData *gDIBgData = nil;          /* 3.0.14: 专辑图原始数据, 换曲判定用 */
static CFTimeInterval gDIBgFetchTS = 0;
static CFTimeInterval gDIBgLastReqTS = 0;   /* 3.0.15: 取图请求节流 */
static CFTimeInterval gDIBgPrefTS = 0;
static BOOL gDIBgOnCache = YES;
static BOOL gDIHideNP = NO;
static dispatch_source_t gDIBgTimer = NULL; /* 3.0.15: 换曲轮询(通知不可靠时的兜底) */

/* 3.0.23(iOS17 卡死的真正大头, 之前一直漏了):
   com.local.playerexact 是**别的进程**的偏好域, CFPreferences 对它没有进程内缓存,
   每读一个键就是一次到 cfprefsd 的同步 XPC。而 diNPTickPrefs 在 1Hz 的布局链路上,
   一次读 2 个键 —— 用户在设置里拨开关时, 设置进程正在高频写这个域, cfprefsd 一被
   占住, SpringBoard 主线程就跟着停(436 日志: "背景: 创建子层" 之后 61 秒空白然后
   重启; 崩溃报告里没有我们 = 被 watchdog 杀掉, 不是我们崩)。
   现在: 主线程只读**内存缓存**, 真正读盘全部在后台串行队列; 只有"用户真的动了开关"
   那一次(diArtChanged)才同步读一遍, 保证开关立刻生效。 */
static NSMutableDictionary<NSString *, NSNumber *> *diNPPrefCache(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}
static BOOL diNPPrefFlagRaw(NSString *key, BOOL def) {
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                      CFSTR("com.local.playerexact")));
    return [v isKindOfClass:NSNumber.class] ? [v boolValue] : def;
}
static void diNPPrefCachePut(NSString *key, BOOL v) {
    @synchronized (diNPPrefCache()) { diNPPrefCache()[key] = @(v); }
}
static BOOL diNPPrefFlag(NSString *key, BOOL def) {
    if (![NSThread isMainThread]) return diNPPrefFlagRaw(key, def);
    @synchronized (diNPPrefCache()) {
        NSNumber *n = diNPPrefCache()[key];
        if (n) return n.boolValue;
    }
    BOOL v = diNPPrefFlagRaw(key, def);
    diNPPrefCachePut(key, v);
    return v;
}
static void diNPLoadPrefsSync(void) {
    /* 3.0.27(iOS17 首装卡死): 注入后 15 秒内不同步读跨进程域 —— 设置页首开正在
       高频写 com.local.playerexact, cfprefsd 被占住时这几条 XPC 就是主线程停摆
       (441: 阶段=prefs 停摆 4~7 秒)。这 15 秒内走后台 1Hz 缓存的值, 拨开关最多
       晚 1 秒生效;过了保护期恢复"用户动开关立刻同步读"。 */
    static CFAbsoluteTime firstCall = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (firstCall == 0) firstCall = now;
    if (now - firstCall < 15.0) return;
    BOOL on = diNPPrefFlagRaw(@"MusicArtworkGradientEnabled", YES);
    BOOL hid = diNPPrefFlagRaw(@"HideNotPlaying", NO);
    diNPPrefCachePut(@"MusicArtworkGradientEnabled", on);
    diNPPrefCachePut(@"HideNotPlaying", hid);
    gDIBgOnCache = on;
    gDIHideNP = hid;
}
static void diNPTickPrefs(void) {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gDIBgPrefTS < 1.0) return;
    gDIBgPrefTS = now;
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.abgg332.di.npflag", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(q, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    dispatch_async(q, ^{
        BOOL on = diNPPrefFlagRaw(@"MusicArtworkGradientEnabled", YES);
        BOOL hid = diNPPrefFlagRaw(@"HideNotPlaying", NO);
        diNPPrefCachePut(@"MusicArtworkGradientEnabled", on);
        diNPPrefCachePut(@"HideNotPlaying", hid);
        dispatch_async(dispatch_get_main_queue(), ^{
            gDIBgOnCache = on;
            gDIHideNP = hid;
        });
    });
}

/* ---------- MediaRemote: 取当前专辑图 ---------- */
static void (*gMRGetNowPlayingInfo)(dispatch_queue_t, void (^)(CFDictionaryRef)) = NULL;
static void (*gMRRegisterNotes)(dispatch_queue_t) = NULL;
static CFStringRef *gMRArtworkKeyPtr = NULL;
static CFStringRef *gMRRateKeyPtr = NULL;      /* 3.0.17: 播放速率, 判断"暂停/停止" */
static CFStringRef *gMRTitleKeyPtr = NULL;
static BOOL gMRTried = NO;

static void diNPLoadMediaRemote(void) {
    if (gMRTried) return;
    gMRTried = YES;
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) h = dlopen(NULL, RTLD_NOW);
    if (!h) return;
    *(void **)&gMRGetNowPlayingInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    *(void **)&gMRRegisterNotes = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    gMRArtworkKeyPtr = (CFStringRef *)dlsym(h, "kMRMediaRemoteNowPlayingInfoArtworkData");
    gMRRateKeyPtr = (CFStringRef *)dlsym(h, "kMRMediaRemoteNowPlayingInfoPlaybackRate");
    gMRTitleKeyPtr = (CFStringRef *)dlsym(h, "kMRMediaRemoteNowPlayingInfoTitle");
    /* 3.0.15: 不注册的话 kMRMediaRemoteNowPlayingInfoDidChangeNotification 根本不会
       投递到 Darwin 通知中心 —— 这是"切歌背景不跟着换"的根因之一。 */
    if (gMRRegisterNotes) {
        @try { gMRRegisterNotes(dispatch_get_main_queue()); RLog(@"[背景] 已向 MediaRemote 注册播放通知"); }
        @catch (__unused NSException *e) {}
    }
    if (!gMRGetNowPlayingInfo)
        RLog(@"[背景] MediaRemote 取不到 MRMediaRemoteGetNowPlayingInfo, 背景暂不可用");
}

static void diNPRefreshBackgrounds(void);
static void diNPStartBgTimer(void);   /* 3.0.15: 定义在模块容器钩子之后 */

/* 3.0.23: 在后台把专辑图缩到 640 长边并**强制解码**。
   600x600 的原图在 3x 屏上被 CA 当成 1800x1800 的纹理, 4×2 一次要铺 4 个宿主 =
   近百 MB 纹理; iOS17 的 SpringBoard 直接就被 watchdog 带走(436 日志: "背景: 创建
   子层" 那一行之后 61 秒空白, 然后重启, 崩溃报告里没有我们 = 被系统杀掉, 不是崩)。
   缩图 + 预解码都放在后台队列, 主线程只剩一次已解码 CGImage 的赋值。 */
static UIImage *diNPDownscaleImage(UIImage *img, CGFloat maxSide) {
    if (!img) return nil;
    CGSize s = img.size;
    if (s.width < 1 || s.height < 1) return img;
    CGFloat k = MIN(1.0, maxSide / MAX(s.width, s.height));
    CGSize t = CGSizeMake(MAX(1.0, round(s.width * k)), MAX(1.0, round(s.height * k)));
    UIGraphicsBeginImageContextWithOptions(t, YES, 1.0);
    UIImage *out = nil;
    @try {
        [img drawInRect:CGRectMake(0, 0, t.width, t.height)];
        out = UIGraphicsGetImageFromCurrentImageContext();
    } @catch (__unused NSException *e) {}
    UIGraphicsEndImageContext();
    return out ?: img;
}

static void diNPFetchArtwork(void) {
    if (gDIStage < 1) return;   /* 档位 0: 不取图 */
    CFTimeInterval rnow = CFAbsoluteTimeGetCurrent();
    if (rnow - gDIBgLastReqTS < 0.8) return;   /* 3.0.15: 通知+轮询+布局三路都会来, 合并 */
    gDIBgLastReqTS = rnow;
    diNPLoadMediaRemote();
    if (!gMRGetNowPlayingInfo) { diCrumb(@"取图: 符号缺失, 放弃"); return; }
    gMRGetNowPlayingInfo(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(CFDictionaryRef info) {
        /* 3.0.10: 回调在后台队列, 整体兜 @try + autoreleasepool —— 这里出任何异常
           都不能带崩 SpringBoard */
        @autoreleasepool { @try {
            NSData *data = nil;
            if (info) {
                CFStringRef key = (gMRArtworkKeyPtr && *gMRArtworkKeyPtr) ? *gMRArtworkKeyPtr : NULL;
                if (key) {
                    id v = (__bridge id)CFDictionaryGetValue(info, key);
                    if ([v isKindOfClass:NSData.class] && [((NSData *)v) length] > 64) data = v;
                }
            }
            /* 3.0.17: 「背景要跟专辑头像一样」—— 歌曲暂停/停止后背景必须回到默认。
               以前只认 artworkData, 而暂停时这首曲子的图还在, 于是背景一直挂着。
               现在读 PlaybackRate: 有值且 <= 0 就是停/暂停, 直接清空。 */
            BOOL playing = YES;
            if (info) {
                if (gMRRateKeyPtr && *gMRRateKeyPtr) {
                    id rv = (__bridge id)CFDictionaryGetValue(info, *gMRRateKeyPtr);
                    if ([rv isKindOfClass:NSNumber.class]) playing = ([rv doubleValue] > 0.01);
                } else if (gMRTitleKeyPtr && *gMRTitleKeyPtr) {
                    id tv = (__bridge id)CFDictionaryGetValue(info, *gMRTitleKeyPtr);
                    playing = (tv != NULL);
                }
            } else {
                playing = NO;   /* 连 now playing 都没有 = 没有在放 */
            }
            if (!playing) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        if (!gDIBgImage && !gDIBgData) return;
                        gDIBgImage = nil;
                        gDIBgData = nil;
                        diNPRefreshBackgrounds();
                        RLog(@"[背景] 暂停/停止 → 收起专辑背景, 恢复默认外观");
                    } @catch (__unused NSException *e) {}
                });
                return;
            }
            /* 3.0.16: 先比数据再解码 —— 轮询变快以后每次都解一张 600x600 太重 */
            NSData *prev = gDIBgData;
            BOOL same = (data && prev && [data isEqualToData:prev]);
            UIImage *img = (data && !same) ? diNPDownscaleImage([UIImage imageWithData:data], 640.0) : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (!img) {
                        /* 3.0.14: 取不到图(该曲无封面/未播放) → 保留现有背景, 不清空 */
                        static CFTimeInterval lastNone = 0;
                        if (!gDIBgImage && CFAbsoluteTimeGetCurrent() - lastNone > 30.0) {
                            lastNone = CFAbsoluteTimeGetCurrent();
                            RLog(@"[背景] 取不到专辑图(未播放/无封面), 保持当前背景");
                        }
                        return;
                    }
                    if (data && gDIBgData && [data isEqualToData:gDIBgData]) {
                        return;   /* 同一张专辑图, 不重铺 */
                    }
                    gDIBgData = data;
                    gDIBgImage = img;
                    diNPRefreshBackgrounds();
                    RLog(@"[背景] 专辑图 %@ (数据 %lu 字节)", [NSString stringWithFormat:@"%.0fx%.0f", img.size.width, img.size.height],
                         (unsigned long)data.length);
                } @catch (NSException *e) { diCrumb([NSString stringWithFormat:@"取图: 主线程异常 %@", e.reason]); }
            });
        } @catch (NSException *e) { diCrumb([NSString stringWithFormat:@"取图: 回调异常 %@", e.reason]); } }
    });
    /* 3.0.15: 这条路径现在每 1.5 秒跑一次, 不再写足迹文件(每次 4 行会拖慢主线程) */
}

/* ---------- 背景层(3.0.11 改 CALayer 子层) ----------
   3.1.0/3.0.10 用 insertSubview 往模块内容视图里塞 UIImageView —— 模块容器自己
   管理子视图的次序/约束, 我们插进去它下一轮布局就重排/崩溃。改用 CALayer 子层:
   插到 host.layer 最底层, 渲染效果一样, 但完全绕开 UIKit 的视图管理簿记。

   3.0.15: 背景矩形不再"找卡片" —— 直接铺满宿主(播放器视图)的 bounds。
   播放器视图本身就是当前尺寸下的可见卡片: 3×2 小卡、展开大卡、折叠态, 尺寸一变
   它跟着变, 背景实时跟随, 也就不会再出现"展开显示太长 / 起点偏下 / 直角"这三种错位。
   圆角单独找: 最近的、能包住宿主的祖先圆角, 或宿主内部铺满的材质层圆角, 都没有才估算。 */
static void diNPGeometryFor(UIView *host, CGRect *outRect, CGFloat *outR, NSString **outSrc) {
    CGRect rect = host.bounds;
    CGFloat r = host.layer.cornerRadius;
    NSString *src = (r >= 6.0) ? NSStringFromClass(host.class) : nil;
    CGFloat hostArea = host.bounds.size.width * host.bounds.size.height;
    /* ① 最近的、把宿主整个包住、而且只比宿主大一点点的祖先 = 卡片本体。
          用它的矩形+圆角(播放器常有几 pt 内边距, 背景要铺到卡片边才算对)。 */
    UIView *a = host.superview;
    for (int i = 0; a && i < 4; i++, a = a.superview) {
        CGFloat cr = a.layer.cornerRadius;
        CGSize s = a.bounds.size;
        CGFloat area = s.width * s.height;
        if (cr >= 6.0 && hostArea > 1
            && area >= hostArea * 0.9 && area <= hostArea * 1.45) {
            rect = [a convertRect:a.bounds toView:host];
            r = cr;
            src = NSStringFromClass(a.class);
            break;
        }
    }
    /* ② 祖先太大(整块 CC 面板) → 只借圆角, 矩形还是用宿主自己的 */
    if (!src) {
        UIView *b = host.superview;
        for (int i = 0; b && i < 4; i++, b = b.superview) {
            CGFloat cr = b.layer.cornerRadius;
            CGSize s = b.bounds.size;
            if (cr >= 6.0 && (hostArea <= 1 || s.width * s.height >= hostArea * 0.9)) {
                r = cr;
                src = NSStringFromClass(b.class);
                break;
            }
        }
    }
    if (!src) {
        /* ② 卡片把圆角挂在内层材质视图(MTMaterialView 之类)上 */
        NSMutableArray *q = [NSMutableArray arrayWithObject:host];
        int budget = 200;
        while (q.count && budget-- > 0) {
            UIView *v = q.firstObject; [q removeObjectAtIndex:0];
            if (v != host && !v.hidden) {
                CGFloat cr = v.layer.cornerRadius;
                CGSize s = v.bounds.size;
                if (cr >= 6.0 && hostArea > 1 && s.width * s.height >= hostArea * 0.85) {
                    r = cr;
                    src = NSStringFromClass(v.class);
                    break;
                }
            }
            for (UIView *c in v.subviews) [q addObject:c];
        }
    }
    if (!src || r < 6.0) {
        CGFloat side = MIN(host.bounds.size.width, host.bounds.size.height);
        r = MIN(MAX(side * 0.16, 18.0), 40.0);
        src = @"估算";
    }
    *outRect = rect;
    *outR = r;
    if (outSrc) *outSrc = src;
}

static int gDIBgSlowCount = 0;
static BOOL gDIBgStopped = NO;      /* 3.0.21: 本进程内停用专辑背景(连续超时保护) */
static void diNPApplyBackgroundTo(UIView *host, BOOL on) {
    if (gDIBgStopped && on) return;
    diPhase("bgwrite");
    CFTimeInterval tBG = CFAbsoluteTimeGetCurrent();
    @try {
        if (![host isKindOfClass:UIView.class] || !host.window) return;
        CALayer *bg = objc_getAssociatedObject(host, kDIBgIVKey);
        CALayer *dim = objc_getAssociatedObject(host, kDIBgDimKey);
        if (!on || !gDIBgImage) {
            bg.hidden = YES;
            dim.hidden = YES;
            return;
        }
        CGRect rect = host.bounds;
        if (rect.size.width < 40 || rect.size.height < 40) return;   /* 占位尺寸不铺 */

        /* 3.0.15: 几何(矩形+圆角)只在"尺寸变了 / 还没有层"时重算并缓存 —— 尺寸没变时
           反复量只会让背景跟着布局抖动反复改。 */
        NSValue *sz = objc_getAssociatedObject(host, kDIBgSizeKey);
        CGFloat r = [objc_getAssociatedObject(host, kDIBgRKey) doubleValue];
        BOOL needGeo = (!bg || !sz || !CGSizeEqualToSize(sz.CGSizeValue, rect.size));
        NSString *srcName = nil;
        NSValue *rv = objc_getAssociatedObject(host, kDIBgRectKey);
        if (!needGeo && rv) rect = rv.CGRectValue;   /* 尺寸没变就沿用上次量的矩形 */
        if (needGeo) {
            @try { diNPGeometryFor(host, &rect, &r, &srcName); }
            @catch (__unused NSException *e) { rect = host.bounds; r = 22.0; srcName = @"兜底"; }
            objc_setAssociatedObject(host, kDIBgRKey, @(r), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(host, kDIBgSizeKey, [NSValue valueWithCGSize:host.bounds.size],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(host, kDIBgRectKey, [NSValue valueWithCGRect:rect],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            static int geoLogs = 0;
            if (geoLogs < 10) {
                geoLogs++;
                RLog(@"[背景] 几何: 宿主 %.0fx%.0f → %.0fx%.0f@(%.0f,%.0f) 圆角%.1f (来源 %@, %@)",
                     host.bounds.size.width, host.bounds.size.height,
                     rect.size.width, rect.size.height, rect.origin.x, rect.origin.y,
                     r, srcName ?: @"?", NSStringFromClass(host.class));
            }
        }
        if (r < 6.0) r = 22.0;

        if (!bg) {
            diCrumb([NSString stringWithFormat:@"背景: 创建子层 %@ %.0fx%.0f 圆角%.1f",
                     NSStringFromClass(host.class), rect.size.width, rect.size.height, r]);
            bg = [CALayer layer];
            bg.contentsGravity = kCAGravityResizeAspectFill;
            /* 3.0.23: 必须 1.0 —— 默认跟着屏幕 3x, 600pt 的图会被撑成 1800x1800 的
               backing store(iOS17 上这一手直接几十 MB 一次)。 */
            bg.contentsScale = 1.0;
            bg.masksToBounds = YES;
            diNoImplicitActions(bg);
            [host.layer insertSublayer:bg atIndex:0];
            objc_setAssociatedObject(host, kDIBgIVKey, bg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            dim = [CALayer layer];
            dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.22].CGColor;
            dim.masksToBounds = YES;
            diNoImplicitActions(dim);
            [host.layer insertSublayer:dim above:bg];
            objc_setAssociatedObject(host, kDIBgDimKey, dim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        bg.hidden = NO;
        dim.hidden = NO;
        bg.cornerRadius = r;
        dim.cornerRadius = r;
        if (!CGRectEqualToRect(bg.frame, rect)) {
            bg.frame = rect;
            dim.frame = rect;
        }
        if (bg.contents != (__bridge id)gDIBgImage.CGImage)
            bg.contents = (__bridge id)gDIBgImage.CGImage;
    } @catch (NSException *e) { diCrumb([NSString stringWithFormat:@"背景: 异常 %@", e.reason]); }
    /* 3.0.21: 这一手在 iOS17 上曾经把主线程按死(日志最后一行就是"专辑图 600x600",
       紧接着 65 秒空白 + watchdog 注销)。现在给它计时: 单次超过 300ms 就记一笔, 连续
       三次直接本进程内停用背景 —— 宁可这次不显示背景, 也不能把 SpringBoard 拖死。 */
    CFTimeInterval used = CFAbsoluteTimeGetCurrent() - tBG;
    if (used > 0.25 && !gDIBgStopped) {
        gDIBgSlowCount++;
        RLog(@"[卡死] 铺背景耗时 %.0f ms (第 %d 次, 宿主 %@)",
             used * 1000.0, gDIBgSlowCount, NSStringFromClass(host.class));
        /* 3.0.23: 从"连续 3 次"改成"单次就停"。一次 400ms 的主线程卡顿已经足以
           让用户在控制中心里"顿住", 而连按三次才停意味着用户要先被卡三次。
           停用只影响本进程, 注销后自动恢复; 下次日志里会有一行"已停用"。 */
        if (used > 0.4 || gDIBgSlowCount >= 3) {
            gDIBgStopped = YES;
            for (UIView *h in gDIBgPlayers.allObjects) diNPApplyBackgroundTo(h, NO);
            RLog(@"[卡死] 专辑背景已在本进程内停用(单次 %.0f ms)", used * 1000.0);
        }
    }
}

/* 3.0.15: 每次播放器布局都调一次 —— 背景尺寸跟着宿主走, 换尺寸当帧生效 */
static void diNPBackgroundTick(UIView *root) {
    if (!root || !root.window) return;
    diNPTickPrefs();
    if (!gDIBgPlayers) gDIBgPlayers = [NSHashTable weakObjectsHashTable];
    [gDIBgPlayers addObject:root];
    /* 3.0.16: 不在 layoutSubviews 里直接动图层 —— 丢到下一轮 runloop, 16ms 合并一次。
       3×2 那套布局在系统排版里还要再算一遍, 我们插进去改图层会让它这一帧多排一次,
       表现就是"整条按钮抖一下"。 */
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    static CFTimeInterval lastReq = 0;
    if (now - lastReq > 0.016) {
        lastReq = now;
        __weak UIView *w = root;
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                UIView *h = w;
                if (!h || !h.window) return;
                if (!gDIBgOnCache) { diNPApplyBackgroundTo(h, NO); return; }
                diNPApplyBackgroundTo(h, gDIBgImage != nil);
            } @catch (__unused NSException *e) {}
        });
    }
    /* 图还没拿到时也别每帧都发 XPC */
    if (now - gDIBgFetchTS > 2.0) {
        gDIBgFetchTS = now;
        diNPFetchArtwork();
    }
}

static void diNPRefreshBackgrounds(void) {
    diNPTickPrefs();
    /* 3.0.23(iOS17 卡死): 以前是一次性把所有宿主铺完。4×2 有 4 个格子 + 展开卡,
       同一轮 runloop 里连做 5 次"插层 + 设内容", 主线程直接被按住(436 日志里
       开关拨下去那一秒之后就是 61 秒空白 + 重启)。现在一个一个来, 每次隔 24ms,
       每个之间还给主线程留机会跑布局 —— 用户最多觉得"背景淡入晚了半拍"。 */
    NSArray<UIView *> *hosts = gDIBgPlayers.allObjects;
    NSUInteger idx = 0;
    for (UIView *host in hosts) {
        __weak UIView *w = host;
        NSUInteger k = idx++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.024 * k * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                UIView *h = w;
                if (!h || !h.window) return;
                diNPApplyBackgroundTo(h, gDIBgOnCache && gDIBgImage != nil);
            } @catch (__unused NSException *e) {}
        });
    }
}

/* ---------- 隐藏「未在播放」 ---------- */
static void diNPHideNotPlayingLabels(UIView *root, BOOL hide) {
    if (!root) return;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int budget = 2500;
    while (stack.count && budget-- > 0) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:UILabel.class]) {
            UILabel *lb = (UILabel *)v;
            NSMutableString *t = [NSMutableString string];
            if (lb.text.length) [t appendString:lb.text];
            if (lb.attributedText.length) [t appendString:lb.attributedText.string];
            if (t.length && ([t containsString:@"未在播放"] || [t containsString:@"Not Playing"]
                             || [t containsString:@"Nothing Playing"])) {
                if (v.hidden != hide) v.hidden = hide;
            }
        }
        for (UIView *c in v.subviews) {
            /* 3.0.17: 不往传送栏/音量/进度这些控件子树里钻 —— 在那里写 hidden 会让
               系统判定需要重排, 3×2 的 5 个按钮就跟着"抖一下"。这些子树里也不会有
               "未在播放"文案。 */
            NSString *cn = NSStringFromClass(c.class);
            /* 3.0.21: 去掉 "Header" / "Button" 两条跳过 —— "未在播放" 这行字就在
               标题区里, 跳过 Header 等于把开关关掉了(用户 433 反馈"打开也不隐藏了")。
               这里本来就只对**文案匹配的 UILabel** 写 hidden, 而且只在值真的变化时写,
               写一次之后就是空操作, 不会再触发重排。 */
            if ([cn containsString:@"Transport"] || [cn containsString:@"Stepper"]
                || [cn containsString:@"Slider"] || [cn containsString:@"VolumeControls"]
                || [cn containsString:@"TimeControls"] || [cn containsString:@"CAPackage"]) continue;
            [stack addObject:c];
        }
    }
}

static void diNPApplyHideForRoot(UIView *root) {
    diNPTickPrefs();
    diNPHideNotPlayingLabels(root, gDIHideNP);
}

/* ---------- 模块容器钩子 ---------- */
static void (*gDIOrigModuleLayout)(id, SEL) = NULL;

static void diNPHandleModuleVC(id vc) {
    if (gDIStage < 1) return;
    NSString *ident = nil;
    @try { ident = [vc valueForKey:@"moduleIdentifier"]; } @catch (__unused NSException *e) {}
    if (![ident isKindOfClass:NSString.class] || ![ident containsString:@"nowplaying"]) return;

    /* 模块内容视图(播放器视图的父级)最底层: 与播放器平级, 又不插进播放器自己的树 ——
       3.0.8 直接把背景插进播放器视图, 它每次 layout 都重排子视图, 整块布局被带崩。 */
    UIView *card = nil;
    @try {
        id cv = [vc valueForKey:@"moduleContentView"];
        if ([cv isKindOfClass:UIView.class]) card = cv;
    } @catch (__unused NSException *e) {}
    if (!card) {
        @try {
            id cv = [vc valueForKey:@"containerView"];
            if ([cv isKindOfClass:UIView.class]) card = cv;
        } @catch (__unused NSException *e) {}
    }
    if (!card) card = [(UIViewController *)vc view];
    if (![card isKindOfClass:UIView.class]) return;
    /* 3.0.35: 3×1 收窄挪到"必须有 window / 尺寸够大"两个检查**之前**。
       现象(用户): 注销后第一次打开控制中心还是满宽 4×1, 要展开一下才变 3×1。
       原因就在这两行 return 上: 注销后首开时模块卡片往往还没接进视图树(window=nil)、
       尺寸还是 0×0, 而这条路径是全场**唯一**靠 moduleIdentifier 精确认出播放器模块的
       地方 —— 它一 return, 标记就打不上; 后面 setFrame/layout 的所有兜底都要靠标记或
       四级识别, 而那时容器上没有 identifier、内容也还没加载, 四级全不命中。
       等用户展开 → 内容重建、window 有了 → 才第一次收窄, 正好就是用户看到的现象。
       这里既然已经认准是播放器模块, 先把标记打上(宽度为零也不影响), 后面 setFrame
       钩子从第一帧就能按标记收窄, 用户看不到 4×1 的中间态。 */
    if ([diNPLayoutKey() isEqualToString:@"3x1"]) {
        diNP31ApplyModule(card);
        @try {
            UIView *vv = [(UIViewController *)vc view];
            if (vv && vv != card
                && [NSStringFromClass(vv.class) isEqualToString:@"CCUIContentModuleContainerView"]) {
                /* 卡片还没进树时, ApplyModule 顺着 superview 找不到外层容器, 这里补上 */
                diNP31Mark(vv);
                diNP31FitBox(vv);
            }
        } @catch (__unused NSException *e) {}
    }
    if (!card.window) return;
    /* 3.0.10: 启动早期卡片的占位尺寸(0x0 / 极小)一律不处理, 等真正排出来再说 */
    CGSize cs = card.bounds.size;
    if (cs.width < 40 || cs.height < 40) return;
    static int cardLogs = 0;
    if (cardLogs < 3) {
        cardLogs++;
        diCrumb([NSString stringWithFormat:@"模块: 卡片 %@ %.0fx%.0f",
                 NSStringFromClass(card.class), cs.width, cs.height]);
    }

    if (!gDIBgHosts) gDIBgHosts = [NSHashTable weakObjectsHashTable];
    [gDIBgHosts addObject:card];

    /* 3.0.30: 3×1 —— 这里已经按 moduleIdentifier 认准是播放器模块了, 直接给卡片和
       外层模块容器打标记并收窄; 其他模块(天气/手电)走不到这儿, 不会被误伤。
       3.0.35: 调用点上移到 window/尺寸检查之前(见上面的注释), 这里不再重复。 */

    diNPTickPrefs();
    diNPStartBgTimer();
    diNPHideNotPlayingLabels(card, gDIHideNP);

    if (gDIBgOnCache) {
        /* 3.0.15: 取图交给 1.5 秒轮询 + 通知, 这里只做兜底(没有播放器宿主时才铺容器) */
        CFTimeInterval fnow = CFAbsoluteTimeGetCurrent();
        if (fnow - gDIBgFetchTS > 2.0) {
            gDIBgFetchTS = fnow;
            diNPFetchArtwork();
        }
        if (!gDIBgPlayers || gDIBgPlayers.count == 0) {
            CGFloat ratio = cs.height > 1 ? cs.width / cs.height : 1.0;
            /* 容器可能比可见卡片高很多(展开态整条), 只有形状像卡片时才兜底铺 */
            if (ratio > 0.4 && ratio < 2.6 && cs.width <= 460 && cs.height <= 460) {
                diCrumb(@"模块: 铺背景前(容器兜底)");
                diNPApplyBackgroundTo(card, YES);
                diCrumb(@"模块: 铺背景后");
            }
        }
    } else {
        diNPApplyBackgroundTo(card, NO);
    }
}

/* 3.0.14: 播放信息变化通知 —— 之前只在构造器里注册且被保险门控, 一旦那次没注册上
   (或档位为 0), 之后切歌就永远不刷新。改成幂等函数, 构造器和延迟安装各调一次。 */
static void diNPMediaChanged(CFNotificationCenterRef c, void *obs, CFStringRef name,
                             const void *obj, CFDictionaryRef info);   /* 定义在后面 */
static BOOL gDIMediaObserved = NO;
static void diNPInstallMediaObserver(void) {
    if (gDIMediaObserved) return;
    gDIMediaObserved = YES;
    @try {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            diNPMediaChanged, CFSTR("kMRMediaRemoteNowPlayingInfoDidChangeNotification"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        RLog(@"[背景] 换歌通知已监听");
    } @catch (__unused NSException *e) { gDIMediaObserved = NO; }
}

/* 3.0.15: 换曲轮询 —— 通知在 iOS 16 上经常收不到(没注册/被系统吞掉), 之前背景只在
   "模块重新布局"时才会复核, 用户放歌时布局不动 → 背景永远停在上一首。这里 1.5 秒
   问一次现在播放什么, 拿到的 artworkData 和手上的一样就什么都不做(不重铺不闪)。 */
static void diNPStartBgTimer(void) {
    if (gDIBgTimer) return;
    if (gDIStage < 1) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                dispatch_get_main_queue());
    if (!t) return;
    dispatch_source_set_timer(t,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                              (uint64_t)(0.8 * NSEC_PER_SEC),
                              (uint64_t)(0.2 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, ^{
        @try {
            if (gDIStage < 1) return;
            diNPTickPrefs();
            if (!gDIBgOnCache) return;
            if (!gDIBgPlayers || gDIBgPlayers.count == 0) return;
            diNPFetchArtwork();
        } @catch (__unused NSException *e) {}
    });
    gDIBgTimer = t;
    dispatch_resume(t);
    RLog(@"[背景] 换曲轮询已启动(0.8s)");
}

static void diNPModuleLayout(id self, SEL cmd) {
    if (gDIOrigModuleLayout) gDIOrigModuleLayout(self, cmd);
    diNPInstall3x1Hook();   /* 3.0.28: 类晚加载时在这里补装(已装则立即返回) */
    /* 3.0.35 诊断: "3×1 不生效"最常见的两种, 日志里必须能一眼分开 ——
       ① 域里读到的键根本不是 3x1(被播放器自己改回去/没写进去) ② 读到了但钩子没认到视图。
       这条只在"判定不是 3x1"时打, 5 秒一次, 不刷屏。 */
    {
        static CFTimeInterval lastKeyLog = 0;
        CFTimeInterval kn = CFAbsoluteTimeGetCurrent();
        if (kn - lastKeyLog > 5.0) {
            lastKeyLog = kn;
            NSString *k = diNPLayoutKey();
            if (!k.length) {
                /* 3.0.35: 注入后 1 秒内 diNPLayoutKey 故意返回空(首开保护)。如果模块
                   恰好在这一秒内布局完, 标记就打不上, 而后面没有任何人再来一次 ——
                   表现就是"注销后一直 4×1, 直到我去展开一下"。这里补一次延迟重试。 */
                __weak id wvc = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    id s2 = wvc;
                    @try { if (s2) diNPHandleModuleVC(s2); } @catch (__unused NSException *e) {}
                });
            }
            if (![k isEqualToString:@"3x1"]) {
                id szK = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("Size"),
                                                                     CFSTR("com.local.playerexact")));
                id vrK = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("PlayerGridVariant"),
                                                                     CFSTR("com.local.playerexact")));
                RLog(@"[3x1][键] 判定=%@ Size=%@ Variant=%@ 功能档位=%d",
                     k.length ? k : @"(空)", szK ?: @"(无)", vrK ?: @"(无)", gDIStage);
            }
        }
    }
    /* 3.0.10: 绝不在 viewWillLayoutSubviews 里同步改视图树/发 XPC —— 挪到下一轮
       runloop, 且每个 VC 节流 0.5s。 */
    @try {
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        NSNumber *last = objc_getAssociatedObject(self, kDIBgLastKey);
        if (last && now - last.doubleValue < 0.5) return;
        objc_setAssociatedObject(self, kDIBgLastKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        static int crumbLeft = 12;   /* 3.0.11: 足迹只记前 12 次, 防刷盘 */
        if (crumbLeft > 0) { crumbLeft--; diCrumb(@"模块: 容器布局节流通过"); }
        id vc = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { diNPHandleModuleVC(vc); } @catch (NSException *e) { diCrumb([NSString stringWithFormat:@"模块: 异常 %@", e.reason]); }
        });
    } @catch (__unused NSException *e) {}
}

static void diNPMediaChanged(CFNotificationCenterRef c, void *obs, CFStringRef name,
                             const void *obj, CFDictionaryRef info) {
    static CFTimeInterval last = 0;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - last < 0.4) return;
    last = now;
    gDIBgFetchTS = 0;   /* 3.0.14: 通知来了就别等 2 秒节流 */
    @try { diNPFetchArtwork(); } @catch (__unused NSException *e) {}
    /* 3.0.16: 通知到的时候 artworkData 常常还没写好(还拿得到上一首的图), 补两次 */
    for (int i = 0; i < 2; i++) {
        CFTimeInterval d = (i == 0) ? 0.25 : 0.7;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                gDIBgFetchTS = 0;
                gDIBgLastReqTS = 0;
                diNPFetchArtwork();
            } @catch (__unused NSException *e) {}
        });
    }
}

/* ===== 3.0.17: 直接接管 MRUArtworkView 自身 =====
   用户给的参考实现(musicRotation.dylib)只做一件事: hook 目标类的 layoutSubviews,
   在里面给 self 挂圆形 mask + transform.rotation.z。它"完整"是因为挂在"类"上 ——
   每个实例、每次换尺寸都会自动处理, 不存在"扫不到"。
   我们之前是"遍历视图树按特征收集", 3×2 网格里格子图一换实例就漏, 一秒后重扫到又
   重挂 mask, 就是"有些尺寸会闪 / 有些缺失"。现在同样 hook 类, 收集只作兜底。 */
static void (*gDIOrigAVLayout)(id, SEL) = NULL;
static BOOL gDIArtAVTried = NO;

static BOOL diArtInControlCenter(UIView *v) {
    /* 按"窗口"判定最干净: 3×2 那套在 SBControlCenterWindow 里; 锁屏/灵动岛是
       SBLockScreen 或 SBAperture 窗口 —— 那些地方的头像有自己的遮罩素材, 绝不能碰。 */
    UIWindow *w = v.window;
    if (w) {
        NSString *wn = NSStringFromClass(w.class);
        if ([wn containsString:@"ControlCenter"]) return YES;
        if ([wn containsString:@"LockScreen"] || [wn containsString:@"Aperture"]
            || [wn containsString:@"SystemAperture"]) return NO;
    }
    UIView *a = v.superview;
    for (int i = 0; a && i < 10; i++, a = a.superview) {
        NSString *cn = NSStringFromClass(a.class);
        if ([cn containsString:@"MRUControlCenter"]) return YES;
        if ([cn containsString:@"Activity"] || [cn containsString:@"Aperture"]) return NO;
    }
    return NO;
}

static void diArtAVLayout(id self, SEL cmd) {
    if (gDIOrigAVLayout) gDIOrigAVLayout(self, cmd);
    @try {
        if (gDIStage < 1) return;
        /* 3.0.19: 去掉 diArtIs3x2() 限制 —— 3×2 只是"要不要动传送栏"的判据, 与封面
           无关。用户实测 3×2 展开已经正常, 但 4×2 / 其他尺寸的展开不转, 就是因为
           这里把非 3×2 全挡掉了。 */
        if (!diArtPrefOn()) return;
        UIView *v = (UIView *)self;
        if (!v.window || v.hidden || v.alpha < 0.05) return;
        if (!diArtInControlCenter(v)) return;   /* 锁屏 / 灵动岛不碰 */
        /* 3.0.20: 不在 layoutSubviews 里挂 mask/加动画 —— 那会让系统在**同一帧**里
           把父视图再排一次(3×2 的传送栏就是这么抖的)。丢到主队列, 同一 runloop
           内合并执行, 一定在本次布局之后、CA 提交之前 —— 视觉上还是这一帧。 */
        diArtScheduleDress(v);
    } @catch (__unused NSException *e) {}
}

/* ===== 3.0.17: 按钮抖动只读定位 =====
   3.0.16 的 [抖动2] 证明: 5 个按钮在两套 frame 之间来回(A=44x44 紧排,
   B=37.5x37.5 且 y 漂到 43~46), 说明是"某个调用方每隔两三秒重新触发了一次
   传送栏的布局动画"。这里只读不改: hook 按钮的 setFrame/setTransform/
   setHighlighted, 把调用者(镜像+符号)写进日志, 最多 40 条。 */
static void (*gDIOrigTBSetFrame)(id, SEL, CGRect) = NULL;
static void (*gDIOrigTBSetTransform)(id, SEL, CGAffineTransform) = NULL;
static void (*gDIOrigTBSetHighlighted)(id, SEL, BOOL) = NULL;
static int gDITBLogs = 0;

/* 3.0.20: 打**整条调用链**(最多 4 帧), 每帧带 "镜像+偏移"。
   原因: 3.0.19 只打第一帧, 而 dylib 里的 static 函数没有导出符号, dladdr 只能给出
   "最近的前一个导出符号", 于是所有调用都被记成了 diGainRestoreAll —— 白查两轮。
   现在偏移量可以拿同一份 dylib 用 nm 反解, 下次日志就能直接点名到具体函数。 */
static void diTraceCaller(const char *tag) {
    void *bt[16];
    int n = backtrace(bt, 16);
    NSMutableString *chain = [NSMutableString string];
    int shown = 0;
    for (int i = 1; i < n && shown < 4; i++) {
        Dl_info di;
        if (!dladdr(bt[i], &di)) continue;
        const char *fn = di.dli_fname ? di.dli_fname : "?";
        const char *base = strrchr(fn, '/');
        NSString *fnS = [NSString stringWithUTF8String:(base ? base + 1 : fn)];
        NSString *symS = di.dli_sname ? [NSString stringWithUTF8String:di.dli_sname] : nil;
        if (symS && [symS containsString:@"diTrace"]) continue;
        uintptr_t off = di.dli_fbase ? ((uintptr_t)bt[i] - (uintptr_t)di.dli_fbase) : 0;
        if (shown) [chain appendString:@" ← "];
        [chain appendFormat:@"%@+0x%lx", fnS ?: @"?", (unsigned long)off];
        if (symS.length) [chain appendFormat:@"(%@)", symS];
        shown++;
    }
    NSString *tagS = tag ? [NSString stringWithUTF8String:tag] : @"?";
    RLog(@"[抖动3] %@ ← %@", tagS, chain.length ? chain : @"(无)");
}

/* 3.0.19: 丢掉引导前 10 秒的记录 —— 430 日志里 40 条配额全被引导期的正常布局吃光了,
   真正抖动时反而一条都没有。现在只在"系统已经稳定"之后才开始记。 */
static BOOL diTBShouldLog(void) {
    if (gDITBLogs >= 40) return NO;
    if (gDILoadTS <= 0) return NO;
    if (CFAbsoluteTimeGetCurrent() - gDILoadTS < 10.0) return NO;
    return diArtIs3x2();
}
static void diTBSetFrame(id self, SEL cmd, CGRect f) {
    if (diTBShouldLog()) { gDITBLogs++; diTraceCaller("TB.setFrame"); }
    if (gDIOrigTBSetFrame) gDIOrigTBSetFrame(self, cmd, f);
}
static void diTBSetTransform(id self, SEL cmd, CGAffineTransform t) {
    if (diTBShouldLog()) { gDITBLogs++; diTraceCaller("TB.setTransform"); }
    if (gDIOrigTBSetTransform) gDIOrigTBSetTransform(self, cmd, t);
}
static void diTBSetHighlighted(id self, SEL cmd, BOOL h) {
    if (diTBShouldLog()) { gDITBLogs++; diTraceCaller("TB.setHighlighted"); }
    if (gDIOrigTBSetHighlighted) gDIOrigTBSetHighlighted(self, cmd, h);
}

static BOOL gDITBHookTried = NO;
static void diArtInstallTBHook(void) {
    if (gDITBHookTried) return;
    Class tb = NSClassFromString(@"MRUTransportButton");
    if (!tb) return;
    gDITBHookTried = YES;
    @try {
        MSHookMessageEx(tb, @selector(setFrame:), (IMP)diTBSetFrame, (IMP *)&gDIOrigTBSetFrame);
        MSHookMessageEx(tb, @selector(setTransform:), (IMP)diTBSetTransform, (IMP *)&gDIOrigTBSetTransform);
        MSHookMessageEx(tb, @selector(setHighlighted:), (IMP)diTBSetHighlighted, (IMP *)&gDIOrigTBSetHighlighted);
        RLog(@"[抖动3] MRUTransportButton 定位钩子已装(只读)");
    } @catch (__unused NSException *e) {}
}

static void diArtInstallAVHook(void) {
    if (gDIArtAVTried) return;
    Class av = NSClassFromString(@"MRUArtworkView");
    if (!av) return;
    gDIArtAVTried = YES;
    Method m = class_getInstanceMethod(av, @selector(layoutSubviews));
    IMP before = m ? method_getImplementation(m) : NULL;
    MSHookMessageEx(av, @selector(layoutSubviews), (IMP)diArtAVLayout, (IMP *)&gDIOrigAVLayout);
    if (!gDIOrigAVLayout) gDIOrigAVLayout = (void (*)(id, SEL))before;
    RLog(@"[封面] 已接管 MRUArtworkView layoutSubviews(全部实例/全部尺寸)");
    diArtInstallTBHook();
}

static void diArtInstall(void) {
    if (gDIArtHooked) return;
    diArtDisableNPRSpin();   /* 尽早接管播放器内置旋转, 避免第一次播放就已经在转 */
    diArtInstallAVHook();    /* 3.0.17: 类级接管, 覆盖所有实例/尺寸 */
    Class npv = NSClassFromString(@"MRUNowPlayingView");
    Class ccv = NSClassFromString(@"MRUControlCenterViewController");
    if (!npv || !ccv) {
        /* iOS 16 的 MediaRemoteUI 是懒加载的, 类不在就把框架拉起来(与播放器诊断同一套) */
        const char *fws[3] = {
            "/System/Library/PrivateFrameworks/MediaRemoteUI.framework/MediaRemoteUI",
            "/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI",
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        };
        for (int i = 0; i < 3; i++) dlopen(fws[i], RTLD_NOW | RTLD_GLOBAL);
        npv = NSClassFromString(@"MRUNowPlayingView");
        ccv = NSClassFromString(@"MRUControlCenterViewController");
    }
    BOOL any = NO;
    if (npv) {
        Method m = class_getInstanceMethod(npv, @selector(layoutSubviews));
        IMP before = m ? method_getImplementation(m) : NULL;
        MSHookMessageEx(npv, @selector(layoutSubviews), (IMP)diArtNPLayout, (IMP *)&gDIArtOrigNPViewLayout);
        if (!gDIArtOrigNPViewLayout) gDIArtOrigNPViewLayout = (void (*)(id, SEL))before;
        any = YES;
    }
    if (ccv) {
        Method m = class_getInstanceMethod(ccv, @selector(layoutSubviews));
        IMP before = m ? method_getImplementation(m) : NULL;
        MSHookMessageEx(ccv, @selector(layoutSubviews), (IMP)diArtCCLayout, (IMP *)&gDIArtOrigCCVCLayout);
        if (!gDIArtOrigCCVCLayout) gDIArtOrigCCVCLayout = (void (*)(id, SEL))before;
        any = YES;
    }
    /* 3.1.0: 模块卡片(专辑背景/隐藏未在播放) —— ControlCenterUI 里的容器 VC
       3.0.11: 保险引导(距上次引导<90秒)下不装, 防止崩溃循环 */
    if (any) {
        gDIArtHooked = YES;
        RLog(@"[封面] 钩子已装 (NowPlayingView=%d CCVC=%d 开关=%d)",
             npv != nil, ccv != nil, diArtPrefOn());
    }
}

/* 3.0.13: 高危钩子独立安装 —— 引导满 8 秒后才调用(第 8/20 秒诊断各试一次),
   档位 1=模块背景/隐藏, 2+=传送栏 setFrame。引导早期(SpringBoard 还在铺布局)
   碰这些是 3.0.9 起每次引导#1 必崩的头号时间窗。 */
static BOOL gDIStageHooksDone = NO;
static void diArtInstallGated(void) {
    if (gDIStageHooksDone) return;
    if (gDIStage < 1) return;
    if (gDILoadTS <= 0 || CFAbsoluteTimeGetCurrent() - gDILoadTS < 8.0) return;
    /* 类懒加载: 跟 diArtInstall 同一套拉起, 类不在就拉框架 */
    if (!NSClassFromString(@"MRUNowPlayingTransportControlsView")
        || !NSClassFromString(@"CCUIContentModuleContainerViewController")) {
        const char *fws[3] = {
            "/System/Library/PrivateFrameworks/MediaRemoteUI.framework/MediaRemoteUI",
            "/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI",
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        };
        for (int i = 0; i < 3; i++) dlopen(fws[i], RTLD_NOW | RTLD_GLOBAL);
    }
    Class mvc = NSClassFromString(@"CCUIContentModuleContainerViewController");
    Class tcc = NSClassFromString(@"MRUNowPlayingTransportControlsView");
    BOOL needModule = (gDIStage >= 1);
    BOOL needTC = (gDIStage >= 2);
    if (needModule && !mvc) return;   /* 类还没出来, 第 20 秒诊断会再试 */
    if (needTC && !tcc) return;
    gDIStageHooksDone = YES;
    diArtInstallAVHook();
    diCrumb([NSString stringWithFormat:@"安装: 高危钩子开始(档位 %d)", gDIStage]);
    diNPInstall3x1Hook();   /* 3.0.28: 3×1 布局收紧(类不存在时在模块布局时会再试) */
    diNPInstallMediaObserver();   /* 3.0.14: 换歌通知兜底注册 */
    diNPStartBgTimer();           /* 3.0.15: 换曲轮询(通知不可靠) */

    if (needModule) {
        if (mvc) {
            diCrumb(@"安装: 模块容器钩子前");
            Method m = class_getInstanceMethod(mvc, @selector(viewWillLayoutSubviews));
            IMP before = m ? method_getImplementation(m) : NULL;
            MSHookMessageEx(mvc, @selector(viewWillLayoutSubviews), (IMP)diNPModuleLayout, (IMP *)&gDIOrigModuleLayout);
            if (!gDIOrigModuleLayout) gDIOrigModuleLayout = (void (*)(id, SEL))before;
            diCrumb(@"安装: 模块容器钩子后");
            RLog(@"[背景] 模块容器钩子 %@", gDIOrigModuleLayout ? @"已装" : @"失败");
        }
    }
    /* 3.0.15: 传送栏 setFrame: 接管彻底停用。
       用户连续四轮反馈"3×2 按钮还是会抖一下", 而 3.0.10~3.0.14 的日志里这个钩子
       一次都没真正拦下过瞬跳(没有一条 [抖动] 拦下...) —— 它没在修问题, 只在跟系统
       布局抢 frame。现在完全不碰传送栏的任何 frame/动画, 由系统自己排。 */
    RLog(@"[抖动] 传送栏 setFrame 接管已停用(3.0.15: 不再改写系统 frame, 档位=%d)", gDIStage);
    (void)tcc;
}


static void diArtChanged(CFNotificationCenterRef c, void *obs, CFStringRef name,
                         const void *obj, CFDictionaryRef info) {
    /* 3.0.13: 用户在设置里动了开关 = 明确要求恢复全功能, 档位回满(下次引导生效) */
    if (gDIStage < 3) {
        gDIStage = 3;
        gDIPlayerSafeBoot = NO;
        CFPreferencesSetAppValue(CFSTR("FeatureStage"), (__bridge CFPropertyListRef)@3, CFSTR("com.abgg332.driftisland"));
        CFPreferencesAppSynchronize(CFSTR("com.abgg332.driftisland"));
        RLog(@"[保险] 设置有改动 → 功能档位恢复全开(下次引导生效)");
    }
    gDIBgPrefTS = 0;               /* 3.1.0: 背景/隐藏未在播放的开关立刻重读 */
    gDIBgFetchTS = 0;
    /* 3.0.23: 只有"用户真的动开关"这一次值得同步读(他要立刻看到效果), 其余全走后台缓存。
       顺便复位背景熔断 —— 用户重新打开开关 = 明确想再试一次。 */
    {
        BOOL wasOn = gDIBgOnCache;
        diNPLoadPrefsSync();
        if (gDIBgOnCache && !wasOn) { gDIBgStopped = NO; gDIBgSlowCount = 0; }
    }
    /* 3.0.20(iOS17 卡死的主修): 以前这里在 SpringBoard 主线程直接
       CFPreferencesAppSynchronize(com.local.playerexact) —— 那是**别的进程**的域,
       设置页正在高频写它, cfprefsd 一争用就把主线程按住几十秒, watchdog 直接注销
       (432 日志: 33 秒 / 66 秒两段空洞, 全都紧跟在这条通知之后)。
       现在: ① 合并抖动(0.35 秒内只认一次); ② 跨进程同步丢到后台串行队列;
       ③ 回主线程只做"重挂蒙版", 不再对每个根视图 setNeedsLayout(那会逼整张卡重排)。 */
    static BOOL pending = NO;
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        pending = NO;
        static dispatch_queue_t q;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            q = dispatch_queue_create("com.abgg332.driftisland.npprefs", DISPATCH_QUEUE_SERIAL);
            dispatch_set_target_queue(q, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        });
        dispatch_async(q, ^{
            @try { diArtForceRefresh(); } @catch (__unused NSException *e) {}
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    diPhase("prefs");
                    diArtDisableNPRSpin();
                    @try { diExportMaskSoon(); } @catch (__unused NSException *e) {}  /* 3.0.24: 保证 mask.png 在 */
                    BOOL on = diArtPrefOn();
                    RLog(@"[封面] 开关变化 → %@", on ? @"圆 + 旋转" : @"方形 + 停止");
                    diNPRefreshBackgrounds();
                    for (UIView *host in gDIBgHosts.allObjects) {
                        diNPHideNotPlayingLabels(host, diNPPrefFlag(@"HideNotPlaying", NO));
                    }
                    for (UIView *root in gDIArtRoots.allObjects) {
                        DIArtRootState *rs = objc_getAssociatedObject(root, kDIArtRootKey);
                        for (UIView *a in rs.arts) diArtApply(a, on);
                    }
                } @catch (NSException *e) { RLog(@"[封面] 刷新异常: %@", e.reason); }
            });
        });
    });
}

__attribute__((constructor)) static void init(void) {
    @autoreleasepool {
        /* 2.7.15: 版本标记写死在这里, 不依赖 CFBundleShortVersionString ——
           248 日志里连"tweak 加载"那一行都没有, 无法判断新代码到底有没有被加载。
           这条 RLog 不受日志开关控制, 装完重启 SpringBoard 立刻就能确认版本。 */
        /* 2.7.43: 版本行不再写死 —— 上一版一直硬编码 "2.7.35", 装 2.7.42 后
           日志还显示 2.7.35, 连续两轮都在怀疑"是不是没装上"。现在优先读包版本,
           读不到再退回编译宏, 并附编译时间戳, 一眼就能确认跑的是哪一版。 */
        NSString *diVer = nil;
        @try {
            diVer = [[NSBundle bundleWithPath:@"/Library/MobileSubstrate/DynamicLibraries/DriftIsland.dylib"] infoDictionary][@"CFBundleVersion"];
        } @catch (__unused NSException *e) {}
        if (!diVer.length) diVer = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"];
        if (!diVer.length) diVer = @"?";
        RLog(@"===== 漂流岛 v%@ 已加载 (%@) 编译于 %s %s =====", diVer, diProcName(), __DATE__, __TIME__);
        diStartWatchdog();
        // MediaRemoteUI gets only the real-artwork mask component, never SB initialization.
        NSString *process = NSProcessInfo.processInfo.processName;
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier.lowercaseString;
        if ([bundle isEqualToString:@"com.apple.mediaremoteui"] || [process isEqualToString:@"MediaRemoteUI"]) {
            /* 2.8.80: 进进程第一件事就回传 —— 之前的日志只能看到 reload, 无法确认构造器是否跑完 */
            diMruPostPayload(@"boot", [NSString stringWithFormat:@"%@_%@", process ?: @"?", bundle ?: @"?"]);
            diActivityStart();
            return;
        }
        refreshPrefs();
        gDILoadTS = CFAbsoluteTimeGetCurrent();
        /* 3.0.11: 防死循环保险 —— 必须在任何 3.x 钩子安装之前判定 */
        diBootGuardCheck();
        /* 2.8.5: 来电视频已整体删除, 非 SpringBoard 进程直接退出 */
        NSString *bid = NSBundle.mainBundle.bundleIdentifier.lowercaseString;
        if (![bid isEqual:@"com.apple.springboard"]
            && ![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) {
            return;
        }
        logHandle = os_log_create("com.abgg332.driftisland", "runtime");
        DLog(@"===== 漂流岛 tweak 加载 (SpringBoard) 版本 %@ (构建 %@) =====", \
         [NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] description] ?: @"?", DI_BUILD_VER);
        /* 3.0.3: 内置播放器自检 —— 同步补激活键(万一本 dylib 的构造器排在播放器之前, 这一写就能救回来),
           再在第 2/6 秒各探一次: 播放器到底有没有被注入, 没有就手动 dlopen 并把 dlerror 记下来。 */
        @try { diNPHealPrefs(); } @catch (NSException *e) { RLog(@"[播放器] 补写激活键异常: %@", e.reason); }
        for (int npSec : {2, 8, 20})
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)npSec * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                @try {
                    RLog(@"[播放器][诊断] ==== 第 %d 秒 ====", npSec);
                    if (npSec == 2) diNPDumpCrashEvidence();   /* 3.0.13: 崩溃报告+足迹回放 */
                    diNPHealPrefs();
                    diNPProbe();
                    diNPImages();
                    diArtInstall();   /* 3.0.6: 封面圆角/3×2 抖动 */
                    diArtInstallGated();   /* 3.0.13: 档位门控的高危钩子(满8秒才装) */
                    if (npSec >= 8) {
                        int hk = diNPHookCheck();
                        diNPDumpDomain();
                        if (npSec == 8) {
                            diNPProbeRuntime();
                            if (hk == 0) {
                                /* 播放器的钩子是挂在 com.apple.springboard.finishedstartup 的 dispatch 块里的。
                                   如果它注册得比通知晚(或通知早于注入), 那个块永远不会跑, 表现就是"什么都不生效"。
                                   它自己有 once 保护(0xd27), 重发这条通知最多让它空转一次, 不会重复 hook。 */
                                if (!NSClassFromString(@"MRUNowPlayingViewController")) {
                                    /* iOS 16 上 MediaRemoteUI 是懒加载的: 控制中心没开过时这些类还不存在,
                                       播放器就算跑到 hook 那一步也只会拿到 nil 类 → 静默跳过。先把框架拉起来。 */
                                    RLog(@"[播放器][修复] MRUNowPlayingViewController 此刻不存在 → 提前 dlopen MediaRemoteUI");
                                    const char *fws[3] = {
                                        "/System/Library/PrivateFrameworks/MediaRemoteUI.framework/MediaRemoteUI",
                                        "/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI",
                                        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
                                    };
                                    for (int fi = 0; fi < 3; fi++) {
                                        void *h = dlopen(fws[fi], RTLD_NOW | RTLD_GLOBAL);
                                        if (h) RLog(@"[播放器][修复] 已加载 %s", fws[fi]);
                                        else { const char *e = dlerror(); RLog(@"[播放器][修复] 加载失败 %s → %s", fws[fi], e ? e : "?"); }
                                    }
                                    RLog(@"[播放器][修复] 加载后 MRUNowPlayingViewController=%@",
                                         NSClassFromString(@"MRUNowPlayingViewController") ? @"存在" : @"仍不存在");
                                }
                                RLog(@"[播放器][修复] 一个 hook 都没装上 → 补发 com.apple.springboard.finishedstartup 让启动块重跑");
                                notify_post("com.apple.springboard.finishedstartup");
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                                               dispatch_get_main_queue(), ^{
                                    RLog(@"[播放器][修复] 补发后复查:");
                                    diNPHookCheck();
                                    diNPDumpDomain();
                                });
                            }
                        }
                    }
                }
                @catch (NSException *e) { RLog(@"[播放器] 自检异常: %@", e.reason); }
            });
        /* 2.8.78: 接收 MediaRemoteUI 的打点 + 把遮罩素材导出给那个进程 */
        diMruObserve();
        diMruTailInstall();
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ diExportMaskForMRU(); });
        /* 2.7.15: 组名 hook **必须在主队列 block 之外、且在最前面** 装 ——
           2.7.14 把它放在 dispatch_async 里, 前面还排了 refreshAll/installKnownHosts/
           两个 ticker/5 个通知监听。只要前面任何一步抛异常, hook 就永远装不上,
           而且连日志都不会留(248 日志里 [壁纸图层] 0 条就是这么来的)。
           现在先装 hook, 再进主队列做其余的事, 各自独立兜底。 */
        /* 2.8.5: 控制中心壁纸已随设置入口一并下架, 三个 hook 不再安装(代码留档, git 可找回) */
        /* 2.8.41: 控制中心壁纸恢复(用户要求) —— wpOn 开启时装 overlay hook(ccvideobg 机制, 2.7.37 形态) */
        if (wpOn) diCCInstallOverlayHook();
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                refreshAll(); installKnownHosts();
                /* 2.9.55: 17 专用形态播报(16 不装) */
                diHostPubInstall();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ @try { diHostPubInstall(); } @catch (...) {} });
                diStartFlowTicker(); // 流光常驻驱动(岛静止时也能流动)
                diStartBarFlowTicker(); // 2.5.11: 横条流光心跳(与文字同一套相位驱动)
            } @catch (NSException *e) {
                RLog(@"启动初始化异常: %@ — %@", e.name, e.reason);
            }
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                prefsChanged, (__bridge CFStringRef)kNotifyStr, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            /* 2.6.12: 设置页选完遮罩素材后 post 这条, 让遮罩立刻换图 */
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                prefsChanged, CFSTR("com.abgg332.driftisland/prefsChanged"), NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);

            /* 3.1.0: 系统「正在播放信息变化」 —— 换歌/开始播放时刷新专辑背景
               3.0.14: 幂等注册, 延迟安装时还会再兜一次 */
            diNPInstallMediaObserver();
            /* 3.0.6: 面板里拨「专辑图旋转」→ 立刻刷新封面蒙版(不用注销) */
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                diArtChanged, CFSTR("com.local.playerexact/artwork-changed"), NULL,
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
                    gVolumeUntil = CFAbsoluteTimeGetCurrent() + 4.0;
                    DLog(@"音量键事件: 4秒内我们让位, 让系统自己收音量条");
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
                    dispatch_get_main_queue(), ^{ installKnownHosts(); refreshAll(); diPreloadIslandVideos(); diHookHomeBarGrabberRetry(); });
        });
    }
}
