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
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

#define PB_DOMAIN    @"com.abgg332.driftisland"
#define PB_ASSET_DIR @"/var/mobile/灵动岛/播放器入口"
#define PB_LOG_FILE  @"/var/mobile/灵动岛/driftisland.log"
#define PB_LIST_DIR  @"/var/mobile/灵动岛/播放器入口"

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

#pragma mark - 酷我音源(公开接口实测可用)

/* 搜索: http://search.kuwo.cn/r.s  返回单引号 JSON(键值都是 ' 包裹), 内容转双引号后可解析。
   播放: http://antiserver.kuwo.cn/anti.s?...&rid=MUSIC_<id>&type=convert_url
         302 到真实 mp3, AVPlayer 会自动跟随。 */

static NSArray<NSDictionary *> *PBKuwoParseSearch(NSString *text) {
    if (!text.length) return nil;
    NSString *j = [text stringByReplacingOccurrencesOfString:@"'" withString:@"\""];
    NSData *d = [j dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    NSArray *list = [root isKindOfClass:NSDictionary.class] ? root[@"abslist"] : nil;
    if (![list isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *s in list) {
        if (![s isKindOfClass:NSDictionary.class]) continue;
        NSString *rid = s[@"MUSICRID"];
        NSString *name = s[@"SONGNAME"];
        NSString *artist = s[@"ARTIST"];
        if (![rid isKindOfClass:NSString.class] || rid.length < 7) continue;
        rid = [rid stringByReplacingOccurrencesOfString:@"MUSIC_" withString:@""];
        /* 歌名里的 &nbsp; 还原成空格 */
        name = [name stringByReplacingOccurrencesOfString:@"&nbsp;" withString:@" "];
        artist = [artist stringByReplacingOccurrencesOfString:@"&nbsp;" withString:@" "];
        [out addObject:@{ @"rid": rid ?: @"",
                          @"name": name.length ? name : @"未知歌曲",
                          @"artist": artist.length ? artist : @"未知歌手",
                          @"dur": @([s[@"DURATION"] doubleValue]) }];
    }
    return out.count ? out : nil;
}

static void PBKuwoSearch(NSString *kw, void (^done)(NSArray<NSDictionary *> *items, NSString *err)) {
    if (!kw.length) { done(nil, @"请输入关键词"); return; }
    NSString *enc = [kw stringByAddingPercentEncodingWithAllowedCharacters:
                        [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *url = [NSString stringWithFormat:
        @"http://search.kuwo.cn/r.s?all=%@&ft=music&rformat=json&encoding=utf8&rpcid=65&pn=0&rn=30",
        enc ?: kw];
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:url]
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:12.0];
    [[NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data.length) { done(nil, @"搜索失败(网络)"); return; }
            NSArray *items = PBKuwoParseSearch([[NSString alloc] initWithData:data
                                                              encoding:NSUTF8StringEncoding]);
            done(items, items ? nil : @"没有找到歌曲");
        });
    }] resume];
}

static NSURL *PBKuwoStreamURL(NSString *rid) {
    return [NSURL URLWithString:[NSString stringWithFormat:
        @"http://antiserver.kuwo.cn/anti.s?format=mp3&rid=MUSIC_%@&type=convert_url&response=res", rid]];
}

/* 本地列表存储: 最近播放 / 我喜欢 */
static NSString *PBListPath(BOOL likes) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:PB_LIST_DIR
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    return [PB_LIST_DIR stringByAppendingPathComponent:likes ? @"likes.plist" : @"recent.plist"];
}
static NSMutableArray *PBLoadList(BOOL likes) {
    NSArray *a = [NSArray arrayWithContentsOfFile:PBListPath(likes)];
    return [a isKindOfClass:NSArray.class] ? [a mutableCopy] : [NSMutableArray array];
}
static void PBSaveList(BOOL likes, NSArray *a) {
    [a writeToFile:PBListPath(likes) atomically:YES];
}
static void PBAddRecent(NSDictionary *song) {
    NSMutableArray *a = PBLoadList(NO);
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *s in a)
        if ([s isKindOfClass:NSDictionary.class] && ![s[@"rid"] isEqualToString:song[@"rid"]])
            [out addObject:s];
    [out insertObject:song atIndex:0];
    while (out.count > 100) [out removeLastObject];
    PBSaveList(NO, out);
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

