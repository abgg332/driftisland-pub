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
#include <stdlib.h>   /* 3.0.83: arc4random_uniform(气泡随机) */
#include <notify.h>
#include <fcntl.h>
#include <unistd.h>
#import <substrate.h>
#import <os/log.h>
#include <dispatch/dispatch.h>
#include "DIVersion.h"   /* 3.0.28: 版本号唯一来源(与 prefs 共用) */
#include <vector>

/* ===== 3.1.6 修复: 3.1 重构时丢失的定义区(日志基础设施 + 频谱/鼓点/律动状态) =====
   3.1.6 的 Tweak.mm 从 1.26MB 精简到 155KB, 实现逻辑都在, 但这批 static 定义/
   宏/日志函数被整段删掉了, 编译报 90+ 个 undeclared identifier。
   本块从 3.0.119 完整版按原顺序搬回。 */
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
/* 3.0.49: 刷屏源定位 —— 462 日志里"上一秒省略 40009 行", 但被折叠的到底是哪一句
   打出来的完全看不出来, 排查死循环全靠猜。DLog/RLog 现在把格式串指针先存进来
   (静态字面量, 存指针零开销), 第一条被挤掉的行记下它的格式串, 秒末汇总打出来。
   另加诊断旁路: 崩溃回放/保险这类一次性诊断输出不再跟刷屏源抢 25 行配额。 */
static NSString *gDILogCurFmt = nil;
static NSString *gDILogDropFmt = nil;
static BOOL gDILogBypass = NO;
static BOOL diLogGate(void) {
    static int n = 0; static int dropped = 0;
    static CFAbsoluteTime sec = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - sec >= 1.0) {
        int d = dropped;
        NSString *src = gDILogDropFmt;
        dropped = 0;
        gDILogDropFmt = nil;
        sec = now;
        n = 0;
        if (d > 0) {
            @try {
                NSString *head = src.length > 120 ? [src substringToIndex:120] : src;
                NSString *line = [NSString stringWithFormat:@"[%@] [现场] (上一秒省略 %d 行重复日志, 刷屏源格式串: %@)\n",
                                  [diLogDF() stringFromDate:[NSDate date]], d, head ?: @"<空>"];
                diLogWrite(line);
            } @catch (__unused NSException *e) {}
        }
    }
    if (gDILogBypass) return YES;
    if (n >= 25) {
        if (dropped == 0) gDILogDropFmt = gDILogCurFmt;
        dropped++;
        return NO;
    }
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
    gDILogCurFmt = fmt;
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
    gDILogCurFmt = fmt;
    if (!diLogGate()) return;
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *out = [NSString stringWithFormat:@"[%@] [现场] %@\n", [diLogDF() stringFromDate:[NSDate date]], line];
    diLogWrite(out);
}
#define DI_STEP(fmt, ...) RLog(fmt, ##__VA_ARGS__)


static NSHashTable *gDIArtRoots = nil;
static NSHashTable *gDIArtKnown = nil; /* 3.0.17: 见过的封面(弱引用), 持续维护 */
/* 3.0.57: 律动接管了哪一层的 transform(旋转+缩放)。这层暂时不挂 di.art.spin ——
   两个写入者抢同一个属性时, 探针里 m11 会间歇变回 1.000, 旋转也会忽快忽慢。 */
static __weak UIView *gDIArtSpinYield = nil;
static int gDIStage = 3;              /* 功能档位: 3=全开 2=去掉传送栏setFrame钩子 1=再去掉模块背景/隐藏钩子 0=全关(旧保险态) */
static UIImage *gDIBgImage = nil;
static BOOL gDIHasNowPlaying = NO;
static BOOL gDIInfoReady = NO;
#define DI_AU_PORT   41235
#define DI_AU_BANDS  24
#define DI_AU_PKT    36          /* v1: 4 头 + 4 fast + 4 slow + 24 bands */
#define DI_AU_PKT3   120
static float gDIReferenceRaw[72], gDIReferenceCurrent[72];
static BOOL gDIReferenceSeen = NO;
#define DI_AU_PKT2   48          /* v2(3.0.71): 再 + 强度/年龄/序号/低频RMS */
static float gDIBandRaw[DI_AU_BANDS];
static float gDIBandSmooth[DI_AU_BANDS];
static BOOL gDIBandSeen = NO;
/* 3.0.71: 服务端(mediaserverd, 样本域)直接算好的"咚" —— 客户端不再自己猜鼓点 */
static BOOL     gDIPcmKickSeen = NO;      /* 收到过 v2 包 */
static uint32_t gDIPcmKickSerial = 0;     /* 服务端触发序号 */
static float    gDIPcmKickAmp = 0.0f;     /* 0~1 */
static uint16_t gDIPcmKickAgeMs = 0;      /* 这一包发出时距触发多久 */
static float    gDIPcmLowRms = 0.0f;      /* 低频 RMS(探针用) */
   看起来就是"一卡一卡"。CADisplayLink 严格跟屏幕刷新走, 120Hz 下每帧都更新。 */
static CADisplayLink *gDIRhythmLink = nil;
static id gDIRhythmTicker = nil;
static __weak UIView *gDIRhythmTarget = nil;
static __weak UIView *gDIRhythmHost = nil;
static CALayer *gDIRhythmRingBox = nil;
static CAGradientLayer *gDIRhythmRingGrad = nil;
static CAShapeLayer *gDIRhythmRingMask = nil;
static CAShapeLayer *gDIRhythmRingBack = nil;
static BOOL gDIBeatStopped = NO;          /* 3.0.79: 暂停/停止后已硬停(粒子清零+层隐藏) */
static CFAbsoluteTime gDIBeatStopAt = 0;  /* 3.0.88: 上次硬停的时刻(唤醒节流用) */
static CAGradientLayer *gDIRhythmBarsGrad = nil;
static CAShapeLayer *gDIRhythmBars = nil;      /* 条形的 mask 形状 */
   键: SpectrumStyle(不分尺寸) —— Spectrum 前缀会被 diIsFxKey 认出来, 切换即时生效。 */
/* (变量声明提前到文件前部 —— 偏好读取里就要用到) */
static CATransform3D gDIRhythmBase;
static BOOL gDIRhythmBaseValid = NO;
static CGRect gDIRhythmRingFrame = {{0, 0}, {0, 0}};
static NSString *gDIRhythmUsedA = nil;
static NSString *gDIRhythmUsedB = nil;
static int gDIBarsModeUsed = -1;
static NSString *gDIBarsUsedA = nil;
static NSString *gDIBarsUsedB = nil;
static float gDIBeatEnv = 0.0f;      /* 视觉拍点(平滑后 0~1): 缩放/透明度用它 */
static float gDISteady = 0.0f;       /* 整体响度 0~1 */
static float gDIBassPrev = 0.0f;     /* 上一帧低音能量(算通量) */
static float gDIBassPulse = 0.0f;    /* 物理冲击 0~1: 粒子外推用它 */
static float gDIBeatRaw = 0.0f;      /* 起音瞬间的强度, 快速衰减 */
static float gDIOnsetAvg = 0.0f;     /* 低音滑动均值(自适应阈值) */
static float gDIOnsetVar = 0.0f;     /* 低音滑动方差 */
static CFTimeInterval gDILastOnset = 0;
static double gDIHuePhase = 0.0;     /* 3.0.54: 流光模式的色相相位 */
static int gDIRingModeUsed = -1;     /* 3.0.54: 上次建环用的颜色模式 */
static double gDISynPhase = 0.0;
static CFTimeInterval gDIClock = 0;
static CFTimeInterval gDITargetAt = 0;
static BOOL gDIFxRealLogged = NO;
/* 3.0.56 */
static __weak UIView *gDIRhythmDrive = nil;   /* 真正承载缩放的视图(封面外面可能还套着一层裁剪容器) */
   兄弟/叔伯视图。真正的专辑图落在哪一层, 都能被一起缩放。 */
#define DI_RHYTHM_EXTRA_MAX 4
static __weak UIView *gDIRhythmExtras[DI_RHYTHM_EXTRA_MAX];
static int gDIRhythmExtraN = 0;
static CGSize gDIRhythmBaseSize;       /* 记 base 时 dv 的尺寸 —— 变了说明展开/收起, base 作废 */
static double gDILastAng = 0.0;        /* 3.0.61: 关掉旋转时把角度冻结在这个值上(不跳回 0°) */
static BOOL gDIRhythmDriving = NO;     /* 上一帧我们是否在写 transform(用于"只还原一次") */
static float gDIKick = 0.0f;           /* 视觉包络: 3.0.74 起由统一顺滑包络推进(45ms 顶/170ms 落) */
static float gDIKickTarget = 0.0f;     /* 3.0.74: 本次咚的目标强度 */
static CFTimeInterval gDIKickAtkT = 0; /* 3.0.74: 起音时刻(45ms 趋近窗口) */
static float gDILowPrevK = 0.0f;       /* 上一帧低频归一值 */
   再加 0.17s 不应期 + "必须回落到 0.3 以下才重新上膛", 保证一个鼓点只触发一次。 */
static float gDILowFloor = 0.0f;
static float gDILowPeak = 0.0f;
static float gDILowN = 0.0f;
static float gDILowNPrev = 0.0f;
static BOOL  gDIKickArmed = YES;
static CFTimeInterval gDILastKickT = 0;
static float gDILowSm = 0.0f;          /* 12ms 平滑后的低频(压掉逐帧噪声) */
static float gDILowHist[5];            /* 最近 4 帧(~66ms)的平滑值, 用来量"这一下冲了多高" */
static int   gDILowHistW = 0;
/* 3.0.68: "咚"的前沿检测 —— 前两帧(32ms)的最高点 + 低频占比 + 本次触发峰值 */
static float gDILowP1 = 0.0f, gDILowP2 = 0.0f;
static float gDILowShare = 0.0f;       /* 0~5 段能量 / 全谱能量(0~1) */
static float gDIKickHoldN = 1.0f;      /* 本次触发的归一峰值, 掉到 72% 以下才重新上膛 */
   所以鼓点从"大概在这附近"变成"就落在这一下上"。 */
static float gDIKickPunchAmp = 0.0f;
static CFTimeInterval gDIKickPunchT = 0.0;
static uint32_t gDILastPcmSerial = 0;
static BOOL  gDIRhythmSkipDv = NO;     /* extras 里已经有 dv 的祖先 → dv 不再单独写(否则缩两次) */
static CFTimeInterval gDIDumpAt = 0;
static float gDIMidLevel = 0.0f;              /* 当前中音能量(探针) */
static CFTimeInterval gDIQuietAt = 0;         /* 频谱端"连着但没数据"的起点 */
   自适应。底鼓/军鼓/拍手/人声起音都会在通量上留一个尖峰, 不依赖某一频段的绝对电平。 */
static float gDIBandPrevFlux[DI_AU_BANDS];
static float gDIFluxAvg = 0.0f;      /* 通量慢均值(自适应阈值) */
static float gDIFluxNow = 0.0f;      /* 本帧通量(探针) */
static float gDILowLevel = 0.0f;     /* 60~250Hz 能量(探针/低频呼吸) */
static __weak UIView *gDICoverRounded = nil;
static CGFloat gDICoverOrigRadius = 0;
static BOOL gDICoverOrigClip = NO;
/* 量出来的比例(见文件头): 刻度 80 根 / 宽 0.065R / 长 0.26R / 间距 0.045R */
#define DI_TICK_N      72
#define DI_TICK_W      0.065


static NSString *const kDomain = @"com.abgg332.driftisland";
static NSString *const kNotifyStr = @"com.abgg332.driftisland.reload";
/* 3.0.71: 尺寸代次 —— 设置页改尺寸时 +1, 所有"按尺寸缓存"的读取看到代次变了就重读 */
static int gDISizeGen = 0;
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
/* 3.0.40: 控制中心播放器专用遮罩 —— 与岛上那颗**完全分开**的两套键。
   岛: maskOn + diAlbumMaskAsset + mask.png
   播放器: PlayerMaskOn + PlayerMaskAsset + player_mask.png
   以前两者共用 maskOn/mask.png, 改一个另一个跟着变(用户明确要求分开)。 */
static BOOL playerMaskOn = NO;
static NSString *playerMaskAsset;   // 相对 kMaskDir 的文件名
/* 3.0.45: 控制中心播放器专辑的「律动特效」(真音频驱动, 见文件末尾模块注释) */
static BOOL rhythmFxOn = YES;                  // 特效总开关(AlbumEffectsOn)
static BOOL rhythmOn = YES;                    // 封面律动: 随节拍缩放
static BOOL diProgressRingOn = NO;
static double diProgressRingWidth = 3.0;
static NSString *diProgressRingColor = nil;
static BOOL rhythmRingOn = YES;                // 律动环(锥形渐变圆环 + 外圈刻度)
static BOOL diParticleExtraBeat=NO;
static BOOL rhythmParticlesOn = YES;           // 封面外圈粒子
static BOOL rhythmRoundCover = YES;            // 3.0.47: 封面裁成正圆
static BOOL rhythmBarsOn = YES;                // 3.0.48: 频谱条(进度条上方)
static int  rhythmBarsCount = 40;              // 3.0.50: 频谱条根数(可调)
/* 3.0.83: 频谱条样式 —— 0 柱状 / 1 点阵 / 2 镜像 / 4 峰值 / 5 尖刺 / 6 斜切
   / 10 萤火 / 14 星轨 / 15 胶囊 / 16 霓虹 / 17 双子
   (18/19/20 声呐/波浪/雨帘已在 3.0.115 删除)
   (3/7/8 历史预留位; 9/11/12/13 已在 3.0.112 按用户要求删除) */
static int gDIBarStyle = 0;
static float gDIBarPeak[64];
static CFAbsoluteTime gDIBarPeakT = 0;
/* 3.0.83: 气泡样式 —— 每根柱子顶上吐小泡泡往上飘(鱼吐泡泡)。
   泡泡是纯状态 + 每帧重画路径, 不新增图层: 依然挂在同一个渐变遮罩里,
   所以颜色照旧跟随封面/固定色/流光。 */
#define DI_BUBBLE_MAX 120
typedef struct {
    float x, y;         /* 当前圆心(bars 坐标系) */
    float vy;           /* 上升速度 pt/s, 会随寿命略微加速 */
    float r0;           /* 初始半径 */
    float life, maxLife;
    float swayPh, swayAmp;   /* 横向摆动的相位与幅度 */
    int alive;
} DIBubble;
static DIBubble gDIBubbles[DI_BUBBLE_MAX];
static float gDIBubbleLastV[64];    /* 上一帧各柱的频谱值, 用来抓"起音" */
static double gDIBubbleNextAt[64];  /* 各柱下次允许冒泡的时间(持续冒泡节流) */
static float gDIBubbleT = 0.0f;     /* 上一帧时间戳, 用来算 dt */
static double rhythmBarsHeight = 13.0;         // 3.0.50: 频谱条长度(可调)
static double rhythmBarsWidth = 3.0;           // 3.0.51: 频谱条单根最大宽度(可调)
static double rhythmBarsOffset = 0.0;          // 3.0.52: 频谱条水平位移(可调, 负=左 正=右)
static double rhythmParticleSize = 1.0;        // 3.0.51: 粒子大小倍率(可调)
static double rhythmParticleStrength = 1.0;    // 3.0.61: 粒子自己的强度(与鼓点/专辑律动无关)
static double rhythmBarsOffsetY = 0.0;         // 3.0.54: 频谱条垂直位移(正=上移)
static int    ringColorMode = 0;               // 3.0.54: 0=跟随专辑 1=固定色 2=流光
static int    particleColorMode = 0;           // 3.0.54: 同上
static int    spectrumColorMode = 0;           // 3.0.55: 频谱条颜色, 同上三态
static NSString *spectrumColorA = nil;         // 3.0.55: 频谱条固定色(起始)
static NSString *spectrumColorB = nil;         // 3.0.55: 频谱条固定色(结束)
static double rhythmParticleAlpha = 1.0;       // 3.0.48: 粒子透明度
static double rhythmRingFollowAlpha = 1.0;     // 3.0.48: 环跟随透明度
static int  rhythmParticleCount = 12;          // 3.0.47: 参考视频里只有十几颗
static double rhythmStrength = 0.90;           // 律动强度(刻度最长值的比例)
static double rhythmBeatScale = 0.70;          // 专辑律动幅度
static double rhythmRingWidth = 2.2;           // 3.0.47: 刻度粗细(参考约 2pt)
static NSString *rhythmColorA = nil;           // 渐变起始色(#E59971)
static NSString *rhythmColorB = nil;           // 渐变结束色(#948FFF)
/* 3.0.53: 粒子独立渐变起止色(截图 #FFFFBC / #BFCDF8), 在偏好读取里就要用到,
   所以定义提到文件前部; 取色函数在律动模块里, 这里先声明。 */
