//
//  DIPlayerEntry.mm
//  3.0: 播放器入口
//    · 全局悬浮球: 素材支持 png / gif(动图) / jpg, 可拖动, 位置记忆
//    · 点击悬浮球呼出播放面板: 素材大图 + 曲目信息 + 播放控制 + 进度条
//    · 播放完全接系统播放器: MediaRemote 私有接口(播放/暂停/上下曲/定位),
//      拿不到符号时回落到 MediaPlayer 的 MPMusicPlayerController
//
//  本文件只负责「悬浮球 + 面板 UI + 系统播放器桥」, 不碰岛上任何既有逻辑。
//

#import "DIPlayerEntry.h"
#import <ImageIO/ImageIO.h>
#import <MediaPlayer/MediaPlayer.h>
#import <dlfcn.h>

#define PB_DOMAIN    @"com.abgg332.driftisland"
#define PB_ASSET_DIR @"/var/mobile/灵动岛/播放器入口"
#define PB_LOG_FILE  @"/var/mobile/灵动岛/driftisland.log"

#pragma mark - 日志 / 偏好

static void PBLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void PBLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/灵动岛"
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        path = PB_LOG_FILE;
    });
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *out = [NSString stringWithFormat:@"[%@] [播放器] %@\n",
                     [df stringFromDate:[NSDate date]], line];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]; return; }
    @try {
        [h seekToEndOfFile];
        [h writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    } @catch (__unused NSException *e) {}
}

static id PBPref(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)PB_DOMAIN);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                       (__bridge CFStringRef)PB_DOMAIN));
}
static BOOL PBBool(NSString *key, BOOL def) {
    id v = PBPref(key);
    return v ? [v boolValue] : def;
}
static double PBScalar(NSString *key, double def) {
    id v = PBPref(key);
    return v ? [v doubleValue] : def;
}
static NSString *PBStr(NSString *key, NSString *def) {
    id v = PBPref(key);
    return [v isKindOfClass:NSString.class] ? (NSString *)v : def;
}

#pragma mark - 图片(含 GIF 解码)

static UIImage *PBResize(UIImage *img, CGFloat maxPx) {
    if (!img) return nil;
    CGSize s = img.size;
    CGFloat longest = MAX(s.width, s.height) * img.scale;
    if (longest <= maxPx || longest < 1) return img;
    CGFloat k = maxPx / longest;
    CGSize out = CGSizeMake(MAX(1.0, s.width * k), MAX(1.0, s.height * k));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:out format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, out.width, out.height)];
    }];
}

/* GIF 逐帧解码成 animatedImage —— UIImageView 自己循环播放, 不用挂定时器。
   每帧按 maxSide 降采样, 避免几十帧的大图把 SpringBoard 内存吃掉。 */
static UIImage *PBImageAtPath(NSString *path, CGFloat maxSide) {
    if (!path.length) return nil;
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"gif"]) {
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
        if (!src) return nil;
        size_t n = CGImageSourceGetCount(src);
        NSMutableArray<UIImage *> *frames = [NSMutableArray array];
        NSTimeInterval total = 0;
        for (size_t i = 0; i < n; i++) {
            CGImageRef cg = CGImageSourceCreateImageAtIndex(src, i, NULL);
            if (!cg) continue;
            UIImage *u = [UIImage imageWithCGImage:cg scale:UIScreen.mainScreen.scale
                                       orientation:UIImageOrientationUp];
            CGImageRelease(cg);
            u = PBResize(u, MAX(96.0, maxSide * 3.0));
            if (u) [frames addObject:u];
            NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, i, NULL));
            NSDictionary *gd = [props isKindOfClass:NSDictionary.class]
                ? props[(NSString *)kCGImagePropertyGIFDictionary] : nil;
            double d = 0;
            if ([gd isKindOfClass:NSDictionary.class]) {
                d = [gd[(NSString *)kCGImagePropertyGIFUnclampedDelayTime] doubleValue];
                if (d <= 0.011) d = [gd[(NSString *)kCGImagePropertyGIFDelayTime] doubleValue];
            }
            if (d <= 0.011) d = 0.1;
            total += d;
        }
        CFRelease(src);
        if (!frames.count) return nil;
        if (frames.count == 1) return frames.firstObject;
        return [UIImage animatedImageWithImages:frames duration:total];
    }
    return PBResize([UIImage imageWithContentsOfFile:path], MAX(96.0, maxSide * 3.0));
}