/* 3.0.1: 在线播放(酷我)与面板多页 */
static AVPlayer *pbPlayer = nil;               /* 非 nil = 在线播放模式 */
static NSMutableDictionary *pbOnlineNow = nil;  /* 当前在线歌曲 {rid,name,artist,dur} */
static NSMutableArray *pbSearchResults = nil;
static NSMutableArray *pbListItems = nil;       /* 当前列表页(喜欢/最近)显示的数据 */
static BOOL pbListIsLikes = NO;
static UITableView *pbList = nil;
static UILabel *pbListEmpty = nil;
static UITextField *pbSearchField = nil;
static NSArray<NSString *> *pbTabNames = nil;
static NSMutableArray<UIButton *> *pbTabBtns = nil;
static NSInteger pbTabNow = 0;
static UIView *pbPageNow = nil, *pbPageSearch = nil, *pbPageList = nil;
static BOOL pbSearching = NO;
static void PBShowTab(NSInteger idx);
static void PBPlaySong(NSDictionary *song);
static void PBOnlineSkip(BOOL next);

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

@interface PBBallController : NSObject <UITableViewDataSource, UITableViewDelegate>
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
- (void)tabTap:(UIButton *)b;
- (void)searchGo:(UIButton *)b;
- (void)searchField:(UITextField *)f;
- (void)openKuwo:(UIButton *)b;
- (void)openQQ:(UIButton *)b;
- (void)rowDel:(UIButton *)b;
@end

static PBBallController *pbCtrl = nil;

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
- (void)prevTap {
    if (pbPlayer) { PBOnlineSkip(NO); return; }
    PBSendCommand(PB_CMD_PREV);
}
- (void)nextTap {
    if (pbPlayer) { PBOnlineSkip(YES); return; }
    PBSendCommand(PB_CMD_NEXT);
}
- (void)playTap {
    /* 3.0.1: 修安全模式 —— SpringBoard 进程里绝不调 MPMusicPlayerController
       (内部依赖音乐 App 的 XPC 结构, SB 里一调就崩)。在线播放模式控制 AVPlayer,
       否则一律走 MediaRemote 命令(408/409 实锤 SB 里可用)。 */
    if (pbPlayer) {
        @try {
            if (pbPlayer.rate > 0.01) [pbPlayer pause];
            else [pbPlayer play];
        } @catch (__unused NSException *e) {}
        return;
    }
    PBSendCommand(pbRate > 0.01 ? PB_CMD_PAUSE : PB_CMD_PLAY);
}
- (void)sliderDown:(UISlider *)s { pbDragging = YES; }
- (void)sliderChanging:(UISlider *)s {
    double dur = pbPlayer ? CMTimeGetSeconds(pbPlayer.currentItem.duration) : pbDuration;
    if (pbPos) pbPos.text = ([NSString stringWithFormat:@"%d:%02d",
                             (int)(s.value * dur) / 60, (int)(s.value * dur) % 60]);
}
- (void)sliderUp:(UISlider *)s {
    pbDragging = NO;
    if (pbPlayer) {
        @try {
            double dur = CMTimeGetSeconds(pbPlayer.currentItem.duration);
            if (dur > 0.5)
                [pbPlayer seekToTime:CMTimeMakeWithSeconds(s.value * dur, 600)];
        } @catch (__unused NSException *e) {}
        return;
    }
    double sec = s.value * pbDuration;
    if (pbSetElapsed) pbSetElapsed(sec);
    PBRefresh();
}
- (void)tabTap:(UIButton *)b { PBShowTab(b.tag); }
- (void)searchGo:(UIButton *)b { [self doSearch]; }
- (void)searchField:(UITextField *)f { [self doSearch]; }
- (void)doSearch {
    if (pbSearching) return;
    NSString *kw = pbSearchField.text;
    if (!kw.length) return;
    pbSearching = YES;
    if (pbListEmpty) pbListEmpty.text = @"搜索中…";
    PBKuwoSearch(kw, ^(NSArray<NSDictionary *> *items, NSString *err) {
        pbSearching = NO;
        if (!items) {
            pbSearchResults = nil;
            if (pbListEmpty) pbListEmpty.text = err ?: @"没有找到歌曲";
            if (pbList) [pbList reloadData];
            return;
        }
        pbSearchResults = [items mutableCopy];
        pbListIsLikes = NO;
        if (pbListEmpty) pbListEmpty.text = @"";
        if (pbList) [pbList reloadData];
    });
}
/* 深链跳转: QQ 音乐无公开接口, 打开对应 App */
- (void)openURLStr:(NSString *)scheme fallback:(NSString *)fb {
    @try {
        NSURL *u = [NSURL URLWithString:scheme];
        void (^blk)(BOOL) = ^(BOOL ok){ if (!ok && fb) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:fb]
                                               options:@{} completionHandler:nil];
        }};
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:blk];
        PBLog(@"深链跳转: %@", scheme);
    } @catch (__unused NSException *e) {}
}
- (void)openKuwo:(UIButton *)b { [self openURLStr:@"kuwo://" fallback:nil]; }
- (void)openQQ:(UIButton *)b {
    NSString *kw = pbSearchField.text ?: @"";
    if (kw.length)
        [self openURLStr:[NSString stringWithFormat:@"qqmusic://qq.com/ui/search?keyword=%@", kw]
                fallback:@"qqmusic://"];
    else
        [self openURLStr:@"qqmusic://" fallback:nil];
}
- (void)rowDel:(UIButton *)b {
    NSInteger row = b.tag;
    if (row < 0 || row >= (NSInteger)pbListItems.count) return;
    [pbListItems removeObjectAtIndex:row];
    PBSaveList(pbListIsLikes, pbListItems);
    if (pbList) [pbList reloadData];
}
- (void)rowLike:(UIButton *)b {
    NSInteger row = b.tag;
    if (row < 0 || row >= (NSInteger)pbListItems.count) return;
    NSDictionary *song = pbListItems[row];
    NSMutableArray *likes = PBLoadList(YES);
    for (NSDictionary *s in likes)
        if ([s isKindOfClass:NSDictionary.class] && [s[@"rid"] isEqualToString:song[@"rid"]]) {
            PBLog(@"已收藏过: %@", song[@"name"]);
            return;
        }
    [likes insertObject:song atIndex:0];
    PBSaveList(YES, likes);
    PBLog(@"已收藏: %@ - %@", song[@"name"], song[@"artist"]);
}

