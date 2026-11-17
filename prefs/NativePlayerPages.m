/* 独立原生播放器 —— 原生播放面板 1:1 移植 漂流岛 DIPlayerEntryPage/DIPlayerSizePage。
   行结构/键/域/按钮名/尺寸右侧显示/注销通道 与原版一致; 仅排除律动特效。
   diNP* 函数族逐字来自 漂流岛 Controllers.m。 */
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
#import <objc/runtime.h>
#include <sys/sysctl.h>
#include <sys/param.h>
#include <stdlib.h>

/* ===== 常量 ===== */
static NSString *const kDomain   = @"com.abgg332.driftisland";
static NSString *const kDIPlayerMaskOnKey = @"PlayerMaskOn";
static NSString *const kDIAlbumMaskKey    = @"diAlbumMaskAsset";
static NSString *const kDIMaskRoot = @"/var/mobile/灵动岛/遮罩素材";
static NSString * const kNPDomain   = @"com.local.playerexact";
static NSString * const kNPModuleID = @"com.apple.mediaremote.controlcenter.nowplaying";
static NSString * const kNPActivationVer = @"0.3.1";

/* ===== 域读写 ===== */
static id diNPRead(NSString *key, NSString *dom) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)dom);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                       (__bridge CFStringRef)dom));
}
static void diNPWrite(NSString *key, id val, NSString *dom) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)val,
                             (__bridge CFStringRef)dom);
    CFPreferencesAppSynchronize((__bridge CFStringRef)dom);
}
static NSArray<NSString *> *diNPKeys(void) {
    return @[@"Size", @"ModuleSizes", @"PlayerGridVariant",
             @"MusicArtworkBackgroundMode", @"MusicArtworkBlurRadius",
             @"MusicArtworkGradientEnabled", @"ArtworkRotationEnabled",
             @"BlockN95Artwork", @"HideRoutingIcon", @"HideNotPlaying",
             @"HideTimeWhenIdle"];
}
static BOOL diNPReadEnabled(void) {
    id v = diNPRead(@"Enabled", kNPDomain);
    return ([v isKindOfClass:NSNumber.class]) ? [v boolValue] : YES;
}
static NSString *diNPCurrentSize(void) {
    id s31 = diNPRead(@"Size", kNPDomain);
    if ([s31 isKindOfClass:NSString.class] && [(NSString *)s31 isEqualToString:@"3x1"]) return @"3x1";
    id variant = diNPRead(@"PlayerGridVariant", kNPDomain);
    if ([variant isKindOfClass:NSString.class] && [variant length]) return variant;
    id dict = diNPRead(@"ModuleSizes", kNPDomain);
    if ([dict isKindOfClass:NSDictionary.class]) {
        id s = dict[kNPModuleID];
        if ([s isKindOfClass:NSString.class] && [s length]) return s;
    }
    id sz = diNPRead(@"Size", kNPDomain);
    return ([sz isKindOfClass:NSString.class] && [sz length]) ? sz : @"2x2";
}
static void diNPApplySize(NSString *size) {
    if (![size isKindOfClass:NSString.class] || !size.length) return;
    NSMutableDictionary *sizes = [NSMutableDictionary dictionary];
    id cur = diNPRead(@"ModuleSizes", kNPDomain);
    if ([cur isKindOfClass:NSDictionary.class]) [sizes addEntriesFromDictionary:cur];
    NSString *moduleSize = size, *variant = nil;
    if ([size isEqualToString:@"3x2b"]) { moduleSize = @"4x2"; variant = @"3x2b"; }
    else if ([size isEqualToString:@"3x1"]) { moduleSize = @"4x1"; variant = nil; }
    sizes[kNPModuleID] = moduleSize;
    diNPWrite(@"ModuleSizes", sizes, kNPDomain);
    diNPWrite(@"PlayerGridVariant", variant, kNPDomain);
    diNPWrite(@"Size", size, kNPDomain);
}
static void diNPMigrateRetiredSizes(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    id dict = diNPRead(@"ModuleSizes", kNPDomain);
    if (![dict isKindOfClass:NSDictionary.class]) return;
    id v = ((NSDictionary *)dict)[kNPModuleID];
    if (![v isKindOfClass:NSString.class] || ![v isEqualToString:@"3x1"]) return;
    NSMutableDictionary *m = [dict mutableCopy];
    m[kNPModuleID] = @"4x1";
    diNPWrite(@"ModuleSizes", m, kNPDomain);
}
static void diNPEnsureActivation(void) {
    id en = diNPRead(@"Enabled", kNPDomain);
    BOOL keyExists = [en isKindOfClass:NSNumber.class];
    if (keyExists && ![en boolValue]) return;
    NSString *av = diNPRead(@"ActivationVersion", kNPDomain);
    if (keyExists && [av isKindOfClass:NSString.class] && [av isEqualToString:kNPActivationVer]) return;
    diNPWrite(@"Enabled", @YES, kNPDomain);
    diNPWrite(@"ActivationVersion", kNPActivationVer, kNPDomain);
    diNPWrite(@"StartupPendingVersion", nil, kNPDomain);
    diNPWrite(@"StartupPendingToken", nil, kNPDomain);
}
static void diwKillByComm(const char *comm) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) < 0 || len == 0) return;
    struct kinfo_proc *procs = malloc(len + sizeof(struct kinfo_proc));
    if (!procs) return;
    if (sysctl(mib, 4, procs, &len, NULL, 0) == 0) {
        int n = (int)(len / sizeof(struct kinfo_proc));
        for (int i = 0; i < n; i++) {
            pid_t pid = procs[i].kp_proc.p_pid;
            if (pid <= 1) continue;
            if (strncmp(procs[i].kp_proc.p_comm, comm, MAXCOMLEN) == 0) kill(pid, SIGTERM);
        }
    }
    free(procs);
}
/* 遮罩素材目录列举 */
static NSArray<NSString *> *diSortStrs(NSArray *a);
static NSArray<NSString *> *diMaskListAssets(void) {
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
static NSString *diReadPrefString(NSString *key) {
    id v = diNPRead(key, kDomain);
    return [v isKindOfClass:NSString.class] ? v : nil;
}
static void diWritePrefString(NSString *value, NSString *key) {
    diNPWrite(key, value, kDomain);
}

/* ================= 遮罩素材选择页(对齐 DIMaskPicker + DIPlayerMaskPicker) ================= */
static NSString *const kDIPlayerMaskKey=@"PlayerMaskAsset";
static NSString *readPrefString(NSString *key){return diReadPrefString(key);}
static void writePrefString(NSString *value,NSString *key){diWritePrefString(value,key);notify_post("com.local.playerexact/artwork-changed");}
static NSArray *DIMaskListAssets(void){return diMaskListAssets();}
static NSArray<NSString *> *diSortStrs(NSArray *a){return [a sortedArrayUsingComparator:^NSComparisonResult(NSString *x,NSString *y){return [x localizedStandardCompare:y];}] ?: @[];}
@interface DIMaskPicker:PSListController
- (NSString *)maskKey;
- (NSString *)pickerTitle;
@end
@implementation DIMaskPicker
- (NSString *)maskKey { return kDIAlbumMaskKey; }
- (NSString *)pickerTitle { return @"专辑遮罩素材"; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self pickerTitle];
    /* 进页就保证目录存在, 方便用户直接往里面丢 png(不用先手动建目录) */
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL d = NO;
    if (![fm fileExistsAtPath:kDIMaskRoot isDirectory:&d] || !d) {
        [fm createDirectoryAtPath:kDIMaskRoot withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0777} error:NULL];
    }
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        NSArray<NSString *> *list = DIMaskListAssets();
        NSString *cur = readPrefString([self maskKey]);

        PSSpecifier *none = [PSSpecifier preferenceSpecifierNamed:@"不遮罩（关闭遮罩）"
                                                           target:self set:nil get:@selector(currentValueForSpecifier:)
                                                           detail:nil cell:PSListItemCell edit:nil];
        [none setProperty:@"__none__" forKey:@"diKey"];
        [none setProperty:[NSNumber numberWithBool:[cur isEqualToString:@"__none__"]] forKey:@"diChecked"];
        [specs addObject:none];

        if (!list.count) {
            PSSpecifier *empty = [PSSpecifier preferenceSpecifierNamed:@"（目录里还没有 png 素材）"
                                                                target:nil set:nil get:nil detail:nil
                                                                cell:PSListItemCell edit:nil];
            [empty setProperty:@"把 png 放进 /var/mobile/灵动岛/遮罩素材 即可, 无需重编译" forKey:@"footerText"];
            [specs addObject:empty];
        } else {
            NSString *eff = cur.length ? cur : list.firstObject;
            for (NSString *rel in list) {
                PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:rel
                                                                 target:self set:nil get:@selector(currentValueForSpecifier:)
                                                                 detail:nil cell:PSListItemCell edit:nil];
                [sp setProperty:rel forKey:@"diKey"];
                [sp setProperty:[NSNumber numberWithBool:[rel isEqualToString:eff]] forKey:@"diChecked"];
                [specs addObject:sp];
            }
        }
        _specifiers = specs;
    }
    return _specifiers;
}