static UIColor *gDIParticleColA = nil;
static UIColor *gDIParticleColB = nil;
/* 3.0.56: 粒子颜色/模式变了 → 已存在的粒子立刻换色(定义提前, 偏好读取里就要用到) */
static BOOL gDIParticleColorDirty = YES;
static UIColor *diRhythmHexColor(NSString *hex, UIColor *def) {
    if(![hex isKindOfClass:NSString.class])return def;
    NSString *v=[hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if(v.length!=6 && v.length!=8)return def;
    unsigned long long n=0;if(![[NSScanner scannerWithString:v] scanHexLongLong:&n])return def;
    CGFloat alpha=1;
    if(v.length==8){alpha=(n&255)/255.0;n>>=8;}
    return [UIColor colorWithRed:((n>>16)&255)/255.0 green:((n>>8)&255)/255.0 blue:(n&255)/255.0 alpha:alpha];
}

/* ---------- 粒子池(实心点 + 空心几何) ----------
   3.0.55 重写, 针对"一卡一卡"和"不自然"两个问题:

   ① 位置不再"跳": 旧版每个鼓点直接给 position 加 2.6~7px 的偏移, 然后 180ms 衰减,
      本质是**瞬移**, 一帧之内位置突变 → 肉眼就是卡一下。现在鼓点只往速度里注入
      冲量(push), 位置靠积分推进, 任何时刻都是连续的。
   ② 去掉 shadow: 每颗粒子都带 shadowRadius 的 CAShapeLayer, 在灵动岛这么大的
      合成层里 25~40 颗粒子 = 几十次离屏模糊, 主线程/GPU 一忙就掉帧。
   ③ 时间常数化: 摆动、冲量衰减全部用 dt 计算, 60/120Hz 手感一致。
   ④ 出生/消失都带淡入淡出, 不会凭空出现或突然消失。 */
#define DI_DOT_CAP 64
typedef struct {
    float ang, rad;          /* 极坐标位置 */
    float spin, drift;       /* 角速度 / 恒定向外速度(px/s) */
    float push;              /* 鼓点冲量(px/s), 指数衰减 */
    float sway, swayAmp, swayPhase;   /* 横向自然摆动 */
    float size, rot, rotSpd;
    float life, maxLife, phase, beatGain;
    int   shape;             /* 0 实心点 1 空心菱形 2 空心方块 3 空心三角 */
    float tint;              /* 0~1: 在粒子起始色/结束色之间插值的位置 */
} DIDot;

static DIDot gDIDots[DI_DOT_CAP];
static CALayer *gDIDotLayer[DI_DOT_CAP];
static CALayer *gDIDotClipLayer = nil;    /* 3.0.58: 粒子容器(带"挖掉专辑"的遮罩) */
static CAShapeLayer *gDIDotMaskLayer = nil;
static float gDICoverScaleNow = 1.0f;     /* 封面当前缩放(遮罩孔跟着走) */
static int gDIDotCount = 0;
static float gDISpawnAcc = 0.0f;

static float diFxRand01(void) { return (float)arc4random_uniform(10000)/10000.0f; }

/* ===== 3.0.92: 形状换成 FlexMusic 1.1.6 逆向后逐点还原的那四种 =====
   style%4: 0 空心三角 / 1 空心菱形 / 2 实心圆 / 3 空心四角星。
   坐标、线宽都是它二进制里的原始值(三角 6.6x6.6、菱形 6.2x8.0、圆 ⌀4.9、
   星 9.2x9.2; 线宽 1.15/1.10/0.70/0.95), 再乘用户「粒子大小」倍率。
   以前那套是自己的画法(实心点/方块/三角), 观感跟参考实现不是一回事。 */
static CGFloat diFxShapeSide(int shape) {
    switch (shape) {
        case 1:  return 8.0f;    /* 菱形: 高 8.0 */
        case 2:  return 4.9f;    /* 圆: ⌀4.9 */
        case 3:  return 9.2f;    /* 四角星: ±4.6 */
        default: return 6.6f;    /* 三角: 高 6.6 */
    }
}
static CGFloat diFxShapeLine(int shape) {
    switch (shape) {
        case 1:  return 1.10f;
        case 2:  return 0.70f;
        case 3:  return 0.95f;
        default: return 1.15f;
    }
}
static CGPathRef diFxShapePath(int shape, CGFloat m) {
    CGMutablePathRef p = CGPathCreateMutable();
    if (m < 0.05f) m = 0.05f;
    switch (shape) {
        case 1:   /* 菱形: (0,-4) → (3.1,0) → (0,4) → (-3.1,0) */
            CGPathMoveToPoint(p, NULL, 0.0f, -4.0f * m);
            CGPathAddLineToPoint(p, NULL, 3.1f * m, 0.0f);
            CGPathAddLineToPoint(p, NULL, 0.0f, 4.0f * m);
            CGPathAddLineToPoint(p, NULL, -3.1f * m, 0.0f);
            CGPathCloseSubpath(p);
            break;
        case 2:   /* 实心圆: rect(-2.45,-2.45,4.9,4.9) */
            CGPathAddEllipseInRect(p, NULL,
                CGRectMake(-2.45f * m, -2.45f * m, 4.9f * m, 4.9f * m));
            break;
        case 3:   /* 四角星: 外尖 ±4.6 / 内尖 ±1.15 */
            CGPathMoveToPoint(p, NULL, 0.0f, -4.6f * m);
            CGPathAddLineToPoint(p, NULL, 1.15f * m, -1.15f * m);
            CGPathAddLineToPoint(p, NULL, 4.6f * m, 0.0f);
            CGPathAddLineToPoint(p, NULL, 1.15f * m, 1.15f * m);
            CGPathAddLineToPoint(p, NULL, 0.0f, 4.6f * m);
            CGPathAddLineToPoint(p, NULL, -1.15f * m, 1.15f * m);
            CGPathAddLineToPoint(p, NULL, -4.6f * m, 0.0f);
            CGPathAddLineToPoint(p, NULL, -1.15f * m, -1.15f * m);
            CGPathCloseSubpath(p);
            break;
        default:  /* 三角: (0,-3.8) → (3.3,2.8) → (-3.3,2.8) */
            CGPathMoveToPoint(p, NULL, 0.0f, -3.8f * m);
            CGPathAddLineToPoint(p, NULL, 3.3f * m, 2.8f * m);
            CGPathAddLineToPoint(p, NULL, -3.3f * m, 2.8f * m);
            CGPathCloseSubpath(p);
            break;
    }
    return p;
}

static void diFxRemoveAllDots(void) {
    for (int i = 0; i < DI_DOT_CAP; i++) {
        [gDIDotLayer[i] removeFromSuperlayer];
        gDIDotLayer[i] = nil;
        gDIDots[i].life = 0;
    }
    [gDIDotMaskLayer removeFromSuperlayer];
    gDIDotMaskLayer = nil;
    [gDIDotClipLayer removeFromSuperlayer];
    gDIDotClipLayer = nil;
    gDIDotCount = 0;
    gDISpawnAcc = 0;
}

/* 3.0.58: 粒子"在专辑后面"的正确做法。
   以前两种都不行:
     · zPosition 960 放最上面 + 半径门控 → 粒子只在封面边缘外面出现, 用户说"启动太外面";
     · zPosition -1 压到下面 → 播放卡的磨砂/背景层本身就是 host 的子层, 直接把粒子整块盖掉。
   现在: 所有粒子挂在一个**带遮罩的容器层**里, 遮罩 = 整块宿主 - 专辑那个圆(奇偶填充)。
   圆里面的粒子被裁掉(等于被专辑挡住), 圆外面的照常显示 —— 视觉上就是"从专辑背后飘出来",
   而且不依赖任何层的叠放顺序, 不会被背景吃掉。 */
static void diFxEnsurePool(UIView *host) {
    if (!host) return;
    CALayer *hl = host.layer;
    if (!hl) return;
    if (!gDIDotClipLayer) {
        gDIDotClipLayer = [CALayer layer];
        gDIDotClipLayer.zPosition = 960.0f;
    }
    if (gDIDotClipLayer.superlayer != hl) [hl addSublayer:gDIDotClipLayer];
    /* 3.0.79: 暂停时整个容器被设为透明(彻底隐藏), 恢复播放要还原 */
    if (gDIDotClipLayer.opacity < 0.99f) gDIDotClipLayer.opacity = 1.0f;
    for (int i = 0; i < DI_DOT_CAP; i++) {
        CALayer *l = gDIDotLayer[i];
        if (!l) {
            l = [CAShapeLayer layer];
            l.opacity = 0.0f;
            l.contentsScale = UIScreen.mainScreen.scale;
            gDIDotLayer[i] = l;
        }
        if (l.superlayer != gDIDotClipLayer) [gDIDotClipLayer addSublayer:l];
    }
}

/* 遮罩: 宿主整块 + 中间挖掉专辑的圆。只在尺寸/圆心/半径真的变了才重建路径。 */
static void diFxUpdateMask(CGRect cover, float coverScale) {
    if (!gDIDotClipLayer) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CALayer *sup = gDIDotClipLayer.superlayer;
    /* 统一用 (0,0) 原点的坐标: 容器层 bounds 和遮罩 frame 都按这个来,
       免得宿主 bounds.origin 不为 0 时孔偏掉。 */
    CGSize hs = sup ? sup.bounds.size : cover.size;
    CGRect b = CGRectMake(0, 0, hs.width, hs.height);
    if (!CGSizeEqualToSize(gDIDotClipLayer.bounds.size, hs)) {
        gDIDotClipLayer.bounds = b;
        gDIDotClipLayer.position = CGPointMake(hs.width / 2.0, hs.height / 2.0);
    }
    /* 3.0.61: 孔**固定** 1.02R, 绝不跟封面缩放走。
       474 用户: "专辑跟随律动怎么会加到粒子上呢? 我要的是专辑" —— 根就在这一行:
       孔跟着封面一涨一缩, 边缘那圈粒子每一下鼓点被"吃掉"又"吐出来",
       看上去就是粒子在跟着鼓点抽。现在孔不动, 粒子的可见范围就完全由它自己的
       漂移决定; 封面涨到 1.18R 时顶多在边缘盖住几颗粒子(物理上就该被挡住)。 */
    CGFloat r = MAX(4.0, cover.size.width * 0.5 * 1.02 * MAX(0.01f,coverScale));
    CGPoint c = CGPointMake(CGRectGetMidX(cover) - (sup ? sup.bounds.origin.x : 0.0),
                            CGRectGetMidY(cover) - (sup ? sup.bounds.origin.y : 0.0));
    static CGRect lastB; static CGPoint lastC; static CGFloat lastR;
    if (gDIDotMaskLayer && CGRectEqualToRect(lastB, b)
        && fabs(lastC.x - c.x) < 0.5 && fabs(lastC.y - c.y) < 0.5
        && fabs(lastR - r) < 0.4) { [CATransaction commit]; return; }
    lastB = b; lastC = c; lastR = r;
    if (!gDIDotMaskLayer) {
        gDIDotMaskLayer = [CAShapeLayer layer];
        gDIDotMaskLayer.fillRule = kCAFillRuleEvenOdd;
        gDIDotClipLayer.mask = gDIDotMaskLayer;
    }
    gDIDotMaskLayer.frame = b;
    CGMutablePathRef mp = CGPathCreateMutable();
    CGPathAddRect(mp, NULL, b);
    CGPathAddEllipseInRect(mp, NULL, CGRectMake(c.x - r, c.y - r, r * 2, r * 2));
    gDIDotMaskLayer.path = mp;
    CGPathRelease(mp);
    [CATransaction commit];
}

/* 调色板定义在后面的重建区, 粒子出生时要先用, 这里前置声明 */
static void diColorPalette(int mode, NSString *hexA, NSString *hexB,
                           UIColor *defA, UIColor *defB,
                           double huePhase, BOOL forParticles,
                           UIColor **outA, UIColor **outB);

static UIColor *diFxParticleColorBetween(UIColor *a, UIColor *b, float t) {
    if (!a) a = [UIColor colorWithRed:1.000 green:1.000 blue:0.737 alpha:1.0]; /* #FFFFBC */
    if (!b) b = [UIColor colorWithRed:0.749 green:0.804 blue:0.973 alpha:1.0]; /* #BFCDF8 */
    CGFloat ar = 1, ag = 1, ab = 1, aa = 1, br = 1, bg = 1, bb = 1, ba = 1;
    [a getRed:&ar green:&ag blue:&ab alpha:&aa];
    [b getRed:&br green:&bg blue:&bb alpha:&ba];
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    return [UIColor colorWithRed:ar + (br - ar) * t
                           green:ag + (bg - ag) * t
                            blue:ab + (bb - ab) * t
                           alpha:aa + (ba-aa)*t];
}

/* ===== 3.0.92: 出生参数照 FlexMusic 1.1.6 的 spawn 一比一还原 =====
   u1/u2/u3 = arc4random_uniform(10000)/10000:
     angle    = 2π·u1
     radius   = 31.5 + 2.5·u2          (它的布局单位; 这里按封面半径 R/30 等比缩放)
     speed    = 5 + 7·u3 + 4·E          (E = 环能量, 越响初速越快)
     rotation = 2π·u2                   (初始自转角)
     spin     = (u1-0.5)·1.4            (自转速度, rad/s)
     maxLife  = 1.9 + 1.4·u3            (1.9~3.3s)
     style    = rand(4)
   之前那套是"8~14s 寿命 + 摆动 + 鼓点冲量 + 恒定向外 3.5~7px/s", 完全不同。 */
static void diFxSpawnDot(UIView *host, CGRect cover, float energy) {
    if (!host) return;
    diFxEnsurePool(host);
    int slot = -1;
    for (int i = 0; i < DI_DOT_CAP; i++)
        if (gDIDots[i].life <= 0) { slot = i; break; }
    if (slot < 0) return;
    DIDot *d = &gDIDots[slot];

    float E = energy;
    if (E < 0.0f) E = 0.0f;
    if (E > 1.0f) E = 1.0f;
    CGFloat R = cover.size.width * 0.5f;
    if (R < 6.0f) R = 6.0f;
    CGFloat k = R / 30.0f;                 /* 参考实现里环半径≈30pt */

    float u1 = diFxRand01(), u2 = diFxRand01(), u3 = diFxRand01();
    d->ang    = (float)(2.0 * M_PI) * u1;
    d->rad    = (float)((31.5 + 2.5 * u2) * k);
    d->drift  = (float)((5.0 + 7.0 * u3 + 4.0 * E) * k);   /* 径向速度 pt/s */
    d->push   = 0.0f;
    d->sway   = 0.0f;  d->swayAmp = 0.0f;  d->swayPhase = 0.0f;
    d->rot    = (float)(2.0 * M_PI) * u2;
    d->rotSpd = (u1 - 0.5f) * 1.4f;
    d->shape  = (int)arc4random_uniform(4);
    d->maxLife = 1.9f + 1.4f * u3;
    d->life    = d->maxLife;
    d->phase   = 0.0f;
    d->beatGain = 0.0f;
    d->tint    = diFxRand01();
    gDIDotCount++;

    float m = (float)rhythmParticleSize;
    if (m < 0.05f) m = 0.05f;
    CGFloat side = diFxShapeSide(d->shape) * m;
    d->size = (float)side;

    UIColor *pa = nil, *pb = nil;
    diColorPalette(particleColorMode, nil, nil, gDIParticleColA, gDIParticleColB,
                   gDIHuePhase, YES, &pa, &pb);
    UIColor *tint = diFxParticleColorBetween(pa, pb, d->tint);

    CALayer *layer = gDIDotLayer[slot];
    if (!layer) layer = [CAShapeLayer layer];
    CAShapeLayer *sl = (CAShapeLayer *)layer;
    /* bounds 以 0 为中心(负原点): anchorPoint(0.5,0.5) 正好落在 position 上,
       路径画在 0 附近就居中 —— 以前 bounds 从 (0,0) 起, 图形整体偏左上半个身位。 */
    sl.bounds = CGRectMake(-side * 0.5f, -side * 0.5f, side, side);
    CGPathRef path = diFxShapePath(d->shape, m);
    sl.path = path;
    CGPathRelease(path);
    if (d->shape == 2) {                       /* 实心圆 */
        sl.fillColor = tint.CGColor;
        sl.strokeColor = UIColor.clearColor.CGColor;
        sl.lineWidth = 0.0f;
    } else {                                   /* 空心几何: 只描边, 内部必须透明 */
        sl.fillColor = UIColor.clearColor.CGColor;
        sl.strokeColor = tint.CGColor;
        sl.lineWidth = diFxShapeLine(d->shape) * m;
    }
    sl.lineJoin = kCALineJoinRound;
    sl.shadowOpacity = 0.0f;
    sl.opacity = 0.0f;
}

static float __attribute__((unused)) diFxSmoothStep(float a, float b, float x) {
    if (b <= a) return x >= b ? 1.0f : 0.0f;
    float t = (x - a) / (b - a);
    if (t < 0.0f) t = 0.0f;
    if (t > 1.0f) t = 1.0f;
    return t * t * (3.0f - 2.0f * t);
}

/* ===== 3.0.92: 存活更新照 FlexMusic 的 update 还原 =====
   life -= dt; radius += speed·dt; rotation += spin·dt;
   progress = 1 - life/max(maxLife,0.16);
   fadeIn   = min(progress/0.001, 1)      (出生即满, 没有 0.8s 淡入)
   fadeOut  = min(life/0.72, 1)           (最后 0.72s 线性淡出)
   opacity  = 粒子透明 · fadeIn · fadeOut
   position = center + radius·(cos angle, sin angle)
   scale    = 0.72 + 0.48·progress        (慢慢变大, 不是鼓点放大)
   transform= rotateZ(rotation) × scale
   angle 一帧都不变 —— 粒子只沿出生方向直线外飘, 不绕圈、不摆动、不吃鼓点。 */
static void diFxUpdateDots(UIView *host, CGRect cover, float dt,
                           float energy, BOOL active) {
    if (!host) return;
    (void)energy;
    if (gDICoverScaleNow <= 0.05f) gDICoverScaleNow = 1.0f;
    diFxUpdateMask(cover, gDICoverScaleNow);
    if(gDIDotClipLayer){
        CGFloat sc=rhythmOn?gDICoverScaleNow:1.0f;
        CGPoint c=CGPointMake(CGRectGetMidX(cover)-host.bounds.origin.x,CGRectGetMidY(cover)-host.bounds.origin.y);
        CATransform3D tr=CATransform3DIdentity;
        tr=CATransform3DTranslate(tr,c.x,c.y,0);
        tr=CATransform3DScale(tr,sc,sc,1);
        tr=CATransform3DTranslate(tr,-c.x,-c.y,0);
        [CATransaction begin];[CATransaction setDisableActions:YES];
        gDIDotClipLayer.sublayerTransform=tr;
        [CATransaction commit];
    }
    if (gDIDotCount == 0) return;

    CGFloat cx = CGRectGetMidX(cover) - host.bounds.origin.x;
    CGFloat cy = CGRectGetMidY(cover) - host.bounds.origin.y;
    int limit = rhythmParticleCount;
    if (limit < 0) limit = 0;
    if (limit > DI_DOT_CAP) limit = DI_DOT_CAP;
    /* 3.0.95: existing particles follow the measured kick, not just spawn rate.
       Strength affects the transient only; zero preserves natural drift/opacity. */
    float beat = 0.0f; // reference particles have no independent beat pulse
    float strength = fminf(2.0f, fmaxf(0.0f, (float)rhythmParticleStrength));
    float beatTarget = beat * strength;
    float alphaMul = (float)rhythmParticleAlpha;
    if (alphaMul < 0.0f) alphaMul = 0.0f;
    if (alphaMul > 1.6f) alphaMul = 1.6f;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    int alive = 0;
    for (int i = 0; i < DI_DOT_CAP; i++) {
        DIDot *d = &gDIDots[i];
        CALayer *layer = gDIDotLayer[i];
        if (!layer) continue;
        if (d->life <= 0.0f) {                 /* 空槽: 只保证不可见, 不动图层树 */
            if (layer.opacity != 0.0f) layer.opacity = 0.0f;
            continue;
        }
        /* 停用 / 暂停 / 超出「粒子数量」: 直接判死并留在池里等重用(参考实现的做法) */
        if (!active || !rhythmParticlesOn || i >= limit) {
            d->life = 0.0f;
            layer.opacity = 0.0f;
            continue;
        }
        d->life -= dt;
        if (d->life <= 0.0f) {
            d->life = 0.0f;
            layer.opacity = 0.0f;
            continue;
        }
        d->rad += d->drift * dt;
        d->rot += d->rotSpd * dt;

        float progress = 1.0f - d->life / MAX(d->maxLife, 0.16f);
        if (progress < 0.0f) progress = 0.0f;
        if (progress > 1.0f) progress = 1.0f;
        float fadeIn  = MIN(progress / 0.001f, 1.0f);
        float fadeOut = MIN(d->life / 0.72f, 1.0f);
        d->beatGain = beatTarget;
        float pulse = beatTarget;
        float alpha = alphaMul * fadeIn * fadeOut * (1.0f + 0.22f * pulse);
        if (alpha < 0.0f) alpha = 0.0f;
        if (alpha > 1.0f) alpha = 1.0f;

        /* Offset is transient, never accumulated into drift: no speed runaway. */
        float radialPulse = cover.size.width * 0.055f * pulse;
        // Reference artRingContainer scales particle offsets AND glyphs together.
        // Keep the verified visible host; apply the same affine transform numerically.
        float groupScale = 1.0f; // parent sublayerTransform applies the shared scale once
        layer.position = CGPointMake(cx + cosf(d->ang) * ((d->rad + radialPulse)*groupScale),
                                     cy + sinf(d->ang) * ((d->rad + radialPulse)*groupScale));
        layer.opacity = alpha;
        float sc = (0.72f + 0.48f * progress) * (1.0f + 0.60f * pulse) * groupScale;
        CATransform3D tr = CATransform3DMakeRotation(d->rot, 0, 0, 1);
        layer.transform = CATransform3DScale(tr, sc, sc, 1.0f);
        alive++;
    }
    gDIDotCount = alive;
    [CATransaction commit];
    static CFTimeInterval particleProbeAt = 0;
    static float particlePeak = 0;
    particlePeak = fmaxf(particlePeak, beatTarget);
    CFTimeInterval probeNow = CACurrentMediaTime();
    if (logEnabled && active && probeNow - particleProbeAt >= 10.0) {
        RLog(@"[粒子鼓点] 存活=%d 强度=%.2f 两秒峰值=%.3f 缩放增益=%.3f 径向增益=%.2fpt 同步组缩放=%.4f 额外弹跳=%d", alive, strength, particlePeak, 0.60f*particlePeak, cover.size.width*0.055f*particlePeak, gDICoverScaleNow, diParticleExtraBeat);
        particleProbeAt = probeNow;
        particlePeak = 0;
    }
}

/* ===== 3.0.92: 环能量 —— FlexMusic 的 energy 通道 =====
   参考实现: 每段 target 夹到 [0,1]; 上升用 (0.46+0.10·target)、下降用 0.12 的逐帧系数
   逼近 current; 环能量 = mean(current[0..N-1]), 再夹到 [0,1]。
   我们的频谱是 dB 绝对值映射(没有 AGC), 但动态走向一致, 公式原样搬过来即可。
   时间基: 上述系数是 60Hz 每帧的, 这里换成 dt·60 的幂次, 120Hz 上手感一致。 */
static float gDIFxEneCur[DI_AU_BANDS];
static float gDIFxEnergy = 0.0f;
static float gDIFxBeatBase = 0.0f;
static float gDIFxBeatPulse = 0.0f;
static float gDIFxBeatScale = 1.0f;

/* ===== 3.0.93: 鼓点专用能量 —— 上一版"鼓点没效果"的根因就在这里 =====
   3.0.92 把"24 段 dB 均值的固定线性标定"当 E 直接喂给 beat 包络。实测不行:
   本机送来的 24 段是 dB 绝对值映射(没有 AGC), 音乐里长期钉在 0.70~0.78,
   相邻两包(16~33ms)只差 0.01~0.03。于是
     excess = E - (基线·1.08 + 0.025) 恒为 0(均值永远追不上自己的 1.08 倍),
     drive 只剩 (E-0.58)·0.55 ≈ 0.08 → 脉冲 ≈ 0.08 → 缩放 1.008。
   1% 缩放落在 57pt 封面上是 0.5pt —— 肉眼看就是"完全没动"。
   FlexMusic 的 E 能顶到 1, 是因为它每段前面有 AGC(§3: 每带维护峰值,
   上升跟随新值、下降 0.985·old+0.015·value), 归一后每段在 0.2~1.0 大幅摆动。
   这里补两条"局部归一"链, 把 dB 的小跳变放大回 0~1:
     底噪: 只允许慢慢爬升(0.003/帧), 下落快(0.30/帧)
     峰值: 上升快(0.30/帧), 只允许慢慢回落(0.004/帧)
     n    = (v-底噪) / max(峰值-底噪, 最小量程)  → 静时 0.05~0.25, 底鼓 0.8~1.0
   低频链(0~4 段 ≈ 60~200Hz)权重 0.72、全带链 0.28 —— 鼓点主要看低频,
   整体段落强弱也参与一点(参考实现是 72 段等权均值)。最后与统一的低音鼓
   包络 gDIKick(样本域触发, 和粒子同一个鼓)取大: 那一下"咚"必定推得起来。 */
static float gDIFxBeatE = 0.0f;          /* 0~1, 只喂鼓点包络; 粒子仍用 gDIFxEnergy */
static float gDIFxBeatBaseSee = 0.0f;    /* 探针: 当前基线 */
static float gDIFxBeatExcSee = 0.0f;     /* 探针: 上一次超出量 */
static float gDIFxBeatDrvSee = 0.0f;     /* 探针: 上一次驱动值 */
static float gDIFxNormFloor[2] = {0.0f, 0.0f};   /* 0=低频链 1=全带链 */
static float gDIFxNormPeak[2]  = {0.0f, 0.0f};
static float gDIFxNormN[2]     = {0.0f, 0.0f};

static float diFxClamp01(float v) {
    if (v < 0.0f) return 0.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}

static float __attribute__((unused)) diFxNormChain(int idx, float v, float step, float minRange) {
    float f = gDIFxNormFloor[idx], p = gDIFxNormPeak[idx];
    if (!(p > 0.0f) || p < f) { f = v; p = v + minRange; }
    float kFast = 1.0f - powf(1.0f - 0.30f, step);
    float kFUp  = 1.0f - powf(1.0f - 0.003f, step);
    float kPDn  = 1.0f - powf(1.0f - 0.004f, step);
    if (v < f) f += (v - f) * kFast; else f += (v - f) * kFUp;
    if (v > p) p += (v - p) * kFast; else p += (v - p) * kPDn;
    if (p < f + minRange) p = f + minRange;
    gDIFxNormFloor[idx] = f;
    gDIFxNormPeak[idx] = p;
    return diFxClamp01((v - f) / (p - f));
}

static void diFxAdvanceEnergy(BOOL active, BOOL real, float dt) {
    float step = dt * 60.0f;
    if (step <= 0.0f) return;
    float sum = 0.0f;
    for (int i = 0; i < DI_AU_BANDS; i++) {
        /* 真频谱用未平滑的原始段(和参考实现一样自己平滑); 合成节拍没有 raw, 用平滑段 */
        float tgt = active ? (real ? gDIBandRaw[i] : gDIBandSmooth[i]) : 0.0f;
        if (tgt < 0.0f) tgt = 0.0f;
        if (tgt > 1.0f) tgt = 1.0f;
        float cur = gDIFxEneCur[i];
        float rate = (tgt > cur) ? (0.46f + 0.10f * tgt) : 0.12f;
        rate = 1.0f - powf(1.0f - rate, step);
        cur += (tgt - cur) * rate;
        if (cur < 0.0f) cur = 0.0f;
        if (cur > 1.0f) cur = 1.0f;
        gDIFxEneCur[i] = cur;
        sum += cur;
    }
    (void)sum;
    /* Reference channel uses its own FFT/AGC, not legacy dB/kick normalization. */
    float referenceSum=0;
    BOOL referenceLive=active && real && gDIReferenceSeen;
    for(int i=0;i<72;i++) {
        float target=referenceLive?gDIReferenceRaw[i]:0;
        float current=gDIReferenceCurrent[i];
        float rate=target>current?(0.46f+0.10f*target):0.12f;
        current+=(target-current)*(1-powf(1-rate,step));
        gDIReferenceCurrent[i]=current;
        referenceSum+=current;
    }
    gDIFxEnergy=referenceSum/72.0f;
    gDIFxBeatE=gDIFxEnergy;
    gDIFxNormN[0]=gDIFxNormN[1]=0;

}

/* ===== 3.0.92: 专辑鼓点包络 —— FlexMusic 的 beatScale 原样还原 =====
   E 夹到 [0,1]; baseline 以 0.028/帧 跟踪(≈2.4s); 
     excess = max(E - (baseline·1.08 + 0.025), 0)      ← 相对基线的瞬态
     drive  = min(1, max(E-0.58,0)·0.55 + excess·5.6)
     pulse: 上升逼近 72%/帧, 否则每帧 ×0.79
     desired = 1 + min(0.22, pulse·0.095·clamp(强度,0.3,2.5))
     scale: 上升 0.58 / 下降 0.20 逼近 desired
   停用: baseline×0.92、pulse×0.72、desired=1; 距 1 小于 0.0005 时精确归位。
   它是"相对基线的能量瞬态", 不是 BPM/底鼓识别 —— 这正是参考实现的手感来源。
   3.0.93: 公式一个字没改, 只把输入 E 换成 gDIFxBeatE(见上), 并补探针。 */
static float diFxAdvanceBeat(BOOL active, float energy, double strengthSlider, float dt) {
    float step = dt * 60.0f;
    if (step <= 0.0f) return gDIFxBeatScale;
    float desired;
    if (active) {
        float E = energy;
        if (E < 0.0f) E = 0.0f;
        if (E > 1.0f) E = 1.0f;
        if (gDIFxBeatBase <= 0.001f) gDIFxBeatBase = E;
        float kBase = 1.0f - powf(1.0f - 0.028f, step);
        gDIFxBeatBase += (E - gDIFxBeatBase) * kBase;
        float excess = E - (gDIFxBeatBase * 1.08f + 0.025f);
        if (excess < 0.0f) excess = 0.0f;
        float drive = (E > 0.58f ? (E - 0.58f) : 0.0f) * 0.55f + excess * 5.6f;
        if (drive > 1.0f) drive = 1.0f;
        gDIFxBeatBaseSee = gDIFxBeatBase;
        gDIFxBeatExcSee = excess;
        gDIFxBeatDrvSee = drive;
        if (drive > gDIFxBeatPulse) {
            float k = 1.0f - powf(1.0f - 0.72f, step);
            gDIFxBeatPulse += (drive - gDIFxBeatPulse) * k;
        } else {
            gDIFxBeatPulse *= powf(0.79f, step);
        }
        /* 滑杆 0~2 → 参考实现的 strength 域(0.3~2.5)。默认 0.70 → 2.1,
           与旧版"0.20×0.70 幅度"在 pulse≈0.7 时正好对上, 老手感不会突变。 */
        float st = (float)strengthSlider;
        if (st < 0.3f) st = 0.3f;
        if (st > 2.5f) st = 2.5f;
        float amp = gDIFxBeatPulse * 0.095f * st;
        if (amp > 0.22f) amp = 0.22f;
        desired = 1.0f + amp;
    } else {
        gDIFxBeatBase *= powf(0.92f, step);
        gDIFxBeatPulse *= powf(0.72f, step);
        /* 3.0.93: 停一会儿之后从干净状态重来 —— 否则再按播放时基线还挂在
           上回的低位, 第一帧 excess 会顶满, 封面"啪"地放大一下。 */
        /* Reference: retain the decaying baseline and pulse. */
        desired = 1.0f;
    }
    float rate = (desired > gDIFxBeatScale) ? 0.58f : 0.20f;
    rate = 1.0f - powf(1.0f - rate, step);
    gDIFxBeatScale += (desired - gDIFxBeatScale) * rate;
    /* 拍与拍之间必须严格回到 1.000(3.0.64 用户"静止时必须是 1.000") ——
       指数回落永远差一点, 这里在脉冲已经落干净时直接吸住。 */
    /* Reference snaps to identity only when inactive, below 0.0005. */
    if (!active && fabsf(gDIFxBeatScale - 1.0f) < 0.0005f) gDIFxBeatScale = 1.0f;
    return gDIFxBeatScale;
}

/* 3.0.71: 视觉"咚" —— 服务端(样本域)触发时调一次 */
static void diKickFire(float amp, CFTimeInterval at) {
    if (amp <= 0.05f) return;
    if (amp > 1.0f) amp = 1.0f;
    CFTimeInterval now = CACurrentMediaTime();
    if (at > now) at = now;
    if (now - at > 0.30) at = now - 0.30;     /* 年龄补偿上限, 免得一上来就是衰减尾巴 */
    gDIKickPunchAmp = amp;
    gDIKickPunchT = at;
    /* 3.0.74: 不再一帧冲顶。只记录目标值和起音时刻, 由统一顺滑包络
       (diRhythmAdvanceSpectrum 末尾)在 ~45ms 内平滑顶到位 —— 68 的"微动态"
       幅度不变, 但 120Hz 上不再是"啪"一下, 而是同样快的、肉眼连续的弹起。 */
    if (amp >= gDIKickTarget) { gDIKickTarget = amp; gDIKickAtkT = now; }
    gDILastKickT = now;
    gDILowNPrev = 1.0f;
    gDIKickHoldN = 1.0f;
    gDIKickArmed = NO;
}

/* 当前这一下的视觉量: 16ms 顶到位, 95ms 收回, 0.30s 归零 */
static float diKickPunchNow(void) {
    if (gDIKickPunchAmp <= 0.001f) return 0.0f;
    double t = CACurrentMediaTime() - gDIKickPunchT;
    if (t < 0.0) t = 0.0;
    if (t > 0.30) { gDIKickPunchAmp = 0.0f; return 0.0f; }
    double attack = t < 0.016 ? (t / 0.016) : 1.0;
    double decay = exp(-MAX(0.0, t - 0.016) / 0.095);
    return gDIKickPunchAmp * (float)(attack * decay);
}

/* 颜色/模式改了: 已存在的粒子立刻换色(以前只影响新生粒子, 用户以为"自定义没用") */
static void diFxRefreshColors(void) {
    if (gDIDotCount <= 0) return;
    UIColor *pa = nil, *pb = nil;
    diColorPalette(particleColorMode, nil, nil, gDIParticleColA, gDIParticleColB,
                   gDIHuePhase, YES, &pa, &pb);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < DI_DOT_CAP; i++) {
        CALayer *layer = gDIDotLayer[i];
        if (!layer || gDIDots[i].life <= 0) continue;
        CAShapeLayer *sl = (CAShapeLayer *)layer;
        UIColor *tint = diFxParticleColorBetween(pa, pb, gDIDots[i].tint);
        if (gDIDots[i].shape == 2) sl.fillColor = tint.CGColor;   /* 3.0.92: 实心圆 */
        else sl.strokeColor = tint.CGColor;
    }
    [CATransaction commit];
}

