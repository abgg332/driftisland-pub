#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>

static NSString *const kDomain = @"com.abgg332.driftisland";
static NSString *const kNotifyStr = @"com.abgg332.driftisland.reload";
static NSString *const kMaterialDir = @"/var/mobile/灵动岛";
static NSString *const kFrameDir = @"/var/mobile/灵动岛/帧率素材";

static NSArray<NSString *> *videoFiles(void) {
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kMaterialDir error:NULL] ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *f in files) {
        NSString *ext = f.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [ext isEqualToString:@"m4v"])
            [out addObject:f];
    }
    [out sortUsingSelector:@selector(localizedCompare:)];
    return out;
}

/* matMode: 0=小岛素材 1=展开素材 */
static NSInteger indexForKey(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    if (v) return [v integerValue];
    if (![key isEqualToString:@"videoIndex"]) { /* 兼容旧版单素材键 */ }
    id legacy = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("videoIndex"), (__bridge CFStringRef)kDomain));
    NSInteger idx = legacy ? [legacy integerValue] : 0;
    NSInteger cnt = (NSInteger)videoFiles().count;
    if (cnt == 0) return -1;
    if (idx < 0 || idx >= cnt) return 0;
    return idx;
}

static void postReload(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kNotifyStr, NULL, NULL, YES);
}

@interface DIMaterialsController : PSListController
- (NSInteger)matMode; /* 0=小岛 1=展开 */
@end

@interface DIMaterialsSmall : DIMaterialsController @end
@interface DIMaterialsExpand : DIMaterialsController @end
@interface DIFrameFolders : PSListController @end

@interface DIPrefsController : PSListController {
    NSInteger _smallRow; /* 小岛素材选择 行号 */
    NSInteger _expandRow; /* 展开素材选择 行号 */
}
@end

static BOOL diGridPicked = NO; // 网格选中标记: 主页据此刷新按钮标题
@class DIPreviewGrid;

static void diPrefsReloadCB(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    if (!diGridPicked) return;
    diGridPicked = NO;
    id self_ = (__bridge id)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self_ respondsToSelector:@selector(reloadSpecifiers)]) [(id)self_ reloadSpecifiers]; // 刷新"素材选择 (9.mp4)"按钮标题
    });
}

@implementation DIPrefsController

- (instancetype)init {
    if ((self = [super init])) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self,
            diPrefsReloadCB, (__bridge CFStringRef)kNotifyStr, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    return self;
}
- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self);
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key) return nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return v ?: [spec propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key.length) return;
    NSDictionary *range = [spec propertyForKey:@"range"];
    if (range) { // 数值键: 取整+clamp
        double v = [value doubleValue];
        double mn = [range[@"min"] doubleValue], mx = [range[@"max"] doubleValue];
        if (v < mn) v = mn; if (v > mx) v = mx;
        value = @(round(v));
    }
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
    if ([key isEqualToString:@"spectrumOn"] || [key isEqualToString:@"materialOn"]) { // 开关切换: 立即增删下方参数行
        _specifiers = nil;
        [self reloadSpecifiers];
    } else if (range) {
        [self scheduleSync]; // 数值改动: 稍后刷新标题里的数字
    }
}

/* 素材选择行右侧显示的当前素材名 */
- (NSString *)nameForMode:(NSInteger)mode {
    NSString *key = (mode == 0) ? @"smallIndex" : @"expandIndex";
    NSInteger idx = indexForKey(key);
    if (idx < 0) return @"无素材";
    return videoFiles()[idx];
}

/* 频谱行右侧: 当前素材文件夹名 */
- (NSString *)frameStatusName {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("animFolder"), (__bridge CFStringRef)kDomain));
    if ([v isKindOfClass:NSString.class] && [(NSString *)v length]) return v;
    return @"默认(全部帧)";
}

- (id)readSmallVideoName:(PSSpecifier *)spec { return [self nameForMode:0]; }
- (id)readExpandVideoName:(PSSpecifier *)spec { return [self nameForMode:1]; }
- (id)readSpectrumName:(PSSpecifier *)spec { return [self frameStatusName]; }

- (PSSpecifier *)switchSpec:(NSString *)name key:(NSString *)key def:(id)def {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSwitchCell edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:kDomain forKey:@"defaults"];
    [s setProperty:def forKey:@"default"];
    return s;
}

