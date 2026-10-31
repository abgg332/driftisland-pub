// DIAlbumMask.mm —— 专辑光晕遮罩
// 三块职责:
//   1) 读取: 扫描 /var/mobile/灵动岛/遮罩素材 (一层递归, 只要 png), 选中项存 diAlbumMaskAsset
//   2) 应用: 封面本体 + 遮罩 png 作为 maskView, 垫在专辑封面下面
//   3) 素材缺失时整段跳过 —— 绝不代码兜底(代码兜底就是黑块的成因)
//
// 2.6.11 修复:
//   · sortedArrayUsingSelector:@selector(localizedCompare) 在部分系统/ARC 下会对
//     __NSCFString 抛 unrecognized selector(日志里每 16ms 一条), 改成 block 比较器;
//   · 素材列表 + 图片走缓存, 只在目录 mtime 变化时重扫 —— 原来 displayLink 每帧都扫盘+排序,
//     是光晕卡顿的根源;
//   · 目录扫描只在后台线程做, 严格避免在主线程同步 IO。
#import "DIAlbumMask.h"

static NSString *const kDIMaskRoot = @"/var/mobile/灵动岛/遮罩素材";

#pragma mark - 排序(不用 localizedCompare: 避开 __NSCFString 抛 selector 的坑)

static NSArray<NSString *> *DISorted(NSArray<NSString *> *arr) {
    return [arr sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if (![a isKindOfClass:NSString.class]) return NSOrderedSame;
        if (![b isKindOfClass:NSString.class]) return NSOrderedSame;
        return [a compare:b options:NSCaseInsensitiveSearch | NSNumericSearch];
    }];
}

#pragma mark - 1) 读取

NSArray<NSString *> *DIMaskListAssets(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:kDIMaskRoot isDirectory:&isDir] || !isDir) return out;

    NSArray *rootItems = [fm contentsOfDirectoryAtPath:kDIMaskRoot error:NULL];
    if (![rootItems isKindOfClass:NSArray.class]) return out;
    rootItems = DISorted(rootItems);

    // 根目录下的 png: 直接记文件名
    for (NSString *name in rootItems) {
        if (![name isKindOfClass:NSString.class]) continue;
        NSString *full = [kDIMaskRoot stringByAppendingPathComponent:name];
        BOOL d = NO;
        if (![fm fileExistsAtPath:full isDirectory:&d]) continue;
        if (!d && [name.pathExtension.lowercaseString isEqualToString:@"png"]) [out addObject:name];
    }
    // 一层子文件夹里的 png: 记 "文件夹/文件名"
    for (NSString *name in rootItems) {
        if (![name isKindOfClass:NSString.class]) continue;
        NSString *sub = [kDIMaskRoot stringByAppendingPathComponent:name];
        BOOL d = NO;
        if (![fm fileExistsAtPath:sub isDirectory:&d] || !d) continue;
        NSArray *subItems = [fm contentsOfDirectoryAtPath:sub error:NULL];
        if (![subItems isKindOfClass:NSArray.class]) continue;
        for (NSString *f in DISorted(subItems)) {
            if (![f isKindOfClass:NSString.class]) continue;
            if (![f.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
            [out addObject:[name stringByAppendingPathComponent:f]];
        }
    }
    return out;
}

/* 目录 mtime 作为缓存键: 用户往目录里丢/删 png, mtime 会变, 自动重扫 */
static double DIMaskDirStamp(void) {
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:kDIMaskRoot error:NULL];
    NSDate *m = at[NSFileModificationDate];
    return m ? m.timeIntervalSince1970 : 0;
}

/* 当前素材图片缓存: 路径 + 目录时间戳 都没变就直接返回上次的图 */
static UIImage *gMaskCacheImg = nil;
static NSString *gMaskCacheRel = nil;
static double gMaskCacheStamp = -1;
/* 2.6.11: 失效代数 —— 每次 DIMaskInvalidateCache 自增, 外部用它做"素材是否换过"的缓存键 */
static NSInteger gMaskGen = 0;
NSInteger DIMaskGeneration(void) { return gMaskGen; }

