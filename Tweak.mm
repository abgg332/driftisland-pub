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

static NSString *materialPath(void) {
    NSArray<NSString *> *list = materialList();
    if (!list.count) return nil;
    NSInteger idx = pInt(@"videoIndex", 0);
    if (idx < 0) idx = 0;
    if (idx >= (NSInteger)list.count) idx = list.count - 1;
    return [kMaterialDir stringByAppendingPathComponent:list[idx]];
}

#pragma mark - 视频覆盖视图

@interface DIVideoView : UIView
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, strong) CADisplayLink *syncLink;
@end

static char kWinVideoKey; // 每窗口唯一视频层
static BOOL enabled;
static NSHashTable *hostTable; // 弱引用宿主集合
static void updateSingleVideo(UIWindow *win); // 前置声明

@implementation DIVideoView

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

// 每帧把视频 frame/圆角 对齐到宿主的实时呈现值(动画插值), 保证任意时刻都精确铺满
- (void)syncFrameToHost {
    UIView *host = self.superview;
    if (!host || self.hidden || self.superview.window == nil) return;
    CALayer *pl = host.layer.presentationLayer;
    CGRect b = pl ? pl.bounds : host.bounds;
    if (!CGRectEqualToRect(self.frame, b)) self.frame = b;
    CGFloat cr = pl ? pl.cornerRadius : host.layer.cornerRadius;
    if (self.layer.cornerRadius != cr) self.layer.cornerRadius = cr;
}

- (void)dealloc {
    [_syncLink invalidate];
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
    [self applyState];
}

- (void)applyState {
    self.hidden = !enabled;
    self.player.muted = YES; // 不需要声音
    if (enabled) [self.player play]; else [self.player pause];
}

// 岛可见 → 播放; 岛收回/隐藏 → 暂停并隐藏; 总开关关 → 全部隐藏(含音乐岛)
- (void)syncVisibility {
    UIView *host = self.superview;
    BOOL visible = enabled && host && !host.isHidden && host.alpha > 0.05
                   && host.window != nil && host.bounds.size.width > 2 && materialPath() != nil;
    if (!enabled) {
        // 总开关关闭: 所有宿主(含音乐岛)的视频都隐藏并暂停
        self.hidden = YES;
        if (self.player.timeControlStatus != AVPlayerTimeControlStatusPaused) [self.player pause];
        return;
    }
    if (visible) {
        self.hidden = NO;
        if (self.player.timeControlStatus != AVPlayerTimeControlStatusPlaying) [self.player play];
        // 视频垫到最底层, 不遮挡文字
        [host sendSubviewToBack:self];
    } else {
        self.hidden = YES;
        if (self.player.timeControlStatus != AVPlayerTimeControlStatusPaused) [self.player pause];
    }
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

// 每窗口唯一视频层: 挂到当前可见的最大岛胶囊上, 统一尺寸/圆角/素材 —— 无重叠无不同步
static void updateSingleVideo(UIWindow *win) {
    if (!win) return;
    DIVideoView *ov = objc_getAssociatedObject(win, &kWinVideoKey);
    if (!enabled) {
        if (ov && !ov.hidden) { ov.hidden = YES; if (ov.player.timeControlStatus != AVPlayerTimeControlStatusPaused) [ov.player pause]; }
        return;
    }
    UIView *bestRoot = nil; CGFloat bestA = 0;
    for (UIView *h in hostTable) {
        if (h.window != win || h.isHidden || h.alpha < 0.05) continue;
        if (h.bounds.size.width < 2 || h.bounds.size.height < 2) continue;
        UIView *root = islandRoot(h);
        CGFloat a = root.bounds.size.width * root.bounds.size.height;
        if (a > bestA) { bestA = a; bestRoot = root; }
    }
    if (!bestRoot) {
        if (ov && !ov.hidden) { ov.hidden = YES; if (ov.player.timeControlStatus != AVPlayerTimeControlStatusPaused) [ov.player pause]; }
        return;
    }
    if (!ov) {
        ov = [[DIVideoView alloc] initWithFrame:bestRoot.bounds];
        objc_setAssociatedObject(win, &kWinVideoKey, ov, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (ov.superview != bestRoot) {
        [ov removeFromSuperview];
        [bestRoot insertSubview:ov atIndex:0]; // 垫到底层: 文字/图标都在视频之上
        bestRoot.clipsToBounds = YES;
        [ov loadVideo:materialPath()];
        DLog(@"挂载视频层 container=%@ frame=%@ 素材=%@", NSStringFromClass(bestRoot.class), NSStringFromCGRect(bestRoot.bounds), materialPath() ?: @"(无)");
    }
    // 尺寸策略: 无条件立即对齐; 动画期间的逐帧贴合由 DIVideoView 内部 displayLink 负责
    ov.frame = bestRoot.bounds;
    ov.layer.cornerRadius = bestRoot.layer.cornerRadius;
    if (bestRoot.subviews.firstObject != ov) [bestRoot sendSubviewToBack:ov];
    NSString *mp = materialPath();
    if (mp && ![mp isEqualToString:ov.currentPath]) [ov loadVideo:mp]; // 切换素材立即生效
    [ov syncVisibility];
}

static void updateHost(UIView *host) {
    if (!host || !viewHasToken(host, @"SAUIElementView")) return;
    attach(host);
    if (NSThread.isMainThread && host.window) updateSingleVideo(host.window); // 每次布局跟随岛尺寸
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
    enabled = pBool(@"enabled", NO);
    logEnabled = pBool(@"logging", NO);
    if (enabled != lastLoggedEnabled) { DLog(@"总开关状态: %@, 声音=永远关闭", enabled ? @"开" : @"关"); lastLoggedEnabled = enabled; }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]])
            dispatch_async(dispatch_get_main_queue(), ^{ updateSingleVideo(((UIWindowScene *)s).windows.firstObject); });
}

// 0.5 秒轮询: 岛展开才播放, 收回即暂停; 素材路径变化立即重载(单视频层统一管理)
static void visibilityTick(void) {
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