- (PSSpecifier *)groupSpec:(NSString *)header footer:(NSString *)footer {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:header target:nil
        set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
    if (footer) [s setProperty:footer forKey:@"footerText"];
    return s;
}

/* 数值行: 标题=文字+当前整数(如"帧率速度 60"), 滑杆改动后刷新标题; 保存取整并clamp */
- (int)numValue:(NSString *)key def:(int)def {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return v ? (int)round([v doubleValue]) : def;
}

- (PSSpecifier *)numSlider:(NSString *)label key:(NSString *)key def:(int)def mn:(int)mn mx:(int)mx {
    int v = [self numValue:key def:def];
    if (v < mn) v = mn; if (v > mx) v = mx;
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"%@  %d", label, v]
        target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSliderCell edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:kDomain forKey:@"defaults"];
    [s setProperty:@(def) forKey:@"default"];
    [s setProperty:@(mn) forKey:@"min"];
    [s setProperty:@(mx) forKey:@"max"];
    [s setProperty:@{ @"min": @(mn), @"max": @(mx), @"label": label } forKey:@"range"];
    return s;
}

- (void)scheduleSync {
    static NSTimer *t = nil;
    [t invalidate];
    t = [NSTimer scheduledTimerWithTimeInterval:0.6 target:self selector:@selector(doSync)
        userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}

- (void)doSync {
    [self reloadSpecifiers]; // 重建后标题带上最新数值
}

- (PSSpecifier *)buttonSpec:(NSString *)name action:(SEL)sel {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
    [s setButtonAction:sel];
    return s;
}

/* 素材选择行: 左标题、右当前素材名(箭头位置), 点击进入二级页面 */
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        [specs addObject:[self groupSpec:@"漂流岛 · 灵动岛视频背景" footer:nil]];
        [specs addObject:[self switchSpec:@"总开关" key:@"enabled" def:@NO]];
        [specs addObject:[self switchSpec:@"隐藏小岛" key:@"hideNoMusic" def:@NO]]; // 开=没放音乐时小岛不显示视频
        /* 小岛素材: 开关 + 素材选择按钮(点击直接弹出平铺预览, 不进二级页) */
        [specs addObject:[self groupSpec:@"小岛素材" footer:nil]];
        PSSpecifier *smallMat = [self buttonSpec:@"素材选择" action:@selector(openSmallGrid:)];
        [specs addObject:[self switchSpec:@"小岛显示素材" key:@"smallOn" def:@YES]];
        [specs addObject:smallMat];

        /* 展开素材: 开关 + 素材选择按钮 */
        [specs addObject:[self groupSpec:@"展开素材" footer:nil]];
        PSSpecifier *expandMat = [self buttonSpec:@"素材选择" action:@selector(openExpandGrid:)];
        [specs addObject:[self switchSpec:@"展开显示素材" key:@"expandOn" def:@YES]];
        [specs addObject:expandMat];

        /* 帧(音频)率组: 音频开关=右上角原生音频动态(关=显示 开=隐藏); 帧率开关=序列帧素材(立即生效) */
        [specs addObject:[self groupSpec:@"帧率" footer:nil]];
        [specs addObject:[self switchSpec:@"音频开关" key:@"spectrumOn" def:@NO]];
        [specs addObject:[self switchSpec:@"帧率开关" key:@"materialOn" def:@YES]];
        if ([[self readPreferenceValue:[self switchSpec:@"materialOn" key:@"materialOn" def:@YES]] boolValue]) {
            [specs addObject:[self numSlider:@"帧率速度" key:@"animFPS" def:50 mn:10 mx:200]];
            [specs addObject:[self numSlider:@"素材大小" key:@"animScaleAdj" def:0 mn:-20 mx:20]];
            [specs addObject:[self numSlider:@"左右偏移" key:@"animOffsetX3" def:0 mn:-50 mx:50]];
            [specs addObject:[self numSlider:@"上下偏移" key:@"animOffsetY3" def:0 mn:-50 mx:50]];
            PSSpecifier *animSet = [PSSpecifier preferenceSpecifierNamed:@"素材名称" target:self
                set:NULL get:@selector(readSpectrumName:)
                detail:[DIFrameFolders class] cell:PSLinkCell edit:nil];
            [animSet setProperty:[self frameStatusName] forKey:@"value"];
            [specs addObject:animSet];
        }
        _smallRow = _expandRow = -1;
        NSInteger n = 0;
        for (PSSpecifier *s in specs) {
            if (s.cellType == PSGroupCell) continue;
            if (s == smallMat) _smallRow = n;
            if (s == expandMat) _expandRow = n;
            n++;
        }

        [specs addObject:[self groupSpec:@"工具" footer:@"视频素材目录: /var/mobile/灵动岛\n频谱帧率素材目录: /var/mobile/灵动岛/帧率素材"]];
        [specs addObject:[self buttonSpec:@"跳转素材目录" action:@selector(openMaterialDir)]];
        [specs addObject:[self buttonSpec:@"跳转帧率目录" action:@selector(openFrameDir)]];

        /* 日志开关放最下面 */
        [specs addObject:[self groupSpec:nil footer:@"日志开关打开后，运行日志自动生成在 /var/mobile/灵动岛/driftisland.log"]];
        [specs addObject:[self switchSpec:@"日志开关" key:@"logging" def:@NO]];

        _specifiers = specs;
    }
    return _specifiers;
}