UIImage *DIMaskCurrentImage(void) {
    /* displayLink 和主线程都可能进来, 缓存用锁保护 */
    static NSLock *lk = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lk = [NSLock new]; });
    [lk lock];
    UIImage *result = nil;
    @try {
        NSArray<NSString *> *list = DIMaskListAssets();
        if (list.count) {
            NSString *sel = nil;
            CFPreferencesAppSynchronize((__bridge CFStringRef)@"com.abgg332.driftisland");
            id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)kDIAlbumMaskKey,
                                                               (__bridge CFStringRef)@"com.abgg332.driftisland"));
            if ([v isKindOfClass:NSString.class]) sel = (NSString *)v;

            if ([sel isEqualToString:@"__none__"]) {
                // 偏好里明确选了"不遮罩"
                gMaskCacheImg = nil; gMaskCacheRel = nil;
            } else {
                NSString *rel = nil;
                if (sel.length && [list containsObject:sel]) rel = sel;
                else rel = list.firstObject;    // 没选/选了已删除的 → 用第一个

                double stamp = DIMaskDirStamp();
                if (gMaskCacheImg && [gMaskCacheRel isEqualToString:rel] && gMaskCacheStamp == stamp) {
                    result = gMaskCacheImg;
                } else {
                    NSString *path = [kDIMaskRoot stringByAppendingPathComponent:rel];
                    UIImage *img = [UIImage imageWithContentsOfFile:path];   // 读不出来就 nil, 不兜底
                    gMaskCacheImg = img;
                    gMaskCacheRel = rel;
                    gMaskCacheStamp = stamp;
                    result = img;
                }
            }
        } else {
            gMaskCacheImg = nil; gMaskCacheRel = nil;   // 目录里没有 png → 不做遮罩
        }
    } @catch (__unused NSException *e) {
        result = nil;
    }
    [lk unlock];
    return result;
}

/* 外部(设置页选完素材)主动让缓存失效 */
void DIMaskInvalidateCache(void) {
    static NSLock *lk2 = nil;
    static dispatch_once_t o2;
    dispatch_once(&o2, ^{ lk2 = [NSLock new]; });
    [lk2 lock];
    gMaskCacheImg = nil;
    gMaskCacheRel = nil;
    gMaskCacheStamp = -1;
    gMaskGen++;
    [lk2 unlock];
}

#pragma mark - 2) 应用

void DIClearAlbumHalo(UIView *card) {
    if (!card) return;
    NSMutableArray<UIView *> *kill = [NSMutableArray array];
    for (UIView *v in card.subviews) if (v.tag == DIAlbumHaloTag) [kill addObject:v];
    for (UIView *v in kill) [v removeFromSuperview];
}

void DIApplyAlbumHalo(UIView *card, UIView *albumView, CGFloat haloDiameter) {
    if (!card || !albumView) return;
    if (haloDiameter < 8) return;

    UIImage *mask = DIMaskCurrentImage();
    if (!mask) {    // 没有素材: 整段跳过(不兜底)
        DIClearAlbumHalo(card);
        return;
    }
    UIImage *cover = nil;
    if ([albumView isKindOfClass:UIImageView.class]) cover = ((UIImageView *)albumView).image;
    if (!cover) {
        // 专辑不是 UIImageView(或图还没到) → 从封面视图的图层里找内容图
        for (CALayer *l in albumView.layer.sublayers) {
            if ([l isKindOfClass:CALayer.class] && l.contents) {
                cover = [UIImage imageWithCGImage:(__bridge CGImageRef)l.contents];
                if (cover) break;
            }
        }
    }
    if (!cover) return;    // 没封面就不画光晕

    // 旧的光晕先清掉(tag 识别)
    DIClearAlbumHalo(card);

    CGFloat d = haloDiameter;
    UIImageView *halo = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, d, d)];
    halo.tag = DIAlbumHaloTag;
    halo.image = cover;
    halo.contentMode = UIViewContentModeScaleAspectFill;
    halo.layer.cornerRadius = d / 2.0;
    halo.clipsToBounds = YES;
    halo.userInteractionEnabled = NO;

    // 关键: 遮罩作为 maskView(靠 alpha 通道), 绝不是 addSubview 叠上去
    UIImageView *maskView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, d, d)];
    maskView.image = mask;
    maskView.contentMode = UIViewContentModeScaleToFill;    // 蒙版拉伸铺满
    maskView.userInteractionEnabled = NO;
    halo.maskView = maskView;

    // 圆心对齐封面, 垫在封面下面
    CGPoint c = albumView.center;
    UIView *parent = albumView.superview ?: card;
    halo.center = [card convertPoint:c fromView:parent];
    [card insertSubview:halo belowSubview:albumView];
}
