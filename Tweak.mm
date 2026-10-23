// 漂流岛 Drift Island —— 灵动岛视频背景
// 素材目录: /var/mobile/灵动岛 (mp4/mov/m4v, 按文件名排序, 设置里按序号选用)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CMTime.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>
#include <vector>

static NSString *const kDomain = @"com.abgg332.driftisland";
static NSString *const kNotifyStr = @"com.abgg332.driftisland.reload";
static NSString *const kMaterialDir = @"/var/mobile/灵动岛";

static BOOL logEnabled; // 日志开关
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
        [fm createDirectoryAtPath:kMaterialDir withIntermediateDirectories:YES attributes:NULL error:NULL];
        path = [kMaterialDir stringByAppendingPathComponent:@"driftisland.log"];
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

/* 偏好缓存: 供 displayLink 每帧读取(不直接读 CFPreferences), 由 refreshPrefs 定期刷新 */
static BOOL enabled, smallOn = YES, expandOn = YES, hideAirPlay, spectrumOn;
static NSInteger smallIdx, expandIdx, spectrumIdx;

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

static NSString *spectrumPath(void) {
    if (!spectrumOn) return nil;
    NSArray<NSString *> *list = cachedMaterials();
    if (!list.count) return nil;
    NSInteger idx = spectrumIdx;
    if (idx < 0) idx = 0;
    if (idx >= (NSInteger)list.count) idx = list.count - 1;
    return [kMaterialDir stringByAppendingPathComponent:list[idx]];
}

static void refreshPrefs(void) {
    enabled = pBool(@"enabled", NO);
    logEnabled = pBool(@"logging", NO);
    smallOn = pBool(@"smallOn", YES);
    expandOn = pBool(@"expandOn", YES);
    hideAirPlay = pBool(@"hideAirPlay", NO);
    spectrumOn = pBool(@"spectrumOn", NO);
    spectrumIdx = pInt(@"spectrumIndex", 0);
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
@property (nonatomic, assign) BOOL spectrumLayer; // YES=频谱层(对齐 anchorView 位置)
@property (nonatomic, weak) UIView *anchorView;   // 频谱层的锚点: 系统频谱视图
@end

static char kWinVideoSmall, kWinVideoExpand, kWinVideoSpec; // 每窗口视频层(小岛/展开/频谱)
// enabled 等偏好缓存已在 materialPathFor 上方声明
static NSHashTable *hostTable; // 弱引用宿主集合
static void updateSingleVideo(UIWindow *win); // 前置声明

@implementation DIVideoView {
    NSInteger _missCount; // 连续不可见帧计数, 攒够才暂停 displayLink(防瞬时抖动误停)
}

+ (Class)layerClass { return AVPlayerLayer.class; }

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _player = [[AVQueuePlayer alloc] init];
        _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        _player.muted = YES; // 永远静音
        AVPlayerLayer *l = (AVPlayerLayer *)self.layer;
        l.player = _player;
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = YES;
        // 逐帧同步: 岛收缩/展开是系统动画, 每帧把视频对齐到岛的实时呈现尺寸, 永不露底
        _syncLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(syncFrameToHost)];
        [_syncLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}