/* 没有素材时的占位球: 深色圆 + 白色音符 */
static UIImage *PBPlaceholder(CGFloat side) {
    if (side < 8) side = 8;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:0.13 alpha:0.96].CGColor);
        CGContextFillEllipseInRect(c, CGRectMake(0, 0, side, side));
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:side * 0.42
                                                            weight:UIImageSymbolWeightSemibold];
        UIImage *sym = [[UIImage systemImageNamed:@"music.note" withConfiguration:cfg]
                        imageWithTintColor:UIColor.whiteColor
                             renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGFloat s = side * 0.46;
        [sym drawInRect:CGRectMake((side - s) * 0.5, (side - s) * 0.5, s, s)];
    }];
}

#pragma mark - 系统播放器桥(MediaRemote)

enum { PB_CMD_PLAY = 0, PB_CMD_PAUSE = 1, PB_CMD_TOGGLE = 2,
       PB_CMD_STOP = 3, PB_CMD_NEXT = 4, PB_CMD_PREV = 5 };

static void  *pbMR = NULL;
static void (*pbSendCmd)(int, CFDictionaryRef) = NULL;
static void (*pbGetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef)) = NULL;
static void (*pbSetElapsed)(double) = NULL;
static BOOL  pbMRLoaded = NO;

static void PBLoadMR(void) {
    if (pbMRLoaded) return;
    pbMRLoaded = YES;
    pbMR = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!pbMR) { PBLog(@"MediaRemote 打不开, 播放键回落 MPMusicPlayerController"); return; }
    pbSendCmd    = (void (*)(int, CFDictionaryRef))dlsym(pbMR, "MRMediaRemoteSendCommand");
    pbGetInfo    = (void (*)(dispatch_queue_t, void (^)(CFDictionaryRef)))dlsym(pbMR, "MRMediaRemoteGetNowPlayingInfo");
    pbSetElapsed = (void (*)(double))dlsym(pbMR, "MRMediaRemoteSetElapsedTime");
    PBLog(@"MediaRemote 就绪: 命令=%d 信息=%d 定位=%d",
          pbSendCmd != NULL, pbGetInfo != NULL, pbSetElapsed != NULL);
}

/* Now Playing 字典的键就是 MediaRemote 导出的 CFString 常量(名字与符号一致);
   优先 dlsym 取真常量, 取不到退回同名字面量。 */
static NSString *PBMRKey(const char *sym) {
    static NSMutableDictionary<NSString *, NSString *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *name = [NSString stringWithUTF8String:sym];
    NSString *hit = cache[name];
    if (hit) return hit;
    NSString *val = nil;
    CFStringRef *p = pbMR ? (CFStringRef *)dlsym(pbMR, sym) : NULL;
    if (p && *p) val = (__bridge NSString *)*p;
    if (!val.length) val = name;
    cache[name] = val;
    return val;
}
static NSString *PBKeyTitle(void)    { return PBMRKey("kMRMediaRemoteNowPlayingInfoTitle"); }
static NSString *PBKeyArtist(void)   { return PBMRKey("kMRMediaRemoteNowPlayingInfoArtist"); }
static NSString *PBKeyDuration(void) { return PBMRKey("kMRMediaRemoteNowPlayingInfoDuration"); }
static NSString *PBKeyElapsed(void)  { return PBMRKey("kMRMediaRemoteNowPlayingInfoElapsedTime"); }
static NSString *PBKeyRate(void)     { return PBMRKey("kMRMediaRemoteNowPlayingInfoPlaybackRate"); }
static NSString *PBKeyArtwork(void)  { return PBMRKey("kMRMediaRemoteNowPlayingInfoArtworkData"); }

static void PBSendCommand(int cmd) {
    if (pbSendCmd) { pbSendCmd(cmd, NULL); return; }
    @try {
        MPMusicPlayerController *mp = [MPMusicPlayerController systemMusicPlayer];
        if (cmd == PB_CMD_PLAY || cmd == PB_CMD_TOGGLE) [mp play];
        else if (cmd == PB_CMD_PAUSE) [mp pause];
        else if (cmd == PB_CMD_NEXT) [mp skipToNextItem];
        else if (cmd == PB_CMD_PREV) [mp skipToPreviousItem];
    } @catch (__unused NSException *e) {}
}