- (void)reloadSpecifiers {
    _specifiers = nil;
    [super reloadSpecifiers];
}

/* 强制在箭头位置显示当前素材名（valueLabel / detailTextLabel 双保险） */
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    /* 仅当父类真的实现了该回调时才转发，避免 unrecognized selector 闪退 */
    if ([[self superclass] instancesRespondToSelector:@selector(tableView:willDisplayCell:forRowAtIndexPath:)])
        ((void (*)(struct objc_super *, SEL, UITableView *, UITableViewCell *, NSIndexPath *))objc_msgSendSuper)(
            (struct objc_super *)&(struct objc_super){ .receiver = self, .super_class = class_getSuperclass(object_getClass(self)) },
            @selector(tableView:willDisplayCell:forRowAtIndexPath:), tableView, cell, indexPath);
    /* 注意: PSGroupCell 是 section header 不占行, indexPath.row 是组内行号:
       section1(小岛): row0=开关 row1=素材; section2(展开): row1=素材;
       section3(帧率): row0=音频开关 row1=帧率开关 row2~5=滑杆 row6=素材名称 */
    /* 帧率参数滑杆行(section3 row2~5): 文字(左) + 滑杆(中) + 数值(右), 自绘布局 */
    if (indexPath.section == 3 && indexPath.row >= 2 && indexPath.row <= 5) {
        NSArray *labels = @[@"帧率速度", @"素材大小", @"左右偏移", @"上下偏移"];
        NSArray *keys   = @[@"animFPS", @"animScaleAdj", @"animOffsetX3", @"animOffsetY3"];
        NSArray *defs   = @[@50, @0, @0, @0];
        NSArray *mins   = @[@10, @-20, @-50, @-50];
        NSArray *maxs   = @[@200, @20, @50, @50];
        NSInteger i = indexPath.row - 2;
        int v = [self numValue:keys[i] def:[defs[i] intValue]];
        if (v < [mins[i] intValue]) v = [mins[i] intValue];
        if (v > [maxs[i] intValue]) v = [maxs[i] intValue];

        cell.textLabel.text = labels[i];
        cell.textLabel.font = [UIFont systemFontOfSize:15];

        /* 隐藏系统滑杆(它不渲染标题且铺满整行) */
        UIView *root = cell.contentView.subviews.count ? cell.contentView : cell;
        for (UIView *sv in root.subviews) if ([sv isKindOfClass:UISlider.class]) sv.hidden = YES;
        for (UIView *sv in cell.subviews) if ([sv isKindOfClass:UISlider.class]) sv.hidden = YES;

        CGFloat cw = cell.contentView.bounds.size.width, ch = cell.contentView.bounds.size.height;
        UIView *box = objc_getAssociatedObject(cell, "diBox");
        if (!box) {
            box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cw, ch)];
            box.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            UISlider *sl = [UISlider new];
            sl.minimumTrackTintColor = [UIColor systemBlueColor];
            [sl addTarget:self action:@selector(diSliderChanged:) forControlEvents:UIControlEventValueChanged];
            UILabel *vl = [UILabel new];
            vl.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightRegular];
            vl.textAlignment = NSTextAlignmentRight;
            vl.userInteractionEnabled = YES;
            vl.textColor = [UIColor systemBlueColor]; // 提示可点击输入
            [vl addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(diTapValue:)]];
            [box addSubview:sl];
            [box addSubview:vl];
            [cell.contentView addSubview:box];
            objc_setAssociatedObject(cell, "diBox", box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(box, "slider", sl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(box, "valLabel", vl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(box, "key", keys[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(box, "label", labels[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(box, "mn", mins[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(box, "mx", maxs[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        box.frame = CGRectMake(0, 0, cw, ch);
        UISlider *sl = objc_getAssociatedObject(box, "slider");
        UILabel *vl = objc_getAssociatedObject(box, "valLabel");
        sl.frame = CGRectMake(cw * 0.30, (ch - 31) / 2, cw * 0.38, 31);
        sl.minimumValue = [mins[i] intValue]; sl.maximumValue = [maxs[i] intValue];
        if ((int)round(sl.value) != v) sl.value = v; // 不在拖动中才校准
        vl.text = [NSString stringWithFormat:@"%d", v];
        vl.frame = CGRectMake(cw * 0.70, (ch - 24) / 2, cw * 0.18, 24);
        box.hidden = NO;
    }

    NSString *name = nil;
    if (indexPath.section == 1 && indexPath.row == 1) name = [self nameForMode:0];
    if (indexPath.section == 2 && indexPath.row == 1) name = [self nameForMode:1];
    if (indexPath.section == 3 && indexPath.row == 6) name = [self frameStatusName];
    if (name) {
        if ([cell respondsToSelector:@selector(setValue:)])
            ((void (*)(id, SEL, id))objc_msgSend)(cell, @selector(setValue:), name);
        if ([cell respondsToSelector:@selector(valueLabel)]) {
            UILabel *vl = ((id (*)(id, SEL))objc_msgSend)(cell, @selector(valueLabel));
            if (vl) { vl.text = name; vl.textColor = [UIColor secondaryLabelColor]; }
        }
        if (cell.detailTextLabel) cell.detailTextLabel.text = name;
    }
}

/* 自绘滑杆拖动: 实时保存(取整+clamp) + 实时刷新数值 */
- (void)diSliderChanged:(UISlider *)sl {
    UIView *box = sl.superview;
    NSString *key = objc_getAssociatedObject(box, "key");
    double v = round(sl.value);
    double mn = [objc_getAssociatedObject(box, "mn") doubleValue];
    double mx = [objc_getAssociatedObject(box, "mx") doubleValue];
    if (v < mn) v = mn; if (v > mx) v = mx;
    if (sl.value != v) sl.value = v;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(v), (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
    UILabel *vl = objc_getAssociatedObject(box, "valLabel");
    vl.text = [NSString stringWithFormat:@"%d", (int)v];
    /* 同步行标题? 标题只有文字, 数字在右侧已实时刷新 */
}

/* 点击右侧数值: 弹框手动输入精确值(取整+clamp) */
- (void)diTapValue:(UITapGestureRecognizer *)tap {
    UIView *box = tap.view.superview;
    NSString *key = objc_getAssociatedObject(box, "key");
    NSString *label = objc_getAssociatedObject(box, "label");
    double mn = [objc_getAssociatedObject(box, "mn") doubleValue];
    double mx = [objc_getAssociatedObject(box, "mx") doubleValue];
    UILabel *vl = objc_getAssociatedObject(box, "valLabel");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:label
        message:[NSString stringWithFormat:@"范围 %.0f ~ %.0f", mn, mx]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = vl.text;
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        double v = round([alert.textFields.firstObject.text doubleValue]);
        if (v < mn) v = mn; if (v > mx) v = mx;
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(v), (__bridge CFStringRef)kDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        postReload();
        vl.text = [NSString stringWithFormat:@"%d", (int)v];
        UISlider *sl = objc_getAssociatedObject(box, "slider");
        if (sl && (int)round(sl.value) != (int)v) sl.value = v; // 滑杆同步
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/* Filza 官方 URL 格式: filza://view/路径 或 filza://路径（见 tigisoftware 官方指南），中文路径严格百分号编码 */
- (void)openDirWithConfirm:(NSString *)dir title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:nil // 只留标题一行, 不放路径文字
        preferredStyle:UIAlertControllerStyleAlert]; // 二次确认防误触
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"跳转" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self openDir:dir]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openMaterialDir {
    [self openDirWithConfirm:kMaterialDir title:@"跳转素材目录"];
}

- (void)openFrameDir {
    [self openDirWithConfirm:kFrameDir title:@"跳转帧率目录"];
}

- (void)openDir:(NSString *)dir {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"];
    NSString *enc = [dir stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"filza://view%@", enc]];
    if (!url) url = [NSURL URLWithString:[NSString stringWithFormat:@"filza://%@", enc]];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end

@implementation DIMaterialsController
- (NSInteger)matMode { return 0; }
@end

@implementation DIMaterialsSmall
- (NSInteger)matMode { return 0; }
@end

@implementation DIMaterialsExpand
- (NSInteger)matMode { return 1; }
@end

@implementation DIFrameFolders

- (void)saveFolder:(NSString *)name {
    CFPreferencesSetAppValue(CFSTR("animFolder"), (__bridge CFPropertyListRef)name, (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kNotifyStr, NULL, NULL, YES);
}

- (NSArray<NSString *> *)folders {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *out = [NSMutableArray array];
    BOOL hasDirectFrame = NO;
    for (NSString *n in [fm contentsOfDirectoryAtPath:kFrameDir error:NULL]) {
        NSString *p = [kFrameDir stringByAppendingPathComponent:n];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&isDir]) continue;
        if (isDir) [out addObject:n];
        else {
            NSString *ext = n.pathExtension.lowercaseString;
            if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) hasDirectFrame = YES;
        }
    }
    [out sortUsingSelector:@selector(localizedCompare:)];
    if (hasDirectFrame || out.count == 0) [out insertObject:@"默认(全部帧)" atIndex:0];
    return out;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *g = [PSSpecifier preferenceSpecifierNamed:@"选择素材" target:nil
            set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
        [g setProperty:@"点击选择帧率素材文件夹。素材目录: /var/mobile/灵动岛/帧率素材" forKey:@"footerText"];
        [specs addObject:g];
        NSString *cur = nil;
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("animFolder"), (__bridge CFStringRef)kDomain));
        if ([v isKindOfClass:NSString.class]) cur = v;
        for (NSString *f in [self folders]) {
            BOOL isCur = cur ? [f isEqualToString:cur] : [f isEqualToString:@"默认(全部帧)"];
            NSString *label = isCur ? [NSString stringWithFormat:@"✓ %@", f] : f;
            PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label target:self
                set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
            [s setButtonAction:@selector(pick:)];
            [s setProperty:f forKey:@"folder"];
            [specs addObject:s];
        }
        _specifiers = specs;
    }
    return _specifiers;
}

- (void)pick:(PSSpecifier *)spec {
    NSString *f = [spec propertyForKey:@"folder"];
    [self saveFolder:[f isEqualToString:@"默认(全部帧)"] ? nil : f];
    NSArray *vcs = self.navigationController.viewControllers;
    UIViewController *parent = (vcs.count >= 2) ? vcs[vcs.count - 2] : nil;
    [self.navigationController popViewControllerAnimated:YES];
    if ([parent respondsToSelector:@selector(reloadSpecifiers)])
        [(id)parent performSelector:@selector(reloadSpecifiers)];
}

- (void)reloadSpecifiers {
    _specifiers = nil;
    [super reloadSpecifiers];
}

@end

#pragma mark - 素材预览网格

static NSCache *diThumbCache(void) {
    static NSCache *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [NSCache new]; c.countLimit = 60; });
    return c;
}

@interface DIPreviewCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iv;
@property (nonatomic, strong) UILabel *lb;
@end
@implementation DIPreviewCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _iv = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height - 20)];
        _iv.contentMode = UIViewContentModeScaleAspectFill;
        _iv.clipsToBounds = YES;
        _iv.layer.cornerRadius = 12;
        _iv.backgroundColor = [UIColor tertiarySystemFillColor];
        _iv.translatesAutoresizingMaskIntoConstraints = NO;
        _lb = [[UILabel alloc] initWithFrame:CGRectZero];
        _lb.font = [UIFont systemFontOfSize:11];
        _lb.textAlignment = NSTextAlignmentCenter;
        _lb.textColor = [UIColor secondaryLabelColor];
        _lb.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_iv];
        [self.contentView addSubview:_lb];
        [NSLayoutConstraint activateConstraints:@[
            [_iv.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_iv.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_iv.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_iv.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-20],
            [_lb.topAnchor constraintEqualToAnchor:_iv.bottomAnchor constant:2],
            [_lb.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_lb.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        ]];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = 0;
    if (self.highlighted) self.contentView.alpha = 0.6; else self.contentView.alpha = 1;
}
@end