/* ---------- 目标/宿主 ---------- */
static BOOL diViewIsSuggestions(UIView *v) {
    UIView *p = v;
    for (int i = 0; i < 6 && p; i++) {
        if ([NSStringFromClass(p.class) containsString:@"Suggestion"]) return YES;
        p = p.superview;
    }
    return NO;
}

/* 3.0.63: 476 用户: "打开功能会影响展开的专辑, 展开跟不展开的不要影响"。
   控制中心模块里的封面父链上有 MRUControlCenterView / CCUIContentModule,
   而"点开的大播放页"父链上是 MRUNowPlayingViewController / *Expanded。
   前者才归律动管, 后者一个字都不写。 */
static BOOL diArtInExpandedPlayer(UIView *v) {
    UIView *p = v;
    for (int i = 0; i < 16 && p; i++) {
        NSString *cn = NSStringFromClass(p.class);
        if ([cn containsString:@"ControlCenter"] || [cn containsString:@"ContentModule"]) return NO;
        if ([cn containsString:@"SystemAperture"]) return NO;
        if ([cn containsString:@"NowPlayingViewController"] ||
            [cn containsString:@"NowPlayingExpanded"] ||
            [cn containsString:@"Expanded"]) return YES;
        p = p.superview;
    }
    return NO;
}

static BOOL diFxExpandedOrSuggestion(UIView *v);
static UIView *diRhythmPickTarget(void) {
    UIView *best = nil;
    CGFloat bestArea = 0;
    if (!gDIArtKnown) return nil;
    for (UIView *v in gDIArtKnown.allObjects) {
        if (!v.window || v.hidden || v.alpha < 0.3) continue;
        if (diFxExpandedOrSuggestion(v)) continue;
        if (diViewIsSuggestions(v)) continue;          /* 3.0.48: 不认"媒体建议"页 */
        if (diArtInExpandedPlayer(v)) continue;        /* 3.0.63: 展开的播放页不归律动管 */
        /* 3.0.67: 呈现层被系统放大 >1.6 倍 = 展开页复用的这张封面(bounds 不变,
           transform 放大) —— 一律不选, 不然律动会写到展开的大专辑上。 */
        {
            CALayer *pl2 = v.layer.presentationLayer;
            if (pl2) {
                CGSize ps2 = pl2.bounds.size;
                if (ps2.width > v.bounds.size.width * 1.6 + 2.0 ||
                    ps2.height > v.bounds.size.height * 1.6 + 2.0) continue;
            }
        }
        CGSize s = v.bounds.size;
        if (s.width < 40 || s.width > 220) continue;
        CGFloat ratio = s.width / MAX(1.0, s.height);
        if (ratio < 0.8 || ratio > 1.25) continue;
        CGFloat area = s.width * s.height;
        if (area > bestArea) { bestArea = area; best = v; }
    }
    return best;
}

static UIView *diRhythmHostFor(UIView *t) {
    if (!t) return nil;
    CGFloat need = MAX(150.0, t.bounds.size.width * 1.35);
    UIView *best = nil;
    UIView *v = t.superview;
    int g = 0;
    while (v && g++ < 9) {
        BOOL clip = v.clipsToBounds || v.layer.masksToBounds;
        if (!clip && v.bounds.size.width >= need) return v;
        if (!clip && !best && v.bounds.size.width >= t.bounds.size.width * 1.25) best = v;
        v = v.superview;
    }
    if (best) return best;
    UIView *s = t.superview;
    while (s && (s.clipsToBounds || s.layer.masksToBounds)) s = s.superview;
    return s ?: t.superview;
}

static CGRect diRhythmCoverRect(UIView *t, UIView *host) {
    /* 3.0.58: **只按原始尺寸算, 不乘封面当前的缩放**。
       3.0.57 这里读了 layer.transform 的缩放, 于是封面每打一下拍, 半径就变一次;
       粒子的位置全部以"封面半径"为基准 → 整片云跟着拍点一抽一抽, 就是用户说的
       "放着一卡一卡的"。现在粒子用固定基准, 只由自己的漂移推进, 位置永远连续。 */
    CGSize s = t.bounds.size;
    CGPoint c = t.center;
    if (t.superview && host) c = [t.superview convertPoint:t.center toView:host];
    return CGRectMake(c.x - s.width / 2, c.y - s.height / 2, s.width, s.height);
}

/* 3.0.56: 鼓点缩放到底该作用在哪个视图上?
   封面 MRUArtworkView 外面往往还套着一层"同尺寸 + clipsToBounds"的圆形容器。
   只缩放封面本身, 会被这层容器裁掉/或者看不太出来 —— 这就是"明明有旋转却看不出抖动"的原因。
   这里向上找: 只要父视图**裁剪**且尺寸和它差不多(<=1.3 倍, 且接近正方形), 就把父视图也算进来,
   最终返回最外层那个"同尺寸裁剪容器"。缩放它, 才不会被自己裁掉。 */
static UIView *diRhythmDriveView(UIView *t) {
    if (!t) return nil;
    UIView *d = t;
    /* 3.0.59: 472 用户看到"专辑后面还有个黑块有鼓点, 上面一层专辑不会动" ——
       我们对 MRUArtworkView 做 transform, 但真正显示封面内容的可能是它外面/里面
       另一层(系统在 MRU 里用了 CAPortalLayer 之类的门户层, 门户内容不跟着源视图的
       transform 走), 于是缩放的只是一个黑色圆底。
       现在继续往上找**同尺寸容器**(尺寸差 <12%、近似正方), 把封面和它的内容层
       一起包进缩放里。3.0.58 要求父层 clipsToBounds 才继续, 这里放宽 —— 播放卡里
       那层圆形容器常常自己不裁(裁的是里面的 mask), 一放宽就断在封面那一层。 */
    for (int i = 0; i < 4; i++) {
        UIView *p = d.superview;
        if (!p) break;
        if (p == p.window) break;
        CGSize a = p.bounds.size, b = d.bounds.size;
        if (b.width < 1.0f || a.width < 1.0f) break;
        CGFloat k = a.width / b.width;
        CGFloat ky = a.height / b.height;
        if (k < 0.88f || k > 1.12f) break;
        if (ky < 0.88f || ky > 1.12f) break;
        CGFloat ratio = a.width / MAX(1.0f, a.height);
        if (ratio < 0.80f || ratio > 1.25f) break;
        d = p;
    }
    return d;
}

static void diCoverRound(UIView *t) {
    if (!t) return;
    if (gDICoverRounded != t) {
        if (gDICoverRounded) {
            gDICoverRounded.layer.cornerRadius = gDICoverOrigRadius;
            gDICoverRounded.layer.masksToBounds = gDICoverOrigClip;
        }
        gDICoverRounded = t;
        gDICoverOrigRadius = t.layer.cornerRadius;
        gDICoverOrigClip = t.layer.masksToBounds;
    }
    CGFloat r = MIN(t.bounds.size.width, t.bounds.size.height) * 0.5f;
    if (fabs(t.layer.cornerRadius - r) > 0.3f || !t.layer.masksToBounds) {
        t.layer.cornerRadius = r;
        t.layer.masksToBounds = YES;
    }
}

static void diCoverUnround(void) {
    if (gDICoverRounded) {
        gDICoverRounded.layer.cornerRadius = gDICoverOrigRadius;
        gDICoverRounded.layer.masksToBounds = gDICoverOrigClip;
    }
    gDICoverRounded = nil;
}

/* ---------- 刻度环 ---------- */
static void diRhythmDetach(void) {
    [diProgressBack removeFromSuperlayer]; [diProgressFront removeFromSuperlayer];
    diProgressBack=nil; diProgressFront=nil;
    if (gDIRhythmRingBox) {
        [gDIRhythmRingBox removeFromSuperlayer];
        gDIRhythmRingBox = nil;
    }
    if (gDIRhythmBarsGrad) {
        [gDIRhythmBarsGrad removeFromSuperlayer];
        gDIRhythmBarsGrad = nil;
    }
    if (gDIRhythmBars) {
        [gDIRhythmBars removeFromSuperlayer];
        gDIRhythmBars = nil;
    }
    gDIBarsModeUsed = -1;
    gDIRhythmRingGrad = nil;
    gDIRhythmRingMask = nil;
    gDIRhythmRingBack = nil;
    gDIRhythmRingFrame = CGRectZero;
    gDIRhythmHost = nil;
    /* 3.0.60: 总开关关掉 / 拆引擎时, 封面要回到原样, 旋转归属也要交还 */
    if (gDIRhythmDrive && gDIRhythmBaseValid && gDIRhythmDrive.window) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        gDIRhythmDrive.layer.transform = gDIRhythmBase;
        [CATransaction commit];
    }
    if (gDIArtSpinYield) {
        UIView *yv = gDIArtSpinYield;
        gDIArtSpinYield = nil;
        if (yv.window) @try { diArtDress(yv); } @catch (__unused NSException *e) {}
    }
    if (gDIRhythmExtraN > 0) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (int i = 0; i < gDIRhythmExtraN; i++)
            if (gDIRhythmExtras[i])
                { [gDIRhythmExtras[i].layer removeAnimationForKey:@"di.rhythm.scale.hold"]; gDIRhythmExtras[i].layer.transform = diRhythmBaseOf(gDIRhythmExtras[i]); }
        [CATransaction commit];
    }
    /* 3.0.67: 摘掉壳和额外视图上遗留的 di.rhythm.tf 兜底动画 —— 它是
       fillMode=forwards + removedOnCompletion=NO, 拆引擎只复位 model 不摘动画的话,
       最后一次的 ~1.1x 缩放会一直冻在封面上(展开态看着"缩着/变形"就是它)。 */
    {
        CALayer *ls[1 + DI_RHYTHM_EXTRA_MAX];
        int n = 0;
        if (gDIRhythmDrive) ls[n++] = gDIRhythmDrive.layer;
        for (int i = 0; i < gDIRhythmExtraN && n < (int)(1 + DI_RHYTHM_EXTRA_MAX); i++)
            if (gDIRhythmExtras[i]) ls[n++] = gDIRhythmExtras[i].layer;
        for (int i = 0; i < n; i++)
            if ([ls[i] animationForKey:@"di.rhythm.tf"])
                [ls[i] removeAnimationForKey:@"di.rhythm.tf"];
    }
    for (int i = 0; i < DI_RHYTHM_EXTRA_MAX; i++) gDIRhythmExtras[i] = nil;
    gDIRhythmExtraN = 0;
    gDIRhythmSkipDv = NO;
    gDIRhythmDriving = NO;
    gDILastAng = 0.0;
    diFxRemoveAllDots();
}

static void diRhythmBuildRing(UIView *host, UIColor *ca, UIColor *cb) {
    CALayer *box = [CALayer layer];
    box.name = @"di.rhythm.ticks";
    box.zPosition = 900;
    box.masksToBounds = NO;
    [host.layer addSublayer:box];

    /* 底层: 同形状的宽描边, 做柔光(参考里刻度是发光的实心棒, 不是细线) */
    CAShapeLayer *back = [CAShapeLayer layer];
    back.fillColor = UIColor.clearColor.CGColor;
    back.strokeColor = ca.CGColor;
    back.lineCap = kCALineCapRound;
    back.opacity = 0.0f;
    back.shadowColor = ca.CGColor;
    back.shadowOpacity = 0.5f;
    back.shadowRadius = 3.0;
    back.shadowOffset = CGSizeZero;
    [box addSublayer:back];

    CAGradientLayer *g = [CAGradientLayer layer];
    @try { [g setValue:@"conical" forKey:@"type"]; } @catch (__unused NSException *e) {}
    g.colors = @[ (__bridge id)ca.CGColor,
                  (__bridge id)cb.CGColor,
                  (__bridge id)ca.CGColor ];
    g.locations = @[ @0.0, @0.5, @1.0 ];
    g.startPoint = CGPointMake(0.5, 0.5);
    g.endPoint = CGPointMake(0.5, 0.0);

    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.fillColor = UIColor.clearColor.CGColor;
    mask.strokeColor = UIColor.whiteColor.CGColor;
    mask.lineWidth = 2.0;
    mask.lineCap = kCALineCapRound;
    g.mask = mask;
    [box addSublayer:g];

    gDIRhythmRingBox = box;
    gDIRhythmRingGrad = g;
    gDIRhythmRingMask = mask;
    gDIRhythmRingBack = back;
    gDIRhythmRingFrame = CGRectZero;
}

/* 刻度: 80 根实心圆头短棒, 长度按 24 段频谱插值 */
static void diRhythmLayoutRing(CGRect cover, const float *bands, BOOL active) {
    if (!gDIRhythmRingBox) return;
    CGFloat R = cover.size.width * 0.5f;
    CGFloat gap = 1.25 * (cover.size.width / 57.0);
    CGFloat maxLen = 8.5 * (cover.size.width / 57.0) * MAX(0.3, rhythmStrength);
    if (maxLen < 2.5) maxLen = 2.5;
    CGFloat tickW = MAX(1.4, R * DI_TICK_W) * (CGFloat)(rhythmRingWidth / 2.2);
    /* Reference keeps stroke width stable; energy changes length, not thickness. */
    gDIRhythmRingMask.lineWidth = tickW;
    if (gDIRhythmRingBack) gDIRhythmRingBack.lineWidth = tickW * 1.25;

    CGFloat pad = R + gap + maxLen + tickW * 2.2 + 3.0;
    CGRect boxFrame = CGRectMake(CGRectGetMidX(cover) - pad, CGRectGetMidY(cover) - pad,
                                 pad * 2, pad * 2);
    if (!CGRectEqualToRect(boxFrame, gDIRhythmRingFrame)) {
        gDIRhythmRingFrame = boxFrame;
        gDIRhythmRingBox.frame = boxFrame;
        gDIRhythmRingGrad.frame = gDIRhythmRingBox.bounds;
        gDIRhythmRingMask.frame = gDIRhythmRingGrad.bounds;
        gDIRhythmRingBack.frame = gDIRhythmRingBox.bounds;
    }

    CGPoint c = CGPointMake(gDIRhythmRingBox.bounds.size.width / 2,
                            gDIRhythmRingBox.bounds.size.height / 2);
    CGFloat r0 = R - 0.25 * (cover.size.width / 57.0);
    /* 3.0.55: 取消 30Hz 降频 —— 120Hz 屏上 30Hz 更新就是"每四帧才动一下"的顿感。
       80 段直线路径的构建开销很小, 每帧重建肉眼才连得上。 */
    CGMutablePathRef tp = CGPathCreateMutable();
    for (int i = 0; i < DI_TICK_N; i++) {
        CGFloat a = (CGFloat)i / (CGFloat)DI_TICK_N * M_PI * 2.0 - M_PI_2;
        /* 3.0.50: 左右对称 —— 以竖轴为镜面, 顶部(中轴)是最低频、最长的刻度,
           两侧依次向高频展开(和频谱条同一种排列), 不再绕圈扫一条彩虹。 */
        CGFloat t01 = (CGFloat)i / (CGFloat)DI_TICK_N;
        CGFloat u = fabs(t01 * 2.0f - 1.0f);              /* 顶部=1, 底部=0 */
        CGFloat pos = (1.0f - u) * (CGFloat)(DI_AU_BANDS - 1);
        int b0 = (int)pos;
        if (b0 < 0) b0 = 0;
        if (b0 > DI_AU_BANDS - 1) b0 = DI_AU_BANDS - 1;
        int b1 = MIN(b0 + 1, DI_AU_BANDS - 1);
        CGFloat fr = pos - floorf((float)pos);
        CGFloat band = bands[b0] * (1.0f - fr) + bands[b1] * fr;
        if (gDIReferenceSeen) {
            int left=(i+71)%72, right=(i+1)%72;
            band=0.1f*gDIReferenceCurrent[left]+0.8f*gDIReferenceCurrent[i]+0.1f*gDIReferenceCurrent[right];
        }
        if (band < 0) band = 0;
        if (band > 1) band = 1;
        CGFloat len = active ? (gap + 0.25*(cover.size.width/57.0) + maxLen*band) : 0;
        CGPathMoveToPoint(tp, NULL, c.x + cos(a) * r0, c.y + sin(a) * r0);
        CGPathAddLineToPoint(tp, NULL, c.x + cos(a) * (r0 + len), c.y + sin(a) * (r0 + len));
    }
    gDIRhythmRingMask.path = tp;
    if (gDIRhythmRingBack) gDIRhythmRingBack.path = tp;
    CGPathRelease(tp);
}

/* Progress is song time / duration, never audio energy or a synthetic loop. */
static void diUpdateProgressRing(UIView *host, CGRect cover, BOOL visible) {
    if (!diProgressRingOn || !host || !visible || diRingDuration <= 0) {
        diProgressBack.hidden=YES; diProgressFront.hidden=YES; return;
    }
    if (!diProgressFront) {
        diProgressBack=[CAShapeLayer layer]; diProgressFront=[CAShapeLayer layer];
        for (CAShapeLayer *l in @[diProgressBack,diProgressFront]) {
            l.fillColor=UIColor.clearColor.CGColor; l.lineCap=kCALineCapRound;
            l.zPosition=945; l.actions=@{@"path":NSNull.null,@"position":NSNull.null,
                @"bounds":NSNull.null,@"strokeEnd":NSNull.null,@"hidden":NSNull.null};
            [host.layer addSublayer:l];
        }
    }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    diProgressBack.hidden=NO; diProgressFront.hidden=NO;
    CGFloat w=diProgressRingWidth;
    CGFloat r=MAX(1,MIN(cover.size.width,cover.size.height)*0.5+w*0.5+1.0);
    CGPoint center=CGPointMake(CGRectGetMidX(cover),CGRectGetMidY(cover));
    UIBezierPath *path=[UIBezierPath bezierPathWithArcCenter:center radius:r
        startAngle:-M_PI_2 endAngle:3*M_PI_2 clockwise:YES];
    UIColor *color=diRhythmHexColor(diProgressRingColor,
        [UIColor colorWithRed:191.0/255 green:205.0/255 blue:186.0/255 alpha:1]);
    diProgressBack.path=path.CGPath; diProgressFront.path=path.CGPath;
    diProgressBack.lineWidth=w; diProgressFront.lineWidth=w;
    diProgressBack.strokeColor=[UIColor colorWithWhite:1 alpha:0.18].CGColor;
    diProgressFront.strokeColor=color.CGColor;
    double elapsed=diRingElapsed;
    if (musicPlaying && diRingRate>0) elapsed+=MAX(0,CFAbsoluteTimeGetCurrent()-diRingStamp)*diRingRate;
    diProgressFront.strokeEnd=MIN(1,MAX(0,elapsed/diRingDuration));
    [CATransaction commit];
}

/* ---------- 频谱条(进度条上方的小竖条) ---------- */
static UIView *diFindSliderIn(UIView *v, int depth) {
    if (!v || depth > 8) return nil;
    if ([NSStringFromClass(v.class) containsString:@"Slider"] &&
        v.bounds.size.width >= 60 && !v.hidden) return v;
    for (UIView *s in v.subviews) {
        UIView *r = diFindSliderIn(s, depth + 1);
        if (r) return r;
    }
    return nil;
}

/* 3.0.49: 滑条查找缓存 —— 之前每个 tick(60Hz)都全树递归扫一遍, 播放卡视图树
   上千个节点, 光这一项就是每秒几万次遍历, 主线程直接被吃满(462 日志的
   "停摆 2~3 秒"+"40009 行日志"就是这种热循环的典型症状)。改 0.5s 找一次。 */