#pragma mark - 全局状态 / 前置声明

@class PBWindow;

static PBWindow *pbWin = nil;
static UIView *pbBall = nil;
static UIImageView *pbBallIV = nil;
static UIImage *pbBallImg = nil;
static NSString *pbBallPath = nil;
static CGFloat pbBallSize = 64;
static BOOL pbRetrying = NO;
static int  pbRetryCount = 0;

static UIView *pbDim = nil;
static UIView *pbCard = nil;
static UIImageView *pbCover = nil;
static UILabel *pbTitle = nil, *pbArtist = nil, *pbPos = nil, *pbDur = nil;
static UISlider *pbSlider = nil;
static UIButton *pbPlayBtn = nil;
static NSTimer *pbTimer = nil;
static BOOL pbDragging = NO;
static double pbDuration = 0, pbElapsed = 0, pbRate = 0;

static CGPoint PBClampCenter(CGPoint c, CGSize size);
static void PBSaveBallPosition(CGPoint c);
static void PBOpenPanel(void);
static void PBClosePanel(void);
static void PBRefresh(void);
static void PBBuildBall(void);
static void PBDestroy(void);
static BOOL PBEnsureWindow(void);
static void PBRetryBuild(void);

#pragma mark - 窗口(空白处穿透)

@interface PBWindow : UIWindow
@end
@implementation PBWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

#pragma mark - 悬浮球手势 / 面板动作

@interface PBBallController : NSObject
- (void)pan:(UIPanGestureRecognizer *)g;
- (void)tap:(UITapGestureRecognizer *)g;
- (void)dimTap:(UITapGestureRecognizer *)g;
- (void)closeTap:(UIButton *)b;
- (void)prevTap;
- (void)nextTap;
- (void)playTap;
- (void)sliderDown:(UISlider *)s;
- (void)sliderChanging:(UISlider *)s;
- (void)sliderUp:(UISlider *)s;
@end

@implementation PBBallController
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    if (!v || !pbWin) return;
    CGPoint t = [g translationInView:pbWin];
    [g setTranslation:CGPointZero inView:pbWin];
    v.center = PBClampCenter(CGPointMake(v.center.x + t.x, v.center.y + t.y), v.bounds.size);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled)
        PBSaveBallPosition(v.center);
}
- (void)tap:(UITapGestureRecognizer *)g { PBOpenPanel(); }
- (void)dimTap:(UITapGestureRecognizer *)g { PBClosePanel(); }
- (void)closeTap:(UIButton *)b { PBClosePanel(); }
- (void)prevTap { PBSendCommand(PB_CMD_PREV); }
- (void)nextTap { PBSendCommand(PB_CMD_NEXT); }
- (void)playTap {
    if (pbRate > 0.01) { PBSendCommand(PB_CMD_PAUSE); return; }
    BOOL hadSession = (pbDuration > 0.5);
    PBSendCommand(PB_CMD_PLAY);
    /* 没有任何正在播放的会话时, MediaRemote 的 play 是空转的 ——
       回落到系统音乐 App 的播放器, 保证"点一下就真的开始放" */
    if (!hadSession) {
        @try { [[MPMusicPlayerController systemMusicPlayer] play]; } @catch (__unused NSException *e) {}
    }
}
- (void)sliderDown:(UISlider *)s { pbDragging = YES; }
- (void)sliderChanging:(UISlider *)s {
    if (pbPos) pbPos.text = ([NSString stringWithFormat:@"%d:%02d",
                             (int)(s.value * pbDuration) / 60, (int)(s.value * pbDuration) % 60]);
}
- (void)sliderUp:(UISlider *)s {
    pbDragging = NO;
    double sec = s.value * pbDuration;
    if (pbSetElapsed) pbSetElapsed(sec);
    PBRefresh();
}
@end

static PBBallController *pbCtrl = nil;

#pragma mark - 几何 / 素材

