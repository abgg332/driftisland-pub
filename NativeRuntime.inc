/* 独立原生播放器 运行时 —— 逐字摘自 漂流岛 3.1 Tweak.mm(除音律)。背景/隐藏未在/隐藏时间/MediaRemote取图。*/
static void RLog(NSString *fmt, ...) { va_list a; va_start(a,fmt); NSString *s=[[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a); NSLog(@"[原生播放器] %@",s); }
static void diNoImplicitActions(CALayer *l) {
    if (!l) return;
    l.actions = @{ @"contents": [NSNull null], @"frame": [NSNull null],
                   @"position": [NSNull null], @"bounds": [NSNull null],
                   @"cornerRadius": [NSNull null], @"hidden": [NSNull null],
                   @"opacity": [NSNull null], @"path": [NSNull null],
                   @"transform": [NSNull null], @"backgroundColor": [NSNull null] };
}
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
static int gDIStage = 3;
static void diPhase(const char *p){ (void)p; }
static const void *kDIBgIVKey  = &kDIBgIVKey;
static const void *kDIBgDimKey = &kDIBgDimKey;
static const void *kDIBgLastKey = &kDIBgLastKey;   /* 3.0.10: 模块 VC 处理节流 */
static const void *kDIBgRKey    = &kDIBgRKey;      /* 3.0.15: 缓存圆角 */
static const void *kDIBgSizeKey = &kDIBgSizeKey;   /* 3.0.15: 缓存 host 尺寸 */
static const void *kDIBgRectKey = &kDIBgRectKey;   /* 3.0.15: 缓存背景矩形 */

static NSHashTable *gDIBgHosts = nil;       /* 模块内容容器(隐藏未在播放用) */
static NSHashTable *gDIBgPlayers = nil;     /* 3.0.15: 背景宿主 = 播放器视图(各尺寸的可见卡片) */
static UIImage *gDIBgImage = nil;
static UIImage *diFxArtworkImage=nil;
static NSData *diFxArtworkData=nil;
static NSData *gDIBgData = nil;          /* 3.0.14: 专辑图原始数据, 换曲判定用 */
static CFTimeInterval gDIBgFetchTS = 0;
static CFTimeInterval gDIBgLastReqTS = 0;   /* 3.0.15: 取图请求节流 */
static CFTimeInterval gDIBgPrefTS = 0;
static BOOL gDIBgOnCache = YES;
static BOOL gDIHideNP = NO;
static BOOL gDIHideTime = NO;   /* 3.0.41: 未播放时隐藏进度条与两侧时间 */
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
        BOOL hidT = diNPPrefFlagRaw(@"HideTimeWhenIdle", NO);
        diNPPrefCachePut(@"MusicArtworkGradientEnabled", on);
        diNPPrefCachePut(@"HideNotPlaying", hid);
        diNPPrefCachePut(@"HideTimeWhenIdle", hidT);
        dispatch_async(dispatch_get_main_queue(), ^{
            gDIBgOnCache = on;
            gDIHideNP = hid;
            gDIHideTime = hidT;
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
    static BOOL writing=NO;
    if(writing)return;
    struct DIBgScope {BOOL *flag;DIBgScope(BOOL *f):flag(f){*flag=YES;}~DIBgScope(){*flag=NO;}} scope(&writing);
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
        if(bg.hidden)bg.hidden=NO;
        if(dim.hidden)dim.hidden=NO;
        if(fabs(bg.cornerRadius-r)>.01)bg.cornerRadius=r;
        if(fabs(dim.cornerRadius-r)>.01)dim.cornerRadius=r;
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
/* 3.0.42: 记录"被我们亲手藏掉的未在播放标签" —— 判断"现在是不是真的没歌"时,
   这些标签虽然 hidden 了, 仍然算作可见(是我们藏的, 不是系统收起的)。 */
static NSHashTable *gDIHiddenNPLabels = nil;

static void diNPHideNotPlayingLabels(UIView *root, BOOL hide) {
    if (!root) return;
    if (!gDIHiddenNPLabels) gDIHiddenNPLabels = [NSHashTable weakObjectsHashTable];
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
                if (hide) [gDIHiddenNPLabels addObject:v];
                else [gDIHiddenNPLabels removeObject:v];
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

static void diNPApplyHideTime(void);
static void diNPApplyHideForRoot(UIView *root) {
    diNPTickPrefs();
    diNPHideNotPlayingLabels(root, gDIHideNP);
    @try { diNPApplyHideTime(); } @catch (__unused NSException *e) {}
}

/* ---------- 3.0.41/3.0.42: 隐藏时间(只在没放歌的时候) ----------
   用户要的是: 没播放歌曲时, 把进度条那条横条和左右两个时间一起藏掉。

   3.0.42 修两个毛病:
   ① 播放后仍被判成"未播放", 时间条一直被压成透明, 和系统一拉一扯 → 用户看到"一闪一闪"。
      根因: 播放时"未在播放"那条 UILabel 还留在视图树里(只是被系统 hidden),
      旧逻辑只看文字不看可见性, 于是永远判空。现在要求标签真的在窗口里、
      自身与祖先都没被系统收起(「隐藏未在」被我们亲手藏的那个除外)。
   ② 呼出控制中心、展开再收起时, 时间条先露一下才被藏掉 → 旧逻辑靠 0.5 秒巡检,
      第一帧来不及。现在给 MRUNowPlayingTimeControlsView 挂 layoutSubviews:
      系统每次重排完, 在同一个提交帧里把 alpha 压回去, 肉眼看不到中间态。

   为什么仍然用 alpha 不用 hidden: hidden 会让父级 stack 当场塌陷, 3×2 那排按钮
   跟着移位(用户对"按钮乱跳"零容忍); alpha 只影响可见性, 排版一个像素不动。 */
/* 3.0.42: "到底有没有歌" 用 MediaRemote 的 now playing info 判断 ——
   有 info 且有标题 = 有歌(暂停也算, 暂停时系统仍显示时间和进度);
   info 为空/没有标题 = 真的没歌, 这才是用户说的"没播放"。
   1 秒最多问一次, 回调在后台队列, 结果回主线程。符号缺失时退回文案判定。 */
static double diRingElapsed=0, diRingDuration=0, diRingRate=0;
static CFAbsoluteTime diRingStamp=0;
static BOOL gDIHasNowPlaying = NO;
static BOOL gDIInfoReady = NO;
static void diNPQueryNowPlaying(void) {
    diNPLoadMediaRemote();   /* 幂等: 背景功能关着时也要把符号拉起来 */
    if (!gMRGetNowPlayingInfo) return;
    static CFAbsoluteTime last = 0;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - last < 1.0) return;
    last = now;
    gMRGetNowPlayingInfo(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(CFDictionaryRef info) {
        BOOL has = NO;
        @try {
            /* 3.0.88: 494 —— 以前只认"有标题", 本地/无标题的源(播客、无元数据的文件)
               info 里没有 Title 就被判成"没歌", 律动/粒子整套引擎都起不来。
               现在: info 非空就算有歌(暂停也算), 只有 info 全空才是真的没歌。
               "到底在不在放"交给 PlaybackRate 那条硬信号, 不靠这里。 */
            has = (info != NULL);
        } @catch (__unused NSException *e) {}
        (void)info;
        dispatch_async(dispatch_get_main_queue(), ^{
            /* standalone */
            /* standalone */
            gDIHasNowPlaying = has;
        });
    });
}

/* 3.0.43/3.0.44: 只看折叠态的播放器卡片 —— 展开整块完全不动(用户明确要求)。
   3.0.43 用 bounds 高度判, 用户实测"展开的也被藏了(时好时坏)", 原因两条:
     ① 展开/收起是 transform 缩放动画, bounds 经常还是折叠尺寸, 量出来永远"没展开";
     ② 类名不能用 isEqualToString 比对, 实际拿到的是 MRUNowPlayingView 的子类。
   现在: 沿父链把所有 MRUNowPlaying* / *ContentModuleContainerView 都换算到 window
   坐标量一遍(带 transform 的真实大小), 取最大那块, 宽≥320 或 高≥235 就算展开。 */



/* ===== 3.0.66: 3×2 歌名/歌词的原生来回滚动补齐 =====
   478 用户: "4×2 布局的歌词歌名会原生那样来回滚动, 3×2 的没有了, 顺便修一下,
   保持原生的逻辑"。4×2 等布局系统自带 marquee(3×2 下标签被排得足够宽/换了实现,
   系统就不滚了)。这里只在 **3x2 / 3x2b** 档生效:
   · 头部(MRUNowPlayingHeader*)里文本溢出的 UILabel → 层上加来回滚动动画;
   · 只写 presentation(动画挂在 transform.translation.x 上, model 一字不动)——
     不会触发系统重排, 也不会和布局打架;
   · 系统已经在滚(层上有别的动画)的标签一律不碰 —— 保持原生逻辑;
   · 文本/宽度变了自动重建, 文本放得下自动摘掉。
   原生节奏: 起停各停 0.5 秒, 移动速度约 30pt/s, 到头停半秒再回来。 */





/* 3.0.54: 用户把「隐藏时间」改成「时间条上下移动」。
   ------------------------------------------------------------------
   3.0.55 把 layoutSubviews 钩子整个删掉了(它就是"一设置就卡死"的元凶):
     · 在 layoutSubviews 里给视图设 transform, transform 会影响 frame, UIKit 随即
       再给父视图排一次版 → 又进钩子 → 每帧无限重排, SpringBoard 主线程直接卡死;
     · 钩子里还调 diTimeExpanded() → convertRect:toView: → 在布局过程中强制布局,
       形成重入, 更糟。
   现在只保留"巡检式"应用: 由 0.25/0.4 秒的轻量扫描(和设置页的 fxtune 通知)去设
   transform。系统重排只写 frame、不会清 transform, 所以位移能稳定保持;
   万一系统把控件换了个新实例, 下一次巡检会重新套上。 */
/* 3.0.55: 设置页特效参数变化(拖滑杆 / 换颜色 / 换颜色模式) 的**轻量通道**。
   以前这些键写完后发的是通用的 prefsChanged / artwork-changed, 那两条会触发
   "全量偏好重读 + 壁纸/视频/锁屏卡片全刷 + mask.png 重新导出" —— 拖一下滑杆
   每秒三五次, SpringBoard 主线程直接被按住, 用户看到的就是"一设置就卡死"。
   现在只做: 重读特效参数 → 立即套时间条位移 → 确保引擎在跑。
   合并 0.12 秒, 连续拖动也只会在停顿处生效一两次。 */


static void diNPApplyHideTime(void) {
    static CFAbsoluteTime lastScan = 0;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - lastScan < 0.4) return;
    lastScan = now;

    diNPQueryNowPlaying();   /* 律动那边还靠 gDIHasNowPlaying 判"到底有没有歌" */
}
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