// 漂流岛 Drift Island —— 灵动岛视频背景
// 素材目录: /var/mobile/灵动岛 (mp4/mov/m4v, 按文件名排序, 设置里按序号选用)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CMTime.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <substrate.h>
#import <os/log.h>
#include <vector>

static NSString *const kDomain = @"com.abgg332.driftisland";
static NSString *const kNotifyStr = @"com.abgg332.driftisland.reload";
static NSString *const kMaterialDir = @"/var/mobile/灵动岛";
static NSString *const kFrameDir = @"/var/mobile/灵动岛/帧率素材"; // 频谱序列帧目录(png/jpg, 按文件名数字排序)

static BOOL logEnabled; // 日志开关
static BOOL gLocked = NO; // 锁屏状态: 锁屏期间所有岛视频/帧率动画全停(锁屏界面组件也是岛视图, 不停会一直亮屏)
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
static BOOL hideNoMusic; // 无音乐时隐藏小岛视频(开关控制)
static NSInteger smallIdx, expandIdx;
/* 频谱帧率动画参数 */
static double animFPS = 50, animScale = 1, animOffsetX, animOffsetY;
static NSString *animFolder; // 选中的素材文件夹名(帧率素材目录下的子文件夹)
static BOOL gFramesDirty;    // 素材文件夹变更标志: 立即重扫

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
static NSArray<NSString *> *framePaths(void) {
    static NSArray *c; static CFAbsoluteTime t;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gFramesDirty || (c && now - t > 2.0)) { gFramesDirty = NO; c = nil; }
    if (c) return c;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSString *base = animFolder.length ? [kFrameDir stringByAppendingPathComponent:animFolder] : nil;
    if (!base) {
        // 未选择文件夹: 默认用第一个子文件夹(避免多套素材混播); 根目录有直属 png 才用根目录
        NSFileManager *fm = NSFileManager.defaultManager;
        NSMutableArray *dirs = [NSMutableArray array];
        BOOL hasDirect = NO;
        for (NSString *n in [fm contentsOfDirectoryAtPath:kFrameDir error:NULL]) {
            NSString *p = [kFrameDir stringByAppendingPathComponent:n];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:p isDirectory:&isDir]) continue;
            if (isDir) [dirs addObject:n];
            else {
                NSString *ext = n.pathExtension.lowercaseString;
                if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) hasDirect = YES;
            }
        }
        if (hasDirect || !dirs.count) base = kFrameDir;
        else {
            [dirs sortUsingSelector:@selector(localizedCompare:)];
            base = [kFrameDir stringByAppendingPathComponent:dirs.firstObject];
            static NSString *lastAuto;
            if (![lastAuto isEqualToString:dirs.firstObject]) { lastAuto = dirs.firstObject; DLog(@"未选素材文件夹, 默认使用: %@", dirs.firstObject); }
        }
    }
    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:base];
    while (stack.count) {
        NSString *dir = stack.firstObject; [stack removeObjectAtIndex:0];
        for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            NSString *p = [dir stringByAppendingPathComponent:n];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) { [stack addObject:p]; continue; }
            NSString *ext = n.pathExtension.lowercaseString;
            if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"])
                [out addObject:p];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a.lastPathComponent compare:b.lastPathComponent options:NSNumericSearch];
    }];
    c = out; t = now;
    return out;
}

// 素材列表缓存(2秒TTL): displayLink 每帧调用, 不能每次扫描目录
static NSArray<NSString *> *cachedMaterials(void) {
    static NSArray *l; static CFAbsoluteTime t;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!l || now - t > 2.0) { l = materialList(); t = now; }
    return l;
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
    enabled = pBool(@"enabled", NO);
    hideNoMusic = pBool(@"hideNoMusic", NO); // 无音乐时隐藏小岛视频
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
}

#pragma mark - 视频覆盖视图

@interface DIVideoView : UIView
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, strong) CADisplayLink *syncLink;
@property (nonatomic, assign) BOOL expandedLayer; // YES=展开层(播展开素材), NO=小岛层
@property (nonatomic, strong) id loopObs; // composition 手动循环通知(播完回开头续播)
@end

static char kWinVideoSmall, kWinVideoExpand, kWinVideoSpec;