static CGPoint PBClampCenter(CGPoint c, CGSize size) {
    if (!pbWin) return c;
    UIEdgeInsets in = pbWin.safeAreaInsets;
    CGSize ws = pbWin.bounds.size;
    CGFloat hw = size.width * 0.5, hh = size.height * 0.5;
    CGFloat minX = in.left + hw + 3.0, maxX = ws.width - in.right - hw - 3.0;
    CGFloat minY = in.top + hh + 3.0,  maxY = ws.height - in.bottom - hh - 3.0;
    if (maxX < minX) maxX = minX;
    if (maxY < minY) maxY = minY;
    c.x = MIN(MAX(c.x, minX), maxX);
    c.y = MIN(MAX(c.y, minY), maxY);
    return c;
}

static void PBSaveBallPosition(CGPoint c) {
    if (!pbWin) return;
    CGSize ws = pbWin.bounds.size;
    if (ws.width < 1 || ws.height < 1) return;
    CFPreferencesSetAppValue(CFSTR("pbFloatX"), (__bridge CFPropertyListRef)@(c.x / ws.width),
                             (__bridge CFStringRef)PB_DOMAIN);
    CFPreferencesSetAppValue(CFSTR("pbFloatY"), (__bridge CFPropertyListRef)@(c.y / ws.height),
                             (__bridge CFStringRef)PB_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)PB_DOMAIN);
}

static NSString *PBResolveAssetPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *sel = PBStr(@"pbFloatAsset", nil);
    if (sel.length) {
        if ([sel hasPrefix:@"/"] && [fm fileExistsAtPath:sel]) return sel;
        NSString *p = [PB_ASSET_DIR stringByAppendingPathComponent:sel];
        if ([fm fileExistsAtPath:p]) return p;
    }
    NSArray *names = [fm contentsOfDirectoryAtPath:PB_ASSET_DIR error:NULL];
    NSSet *ok = [NSSet setWithObjects:@"png", @"gif", @"jpg", @"jpeg", @"webp", @"heic", nil];
    for (NSString *n in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        if ([ok containsObject:n.pathExtension.lowercaseString])
            return [PB_ASSET_DIR stringByAppendingPathComponent:n];
    }
    return nil;
}

static void PBApplyAsset(void) {
    if (!pbBallIV) return;
    NSString *p = PBResolveAssetPath();
    if (pbBallImg && [p isEqualToString:pbBallPath]) return;
    pbBallPath = p;
    UIImage *img = p ? PBImageAtPath(p, pbBallSize) : nil;
    pbBallImg = img;
    pbBallIV.image = img ?: PBPlaceholder(pbBallSize);
    PBLog(@"悬浮球素材: %@", p.length ? p.lastPathComponent : @"(无, 用占位音符)");
}

#pragma mark - 播放面板

static UILabel *PBMakeLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = font;
    l.textColor = color;
    l.textAlignment = NSTextAlignmentCenter;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

static UIButton *PBMakeIcon(NSString *name, CGFloat pt, UIColor *tint) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:name] forState:UIControlStateNormal];
    [b setPreferredSymbolConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightSemibold]
                              forImageInState:UIControlStateNormal];
    b.tintColor = tint;
    return b;
}

static NSString *PBTimeText(double s) {
    if (!isfinite(s) || s < 0) s = 0;
    int t = (int)llround(s);
    return [NSString stringWithFormat:@"%d:%02d", t / 60, t % 60];
}

static void PBUpdatePlayIcon(void) {
    if (!pbPlayBtn) return;
    NSString *n = (pbRate > 0.01) ? @"pause.fill" : @"play.fill";
    [pbPlayBtn setImage:[UIImage systemImageNamed:n] forState:UIControlStateNormal];
}