static __weak UIView *gDIRhythmSliderW = nil;
static CFAbsoluteTime gDIRhythmSliderAt = 0;
static void diRhythmUpdateBars(UIView *host, BOOL active) {
    if (!host) return;
    /* 3.0.59: 没音乐时整条频谱隐藏。以前 active=NO 仍然画 40 根 1.5pt 的短杠、opacity 0.25,
       屏幕上就是"一条杠"(用户 472 明确点名)。暂停时它就该彻底消失。 */
    if (!active) {
        /* 3.0.83: 暂停/停止时泡泡也一起清掉, 恢复播放不该有旧泡泡悬在半空 */
        if (gDIBarStyle == 8) {
            for (int i = 0; i < DI_BUBBLE_MAX; i++) gDIBubbles[i].alive = 0;
            for (int i = 0; i < 64; i++) {
                gDIBubbleLastV[i] = 0.0f;
                gDIBubbleNextAt[i] = 0.0;
            }
            gDIBubbleT = 0.0f;
        }
        if (gDIRhythmBarsGrad) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            gDIRhythmBarsGrad.opacity = 0.0f;
            [CATransaction commit];
        }
        return;
    }
    if (!rhythmBarsOn) {
        if (gDIRhythmBarsGrad) { [gDIRhythmBarsGrad removeFromSuperlayer]; gDIRhythmBarsGrad = nil; }
        if (gDIRhythmBars) { gDIRhythmBars = nil; }
        return;
    }
    static CFTimeInterval pathAt=0;
    CFTimeInterval pathNow=CACurrentMediaTime();
    if(pathNow-pathAt<1.0/30.0)return;
    pathAt=pathNow;
    UIView *sl = gDIRhythmSliderW;
    if (!sl || CACurrentMediaTime() - gDIRhythmSliderAt > 0.5) {
        sl = diFindSliderIn(host, 0);
        gDIRhythmSliderW = sl;
        gDIRhythmSliderAt = CACurrentMediaTime();
    }
    if (!sl) {
        if (gDIRhythmBarsGrad) { [gDIRhythmBarsGrad removeFromSuperlayer]; gDIRhythmBarsGrad = nil; }
        if (gDIRhythmBars) { gDIRhythmBars = nil; }
        return;
    }
    CGRect sf = [sl convertRect:sl.bounds toView:host];
    CGFloat bottom = CGRectGetMinY(sf) - 5.0 - (CGFloat)rhythmBarsOffsetY;
    CGFloat height = (CGFloat)rhythmBarsHeight;
    if(!isfinite(bottom)||!isfinite(height)||height<=0 || !isfinite(host.bounds.size.width))return;
    CGFloat top = bottom - height;
    /* 3.0.56: 上下位移放大到 ±150 后, 条可能被推到岛外。以前这里直接 return,
       上一次画的路径会留在屏幕上(看着像"卡住")。现在明确隐藏。 */
    if (top < 2.0 || bottom > host.bounds.size.height - 1.0) {
        if (gDIRhythmBarsGrad) gDIRhythmBarsGrad.opacity = 0.0f;
        return;
    }

    CGFloat x0 = 14.0, x1 = host.bounds.size.width - 14.0;
    CGFloat avail = x1 - x0;
    int n = rhythmBarsCount;
    if (n < 4) n = 4;
    CGFloat gap = 2.0;
    CGFloat bw = (avail - gap * (n - 1)) / (CGFloat)n;
    if (bw < 1.2) { gap = 1.2; bw = (avail - gap * (n - 1)) / (CGFloat)n; }
    if (bw < 0.5) { bw = 0.5; }
    CGFloat maxW = (CGFloat)rhythmBarsWidth;
    if (bw > maxW) {
        bw = maxW;
        CGFloat total = bw * n + gap * (n - 1);
        x0 = (host.bounds.size.width - total) * 0.5f;
        if (x0 < 10.0) x0 = 10.0;
    }
    x0 += (CGFloat)rhythmBarsOffset;

    /* 3.0.55: 条形改成"渐变 + 形状遮罩" —— 这样频谱条也能跟随专辑/固定色/流光,
       而不是写死一个紫色。遮罩是形状层, 渐变填色, 换色不用重建路径。 */
    if (!gDIRhythmBarsGrad) {
        gDIRhythmBarsGrad = [CAGradientLayer layer];
        gDIRhythmBarsGrad.zPosition = 890;
        gDIRhythmBarsGrad.startPoint = CGPointMake(0.0, 0.5);
        gDIRhythmBarsGrad.endPoint = CGPointMake(1.0, 0.5);
        gDIRhythmBars = [CAShapeLayer layer];
        gDIRhythmBars.fillColor = UIColor.whiteColor.CGColor;
        gDIRhythmBars.strokeColor = UIColor.clearColor.CGColor;
        gDIRhythmBarsGrad.mask = gDIRhythmBars;
        [host.layer addSublayer:gDIRhythmBarsGrad];
        gDIBarsModeUsed = -1;
    }
    if (!CGRectEqualToRect(gDIRhythmBarsGrad.frame, host.bounds)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        gDIRhythmBarsGrad.frame = host.bounds;
        gDIRhythmBars.frame = host.bounds;
        [CATransaction commit];
    }

    UIColor *ca = nil, *cb = nil;
    diColorPalette(spectrumColorMode, spectrumColorA, spectrumColorB,
                   [UIColor colorWithRed:0.60 green:0.54 blue:0.95 alpha:1.0],
                   [UIColor colorWithRed:0.42 green:0.72 blue:1.00 alpha:1.0],
                   gDIHuePhase, NO, &ca, &cb);
    static double lastBarsHue = -1.0;
    static UIColor *lastResolvedA=nil,*lastResolvedB=nil;
    BOOL colorsDirty = ![ca isEqual:lastResolvedA] || ![cb isEqual:lastResolvedB] || (spectrumColorMode != gDIBarsModeUsed)
        || ![gDIBarsUsedA isEqualToString:(spectrumColorA ?: @"")]
        || ![gDIBarsUsedB isEqualToString:(spectrumColorB ?: @"")]
        || (spectrumColorMode == 2 && fabs(gDIHuePhase - lastBarsHue) > 0.004);
    if (colorsDirty) {
        lastResolvedA=ca;lastResolvedB=cb;
        gDIBarsModeUsed = spectrumColorMode;
        gDIBarsUsedA = [(spectrumColorA ?: @"") copy];
        gDIBarsUsedB = [(spectrumColorB ?: @"") copy];
        lastBarsHue = gDIHuePhase;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        gDIRhythmBarsGrad.colors = @[ (__bridge id)ca.CGColor, (__bridge id)cb.CGColor ];
        [CATransaction commit];
    }

    /* 3.0.80: 每帧重建路径(最多 64 根, 开销很小); 不再 30Hz 降频。
       先把每根的"频谱值 v / 高度 h"统一算出来 —— 6 种样式共用同一套数据,
       只是画法不同, 所以切换样式时波形/节奏完全一致, 只有形状变。 */
    if (n > 64) n = 64;
    CGFloat vArr[64], hArr[64];
    /* 3.0.71: "咚"的增益整帧只算一次(每根条都调 expf 没必要) */
    float kb = 1.0f + 0.38f * diKickPunchNow();
    for (int i = 0; i < n; i++) {
        CGFloat mid = (CGFloat)(n - 1) * 0.5f;
        CGFloat dist = mid > 0 ? fabs((CGFloat)i - mid) / mid : 0.0f;
        CGFloat bp = pow(dist, 0.55f) * (CGFloat)(DI_AU_BANDS - 1);
        int b0 = (int)bp % DI_AU_BANDS, b1 = MIN(b0 + 1, DI_AU_BANDS - 1);
        CGFloat bf = bp - floor(bp);
        float v = active ? (gDIBandSmooth[b0] * (1.0f - bf) + gDIBandSmooth[b1] * bf) : 0.0f;
        if(!isfinite(v))v=0;
        v *= kb;
        if (v < 0.0f) v = 0.0f;
        if (v > 1.0f) v = 1.0f;
        vArr[i] = (CGFloat)v;
        hArr[i] = 1.5 + (height - 1.5) * pow(v, 0.85);
    }

    CGMutablePathRef p = CGPathCreateMutable();
    const CGFloat xMidAll = (top + bottom) * 0.5f;   /* 镜像样式的中线 */

    switch(gDIBarStyle){
        case 1: {   /* 点阵: 每列是一串自下而上的小方块(LED 电平表), 亮的格数随频谱值 */
            CGFloat cell = 2.2f, cgap = 1.0f, cspan = cell + cgap;
            int cells = (int)floorf((height + cgap) / cspan);
            if (cells < 1) cells = 1;
            if (cells > 16) cells = 16;
            for (int i = 0; i < n; i++) {
                int lit = (int)lroundf((float)vArr[i] * (float)cells);
                if (lit < 1) lit = 1;
                if (lit > cells) lit = cells;
                CGFloat bx = x0 + i * (bw + gap);
                for (int k = 0; k < lit; k++) {
                    CGFloat y = bottom - cell - (CGFloat)k * cspan;
                    CGFloat rr0 = MIN(cell * 0.35f, bw * 0.5f);
                    diSafeSpectrumRoundedRect(p, NULL, CGRectMake(bx, y, bw, cell), rr0, rr0);
                }
            }
            break;
        }
        case 2: {   /* 镜像: 以中线为轴上下各一半 */
            for (int i = 0; i < n; i++) {
                CGFloat hh = hArr[i] * 0.5f;
                CGRect r = CGRectMake(x0 + i * (bw + gap), xMidAll - hh, bw, hh * 2.0f);
                CGFloat rr = MIN(bw * 0.5f, MIN(hh * 0.9f, 1.6f));
                if (rr < 0.0f) rr = 0.0f;
                diSafeSpectrumRoundedRect(p, NULL, r, rr, rr);
            }
            break;
        }
        case 4: {   /* 峰值: 柱状 + 顶部峰值帽(峰值缓降, 像专业频谱仪) */
            CFAbsoluteTime nowB = CACurrentMediaTime();
            float dtb = (gDIBarPeakT > 0.0) ? (float)(nowB - gDIBarPeakT) : 0.016f;
            if (dtb < 0.0f) dtb = 0.0f;
            if (dtb > 0.20f) dtb = 0.20f;
            gDIBarPeakT = nowB;
            for (int i = 0; i < n; i++) {
                float pk = gDIBarPeak[i];
                float vv = (float)vArr[i];
                if (vv >= pk) pk = vv;
                else {
                    pk -= 0.55f * dtb;          /* 每秒落 0.55, 约 1.8s 从顶到底 */
                    if (pk < vv) pk = vv;
                }
                if (pk < 0.0f) pk = 0.0f;
                gDIBarPeak[i] = pk;
                CGRect r = CGRectMake(x0 + i * (bw + gap), bottom - hArr[i], bw, hArr[i]);
                CGFloat rr = MIN(bw * 0.5f, MIN(hArr[i] * 0.45f, 1.6f));
                if (rr < 0.0f) rr = 0.0f;
                diSafeSpectrumRoundedRect(p, NULL, r, rr, rr);
                /* 峰值帽: 1.6pt 高的横条, 悬在峰值位置 */
                if (pk > 0.02f) {
                    CGFloat ph = 1.5 + (height - 1.5) * pow(pk, 0.85);
                    CGFloat capY = bottom - ph - 2.2f;
                    if (capY > top - 2.0f)
                        diSafeSpectrumRoundedRect(p, NULL, CGRectMake(x0 + i * (bw + gap),
                                                                 capY, bw, 1.6f), 0.8f, 0.8f);
                }
            }
            break;
        }
        case 5: {   /* 尖刺: 底部略宽、顶上收成锐尖的针, 密集时像一排锯齿 */
            CGFloat baseW = MIN(bw * 1.7f, bw + gap * 1.6f);
            if (baseW < bw) baseW = bw;
            for (int i = 0; i < n; i++) {
                CGFloat cx = x0 + i * (bw + gap) + bw * 0.5f;
                CGFloat tipY = bottom - hArr[i];
                CGPathMoveToPoint(p, NULL, cx - baseW * 0.5f, bottom);
                CGPathAddLineToPoint(p, NULL, cx, tipY);
                CGPathAddLineToPoint(p, NULL, cx + baseW * 0.5f, bottom);
                CGPathCloseSubpath(p);
            }
            break;
        }
        case 6: {   /* 斜切: 柱体越高歪得越多, 像被风推住的雨线 */
            for (int i = 0; i < n; i++) {
                CGFloat hh = hArr[i];
                CGFloat sk = hh * 0.30f;
                CGFloat xl = x0 + i * (bw + gap);
                CGFloat y = bottom - hh;
                CGPathMoveToPoint(p, NULL, xl, bottom);
                CGPathAddLineToPoint(p, NULL, xl + bw, bottom);
                CGPathAddLineToPoint(p, NULL, xl + bw + sk, y);
                CGPathAddLineToPoint(p, NULL, xl + sk, y);
                CGPathCloseSubpath(p);
            }
            break;
        }
        case 10: {  /* 萤火: 一根极细的光柱 + 顶端一颗随音量变大的光点 */
            for (int i = 0; i < n; i++) {
                CGFloat cx = x0 + i * (bw + gap) + bw * 0.5f;
                CGFloat topY = bottom - hArr[i];
                CGPathAddRect(p, NULL, CGRectMake(cx - 0.35f, topY, 0.7f, hArr[i]));
                CGFloat r = 0.8f + 2.4f * (CGFloat)vArr[i];
                CGPathAddEllipseInRect(p, NULL, CGRectMake(cx - r, topY - r, r * 2.0f, r * 2.0f));
            }
            break;
        }
        case 15: {  /* 胶囊: 整根圆头竖胶囊, 高低反差最干净 —— iOS 音量条那种 */
            for (int i = 0; i < n; i++) {
                CGFloat cw = bw * 1.30f;
                CGFloat cx = x0 + i * (bw + gap) + bw * 0.5f;
                CGFloat hh = MAX(2.0f, hArr[i]);
                CGFloat rr = MIN(cw * 0.5f, hh * 0.5f);
                diSafeSpectrumRoundedRect(p, NULL, CGRectMake(cx - cw * 0.5f, bottom - hh, cw, hh), rr, rr);
            }
            break;
        }
        case 16: {  /* 霓虹: 空心灯管 + 管内一小段亮芯, 夜里最出效果 */
            for (int i = 0; i < n; i++) {
                CGFloat cw = bw * 1.15f;
                CGFloat cx = x0 + i * (bw + gap) + bw * 0.5f;
                CGFloat hh = MAX(5.0f, hArr[i]);
                CGFloat t = MAX(0.85f, cw * 0.26f);
                CGFloat xl = cx - cw * 0.5f, yt = bottom - hh;
                CGFloat rr = MIN(t * 0.5f, 1.2f);
                diSafeSpectrumRoundedRect(p, NULL, CGRectMake(xl, yt, cw, t), rr, rr);          /* 顶 */
                diSafeSpectrumRoundedRect(p, NULL, CGRectMake(xl, bottom - t, cw, t), rr, rr);   /* 底 */
                diSafeSpectrumRoundedRect(p, NULL, CGRectMake(xl, yt, t, hh), rr, rr);           /* 左 */
                diSafeSpectrumRoundedRect(p, NULL, CGRectMake(xl + cw - t, yt, t, hh), rr, rr);   /* 右 */
                /* 亮芯: 从底部升起的一段 */
                CGFloat ch = hh * 0.42f;
                diSafeSpectrumRoundedRect(p, NULL, CGRectMake(cx - t * 0.32f, bottom - ch, t * 0.64f, ch), 0.5f, 0.5f);
            }
            break;
        }
        case 17: {  /* 双子: 每格主副两根细柱(副柱 55% 高), 立体的层次感 */
            for (int i = 0; i < n; i++) {
                CGFloat slot = bw + gap;
                CGFloat cw = MAX(0.9f, bw * 0.44f);
                CGFloat cx = x0 + i * slot + slot * 0.5f;
                CGFloat h1 = MAX(2.0f, hArr[i]);
                CGFloat h2 = MAX(1.4f, h1 * 0.55f);
                CGFloat rr = MIN(cw * 0.5f, 1.3f);
                diSafeSpectrumRoundedRect(p, NULL, CGRectMake(cx - cw - 0.35f, bottom - h1, cw, h1), rr, rr);
                diSafeSpectrumRoundedRect(p, NULL, CGRectMake(cx + 0.35f, bottom - h2, cw, h2), rr, rr);
            }
            break;
        }
        case 14: {  /* 星轨: 一根细光柱顶上挂一颗十字星, 星的大小跟着频谱走 */
            for (int i = 0; i < n; i++) {
                CGFloat cx = x0 + i * (bw + gap) + bw * 0.5f;
                CGFloat topY = bottom - hArr[i];
                CGFloat r = 1.0f + 3.0f * (CGFloat)vArr[i];
                CGFloat t = MAX(0.55f, bw * 0.24f);
                CGPathAddRect(p, NULL, CGRectMake(cx - t * 0.5f, topY - r, t, r * 2.0f));
                CGPathAddRect(p, NULL, CGRectMake(cx - r, topY - t * 0.5f, r * 2.0f, t));
                CGPathAddEllipseInRect(p, NULL, CGRectMake(cx - 0.9f, topY - 0.9f, 1.8f, 1.8f));
            }
            break;
        }
        default: {  /* 0: 柱状(默认) —— 圆角长条, 中间高两边低 */
            for (int i = 0; i < n; i++) {
                CGRect r = CGRectMake(x0 + i * (bw + gap), bottom - hArr[i], bw, hArr[i]);
                CGFloat rr = MIN(bw * 0.5f, MIN(hArr[i] * 0.45f, 1.6f));
                if (rr < 0.0f) rr = 0.0f;
                diSafeSpectrumRoundedRect(p, NULL, r, rr, rr);
            }
            break;
        }
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    gDIRhythmBars.path = p;
    gDIRhythmBarsGrad.opacity = 1.0f;
    gDIRhythmBars.opacity = 1.0f;
    [CATransaction commit];
    CGPathRelease(p);
}

/* ---------- 重建 / 复位 / tick ---------- */
/* ---------- 3.0.54: 颜色模式(跟随专辑 / 固定颜色 / 流光颜色) ----------
   用户要求像 FlexMusic 那样可选, 而不是把色值写死。三种来源统一成一个调色板:
   mode 0 = 从专辑封面取平均色(提高饱和/亮度), 结束色取同色相偏移;
   mode 1 = 设置页选的固定起止色;
   mode 2 = 色相随时间旋转的流光, 起止色相差 0.14 圈。 */
static UIColor *diHSB(double h, double sat, double bri) {
    h = fmod(h, 1.0); if (h < 0) h += 1.0;
    return [UIColor colorWithHue:h saturation:sat brightness:bri alpha:1.0];
}
static void diRGB2HSB(UIColor *c, double *h, double *s, double *b) {
    CGFloat r=0,g=0,bb=0,a=0;
    if (![c getRed:&r green:&g blue:&bb alpha:&a]) { *h=0; *s=0; *b=1; return; }
    double mx = MAX(r, MAX(g, bb)), mn = MIN(r, MIN(g, bb));
    double d = mx - mn;
    double hh = 0;
    if (d > 1e-6) {
        if (mx == r) hh = fmod((g - bb) / d, 6.0);
        else if (mx == g) hh = (bb - r) / d + 2.0;
        else hh = (r - g) / d + 4.0;
        hh /= 6.0; if (hh < 0) hh += 1.0;
    }
    *h = hh; *s = (mx > 1e-6) ? d / mx : 0; *b = mx;
}

/* 封面主色: 递归找 UIImageView 的图, 取不到就从 layer.contents 取 CGImage;
   缩到 6x6 求平均, 跳过近黑像素, 最后把饱和度/亮度抬到能看清的程度。 */
static UIColor *diCoverAverageColor(UIView *cover) {
    if (!cover) return nil;
    UIImage *img = diFxArtworkImage;
    NSMutableArray *st = [NSMutableArray arrayWithObject:cover];
    int budget = 300;
    while (!img && st.count && budget-- > 0) {
        UIView *v = st.lastObject; [st removeLastObject];
        if ([v isKindOfClass:UIImageView.class]) {
            UIImage *im = ((UIImageView *)v).image;
            if (im) { img = im; break; }
        }
        for (UIView *c in v.subviews) [st addObject:c];
    }
    CGImageRef cg = img.CGImage;
    if (!cg) {
        id cont = cover.layer.contents;
        if (cont && CFGetTypeID((__bridge CFTypeRef)cont)==CGImageGetTypeID()) {
            @try { cg = (__bridge CGImageRef)cont; } @catch (__unused NSException *e) { cg = NULL; }
        }
    }
    if (!cg) return nil;
    static UIImage *cachedImage=nil;static UIColor *cachedColor=nil;
    if(img && img==cachedImage && cachedColor)return cachedColor;
    unsigned char px[6 * 6 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 6, 6, 8, 24, cs, kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextDrawImage(ctx, CGRectMake(0, 0, 6, 6), cg);
    CGContextRelease(ctx);
    double r = 0, g = 0, b = 0, n = 0;
    for (int i = 0; i < 36; i++) {
        double rr = px[i*4] / 255.0, gg = px[i*4+1] / 255.0, bb = px[i*4+2] / 255.0;
        double alpha=px[i*4+3]/255.0;
        if(alpha<0.05)continue;
        r+=MIN(1.0,rr/alpha);g+=MIN(1.0,gg/alpha);b+=MIN(1.0,bb/alpha);n+=1;
    }
    if (n < 1) return nil;
    UIColor *result=[UIColor colorWithRed:r/n green:g/n blue:b/n alpha:1.0];
    if(img){cachedImage=img;cachedColor=result;}
    return result;
}

/* 统一调色板: 返回 A/B 两个颜色 */
static void diColorPalette(int mode, NSString *hexA, NSString *hexB,
                           UIColor *defA, UIColor *defB,
                           double huePhase, BOOL forParticles,
                           UIColor **outA, UIColor **outB) {
    if (mode == 0) {
        UIColor *base = gDIRhythmTarget ? diCoverAverageColor(gDIRhythmTarget) : nil;
        if(!base && gDIBgImage) {
            UIImageView *fallback=[[UIImageView alloc]initWithImage:gDIBgImage];
            base=diCoverAverageColor(fallback);
        }
        *outA=base ?: defA; *outB=base ?: defA;
        (void)forParticles;
        return;
    }
    if (mode == 2) {
        /* 3.0.56: 流光不再"写死色相转圈"。以用户自定义的 A/B 为基色, 只让色相缓慢偏移 ——
           这样自定义颜色在流光模式下也真正生效(以前流光完全忽略自定义色, 看着就是"锁死")。 */
        UIColor *a = diRhythmHexColor(hexA, defA ?: [UIColor colorWithRed:0.898 green:0.600 blue:0.443 alpha:1.0]);
        UIColor *b = diRhythmHexColor(hexB, defB ?: [UIColor colorWithRed:0.580 green:0.561 blue:1.000 alpha:1.0]);
        double ha = 0, sa = 0, va = 0, hb = 0, sb = 0, vb = 0;
        diRGB2HSB(a, &ha, &sa, &va);
        diRGB2HSB(b, &hb, &sb, &vb);
        /* 3.0.57: 自定义色**原样使用**。以前这里对粒子做 sat≤0.55 / 提亮, 用户选了正红
           出来是淡粉, 那种"改了跟没改一样"的反馈就是从这来的。自定义 = 你选什么就是什么。 */
        *outA = diHSB(ha + huePhase, sa, va);
        *outB = diHSB(hb + huePhase, sb, vb);
        return;
    }
    *outA = diRhythmHexColor(hexA, defA);
    *outB = diRhythmHexColor(hexB, defB);
    if(mode==1)*outB=*outA;
}

static void diRhythmRebuild(UIView *t) {
    diRhythmDetach();
    if (!t) return;
    UIView *host = diRhythmHostFor(t);
    gDIRhythmHost = host;
    if (!host) return;
    UIColor *ca = nil, *cb = nil;
    diColorPalette(ringColorMode, rhythmColorA, rhythmColorB,
                   [UIColor colorWithRed:0.898 green:0.600 blue:0.443 alpha:1.0],   /* #E59971 */
                   [UIColor colorWithRed:0.580 green:0.561 blue:1.000 alpha:1.0],   /* #948FFF */
                   gDIHuePhase, NO, &ca, &cb);
    gDIRhythmUsedA = [(rhythmColorA.length ? rhythmColorA : @"#E59971") copy];
    gDIRhythmUsedB = [(rhythmColorB.length ? rhythmColorB : @"#948FFF") copy];
    gDIRingModeUsed = ringColorMode;
    if (rhythmRoundCover) diCoverRound(t);
    if (rhythmRingOn) diRhythmBuildRing(host, ca, cb);
    RLog(@"[律动] 目标封面 %@ %.0fx%.0f, 宿主 %@ %.0fx%.0f, 圆=%d 粒=%d 条=%d",
         NSStringFromClass(t.class), t.bounds.size.width, t.bounds.size.height,
         NSStringFromClass(host.class), host.bounds.size.width, host.bounds.size.height,
         rhythmRoundCover, rhythmParticlesOn, rhythmBarsOn);
    /* 3.0.56 探针: 把封面往上的 4 层祖先打出来(类名/尺寸/是否裁剪),
       用来确认鼓点缩放是不是被某层"同尺寸裁剪容器"吃掉了。 */
    {
        UIView *v = t;
        int gi = 0;
        while (v && gi < 4) {
            RLog(@"[探针] 祖先%d %@ %.0fx%.0f clip=%d",
                 gi, NSStringFromClass(v.class), v.bounds.size.width, v.bounds.size.height,
                 (v.clipsToBounds || v.layer.masksToBounds) ? 1 : 0);
            v = v.superview; gi++;
        }
    }
}

static void diRhythmReset(void) {
    diAuClose();
    UIView *t = gDIRhythmTarget;
    UIView *dv = gDIRhythmDrive ?: t;
    if (dv && gDIRhythmBaseValid) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [dv.layer removeAnimationForKey:@"di.rhythm.scale.hold"];
        dv.layer.transform = gDIRhythmBase;
        [CATransaction commit];
    }
    gDIRhythmDrive = nil;
    gDIRhythmBaseValid = NO;
    gDIRhythmTarget = nil;
    gDISteady = 0;
    gDIBeatEnv = 0;
    gDIBassPulse = 0;
    gDIBeatRaw = 0;
    gDIBassPrev = 0;
    gDIOnsetAvg = 0;
    gDIOnsetVar = 0;
    for (int i = 0; i < DI_AU_BANDS; i++) gDIBandPrevFlux[i] = 0.0f;
    gDIFluxAvg = 0; gDIFluxNow = 0; gDILowLevel = 0;
    gDIKick = 0; gDILowN = 0; gDILowNPrev = 0;
    gDILowFloor = 0; gDILowPeak = 0; gDIKickArmed = YES; gDILastKickT = 0;
    gDILowSm = 0; gDILowHistW = 0;
    for (int i = 0; i < 5; i++) gDILowHist[i] = 0.0f;
    gDILowP1 = 0; gDILowP2 = 0; gDILowShare = 0; gDIKickHoldN = 1.0f;
    gDIKickPunchAmp = 0.0f; gDIKickPunchT = 0.0;
    /* 3.0.57: 把旋转交还给 CA 动画(律动接管期间是我们自己在转) */
    if (gDIArtSpinYield) {
        UIView *yv = gDIArtSpinYield;
        gDIArtSpinYield = nil;
        if (yv.window) @try { diArtDress(yv); } @catch (__unused NSException *e) {}
    }
    diRhythmDetach();
    if (rhythmRoundCover) diCoverUnround();
    for (int i = 0; i < DI_AU_BANDS; i++) { gDIBandRaw[i] = 0; gDIBandSmooth[i] = 0; }
    /* 3.0.83: 引擎停/重启时把气泡一起清空 */
    for (int i = 0; i < DI_BUBBLE_MAX; i++) gDIBubbles[i].alive = 0;
    for (int i = 0; i < 64; i++) { gDIBubbleLastV[i] = 0.0f; gDIBubbleNextAt[i] = 0.0; }
    gDIBubbleT = 0.0f;
    gDIBeatStopped = NO;      /* 3.0.79: 引擎重启后允许重新硬停 */
}

