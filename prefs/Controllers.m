#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>

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
@interface DIAnimSettings : PSListController @end
@interface DIFrameFolders : PSListController @end

@interface DIPrefsController : PSListController {
    NSInteger _smallRow; /* 小岛素材选择 行号 */
    NSInteger _expandRow; /* 展开素材选择 行号 */
}
@end

@implementation DIPrefsController

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
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
    /* 频谱开关切换: 立即增删下方"帧率动画设置"行 */
    if ([key isEqualToString:@"spectrumOn"]) {
        _specifiers = nil;
        [self reloadSpecifiers];
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
        /* 投送按钮: 隐藏/显示音乐岛右下角的投送(AirPlay)图标 */
        [specs addObject:[self switchSpec:@"投送按钮" key:@"hideAirPlay" def:@NO]];

        /* 小岛素材: 开关 + 素材选择行(同组相邻) */
        [specs addObject:[self groupSpec:@"小岛素材" footer:nil]];
        PSSpecifier *smallMat = [PSSpecifier preferenceSpecifierNamed:@"素材选择" target:self
            set:NULL get:@selector(readSmallVideoName:)
            detail:[DIMaterialsSmall class] cell:PSLinkCell edit:nil];
        [smallMat setProperty:[self nameForMode:0] forKey:@"value"];
        [specs addObject:[self switchSpec:@"小岛显示素材" key:@"smallOn" def:@YES]];
        [specs addObject:smallMat];

        /* 展开素材: 开关 + 素材选择行(同组相邻) */
        [specs addObject:[self groupSpec:@"展开素材" footer:nil]];
        PSSpecifier *expandMat = [PSSpecifier preferenceSpecifierNamed:@"素材选择" target:self
            set:NULL get:@selector(readExpandVideoName:)
            detail:[DIMaterialsExpand class] cell:PSLinkCell edit:nil];
        [expandMat setProperty:[self nameForMode:1] forKey:@"value"];
        [specs addObject:[self switchSpec:@"展开显示素材" key:@"expandOn" def:@YES]];
        [specs addObject:expandMat];

        /* 频谱: 开关 + 素材选择行(开关打开才显示); 关闭=系统频谱, 打开=隐藏频谱+播放序列帧动画 */
        [specs addObject:[self groupSpec:@"频谱" footer:@"关闭时显示系统频谱，打开时用所选素材替换频谱。"]];
        [specs addObject:[self switchSpec:@"频谱开关" key:@"spectrumOn" def:@NO]];
        if ([[self readPreferenceValue:[self switchSpec:@"spectrumOn" key:@"spectrumOn" def:@NO]] boolValue]) {
            PSSpecifier *animSet = [PSSpecifier preferenceSpecifierNamed:@"素材选择" target:self
                set:NULL get:@selector(readSpectrumName:)
                detail:[DIAnimSettings class] cell:PSLinkCell edit:nil];
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

        [specs addObject:[self groupSpec:@"工具" footer:@"视频素材目录: /var/mobile/灵动岛  |  频谱帧率素材目录: /var/mobile/灵动岛/帧率素材 (png/jpg 序列帧, 按文件名数字顺序播放)"]];
        [specs addObject:[self buttonSpec:@"跳转素材目录" action:@selector(openMaterialDir)]];
        [specs addObject:[self buttonSpec:@"跳转帧率素材目录" action:@selector(openFrameDir)]];

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
       section1(小岛): row0=开关 row1=素材; section2(展开): row1=素材; section3(频谱): row1=素材 */
    NSString *name = nil;
    if (indexPath.section == 1 && indexPath.row == 1) name = [self nameForMode:0];
    if (indexPath.section == 2 && indexPath.row == 1) name = [self nameForMode:1];
    if (indexPath.section == 3 && indexPath.row == 1) name = [self frameStatusName];
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

/* Filza 官方 URL 格式: filza://view/路径 或 filza://路径（见 tigisoftware 官方指南），中文路径严格百分号编码 */
- (void)openMaterialDir {
    [self openDir:kMaterialDir];
}

- (void)openFrameDir {
    [self openDir:kFrameDir];
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

#pragma mark - 频谱帧率动画设置页(手写UI: 文字左+滑杆中+数值右, 与素材图逐行一致)

@implementation DIAnimSettings {
    NSMutableDictionary<NSString *, UILabel *> *_labels;
}

- (NSArray *)specifiers { return @[]; } /* 自绘UI, 不用 Preferences 表格 */

- (double)numForKey:(NSString *)key def:(double)def {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return v ? [v doubleValue] : def;
}

- (void)saveNum:(double)v forKey:(NSString *)key {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(v), (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kNotifyStr, NULL, NULL, YES);
}

- (BOOL)boolForKey:(NSString *)key def:(BOOL)def {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return v ? [v boolValue] : def;
}

- (void)saveBool:(BOOL)v forKey:(NSString *)key {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(v), (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kNotifyStr, NULL, NULL, YES);
}

- (void)loadView {
    _labels = [NSMutableDictionary dictionary];
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.backgroundColor = UIColor.systemGroupedBackgroundColor;
    scroll.alwaysBounceVertical = YES;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.view = scroll;
    self.navigationItem.title = @"动画设置";

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    UIView *content = stack;
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    /* —— 与素材图逐行一致 —— */
    [stack addArrangedSubview:[self headerLabel:@"灵动岛动画"]];
    [stack addArrangedSubview:[self cardWithRows:@[
        [self switchRow:@"启用动画" key:@"spectrumOn" def:NO],
    ]]];

    [stack addArrangedSubview:[self headerLabel:@"动画设置"]];
    [stack addArrangedSubview:[self cardWithRows:@[
        [self sliderRow:@"动画帧率" key:@"animFPS" def:50 min:1 max:60],
        [self switchRow:@"启用素材旋转" key:@"animRotate" def:NO],
        [self switchRow:@"素材旋转反转" key:@"animRotateReverse" def:NO],
        [self sliderRow:@"旋转速度" key:@"animRotateSpeed" def:5 min:1 max:30],
    ]]];

    [stack addArrangedSubview:[self headerLabel:@"位置缩放设置"]];
    [stack addArrangedSubview:[self cardWithRows:@[
        [self sliderRow:@"缩放倍数" key:@"animScale" def:1 min:0.2 max:3],
        [self sliderRow:@"X偏移" key:@"animOffsetX" def:0 min:-150 max:150],
        [self sliderRow:@"Y偏移" key:@"animOffsetY" def:0 min:-150 max:150],
    ]]];

    [stack addArrangedSubview:[self headerLabel:@"素材设置"]];
    [stack addArrangedSubview:[self cardWithRows:@[
        [self folderRow],
    ]]];
}

- (UILabel *)headerLabel:(NSString *)text {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    l.textColor = UIColor.secondaryLabelColor;
    return l;
}

/* 白色圆角卡片包住若干行 */
- (UIView *)cardWithRows:(NSArray *)rows {
    UIStackView *v = [[UIStackView alloc] init];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 14;
    v.layoutMargins = UIEdgeInsetsMake(14, 16, 14, 16);
    v.isLayoutMarginsRelativeArrangement = YES;
    for (UIView *r in rows) [v addArrangedSubview:r];
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 12;
    [card addSubview:v];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:card.topAnchor],
        [v.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [v.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
    ]];
    return card;
}

/* 行: 文字(左) + 滑杆(中) + 数值(右, 实时刷新) */
- (UIView *)sliderRow:(NSString *)title key:(NSString *)key def:(double)def min:(double)mn max:(double)mx {
    UILabel *name = [UILabel new];
    name.text = title;
    name.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [name setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UISlider *slider = [UISlider new];
    slider.minimumValue = mn;
    slider.maximumValue = mx;
    slider.value = [self numForKey:key def:def];

    UILabel *val = [UILabel new];
    val.text = [NSString stringWithFormat:@"%.2f", slider.value];
    val.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightRegular];
    val.textAlignment = NSTextAlignmentRight;
    [val setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _labels[key] = val;

    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(slider, "key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, slider, val]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 10;
    row.alignment = UIStackViewAlignmentCenter;
    [slider.widthAnchor constraintGreaterThanOrEqualToConstant:110].active = YES;
    return row;
}

- (void)sliderChanged:(UISlider *)slider {
    NSString *key = objc_getAssociatedObject(slider, "key");
    [self saveNum:slider.value forKey:key];
    UILabel *val = _labels[key];
    val.text = [NSString stringWithFormat:@"%.2f", slider.value];
}

/* 行: 文字(左) + 开关(右) */
- (UIView *)switchRow:(NSString *)title key:(NSString *)key def:(BOOL)def {
    UILabel *name = [UILabel new];
    name.text = title;
    name.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];

    UISwitch *sw = [UISwitch new];
    sw.on = [self boolForKey:key def:def];
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(sw, "key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, [[UIView alloc] init], sw]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 10;
    return row;
}

- (void)switchChanged:(UISwitch *)sw {
    NSString *key = objc_getAssociatedObject(sw, "key");
    [self saveBool:sw.on forKey:key];
}

/* 行: 素材名(左) + 当前文件夹(右) + 箭头, 点击进入文件夹选择 */
- (UIView *)folderRow {
    UILabel *name = [UILabel new];
    name.text = @"素材名";
    name.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];

    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("animFolder"), (__bridge CFStringRef)kDomain));
    NSString *cur = ([v isKindOfClass:NSString.class] && [(NSString *)v length]) ? v : @"默认(第一个文件夹)";
    UILabel *val = [UILabel new];
    val.text = cur;
    val.font = [UIFont systemFontOfSize:16];
    val.textColor = UIColor.secondaryLabelColor;

    UILabel *chevron = [UILabel new];
    chevron.text = @"›";
    chevron.font = [UIFont systemFontOfSize:20];
    chevron.textColor = UIColor.tertiaryLabelColor;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.backgroundColor = [UIColor clearColor];
    [btn addTarget:self action:@selector(pushFolders) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, [[UIView alloc] init], val, chevron]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    row.alignment = UIStackViewAlignmentCenter;

    // 全行可点: 透明按钮盖在整行上
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:btn];
    [NSLayoutConstraint activateConstraints:@[
        [btn.topAnchor constraintEqualToAnchor:row.topAnchor],
        [btn.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [btn.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [btn.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
    ]];
    return row;
}

- (void)pushFolders {
    [self.navigationController pushViewController:[[DIFrameFolders alloc] init] animated:YES];
}

@end

#pragma mark - 素材文件夹选择(帧率素材目录下的全部子文件夹)

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

@implementation DIMaterialsController (Internal)

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        NSInteger cnt = (NSInteger)videoFiles().count;
        NSString *title = (self.matMode == 0) ? @"选择小岛素材" : (self.matMode == 1) ? @"选择展开素材" : @"选择频谱素材";
        if (cnt == 0) {
            [specs addObject:[self groupSpec:@"素材目录为空" footer:@"请把视频 (mp4/mov/m4v) 放进 /var/mobile/灵动岛，然后重新进入本页。"]];
        } else {
            [specs addObject:[self groupSpec:title footer:@"文件夹里有几个视频就显示几个（原文件名），点击哪个生效哪个。"]];
            NSInteger cur = indexForKey(self.matMode == 0 ? @"smallIndex" : @"expandIndex");
            for (NSInteger i = 0; i < cnt; i++) {
                NSString *name = videoFiles()[i];
                NSString *label = (i == cur) ? [NSString stringWithFormat:@"✓ %@", name] : name;
                PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label target:self
                    set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
                [s setButtonAction:@selector(selectVideo:)];
                [s setProperty:@(i) forKey:@"idx"];
                [specs addObject:s];
            }
        }
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

- (void)selectVideo:(PSSpecifier *)spec {
    NSInteger idx = [[spec propertyForKey:@"idx"] integerValue];
    NSString *key = (self.matMode == 0) ? @"smallIndex" : @"expandIndex";
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(idx), (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    postReload();
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