static void PBRefresh(void) {
    if (!pbGetInfo) { PBUpdatePlayIcon(); return; }
    pbGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        NSDictionary *d = info ? CFBridgingRelease(info) : nil;
        if (![d isKindOfClass:NSDictionary.class]) d = nil;
        NSString *title  = [d[PBKeyTitle()] isKindOfClass:NSString.class] ? d[PBKeyTitle()] : nil;
        NSString *artist = [d[PBKeyArtist()] isKindOfClass:NSString.class] ? d[PBKeyArtist()] : nil;
        pbDuration = [d[PBKeyDuration()] doubleValue];
        pbElapsed  = [d[PBKeyElapsed()] doubleValue];
        pbRate     = [d[PBKeyRate()] doubleValue];
        if (pbTitle)  pbTitle.text  = title.length ? title : @"未在播放";
        if (pbArtist) pbArtist.text = artist.length ? artist
                                     : (title.length ? @"" : @"点播放键接入系统播放器");
        if (pbSlider && !pbDragging)
            pbSlider.value = (pbDuration > 0.5)
                ? (float)MIN(1.0, MAX(0.0, pbElapsed / pbDuration)) : 0.0f;
        if (pbPos) pbPos.text = PBTimeText(pbElapsed);
        if (pbDur) pbDur.text = PBTimeText(pbDuration);
        /* 只有没素材时才借用系统封面, 有素材始终保持用户自己的图 */
        if (pbCover && !pbBallImg) {
            NSData *art = d[PBKeyArtwork()];
            if ([art isKindOfClass:NSData.class] && art.length) {
                UIImage *im = [UIImage imageWithData:art];
                if (im && pbCover.image != im) pbCover.image = im;
            }
        }
        PBUpdatePlayIcon();
    });
}

static void PBBuildPanel(void) {
    if (pbCard || !pbWin) return;
    if (!pbCtrl) pbCtrl = [PBBallController new];
    CGRect wb = pbWin.bounds;
    CGFloat cw = MIN(wb.size.width - 56.0, 340.0);
    CGFloat cover = cw - 72.0;
    CGFloat ch = 56.0 + cover + 16 + 24 + 20 + 30 + 28 + 18 + 74;

    UIView *dim = [[UIView alloc] initWithFrame:wb];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.42];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:pbCtrl
                                                                     action:@selector(dimTap:)]];
    [pbWin addSubview:dim];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((wb.size.width - cw) * 0.5,
                                                           (wb.size.height - ch) * 0.5, cw, ch)];
    card.layer.cornerRadius = 28;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    card.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.96];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
                                 [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blur.frame = card.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    [card addSubview:blur];

    UILabel *head = PBMakeLabel(@"播放器", [UIFont systemFontOfSize:13 weight:UIFontWeightMedium],
                                [UIColor colorWithWhite:1 alpha:0.55]);
    head.frame = CGRectMake(0, 20, cw, 18);
    [card addSubview:head];

    UIButton *close = PBMakeIcon(@"xmark", 15, [UIColor colorWithWhite:1 alpha:0.7]);
    close.frame = CGRectMake(cw - 44, 10, 36, 36);
    [close addTarget:pbCtrl action:@selector(closeTap:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    UIImageView *coverV = [[UIImageView alloc] initWithFrame:CGRectMake(36, 56, cover, cover)];
    coverV.contentMode = UIViewContentModeScaleAspectFill;
    coverV.clipsToBounds = YES;
    coverV.layer.cornerRadius = 22;
    coverV.layer.cornerCurve = kCACornerCurveContinuous;
    coverV.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    coverV.userInteractionEnabled = NO;
    coverV.image = pbBallImg ?: PBPlaceholder(cover);
    [card addSubview:coverV];

    UILabel *t = PBMakeLabel(@"未在播放", [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold],
                             UIColor.whiteColor);
    t.frame = CGRectMake(24, CGRectGetMaxY(coverV.frame) + 16, cw - 48, 24);
    [card addSubview:t];

    UILabel *a = PBMakeLabel(@"点播放键接入系统播放器",
                             [UIFont systemFontOfSize:13 weight:UIFontWeightRegular],
                             [UIColor colorWithWhite:1 alpha:0.55]);
    a.frame = CGRectMake(24, CGRectGetMaxY(t.frame) + 4, cw - 48, 20);
    [card addSubview:a];

    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(28, CGRectGetMaxY(a.frame) + 22,
                                                              cw - 56, 28)];
    sl.minimumValue = 0; sl.maximumValue = 1; sl.value = 0;
    sl.minimumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.9];
    sl.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.22];
    [sl addTarget:pbCtrl action:@selector(sliderDown:) forControlEvents:UIControlEventTouchDown];
    [sl addTarget:pbCtrl action:@selector(sliderChanging:) forControlEvents:UIControlEventValueChanged];
    [sl addTarget:pbCtrl action:@selector(sliderUp:) forControlEvents:
        UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [card addSubview:sl];

    UILabel *p = PBMakeLabel(@"0:00", [UIFont monospacedDigitSystemFontOfSize:11
                                                                    weight:UIFontWeightRegular],
                             [UIColor colorWithWhite:1 alpha:0.5]);
    p.textAlignment = NSTextAlignmentLeft;
    p.frame = CGRectMake(28, CGRectGetMaxY(sl.frame), 60, 16);
    [card addSubview:p];

    UILabel *dm = PBMakeLabel(@"0:00", [UIFont monospacedDigitSystemFontOfSize:11
                                                                     weight:UIFontWeightRegular],
                              [UIColor colorWithWhite:1 alpha:0.5]);
    dm.textAlignment = NSTextAlignmentRight;
    dm.frame = CGRectMake(cw - 88, CGRectGetMaxY(sl.frame), 60, 16);
    [card addSubview:dm];

    CGFloat by = ch - 66.0;
    UIButton *prev = PBMakeIcon(@"backward.fill", 24, UIColor.whiteColor);
    prev.frame = CGRectMake(cw * 0.5 - 104, by, 56, 52);
    [prev addTarget:pbCtrl action:@selector(prevTap) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:prev];

    UIButton *play = [UIButton buttonWithType:UIButtonTypeSystem];
    play.frame = CGRectMake(cw * 0.5 - 30, by - 4, 60, 60);
    play.backgroundColor = UIColor.whiteColor;
    play.tintColor = UIColor.blackColor;
    play.layer.cornerRadius = 30;
    [play setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
    [play setPreferredSymbolConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightBold]
                                  forImageInState:UIControlStateNormal];
    [play addTarget:pbCtrl action:@selector(playTap) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:play];

    UIButton *next = PBMakeIcon(@"forward.fill", 24, UIColor.whiteColor);
    next.frame = CGRectMake(cw * 0.5 + 48, by, 56, 52);
    [next addTarget:pbCtrl action:@selector(nextTap) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:next];

    [pbWin addSubview:card];

    pbDim = dim; pbCard = card; pbCover = coverV;
    pbTitle = t; pbArtist = a; pbPos = p; pbDur = dm;
    pbSlider = sl; pbPlayBtn = play;

    PBRefresh();
    if (pbTimer) [pbTimer invalidate];
    pbTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *tm) {
        PBRefresh();
    }];
}

