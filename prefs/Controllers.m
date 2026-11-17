#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
#include <sys/sysctl.h>
#include <sys/param.h>

/* 独立原生播放器 —— 面板 1:1 移植自 漂流岛 3.x DIPlayerEntryPage/DIPlayerSizePage,
   仅排除律动特效。键域固定 com.local.playerexact(内置原生播放器域), 与原版一致。 */

static NSString * const kNPDomain   = @"com.local.playerexact";
static NSString * const kNPModuleID = @"com.apple.mediaremote.controlcenter.nowplaying";
static NSString * const kNPActivationVer = @"0.3.1";
static NSString * const kPMPackage  = @"com.privatecustom.nativeplayer";

/* ================= 通用: 域读写 ================= */
static id npRead(NSString *key, NSString *dom) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)dom);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                       (__bridge CFStringRef)dom));
}
static void npWrite(NSString *key, id val, NSString *dom) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)val,
                             (__bridge CFStringRef)dom);
    CFPreferencesAppSynchronize((__bridge CFStringRef)dom);
}
/* 尺寸/功能共用键表(与原版面板同源) */
static NSArray<NSString *> *npKeys(void) {
    return @[@"Size", @"ModuleSizes", @"PlayerGridVariant",
             @"MusicArtworkBackgroundMode", @"MusicArtworkBlurRadius",
             @"MusicArtworkGradientEnabled", @"ArtworkRotationEnabled",
             @"BlockN95Artwork", @"HideRoutingIcon", @"HideNotPlaying",
             @"HideTimeWhenIdle"];
}
static BOOL npReadEnabled(void) {
    id v = npRead(@"Enabled", kNPDomain);
    return ([v isKindOfClass:NSNumber.class]) ? [v boolValue] : YES;
}
static NSString *npcurrentSize(void) {
    id s31 = npRead(@"Size", kNPDomain);
    if ([s31 isKindOfClass:NSString.class] && [(NSString *)s31 isEqualToString:@"3x1"]) return @"3x1";
    id variant = npRead(@"PlayerGridVariant", kNPDomain);
    if ([variant isKindOfClass:NSString.class] && [variant length]) return variant;
    id dict = npRead(@"ModuleSizes", kNPDomain);
    if ([dict isKindOfClass:NSDictionary.class]) {
        id s = dict[kNPModuleID];
        if ([s isKindOfClass:NSString.class] && [s length]) return s;
    }
    id sz = npRead(@"Size", kNPDomain);
    return ([sz isKindOfClass:NSString.class] && [sz length]) ? sz : @"2x2";
}
static void npApplySize(NSString *size) {
    if (![size isKindOfClass:NSString.class] || !size.length) return;
    NSMutableDictionary *sizes = [NSMutableDictionary dictionary];
    id cur = npRead(@"ModuleSizes", kNPDomain);
    if ([cur isKindOfClass:NSDictionary.class]) [sizes addEntriesFromDictionary:cur];
    NSString *moduleSize = size, *variant = nil;
    if ([size isEqualToString:@"3x2b"]) { moduleSize = @"4x2"; variant = @"3x2b"; }
    else if ([size isEqualToString:@"3x1"]) { moduleSize = @"4x1"; variant = nil; }
    sizes[kNPModuleID] = moduleSize;
    npWrite(@"ModuleSizes", sizes, kNPDomain);
    npWrite(@"PlayerGridVariant", variant, kNPDomain);
    npWrite(@"Size", size, kNPDomain);
}
static void npMigrateRetiredSizes(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    id dict = npRead(@"ModuleSizes", kNPDomain);
    if (![dict isKindOfClass:NSDictionary.class]) return;
    id v = ((NSDictionary *)dict)[kNPModuleID];
    if (![v isKindOfClass:NSString.class] || ![v isEqualToString:@"3x1"]) return;
    NSMutableDictionary *m = [dict mutableCopy];
    m[kNPModuleID] = @"4x1";
    npWrite(@"ModuleSizes", m, kNPDomain);
}
static void npEnsureActivation(void) {
    id en = npRead(@"Enabled", kNPDomain);
    BOOL keyExists = [en isKindOfClass:NSNumber.class];
    if (keyExists && ![en boolValue]) return;
    NSString *av = npRead(@"ActivationVersion", kNPDomain);
    if (keyExists && [av isKindOfClass:NSString.class] && [av isEqualToString:kNPActivationVer]) return;
    npWrite(@"Enabled", @YES, kNPDomain);
    npWrite(@"ActivationVersion", kNPActivationVer, kNPDomain);
    npWrite(@"StartupPendingVersion", nil, kNPDomain);
    npWrite(@"StartupPendingToken", nil, kNPDomain);
}
/* 注销: 与原版同一通道 —— Darwin 通知 + killall SpringBoard(chronod 加速) */
static void npKillByComm(const char *comm) {
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

/* ================= 遮罩素材选择页(对齐 DIMaskPicker, 独立域与目录) ================= */
static NSString * const kPMMaskKey = @"PlayerMaskAsset";
static NSString * const kPMMaskRoot = @"/var/mobile/原生播放器/遮罩素材";
static NSArray<NSString *> *pmListAssets(void) {
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:kPMMaskRoot];
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *f in en) {
        if (f.pathComponents.count > 2) { [en skipDescendants]; continue; }
        if ([f.pathExtension.lowercaseString isEqual:@"png"]) [a addObject:f];
    }
    [a sortUsingSelector:@selector(localizedStandardCompare:)];
    return a;
}
@interface PPMaskPicker : PSListController @end
@implementation PPMaskPicker
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"专辑遮罩素材";
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL d = NO;
    if (![fm fileExistsAtPath:kPMMaskRoot isDirectory:&d] || !d)
        [fm createDirectoryAtPath:kPMMaskRoot withIntermediateDirectories:YES
                          attributes:@{NSFilePosixPermissions:@0777} error:NULL];
    npWrite(kPMMaskKey, nil, kPMMaskRoot); // no-op guard
}
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        NSArray<NSString *> *list = pmListAssets();
        NSString *cur = npRead(kPMMaskKey, kPMMaskRoot);
        PSSpecifier *none = [PSSpecifier preferenceSpecifierNamed:@"不遮罩（关闭遮罩）"
            target:self set:NULL get:NULL detail:nil cell:PSListItemCell edit:nil];
        [none setProperty:@"__none__" forKey:@"diKey"];
        [none setProperty:@([cur isEqualToString:@"__none__"] || cur.length==0) forKey:@"diChecked"];
        [specs addObject:none];
        if (!list.count) {
            PSSpecifier *empty = [PSSpecifier preferenceSpecifierNamed:@"（目录里还没有 png 素材）"
                target:nil set:NULL get:NULL detail:nil cell:PSListItemCell edit:nil];
            [empty setProperty:@"把 png 放进 /var/mobile/原生播放器/遮罩素材 即可, 无需重编译"
                 forKey:@"footerText"];
            [specs addObject:empty];
        } else {
            NSString *eff = cur.length ? cur : list.firstObject;
            for (NSString *rel in list) {
                PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:rel
                    target:self set:NULL get:NULL detail:nil cell:PSListItemCell edit:nil];
                [sp setProperty:rel forKey:@"diKey"];
                [sp setProperty:@([rel isEqualToString:eff]) forKey:@"diChecked"];
                [specs addObject:sp];
            }
        }
        _specifiers = specs;
    }
    return _specifiers;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    PSSpecifier *sp = [self specifierAtIndexPath:ip];
    NSString *key = [sp propertyForKey:@"diKey"];
    if (key && ![key isEqualToString:@"__none__"]) {
        npWrite(@"MaskAsset", key, kPMMaskRoot);
        npWrite(@"MaskEnabled", @YES, kNPDomain);
    } else if (key) {
        npWrite(@"MaskAsset", nil, kPMMaskRoot);
        npWrite(@"MaskEnabled", @NO, kNPDomain);
    }
    notify_post("com.local.playerexact/artwork-changed");
    [tv deselectRowAtIndexPath:ip animated:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.15*NSEC_PER_SEC)),
                   dispatch_get_main_queue(),^{ [self reloadSpecifiers]; });
}
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    PSSpecifier *sp = [self specifierAtIndexPath:ip];
    BOOL on = [[sp propertyForKey:@"diChecked"] boolValue];
    cell.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
}
@end