/* 3.0.55: 频谱跟随 + 鼓点检测(重写)
   旧版三个毛病, 直接对应"一卡一卡"和"鼓点不明显":
     ① 平滑系数写成"每帧常数"(0.40/0.82)。帧率一变手感就变, 而且 DIAudio 是 30Hz
        发包, 120Hz 屏上每 4 帧才拿到一个新值 —— 条和粒子都是一顿一顿的;
     ② 鼓点用"绝对能量 - 缓慢基线", 基线爬升也是每帧常数, 底鼓密集时脉冲被吃掉;
     ③ 阈值写死 0.05, 小音量下完全没有反应。
   现在: ① 全部换成**时间常数** 1-exp(-dt/tau), 60/120Hz 完全一致;
        ② 低音取 60~250Hz 四段加权, 做"谱通量 + 自适应阈值(局部均值/方差) + 不应期",
           这是常规的 onset 检测, 跟着底鼓走而不是跟着音量走;
        ③ 脉冲分两层: gDIBassPulse(物理, 快) / gDIBeatEnv(视觉, 40ms 起 260ms 落)。 */
static void diRhythmAdvanceSpectrum(BOOL active, BOOL real, float dt) {
    if (dt < 0.001f) dt = 0.001f;
    if (dt > 0.05f) dt = 0.05f;
    float kUp = 1.0f - expf(-dt / 0.045f);      /* 上冲 ~45ms */
    float kDn = 1.0f - expf(-dt / 0.190f);      /* 回落 ~190ms */

    /* 3.0.56: 频谱端"连接还在但一直没数据"时, 2 秒后自动转合成节拍 ——
       否则 real=YES 但 24 段全是 0, 封面永远不抖, 用户看到的就是"没效果"。
       一旦有真数据立刻切回来。 */
    BOOL usable = (active && real);
    if (usable) {
        float sum0 = 0.0f;
        for (int i = 0; i < DI_AU_BANDS; i++) sum0 += gDIBandRaw[i];
        if (sum0 < 0.03f) {
            if (gDIQuietAt <= 0.0) gDIQuietAt = CACurrentMediaTime();
            else if (CACurrentMediaTime() - gDIQuietAt > 2.0) usable = NO;
        } else {
            gDIQuietAt = 0.0;
        }
    } else {
        gDIQuietAt = 0.0;
    }

    if (usable) {
        /* 3.0.71: 服务端(样本域, AudioUnitRender)已经算好"咚" —— 序号变了就是新的一下。
           age = 这一包离开服务端时距触发多少毫秒, 用它把动画起点往前挪,
           把 TCP/调度那几十毫秒抵掉, 视觉才真的落在鼓点上。 */
        if (gDIPcmKickSeen) {
            if (gDILastPcmSerial == 0) {
                gDILastPcmSerial = gDIPcmKickSerial;   /* 首包只对齐序号, 不补一枪 */
            } else if (gDIPcmKickSerial != gDILastPcmSerial) {
                gDILastPcmSerial = gDIPcmKickSerial;
                if (gDIPcmKickAmp > 0.05f) {
                    double age = (double)gDIPcmKickAgeMs / 1000.0;
                    diKickFire(gDIPcmKickAmp, CACurrentMediaTime() - age);
                }
            }
        }
        float sum = 0;
        for (int i = 0; i < DI_AU_BANDS; i++) {
            float v = gDIBandRaw[i];
            gDIBandSmooth[i] += (v - gDIBandSmooth[i]) * (v > gDIBandSmooth[i] ? kUp : kDn);
            sum += gDIBandSmooth[i];
        }
        gDISteady = MIN(1.0f, sum / (float)DI_AU_BANDS * 1.5f);

        /* 3.0.59: 鼓点 = 绝对通量 + 相对通量。
           472 日志里通量长期 0.000~0.03 —— DIAudio 送的是 dB 归一值, 相邻两包(16ms)
           差得很小, 只看绝对差几乎判不出拍。现在每个频段同时算
             abs = cur - prev        (能量涨了多少)
             rel = abs / (prev+0.10) (相对自己涨了多少倍)
           两者加权求和, 稳态时两者都趋 0, 起音时一起冲高, 对比度比 3.0.58 大一个量级。 */
        float flux = 0.0f, low = 0.0f, lowAll = 0.0f, wsum = 0.0f;
        for (int i = 0; i < DI_AU_BANDS; i++) {
            float cur = gDIBandRaw[i];
            float prev = gDIBandPrevFlux[i];
            gDIBandPrevFlux[i] = cur;
            float dlt = cur - prev;
            float w = (i < 16) ? 1.0f : 0.70f;
            if (dlt > 0.0f) flux += (dlt * 0.80f + (dlt / (prev + 0.10f)) * 0.55f) * w;
            wsum += w;
            if (i <= 5) lowAll += cur;
            /* 3.0.68: 底鼓("咚")只看 0~2 段 —— 24 段对数频带里这三段约 60~140Hz,
               正是底鼓的基频。以前用 0~5 段(到 250Hz), 贝斯/男声低音/军鼓根部
               都会进来, 鼓点跟着"别的声音"动, 就是用户说的"不是咚"。
               权重 4/3/2: 越低的段越像底鼓。 */
            if (i == 0)      low += cur * 4.0f;
            else if (i == 1) low += cur * 3.0f;
            else if (i == 2) low += cur * 2.0f;
        }
        flux /= MAX(1.0f, wsum);
        gDIFluxNow = flux;
        gDILowLevel = MIN(1.0f, low / 9.0f);           /* 4+3+2 = 9 */
        /* 低频占比: 底鼓 0~5 段能量 / 全谱能量。咚的那一下几乎全在低频,
           人声/军鼓/镲片起音时低频占比会掉下去 —— 用它把"不是咚的起音"挡掉。 */
        gDILowShare = lowAll / MAX(0.02f, sum);
        /* 3.0.68: 底鼓("咚")采集 —— 480 用户: "粒子跟专辑鼓点采集用咚(咚咚咚的第一个咚)"。
           上一版(3.0.65)是"0~5 段电平 + 66ms 涨幅", 三个毛病:
             ① 0~5 段到 250Hz, 贝斯/男声/军鼓根部都算进来 → 跟着"别的声音"动;
             ② 66ms 比涨幅 + 12ms 平滑 → 比真正的鼓点晚 50~80ms, "咚"都过去了才动;
             ③ 只看电平不看"是不是低频主导" → 镲片/人声起音也能凑出一次。
           现在按底鼓的物理特征抓:
             · 频段: 只取 0~2 段(≈60~140Hz) 加权 4/3/2 —— 咚的基频;
             · 起音: 这一帧比**前两帧(32ms)的最高点**还冲出去多少(原始值, 不平滑) —— 抓前沿;
             · 鼓性强: 低频占比 >0.38 才算, 人声/军鼓/镲片起音占比会掉下去;
             · 只响一次: 触发后必须等电平掉到峰值的 72% 以下才重新上膛(防鼓身余音二次触发)。 */
        {
            float low = gDILowLevel;
            /* 第一帧: 直接用当前电平建立 floor/peak */
            if (gDILowPeak < 0.02f && low > 0.02f) {
                gDILowPeak = low;
                gDILowFloor = low * 0.80f;
                gDILowSm = low;
                gDILowP1 = low; gDILowP2 = low;
                for (int i = 0; i < 5; i++) gDILowHist[i] = low;
            }

            /* 6ms 极轻平滑: 只压单帧毛刺, 不能把前沿抹平(12ms 那个太肉) */
            float kSm = 1.0f - expf(-dt / 0.006f);
            gDILowSm += (low - gDILowSm) * kSm;
            float lowS = gDILowSm;

            /* 起音量: 相对"前两帧的最高点"(≈32ms)冲出去多少 —— 抓的是前沿本身,
               不是"和 66ms 前比累计涨了多少"(那会晚且钝) */
            float pastMax = MAX(gDILowP1, gDILowP2);
            float attack = lowS - pastMax;                       /* 绝对冲高 */
            float rel = lowS / MAX(0.05f, pastMax);              /* 相对冲高(倍) */
            gDILowP2 = gDILowP1; gDILowP1 = lowS;

            /* floor: 掉下去立刻跟, 往上只能慢慢爬(2.2s) —— 近似"这一段音乐的底噪" */
            float kUpFloor = 1.0f - expf(-dt / 2.2f);
            if (lowS < gDILowFloor) gDILowFloor += (lowS - gDILowFloor) * 0.35f;
            else                    gDILowFloor += (lowS - gDILowFloor) * kUpFloor;
            /* peak: 冲上去立刻跟, 回落很慢(1.6s) */
            float kDnPeak = 1.0f - expf(-dt / 1.6f);
            if (lowS > gDILowPeak) gDILowPeak += (lowS - gDILowPeak) * 0.35f;
            else                   gDILowPeak += (lowS - gDILowPeak) * kDnPeak;

            /* span 最小 0.12: 防止音乐很平稳时把噪声放大成满量程 */
            float span = gDILowPeak - gDILowFloor;
            if (span < 0.12f) span = 0.12f;
            float n = (lowS - gDILowFloor) / span;
            if (n < 0.0f) n = 0.0f;
            if (n > 1.3f) n = 1.3f;
            gDILowN = n;

            CFTimeInterval nowK = CACurrentMediaTime();
            float riseN = n - gDILowNPrev;

            /* 上膛: ① 电平掉回很低 ② 掉到这次触发峰值的 72% 以下(鼓身余音不算新鼓点) */
            if (n < 0.35f) gDIKickArmed = YES;
            if (riseN < -0.05f && n < gDIKickHoldN * 0.72f) gDIKickArmed = YES;

            gDILowNPrev = n;
            gDILowPrevK = low;

            /* 咚的判定(五条同时满足):
               ① 归一电平够高
               ② 32ms 内绝对冲高 ≥0.045(前沿陡)
               ③ 相对冲高 ≥1.15 倍(不是缓慢爬升)
               ④ 低频占比 ≥0.34(鼓, 不是人声/镲片)
               ⑤ 距上次 >0.16s
               3.0.71: 只在拿不到样本域"咚"时兜底(老 DIAudio / 连接断掉),
               有 v2 包时完全以服务端为准, 免得两套判定互相打架。 */
            if (!gDIPcmKickSeen && gDIKickArmed && n > 0.55f && attack > 0.045f && rel > 1.15f &&
                gDILowShare > 0.34f && (nowK - gDILastKickT) > 0.16) {
                float kv = 0.60f + (n - 0.55f) * 0.75f + MIN(0.25f, attack * 1.20f);
                if (kv > 1.0f) kv = 1.0f;
                gDIKickArmed = NO;
                gDIKickHoldN = n;
                diKickFire(kv, nowK);
            }
        }
        gDIMidLevel = sum / (float)DI_AU_BANDS;

        /* 3.0.58: 阈值抬高 + 加 0.16s 不应期, 冲量 75ms 快速衰减。
           3.0.57 是"通量 > 均值的 1.35 倍就算一拍, 强度下限 0.50" —— 密一点的歌里
           几乎每帧都在起音, 包络被顶在 0.55~0.9 下不来(471 日志实测), 封面就一直卡在
           最大缩放上, 用户看到的就是"一点效果都没有"。现在两拍之间包络会真的掉下去。 */
        float kAvg = 1.0f - expf(-dt / 1.20f);
        gDIFluxAvg += (flux - gDIFluxAvg) * kAvg;
        float thr = MAX(0.020f, gDIFluxAvg * 1.45f);

        CFTimeInterval nowS = CACurrentMediaTime();
        float imp = 0.0f;
        if (flux > thr && (nowS - gDILastOnset) > 0.13) {
            float rel = (flux - thr) / MAX(0.010f, thr);
            imp = 0.45f + MIN(1.4f, rel) * 0.55f;
            if (imp > 1.0f) imp = 1.0f;
            gDILastOnset = nowS;
        }
        gDIBeatRaw = MAX(imp, gDIBeatRaw * expf(-dt / 0.060f));
        gDIBassPrev = flux;
        gDIBassPulse = MAX(gDIBeatRaw, gDIBassPulse * expf(-dt / 0.150f));
    } else if (active) {
        /* 没有真频谱(没重启 mediaserverd / 没装 DIAudio / 有连接但没数据): 合成节拍 */
        gDISynPhase += dt * 1.85;
        double frac = fmod(gDISynPhase, 1.0);
        double pulse = exp(-frac * 6.0);
        for (int i = 0; i < DI_AU_BANDS; i++) {
            double w = 0.30 + 0.70 * fabs(sin(gDIClock * 0.9 + i * 0.75));
            float v = (float)(0.10 + 0.66 * pulse * w);
            gDIBandSmooth[i] += (v - gDIBandSmooth[i]) * (v > gDIBandSmooth[i] ? kUp : kDn);
            gDIBandPrevFlux[i] = gDIBandSmooth[i];   /* 3.0.57: 别在切回真频谱时炸一个大通量 */
        }
        gDISteady = (float)(0.28 + 0.50 * pulse);
        gDIMidLevel = (float)(0.30 * pulse);
        gDIFluxNow = (float)(pulse * 0.5);
        gDIBassPulse = MAX((float)pulse, gDIBassPulse * expf(-dt / 0.18f));
        gDIBassPrev = 0.3f;
        /* 3.0.64: 没真频谱时合成节拍也走同一个包络(静止 = 0) */
        if (frac < 0.16 && gDIKick < (float)pulse * 0.5f) {
            diKickFire((float)pulse, CACurrentMediaTime());
        }
        gDILowN = gDIKick;
    } else {
        float k = 1.0f - expf(-dt / 0.12f);
        for (int i = 0; i < DI_AU_BANDS; i++) {
            gDIBandSmooth[i] -= gDIBandSmooth[i] * k;
            gDIBandPrevFlux[i] = gDIBandSmooth[i];
        }
        gDISteady *= expf(-dt / 0.16f);
        gDIBassPrev = 0.0f;
        gDIBassPulse *= expf(-dt / 0.10f);
        gDIOnsetAvg *= expf(-dt / 0.40f);
        gDIOnsetVar *= expf(-dt / 0.40f);
        gDIMidLevel *= expf(-dt / 0.30f);
        gDIFluxNow *= expf(-dt / 0.30f);
        gDIFluxAvg *= expf(-dt / 0.60f);
        gDILowPrevK = 0.0f;
        gDILowN = 0.0f;
        gDILowNPrev = 0.0f;
        gDIKickArmed = YES;
    }
    /* 视觉拍点: 上升 25ms / 下降 150ms —— 缩放、透明度都用它, 绝不单帧跳变。
       3.0.58: 回落从 260ms 收到 150ms, 否则密鼓点下包络来不及掉, 看着像"一直很大"。 */
    float visK = (gDIBassPulse > gDIBeatEnv)
        ? (1.0f - expf(-dt / 0.015f)) : (1.0f - expf(-dt / 0.095f));
    gDIBeatEnv += (gDIBassPulse - gDIBeatEnv) * visK;

    /* 3.0.63: 拍点冲量已经在上面的三个分支里按"低音鼓"统一算完了 */

    /* 3.0.74: 统一顺滑包络(68 的微动态 + 更自然的手感)。
       起音: ~45ms 平滑顶到 gDIKickTarget(以前是"起音那一帧直接冲顶", 120Hz 上
             就是一帧跳变, 用户觉得硬/别扭; 45ms 仍在鼓点同步的感知范围内);
       回落: 170ms 指数衰减, 和 3.0.68 完全一致。
       三条触发路径(样本域咚 / 客户端五条件 / 合成节拍)都只写 gDIKickTarget。 */
    {
        double atkDt = CACurrentMediaTime() - gDIKickAtkT;
        if (atkDt >= 0.0 && atkDt < 0.045 && gDIKickTarget > gDIKick) {
            gDIKick += (gDIKickTarget - gDIKick) * (float)fmin(1.0, (double)dt / 0.016);
            if (gDIKickTarget - gDIKick < 0.01f) gDIKick = gDIKickTarget;
        } else {
            gDIKick *= expf(-dt / 0.17f);           /* 170ms 回到 0, 与 3.0.68 相同 */
            if (gDIKickTarget > 0.0f && atkDt >= 0.045) gDIKickTarget = 0.0f;
        }
    }
}

/* ===== 3.0.79: 播放状态 & 暂停即停 =====
   消 489 反馈: "歌曲暂停了粒子跟音频还是在动"。
   两个根因:
     ① active 只看 MRMediaRemoteGetNowPlayingIsPlaying。控制中心点暂停后,
        这个接口经常延迟 1~2 秒才变 NO(有时干脆不变), 于是 active 一直是 YES
        —— 粒子继续生成/漂移、频谱条继续画。PlaybackRate 在暂停那一刻就变 0,
        用它做权威判据, 立刻停。
     ② 就算 active 变 NO, 以前也只是把粒子寿命压到 0.35s、让它们慢慢淡,
        引擎还在 120Hz 空转。现在改成硬停: 粒子瞬间清零、所有特效层 opacity=0、
        displayLink 挂起, 直到真的重新播放才唤醒。 */
static NSInteger gDIPlayRateState = -1;      /* -1 未知 / 0 暂停或停止 / 1 播放中 */
static CFTimeInterval gDIPlayRateAt = 0;

static void diPlayRatePoll(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gDIPlayRateAt < 0.40) return;
    gDIPlayRateAt = now;
    if (!gMRGetNowPlayingInfo) {
        diNPLoadMediaRemote();
        if (!gMRGetNowPlayingInfo) return;
    }
    gMRGetNowPlayingInfo(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(CFDictionaryRef info) {
        /* 取不到信息时保持上一次判断 —— 一次查询失败不该把特效灭掉 */
        if (!info) { dispatch_async(dispatch_get_main_queue(), ^{gDIPlayRateState=0;}); return; }
        CFStringRef key = (gMRRateKeyPtr && *gMRRateKeyPtr) ? *gMRRateKeyPtr : NULL;
        if (!key) return;
        id rv = (__bridge id)CFDictionaryGetValue(info, key);
        if (![rv isKindOfClass:NSNumber.class]) return;
        NSInteger st = ([rv doubleValue] > 0.01) ? 1 : 0;
        dispatch_async(dispatch_get_main_queue(), ^{ gDIPlayRateState = st; });
    });
}

/* ===== 3.0.84 → 3.0.87: 岛专辑特效的"复位"半边 =====
   粒子与律动本体已经在 MRU(MediaRemoteUI) 进程里跑了(见文件末尾那段), 这里只剩
   一件事: 暂停/停止时把 SpringBoard 侧自绘玻璃(DIMaskView)的 fxScale 复位。
   SB 侧的粒子层/状态数组在 3.0.87 一起删掉 —— 它们从 3.0.85 起就是死代码。 */
#define DI_IS_GLASS_MAX 4
#define DI_IS_DOT_MAX 40

static __weak UIView *gDIISGlasses[DI_IS_GLASS_MAX];
static int gDIISGlassN = 0;

static void diISRegisterGlass(UIView *g) {
    if (!g) return;
    for (int i = 0; i < gDIISGlassN; i++) if (gDIISGlasses[i] == g) return;
    if (gDIISGlassN < DI_IS_GLASS_MAX) { gDIISGlasses[gDIISGlassN++] = g; return; }
    for (int i = 1; i < DI_IS_GLASS_MAX; i++) gDIISGlasses[i - 1] = gDIISGlasses[i];
    gDIISGlasses[DI_IS_GLASS_MAX - 1] = g;
}

static void diISBeatReset(UIView *g) {
    if (!g) return;
    if ([g isKindOfClass:DIMaskView.class]) {
        ((DIMaskView *)g).fxScale = 1.0;
    } else {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        g.layer.transform = CATransform3DIdentity;
        [CATransaction commit];
    }
}

/* 3.0.84: 岛特效独立跑时用它判"到底有没有在放歌"(与主路径同一套优先级) */

static void diISHardStop(void) {
    for (int i = 0; i < gDIISGlassN; i++) diISBeatReset(gDIISGlasses[i]);
}


/* 暂停/停止时: 粒子全部清空、所有视觉层隐藏。
   注意粒子层下一帧会重新变可见(opacity 由 diFxUpdateDots 写), 所以清空用的是
   life=0 + count=0 —— updateDots 对 life<=0 的槽位只写 opacity 0, 不会被"复活"。 */
static void diFxHardStop(void) {
    diAuClose();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < DI_DOT_CAP; i++) {
        gDIDots[i].life = 0.0f;
        gDIDots[i].push = 0.0f;
        if (gDIDotLayer[i]) gDIDotLayer[i].opacity = 0.0f;
    }
    gDIDotCount = 0;
    gDISpawnAcc = 0.0f;
    if (gDIDotClipLayer) gDIDotClipLayer.opacity = 0.0f;
    diProgressBack.hidden=YES; diProgressFront.hidden=YES;
        if (gDIRhythmRingGrad) gDIRhythmRingGrad.opacity = 0.0f;
    if (gDIRhythmRingBack) gDIRhythmRingBack.opacity = 0.0f;
    if (gDIRhythmBarsGrad) gDIRhythmBarsGrad.opacity = 0.0f;
    [CATransaction commit];
    diISHardStop();   /* 3.0.84: 岛专辑的粒子与缩放一起停 */
    /* 包络/频谱全部归零, 免得恢复播放时第一帧带着上一次的尾巴 */
    gDISteady = 0.0f; gDIBeatEnv = 0.0f; gDIBassPulse = 0.0f;
    gDIKick = 0.0f; gDIKickTarget = 0.0f;
    for (int i = 0; i < DI_AU_BANDS; i++) gDIBandSmooth[i] = 0.0f;
}

