#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
static NSString *const PNPDomain=@"com.privatecustom.nativeplayer",*const PNPNative=@"com.local.playerexact";
static id PNPRead(NSString *key,NSString *domain){CFPreferencesAppSynchronize((__bridge CFStringRef)domain);return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,(__bridge CFStringRef)domain));}
static void PNPWrite(NSString *key,id value,NSString *domain){CFPreferencesSetAppValue((__bridge CFStringRef)key,(__bridge CFPropertyListRef)value,(__bridge CFStringRef)domain);CFPreferencesAppSynchronize((__bridge CFStringRef)domain);}
@interface PNPSizeController:PSListController @end
@interface PNPMaskController:PSListController @end
@interface PNPRootController:PSListController @end
@implementation PNPRootController
- (id)readValue:(PSSpecifier *)sp{return PNPRead([sp propertyForKey:@"key"],[sp propertyForKey:@"defaults"])?:[sp propertyForKey:@"default"];}
- (void)setValue:(id)value specifier:(PSSpecifier *)sp{
 NSString *key=[sp propertyForKey:@"key"],*domain=[sp propertyForKey:@"defaults"];PNPWrite(key,value,domain);
 if([key isEqual:@"Enabled"]&&[value boolValue])PNPWrite(@"ActivationVersion",@"0.3.1",PNPNative);
 notify_post("com.local.playerexact/artwork-changed");
}
- (PSSpecifier *)toggle:(NSString *)name key:(NSString *)key domain:(NSString *)domain fallback:(BOOL)value{
 PSSpecifier *s=[PSSpecifier preferenceSpecifierNamed:name target:self set:@selector(setValue:specifier:) get:@selector(readValue:) detail:nil cell:PSSwitchCell edit:nil];[s setProperty:key forKey:@"key"];[s setProperty:domain forKey:@"defaults"];[s setProperty:@(value) forKey:@"default"];return s;
}
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];self.title=@"原生播放器";[self reloadSpecifiers];}
- (NSArray *)specifiers{
 if(!_specifiers){NSMutableArray *a=[NSMutableArray array];
  PSSpecifier *g=[PSSpecifier preferenceSpecifierNamed:@"原生播放器" target:nil set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];[g setProperty:@"控制中心原生播放器独立版。尺寸更改后请注销重新建立模块。" forKey:@"footerText"];[a addObject:g];
  [a addObject:[self toggle:@"启用播放器" key:@"Enabled" domain:PNPNative fallback:YES]];
  [a addObject:[PSSpecifier preferenceSpecifierNamed:@"播放器尺寸" target:self set:NULL get:NULL detail:PNPSizeController.class cell:PSLinkCell edit:nil]];
  [a addObject:[PSSpecifier preferenceSpecifierNamed:@"功能" target:nil set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil]];
  [a addObject:[self toggle:@"封面背景" key:@"MusicArtworkGradientEnabled" domain:PNPNative fallback:YES]];
  [a addObject:[self toggle:@"隐藏未在播放" key:@"HideNotPlaying" domain:PNPNative fallback:NO]];
  [a addObject:[self toggle:@"专辑旋转" key:@"ArtworkRotationEnabled" domain:PNPNative fallback:NO]];
  [a addObject:[self toggle:@"隐藏投送" key:@"HideRoutingIcon" domain:PNPNative fallback:NO]];
  [a addObject:[self toggle:@"启用遮罩" key:@"MaskEnabled" domain:PNPDomain fallback:NO]];
  [a addObject:[PSSpecifier preferenceSpecifierNamed:@"遮罩素材" target:self set:NULL get:NULL detail:PNPMaskController.class cell:PSLinkCell edit:nil]];
  PSSpecifier *about=[PSSpecifier preferenceSpecifierNamed:@"关于" target:nil set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];[about setProperty:@"Version：1.0\nAuthor：私人定制\n素材目录：/var/mobile/原生播放器/遮罩素材" forKey:@"footerText"];[a addObject:about];_specifiers=a;
 }return _specifiers;
}
@end
@implementation PNPSizeController
- (NSArray *)specifiers{
 if(!_specifiers){NSMutableArray *a=[NSMutableArray array];NSArray *keys=@[@"2x2",@"2x3",@"3x2",@"3x2b",@"4x1",@"3x1",@"4x2",@"4x2b",@"4x3"];
 NSArray *titles=@[@"2 × 2",@"2 × 3",@"3 × 2",@"3 × 2（布局 B）",@"4 × 1",@"3 × 1",@"4 × 2",@"4 × 2（布局 B）",@"4 × 3"];
 NSString *current=PNPRead(@"Size",PNPNative)?:@"2x2";
 for(NSUInteger i=0;i<keys.count;i++){NSString *label=[NSString stringWithFormat:@"%@%@",[current isEqual:keys[i]]?@"✓ ":@"",titles[i]];PSSpecifier *s=[PSSpecifier preferenceSpecifierNamed:label target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];[s setProperty:keys[i] forKey:@"value"];[s setButtonAction:@selector(selectSize:)];[a addObject:s];}_specifiers=a;
 }return _specifiers;
}
- (void)selectSize:(PSSpecifier *)sp{
 NSString *size=[sp propertyForKey:@"value"],*value=size,*variant=nil;
 if([size isEqual:@"3x1"])value=@"4x1";
 if([size isEqual:@"3x2b"]){value=@"4x2";variant=size;}
 NSDictionary *saved=PNPRead(@"ModuleSizes",PNPNative);NSMutableDictionary *sizes=[saved isKindOfClass:NSDictionary.class]?[saved mutableCopy]:[NSMutableDictionary dictionary];
 sizes[@"com.apple.mediaremote.controlcenter.nowplaying"]=value;
 PNPWrite(@"ModuleSizes",sizes,PNPNative);PNPWrite(@"Size",size,PNPNative);PNPWrite(@"PlayerGridVariant",variant,PNPNative);
 notify_post("com.local.playerexact/artwork-changed");[self.navigationController popViewControllerAnimated:YES];
}
@end
@implementation PNPMaskController
- (NSArray *)specifiers{
 if(!_specifiers){NSMutableArray *a=[NSMutableArray array];NSString *base=@"/var/mobile/原生播放器/遮罩素材";
 PSSpecifier *g=[PSSpecifier preferenceSpecifierNamed:@"选择遮罩 PNG" target:nil set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];[g setProperty:base forKey:@"footerText"];[a addObject:g];
 NSString *selected=PNPRead(@"MaskAsset",PNPDomain);NSDirectoryEnumerator *en=[[NSFileManager defaultManager] enumeratorAtPath:base];NSMutableArray *files=[NSMutableArray array];
 for(NSString *f in en){if(f.pathComponents.count>2){[en skipDescendants];continue;}if([f.pathExtension.lowercaseString isEqual:@"png"])[files addObject:f];}
 [files sortUsingSelector:@selector(localizedStandardCompare:)];
 for(NSString *f in files){PSSpecifier *sp=[PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"%@%@",[selected isEqual:f]?@"✓ ":@"",f] target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];[sp setProperty:f forKey:@"asset"];[sp setButtonAction:@selector(selectMask:)];[a addObject:sp];}
 _specifiers=a;
 }return _specifiers;
}
- (void)selectMask:(PSSpecifier *)s{PNPWrite(@"MaskAsset",[s propertyForKey:@"asset"],PNPDomain);notify_post("com.local.playerexact/artwork-changed");[self.navigationController popViewControllerAnimated:YES];}
@end
