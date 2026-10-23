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

#pragma mark - 频谱帧率动画设置页(自绘cell: 文字+滑杆+数字, 点数字弹框手输; 表头机制已用4组specifier对齐)

@implementation DIAnimSettings {
    NSMutableDictionary<NSString *, UILabel *> *_labels;
}

- (NSArray *)specifiers {
    /* 数量必须与 numberOfSectionsInTableView 一致, 否则 Preferences 表头机制越界 */
    if (!_specifiers) {
        NSMutableArray *g = [NSMutableArray array];
        for (NSString *name in @[@"灵动岛动画", @"动画设置", @"位置缩放设置", @"素材设置"])
            [g addObject:[PSSpecifier preferenceSpecifierNamed:name target:nil
                set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil]];
        _specifiers = g;
    }
    return _specifiers;
}

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
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(v), (__bridge CFPropertyListRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kNotifyStr, NULL, NULL, YES);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"动画设置";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return 4;
    if (section == 2) return 3;
    return 1;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"灵动岛动画";
    if (section == 1) return @"动画设置";
    if (section == 2) return @"位置缩放设置";
    return @"素材设置";
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == 1) return @"动画帧率=每秒播放帧数(1~60); 旋转速度=每秒旋转度数。点数字可直接输入精确值。";
    if (section == 2) return @"素材大小=缩放倍数(0.2~3); 左右/上下=偏移点数(-150~150)。点数字可直接输入精确值。";
    if (section == 3) return @"素材目录: /var/mobile/灵动岛/帧率素材 (每个子文件夹=一套素材, png/jpg 按文件名数字顺序播放)。";
    return nil;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return 50; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSString *cellId = [NSString stringWithFormat:@"c-%ld-%ld", (long)ip.section, (long)ip.row];
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cellId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
    cell.textLabel.text = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    for (UIView *sub in cell.contentView.subviews) [sub removeFromSuperview];

    /* 参数表: (标题, 键, 默认, 最小, 最大) */
    if (ip.section == 0 && ip.row == 0)
        [self decorateSwitch:cell title:@"启用动画" key:@"spectrumOn" def:NO];
    else if (ip.section == 1 && ip.row == 1)
        [self decorateSwitch:cell title:@"启用素材旋转" key:@"animRotate" def:NO];
    else if (ip.section == 1 && ip.row == 2)
        [self decorateSwitch:cell title:@"素材旋转反转" key:@"animRotateReverse" def:NO];
    else if (ip.section == 3 && ip.row == 0)
        [self decorateFolder:cell];
    else {
        NSString *key, *title; double def = 0, mn = 0, mx = 1;
        if (ip.section == 1 && ip.row == 0)      { key = @"animFPS";         title = @"动画帧率"; def = 50; mn = 1;   mx = 60;  }
        else if (ip.section == 1 && ip.row == 3) { key = @"animRotateSpeed"; title = @"旋转速度"; def = 5;  mn = 1;   mx = 30;  }
        else if (ip.section == 2 && ip.row == 0) { key = @"animScale";       title = @"素材大小"; def = 1;  mn = 0.2; mx = 3;   }
        else if (ip.section == 2 && ip.row == 1) { key = @"animOffsetX";     title = @"左右偏移"; def = 0;  mn = -150; mx = 150; }
        else                                     { key = @"animOffsetY";     title = @"上下偏移"; def = 0;  mn = -150; mx = 150; }
        [self decorateSlider:cell title:title key:key def:def min:mn max:mx];
    }
    return cell;
}

/* 行: 文字(左) + 滑杆(中) + 数字(右, 点击弹框手输) */
- (void)decorateSlider:(UITableViewCell *)cell title:(NSString *)title key:(NSString *)key def:(double)def min:(double)mn max:(double)mx {
    UILabel *name = [UILabel new];
    name.text = title;
    name.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [name setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    name.translatesAutoresizingMaskIntoConstraints = NO;

    UISlider *slider = [UISlider new];
    slider.minimumValue = mn; slider.maximumValue = mx;
    slider.value = [self numForKey:key def:def];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(slider, "key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(slider, "min", @(mn), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(slider, "max", @(mx), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];

    UILabel *val = [UILabel new];
    val.text = [NSString stringWithFormat:@"%.2f", slider.value];
    val.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
    val.textAlignment = NSTextAlignmentRight;
    val.textColor = [UIColor systemBlueColor]; // 提示可点击
    val.userInteractionEnabled = YES;
    [val setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    val.translatesAutoresizingMaskIntoConstraints = NO;
    _labels[key] = val;

    objc_setAssociatedObject(val, "key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(val, "min", @(mn), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(val, "max", @(mx), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapValue:)];
    [val addGestureRecognizer:tap];

    [cell.contentView addSubview:name];
    [cell.contentView addSubview:slider];
    [cell.contentView addSubview:val];
    [NSLayoutConstraint activateConstraints:@[
        [name.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [name.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [name.trailingAnchor constraintLessThanOrEqualToAnchor:slider.leadingAnchor constant:-6],
        [slider.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [slider.leadingAnchor constraintGreaterThanOrEqualToAnchor:name.trailingAnchor constant:6],
        [val.leadingAnchor constraintEqualToAnchor:slider.trailingAnchor constant:6],
        [val.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [val.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [val.widthAnchor constraintGreaterThanOrEqualToConstant:52],
    ]];
}

- (void)sliderChanged:(UISlider *)slider {
    NSString *key = objc_getAssociatedObject(slider, "key");
    [self saveNum:slider.value forKey:key];
    _labels[key].text = [NSString stringWithFormat:@"%.2f", slider.value];
}

/* 点击数字: 弹框手动输入精确值 */
- (void)tapValue:(UITapGestureRecognizer *)tap {
    UILabel *val = (UILabel *)tap.view;
    NSString *key = objc_getAssociatedObject(val, "key");
    double mn = [objc_getAssociatedObject(val, "min") doubleValue];
    double mx = [objc_getAssociatedObject(val, "max") doubleValue];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:key
        message:[NSString stringWithFormat:@"范围 %.2f ~ %.2f", mn, mx]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = val.text;
        tf.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        double v = [alert.textFields.firstObject.text doubleValue];
        if (v < mn) v = mn; if (v > mx) v = mx;
        [self saveNum:v forKey:key];
        val.text = [NSString stringWithFormat:@"%.2f", v];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/* 行: 文字(左) + 开关(右) */
- (void)decorateSwitch:(UITableViewCell *)cell title:(NSString *)title key:(NSString *)key def:(BOOL)def {
    cell.textLabel.text = title;
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    UISwitch *sw = [UISwitch new];
    sw.on = [self boolForKey:key def:def];
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(sw, "key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cell.accessoryView = sw;
}

- (void)switchChanged:(UISwitch *)sw {
    [self saveBool:sw.on forKey:objc_getAssociatedObject(sw, "key")];
}

/* 行: 素材名(左) + 当前文件夹(右) + 箭头 */
- (void)decorateFolder:(UITableViewCell *)cell {
    cell.textLabel.text = @"素材名";
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("animFolder"), (__bridge CFStringRef)kDomain));
    cell.detailTextLabel.text = ([v isKindOfClass:NSString.class] && [(NSString *)v length]) ? v : @"默认(第一个文件夹)";
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 3 && ip.row == 0)
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