/* ================= 尺寸页(对齐 DIPlayerSizePage) ================= */
@interface PPSizePage : PSListController @end
@implementation PPSizePage
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; npMigrateRetiredSizes(); [self reloadSpecifiers]; }
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"播放器尺寸" target:nil set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil]];
        NSArray<NSString *> *vals = @[@"2x2",@"2x3",@"3x2",@"3x2b",@"4x1",@"3x1",@"4x2",@"4x2b",@"4x3"];
        NSArray<NSString *> *titles = @[@"2 × 2",@"2 × 3",@"3 × 2",@"3 × 2（布局 B）",
                                        @"4 × 1",@"3 × 1（窄岛）",@"4 × 2",@"4 × 2（布局 B）",@"4 × 3"];
        NSString *cur = npcurrentSize();
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
        npApplySize(v);
        notify_post("com.local.playerexact/artwork-changed");
    }
    [self.navigationController popViewControllerAnimated:YES];
}
@end

/* ================= 入口页(对齐 DIPlayerEntryPage, 排除律动) ================= */
@interface PPRootController : PSListController @end
@implementation PPRootController

/* 按域读写的开关/链接(不写漂流岛域) */
- (id)readNP:(PSSpecifier *)sp {
    NSString *key=[sp propertyForKey:@"key"], *dom=[sp propertyForKey:@"defaults"] ?: kNPDomain;
    if (!key.length) return nil;
    id v=npRead(key,dom);
    if (v && ![v isKindOfClass:NSString.class] && ![v isKindOfClass:NSNumber.class]) v=nil;
    return v ?: [sp propertyForKey:@"default"];
}
- (void)setNP:(id)value specifier:(PSSpecifier *)sp {
    NSString *key=[sp propertyForKey:@"key"], *dom=[sp propertyForKey:@"defaults"] ?: kNPDomain;
    if (!key.length) return;
    npWrite(key,value,dom);
    notify_post("com.local.playerexact/artwork-changed");
}
/* 总开关: 开启时补激活版本 + 首启落尺寸 */
- (id)readNPEnabled:(PSSpecifier *)sp { return @(npReadEnabled()); }
- (void)writeNPEnabled:(id)value specifier:(PSSpecifier *)sp {
    BOOL on=[value boolValue];
    npWrite(@"Enabled",@(on),kNPDomain);
    if (on) {
        NSDictionary *sizes=npRead(@"ModuleSizes",kNPDomain);
        if (![sizes isKindOfClass:NSDictionary.class] || !sizes[kNPModuleID]) {
            NSString *sz=npRead(@"Size",kNPDomain);
            npApplySize(([sz isKindOfClass:NSString.class]&&sz.length)?sz:@"2x2");
        }
        npWrite(@"ActivationVersion",kNPActivationVer,kNPDomain);
        npWrite(@"StartupPendingVersion",nil,kNPDomain);
        npWrite(@"StartupPendingToken",nil,kNPDomain);
    }
    notify_post("com.local.playerexact/artwork-changed");
}
- (void)showMessage:(NSString *)title body:(NSString *)body {
    UIAlertController *ac=[UIAlertController alertControllerWithTitle:title message:body
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)importPlayerPreferences:(PSSpecifier *)sp {
    NSArray<NSString *> *sources=@[@"com.jaysuen.evocenter",@"com.local.nativeplayerresize"];
    NSUInteger n=0;
    for (NSString *src in sources) for (NSString *key in npKeys()) {
        id v=npRead(key,src); if (!v) continue; npWrite(key,v,kNPDomain); n++;
    }
    notify_post("com.local.playerexact/artwork-changed");
    [self reloadSpecifiers];
    [self showMessage:@"导入完成"
                 body:(n?[NSString stringWithFormat:@"已导入 %lu 项参数。",(unsigned long)n]
                      :@"没有找到可导入的旧参数(EvoCenter/旧尺寸插件未安装或未设置)。")];
}
- (void)resetPlayerPreferences:(PSSpecifier *)sp {
    for (NSString *key in npKeys()) npWrite(key,nil,kNPDomain);
    notify_post("com.local.playerexact/artwork-changed");
    [self reloadSpecifiers];
    [self showMessage:@"已恢复默认" body:@"尺寸 2 × 2、封面背景开、其余功能关。"];
}
/* 注销生效按钮(原版 doRespring) */
- (void)doRespring:(PSSpecifier *)sp {
    double now=[NSDate date].timeIntervalSince1970;
    npWrite(@"PendingRespringTS",@(now),kPMPackage);
    npWrite(@"PendingRespringTS",@(now),@"com.abgg332.driftisland");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.6*NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        npKillByComm("chronod"); npKillByComm("SpringBoard");
    });
    UIAlertController *ac=[UIAlertController alertControllerWithTitle:@"正在注销"
        message:@"屏幕会短暂黑一下, 桌面回来后尺寸生效。" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.5*NSEC_PER_SEC)),
                   dispatch_get_main_queue(),^{ if (ac.presentingViewController) [ac dismissViewControllerAnimated:YES completion:nil]; });
}
- (PSSpecifier *)groupSpec:(NSString *)header footer:(NSString *)footer {
    PSSpecifier *s=[PSSpecifier preferenceSpecifierNamed:header target:nil set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
    if (footer) [s setProperty:footer forKey:@"footerText"];
    return s;
}
- (PSSpecifier *)buttonSpec:(NSString *)name action:(SEL)sel {
    PSSpecifier *s=[PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
    [s setButtonAction:sel];
    return s;
}
- (PSSpecifier *)linkSpec:(NSString *)name detail:(Class)cls {
    return [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL detail:cls cell:PSLinkCell edit:nil];
}
- (PSSpecifier *)npSwitch:(NSString *)name key:(NSString *)key def:(BOOL)def {
    PSSpecifier *sp=[PSSpecifier preferenceSpecifierNamed:name target:self
        set:@selector(setNP:specifier:) get:@selector(readNP:) detail:nil cell:PSSwitchCell edit:nil];
    [sp setProperty:key forKey:@"key"]; [sp setProperty:kNPDomain forKey:@"defaults"]; [sp setProperty:@(def) forKey:@"default"];
    return sp;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    npEnsureActivation(); npMigrateRetiredSizes();
    [self reloadSpecifiers];
}
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"原生播放器"; }

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs=[NSMutableArray array];
        [specs addObject:[self groupSpec:@"原生播放" footer:nil]];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"启用播放器" target:self
            set:@selector(writeNPEnabled:specifier:) get:@selector(readNPEnabled:)
            detail:nil cell:PSSwitchCell edit:nil]];

        [specs addObject:[self groupSpec:@"播放器尺寸" footer:nil]];
        PSSpecifier *size=[PSSpecifier preferenceSpecifierNamed:@"播放器尺寸" target:self
            set:NULL get:NULL detail:[PPSizePage class] cell:PSLinkListCell edit:nil];
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
        PSSpecifier *rot=[PSSpecifier preferenceSpecifierNamed:@"专辑旋转" target:self
            set:@selector(setNP:specifier:) get:@selector(readNP:) detail:nil cell:PSSwitchCell edit:nil];
        [rot setProperty:@"ArtworkRotationEnabled" forKey:@"key"]; [rot setProperty:kNPDomain forKey:@"defaults"]; [rot setProperty:@NO forKey:@"default"];
        [specs addObject:rot];
        [specs addObject:[self npSwitch:@"隐藏投送" key:@"HideRoutingIcon" def:NO]];
        /* 遮罩: 开关 + 素材选择(排除律动) */
        [specs addObject:[self npSwitch:@"启用遮罩" key:@"MaskEnabled" def:NO]];
        [specs addObject:[self linkSpec:@"遮罩素材" detail:[PPMaskPicker class]]];

        [specs addObject:[self groupSpec:nil footer:nil]];
        [specs addObject:[self buttonSpec:@"导入原播放器参数" action:@selector(importPlayerPreferences:)]];
        [specs addObject:[self buttonSpec:@"恢复默认播放器参数" action:@selector(resetPlayerPreferences:)]];
        [specs addObject:[self groupSpec:nil footer:nil]];
        [specs addObject:[self buttonSpec:@"注销生效" action:@selector(doRespring:)]];
        _specifiers=specs;
    }
    return _specifiers;
}
@end