@interface DIPreviewGrid : UICollectionViewController
@property (nonatomic, assign) NSInteger matMode; /* 0=小岛 1=展开 */
@end

@implementation DIPreviewGrid
- (instancetype)init {
    UICollectionViewFlowLayout *fl = [UICollectionViewFlowLayout new];
    CGFloat w = [UIScreen mainScreen].bounds.size.width - 32;
    fl.itemSize = CGSizeMake((w - 12) / 3, (w - 12) / 3 * 0.72 + 22);
    fl.minimumInteritemSpacing = 6;
    fl.minimumLineSpacing = 14;
    fl.sectionInset = UIEdgeInsetsMake(12, 16, 24, 16);
    return [super initWithCollectionViewLayout:fl];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = (self.matMode == 0) ? @"小岛素材" : @"展开素材";
    self.collectionView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self.collectionView registerClass:[DIPreviewCell class] forCellWithReuseIdentifier:@"cell"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"相册导入" style:UIBarButtonItemStylePlain target:self action:@selector(importFromAlbum)]; // 右上角关闭改为相册导入
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(close)]; // 关闭挪到左侧, 保留退出途径
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressDelete:)]; // 长按删除素材
    [self.collectionView addGestureRecognizer:lp];
}
/* 长按视频缩略图 → 确认后删除该素材文件; 若删的是当前选中项, 选中归零并通知岛重载 */
- (void)longPressDelete:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [gr locationInView:self.collectionView];
    NSIndexPath *ip = [self.collectionView indexPathForItemAtPoint:p];
    if (!ip || ip.item >= (NSInteger)videoFiles().count) return;
    NSString *name = videoFiles()[ip.item];
    NSString *path = [kMaterialDir stringByAppendingPathComponent:name];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除素材"
        message:[NSString stringWithFormat:@"确定删除 \"%@\" 吗?\n此操作不可恢复", name]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        NSString *key = (self.matMode == 0) ? @"smallIndex" : @"expandIndex";
        id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
        if (v && [v integerValue] == (NSInteger)ip.item) { // 删的是当前选中项 → 归零并刷新岛
            CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@0, (__bridge CFStringRef)kDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
            postReload();
        }
        [self.collectionView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)currentIndex {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)(self.matMode == 0 ? @"smallIndex" : @"expandIndex"), (__bridge CFStringRef)kDomain));
    return v ? [v integerValue] : 0;
}
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)videoFiles().count;
}
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    DIPreviewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:ip];
    NSString *name = videoFiles()[ip.item];
    cell.lb.text = name;
    cell.lb.textColor = (ip.item == [self currentIndex]) ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];
    cell.iv.layer.borderWidth = (ip.item == [self currentIndex]) ? 2 : 0;
    cell.iv.layer.borderColor = [UIColor systemBlueColor].CGColor;
    UIImage *thumb = [diThumbCache() objectForKey:name];
    if (thumb) { cell.iv.image = thumb; }
    else {
        cell.iv.image = nil;
        __weak DIPreviewCell *wc = cell;
        __weak UICollectionView *wcv = cv;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[kMaterialDir stringByAppendingPathComponent:name]] options:nil];
            AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
            gen.appliesPreferredTrackTransform = YES;
            gen.maximumSize = CGSizeMake(360, 360);
            NSError *err = nil;
            CGImageRef img = [gen copyCGImageAtTime:CMTimeMake(5, 10) actualTime:NULL error:&err];
            if (img) {
                UIImage *ui = [UIImage imageWithCGImage:img];
                CGImageRelease(img);
                [diThumbCache() setObject:ui forKey:name];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([wc.lb.text isEqualToString:name]) wc.iv.image = ui;
                    [wcv reloadItemsAtIndexPaths:@[ip]];
                });
            }
        });
    }
    return cell;
}
- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    NSString *key = (self.matMode == 0) ? @"smallIndex" : @"expandIndex";
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(ip.item), (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    diGridPicked = YES;
    postReload();
    [self close]; // 选完自动关闭预览
}
@end