- (id)currentValueForSpecifier:(PSSpecifier *)spec {
    return nil;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    PSSpecifier *sp = [self specifierAtIndexPath:ip];
    NSString *key = [sp propertyForKey:@"diKey"];
    if (key) {
        writePrefString(key, [self maskKey]);
        /* 让悬浮岛立刻刷新 */
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.abgg332.driftisland/prefsChanged"), NULL, NULL, YES);
        [tv deselectRowAtIndexPath:ip animated:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self reloadSpecifiers];
        });
    }
}

/* 选中项打勾 */
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    PSSpecifier *sp = [self specifierAtIndexPath:ip];
    BOOL on = [[sp propertyForKey:@"diChecked"] boolValue];
    cell.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return @"点选即生效（无需重启）";
}
@end
@interface DIPlayerMaskPicker:DIMaskPicker @end
@implementation DIPlayerMaskPicker
- (NSString *)maskKey { return kDIPlayerMaskKey; }
- (NSString *)pickerTitle { return @"播放器遮罩素材"; }
@end
/* ================= 尺寸页(对齐 DIPlayerSizePage) ================= */
@interface DIPlayerSizePage : PSListController @end
@implementation DIPlayerSizePage
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; diNPMigrateRetiredSizes(); [self reloadSpecifiers]; }
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"播放器尺寸" target:nil set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil]];
        NSArray<NSString *> *vals = @[@"2x2",@"2x3",@"3x2",@"3x2b",@"4x1",@"3x1",@"4x2",@"4x2b",@"4x3"];
        NSArray<NSString *> *titles = @[@"2 × 2",@"2 × 3",@"3 × 2",@"3 × 2（布局 B）",
                                        @"4 × 1",@"3 × 1（窄岛）",@"4 × 2",@"4 × 2（布局 B）",@"4 × 3"];
        NSString *cur = diNPCurrentSize();
        for (NSUInteger i = 0; i < vals.count; i++) {
            BOOL on = [vals[i] isEqualToString:cur];
            NSString *name = on ? [@"✓ " stringByAppendingString:titles[i]] : titles[i];
            PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
            [sp setProperty:vals[i] forKey:@"sizeValue"];
            [sp setButtonAction:@selector(pickSize:)];
            [specs addObject:sp];
        }
        _specifiers = specs;
    }
    return _specifiers;
}
- (void)pickSize:(PSSpecifier *)sp {
    NSString *v = [sp propertyForKey:@"sizeValue"];
    if ([v isKindOfClass:NSString.class] && v.length) {
        diNPApplySize(v);
        notify_post("com.local.playerexact/artwork-changed");
    }
    [self.navigationController popViewControllerAnimated:YES];
}
@end