/* ---- 表格: 搜索结果 / 喜欢 / 最近播放 ---- */
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)(pbListItems ? pbListItems.count : 0);
}
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return 46; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *idv = @"pbrow";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:idv];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:idv];
        c.backgroundColor = UIColor.clearColor;
        c.textLabel.textColor = UIColor.whiteColor;
        c.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        c.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.5];
        c.detailTextLabel.font = [UIFont systemFontOfSize:12];
        c.imageView.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
        UIButton *like = [UIButton buttonWithType:UIButtonTypeSystem];
        like.frame = CGRectMake(0, 0, 40, 40);
        [like setImage:[UIImage systemImageNamed:@"heart"] forState:UIControlStateNormal];
        like.tintColor = [UIColor colorWithWhite:1 alpha:0.55];
        [like addTarget:pbCtrl action:@selector(rowLike:) forControlEvents:UIControlEventTouchUpInside];
        UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
        del.frame = CGRectMake(0, 0, 40, 40);
        [del setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
        del.tintColor = [UIColor colorWithWhite:1 alpha:0.4];
        [del addTarget:pbCtrl action:@selector(rowDel:) forControlEvents:UIControlEventTouchUpInside];
        c.accessoryView = like;   /* 初始挂收藏按钮, 行内按 tab 切换 */
        objc_setAssociatedObject(c, "pbLikeBtn", like, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(c, "pbDelBtn", del, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSDictionary *s = (ip.row < (NSInteger)pbListItems.count) ? pbListItems[ip.row] : nil;
    c.textLabel.text = s[@"name"];
    c.detailTextLabel.text = s[@"artist"];
    c.imageView.image = [UIImage systemImageNamed:pbListIsLikes ? @"heart.fill" : @"music.note"];
    UIButton *like = objc_getAssociatedObject(c, "pbLikeBtn");
    UIButton *del  = objc_getAssociatedObject(c, "pbDelBtn");
    c.accessoryView = pbListIsLikes ? del : like;
    if (c.accessoryView) c.accessoryView.tag = ip.row;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:NO];
    if (ip.row >= (NSInteger)pbListItems.count) return;
    PBPlaySong(pbListItems[ip.row]);
}
@end

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
    BOOL playing = pbPlayer ? (pbPlayer.rate > 0.01) : (pbRate > 0.01);
    NSString *n = playing ? @"pause.fill" : @"play.fill";
    [pbPlayBtn setImage:[UIImage systemImageNamed:n] forState:UIControlStateNormal];
}