// 每帧: 帧贴合始终进行(即使本层非当前形态, 切换瞬间 frame 已就位), 显示/播放只属于本形态层
// 无岛活动时两层连续 20 帧不可见才暂停循环(省电); 岛可见期间循环保持活跃
- (void)syncFrameToHost {
    UIView *host = self.superview;
    if (!host || host.window == nil) { _syncLink.paused = YES; return; }
    if (self.spectrumLayer) { [self syncSpectrum]; return; }
    CALayer *pl = host.layer.presentationLayer;
    // 帧贴合: 对齐宿主实时呈现值(动画插值), 外扩2pt覆盖取整边缘缝隙
    CGRect b = pl ? pl.bounds : host.bounds;
    b = CGRectInset(b, -2, -2);
    if (!CGRectEqualToRect(self.frame, b)) self.frame = b;
    CGFloat cr = pl ? pl.cornerRadius : host.layer.cornerRadius;
    if (self.layer.cornerRadius != cr) self.layer.cornerRadius = cr;
    BOOL hostVisible = enabled && !host.isHidden && host.bounds.size.width > 2;
    if (!hostVisible) {
        if (!self.hidden) self.hidden = YES;
        if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause];
        if (++_missCount > 20) _syncLink.paused = YES; // 岛彻底消失后才停循环
        return;
    }
    _missCount = 0;
    // 形态判定用呈现层高度: 动画收尾才越过阈值
    CGFloat ph = pl ? pl.bounds.size.height : host.bounds.size.height;
    BOOL expanded = ph > 60; // 小岛高约36, 展开高 51~223
    BOOL mine = (expanded == self.expandedLayer);
    NSString *want = mine ? materialPathFor(expanded) : nil;
    if (mine && want) {
        if (self.hidden) self.hidden = NO;
        if (self.player.timeControlStatus != AVPlayerTimeControlStatusPlaying) [self.player play];
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

// 频谱层: 对齐系统频谱视图位置, 盖住它; 开关关/无锚点时恢复系统频谱并隐藏视频
- (void)syncSpectrum {
    UIView *a = self.anchorView;
    if (!a || !a.window || !self.superview) {
        if (!self.hidden) self.hidden = YES;
        if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause];
        if (++_missCount > 20) _syncLink.paused = YES;
        return;
    }
    _missCount = 0;
    CALayer *pl = a.layer.presentationLayer;
    CGRect f = pl ? pl.frame : a.frame;
    self.frame = CGRectInset(f, -1, -1); // 居中外扩1pt盖住边缘
    self.layer.cornerRadius = pl ? pl.cornerRadius : a.layer.cornerRadius;
    BOOL show = enabled && spectrumOn && !a.isHidden;
    if (show) {
        a.hidden = YES; // 打开频谱素材: 隐藏系统频谱
        NSString *want = spectrumPath();
        if (want) {
            if (self.hidden) self.hidden = NO;
            if (self.player.timeControlStatus != AVPlayerTimeControlStatusPlaying) [self.player play];
            if (![want isEqualToString:self.currentPath]) [self loadVideo:want];
            return;
        }
    } else {
        a.hidden = NO; // 关闭开关: 恢复系统频谱
    }
    if (!self.hidden) self.hidden = YES;
    if (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) [self.player pause];
}

- (void)loadVideo:(NSString *)path {
    self.currentPath = path;
    self.looper = nil;
    [self.player replaceCurrentItemWithPlayerItem:nil];
    if (!path.length) { self.hidden = YES; DLog(@"素材为空: /var/mobile/灵动岛 下没有 mp4/mov/m4v"); return; }
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
    DLog(@"加载视频: %@", path);
    self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:item];
    // 跟随宿主的圆角
    UIView *host = (UIView *)self.superview;
    self.layer.cornerRadius = host ? host.layer.cornerRadius : 0;
    self.player.muted = YES; // 永远静音
    if (enabled) [self.player play];
}

// 音频会话: Ambient 混音模式, 永不抢占/打断音乐等其它音频; 被打断后自动恢复
+ (void)setupAudioSession {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AVAudioSession *s = [AVAudioSession sharedInstance];
        [s setCategory:AVAudioSessionCategoryAmbient mode:AVAudioSessionModeDefault
               options:AVAudioSessionCategoryOptionMixWithOthers error:NULL];
        [s setActive:YES error:NULL];
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                NSNumber *type = n.userInfo[AVAudioSessionInterruptionTypeKey];
                if (type.integerValue == AVAudioSessionInterruptionTypeEnded) {
                    // 被打断结束(如音乐停止), 恢复视频播放
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIWindow *win = nil;
                        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
                            if ([sc isKindOfClass:[UIWindowScene class]]) { win = ((UIWindowScene *)sc).windows.firstObject; break; }
                        if (win) updateSingleVideo(win);
                    });
                }
            }];
    });
}