@implementation DIMaterialsController (Internal)

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        NSInteger cnt = (NSInteger)videoFiles().count;
        (void)cnt;
        NSString *title = (self.matMode == 0) ? @"小岛素材" : @"展开素材";
        [specs addObject:[self groupSpec:title footer:@"进入本页会自动弹出预览网格; 点选封面即生效。素材目录: /var/mobile/灵动岛"]];
        PSSpecifier *btn = [PSSpecifier preferenceSpecifierNamed:@"重新打开预览" target:self
            set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
        [btn setButtonAction:@selector(openGrid:)];
        [specs addObject:btn];
        _specifiers = specs;
    }
    return _specifiers;
}

- (PSSpecifier *)groupSpec:(NSString *)header footer:(NSString *)footer {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:header target:nil
        set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
    if (footer) [s setProperty:footer forKey:@"footerText"];
    return s;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    objc_setAssociatedObject(self, "diShown", @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // 每次进入重置, 自动弹出预览
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if ([objc_getAssociatedObject(self, "diShown") boolValue]) return;
    objc_setAssociatedObject(self, "diShown", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    DIPreviewGrid *g = [[DIPreviewGrid alloc] init];
    g.matMode = self.matMode;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:g];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil]; // 进入页面立即弹出平铺预览(模态弹窗不动 PSListController 视图结构, 不会闪退)
}