/* ===== 3.0.87: 鼓点快照 —— SB 写 beat.bin, MRU 读它 =====
   岛专辑特效在 MediaRemoteUI 进程里跑, 它自己连频谱端当然也能算, 但那样就是"另一份
   包络、另一个鼓点", 和播放器不可能严丝合缝。这里把**已经在算的**这一份(gDIKick/
   gDIBeatEnv/gDIBassPulse)30Hz 落成 24 字节, MRU 直接读 —— 岛上和播放器永远是同一拍。 */
typedef struct { double t; float kick, env, bass, playing, energy, extra; } DIBeatSnapOut;
static void diISPublishBeat(BOOL playing) {
    if(!diIslandEffectsAvailable)return; // no retired island IPC writes

    static int fd = -2;
    static CFAbsoluteTime lastTry = 0, lastW = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (fd < 0) {
        if (fd == -1 && now - lastTry < 2.0) return;
        lastTry = now;
        NSString *dir = diMruSharedDir();
        if (!dir.length) { fd = -1; return; }
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                     attributes:@{NSFilePosixPermissions: @0777} error:NULL];
        NSString *p = [dir stringByAppendingPathComponent:@"beat.bin"];
        fd = open([p fileSystemRepresentation], O_RDWR | O_CREAT, 0644);
        if (fd < 0) { fd = -1; return; }
    }
    if (now - lastW < 0.033) return;     /* 30Hz 足够, 别每帧都 write */
    lastW = now;
    DIBeatSnapOut sn;
    memset(&sn, 0, sizeof sn);
    sn.t = now;
    sn.kick = playing ? diSharedVisualPulse : 0.0f;
    sn.env = playing ? gDIBeatEnv : 0.0f;
    sn.bass = playing ? gDIBassPulse : 0.0f;
    sn.playing = playing ? 1.0f : 0.0f;
    sn.energy = playing ? gDIFxEnergy : 0.0f;
    sn.extra=diParticleExtraBeat?1:0;
    pwrite(fd, &sn, sizeof sn, 0);
}

static BOOL diPowerPlayerVisible(UIView *v){
    if(!v || !v.window || v.window.hidden)return NO;
    for(UIView *p=v;p;p=p.superview){
        if(p.hidden || p.alpha<0.01)return NO;
    }
    CGRect r=[v convertRect:v.bounds toView:v.window];
    return !CGRectIsEmpty(r) && CGRectIntersectsRect(r,v.window.bounds);
}
static BOOL diFxExpandedOrSuggestion(UIView *v){
    if(!v)return NO;
    for(UIView *p=v;p && p!=p.window;p=p.superview){
        NSString *n=NSStringFromClass(p.class);
        if([n containsString:@"Suggestion"] || [n containsString:@"Expanded"])return YES;
        if(([n containsString:@"NowPlaying"] || [n containsString:@"ContentModule"]) && p.bounds.size.height>=420)return YES;
    }
    return diTimeExpanded(v);
}
static void diFxSuspendVisuals(void){
    if(gDIRhythmDriving && gDIRhythmBaseValid)diRhythmWriteAll(1,0,NO,0,YES);
    gDIRhythmDriving=NO;gDICoverScaleNow=1;
    diFxHardStop();
    gDIRhythmRingBox.hidden=YES;
    if(gDIRhythmLink)gDIRhythmLink.paused=YES;
}
static void diRhythmTickWithDelta(float dtIn) {
    BOOL anyFx = (rhythmOn || rhythmRingOn || diProgressRingOn || rhythmParticlesOn || rhythmBarsOn);
    /* 3.0.85: 岛专辑特效改走 MRU(真实专辑遮罩)进程, SB 引擎不再为它启动 */
    if (!rhythmFxOn || !anyFx) { diRhythmReset(); return; }

    UIView *t = gDIRhythmTarget;
    BOOL stale = (!t || !t.window || t.hidden || t.alpha < 0.1 || diFxExpandedOrSuggestion(t));
    if (!stale) {
        UIView *better = nil;
        CFTimeInterval now2 = CACurrentMediaTime();
        if (now2 - gDITargetAt > 1.5) {
            better = diRhythmPickTarget();
            if (better && better != t) {
                CGFloat a1 = t.bounds.size.width * t.bounds.size.height;
                CGFloat a2 = better.bounds.size.width * better.bounds.size.height;
                if (a2 > a1 * 1.6f) stale = YES;
            } else {
                gDITargetAt = now2;
            }
        }
    }
    if (stale) {
        UIView *nt = diRhythmPickTarget();
        UIView *oldDrive = gDIRhythmDrive ?: t;
        if (oldDrive && gDIRhythmBaseValid && oldDrive.window) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [oldDrive.layer removeAnimationForKey:@"di.rhythm.scale.hold"]; oldDrive.layer.transform = gDIRhythmBase;
            for (int i = 0; i < gDIRhythmExtraN; i++)
                if (gDIRhythmExtras[i]) { [gDIRhythmExtras[i].layer removeAnimationForKey:@"di.rhythm.scale.hold"]; gDIRhythmExtras[i].layer.transform = diRhythmBaseOf(gDIRhythmExtras[i]); }
            [CATransaction commit];
        }
        for (int i = 0; i < DI_RHYTHM_EXTRA_MAX; i++) gDIRhythmExtras[i] = nil;
        gDIRhythmExtraN = 0;
        gDIRhythmSkipDv = NO;
        gDIRhythmDriving = NO;
        gDILastAng = 0.0;          /* 换了封面, 冻结角度作废 */
        /* 3.0.57: 换目标时把旋转交还给原来那层, 否则它会一直停在我们算出来的角度上 */
        if (gDIArtSpinYield && gDIArtSpinYield == oldDrive) {
            UIView *yv = gDIArtSpinYield;
            gDIArtSpinYield = nil;
            if (yv.window) @try { diArtDress(yv); } @catch (__unused NSException *e) {}
        }
        gDIRhythmBaseValid = NO;
        gDIRhythmTarget = nt;
        t = nt;
        gDITargetAt = CACurrentMediaTime();
        if (t) {
            UIView *dv = diRhythmDriveView(t);
            gDIRhythmDrive = dv;
            CATransform3D cur = diRhythmNeutral(dv.layer.transform);
            gDIRhythmBase = cur;
            gDIRhythmBaseSize = dv.bounds.size;
            gDIRhythmBaseValid = YES;
            /* 3.0.61: 找"真正显示专辑图"的那几层(同区域 + 有图像内容) */
            diRhythmCollectExtras(dv);
            {
                NSMutableString *names = [NSMutableString string];
                [names appendFormat:@"%@(壳)", NSStringFromClass(dv.class)];
                for (int i = 0; i < gDIRhythmExtraN; i++)
                    [names appendFormat:@" + %@ %.0fx%.0f", NSStringFromClass(gDIRhythmExtras[i].class),
                     gDIRhythmExtras[i].bounds.size.width, gDIRhythmExtras[i].bounds.size.height];
                RLog(@"[律动] 一起缩放: %@", names);
            }
            /* 3.0.62: 没找到"有内容的同区域视图"时, 把视图树打一次(20s 一次, 不刷屏) */
            if (gDIRhythmExtraN == 0) {
                CFTimeInterval nowD = CACurrentMediaTime();
                if (nowD - gDIDumpAt > 20.0) {
                    gDIDumpAt = nowD;
                    diRhythmDumpTree(dv);
                }
            }
            diRhythmRebuild(t);
        } else {
            gDIRhythmDrive = nil;
            diRhythmDetach();
            if (rhythmRoundCover) diCoverUnround();
        }
    }
    /* 3.0.66: 播放器"原生休眠"的对齐 —— 控制中心收起/模块不在窗口上时, 目标必然
       是 nil。以前 CADisplayLink 还在原生刷新率下空转(每帧 pickTarget), 是纯发热。
       现在直接挂起链; 唤醒由 diRhythmEnsure(1Hz) + diArtPlayerPost(每次播放器布局)
       负责, 打开控制中心的第一次 layout 就会恢复, 无感。 */
    if (!t) {
        /* 3.0.85: 岛专辑特效已改走 MRU 进程, 这里恢复 3.0.66 原样(直接挂起, 不为岛空转) */
        if (gDIRhythmLink && !gDIRhythmLink.paused) {
            gDIRhythmLink.paused = YES;
            gDISteady = 0; gDIBeatEnv = 0; gDIBassPulse = 0;
            diRhythmReset();
            RLog(@"[律动] 播放器不可见 → 引擎挂起(休眠)");
        }
        gDISteady = 0; gDIBeatEnv = 0; gDIBassPulse = 0;
        return;
    }

    if(!diPowerPlayerVisible(t)){
        diAuClose();
        if(gDIRhythmLink)gDIRhythmLink.paused=YES;
        return;
    }
    UIView *dv = gDIRhythmDrive ?: t;

    /* 展开态: 特效整体隐藏(与"特效只在不展开的播放卡显示"一致) */
    BOOL expanded = diFxExpandedOrSuggestion(t);
    /* 3.0.61: 尺寸一变(57 ↔ 308 展开/收起、模块缩放), 之前记的 base 立刻作废。
       这时**一个字都不写** —— 展开态那张大图的适配缩放是系统用 transform 做的,
       我们把它按 57pt 时的 base 写回去, 用户看到的就是"关掉旋转后展开全乱了"。 */
    if (gDIRhythmBaseValid && t &&
        (fabs(dv.bounds.size.width - gDIRhythmBaseSize.width) > 1.5 ||
         fabs(dv.bounds.size.height - gDIRhythmBaseSize.height) > 1.5)) {
        /* 3.0.67: 作废 base 的同时把上一帧写出去的缩放/位移**当场写回中性** ——
           以前只停手不擦, 层上 fillMode=forwards 的 di.rhythm.tf 动画会把封面
           冻在最后一次的 ~1.1x, 用户看到的就是"展开后专辑变形/缩着"。 */
        if (gDIRhythmDriving) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            diRhythmWriteAll(1.0, 0.0, NO, 0.0, YES);
            [CATransaction commit];
        }
        gDIRhythmBaseValid = NO;
        gDIRhythmDriving = NO;
    }
    if (expanded) {
        diFxSuspendVisuals();
        diAuClose();
        if(gDIRhythmLink.preferredFramesPerSecond!=20)gDIRhythmLink.preferredFramesPerSecond=20;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        diProgressBack.hidden=YES; diProgressFront.hidden=YES;
        if (gDIRhythmRingGrad) gDIRhythmRingGrad.opacity = 0.0f;
        if (gDIRhythmRingBack) gDIRhythmRingBack.opacity = 0.0f;
        if (gDIRhythmBarsGrad) gDIRhythmBarsGrad.opacity = 0.0f;
        [CATransaction commit];
        if (gDIRhythmDriving) {
            if (gDIRhythmBaseValid) diRhythmWriteAll(1.0, 0.0, NO, 0.0, YES);
            gDIRhythmDriving = NO;
        }
        gDICoverScaleNow = 1.0f;
        if (gDIDotCount > 0)
            diFxUpdateDots(gDIRhythmHost, diRhythmCoverRect(t, gDIRhythmHost),
                           dtIn, 0.0f, NO);
        return;
    }

    if(gDIPlayRateState==0){diFxSuspendVisuals();return;}
    /* 3.0.97: reconcile the ring independently; do not detach working particles,
       progress ring or artwork transforms when toggling a spectrum preference. */
    if (!rhythmRingOn && gDIRhythmRingBox) {
        [gDIRhythmRingBox removeFromSuperlayer];
        gDIRhythmRingBox=nil; gDIRhythmRingGrad=nil;
        gDIRhythmRingMask=nil; gDIRhythmRingBack=nil;
        gDIRhythmRingFrame=CGRectZero;
    }
    if (rhythmRingOn && gDIRhythmHost) {
        if (gDIRhythmRingBox && gDIRhythmRingBox.superlayer != gDIRhythmHost.layer) {
            [gDIRhythmRingBox removeFromSuperlayer];
            gDIRhythmRingBox=nil;
        }
        UIColor *ringA=nil, *ringB=nil;
        diColorPalette(ringColorMode, rhythmColorA, rhythmColorB,
            [UIColor colorWithRed:0.898 green:0.600 blue:0.443 alpha:1],
            [UIColor colorWithRed:0.580 green:0.561 blue:1 alpha:1],
            gDIHuePhase, NO, &ringA, &ringB);
        if (!gDIRhythmRingBox) {
            diRhythmBuildRing(gDIRhythmHost, ringA, ringB);
            RLog(@"[专辑环] 已创建 host=%@ 开关=%d", NSStringFromClass(gDIRhythmHost.class), rhythmRingOn);
        }
        gDIRhythmRingGrad.colors=@[(__bridge id)ringA.CGColor,
            (__bridge id)ringB.CGColor,(__bridge id)ringA.CGColor];
        gDIRhythmRingBack.strokeColor=ringA.CGColor;
        gDIRhythmRingBox.hidden=NO;
        gDIRhythmRingBox.opacity=1;
    }

    /* 流光: 色相每 0.1s 推一点(约 100 秒一圈) */
    if (ringColorMode == 2 || particleColorMode == 2 || spectrumColorMode == 2) {
        static CFTimeInterval lastHue = 0;
        CFTimeInterval nowH = CACurrentMediaTime();
        if (nowH - lastHue >= 0.10) {
            lastHue = nowH;
            gDIHuePhase = fmod(gDIHuePhase + 0.006, 1.0);
            if (particleColorMode == 2) gDIParticleColorDirty = YES;   /* 粒子跟着流光变色 */
        }
    }

    BOOL hasSong = gDIInfoReady ? gDIHasNowPlaying : YES;
    /* 3.0.79: 优先级 PlaybackRate(暂停瞬间就变 0) > MRMediaRemoteGetNowPlayingIsPlaying
       > AVAudioSession。489 反馈"暂停了还在动", 根因就是 IsPlaying 慢半拍甚至不更新。 */
    diPlayRatePoll();
    BOOL playing = mrQueryOK ? musicPlaying : AVAudioSession.sharedInstance.isOtherAudioPlaying;
    if (gDIPlayRateState == 0) playing = NO;
    else if (gDIPlayRateState == 1) playing = YES;
    BOOL active = hasSong && playing;
    if (active) gDIBeatStopped = NO;

    /* 3.0.58(图三): 暂停/停播时把引擎从原生刷新率降到 20Hz。
       图三说的是"原生 layoutSubviews 排完版会休眠, 我们一直改布局它就一直在刷新, 所以发热"。
       我们这边不再动布局(见粒子层的池化), 再补一条: 没在放歌就别按 120Hz 空转。
       播放时立刻恢复 0 = 跟随原生刷新率。 */
    if (gDIRhythmLink) {
        NSProcessInfo *power=NSProcessInfo.processInfo;
        NSInteger wantFps=active ? ((power.lowPowerModeEnabled || power.thermalState>=NSProcessInfoThermalStateSerious)?30:60) : 20;
        if (gDIRhythmLink.preferredFramesPerSecond != wantFps)
            gDIRhythmLink.preferredFramesPerSecond = wantFps;
    }

    diAuPoll();
    BOOL real = diAuAlive();

    float dt = dtIn;
    if (dt < 0.002f) dt = 0.002f;
    if (dt > 0.05f) dt = 0.05f;
    gDIClock += dt;

    diRhythmAdvanceSpectrum(active, real, dt);


    /* ===== 3.0.92: FlexMusic 那套「环能量 + 专辑鼓点包络」只驱动播放器这边 =====
       能量: 24 段原始频谱 → 快升(0.46+0.10·target)慢落(0.12) → 均值 E。
       鼓点: E 的相对基线瞬态(baseline/excess) → pulse → 1+min(0.22, pulse·0.095·强度)。
       岛(MRU)那条链路仍然读 gDIKick/beat.bin, 一行没动。 */
    diFxAdvanceEnergy(active, real, dt);
    // Reference detector uses spectrum energy, not the legacy PCM kick detector.
    float referenceScale=diFxAdvanceBeat(active, diW17Using?diW17Energy:gDIFxEnergy, rhythmBeatScale, dt);
    diSharedVisualPulse=gDIFxBeatPulse;
    diISPublishBeat(active);
    float fxBeatS=referenceScale;
    static CFTimeInterval outProbe=0;
    if(logEnabled && CACurrentMediaTime()-outProbe>10){
      outProbe=CACurrentMediaTime();
      RLog(@"[律动输出314] 开=%d 幅度=%.2f E=%.4f pulse=%.4f scale=%.5f 粒强=%.2f 环=%d",rhythmOn,rhythmBeatScale,gDIFxEnergy,gDIFxBeatPulse,referenceScale,rhythmParticleStrength,rhythmRingOn);
    }

    if (!gDIFxRealLogged && active && real && gDIBandSeen) {
        gDIFxRealLogged = YES;
        float pk = 0, sum = 0;
        for (int i = 0; i < DI_AU_BANDS; i++) { pk = MAX(pk, gDIBandRaw[i]); sum += gDIBandRaw[i]; }
        RLog(@"[律动] 频谱已就绪: 24 段 峰值=%.2f 均值=%.2f (真 FFT)", pk, sum / (float)DI_AU_BANDS);
    }

    CGFloat sDbg = 1.0;
    BOOL ownsSpin = NO;
    /* 3.0.61: 旋转**只认**「原生播放 → 专辑旋转」这一个开关。
       律动页的「圆形封面」已删除, 不再有第二个东西去改专辑的形状/旋转。 */
    BOOL wantSpin = diArtPrefOn();

    if (!active) {
        /* 3.0.59: 没音乐(暂停/停播/切走)时**彻底停下**。
           3.0.61: 只还原一次(以前每帧都写, 停播后 transform 一直被我们按着)。 */
        if (gDIRhythmDriving) {
            if (gDIRhythmBaseValid) diRhythmWriteAll(1.0, 0.0, NO, 0.0, YES);
            gDIRhythmDriving = NO;
        }
        if (gDIArtSpinYield && gDIArtSpinYield == dv) {
            gDIArtSpinYield = nil;
            if (dv.window) @try { diArtDress(dv); } @catch (__unused NSException *e) {}
        }
        gDICoverScaleNow = 1.0f;
        sDbg = 1.0;
        /* 3.0.79: "彻底停止跟隐藏" —— 粒子瞬间清零、频谱/环全部透明,
           然后把 displayLink 挂起。以前只把粒子寿命压到 0.35s 慢慢淡,
           用户看到的就是"暂停了还在飘"; 引擎还在 120Hz 空转。 */
        if (!gDIBeatStopped) {
            gDIBeatStopped = YES;
            gDIBeatStopAt = CFAbsoluteTimeGetCurrent();
            diFxHardStop();
            RLog(@"[律动] 暂停/停止 → 粒子与频谱已隐藏, 引擎挂起");
        }
        if (gDIRhythmLink && !gDIRhythmLink.paused) gDIRhythmLink.paused = YES;
        return;
    } else if (rhythmOn) {
        /* 尺寸变了之后(展开→收起)base 已作废, 用系统现在的 transform 重新记一次 */
        if (!gDIRhythmBaseValid && dv) {
            CATransform3D cur = diRhythmNeutral(dv.layer.transform);
            gDIRhythmBase = cur;
            gDIRhythmBaseSize = dv.bounds.size;
            gDIRhythmBaseValid = YES;
            gDIRhythmDrive = dv;
            if (gDIRhythmExtraN == 0) diRhythmCollectExtras(dv);
        }
        if (gDIRhythmBaseValid) {
            /* 3.0.63: 律动**不再接管旋转**。旋转永远由 di.art.spin(transform.rotation.z)
               这条 CA 动画提供; 我们只写"缩放 + 位移"的 model —— 二者是 CATransform3D
               的不同分量, 可以共存。476 用户「律动跟旋转会冲突, 打开动态就怪怪的」,
               根就是 3.0.57 起把动画摘掉、每帧自己算角度: 两个写入者抢同一份 transform。
               旋转开关仍然只由「专辑旋转」控制(diArtDress 里读 diArtPrefOn)。 */
            (void)wantSpin;
            ownsSpin = NO;

            /* 3.0.61: 幅度再抬一档, 并且**上下都摆**(以前基准 0.28 偏低, 只在峰值上方
               才有变化, 大部分帧落在钳位 1.000 上, 看着就是"根本没动")。
               现在: 拍点冲到 1.10~1.18, 拍与拍之间落回 0.94~0.98, 57pt 上有 8~10pt 起伏。 */
            /* 3.0.63: 和粒子**同一个低音鼓**(gDIKick)。476 用户: "专辑头像跟粒子的鼓点
               统一一个低音鼓, 这样视觉看起来统一动态"。以前这里混的是全谱包络+响度,
               和粒子的信号不同源, 看起来就是各动各的。 */
            /* 3.0.64: 静止时必须**严格**是 1.000, 只在鼓点上向外弹。
               477 用户: "这振的有点别扭" —— 旧公式 s = 1 + (k-0.25)*amp 让 k 大部分时间
               低于 0.25, 封面长期缩到 0.95~0.99, 再加 0.4% 的呼吸正弦, 看着就是在"抖",
               不是"跟着鼓点弹"。现在 k∈[0,1] 且静止=0, s 只往上走, 回落就是 1.0。
               同时去掉上下位移 dy —— 缩放 + 位移叠加在一起, 重心在动, 更"别扭"。 */
            /* 3.0.74: 回到 3.0.68 的微基础动态(用户指定基线): gDIKick 包络 + 0.20 幅度。
               顺滑化只动了包络的"顶到"过程(45ms 趋近, 见统一顺滑包络), 幅度/衰减不变。 */
            /* 3.0.92: 缩放值直接取 FlexMusic 的 beatScale(1.000~1.220),
               不再用 gDIKick·0.20·幅度 自己算 —— 那一套是"底鼓起音前沿",
               和参考实现的"相对基线能量瞬态"手感不是一回事。 */
            CGFloat s = fxBeatS;
            if (s < 1.0) s = 1.0;
            if (s > 1.22) s = 1.22;
            sDbg = s;
            gDICoverScaleNow = (float)s;      /* 粒子遮罩的孔固定 1.02R, 这里只做记录 */
            CGFloat dy = 0.0;
            /* 只写缩放/位移; 旋转交给 di.art.spin 的 rotation.z 动画 */
            diRhythmWriteAll(s, dy, NO, 0.0, NO);
            gDIRhythmDriving = YES;
        }
    } else if (gDIRhythmDriving) {
        /* rhythmOn 关了(但粒子/频谱还开着): 复位缩放, 把旋转交还给 CA 动画 */
        if (gDIRhythmBaseValid) diRhythmWriteAll(1.0, 0.0, NO, 0.0, YES);
        gDIRhythmDriving = NO;
        if (gDIArtSpinYield == dv) {
            gDIArtSpinYield = nil;
            if (wantSpin && dv.window) @try { diArtDress(dv); } @catch (__unused NSException *e) {}
        }
    }

    /* 3.0.57: 探针 —— 看 通量/拍 有没有起伏、缩放有没有真的落到 m11 上。
       m11 一直等于 sDbg = 写进去了; m11 变回 1.000 = 又被别人顶掉了。 */
    {
        static CFTimeInterval probeAt = 0;
        CFTimeInterval nowP = CACurrentMediaTime();
        if (logEnabled && nowP - probeAt >= 10.0) {
            probeAt = nowP;
            CATransform3D p3 = dv.layer.transform;
            /* 3.0.58: 旋转接管后 m11 = cos(角度)×缩放, 单看 m11 会以为是乱跳。
               这里取 (m11,m12) 的模长 = 真正的缩放倍率。 */
            CGFloat sReal = sqrt(p3.m11 * p3.m11 + p3.m12 * p3.m12);
            /* 3.0.62: 呈现层(presentationLayer)上的实际缩放。-1 = 这个层根本没进渲染树,
               说明我们写的视图压根没显示(那就是"找错视图", 不是"幅度太小")。 */
            CALayer *plNow = (CALayer *)dv.layer.presentationLayer;
            CGFloat sPres = -1.0;
            if (plNow) {
                CATransform3D pt = plNow.transform;
                sPres = sqrt(pt.m11 * pt.m11 + pt.m12 * pt.m12);
            }
            NSMutableString *exs = [NSMutableString string];
            for (int i = 0; i < gDIRhythmExtraN; i++)
                [exs appendFormat:@"%@%.0f ", NSStringFromClass(gDIRhythmExtras[i].class),
                 gDIRhythmExtras[i].bounds.size.width];
            RLog(@"[探针] 通量=%.3f 低频=%.3f 占=%.2f 拍=%.2f 鼓=%.2f 踢=%.2f 咚=%.2f 串=%u 低R=%.4f 隔=%.2f 缩放=%.3f 实=%.3f 呈=%.3f 尺=%.0f 基尺=%.0f 驱动=%@ 图=%@ 旋=%@ 播=%d 率=%d 粒=%d 强=%.1f 律=%d 基=%d 能=%.2f 鼓能=%.2f 低N=%.2f 全N=%.2f 基线=%.2f 超出=%.2f 驱=%.2f 律缩=%.3f 脉=%.2f",
                 gDIFluxNow, gDILowLevel, gDILowShare, gDIBeatEnv, gDILowN, gDIKick,
                 diKickPunchNow(), (unsigned)gDIPcmKickSerial, gDIPcmLowRms,
                 (float)(gDILastKickT > 0 ? (CACurrentMediaTime() - gDILastKickT) : 0.0),
                 sDbg, sReal, sPres,
                 dv.bounds.size.width, gDIRhythmBaseSize.width,
                 NSStringFromClass(dv.class),
                 gDIRhythmExtraN ? exs : @"无",
                 ([dv.layer animationForKey:@"di.art.spin"] ? @"CA" : (ownsSpin ? @"我们" : (wantSpin ? @"等" : @"关"))),
                 active ? 1 : 0, (int)gDIPlayRateState, gDIDotCount, rhythmParticleStrength,
                 rhythmOn ? 1 : 0, gDIRhythmBaseValid ? 1 : 0,
                 gDIFxEnergy, gDIFxBeatE, gDIFxNormN[0], gDIFxNormN[1],
                 gDIFxBeatBaseSee, gDIFxBeatExcSee, gDIFxBeatDrvSee,
                 gDIFxBeatScale, gDIFxBeatPulse);
            /* 3.0.62: 没找到内容层就定期把视图树打出来(20s 一次), 不用等切歌 */
            if (gDIRhythmExtraN == 0 && nowP - gDIDumpAt > 20.0) {
                gDIDumpAt = nowP;
                diRhythmDumpTree(dv);
            }
        }
    }

    UIView *host = gDIRhythmHost;
    if (!host) return;
    CGRect cover = diRhythmCoverRect(t, host);
    diNPQueryNowPlaying();
    diUpdateProgressRing(host, cover, hasSong);

    if (gDIRhythmRingBox) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        diRhythmLayoutRing(cover, gDIBandSmooth, active);
        /* 3.0.79: 暂停时环要**全灭**(以前留 0.12/0.05, 屏幕上一直挂着一圈微亮的环,
           用户说的"还在动"里就有它)。 */
        float baseA = active ? 1.0f : 0.0f; // no unrelated legacy beat dimming
        gDIRhythmRingGrad.opacity = baseA * (float)rhythmRingFollowAlpha;
        if (gDIRhythmRingBack) gDIRhythmRingBack.opacity = active ? 0.18f : 0.0f;
        [CATransaction commit];
        static CFTimeInterval ringProbeAt=0;
        CFTimeInterval ringNow=CACurrentMediaTime();
        if (ringNow-ringProbeAt>=3.0) {
            ringProbeAt=ringNow;
            CGRect pathBox=gDIRhythmRingMask.path ? CGPathGetBoundingBox(gDIRhythmRingMask.path) : CGRectZero;
            RLog(@"[专辑环] 开=%d 播=%d 挂载=%d 隐=%d 透明=%.2f 框=%@ 路径=%@ 宿主裁剪=%d 能=%.3f", rhythmRingOn, active, gDIRhythmRingBox.superlayer==host.layer, gDIRhythmRingBox.hidden, gDIRhythmRingGrad.opacity, NSStringFromCGRect(gDIRhythmRingBox.frame), NSStringFromCGRect(pathBox), host.clipsToBounds, gDIFxEnergy);
        }
    }

    /* 3.0.56: 粒子不再跟鼓点(用户要求"不受鼓点影响"), 自然补充、自然消失 */
    static CFTimeInterval followColorAt=0;
    if(particleColorMode==0 && CACurrentMediaTime()-followColorAt>0.5){
        followColorAt=CACurrentMediaTime();gDIParticleColorDirty=YES;
    }
    if (gDIParticleColorDirty) {
        gDIParticleColorDirty = NO;
        diFxRefreshColors();
    }
    /* 3.0.92: 发射规则照 FlexMusic —— E ≥ 0.08 时, 每帧以 min(0.035+0.30·E, 0.40)
       的概率出生一颗(一次只找一个死槽)。概率是 60Hz 基准, 这里按 dt 换算, ProMotion
       120Hz 上不会翻倍。数量上限仍由「粒子数量」管(池里多余的直接判死等重用)。 */
    if (rhythmParticlesOn && active && real && gDIReferenceSeen && gDIFxEnergy >= 0.08f) {
        float p60 = 0.035f + 0.30f * gDIFxEnergy;
        if (p60 > 0.40f) p60 = 0.40f;
        float p = 1.0f - powf(1.0f - p60, dt * 60.0f);
        if (diFxRand01() < p) diFxSpawnDot(host, cover, gDIFxEnergy);
    }
    if (gDIDotCount > 0) diFxUpdateDots(host, cover, dt, gDIFxEnergy, active);

    diRhythmUpdateBars(host, active);
}