static void PBRefresh(void) {
    if (pbPlayer) {
        /* 在线播放(酷我)模式: 信息/进度都来自 AVPlayer 自己 */
        @try {
            double dur = CMTimeGetSeconds(pbPlayer.currentItem.duration);
            double cur = CMTimeGetSeconds(pbPlayer.currentTime);
            if (pbTitle)  pbTitle.text  = pbOnlineNow[@"name"] ?: @"在线播放";
            if (pbArtist) pbArtist.text = pbOnlineNow[@"artist"] ?: @"";
            if (pbSlider && !pbDragging && dur > 0.5)
                pbSlider.value = (float)MIN(1.0, MAX(0.0, cur / dur));
            if (pbPos) pbPos.text = PBTimeText(cur);
            if (pbDur) pbDur.text = PBTimeText(dur);
        } @catch (__unused NSException *e) {}
        PBUpdatePlayIcon();
        return;
    }
    if (!pbGetInfo) { PBUpdatePlayIcon(); return; }
    pbGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        NSDictionary *d = info ? CFBridgingRelease(info) : nil;
        if (![d isKindOfClass:NSDictionary.class]) d = nil;
        NSString *title  = [d[PBKeyTitle()] isKindOfClass:NSString.class] ? d[PBKeyTitle()] : nil;
        NSString *artist = [d[PBKeyArtist()] isKindOfClass:NSString.class] ? d[PBKeyArtist()] : nil;
        pbDuration = [d[PBKeyDuration()] doubleValue];
        pbElapsed  = [d[PBKeyElapsed()] doubleValue];
        pbRate     = [d[PBKeyRate()] doubleValue];
        if (pbPlayer) return;   /* 回调慢一拍, 在线模式已切走就别覆盖 */
        if (pbTitle)  pbTitle.text  = title.length ? title : @"未在播放";
        if (pbArtist) pbArtist.text = artist.length ? artist
                                     : (title.length ? @"" : @"点播放键或搜索歌曲");
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

/* 在线播放的上一首/下一首: 在"最近播放"里按当前曲目索引取邻曲 */
static void PBOnlineSkip(BOOL next) {
    if (!pbOnlineNow) return;
    NSMutableArray *a = PBLoadList(NO);
    NSInteger idx = -1;
    for (NSInteger i = 0; i < (NSInteger)a.count; i++)
        if ([a[i][@"rid"] isEqualToString:pbOnlineNow[@"rid"]]) { idx = i; break; }
    if (idx < 0) { idx = 0; if (!a.count) return; }
    NSInteger want = next ? idx + 1 : idx - 1;
    if (want < 0) want = (NSInteger)a.count - 1;
    if (want >= (NSInteger)a.count) want = 0;
    if (want != idx) PBPlaySong(a[want]);
}

static void PBPlaySong(NSDictionary *song) {
    if (!song || !pbWin) return;
    NSString *rid = song[@"rid"];
    if (!rid.length) return;
    @try {
        AVAudioSession *as = AVAudioSession.sharedInstance;
        [as setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault
                options:0 error:NULL];
        [as setActive:YES withOptions:0 error:NULL];
        [pbPlayer pause];
    } @catch (__unused NSException *e) {}
    @try {
        pbOnlineNow = [song mutableCopy];
        pbPlayer = [[AVPlayer alloc] initWithURL:PBKuwoStreamURL(rid)];
        [pbPlayer play];
        PBAddRecent(song);
        PBLog(@"在线播放: %@ - %@ (rid=%@)", song[@"name"], song[@"artist"], rid);
        if (pbTabNow != 0) PBShowTab(0);
        PBRefresh();
    } @catch (NSException *e) {
        PBLog(@"在线播放异常: %@ — %@", e.name, e.reason);
    }
}

static void PBShowTab(NSInteger idx) {
    if (idx < 0 || idx > 3) idx = 0;
    pbTabNow = idx;
    for (NSInteger i = 0; i < (NSInteger)pbTabBtns.count; i++) {
        UIButton *b = pbTabBtns[i];
        [b setTitleColor:(i == idx) ? UIColor.whiteColor
                        : [UIColor colorWithWhite:1 alpha:0.45]
              forState:UIControlStateNormal];
        b.backgroundColor = (i == idx) ? [UIColor colorWithWhite:1 alpha:0.14]
                                       : UIColor.clearColor;
    }
    pbPageNow.hidden    = (idx != 0);
    pbPageSearch.hidden = (idx != 1);
    BOOL listTab = (idx >= 1);          /* 搜索页与列表页共用同一颗列表 */
    if (idx == 2 || idx == 3) {
        pbListIsLikes = (idx == 2);
        pbListItems = PBLoadList(pbListIsLikes);
    } else if (idx == 1) {
        pbListIsLikes = NO;
        pbListItems = pbSearchResults;
    }
    BOOL hasRows = pbListItems.count > 0;
    if (pbList) { pbList.hidden = !listTab; [pbList reloadData]; }
    if (pbListEmpty) {
        pbListEmpty.hidden = !listTab || hasRows;
        if (!hasRows)
            pbListEmpty.text = (idx == 1) ? (pbSearchResults ? @"没有找到歌曲" : @"输入关键词搜索歌曲\n(酷我音源, 结果点击即播)")
                : (idx == 2 ? @"还没有收藏的歌曲" : @"最近播放还是空的");
    }
}

static void PBBuildPanel(void) {
    if (pbCard || !pbWin) return;
    if (!pbCtrl) pbCtrl = [PBBallController new];
    CGRect wb = pbWin.bounds;
    CGFloat cw = MIN(wb.size.width - 32.0, 360.0);
    CGFloat ch = MIN(wb.size.height - 70.0, 500.0);
    CGFloat cx = (wb.size.width - cw) * 0.5, cy = (wb.size.height - ch) * 0.5;
    UIColor *sub = [UIColor colorWithWhite:1 alpha:0.5];
    UIColor *txt = UIColor.whiteColor;

    UIView *dim = [[UIView alloc] initWithFrame:wb];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:pbCtrl
                                                                     action:@selector(dimTap:)]];
    [pbWin addSubview:dim];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(cx, cy, cw, ch)];
    card.layer.cornerRadius = 26;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    /* 3.0.1: 修安全模式 —— SpringBoard 里不用 UIVisualEffectView, 纯色深底 */
    card.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.97];

    UILabel *head = PBMakeLabel(@"播放器", [UIFont systemFontOfSize:13 weight:UIFontWeightMedium],
                                [UIColor colorWithWhite:1 alpha:0.5]);
    head.frame = CGRectMake(20, 12, cw - 80, 18);
    [card addSubview:head];

    UIButton *close = PBMakeIcon(@"xmark", 14, [UIColor colorWithWhite:1 alpha:0.7]);
    close.frame = CGRectMake(cw - 42, 8, 36, 30);
    [close addTarget:pbCtrl action:@selector(closeTap:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    /* ---- tab 栏 ---- */
    pbTabNames = @[@"正在播", @"搜索", @"我喜欢", @"最近播"];
    pbTabBtns = [NSMutableArray array];
    CGFloat tw = (cw - 32) / 4.0;
    for (NSInteger i = 0; i < 4; i++) {
        UIButton *tb = [UIButton buttonWithType:UIButtonTypeSystem];
        tb.frame = CGRectMake(16 + i * tw, 36, tw, 28);
        tb.layer.cornerRadius = 14;
        tb.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        [tb setTitle:pbTabNames[i] forState:UIControlStateNormal];
        [tb addTarget:pbCtrl action:@selector(tabTap:) forControlEvents:UIControlEventTouchUpInside];
        tb.tag = i;
        [card addSubview:tb];
        [pbTabBtns addObject:tb];
    }

    /* ---- 页 0: 正在播 ---- */
    UIView *p0 = [[UIView alloc] initWithFrame:CGRectMake(0, 70, cw, ch - 70)];
    p0.backgroundColor = UIColor.clearColor;
    [card addSubview:p0];

    UIImageView *coverV = [[UIImageView alloc] initWithFrame:CGRectMake(24, 8, 92, 92)];
    coverV.contentMode = UIViewContentModeScaleAspectFill;
    coverV.clipsToBounds = YES;
    coverV.layer.cornerRadius = 18;
    coverV.layer.cornerCurve = kCACornerCurveContinuous;
    coverV.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    coverV.image = pbBallImg ?: PBPlaceholder(92);
    [p0 addSubview:coverV];

    UILabel *t = PBMakeLabel(@"未在播放", [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold], txt);
    t.frame = CGRectMake(130, 18, cw - 150, 22);
    t.textAlignment = NSTextAlignmentLeft;
    [p0 addSubview:t];

    UILabel *a = PBMakeLabel(@"点播放键或搜索歌曲", [UIFont systemFontOfSize:13], sub);
    a.frame = CGRectMake(130, 44, cw - 150, 18);
    a.textAlignment = NSTextAlignmentLeft;
    [p0 addSubview:a];

    /* 深链: 打开酷我 / QQ 音乐 App */
    UIButton *kuwoB = [UIButton buttonWithType:UIButtonTypeSystem];
    kuwoB.frame = CGRectMake(130, 66, 100, 26);
    kuwoB.layer.cornerRadius = 13;
    kuwoB.layer.borderWidth = 1;
    kuwoB.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    kuwoB.tintColor = txt;
    kuwoB.titleLabel.font = [UIFont systemFontOfSize:11];
    [kuwoB setTitle:@"酷我音乐" forState:UIControlStateNormal];
    [kuwoB addTarget:pbCtrl action:@selector(openKuwo:) forControlEvents:UIControlEventTouchUpInside];
    [p0 addSubview:kuwoB];

    UIButton *qqB = [UIButton buttonWithType:UIButtonTypeSystem];
    qqB.frame = CGRectMake(238, 66, 100, 26);
    qqB.layer.cornerRadius = 13;
    qqB.layer.borderWidth = 1;
    qqB.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    qqB.tintColor = txt;
    qqB.titleLabel.font = [UIFont systemFontOfSize:11];
    [qqB setTitle:@"QQ音乐" forState:UIControlStateNormal];
    [qqB addTarget:pbCtrl action:@selector(openQQ:) forControlEvents:UIControlEventTouchUpInside];
    [p0 addSubview:qqB];

    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(28, 122, cw - 56, 28)];
    sl.minimumValue = 0; sl.maximumValue = 1; sl.value = 0;
    sl.minimumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.9];
    sl.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.22];
    [sl addTarget:pbCtrl action:@selector(sliderDown:) forControlEvents:UIControlEventTouchDown];
    [sl addTarget:pbCtrl action:@selector(sliderChanging:) forControlEvents:UIControlEventValueChanged];
    [sl addTarget:pbCtrl action:@selector(sliderUp:) forControlEvents:
        UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [p0 addSubview:sl];

    UILabel *p = PBMakeLabel(@"0:00", [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular], sub);
    p.textAlignment = NSTextAlignmentLeft;
    p.frame = CGRectMake(28, 150, 60, 16);
    [p0 addSubview:p];

    UILabel *dm = PBMakeLabel(@"0:00", [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular], sub);
    dm.textAlignment = NSTextAlignmentRight;
    dm.frame = CGRectMake(cw - 88, 150, 60, 16);
    [p0 addSubview:dm];

    CGFloat by = 176.0;
    UIButton *prev = PBMakeIcon(@"backward.fill", 22, txt);
    prev.frame = CGRectMake(cw * 0.5 - 100, by, 52, 50);
    [prev addTarget:pbCtrl action:@selector(prevTap) forControlEvents:UIControlEventTouchUpInside];
    [p0 addSubview:prev];

    UIButton *play = [UIButton buttonWithType:UIButtonTypeSystem];
    play.frame = CGRectMake(cw * 0.5 - 28, by - 4, 56, 56);
    play.backgroundColor = UIColor.whiteColor;
    play.tintColor = UIColor.blackColor;
    play.layer.cornerRadius = 28;
    [play setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
    [play setPreferredSymbolConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightBold]
                                  forImageInState:UIControlStateNormal];
    [play addTarget:pbCtrl action:@selector(playTap) forControlEvents:UIControlEventTouchUpInside];
    [p0 addSubview:play];

    UIButton *next = PBMakeIcon(@"forward.fill", 22, txt);
    next.frame = CGRectMake(cw * 0.5 + 48, by, 52, 50);
    [next addTarget:pbCtrl action:@selector(nextTap) forControlEvents:UIControlEventTouchUpInside];
    [p0 addSubview:next];

    /* ---- 页 1: 搜索(酷我音源) ---- */
    UIView *p1 = [[UIView alloc] initWithFrame:CGRectMake(0, 70, cw, ch - 70)];
    p1.backgroundColor = UIColor.clearColor;
    p1.hidden = YES;
    [card addSubview:p1];

    UITextField *sf = [[UITextField alloc] initWithFrame:CGRectMake(16, 8, cw - 92, 36)];
    sf.placeholder = @"搜索歌曲 / 歌手 (酷我音源)";
    sf.font = [UIFont systemFontOfSize:14];
    sf.textColor = txt;
    sf.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    sf.layer.cornerRadius = 10;
    sf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    sf.leftViewMode = UITextFieldViewModeAlways;
    sf.returnKeyType = UIReturnKeySearch;
    sf.autocorrectionType = UITextAutocorrectionTypeNo;
    sf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [sf addTarget:pbCtrl action:@selector(searchField:) forControlEvents:UIControlEventEditingDidEndOnExit];
    [p1 addSubview:sf];

    UIButton *go = [UIButton buttonWithType:UIButtonTypeSystem];
    go.frame = CGRectMake(cw - 70, 8, 56, 36);
    go.layer.cornerRadius = 10;
    go.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    go.tintColor = txt;
    go.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [go setTitle:@"搜索" forState:UIControlStateNormal];
    [go addTarget:pbCtrl action:@selector(searchGo:) forControlEvents:UIControlEventTouchUpInside];
    [p1 addSubview:go];

    /* ---- 页 2/3: 列表(喜欢 / 最近播) ---- */
    UIView *p2 = [[UIView alloc] initWithFrame:CGRectMake(0, 70, cw, ch - 70)];
    p2.backgroundColor = UIColor.clearColor;
    p2.hidden = YES;
    [card addSubview:p2];

    /* ---- 歌曲列表(搜索结果 / 喜欢 / 最近播 共用) ---- */
    UITableView *lv = [[UITableView alloc] initWithFrame:CGRectMake(0, 70, cw, ch - 70)
                                    style:UITableViewStylePlain];
    lv.backgroundColor = UIColor.clearColor;
    lv.separatorColor = [UIColor colorWithWhite:1 alpha:0.10];
    lv.delegate = pbCtrl;
    lv.dataSource = pbCtrl;
    lv.rowHeight = 46;
    lv.contentInset = UIEdgeInsetsMake(0, 0, 20, 0);
    lv.hidden = YES;
    [card addSubview:lv];

    UILabel *empty = PBMakeLabel(@"", [UIFont systemFontOfSize:14], sub);
    empty.numberOfLines = 0;
    empty.frame = lv.frame;
    empty.hidden = YES;
    [card addSubview:empty];

    [pbWin addSubview:card];

    pbDim = dim; pbCard = card; pbCover = coverV;
    pbTitle = t; pbArtist = a; pbPos = p; pbDur = dm;
    pbSlider = sl; pbPlayBtn = play;
    pbSearchField = sf; pbList = lv; pbListEmpty = empty;
    pbPageNow = p0; pbPageSearch = p1; pbPageList = p2;

    PBShowTab(0);
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
    /* 3.0.1: 面板构建全程兜底 —— 任何异常都只记日志, 绝不能把 SpringBoard 拖进安全模式 */
    @try {
        PBBuildPanel();
    } @catch (NSException *e) {
        PBLog(@"面板构建异常: %@ — %@", e.name, e.reason);
        PBClosePanel();
        return;
    }
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
    @try { [pbSearchField resignFirstResponder]; } @catch (__unused NSException *e) {}
    UIView *dim = pbDim, *card = pbCard;
    pbDim = nil; pbCard = nil; pbCover = nil;
    pbTitle = nil; pbArtist = nil; pbPos = nil; pbDur = nil;
    pbSlider = nil; pbPlayBtn = nil; pbDragging = NO;
    pbList = nil; pbListEmpty = nil; pbSearchField = nil;
    pbPageNow = nil; pbPageSearch = nil; pbPageList = nil;
    pbTabBtns = nil;
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
    PBLog(@"悬浮球已挂载: %.0fx%.0f 中心=(%.0f,%.0f) window level=%.0f 素材=%@",
          size, size, pbBall.center.x, pbBall.center.y, pbWin.windowLevel,
          pbBallPath.length ? pbBallPath.lastPathComponent : @"占位");
}

static void PBDestroy(void) {
    PBClosePanel();
    pbRetrying = NO; pbRetryCount = 0;
    if (pbPlayer) { @try { [pbPlayer pause]; } @catch (__unused NSException *e) {} pbPlayer = nil; pbOnlineNow = nil; }
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