- (void)reloadSpecifiers {
    _specifiers = nil;
    [super reloadSpecifiers];
}

@end

/* 点击"素材选择"直接弹出平铺预览网格(不进二级页) */
@implementation DIPrefsController (Grid)
- (void)presentGridMode:(NSInteger)mode {
    DIPreviewGrid *g = [[DIPreviewGrid alloc] init];
    g.matMode = mode;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:g];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)openSmallGrid:(PSSpecifier *)s { [self presentGridMode:0]; }
- (void)openExpandGrid:(PSSpecifier *)s { [self presentGridMode:1]; }

/* 相册素材导入: PHPicker(系统相册选择器, 无需相册权限)选视频, 拷入素材目录 */
- (void)importFromAlbum {
    Class phpPicker = NSClassFromString(@"PHPickerViewController");
    Class phpCfg = NSClassFromString(@"PHPickerConfiguration");
    if (!phpPicker || !phpCfg) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"相册导入" message:@"当前系统不可用(PHPicker 需要 iOS 14+)" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    id cfg = [[phpCfg alloc] init];
    Class f = NSClassFromString(@"PHPickerFilter");
    if ([cfg respondsToSelector:@selector(setFilter:)] && [f respondsToSelector:@selector(videosFilter)])
        [cfg performSelector:@selector(setFilter:) withObject:((id (*)(id, SEL))objc_msgSend)(f, @selector(videosFilter))]; // 只显示视频
    if ([cfg respondsToSelector:@selector(setSelectionLimit:)])
        [cfg performSelector:@selector(setSelectionLimit:) withObject:@0]; // 0=不限制, 多选多导
    id p = [[phpPicker alloc] initWithConfiguration:cfg];
    if ([p respondsToSelector:@selector(setDelegate:)]) [p performSelector:@selector(setDelegate:) withObject:self];
    [self presentViewController:p animated:YES completion:nil];
}