/* 音频会话: 只在 SpringBoard 进程设 Ambient+混音(让岛视频"隐形", 不抢占 now-playing, 音乐不会自动暂停);
   绝不在 mediaremoted 等系统音频进程执行(会干扰自动锁屏) */
static void setupAudioSession(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (![NSBundle.mainBundle.bundleIdentifier.lowercaseString isEqualToString:@"com.apple.springboard"]) return;
        NSError *err = nil;
        [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryAmbient mode:AVAudioSessionModeDefault
                                           options:AVAudioSessionCategoryOptionMixWithOthers error:&err];
        DLog(@"音频会话(Ambient+混音, 仅SpringBoard): %@", err ? err.localizedDescription : @"成功");
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
    if (!mrGet) { static BOOL mrLogged = NO; if (!mrLogged) { mrLogged = YES; DLog(@"MediaRemote 不可用(dlopen/符号缺失), 音乐检测走音频层兜底(此日志只提示一次)"); } return; }
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
static NSHashTable *hostTable; // 弱引用宿主集合
static void updateSingleVideo(UIWindow *win); // 前置声明

static CALayer *diFindAudioLayer(UIView *host); // 前向声明: syncFrameToHost 的"无音乐隐藏"判据使用
@implementation DIVideoView {
    NSInteger _missCount; // 连续不可见帧计数, 攒够才暂停 displayLink(防瞬时抖动误停)
    NSInteger _stallCount; // 播放器起不来计数: 攒够自动重载素材, 保证无限循环不被打断
    NSInteger _retryCount; // 重试播放计数: 连续3次无效才重建播放器自愈
}

+ (Class)layerClass { return AVPlayerLayer.class; }

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _player = [[AVQueuePlayer alloc] init];
        _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        _player.muted = YES; // 永远静音
        setupAudioSession(); // Ambient 混音: 不抢占 now-playing
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
    if (!hostVisible) {
        if (!self.hidden) self.hidden = YES;
        if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause];
        if (++_missCount > 10) _syncLink.paused = YES; // 岛彻底消失后很快停循环
        return;
    }
    _missCount = 0;
    // 形态判定用呈现层高度: 动画收尾才越过阈值
    CGFloat ph = pl ? pl.bounds.size.height : host.bounds.size.height;
    BOOL expanded = ph > 60; // 小岛高约36, 展开高 51~223
    BOOL mine = (expanded == self.expandedLayer);
    NSString *want = mine ? materialPathFor(expanded) : nil;
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
            if (++_stallCount > 120) { _stallCount = 0;
                if (![want isEqualToString:self.currentPath]) {
                    [self loadVideo:want]; DLog(@"播放器连续2秒起不来, 重载素材: %@", want);
                } else {
                    CMTime t = self.player.currentTime, d = self.player.currentItem ? self.player.currentItem.duration : kCMTimeInvalid;
                    double sec = CMTimeGetSeconds(t), dur = CMTimeGetSeconds(d);
                    if (++_retryCount > 2) { _retryCount = 0; [self loadVideo:want]; DLog(@"重试3次仍不播, 重建播放器自愈: %@", want.lastPathComponent); }
                    else if (dur > 0 && sec >= dur - 0.05) {
                        [self.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
                        [self.player play]; DLog(@"播到结尾停住, 回开头续播");
                    } else {
                        [self.player play]; // 路径没变只重试播放, 不重建播放器(重建会黑屏闪一下)
                        float spd2 = (float)(animFPS / 50.0); if (spd2 < 0.1) spd2 = 0.1; if (spd2 > 4) spd2 = 4;
                        [self.player setRate:spd2];
                        DLog(@"播放器2秒未起, 重试播放(%d/3, 不重载防黑屏)", (int)_retryCount);
                    }
                }
            }
        } else {
            _stallCount = 0; _retryCount = 0;
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
    if (_loopObs) [[NSNotificationCenter defaultCenter] removeObserver:_loopObs];
}

// 频谱动画视图: 序列帧播放(替代视频), 支持帧率/旋转/反转/旋转速度/缩放/XY偏移, 全部由偏好实时驱动
// 区域沿用频谱标定(展开岛右上角), 用呈现层 bounds 实时计算不跑位; 开关关=隐藏(露出系统频谱)