@end

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
    [DIVideoView setupAudioSession]; // 混音模式, 不干扰音乐
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

// 递归找类名含任一 token 的子视图(投送按钮/频谱图标, 多特征词兼容不同系统版本命名)
static UIView *findSubviewTokens(UIView *root, NSArray<NSString *> *tokens) {
    if (!root) return nil;
    for (UIView *s in root.subviews) {
        NSString *cn = NSStringFromClass(s.class);
        for (NSString *t in tokens) if ([cn containsString:t]) return s;
        UIView *r = findSubviewTokens(s, tokens);
        if (r) return r;
    }
    return nil;
}
static UIView *findAirPlay(UIView *root) {
    return findSubviewTokens(root, @[@"AirPlay", @"RoutePicker", @"AirDropUp", @"AirTraffic"]);
}
static UIView *findSpectrum(UIView *root) {
    return findSubviewTokens(root, @[@"Spectrum", @"Waveform", @"Visualiz", @"AudioBars"]);
}

// dump 确认: 附件是 _SAUIProvidedViewContainerView(跨进程 PortalView 父容器), 无类名特征
// 只能按位置分: 右侧(x>父宽一半)=频谱, 左侧(26x22)=投送
static UIView *findAccessory(UIView *root, BOOL rightSide) {
    CGFloat half = root.bounds.size.width * 0.5;
    UIView *found = nil;
    for (UIView *s in root.subviews) {
        if ([NSStringFromClass(s.class) containsString:@"ProvidedViewContainer"] && s.bounds.size.width > 1) {
            CGRect r = [root convertRect:s.frame fromView:s.superview];
            if ((r.origin.x > half) == rightSide) { found = s; break; }
        }
        UIView *r2 = findAccessory(s, rightSide);
        if (r2) { found = r2; break; }
    }
    return found;
}

// 展开岛视图树 dump: 记录全部类名+frame; 附件容器额外读 identifier(区分频谱/投送)
static void dumpTree(UIView *v, int depth) {
    if (!v || depth > 16) return;
    NSMutableString *ind = [NSMutableString string];
    for (int i = 0; i < depth; i++) [ind appendString:@"  "];
    NSString *cn = NSStringFromClass(v.class);
    NSString *extra = @"";
    if ([cn containsString:@"Accessory"] || [cn containsString:@"ProvidedView"] || [cn containsString:@"SceneElement"]) {
        for (NSString *kp in @[@"identifier", @"elementIdentifier", @"sceneIdentifier", @"accessoryIdentifier", @"element"]) {
            id val = nil;
            @try { val = [v valueForKey:kp]; } @catch (id e) { val = nil; }
            if (val && ![val isKindOfClass:[UIView class]]) {
                extra = [extra stringByAppendingFormat:@" %@=%@", kp, val];
            }
        }
    }
    DLog(@"%@%@ %@%@", ind, cn, NSStringFromCGRect(v.frame), extra);
    for (UIView *s in v.subviews) dumpTree(s, depth + 1);
}