static void PBOpenPanel(void) {
    if (!pbWin) return;
    PBLoadMR();
    if (pbCard) return;
    PBBuildPanel();
    if (!pbCard) return;
    pbDim.alpha = 0;
    pbCard.alpha = 0;
    pbCard.transform = CGAffineTransformMakeScale(0.88, 0.88);
    [UIView animateWithDuration:0.26 delay:0 usingSpringWithDamping:0.84
          initialSpringVelocity:0.4 options:0 animations:^{
        pbDim.alpha = 1;
        pbCard.alpha = 1;
        pbCard.transform = CGAffineTransformIdentity;
    } completion:nil];
    PBLog(@"播放面板打开");
}

static void PBClosePanel(void) {
    if (pbTimer) { [pbTimer invalidate]; pbTimer = nil; }
    UIView *dim = pbDim, *card = pbCard;
    pbDim = nil; pbCard = nil; pbCover = nil;
    pbTitle = nil; pbArtist = nil; pbPos = nil; pbDur = nil;
    pbSlider = nil; pbPlayBtn = nil; pbDragging = NO;
    if (!dim && !card) return;
    [UIView animateWithDuration:0.18 animations:^{
        dim.alpha = 0;
        card.alpha = 0;
        card.transform = CGAffineTransformMakeScale(0.92, 0.92);
    } completion:^(BOOL finished) {
        [dim removeFromSuperview];
        [card removeFromSuperview];
    }];
}

#pragma mark - 窗口 / 悬浮球

static BOOL PBEnsureWindow(void) {
    if (pbWin) return YES;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class]
            && s.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)s;
            break;
        }
    }
    if (!scene) return NO;
    PBWindow *w = [[PBWindow alloc] initWithWindowScene:scene];
    CGRect sb = UIScreen.mainScreen.bounds;
    w.frame = (sb.size.width > 1 && sb.size.height > 1) ? sb : scene.coordinateSpace.bounds;
    w.windowLevel = UIWindowLevelStatusBar + 10;
    w.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = vc;
    w.hidden = NO;
    pbWin = w;
    return YES;
}