- (void)loadVideo:(NSString *)path {
    self.currentPath = path;
    self.looper = nil;
    if (self.loopObs) { [[NSNotificationCenter defaultCenter] removeObserver:self.loopObs]; self.loopObs = nil; }
    [self.player replaceCurrentItemWithPlayerItem:nil];
    if (!path.length) { self.hidden = YES; DLog(@"素材为空: /var/mobile/灵动岛 下没有 mp4/mov/m4v"); return; }
    /* 音频冲突根治: 用 AVMutableComposition 只保留视频轨(剔除音轨)。
       之前 muted=YES 但音轨仍存在, AVPlayer 播放时在 SpringBoard 激活音频会话,
       rootless iOS16.4.1 上打开视频/音乐类 app 会提示"有其他软件使用音频, 自动暂停播放"。
       无音轨 → 播放器完全不碰音频管道, 不激活任何会话, 顺带省掉音频解码 CPU */
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVPlayerItem *item = nil;
    BOOL usedComp = NO;
    @try {
        AVAssetTrack *vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (vt) {
            AVMutableComposition *comp = [AVMutableComposition composition];
            AVMutableCompositionTrack *cv = (AVMutableCompositionTrack *)[comp addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
            if ([cv insertTimeRange:CMTimeRangeMake(kCMTimeZero, asset.duration) ofTrack:vt atTime:kCMTimeZero error:NULL]) {
                item = [AVPlayerItem playerItemWithAsset:comp];
                usedComp = YES;
                DLog(@"素材已剥离音轨(纯视频, 不碰音频会话): %@", path.lastPathComponent);
            }
        }
    } @catch (NSException *e) { item = nil; usedComp = NO; }
    if (!item) item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]]; // 兜底: 剥离失败用原视频
    DLog(@"加载视频: %@", path);
    if (usedComp) {
        /* AVPlayerLooper 不支持 AVMutableComposition(播完一遍就停 → 卡住 → 看门狗重载 → 闪黑)。
           composition 素材改用"播完通知回开头续播"的无缝手动循环; 原生素材(剥离失败兜底)才用 looper */
        DIVideoView *sv = self; // 强捕获: 每次loadVideo开头都会先移除旧通知, 不会长期成环
        self.loopObs = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *n) {
                if (!sv.player.currentItem) return;
                [sv.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
                float spdL = (float)(animFPS / 50.0); if (spdL < 0.1) spdL = 0.1; if (spdL > 4) spdL = 4;
                [sv.player setRate:spdL]; // setRate 自带播放语义, 回开头无缝续播
            }];
        [self.player replaceCurrentItemWithPlayerItem:item]; // 手动挂载(looper 路径才自动挂, 这里必须自己挂, 否则 player 为空永远不播)
    } else {
        self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:item];
    }
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