/* ================= 入口页(对齐 DIPlayerEntryPage, 排除律动) ================= */
@interface DIPlayerEntryPage : PSListController @end
@implementation DIPlayerEntryPage

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    NSString *dom = [spec propertyForKey:@"defaults"] ?: kNPDomain;
    if (!key.length) return nil;
    id v = diNPRead(key, dom);
    if (v && ![v isKindOfClass:NSString.class] && ![v isKindOfClass:NSNumber.class]) v = nil;
    return v ?: [spec propertyForKey:@"default"];
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    NSString *dom = [spec propertyForKey:@"defaults"] ?: kNPDomain;
    if (!key.length) return;
    diNPWrite(key, value, dom);
    notify_post("com.local.playerexact/artwork-changed");
}
- (id)readNPEnabled:(PSSpecifier *)sp { return @(diNPReadEnabled()); }
- (void)writeNPEnabled:(id)value specifier:(PSSpecifier *)sp {
    BOOL on = [value boolValue];
    diNPWrite(@"Enabled", @(on), kNPDomain);
    if (on) {
        NSDictionary *sizes = diNPRead(@"ModuleSizes", kNPDomain);
        if (![sizes isKindOfClass:NSDictionary.class] || !sizes[kNPModuleID]) {
            NSString *sz = diNPRead(@"Size", kNPDomain);
            diNPApplySize(([sz isKindOfClass:NSString.class] && [sz length]) ? sz : @"2x2");
        }
        diNPWrite(@"ActivationVersion", kNPActivationVer, kNPDomain);
        diNPWrite(@"StartupPendingVersion", nil, kNPDomain);
        diNPWrite(@"StartupPendingToken", nil, kNPDomain);
    }
    notify_post("com.local.playerexact/artwork-changed");
}
- (void)showMessage:(NSString *)title body:(NSString *)body {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:body
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)importPlayerPreferences:(PSSpecifier *)sp {
    NSArray<NSString *> *sources = @[@"com.jaysuen.evocenter", @"com.local.nativeplayerresize"];
    NSUInteger n = 0;
    for (NSString *src in sources) for (NSString *key in diNPKeys()) {
        id v = diNPRead(key, src);
        if (!v) continue;
        diNPWrite(key, v, kNPDomain);
        n++;
    }
    notify_post("com.local.playerexact/artwork-changed");
    [self reloadSpecifiers];
    [self showMessage:@"导入完成"
                 body:(n ? [NSString stringWithFormat:@"已导入 %lu 项参数。", (unsigned long)n]
                        : @"没有找到可导入的旧参数(EvoCenter/旧尺寸插件未安装或未设置)。")];
}
- (void)resetPlayerPreferences:(PSSpecifier *)sp {
    for (NSString *key in diNPKeys()) diNPWrite(key, nil, kNPDomain);
    notify_post("com.local.playerexact/artwork-changed");
    [self reloadSpecifiers];
    [self showMessage:@"已恢复默认" body:@"尺寸 2 × 2、封面背景开、其余功能关。"];
}
- (void)doRespring:(PSSpecifier *)sp {
    diNPWrite(@"PendingRespringTS", @((double)[[NSDate date] timeIntervalSince1970]), kDomain);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        diwKillByComm("chronod");
        diwKillByComm("SpringBoard");
    });
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"正在注销"
        message:@"屏幕会短暂黑一下, 桌面回来后尺寸生效。" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (ac.presentingViewController) [ac dismissViewControllerAnimated:YES completion:nil];
    });
}
- (PSSpecifier *)npSwitch:(NSString *)name key:(NSString *)key def:(BOOL)def {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSwitchCell edit:nil];
    [sp setProperty:key forKey:@"key"];
    [sp setProperty:kNPDomain forKey:@"defaults"];
    [sp setProperty:@(def) forKey:@"default"];
    return sp;
}
- (PSSpecifier *)npRotateSwitch {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:@"专辑旋转" target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSwitchCell edit:nil];
    [sp setProperty:@"ArtworkRotationEnabled" forKey:@"key"];
    [sp setProperty:kNPDomain forKey:@"defaults"];
    [sp setProperty:@NO forKey:@"default"];
    return sp;
}
- (PSSpecifier *)groupSpec:(NSString *)header footer:(NSString *)footer {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:header target:nil set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
    if (footer) [s setProperty:footer forKey:@"footerText"];
    return s;
}
- (PSSpecifier *)buttonSpec:(NSString *)name action:(SEL)sel {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
    [s setButtonAction:sel];
    return s;
}
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls {
    return [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL detail:cls cell:PSLinkCell edit:nil];
}
- (PSSpecifier *)switchSpec:(NSString *)name key:(NSString *)key def:(id)def {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSwitchCell edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:kDomain forKey:@"defaults"];
    [s setProperty:def forKey:@"default"];
    return s;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    diNPEnsureActivation();
    diNPMigrateRetiredSizes();
    [self reloadSpecifiers];
}
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"原生播放器"; }

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        [specs addObject:[self groupSpec:@"原生播放" footer:nil]];
        PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:@"启用播放器" target:self
            set:@selector(writeNPEnabled:specifier:) get:@selector(readNPEnabled:)
            detail:nil cell:PSSwitchCell edit:nil];
        [specs addObject:sw];

        [specs addObject:[self groupSpec:@"播放器尺寸" footer:nil]];
        PSSpecifier *size = [PSSpecifier preferenceSpecifierNamed:@"播放器尺寸" target:self
            set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:[DIPlayerSizePage class] cell:PSLinkListCell edit:nil];
        [size setProperty:@"Size" forKey:@"key"];
        [size setProperty:kNPDomain forKey:@"defaults"];
        [size setProperty:@"2x2" forKey:@"default"];
        [size setProperty:@[@"2x2",@"2x3",@"3x2",@"3x2b",@"4x1",@"3x1",@"4x2",@"4x2b",@"4x3"] forKey:@"validValues"];
        [size setProperty:@[@"2 × 2",@"2 × 3",@"3 × 2",@"3 × 2（布局 B）",
                            @"4 × 1",@"3 × 1（窄岛）",@"4 × 2",@"4 × 2（布局 B）",@"4 × 3"] forKey:@"validTitles"];
        [specs addObject:size];

        [specs addObject:[self groupSpec:@"功能" footer:nil]];
        [specs addObject:[self npSwitch:@"封面背景" key:@"MusicArtworkGradientEnabled" def:YES]];
        [specs addObject:[self npSwitch:@"隐藏未在" key:@"HideNotPlaying" def:NO]];
        [specs addObject:[self npRotateSwitch]];
        [specs addObject:[self npSwitch:@"隐藏投送" key:@"HideRoutingIcon" def:NO]];
        [specs addObject:[self switchSpec:@"启用遮罩" key:kDIPlayerMaskOnKey def:@NO]];
        [specs addObject:[self linkSpec:@"遮罩素材" detail:[DIPlayerMaskPicker class]]];
        /* 律动特效: 用户明确排除 */

        [specs addObject:[self groupSpec:nil footer:nil]];
        [specs addObject:[self buttonSpec:@"注销生效" action:@selector(doRespring:)]];
        _specifiers = specs;
    }
    return _specifiers;
}
@end