/* CADisplayLink 的 target: 用一个独立小对象, 不 retain 任何视图 */
@interface DIFxTicker : NSObject
- (void)onFrame:(CADisplayLink *)link;
@end
@implementation DIFxTicker
- (void)onFrame:(CADisplayLink *)link {
    static CFTimeInterval previous=0;
    double dt=previous>0?link.timestamp-previous:1.0/60.0;
    previous=link.timestamp;
    if(dt<=0 || dt>0.12)dt=1.0/60.0;
    @try { diRhythmTickWithDelta((float)dt); } @catch (__unused NSException *e) {}
}
@end

/* =====================================================================
   3.0.87: 岛专辑特效 —— 只作用于岛上的小头像(23pt), 展开态完全不参与
   493 反馈四条:
     ① "显示一阵一阵的" —— 绑定时两条路(小岛 23 / 展开 66)都在往这里注册,
        后注册的把前一个顶掉: 粒子刚在 23 上冒两颗, 又被挪到 66 上(看不见),
        再挪回来 → 一茬一茬的;
     ② "粒子跟播放器的不一样" —— 3.0.85 那套是"从圆心往外射的圆点" (寿命 0.5~1s),
        播放器是"慢速外飘 + 摆动 + 四种形状 + 8~14s 寿命", 完全两套东西;
     ③ "律动也没有" —— 除了①绑错玻璃, 还有个更硬的: apply 里每 0.1~0.3 秒会写
        glass.frame = box。transform 不是单位矩阵时 frame 是"变换后的外框", 再写
        frame 会让 UIKit 反过来改 bounds(越写越小) → 律动当场被吃掉;
     ④ "展开也有干扰" —— 就是①的另一半。
   3.0.87 的做法:
     · 只用**小岛**的头像(side 12~44pt), 展开 66pt 一律不接; 绑定做成"当前 + 候选",
       当前那块还在窗口里就不换, 换岛才换绑定 → 不再来回跳;
     · 粒子按播放器 diFxSpawnDot/diFxUpdateDots **一比一移植**: 同样的形状(实心圆/
       菱形/方块/三角)、同样的尺寸/漂移/摆动/寿命/淡入淡出曲线, 尺寸按头像半径比例缩放;
     · 律动写 transform 时置 gDIISDrivingFx, diActivityApply 里那句 frame 同步让路;
       (3.0.88 已撤: 让路会让玻璃尺寸不再跟系统走, 展开时那块 23pt 玻璃带着放大压到
        66pt 专辑上 = "展开多出一块蒙版"。现在尺寸走 bounds+center, 缩放走 transform)
     · 鼓点优先读 SB 落的 beat.bin(与播放器同一个包络、同一个鼓点), 读不到才用自己
       连 127.0.0.1:41235 的频谱兜底;
     · 30Hz → 60Hz, 岛虽小, 但 30Hz 上"慢飘"会一顿一顿。
   ===================================================================== */

static __weak UIView *gDIISMArt = nil;        /* 当前绑定的小岛头像 */
static __weak UIView *gDIISMArtCand = nil;    /* 候选(等当前这块下台再换) */
static UIView *gDIISMGlass = nil;             /* 绑定头像里的那块玻璃 */
static UIView *gDIISMGlassCand = nil;
static UIView *gDIISMHost = nil;              /* 粒子宿主: 插在头像**背后** */
static CAShapeLayer *gDIISMDotLayer[DI_IS_DOT_MAX];
static float gDIISSpawnAcc = 0.0f;
static int gDIISMDotCount = 0;
static float gDIISMKick = 0.0f;
static float diIslandEnergy=0;
static float gDIISMScaleNow = 1.0f;
static float gDIISMClock = 0.0f;
static CFAbsoluteTime gDIISMParamsAt = 0;
static CFAbsoluteTime gDIISMProbeAt = 0;
static double gDIISMHue = 0.0;
static CFTimeInterval gDIISMColAt = 0;
static BOOL gDIISMColDirty = YES;
static UIColor *gDIISMDefA = nil, *gDIISMDefB = nil;
static UIColor *gDIISMColA = nil, *gDIISMColB = nil;

static BOOL gDIISMOn = NO, gDIISMBeat = NO, gDIISMPart = NO, gDIISMFlow = NO;
static double gDIISMAmp = 0.70, gDIISMDotN = 25.0, gDIISMDotA = 0.74,
              gDIISMDotS = 1.0, gDIISMDotP = 1.0;
static int gDIISMMode = 0;

typedef struct {
    float ang, rad, drift, push, sway, swayAmp, swayPhase;
    float size, rot, rotSpd, life, maxLife, phase, tint, beatGain;
    int shape;
} DIISMDot;
static DIISMDot gDIISMDots[DI_IS_DOT_MAX];

@interface DIISMRUTicker : NSObject
- (void)onFrame:(CADisplayLink *)l;
@end
static id gDIISMTicker = nil;
static CADisplayLink *gDIISMRL = nil;

static float diISMRand01(void) {
    return (float)arc4random_uniform(10000) / 10000.0f;
}

/* ---------- 鼓点快照: SB 写 beat.bin, 这里读 ---------- */
typedef struct { double t; float kick, env, bass, playing, energy, extra; } DIBeatSnap;
static int gDIISMBeatFd = -2;
static CFAbsoluteTime gDIISMBeatTryAt = 0;
static DIBeatSnap gDIISMBeatSnap;
static BOOL gDIISMBeatEver = NO;   /* 3.0.88: beat.bin 成功读到过 —— 之后读不到就算"停了" */

static BOOL diISMRUReadBeat(void) {
    if (gDIISMBeatFd < 0) {
        CFAbsoluteTime nt = CFAbsoluteTimeGetCurrent();
        if (gDIISMBeatFd == -1 && nt - gDIISMBeatTryAt < 2.0) return NO;
        gDIISMBeatTryAt = nt;
        NSString *dir = diMruSelfDir();
        if (!dir.length) { gDIISMBeatFd = -1; return NO; }
        NSString *p = [dir stringByAppendingPathComponent:@"beat.bin"];
        gDIISMBeatFd = open(p.fileSystemRepresentation, O_RDONLY);
        if (gDIISMBeatFd < 0) { gDIISMBeatFd = -1; return NO; }
    }
    DIBeatSnap s;
    ssize_t n = pread(gDIISMBeatFd, &s, sizeof s, 0);
    if (n != (ssize_t)sizeof s) return NO;
    if (s.t <= 0.0) return NO;
    if (CFAbsoluteTimeGetCurrent() - s.t > 0.40) return NO;   /* 过期(播放器没在算) → 走自己的频谱 */
    gDIISMBeatSnap = s;
    return YES;
}

/* ---------- 形状(与播放器 diFxShapePath 同款) ---------- */
static CGPathRef __attribute__((unused)) diISMShapePath(int shape, CGFloat s2) {
    CGMutablePathRef p = CGPathCreateMutable();
    CGFloat h = s2 * 0.5f;
    CGFloat in2 = MAX(0.55f, s2 * 0.12f);
    switch (shape) {
        case 1: {
            CGFloat r = h - in2;
            CGPathMoveToPoint(p, NULL, 0, -r);
            CGPathAddLineToPoint(p, NULL, r * 0.72f, 0);
            CGPathAddLineToPoint(p, NULL, 0, r);
            CGPathAddLineToPoint(p, NULL, -r * 0.72f, 0);
            CGPathCloseSubpath(p);
            break;
        }
        case 2:
            CGPathAddRect(p, NULL, CGRectMake(-h + in2, -h + in2, s2 - in2 * 2.0f, s2 - in2 * 2.0f));
            break;
        case 3: {
            CGFloat r = h - in2;
            CGPathMoveToPoint(p, NULL, 0, -r);
            CGPathAddLineToPoint(p, NULL, r * 0.88f, r * 0.66f);
            CGPathAddLineToPoint(p, NULL, -r * 0.88f, r * 0.66f);
            CGPathCloseSubpath(p);
            break;
        }
        default:
            CGPathAddEllipseInRect(p, NULL, CGRectMake(-h, -h, s2, s2));
            break;
    }
    return p;
}

/* ---------- 参数(fx.plist, SB 1Hz 落盘) ---------- */
static BOOL diISMRULoadParams(void) {
    /* 3.0.87: 读失败**不清参数** —— SB 用 writeToFile:atomically 落盘(先写临时文件再改名),
       正好撞上那一瞬间会读不到; 以前读不到就当"关掉", 引擎停 1 秒再起, 表现就是
       "显示一阵一阵的"。现在只有第一次就从来没读到过才算失败。 */
    static BOOL sLoaded = NO;
    NSString *dir = diMruSelfDir();
    if (!dir.length) return sLoaded;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                       [dir stringByAppendingPathComponent:@"fx.plist"]];
    if (![d isKindOfClass:NSDictionary.class]) {
        static CFAbsoluteTime sMissT;
        if (CFAbsoluteTimeGetCurrent() - sMissT > 10.0) {
            sMissT = CFAbsoluteTimeGetCurrent();
            diMruFileLog([NSString stringWithFormat:@"岛特效: fx.plist 读不到 (%@)", dir]);
        }
        return sLoaded;
    }
    sLoaded = YES;
    gDIISMOn   = [d[@"on"] boolValue];
    gDIISMBeat = [d[@"beat"] boolValue];
    gDIISMPart = [d[@"pOn"] boolValue];
    gDIISMFlow = [d[@"flow"] boolValue];
    gDIISMAmp  = [d[@"amp"] doubleValue];
    gDIISMDotN = [d[@"count"] doubleValue];
    gDIISMDotA = [d[@"alpha"] doubleValue];
    gDIISMDotS = [d[@"size"] doubleValue];
    gDIISMDotP = [d[@"str"] doubleValue];
    gDIISMMode = [d[@"mode"] intValue];
    if (gDIISMAmp < 0) gDIISMAmp = 0; if (gDIISMAmp > 2.0) gDIISMAmp = 2.0;
    if (gDIISMDotN < 0) gDIISMDotN = 0; if (gDIISMDotN > 40) gDIISMDotN = 40;
    if (gDIISMDotA < 0.1) gDIISMDotA = 0.1; if (gDIISMDotA > 1.5) gDIISMDotA = 1.5;
    if (gDIISMDotS < 0.1) gDIISMDotS = 0.1; if (gDIISMDotS > 2.0) gDIISMDotS = 2.0;
    if (gDIISMDotP < 0.0) gDIISMDotP = 0.0; if (gDIISMDotP > 2.0) gDIISMDotP = 2.0;
    NSString *ca = d[@"colA"], *cb = d[@"colB"];
    gDIISMDefA = diRhythmHexColor([ca isKindOfClass:NSString.class] ? ca : nil,
                                 [UIColor colorWithRed:1.0 green:1.0 blue:0.706 alpha:1.0]);   /* #FFFFB4 */
    gDIISMDefB = diRhythmHexColor([cb isKindOfClass:NSString.class] ? cb : nil,
                                 [UIColor colorWithRed:0.737 green:0.808 blue:0.988 alpha:1.0]); /* #BCCEFC */
    gDIISMColDirty = YES;
    return YES;
}

/* ---------- 颜色(跟随封面 / 自定义 / 流光, 与播放器同一个调色板) ---------- */
static void diISMRURefreshColors(BOOL force) {
    CFAbsoluteTime nt = CACurrentMediaTime();
    if (!force && !gDIISMColDirty && nt - gDIISMColAt < 0.35) return;
    gDIISMColAt = nt;
    gDIISMColDirty = NO;
    UIColor *defA = gDIISMDefA, *defB = gDIISMDefB;
    if (gDIISMMode != 1) {
        UIView *imgV = nil;
        for (UIView *v in gDIISMGlass.subviews)
            if ([v isKindOfClass:UIImageView.class] && ((UIImageView *)v).image) { imgV = v; break; }
        UIColor *avg = imgV ? diCoverAverageColor(imgV) : nil;
        if (avg) defA = avg;   /* 跟随封面: MRU 拿不到播放器目标 → 用岛上的专辑图求平均色 */
    }
    if (gDIISMFlow) gDIISMHue = fmod(gDIISMHue + 0.0024, 1.0);   /* ~100s 一圈 */
    int cm = gDIISMFlow ? 2 : (gDIISMMode == 1 ? 1 : 0);
    UIColor *ca = nil, *cb = nil;
    diColorPalette(cm, nil, nil, defA, defB, gDIISMHue, YES, &ca, &cb);
    gDIISMColA = ca; gDIISMColB = cb;
}

/* ---------- 粒子池 ---------- */
/* 3.0.90: 粒子宿主的落点。
   496 反馈"没有粒子了" —— 3.0.89 把宿主挂到了 art.window 上, 而 MRU 的窗口是
   SBUISystemApertureSecureWindow(安全窗), 岛是把它里面的内容经门户层投到
   SpringBoard 上显示; 直接挂在窗口上的视图不在被投递的那棵子树里, 于是
   "粒子数一直 16~20、屏幕上什么都没有"。
   现在退回头像所在的子树, 只挑一个**不裁剪**的祖先(通常就是 MRUActivityAccessoryView):
   宿主自己的框比它大很多, 粒子就能画到岛外去; 裁剪由祖先决定, 挑不裁剪的那个容器
   等于把"裁在胶囊里"这条也去掉了。 */
static BOOL __attribute__((unused)) diISMClips(UIView *v) {
    return v ? (v.layer.masksToBounds || v.clipsToBounds) : NO;
}
/* 3.0.91: 就挂在头像的父视图里(3.0.87 的位置, 已验证可见)。
   不再往上爬 —— 往上爬会走到窗体一级, 那正是 3.0.89/90 "粒子数有、屏幕没有"
   和"粒子跑到展开页"的来源。 */
static UIView *diISMHostParent(UIView *art) {
    return art.superview; // 102 device-confirmed visible portal content branch
}

static void diISMEnsureHost(void) {
    UIView *art = gDIISMArt;
    if (!art) return;
    UIView *parent = diISMHostParent(art);
    if (!parent) return;
    CGRect box = [art convertRect:art.bounds toView:parent];
    /* 比 87 的 0.6 倍大一圈: 粒子能飘出小岛, 但宿主仍贴着头像, 不会跑到展开页 */
    CGFloat pad = MAX(box.size.width, box.size.height) * 1.6 + 10.0;
    (void)pad; (void)box;
    // A large, noninteractive canvas in the same visible content branch.
    CGRect want = CGRectUnion(parent.bounds,CGRectInset(box,-160.0,-160.0));
    if (gDIISMHost && gDIISMHost.superview == parent) {
        if (!CGRectEqualToRect(gDIISMHost.frame, want)) gDIISMHost.frame = want;
        /* 玻璃/系统层随时可能挤到前面: 每帧把粒子层顶回去(只是改 zPosition, 不动布局) */
        if (gDIISMHost.layer.zPosition < 900.0) gDIISMHost.layer.zPosition = 900.0;
        gDIISMHost.hidden=NO; gDIISMHost.alpha=1;
        gDIISMHost.clipsToBounds=NO; gDIISMHost.layer.masksToBounds=NO;
        [parent bringSubviewToFront:gDIISMHost];
        return;
    }
    /* 宿主换了(岛重建/换层): 粒子**状态不清**, 只把已经建好的 layer 挪过去 ——
       否则每重建一次就"呼"地全没, 那正是 493 说的"一阵一阵"。 */
    [gDIISMHost removeFromSuperview];
    UIView *h = [UIView new];
    h.userInteractionEnabled = NO;
    h.backgroundColor = UIColor.clearColor;
    h.clipsToBounds = NO;
    h.frame = want;
    h.layer.zPosition = 900.0;
    gDIISMHost = h;
    [parent addSubview:h];
    [parent bringSubviewToFront:h];
    for (int i = 0; i < DI_IS_DOT_MAX; i++)
        if (gDIISMDotLayer[i]) [h.layer addSublayer:gDIISMDotLayer[i]];
    diMruFileLog([NSString stringWithFormat:@"岛特效 粒子宿主=%@ %.0fx%.0f 父=%@ %.0fx%.0f 裁剪=%d 头像=%.0fx%.0f",
                  NSStringFromClass(h.class), want.size.width, want.size.height,
                  NSStringFromClass(parent.class), parent.bounds.size.width, parent.bounds.size.height,
                  (int)diISMClips(parent),
                  art.bounds.size.width, art.bounds.size.height]);
}

static void diISMSpawnDot(void) {
    UIView *art = gDIISMArt;
    if (!art) return;
    int slot = -1;
    for (int i = 0; i < DI_IS_DOT_MAX; i++)
        if (gDIISMDots[i].life <= 0.0f) { slot = i; break; }
    if (slot < 0) return;
    CGFloat R = MIN(art.bounds.size.width, art.bounds.size.height) * 0.5f;
    if (R < 4.0f) return;
    /* 播放器的基准是 57pt 封面(R=28.5)。岛上 23pt 就按比例缩, 缩太狠看不见,
       所以给 0.55 的下限。 */
    float k = (float)(R / 28.5);
    if (k < 0.55f) k = 0.55f;
    if (k > 1.15f) k = 1.15f;

    DIISMDot *d = &gDIISMDots[slot];
    float u1=diISMRand01(),u2=diISMRand01(),u3=diISMRand01();
    d->ang=2*M_PI*u1; d->rad=(31.5f+2.5f*u2)*k;
    // Wider travel without moving the birth position or changing beat/lifetime.
    d->drift=(5+7*u3+4*diIslandEnergy)*k*2.0f;
    d->push=0; d->sway=0; d->swayAmp=0;
    d->shape=arc4random_uniform(4);
    d->size=diFxShapeSide(d->shape)*k*(float)gDIISMDotS;
    d->rot=2*M_PI*u2; d->rotSpd=(u1-0.5f)*1.4f;
    d->maxLife=1.9f+1.4f*u3; d->life=d->maxLife;
    d->tint=diISMRand01(); d->beatGain=0;

    CAShapeLayer *L = gDIISMDotLayer[slot];
    if (!L) {
        L = [CAShapeLayer layer];
        L.opacity = 0.0f;
        L.contentsScale = UIScreen.mainScreen.scale;
        gDIISMDotLayer[slot] = L;
        if (gDIISMHost) [gDIISMHost.layer addSublayer:L];
    }
    CGFloat sz = d->size;
    L.bounds = CGRectMake(-sz/2, -sz/2, sz, sz);
    CGPathRef path = diFxShapePath(d->shape, k*(float)gDIISMDotS);
    L.path = path;
    CGPathRelease(path);
    UIColor *tint = diFxParticleColorBetween(gDIISMColA, gDIISMColB, d->tint);
    if (d->shape == 2) {
        L.fillColor = tint.CGColor;
        L.strokeColor = UIColor.clearColor.CGColor;
        L.lineWidth = 0.0f;
    } else {
        L.fillColor = UIColor.clearColor.CGColor;
        L.strokeColor = tint.CGColor;
        L.lineWidth = diFxShapeLine(d->shape)*k*(float)gDIISMDotS;
    }
    L.lineJoin = kCALineJoinRound;
    L.hidden=NO; L.zPosition=1;
    L.actions=@{@"position":NSNull.null,@"transform":NSNull.null,@"opacity":NSNull.null,
        @"path":NSNull.null,@"bounds":NSNull.null};
    if (gDIISMHost && L.superlayer!=gDIISMHost.layer) [gDIISMHost.layer addSublayer:L];
    gDIISMDotCount++;
}

