// DIAlbumMask.m —— 专辑光晕遮罩
// 三块职责:
//   1) 读取: 扫描 /var/mobile/灵动岛/遮罩素材 (一层递归, 只要 png), 选中项存 diAlbumMaskAsset
//   2) 应用: 封面本体 + 遮罩 png 作为 maskView, 垫在专辑封面下面
//   3) 素材缺失时整段跳过 —— 绝不代码兜底(代码兜底就是黑块的成因)
#import "DIAlbumMask.h"

static NSString *const kDIMaskRoot = @"/var/mobile/灵动岛/遮罩素材";

#pragma mark - 1) 读取

NSArray<NSString *> *DIMaskListAssets(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:kDIMaskRoot isDirectory:&isDir] || !isDir) return out;

    // 根目录下的 png: 直接记文件名
    NSArray<NSString *> *rootItems = [[fm contentsOfDirectoryAtPath:kDIMaskRoot error:NULL]
                                      sortedArrayUsingSelector:@selector(localizedCompare)];
    for (NSString *name in rootItems) {
        NSString *full = [kDIMaskRoot stringByAppendingPathComponent:name];
        BOOL d = NO;
        if (![fm fileExistsAtPath:full isDirectory:&d]) continue;
        if (!d) {
            if ([name.pathExtension.lowercaseString isEqualToString:@"png"]) [out addObject:name];
        }
    }
    // 一层子文件夹里的 png: 记 "文件夹/文件名"
    for (NSString *name in rootItems) {
        NSString *sub = [kDIMaskRoot stringByAppendingPathComponent:name];
        BOOL d = NO;
        if (![fm fileExistsAtPath:sub isDirectory:&d] || !d) continue;
        NSArray *subItems = [[fm contentsOfDirectoryAtPath:sub error:NULL]
                             sortedArrayUsingSelector:@selector(localizedCompare)];
        for (NSString *f in subItems) {
            if (![f.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
            NSString *rel = [name stringByAppendingPathComponent:f];
            [out addObject:rel];
        }
    }
    return out;
}

UIImage *DIMaskCurrentImage(void) {
    NSArray<NSString *> *list = DIMaskListAssets();
    if (!list.count) return nil;    // 目录里没有 png → 这次不做遮罩

    NSString *sel = nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)@"com.abgg332.driftisland");
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)kDIAlbumMaskKey,
                                                       (__bridge CFStringRef)@"com.abgg332.driftisland"));
    if ([v isKindOfClass:NSString.class]) sel = (NSString *)v;

    // 偏好里明确选了"不遮罩" → 返回 nil
    if ([sel isEqualToString:@"__none__"]) return nil;

    NSString *rel = nil;
    if (sel.length && [list containsObject:sel]) rel = sel;
    else rel = list.firstObject;    // 没选/选了已删除的 → 用第一个

    NSString *path = [kDIMaskRoot stringByAppendingPathComponent:rel];
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    return img;    // 读不出来就 nil, 不兜底
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