- (void)picker:(id)picker didFinishPicking:(NSArray *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kMaterialDir withIntermediateDirectories:YES attributes:nil error:nil];
    __block NSInteger okCnt = 0, failCnt = 0;
    __block NSString *firstNew = nil;
    dispatch_group_t grp = dispatch_group_create();
    for (id r in results) {
        id provider = [r valueForKey:@"itemProvider"];
        NSString *sugg = [provider respondsToSelector:@selector(suggestedName)] ? [provider performSelector:@selector(suggestedName)] : nil;
        dispatch_group_enter(grp);
        [provider loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *err) {
            if (url) {
                NSString *ext = url.pathExtension.length ? url.pathExtension : @"mov";
                NSString *base = @"相册导入";
                if (sugg.length) {
                    base = sugg.pathExtension.length ? sugg.stringByDeletingPathExtension : sugg;
                    base = [base stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
                }
                NSString *name = [NSString stringWithFormat:@"%@.%@", base, ext];
                NSString *dst = [kMaterialDir stringByAppendingPathComponent:name];
                NSInteger n = 1;
                while ([fm fileExistsAtPath:dst]) { // 重名自动加序号
                    name = [NSString stringWithFormat:@"%@_%ld.%@", base, (long)n++, ext];
                    dst = [kMaterialDir stringByAppendingPathComponent:name];
                }
                NSError *cpErr = nil;
                if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:&cpErr]) {
                    okCnt++;
                    if (!firstNew) firstNew = name;
                } else failCnt++;
            } else failCnt++;
            dispatch_group_leave(grp);
        }];
    }
    dispatch_group_notify(grp, dispatch_get_main_queue(), ^{
        NSString *msg;
        if (failCnt > 0) msg = [NSString stringWithFormat:@"成功 %ld 个, 失败 %ld 个", (long)okCnt, (long)failCnt];
        else if (okCnt == 1) msg = [NSString stringWithFormat:@"已导入: %@", firstNew];
        else msg = [NSString stringWithFormat:@"已导入 %ld 个素材", (long)okCnt];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"相册素材导入" message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    });
}
@end

