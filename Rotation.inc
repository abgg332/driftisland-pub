/* Source: DriftIsland 3.1 Tweak.mm. Rotation/mask function bodies retained. */

#import <mach-o/dyld.h>
static int gDISizeGen=0;
static BOOL playerMaskOn=NO;
static BOOL enabled=YES;
static CFTimeInterval gDISpinEpoch=0;
static const CFTimeInterval kDISpinDur=10.0;
static __weak UIView *gDIArtSpinYield=nil;
static double gDiMaskCoverage=-1;
static BOOL gDiMaskHasAlpha=NO,gDiMaskBrightIsShape=YES;
static int gDiMaskThreshold=0;
#define DLog RLog
static NSString *const kDomain=@"com.abgg332.driftisland";
static NSString *const kDIMaskRoot=@"/var/mobile/灵动岛/遮罩素材";
static BOOL diPrefBoolNow(NSString *key,BOOL fallback){
 id v=CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,(__bridge CFStringRef)kDomain));
 return [v respondsToSelector:@selector(boolValue)]?[v boolValue]:fallback;
}


@implementation DIArtMaskState
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

static void (*gDIOrigLayerAddAnim)(id, SEL, CAAnimation *, NSString *) = NULL;
static int gDISpinBlocked = 0;
static void diLayerAddAnimHook(id self, SEL cmd, CAAnimation *anim, NSString *key) {
    @try {
        if (anim && [anim isKindOfClass:CABasicAnimation.class] && ![key isEqualToString:@"di.art.spin"]) {
            NSString *kp = ((CABasicAnimation *)anim).keyPath;
            if ([kp isEqualToString:@"transform.rotation.z"] || [kp isEqualToString:@"transform.rotation"]) {
                for (CALayer *p = (CALayer *)self; p; p = p.superlayer) {
                    if (objc_getAssociatedObject(p, kDIArtStateKey)) {
                        gDISpinBlocked++;
                        if (gDISpinBlocked <= 8) {
                            RLog(@"[封面] 挡掉第二条旋转 %@ key=%@ (第 %d 条)", kp, key ?: @"?", gDISpinBlocked);
                        }
                        return;
                    }
                }
            }
        }
    } @catch (__unused NSException *e) {}
    if (gDIOrigLayerAddAnim) gDIOrigLayerAddAnim(self, cmd, anim, key);
}
static void diArtInstallSpinGuard(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    @try {
        MSHookMessageEx([CALayer class], @selector(addAnimation:forKey:),
                        (IMP)diLayerAddAnimHook, (IMP *)&gDIOrigLayerAddAnim);
        RLog(@"[封面] 旋转唯一化 %@", gDIOrigLayerAddAnim ? @"已装" : @"失败(退回只清一次)");
    } @catch (__unused NSException *e) {}
}



static BOOL diArtIs3x2(void) {
    static NSString *cache = nil;
    static CFTimeInterval ts = 0;
    static int cacheGen = -1;
    if (cacheGen != gDISizeGen) { cache = nil; ts = 0; cacheGen = gDISizeGen; }   /* 3.0.71 */
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

static BOOL diArtNameIsArtwork(NSString *cn) {
    if (!cn.length) return NO;
    if ([cn containsString:@"Activity"] || [cn containsString:@"Flipping"]) return NO;
    if ([cn containsString:@"Blur"] || [cn containsString:@"Shadow"] || [cn containsString:@"Gradient"]) return NO;
    return [cn containsString:@"Artwork"] || [cn containsString:@"AlbumArt"];
}

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

static BOOL gDIArtSawEmptyTile=NO;
static NSHashTable *gDIArtKnown=nil;

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

static NSArray<NSString *> *diSortStrs(NSArray *a){return [a sortedArrayUsingComparator:^NSComparisonResult(NSString *x,NSString *y){return [x localizedStandardCompare:y];}] ?: @[];}

static NSArray<NSString *> *DIMaskListAssets(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:kDIMaskRoot isDirectory:&isDir] || !isDir) return out;

    NSMutableArray<NSString *> *queue = [NSMutableArray arrayWithObject:@""];
    int depthGuard = 0;
    while (queue.count && depthGuard++ < 200) {
        NSString *rel = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSInteger depth = rel.length ? ([rel componentsSeparatedByString:@"/"].count) : 0;
        NSString *full = rel.length ? [kDIMaskRoot stringByAppendingPathComponent:rel] : kDIMaskRoot;
        NSArray<NSString *> *items = diSortStrs([fm contentsOfDirectoryAtPath:full error:NULL]);
        for (NSString *name in items) {
            if (![name isKindOfClass:NSString.class]) continue;
            if ([name hasPrefix:@"."]) continue;
            NSString *childRel = rel.length ? [rel stringByAppendingPathComponent:name] : name;
            NSString *childFull = [kDIMaskRoot stringByAppendingPathComponent:childRel];
            BOOL d = NO;
            if (![fm fileExistsAtPath:childFull isDirectory:&d]) continue;
            if (!d) {
                NSString *ext = name.pathExtension.lowercaseString;
                if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] ||
                    [ext isEqualToString:@"jpeg"]) [out addObject:childRel];
            } else if (depth < 3) {
                [queue addObject:childRel];
            }
        }
    }
    return out;
}