- (void)step {
    UIView *host = self.superview;
    if (!host || host.window == nil) { self.hidden = YES; if (++_miss > 15) _link.paused = YES; return; }
    syncNativeSpectrum(host); // 无条件每帧同步音频掩码(即使帧率素材关闭/没放歌): 岛重新展开或层重建时波形立即被藏
    /* 帧率图只在展开的音乐岛生效(实测展开岛约407x202); 其他形态/其他岛(锁屏大卡700+/录屏/小岛)全部禁用 */
    BOOL expand = host.bounds.size.height > 100 && host.bounds.size.height < 300
               && host.bounds.size.width > 250 && host.bounds.size.width < 500;
    NSArray<NSString *> *frames = framePaths();
    CALayer *audioL = expand ? diFindAudioLayer(host) : nil; // 原生音频动态层: 在=音乐岛
    CALayer *apl = audioL ? (audioL.presentationLayer ?: audioL) : nil; // 必须真实可见(隐藏/透明/超小都算非音乐岛)
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


/* 音频开关: 开→直接 hidden 展开岛右侧音频律动的原生 UIImageView(探针实测 {{w-79.6, 24.9}, {71.5×53.2}}, 图层直接绘制波形);
   关→恢复显示。不是掩码挖洞, 是把原生图层真正隐藏(只 hidden 我们标记过的, 不碰别人的)。
   只在展开稳定态应用(收缩态岛太小没有这个图层); 恢复时只解除自己的标记, 别人 hidden 的不动 */
static char kDiSpecHit;
static void syncNativeSpectrum(UIView *bestRoot) {
    // 关: 恢复我们隐藏过的所有图层
    if (!spectrumOn || !enabled) {
        NSArray *hits = objc_getAssociatedObject(bestRoot, &kDiSpecHit);
        if (hits.count) {
            for (UIView *v in hits) if ([v isKindOfClass:UIView.class] && v.hidden) v.hidden = NO;
            objc_setAssociatedObject(bestRoot, &kDiSpecHit, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            DLog(@"音频开关关: 恢复 %lu 个原生波形图层", (unsigned long)hits.count);
        }
        return;
    }
    CALayer *pl = bestRoot.layer.presentationLayer;
    CGSize bs = pl ? pl.bounds.size : bestRoot.bounds.size;
    if (bs.width < 250 || bs.width > 500 || bs.height < 150 || bs.height > 300) {
        // 收缩态/锁屏大卡: 收缩态本来就没波形图层, 不动; 但若开关在展开时打开过又切走, 顺便恢复防漏
        NSArray *hits = objc_getAssociatedObject(bestRoot, &kDiSpecHit);
        if (hits.count) { for (UIView *v in hits) if (v.hidden) v.hidden = NO; objc_setAssociatedObject(bestRoot, &kDiSpecHit, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        return;
    }
    // 开: 找右侧波形图层(叶 UIImageView, 尺寸 50~100 × 35~70, 中心 x > 0.7*岛宽)
    NSMutableArray<UIView *> *found = [NSMutableArray new];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:bestRoot];
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if (v.hidden || v.alpha < 0.05) continue; // 已经被别人藏的不管
        if ([v isKindOfClass:UIImageView.class] && v.subviews.count == 0) {
            CGSize s = v.bounds.size;
            if (s.width >= 50 && s.width <= 100 && s.height >= 35 && s.height <= 70) {
                CGPoint c = CGPointMake(v.frame.origin.x + s.width / 2, v.frame.origin.y + s.height / 2);
                if (c.x > bs.width * 0.7 && c.y > 0 && c.y < bs.height) { [found addObject:v]; continue; }
            }
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    NSArray *prev = objc_getAssociatedObject(bestRoot, &kDiSpecHit);
    BOOL changed = NO;
    if (found.count) {
        for (UIView *v in found) { if (!v.hidden) { v.hidden = YES; changed = YES; } }
        objc_setAssociatedObject(bestRoot, &kDiSpecHit, found, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (changed || prev.count != found.count) DLog(@"音频开关开: 直接隐藏 %lu 个原生波形图层 %@", (unsigned long)found.count, [found valueForKeyPath:@"frame"]);
    }
}

#pragma mark - 宿主挂载

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

static void updateSingleVideo(UIWindow *win) {
    if (!win) return;
    DIVideoView *smallV = objc_getAssociatedObject(win, &kWinVideoSmall);
    DIVideoView *expandV = objc_getAssociatedObject(win, &kWinVideoExpand);
    if (!enabled) {
        for (DIVideoView *v in diLayers(smallV, expandV)) {
            if (v && !v.hidden) { v.hidden = YES; if (v.player.timeControlStatus != AVPlayerTimeControlStatusPaused) [v.player pause]; }
        }
        return;
    }
    UIView *capRoot = nil, *bestRoot = nil; CGFloat bestA = 0;
    for (UIView *h in hostTable) {
        if (h.window != win || h.isHidden) continue; // 不看 alpha: 岛淡入淡出期间仍要贴合
        if (h.bounds.size.width < 2 || h.bounds.size.height < 2) continue;
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
    syncNativeSpectrum(bestRoot); // 音频开关开→隐藏原生音频层, 关→恢复
    animV.link.paused = NO; // 岛活动期间保持动画循环, 内部按开关自隐藏
}

static void updateHost(UIView *host) {
    if (!host || !viewHasToken(host, @"SAUIElementView")) return;
    attach(host);
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
    }
}


#pragma mark - layoutSubviews hook（沿用已验证的防重复安装模式）

struct DIHook { Class cls; IMP original; };
static std::vector<DIHook> hooks;

/* 探针: 每10秒一次性打印岛窗口内全部视图(类名+frame+hidden+是否直接绘制), 摸清岛内部结构 */
static void islandProbe(UIView *host) {
    static NSInteger probeCount = 0; // 探针只跑前2次(全窗口遍历较重, 周期执行会导致小岛视频周期性闪黑), 探完自动停止
    if (probeCount >= 2) return;
    probeCount++;
    UIView *top = host.window ?: host;
    NSMutableArray *lines = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:top];
    while (stack.count && lines.count < 120) {
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0];
        for (UIView *c in v.subviews) [stack addObject:c];
        if ([NSStringFromClass(v.class) hasPrefix:@"DI"]) continue; // 跳过本插件的层
        CGRect f = [host convertRect:v.bounds fromView:v];
        NSMutableString *ln = [NSMutableString stringWithFormat:@"%@%@", NSStringFromClass(v.class), NSStringFromCGRect(f)];
        if (v.isHidden) [ln appendString:@"(隐)"];
        if (v.alpha < 0.99) [ln appendFormat:@"(a%.1f)", v.alpha];
        if (v.subviews.count == 0 && v.layer.contents) [ln appendString:@"[绘]"];
        [lines addObject:ln];
    }
    DLog(@"岛全探针: %@", [lines componentsJoinedByString:@" | "]);
}
static void layoutHook(UIView *self, SEL selector) {
    Class concrete = object_getClass(self);
    for (Class c = concrete; c; c = class_getSuperclass(c)) {
        BOOL found = NO;
        for (const DIHook &h : hooks)
            if (h.cls == c) { ((void(*)(id,SEL))h.original)(self, selector); found = YES; break; }
        if (found) break;
    }
    if (NSThread.isMainThread) { updateHost(self); islandProbe(self); }
}

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
static void visibilityTick(void) {
    refreshPrefs();
    static CFAbsoluteTime tMR; // CPU 优化: MediaRemote 查询 1秒一次(检测音乐停止够快)
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - tMR > 1.0) { tMR = now; queryMusicPlaying(); }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]])
            for (UIWindow *w in ((UIWindowScene *)s).windows) updateSingleVideo(w);
}

