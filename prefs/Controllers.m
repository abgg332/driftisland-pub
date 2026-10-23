#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>

static NSString *const kDomain = @"com.abgg332.driftisland";
static NSString *const kNotifyStr = @"com.abgg332.driftisland.reload";
static NSString *const kMaterialDir = @"/var/mobile/灵动岛";

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

@interface DIPrefsController : PSListController {
    NSInteger _smallRow; /* 小岛素材选择 行号 */
    NSInteger _expandRow; /* 展开素材选择 行号 */
}
- (PSSpecifier *)matSpec:(NSString *)name getter:(SEL)get detail:(Class)detailCls;
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
}

/* 素材选择行右侧显示的当前素材名 */
- (NSString *)nameForMode:(NSInteger)mode {
    NSInteger idx = indexForKey(mode == 0 ? @"smallIndex" : @"expandIndex");
    if (idx < 0) return @"无素材";
    return videoFiles()[idx];
}

- (id)readSmallVideoName:(PSSpecifier *)spec { return [self nameForMode:0]; }
- (id)readExpandVideoName:(PSSpecifier *)spec { return [self nameForMode:1]; }

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
- (PSSpecifier *)matSpec:(NSString *)name getter:(SEL)get detail:(Class)detailCls {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:NULL get:get detail:detailCls cell:PSLinkCell edit:nil];
    [s setProperty:((id (*)(id, SEL))objc_msgSend)(self, get) forKey:@"value"];
    return s;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        [specs addObject:[self groupSpec:@"漂流岛 · 灵动岛视频背景" footer:nil]];
        [specs addObject:[self switchSpec:@"总开关" key:@"enabled" def:@NO]];

        /* 小岛素材: 开关 + 素材选择行 */
        [specs addObject:[self groupSpec:@"小岛素材" footer:nil]];
        [specs addObject:[self switchSpec:@"小岛显示素材" key:@"smallOn" def:@YES]];
        PSSpecifier *smallMat = [self matSpec:@"素材选择" get:@selector(readSmallVideoName:) detail:[DIMaterialsSmall class]];

        /* 展开素材: 开关 + 素材选择行 */
        [specs addObject:[self groupSpec:@"展开素材" footer:nil]];
        [specs addObject:[self switchSpec:@"展开显示素材" key:@"expandOn" def:@YES]];
        PSSpecifier *expandMat = [self matSpec:@"素材选择" get:@selector(readExpandVideoName:) detail:[DIMaterialsExpand class]];

        [specs addObject:smallMat];
        [specs addObject:expandMat];
        _smallRow = _expandRow = -1;
        NSInteger n = 0;
        for (PSSpecifier *s in specs) {
            if (s.cellType == PSGroupCell) continue;
            if (s == smallMat) _smallRow = n;
            if (s == expandMat) _expandRow = n;
            n++;
        }

        [specs addObject:[self groupSpec:@"工具" footer:@"素材目录: /var/mobile/灵动岛"]];
        [specs addObject:[self buttonSpec:@"跳转素材目录" action:@selector(openMaterialDir)]];

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
    NSString *name = nil;
    if (indexPath.row == _smallRow) name = [self nameForMode:0];
    if (indexPath.row == _expandRow) name = [self nameForMode:1];
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
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"];
    NSString *enc = [kMaterialDir stringByAddingPercentEncodingWithAllowedCharacters:allowed];
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

@implementation DIMaterialsController (Internal)

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        NSInteger cnt = (NSInteger)videoFiles().count;
        NSString *title = (self.matMode == 0) ? @"选择小岛素材" : @"选择展开素材";
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