/* 素材预览网格页(小岛/展开)的相册导入: 同一套 PHPicker 逻辑, 导入完成后自动刷新网格 */
@implementation DIPreviewGrid (Import)
- (void)importFromAlbum {
    Class phpPicker = NSClassFromString(@"PHPickerViewController");
    Class phpCfg = NSClassFromString(@"PHPickerConfiguration");
    if (!phpPicker || !phpCfg) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"相册导入" message:@"当前系统不可用(PHPicker 需要 iOS 14+)" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    id cfg = [[phpCfg alloc] init];
    Class f = NSClassFromString(@"PHPickerFilter");
    if ([cfg respondsToSelector:@selector(setFilter:)] && [f respondsToSelector:@selector(videosFilter)])
        [cfg performSelector:@selector(setFilter:) withObject:((id (*)(id, SEL))objc_msgSend)(f, @selector(videosFilter))]; // 只显示视频
    if ([cfg respondsToSelector:@selector(setSelectionLimit:)])
        [cfg performSelector:@selector(setSelectionLimit:) withObject:@0]; // 0=不限制, 多选多导
    id p = [[phpPicker alloc] initWithConfiguration:cfg];
    if ([p respondsToSelector:@selector(setDelegate:)]) [p performSelector:@selector(setDelegate:) withObject:self];
    [self presentViewController:p animated:YES completion:nil];
}

- (void)picker:(id)picker didFinishPicking:(NSArray *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kMaterialDir withIntermediateDirectories:YES attributes:nil error:nil];
    __block NSInteger okCnt = 0, failCnt = 0;
    __block NSString *firstNew = nil;
    dispatch_group_t grp = dispatch_group_create();
    for (id r in results) {
        id provider = [r valueForKey:@"itemProvider"];
        NSString *sugg = [provider respondsToSelector:@selector(suggestedName)] ? [provider performSelector:@selector(suggestedName)] : nil;
        dispatch_group_enter(grp);
        [provider loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *err) {
            if (url) {
                NSString *ext = url.pathExtension.length ? url.pathExtension : @"mov";
                NSString *base = @"相册导入";
                if (sugg.length) {
                    base = sugg.pathExtension.length ? sugg.stringByDeletingPathExtension : sugg;
                    base = [base stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
                }
                NSString *name = [NSString stringWithFormat:@"%@.%@", base, ext];
                NSString *dst = [kMaterialDir stringByAppendingPathComponent:name];
                NSInteger n = 1;
                while ([fm fileExistsAtPath:dst]) { // 重名自动加序号
                    name = [NSString stringWithFormat:@"%@_%ld.%@", base, (long)n++, ext];
                    dst = [kMaterialDir stringByAppendingPathComponent:name];
                }
                NSError *cpErr = nil;
                if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:&cpErr]) {
                    okCnt++;
                    if (!firstNew) firstNew = name;
                } else failCnt++;
            } else failCnt++;
            dispatch_group_leave(grp);
        }];
    }
    dispatch_group_notify(grp, dispatch_get_main_queue(), ^{
        NSString *msg;
        if (failCnt > 0) msg = [NSString stringWithFormat:@"成功 %ld 个, 失败 %ld 个", (long)okCnt, (long)failCnt];
        else if (okCnt == 1) msg = [NSString stringWithFormat:@"已导入: %@", firstNew];
        else msg = [NSString stringWithFormat:@"已导入 %ld 个素材", (long)okCnt];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"相册素材导入" message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        [self.collectionView reloadData]; // 网格页导入完立即刷新
    });
}
@end