static void diISMClearDots(void) {
    for (int i = 0; i < DI_IS_DOT_MAX; i++) {
        gDIISMDots[i].life = 0.0f;
        if (gDIISMDotLayer[i]) gDIISMDotLayer[i].opacity = 0.0f;
    }
    gDIISMDotCount = 0;
    gDIISSpawnAcc = 0.0f;
    [gDIISMHost removeFromSuperview];
    gDIISMHost = nil;
}

/* 与播放器 diFxUpdateDots 同一套运动/透明度曲线 */
static void diISMUpdateDots(CGRect cover, float dt, BOOL active) {
    UIView *host = gDIISMHost;
    if (!host || gDIISMDotCount <= 0) return;
    CGFloat cx = CGRectGetMidX(cover);
    CGFloat cy = CGRectGetMidY(cover);
    CGFloat Rc = cover.size.width * 0.5f;

    if (Rc < 4.0f) return;
    float stg = (float)gDIISMDotP;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < DI_IS_DOT_MAX; i++) {
        DIISMDot *d = &gDIISMDots[i];
        CAShapeLayer *L = gDIISMDotLayer[i];
        if (!L) continue;
        if (d->life <= 0.0f) { if (L.opacity != 0.0f) L.opacity = 0.0f; continue; }
        d->life -= dt;
        if (!active && d->life > 0.35f) d->life = 0.35f;
        if (d->life <= 0.0f) {
            d->life = 0.0f;
            L.opacity = 0.0f;
            if (gDIISMDotCount > 0) gDIISMDotCount--;
            continue;
        }
        d->rad+=d->drift*dt; // no capsule-size/radius clamp

        d->rot+=d->rotSpd*dt;
        float progress=fminf(1,fmaxf(0,1-d->life/MAX(d->maxLife,0.16f)));
        float pulseGain=active && diParticleExtraBeat?gDIISMKick*fminf(2,fmaxf(0,stg)):0;
        d->beatGain=pulseGain;
        float fade=fminf(progress/0.001f,1)*fminf(d->life/0.72f,1);
        L.opacity=fminf(1,fmaxf(0,(float)gDIISMDotA*fade*(1+0.22f*pulseGain)));
        float groupScale=gDIISMBeat?gDIISMScaleNow:1;
        float radius=(d->rad+cover.size.width*0.055f*pulseGain)*groupScale;
        L.position=CGPointMake(cx+cosf(d->ang)*radius,cy+sinf(d->ang)*radius);
        float pulse=(0.72f+0.48f*progress)*(1+0.60f*pulseGain)*groupScale;
        CATransform3D tr = CATransform3DMakeRotation(d->rot, 0, 0, 1);
        L.transform = CATransform3DScale(tr, pulse, pulse, 1.0f);
    }
    [CATransaction commit];
}

/* ---------- 律动: 抓玻璃做缩放 ---------- */
static void diISMApplyScale(float kick, BOOL on) {
    /* ===== 3.0.89: 改用 additive 动画, 模型层 transform 一个字节不写 =====
       以前在模型层写 CATransform3DMakeScale。可 diActivityApply 每次布局都会
       写 glass.frame —— transform 非单位时写 frame 会反过来改 bounds, 于是
       "缩放被吃掉/展开多一块影子/玻璃带着放大压到系统专辑上"反复出现,
       3.0.87/88 为此加了一堆"让路"逻辑, 越修越复杂。
       现在动画只管**呈现层**: 系统读到的 transform 永远是单位矩阵,
       布局、frame、形态判定一行都不用改。 */
    UIView *v = gDIISMArt;
    if (!v) { gDIISMScaleNow = 1.0f; return; }
    /* 3.0.102: 23pt island artwork needs its own amplitude calibration.
       Same phase and final scale are consumed by island particles below. */
    CGFloat s=on ? 1+fminf(0.22f,0.20f*(float)gDIISMAmp*kick) : 1;
    if (s <= 1.0015) {
        gDIISMScaleNow = 1.0f;
        if ([v.layer animationForKey:@"di.isl.beat"]) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [v.layer removeAnimationForKey:@"di.isl.beat"];
            [CATransaction commit];
        }
        return;
    }
    /* Reassert when the system removes our presentation animation during layout.
       Cached target alone cannot establish that the visible artwork is scaled. */
    CAAnimation *currentBeat=[v.layer animationForKey:@"di.isl.beat"];
    CALayer *visibleLayer=(CALayer *)v.layer.presentationLayer;
    CGFloat actual=visibleLayer?sqrt(visibleLayer.transform.m11*visibleLayer.transform.m11+visibleLayer.transform.m12*visibleLayer.transform.m12):1;
    if (currentBeat && fabs(s-gDIISMScaleNow)<0.0005 && fabs(actual-s)<0.003) return;
    gDIISMScaleNow = (float)s;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    /* Hold the exact shared pulse on presentation scale without a second easing stage. */
    a.additive = NO;
    a.fromValue = @(s); a.toValue = @(s);
    a.duration = 1.0/60.0;
    a.fillMode = kCAFillModeForwards;
    a.removedOnCompletion = NO;
    [v.layer addAnimation:a forKey:@"di.isl.beat"];
}

/* ---------- 绑定 ---------- */
/* 3.0.91: 辨认"小岛那颗头像"。
   497 日志: 展开页里除了 66 的大专辑, 还有一颗 **45x22** 的小头像(头部那颗),
   它 MIN 边长 22, 也能通过"12~44"的老判据 —— 于是粒子跟着它跑到展开页上去了
   (用户: "你把粒子加到了展开岛")。这里同时卡长短边: 只有近似正方形、边长
   12~34 的才算小岛头像(实际是 23x23); 45x22 / 66x66 / 播放器 57x57 全挡掉。 */
static BOOL diISMIsCompactArt(UIView *v) {
    if (!v || !v.window || v.hidden || v.alpha < 0.02) return NO;
    CGSize sz = v.bounds.size;
    if (sz.width < 12.0 || sz.height < 12.0) return NO;
    if (sz.width > 34.0 || sz.height > 34.0) return NO;
    return YES;
}

static void diISMRUBind(UIView *art, UIView *glass) {
    /* 3.0.89: glass 允许为 nil —— 关掉"启用遮罩"时 MRU 不建自绘玻璃,
       但粒子/律动照样该工作(粒子现在挂在窗口层, 本来就不依赖玻璃)。 */
    if (!art) return;
    /* 只认小岛头像: 展开 66 / 展开页小头像 45x22 / 播放器 57 / 全屏都一律不接 */
    if (!diISMIsCompactArt(art)) return;
    if (gDIISMArt == art) { gDIISMGlass = glass; return; }
    gDIISMArtCand = art;
    gDIISMGlassCand = glass;
    BOOL curOK = (gDIISMArt != nil && gDIISMArt.window != nil && !gDIISMArt.hidden);
    if (!curOK) {
        gDIISMArt = art;
        gDIISMGlass = glass;
    }
}

static void diISMRUAdoptCandidate(void) {
    if (!diISMIsCompactArt(gDIISMArtCand)) return;
    gDIISMArt = gDIISMArtCand;
    gDIISMGlass = gDIISMGlassCand;
}

static void diISMRUTeardown(void) {
    diISMClearDots();
    gDIISMScaleNow = 1.0f;
    UIView *g = gDIISMGlass;
    if (g) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        g.layer.transform = CATransform3DIdentity;
        [CATransaction commit];
    }
    gDIISMArt = nil;
    gDIISMGlass = nil;
    gDIISMArtCand = nil;
    gDIISMGlassCand = nil;
}

/* ===== 3.0.88: 展开/离场时**硬复位** =====
   以前 art 一旦无效(展开成 66pt、换岛、下台)这里只是 return: 粒子清了, 但玻璃上的
   缩放(最多 1.22)留在那儿。岛展开后系统把同一颗头像放大到 66pt, 那块还带着放大的
   玻璃就压到系统专辑上 —— 493/494 说的"展开又多出一块蒙版/影子"就是它。
   现在: 缩放归 1 + 解绑; keepDots=NO 时连粒子宿主一起拆(展开/停止),
   keepDots=YES 时只归缩放 —— 系统换了一颗同尺寸的头像, 粒子该接着飞。 */
static void diISMRUPark(UIView *glass, BOOL keepDots) {
    if (!keepDots && (gDIISMDotCount > 0 || gDIISMHost)) diISMClearDots();
    UIView *g = glass ?: gDIISMGlass;
    if (g) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        g.layer.transform = CATransform3DIdentity;
        [CATransaction commit];
    }
    gDIISMScaleNow = 1.0f;
    gDIISMArt = nil;
    gDIISMGlass = nil;
    gDIISMArtCand = nil;
    gDIISMGlassCand = nil;
}

static void diISMRUStop(void) {
    if (gDIISMRL) { [gDIISMRL invalidate]; gDIISMRL = nil; }
    diISMRUTeardown();
}

static void diISMRUApply(UIView *artwork, UIView *glass) {
    if(!diIslandEffectsAvailable){
        if([artwork.layer animationForKey:@"di.isl.beat"]) [artwork.layer removeAnimationForKey:@"di.isl.beat"];
        if(gDIISMRL || gDIISMHost || gDIISMArt)diISMRUStop();
        return;
    }
    /* 3.0.88: 展开(66)/播放器(57)/全屏 —— 只要不是小岛头像就立刻收干净,
       绝不把上一步的缩放/粒子留在展开态上(493 明确说"我不需要展开")。
       3.0.91: 判据换成 diISMIsCompactArt —— 展开页那颗 45x22 的小头像也挡掉。 */
    if (!diISMIsCompactArt(artwork)) {
        if (artwork == gDIISMArt || glass == gDIISMGlass) diISMRUPark(glass, NO);
        return;
    }
    diISMRUBind(artwork, glass);
}

static void diISMRUEnsure(void) {
    if(!diIslandEffectsAvailable){
        gDIISMOn=NO;gDIISMBeat=NO;gDIISMPart=NO;
        if(gDIISMRL || gDIISMHost || gDIISMArt)diISMRUStop();
        return;
    }
    BOOL has = diISMRULoadParams();
    BOOL need = has && gDIISMOn && (gDIISMBeat || gDIISMPart);
    gDIISMParamsAt = CFAbsoluteTimeGetCurrent();
    if (need && !gDIISMRL) {
        if (!gDIISMTicker) gDIISMTicker = [DIISMRUTicker new];
        gDIISMRL = [CADisplayLink displayLinkWithTarget:gDIISMTicker selector:@selector(onFrame:)];
        gDIISMRL.preferredFramesPerSecond = 60;
        [gDIISMRL addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        diMruFileLog([NSString stringWithFormat:@"岛特效引擎启动 (律动=%d 粒子=%d 幅度=%.2f 数量=%.0f)",
                      (int)gDIISMBeat, (int)gDIISMPart, gDIISMAmp, gDIISMDotN]);
    } else if (!need && gDIISMRL) {
        diMruFileLog(@"岛特效引擎停止");
        diISMRUStop();
    }
}

static void diISMRUFrame(float dtIn) {
    CFAbsoluteTime nowC = CFAbsoluteTimeGetCurrent();
    if (nowC - gDIISMParamsAt > 0.5) {
        gDIISMParamsAt = nowC;
        if (!diISMRULoadParams() || !gDIISMOn || (!gDIISMBeat && !gDIISMPart)) {
            diISMRUStop();
            return;
        }
    }

    /* 绑定维护: 当前这块下台了才换候选, 绝不"谁后注册听谁的" */
    if (!diISMIsCompactArt(gDIISMArt)) {
        UIView *oldGlass = gDIISMGlass;
        /* 展开(66)/展开页小头像(45x22)都算"不该参与": 3.0.91 一并挡掉 */
        BOOL wasExpanded = (gDIISMArt != nil && gDIISMArt.window
                            && !gDIISMArt.hidden && gDIISMArt.alpha >= 0.02
                            && !diISMIsCompactArt(gDIISMArt));
        gDIISMArt = nil; gDIISMGlass = nil;
        if (wasExpanded) {
            /* 展开成 66pt: 律动缩放 + 粒子一起收干净(493: 不需要展开) */
            diISMRUPark(oldGlass, NO);
        } else {
            /* 3.0.88: 先认下一块 —— 系统每次重建岛容器都会换一颗**大小一样**的头像,
               以前这里直接全清, 25 颗粒子要重新一颗颗吐出来(1~2 秒),
               看着就是"一下全没、再一下又出来"。换头像时粒子状态保留, 只把缩放归 1。 */
            diISMRUAdoptCandidate();
            if (!gDIISMArt) {
                diISMRUPark(oldGlass, YES);
            } else if (oldGlass && oldGlass != gDIISMGlass) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                oldGlass.layer.transform = CATransform3DIdentity;
                [CATransaction commit];
                gDIISMScaleNow = 1.0f;
            }
        }
    }
    UIView *art = gDIISMArt;
    if (!art) { diISMClearDots(); return; }

    float dt = dtIn;
    if (dt < 0.002f) dt = 0.002f;
    if (dt > 0.05f) dt = 0.05f;
    gDIISMClock += dt;

    /* 鼓点: 优先 SB 落的 beat.bin(与播放器同一个包络), 读不到再用自己的频谱 */
    BOOL playing = NO;
    float kick = 0.0f;
    BOOL fromFile = diISMRUReadBeat();
    if (fromFile) {
        gDIISMBeatEver = YES;
        playing = (gDIISMBeatSnap.playing > 0.5f);
        kick = gDIISMBeatSnap.kick;
        diIslandEnergy=gDIISMBeatSnap.energy;
        diParticleExtraBeat=gDIISMBeatSnap.extra>0.5f;
    } else if (gDIISMBeatEver) {
        /* 3.0.88: beat.bin 读到过 = SpringBoard 那份引擎在管播放态; 现在读不到/过期
           = 它自己停了(暂停、切走、挂了)。**不能**退回"自己连 41235"那条:
           那条只知道频谱服务活着, 不知道有没有在放, 于是"文件说过期→我算在放→
           冒粒子; SpringBoard 又写回 0→全清掉", 就是 494 的一闪一灭。 */
        playing = NO;
        kick = 0.0f;
    } else {
        diAuPoll();
        BOOL real = diAuAlive();
        diRhythmAdvanceSpectrum(real, real, dt);
        playing = real;
        diFxAdvanceEnergy(real,real,dt);
        diIslandEnergy=gDIFxEnergy;
        float target=real?gDIKick:0;
        float tau=target>diSharedVisualPulse?0.018f:0.090f;
        diSharedVisualPulse+=(target-diSharedVisualPulse)*(1-expf(-dt/tau));
        kick=diSharedVisualPulse;
    }
    if (kick < 0.0f) kick = 0.0f;
    if (kick > 1.0f) kick = 1.0f;
    if (!playing) kick = 0.0f;

    /* 3.0.88: 播放态去抖 —— 开 0.12s / 关 0.65s。
       beat.bin 30Hz 落盘、这边 60Hz 读, 中间任何一次读空/一次 playing=0 都不该
       让满屏粒子当场消失; 只有真的停了半秒以上才清。 */
    static float sOnT = 0.0f, sOffT = 0.0f;
    static BOOL sEff = NO;
    if (playing) {
        sOnT += dt; sOffT = 0.0f;
        if (sOnT >= 0.12f) sEff = YES;
    } else {
        sOffT += dt; sOnT = 0.0f;
        if (sOffT >= 0.65f) sEff = NO;
    }
    if (!sEff) kick = 0.0f;
    gDIISMKick = kick;

    /* 律动 */
    if (gDIISMBeat) diISMApplyScale(kick, sEff);
    else if (gDIISMScaleNow > 1.0005f) diISMApplyScale(0.0f, NO);

    /* 暂停/停止: 粒子清空, 不留悬在半空的 */
    if (!sEff) {
        if (gDIISMDotCount > 0 || gDIISMHost) diISMClearDots();
    } else if (gDIISMPart) {
        diISMEnsureHost();
        diISMRURefreshColors(NO);
        int want = (int)gDIISMDotN;
        if (want > DI_IS_DOT_MAX) want = DI_IS_DOT_MAX;
        if (gDIISMDotCount < want && diIslandEnergy>=0.08f) {
            float p60=fminf(0.4f,0.035f+0.30f*diIslandEnergy);
            if(diISMRand01()<1-powf(1-p60,dt*60))diISMSpawnDot();
        }
        CGPoint center = gDIISMHost ? [art convertPoint:CGPointMake(CGRectGetMidX(art.bounds),CGRectGetMidY(art.bounds)) toView:gDIISMHost] : CGPointZero;
        CGRect cover=CGRectMake(center.x-art.bounds.size.width/2,center.y-art.bounds.size.height/2,art.bounds.size.width,art.bounds.size.height);
        if (cover.size.width < 4.0) cover = CGRectMake(66.0, 46.0, art.bounds.size.width, art.bounds.size.height);
        diISMUpdateDots(cover, dt, YES);
    } else if (gDIISMDotCount > 0 || gDIISMHost) {
        diISMClearDots();
    }

    if (nowC - gDIISMProbeAt > 3.0) {
        gDIISMProbeAt = nowC;
        CALayer *present=(CALayer *)art.layer.presentationLayer;
        CGFloat shown=present?sqrt(present.transform.m11*present.transform.m11+present.transform.m12*present.transform.m12):1;
        diMruFileLog([NSString stringWithFormat:@"[岛律动输出] 开=%d 幅度=%.2f 同步脉冲=%.3f 目标=%.4f 呈现=%.4f 动画=%d 粒子组=%.4f",gDIISMBeat,gDIISMAmp,kick,gDIISMScaleNow,shown,[art.layer animationForKey:@"di.isl.beat"]!=nil,gDIISMBeat?gDIISMScaleNow:1]);
        NSMutableString *clipChain=[NSMutableString string];
        for(UIView *v=art;v;v=v.superview) {
            [clipChain appendFormat:@"%@:%@ clip=%d hidden=%d alpha=%.2f; ",NSStringFromClass(v.class),NSStringFromCGRect(v.bounds),diISMClips(v),v.hidden,v.alpha];
            if(v==v.window)break;
        }
        for(int i=0;i<DI_IS_DOT_MAX;i++) {
            CAShapeLayer *l=gDIISMDotLayer[i];
            if(gDIISMDots[i].life>0 && l) {
                diMruFileLog([NSString stringWithFormat:@"[岛粒子可见性] host=%@ frame=%@ bounds=%@ 位置=%@ 透明=%.3f 线宽=%.2f 路径=%@ 挂载=%d 链=%@",NSStringFromClass(gDIISMHost.superview.class),NSStringFromCGRect(gDIISMHost.frame),NSStringFromCGRect(gDIISMHost.bounds),NSStringFromCGPoint(l.position),l.opacity,l.lineWidth,NSStringFromCGRect(l.path?CGPathGetBoundingBox(l.path):CGRectZero),l.superlayer==gDIISMHost.layer,clipChain]);
                break;
            }
        }
        diMruFileLog([NSString stringWithFormat:
            @"岛特效同步探针 102可见宿主恢复 外扩=2 内容分支外飘=1 头像=%.0fx%.0f 文件=%d 播放=%d 鼓=%.2f 缩放=%.3f 粒子=%d 宿主=%@ 曾在=%@",
            art.bounds.size.width, art.bounds.size.height, (int)fromFile,
            (int)playing, kick, gDIISMScaleNow, gDIISMDotCount,
            gDIISMHost ? NSStringFromClass(gDIISMHost.superview.class) : @"无",
            gDIISMBeatEver ? @"是" : @"否"]);
    }
}

@implementation DIISMRUTicker
- (void)onFrame:(CADisplayLink *)l {
    double dt = l.targetTimestamp - l.timestamp;
    if (dt <= 0.0 || dt > 0.12) dt = 1.0 / 60.0;
    @try { diISMRUFrame((float)dt); } @catch (__unused NSException *e) {}
}
@end



static void diRhythmEnsure(void) {
    /* 3.0.79: 巡检时同步刷新播放状态 —— 引擎挂起后, 这就是唯一的"该不该醒"依据 */
    diPlayRatePoll();
    if(gDIPlayRateState==0 || diFxExpandedOrSuggestion(gDIRhythmTarget)){
        diFxSuspendVisuals();
        if(!diRhythmPickTarget())return;
        if(gDIPlayRateState==0)return;
    }
    /* 3.0.49: 与保险档位联动 —— 连续崩两次(档位≤1)时律动整体停, 先保系统能开机。
       用户在设置里拨任意开关会重新拉满档位, 律动随之恢复。 */
    /* 3.0.84: 只开岛特效时也要把引擎拉起来 */
    /* 3.0.85: 岛特效不再由 SB 引擎带跑(改走 MRU), need 恢复原判据 */
    BOOL need = (rhythmFxOn && (rhythmOn || rhythmRingOn || diProgressRingOn || rhythmParticlesOn || rhythmBarsOn))
                && gDIStage >= 2;
    if (need && !gDIRhythmLink) {
        if (!gDIRhythmTicker) gDIRhythmTicker = [DIFxTicker new];
        gDIRhythmLink = [CADisplayLink displayLinkWithTarget:gDIRhythmTicker
                                                    selector:@selector(onFrame:)];
        /* 0 = 跟随屏幕原生刷新率(ProMotion 120Hz)。以前写死 60Hz, 在 120Hz 屏上
           每两帧才动一次 —— 这就是"一卡一卡"的直接原因。 */
        gDIRhythmLink.preferredFramesPerSecond = 60;
        [gDIRhythmLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        RLog(@"[律动] 引擎启动 CADisplayLink %ld (0=跟随原生刷新率) (总=%d 圆=%d 缩放=%d 环=%d 粒=%d 条=%d)",
             (long)gDIRhythmLink.preferredFramesPerSecond,
             rhythmFxOn, rhythmRoundCover, rhythmOn, rhythmRingOn,
             rhythmParticlesOn, rhythmBarsOn);
    } else if (need && gDIRhythmLink && gDIRhythmLink.paused) {
        /* 3.0.66: 休眠唤醒 —— 播放器重新布局(控制中心打开/换尺寸)或 1Hz 巡检时恢复。
           3.0.79: 暂停/停止时不唤醒(否则每秒醒一次、跑一帧又挂起, 白耗电);
           真的恢复播放(PlaybackRate > 0)才唤醒。
           3.0.88: 494 —— 唤醒条件必须和主循环的 active **同一套判据**, 否则
           会出现"巡检唤醒 → 主循环算 active=0 → 立刻再挂起"的来回抖(494 日志里
           一秒两三次), beat.bin 的 playing 跟着 0/1 翻, 岛上的粒子就闪。
           现在: 没歌(info 空且 Rate 不是 1)不唤醒; 刚停下 2 秒内也不唤醒(熔断)。 */
        CFAbsoluteTime nowW = CFAbsoluteTimeGetCurrent();
        if (gDIBeatStopAt > 0 && nowW - gDIBeatStopAt < 2.0) return;
        BOOL songNow = gDIInfoReady ? gDIHasNowPlaying : YES;
        if (gDIPlayRateState == 1) songNow = YES;
        BOOL playNow = mrQueryOK ? musicPlaying : AVAudioSession.sharedInstance.isOtherAudioPlaying;
        if (gDIPlayRateState == 0) playNow = NO;
        else if (gDIPlayRateState == 1) playNow = YES;
        if (!playNow || !songNow) return;
        BOOL visible=diPowerPlayerVisible(gDIRhythmTarget);
        if(!visible)for(UIView *root in gDIArtRoots.allObjects)if(diPowerPlayerVisible(root)){visible=YES;break;}
        if(!visible)return;
        gDIBeatStopped = NO;
        gDIRhythmLink.paused = NO;
        RLog(@"[律动] 重新播放 → 引擎唤醒");
    } else if (!need && gDIRhythmLink) {
        [gDIRhythmLink invalidate];
        gDIRhythmLink = nil;
        diRhythmReset();
        RLog(@"[律动] 引擎停止");
    }
}