// 类名探测日志只记一次, 防刷屏
static void logOnce(NSString *tag, UIView *v) {
    if (!v) return;
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *k = [tag stringByAppendingString:NSStringFromClass(v.class)];
    if (![seen containsObject:k]) { [seen addObject:k]; DLog(@"探测%@: %@", tag, NSStringFromClass(v.class)); }
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
    // 频谱素材层: 盖在系统频谱上
    DIVideoView *specV = objc_getAssociatedObject(win, &kWinVideoSpec);
    if (spectrumOn) {
        UIView *sp = findSpectrum(bestRoot) ?: findAccessory(bestRoot, YES); // 右侧附件=频谱(右上角)
        logOnce(@"频谱", sp);
        if (sp) {
            if (!specV) {
                specV = [[DIVideoView alloc] initWithFrame:sp.frame];
                specV.spectrumLayer = YES;
                objc_setAssociatedObject(win, &kWinVideoSpec, specV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            specV.anchorView = sp;
            if (specV.superview != sp.superview) {
                [specV removeFromSuperview];
                if (sp.superview) [sp.superview insertSubview:specV aboveSubview:sp];
            }
            wakeLayer(specV, specV.superview);
        }
    } else if (specV && !specV.hidden) {
        specV.hidden = YES; // 开关关闭: syncSpectrum 也会恢复系统频谱
    }
}

static void updateHost(UIView *host) {
    if (!host || !viewHasToken(host, @"SAUIElementView")) return;
    attach(host);
    if (NSThread.isMainThread && host.window) {
        updateSingleVideo(host.window); // 每次布局跟随岛尺寸
        static int dumpCount;
        if (dumpCount < 2 && host.bounds.size.height > 60) {
            dumpCount++;
            DLog(@"===== 展开岛视图树 dump #%d =====", dumpCount);
            dumpTree(host, 0);
            if (dumpCount == 1) {
                __weak UIView *wh = host;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    if (wh && wh.bounds.size.height > 60) {
                        DLog(@"===== 展开岛视图树 dump #2 (布局稳定后) =====");
                        dumpTree(wh, 0);
                    }
                });
            }
        }
        // 投送按钮: 隐藏/显示 AirPlay 图标 + 左侧附件(右下角投送, dump 中 26x22), 每次布局重申防系统重置
        UIView *ap = findAirPlay(host);
        logOnce(@"投送", ap);
        if (ap && ap.hidden != hideAirPlay) ap.hidden = hideAirPlay;
        UIView *acc = findAccessory(host, NO);
        logOnce(@"投送附件", acc);
        if (acc && acc.hidden != hideAirPlay) acc.hidden = hideAirPlay;
    }
}

#pragma mark - layoutSubviews hook（沿用已验证的防重复安装模式）

struct DIHook { Class cls; IMP original; };
static std::vector<DIHook> hooks;

static void layoutHook(UIView *self, SEL selector) {
    Class concrete = object_getClass(self);
    for (Class c = concrete; c; c = class_getSuperclass(c)) {
        BOOL found = NO;
        for (const DIHook &h : hooks)
            if (h.cls == c) { ((void(*)(id,SEL))h.original)(self, selector); found = YES; break; }
        if (found) break;
    }
    if (NSThread.isMainThread) updateHost(self);
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
    install(@"MRUActivityNowPlayingView");
    install(@"MRUActivityAccessoryView");
}

#pragma mark - 状态刷新

static BOOL lastLoggedEnabled = -1;
static void refreshAll(void) {
    refreshPrefs();
    if (enabled != lastLoggedEnabled) { DLog(@"总开关状态: %@, 声音=永远关闭", enabled ? @"开" : @"关"); lastLoggedEnabled = enabled; }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]])
            dispatch_async(dispatch_get_main_queue(), ^{ updateSingleVideo(((UIWindowScene *)s).windows.firstObject); });
}

// 0.5 秒轮询: 刷新偏好缓存 + 维持视频层; displayLink 负责逐帧贴合
static void visibilityTick(void) {
    refreshPrefs();
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]]) updateSingleVideo(((UIWindowScene *)s).windows.firstObject);
}

static void prefsChanged(CFNotificationCenterRef, void *, CFStringRef, const void *, CFDictionaryRef) {
    dispatch_async(dispatch_get_main_queue(), ^{ refreshAll(); installKnownHosts(); });
}

__attribute__((constructor)) static void init(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"]) return;
        logHandle = os_log_create("com.abgg332.driftisland", "runtime");
        DLog(@"===== 漂流岛 tweak 加载 (SpringBoard) =====");
        dispatch_async(dispatch_get_main_queue(), ^{
            refreshAll(); installKnownHosts();
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                prefsChanged, (__bridge CFStringRef)kNotifyStr, NULL,
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