/* 锁屏状态变化: 锁→全停(不再挂载/播放, 根治锁屏界面常亮); 解锁→恢复 */
static void applyLockState(BOOL locked) {
    if (locked == gLocked) return;
    gLocked = locked;
    if (locked) {
        [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:NULL]; // 释放会话: iOS16 上放歌时不再抑制自动息屏
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ setupAudioSession(); }); // 解锁后重新应用类别
    }
    DLog(@"锁屏状态: %@", locked ? @"已锁定 → 全部暂停" : @"已解锁 → 恢复");
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
    dispatch_async(dispatch_get_main_queue(), ^{ refreshAll(); installKnownHosts(); });
}


__attribute__((constructor)) static void init(void) {
    @autoreleasepool {
        refreshPrefs();
        NSString *bid = NSBundle.mainBundle.bundleIdentifier.lowercaseString;
        if (![bid isEqual:@"com.apple.springboard"]) return;
        logHandle = os_log_create("com.abgg332.driftisland", "runtime");
        DLog(@"===== 漂流岛 tweak 加载 (SpringBoard) =====");
        dispatch_async(dispatch_get_main_queue(), ^{
            refreshAll(); installKnownHosts();
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                prefsChanged, (__bridge CFStringRef)kNotifyStr, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                lockStateChanged, CFSTR("com.apple.springboard.lockstate"), NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            // 播放状态轮询: 岛触发才加载/播放, 无通知(岛收回)即暂停
            static dispatch_source_t tickTimer;
            tickTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(tickTimer, DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC, 0.1 * NSEC_PER_SEC);
            dispatch_source_set_event_handler(tickTimer, ^{ visibilityTick(); });
            dispatch_resume(tickTimer);
            // 私有类可能加载较晚, 分阶段重试
            for (int s : {2, 5, 15, 30, 60})
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)s * NSEC_PER_SEC),
                    dispatch_get_main_queue(), ^{ installKnownHosts(); refreshAll(); });
        });
    }
}