static UIImage *diArtMaskImage(void){
 // SpringBoard reads the same selected source and uses the original 3.1 alpha conversion.
 id v=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("PlayerMaskAsset"),(__bridge CFStringRef)kDomain));
 if(![v isKindOfClass:NSString.class] || ![v length] || [v isEqual:@"__none__"])return nil;
 if(![DIMaskListAssets() containsObject:v])return nil;
 return diMaskAlphaCached([kDIMaskRoot stringByAppendingPathComponent:v]);
}

static BOOL diArtMaskWanted(void) {
    /* 3.0.59: **直接读偏好**, 不再信 params.plist。
       472 用户「启用遮罩关了还是显示遮罩」的链路是这样的:
         prefsChanged → 排一次导出(0.25s 去抖) + 排一次全量刷新(0.18s)
         全量刷新先跑 → diArtDress 读 params.plist(此时还是旧值 pmOn=1) → 认为要贴素材
         导出后跑完 → params.plist 更新, 但已经没人再调 diArtDress
       结果就是"关了还亮着"。diArtDress 本来就跑在 SpringBoard 里, 偏好随手可读, 1 秒缓存
       只是为了避免每帧碰 cfprefsd —— 这个开销比一次跨进程读小得多, 也对得起"开关要即时"。 */
    static BOOL cached = NO;
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (last == 0 || now - last > 0.35) {
        last = now;
        cached = diPrefBoolNow(@"PlayerMaskOn", playerMaskOn);
    }
    return cached;
}

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
    /* 3.0.39: 有遮罩素材就贴素材(alpha 蒙版), 没有就退回内切圆 */
    UIImage *mk = diArtMaskWanted() ? diArtMaskImage() : nil;
    BOOL wantAsset = (mk.CGImage != NULL);
    /* 只有"尺寸真的变了" / "系统把我们那片 mask 换掉了" / "素材换了或开关变了"才重建 */
    if (layer.mask != st.mask || !CGSizeEqualToSize(st.lastSize, b.size)
        || st.assetOn != wantAsset || (wantAsset && st.assetImg != mk)) {
        st.lastSize = b.size;
        st.mask.frame = b;
        if (wantAsset) {
            /* CAShapeLayer 同时有 path 和 contents 时 path 优先 —— 必须先清掉 path */
            st.mask.path = NULL;
            st.mask.contents = (__bridge id)mk.CGImage;
            st.mask.contentsGravity = kCAGravityResizeAspect;   /* 保持素材比例, 不拉扁 */
            st.mask.contentsScale = 1.0;
        } else {
            CGFloat side = MIN(b.size.width, b.size.height);
            CGRect circle = CGRectMake((b.size.width - side) / 2.0, (b.size.height - side) / 2.0, side, side);
            st.mask.contents = nil;
            st.mask.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(circle, 0.5, 0.5)].CGPath;
        }
        st.assetOn = wantAsset;
        st.assetImg = wantAsset ? mk : nil;
        layer.mask = st.mask;
        NSString *desc = [NSString stringWithFormat:@"%@ %.0fx%.0f", NSStringFromClass(v.class),
                          b.size.width, b.size.height];
        if (![desc isEqualToString:gDIArtLastDesc]) {
            gDIArtLastDesc = desc;
            RLog(@"[封面] %@已挂 %@", wantAsset ? @"播放器遮罩" : @"圆形蒙版", desc);
        }
    }
    /* 3.0.61: **遮罩和旋转彻底分开**。
       以前这两件事绑在同一个 diArtPrefOn()(「专辑旋转」) 上: 关掉旋转 → 连遮罩一起摘,
       开着旋转 → 不管遮罩开关都会贴素材。用户 472「启用遮罩关了还显示」/474「专辑冲突」
       的根就是这个。现在: 遮罩只看「启用遮罩」, 旋转只看「专辑旋转」。 */
    if (!diArtPrefOn()) return;
    if (![layer animationForKey:@"di.art.spin"]) {
        /* 3.0.57: 律动正在接管这层的 transform(旋转+缩放一起算), 这时再挂 CA 动画
           就是两个写入者抢同一个属性 —— 旋转会忽快忽慢、缩放会被顶掉。直接跳过。 */
        if (gDIArtSpinYield == v) return;
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
            /* 3.0.60: **不把 transform 拍回原值/单位阵**。
               473 用户"关闭专辑旋转, 展开都不显示了": 展开态那张 308x308 的大图,
               系统会用自己的 transform 做适配; 我们硬拍回接管时记下的 origTransform
               (或单位阵) 就把适配缩放清掉了 → 图飞出去/看不见。
               这里只摘动画, transform 留给系统下一次布局去设。 */
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
/* 传送栏自己的 layoutSubviews: 系统排完立刻摆平(同一帧、提交前, 用户看不到中间态) */
static void (*gDIOrigTCRowLayout)(id, SEL) = NULL;
static void diTCRowLayout(id self, SEL cmd) {
    if (gDIOrigTCRowLayout) gDIOrigTCRowLayout(self, cmd);
    @try {
        diTBNormalizeRow((UIView *)self);
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
        diTBfixBtn(b);
    } @catch (__unused NSException *e) {}
}
static void diBtnTransformHook(id self, SEL cmd, CGAffineTransform t) {
    gDIOrigBtnTransform(self, cmd, t);
    @try {
        UIView *b = (UIView *)self;
        diTBfixBtn(b);
    } @catch (__unused NSException *e) {}
}
static void (*gDIOrigTBFrame)(id, SEL, CGRect) = NULL;
static void (*gDIOrigTBTransform)(id, SEL, CGAffineTransform) = NULL;
static void diTBFrameHook(id self, SEL cmd, CGRect f) {
    gDIOrigTBFrame(self, cmd, f);
    @try {
        diTBNormalizeRow((UIView *)self);
    } @catch (__unused NSException *e) {}
}
static void diTBTransformHook(id self, SEL cmd, CGAffineTransform t) {
    gDIOrigTBTransform(self, cmd, t);
    @try {
        diTBNormalizeRow((UIView *)self);
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
static BOOL diTimeExpanded(UIView *v) {
    if (!v) return NO;
    /* 3.0.66: 478 用户: "只有 3×2 有律动/粒子, 其他布局没有"。
       旧判据"宽>=320 或 高>=235"把 4×2/4×3/4×1 这类本来就宽的**折叠模块卡片**
       全部误判成"展开页", 律动/粒子在那些布局下被整体隐藏。
       现在两步走:
       ① 父链判定: 走 MRUNowPlayingViewController / *Expanded 的才是展开播放页;
       ② 尺寸兜底只看高度(展开页高必然 >=420, 折叠模块最高 4×3 也到不了),
          宽度判据删除 —— 宽布局的卡片宽 320~400 是常态。 */
    if (diArtInExpandedPlayer(v)) return YES;
    /* 3.0.67: 479 用户 "4×2 那些的展开有影响" —— 宽布局的展开页**复用同一张封面**,
       系统用 transform 把它放大(bounds 还是 57), 于是:
       · 尺寸兜底(bounds 量出来还是折叠尺寸)量不到 → 展开态漏判;
       · 律动继续往这张"已经被放大"的封面上写缩放 → 展开页专辑跟着鼓点抽动。
       用呈现层/模型层的放大比判: 折叠态比例 ≈1.0(律动最多 1.13),
       展开态系统把它放大 2~5 倍 —— 比例 >1.6 就是展开, 与布局无关。 */
    {
        CALayer *pl = v.layer.presentationLayer;
        CGSize ps = pl ? pl.bounds.size : v.bounds.size;
        CGFloat bw2 = MAX(1.0, v.bounds.size.width), bh2 = MAX(1.0, v.bounds.size.height);
        if (ps.width / bw2 > 1.6 || ps.height / bh2 > 1.6) return YES;
    }
    UIView *win = v.window;
    UIView *cur = v;
    int g = 0;
    CGFloat bw = 0, bh = 0;
    while (cur && g++ < 14) {
        NSString *cn = NSStringFromClass(cur.class);
        if ([cn containsString:@"MRUNowPlaying"] || [cn containsString:@"ContentModuleContainerView"]) {
            CGRect r = win ? [cur convertRect:cur.bounds toView:win] : cur.bounds;
            if (r.size.width * r.size.height > bw * bh) { bw = r.size.width; bh = r.size.height; }
        }
        cur = cur.superview;
    }
    if (bw <= 0) return NO;
    /* 3.0.67: 独立展开容器的兜底 —— 宽≥320 且 高≥300 才算展开。
       折叠卡最高 ~240(2x3/4x3 三行), 不会误伤; 宽布局折叠卡(356x77)高不够也过不了。 */
    return (bw >= 320.0 && bh >= 300.0);
}
static NSString *diMarqueeSigOf(UILabel *lb) {
    return [NSString stringWithFormat:@"%@|%.0f|%.0f", lb.text ?: @"",
            lb.bounds.size.width, lb.bounds.size.height];
}
static void diMarqueeApply(UILabel *lb) {
    CGSize fit = [lb sizeThatFits:CGSizeMake(MAX(10.0, lb.bounds.size.width), CGFLOAT_MAX)];
    CGFloat ov = fit.width - lb.bounds.size.width;
    if (ov < 6.0) {
        if ([lb.layer animationForKey:@"di.marquee"]) [lb.layer removeAnimationForKey:@"di.marquee"];
        objc_setAssociatedObject(lb, @selector(diMarqueeSig), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (lb.layer.animationKeys.count > 0 && ![lb.layer animationForKey:@"di.marquee"])
        return;   /* 系统自己的动画(marquee/淡入等): 一律不碰 */
    NSString *sig = diMarqueeSigOf(lb);
    NSString *last = objc_getAssociatedObject(lb, @selector(diMarqueeSig));
    if ([sig isEqualToString:last ?: @""] && [lb.layer animationForKey:@"di.marquee"]) return;
    objc_setAssociatedObject(lb, @selector(diMarqueeSig), sig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat move = ov / 30.0;
    CGFloat ovX = ov + 8.0;
    double dur = 0.5 + move + 0.5 + move;
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    a.values = @[@0.0, @0.0, @(-ovX), @(-ovX), @0.0];
    a.keyTimes = @[@0.0, @(0.5 / dur), @((0.5 + move) / dur), @((1.0 + move) / dur), @1.0];
    a.duration = dur;
    a.repeatCount = HUGE_VALF;
    [lb.layer addAnimation:a forKey:@"di.marquee"];
}
static void diNPMarqueeScan(UIView *root) {
    if (!root || !root.window || root.hidden) return;
    if (!diArtIs3x2()) return;                    /* 其他布局系统原生会滚, 不碰 */
    if (diArtInExpandedPlayer(root)) return;      /* 展开播放页不碰 */
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    int budget = 800;
    while (stack.count && budget-- > 0) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:UILabel.class]) {
            UILabel *lb = (UILabel *)v;
            BOOL inHeader = NO;
            for (UIView *p = lb.superview; p && p != root; p = p.superview) {
                if ([NSStringFromClass(p.class) containsString:@"Header"]) { inHeader = YES; break; }
            }
            if (inHeader && lb.text.length > 0 && !lb.hidden && lb.alpha > 0.3) {
                @try { diMarqueeApply(lb); } @catch (__unused NSException *e) {}
            }
        }
        for (UIView *c in v.subviews) [stack addObject:c];
    }
}
static void diArtPostFlush(UIView *root);
static void diArtInstallAVHook(void);
static NSHashTable *gDIArtPending=nil,*gDIArtDressPending=nil;
static BOOL gDIArtFlushQueued=NO;
static CFTimeInterval gDIArtLastFlush=0;


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
            if (diArtPrefOn() || diArtMaskWanted()) diArtDress(a);   /* 3.0.61: 遮罩独立 */
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
        if (!nprDone) { nprDone = YES; diArtDisableNPRSpin(); diArtInstallSpinGuard(); }
    }
    if (!gDIArtPending) gDIArtPending = [NSHashTable weakObjectsHashTable];
    [gDIArtPending addObject:root];
    diArtFlushQueue();
}

static void diArtPostFlush(UIView *root) {
    if (!root || !root.window) return;
    /* 3.0.66: 播放器每次布局都尝试唤醒特效引擎 —— 打开控制中心/换尺寸的第一帧就能
       从休眠里恢复, 不用等 1Hz 巡检(diRhythmEnsure 内部有条件, 没休眠时是空操作)。 */

    diPhase("art");
    /* 3.0.61: 遮罩(启用遮罩)和旋转(专辑旋转)分开判断 */
    BOOL on = diArtPrefOn() || diArtMaskWanted();
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

    /* 3.0.43: 不管遮罩/旋转开没开, 都把封面记下来 —— 律动/粒子要用它挑目标,
       否则用户关掉遮罩后律动就失效了。 */
    if (!gDIArtKnown) gDIArtKnown = [NSHashTable weakObjectsHashTable];
    for (__strong UIView *a in arts) [gDIArtKnown addObject:a];
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
                @try { diNPMarqueeScan(root); } @catch (__unused NSException *e) {}
                /* 3.0.66: 3×2 歌名/歌词 marquee 补齐(节流 0.5s 在函数内部) */

                diPhase("art");
            });
        }
    }
    /* 3.0.12: 展开态自动导出一次完整视图树(只为定位"有些封面没覆盖"), 写盘不刷屏 */
    /* 3.0.35: 只在开了日志时导出 —— 400 节点拼字符串 + 落盘是首开那一秒的"主线程
       连续活"之一, 交付版本不该无条件跑(交接文档 P1 也要求"交付前关掉")。 */

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

static void (*gDIOrigAVLayout)(id,SEL)=NULL;
static BOOL gDIArtAVTried=NO;

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

}