static void PBBuildBall(void) {
    if (!pbWin) return;
    CGFloat size = PBScalar(@"pbFloatSize", 64);
    if (size < 24) size = 24;
    if (size > 160) size = 160;
    pbBallSize = size;

    if (!pbBall) {
        if (!pbCtrl) pbCtrl = [PBBallController new];
        UIView *b = [[UIView alloc] initWithFrame:CGRectZero];
        b.backgroundColor = UIColor.clearColor;
        b.layer.shadowColor = UIColor.blackColor.CGColor;
        b.layer.shadowOpacity = 0.30;
        b.layer.shadowRadius = 9;
        b.layer.shadowOffset = CGSizeMake(0, 3);

        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectZero];
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.userInteractionEnabled = NO;
        [b addSubview:iv];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:pbCtrl
                                                                            action:@selector(pan:)];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:pbCtrl
                                                                             action:@selector(tap:)];
        [tap requireGestureRecognizerToFail:pan];
        [b addGestureRecognizer:pan];
        [b addGestureRecognizer:tap];
        [pbWin addSubview:b];
        pbBall = b;
        pbBallIV = iv;
    }

    CGRect wb = pbWin.bounds;
    CGFloat xr = PBScalar(@"pbFloatX", 0.88);
    CGFloat yr = PBScalar(@"pbFloatY", 0.62);
    if (xr < 0 || xr > 1) xr = 0.88;
    if (yr < 0 || yr > 1) yr = 0.62;

    CGFloat r = PBBool(@"pbFloatRound", YES) ? size * 0.5 : size * 0.24;
    pbBall.bounds = CGRectMake(0, 0, size, size);
    pbBall.center = PBClampCenter(CGPointMake(wb.size.width * xr, wb.size.height * yr),
                                  CGSizeMake(size, size));
    pbBallIV.frame = pbBall.bounds;
    pbBallIV.layer.cornerRadius = r;
    pbBall.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:pbBall.bounds
                                                        cornerRadius:r].CGPath;
    pbBall.hidden = NO;
    PBApplyAsset();
}

static void PBDestroy(void) {
    PBClosePanel();
    pbRetrying = NO; pbRetryCount = 0;
    if (pbBall) {
        [pbBall removeFromSuperview];
        pbBall = nil; pbBallIV = nil; pbBallImg = nil; pbBallPath = nil;
    }
    if (pbWin) { pbWin.hidden = YES; pbWin = nil; }
}

/* scene 还没就绪时每秒重试一次 —— 用函数递归, 不引 block 自捕获 */
static void PBRetryBuild(void) {
    @try {
        if (!PBBool(@"pbFloatOn", NO)) { pbRetrying = NO; pbRetryCount = 0; return; }
        if (PBEnsureWindow()) {
            pbRetrying = NO; pbRetryCount = 0;
            PBBuildBall();
            return;
        }
        if (++pbRetryCount > 8) {
            pbRetrying = NO; pbRetryCount = 0;
            PBLog(@"scene 一直没就绪, 放弃挂载悬浮球");
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ PBRetryBuild(); });
    } @catch (NSException *e) {
        pbRetrying = NO; pbRetryCount = 0;
        PBLog(@"重试异常: %@", e.reason);
    }
}

#pragma mark - 对外接口

void diPlayerEntryReload(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!PBBool(@"pbFloatOn", NO)) {
                if (pbBall || pbWin) { PBDestroy(); PBLog(@"播放器入口关闭, 移除悬浮球"); }
                return;
            }
            PBLoadMR();
            if (PBEnsureWindow()) { PBBuildBall(); return; }
            /* SpringBoard 刚起来时可能还没有活跃 scene —— 1 秒后重试, 最多 8 次 */
            if (!pbRetrying) { pbRetrying = YES; pbRetryCount = 0; PBRetryBuild(); }
        } @catch (NSException *e) {
            PBLog(@"reload 异常: %@ — %@", e.name, e.reason);
        }
    });
}
