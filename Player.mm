#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>
#import <notify.h>
#include <math.h>
#include <string.h>
#include <initializer_list>
static NSString *const PNPDomain=@"com.privatecustom.nativeplayer";
static NSDictionary *pnpPrefs,*pnpNative;
static NSHashTable *pnpRoots;
static UIImage *pnpArtwork,*pnpMask;
static NSData *pnpArtData;
static BOOL pnpPlaying=NO,pnpBusy=NO,pnpQuery=NO;
static CFAbsoluteTime pnpLastQuery=0;
static NSDictionary *pnpNowPlayingInfo(void){
 // Read the read-only 'nowPlayingInfo' via KVC to avoid typed msgSend issues in C++.
 Class cls=NSClassFromString(@"MRMediaRemoteController");
 @try{
  id shared=[cls valueForKey:@"sharedController"];
  if([shared isKindOfClass:NSObject.class]){
   NSDictionary *r=[shared valueForKey:@"nowPlayingInfo"];
   if([r isKindOfClass:NSDictionary.class])return r;
  }
 }@catch(NSException *e){}
 return nil;
}
static void PNPLog(NSString *fmt,...){va_list args;va_start(args,fmt);NSString *s=[[NSString alloc]initWithFormat:fmt arguments:args];va_end(args);NSLog(@"[原生播放器] %@",s);}
static BOOL pnpBool(NSString *key,BOOL fallback){id v=pnpNative[key];return v?[v boolValue]:fallback;}
#include "Grid.inc"
@interface PNPArtState:NSObject
@property(nonatomic,strong) CALayer *originalMask;
@property(nonatomic,strong) CALayer *mask;
@end
@implementation PNPArtState @end
static char pnpArtKey,pnpBgKey,pnpHiddenKey;
static BOOL pnpExpanded(UIView *v){
 for(UIResponder *r=v;r;r=r.nextResponder)if([NSStringFromClass(r.class) containsString:@"Expanded"])return YES;
 return v.bounds.size.height>400;
}
static void pnpSetHidden(UIView *v,BOOL hide){
 NSNumber *old=objc_getAssociatedObject(v,&pnpHiddenKey);
 if(hide){if(!old)objc_setAssociatedObject(v,&pnpHiddenKey,@(v.alpha),OBJC_ASSOCIATION_RETAIN_NONATOMIC);if(v.alpha!=0)v.alpha=0;}
 else if(old){v.alpha=old.doubleValue;objc_setAssociatedObject(v,&pnpHiddenKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
}
static void pnpApply(UIView *root){
 if(pnpBusy||!root.window||[NSStringFromClass(root.class) containsString:@"Activity"])return;
 pnpBusy=YES;
 @try{
 BOOL enabled=pnpBool(@"Enabled",YES),expanded=pnpExpanded(root);
 CALayer *bg=objc_getAssociatedObject(root,&pnpBgKey);
 BOOL background=enabled&&!expanded&&pnpBool(@"MusicArtworkGradientEnabled",YES)&&pnpPlaying&&pnpArtwork;
 if(background&&!bg){bg=[CALayer layer];bg.name=@"pnp.cover.background";bg.contentsGravity=kCAGravityResizeAspectFill;bg.masksToBounds=YES;bg.actions=@{@"contents":NSNull.null,@"bounds":NSNull.null,@"position":NSNull.null,@"hidden":NSNull.null};[root.layer insertSublayer:bg atIndex:0];objc_setAssociatedObject(root,&pnpBgKey,bg,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
 [CATransaction begin];[CATransaction setDisableActions:YES];
 bg.hidden=!background;
 if(background){if(!CGRectEqualToRect(bg.frame,root.bounds))bg.frame=root.bounds;bg.cornerRadius=MAX(18,root.layer.cornerRadius);if(bg.contents!=(__bridge id)pnpArtwork.CGImage)bg.contents=(__bridge id)pnpArtwork.CGImage;}
 NSMutableArray *queue=[NSMutableArray arrayWithObject:root];int budget=400;
 while(queue.count&&budget-->0){UIView *v=queue.lastObject;[queue removeLastObject];NSString *name=NSStringFromClass(v.class);
  if([name containsString:@"Activity"])continue;
  if([name containsString:@"ArtworkView"]){
   BOOL mask=enabled&&!expanded&&pnpBool(@"PlayerMaskOn",NO)&&pnpMask;
   PNPArtState *state=objc_getAssociatedObject(v,&pnpArtKey);
   if(mask&&!state){state=[PNPArtState new];state.originalMask=v.layer.mask;state.mask=[CALayer layer];state.mask.contentsGravity=kCAGravityResizeAspect;objc_setAssociatedObject(v,&pnpArtKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
   if(mask){state.mask.frame=v.bounds;state.mask.contents=(__bridge id)pnpMask.CGImage;v.layer.mask=state.mask;}
   else if(state){if(v.layer.mask==state.mask)v.layer.mask=state.originalMask;objc_setAssociatedObject(v,&pnpArtKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
   BOOL rotate=enabled&&!expanded&&pnpPlaying&&pnpBool(@"ArtworkRotationEnabled",NO);
   if(rotate&&![v.layer animationForKey:@"pnp.rotation"]){CABasicAnimation *a=[CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];a.fromValue=@0;a.toValue=@(M_PI*2);a.duration=10;a.repeatCount=HUGE_VALF;[v.layer addAnimation:a forKey:@"pnp.rotation"];}
   else if(!rotate)[v.layer removeAnimationForKey:@"pnp.rotation"];
   continue;
  }
  if([name containsString:@"Routing"]||[name containsString:@"AirPlay"])pnpSetHidden(v,enabled&&!expanded&&pnpBool(@"HideRoutingIcon",NO));
  if([v isKindOfClass:UILabel.class]){NSString *text=((UILabel *)v).text ?: @"";if([text containsString:@"未在播放"]||[text localizedCaseInsensitiveContainsString:@"Not Playing"])pnpSetHidden(v,enabled&&!expanded&&pnpBool(@"HideNotPlaying",NO));}
  [queue addObjectsFromArray:v.subviews];
 }
 [CATransaction commit];
 }@catch(NSException *e){PNPLog(@"应用异常 %@",e.reason);}
 pnpBusy=NO;
}
static void pnpRefresh(void){for(UIView *v in pnpRoots.allObjects)pnpApply(v);}
static NSString *const kPIDomain=@"com.abgg332.driftisland";
static NSString *const kPIMaskDir=@"/var/mobile/灵动岛/遮罩素材";
static void pnpReload(void){
 CFPreferencesAppSynchronize(CFSTR("com.local.playerexact"));
 pnpNative=CFBridgingRelease(CFPreferencesCopyMultiple(NULL,CFSTR("com.local.playerexact"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost))?:@{};
 pnpPrefs=CFBridgingRelease(CFPreferencesCopyMultiple(NULL,CFSTR(kPIDomain),kCFPreferencesCurrentUser,kCFPreferencesAnyHost))?:@{};
 id asset=pnpPrefs[@"PlayerMaskAsset"];
 if(![asset isKindOfClass:NSString.class]) asset=pnpPrefs[@"diAlbumMaskAsset"];
 if([asset isKindOfClass:NSString.class]&&![asset containsString:@".."]&&![asset isAbsolutePath])
  pnpMask=[UIImage imageWithContentsOfFile:[kPIMaskDir stringByAppendingPathComponent:asset]];
 else pnpMask=nil;
 pnpRefresh();
}static void pnpApplyNowPlaying(NSDictionary *d){
 if([d isKindOfClass:NSDictionary.class]){
  id data=d[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
  pnpPlaying=[[d objectForKey:@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue]>.01;
  if([data isKindOfClass:NSData.class]&&![data isEqual:pnpArtData]){pnpArtData=data;UIImage *im=[UIImage imageWithData:data];
   if(im){UIGraphicsBeginImageContextWithOptions(CGSizeMake(256,256),NO,1);[im drawInRect:CGRectMake(0,0,256,256)];pnpArtwork=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();}
  }
 }else{pnpArtwork=nil;pnpArtData=nil;pnpPlaying=NO;}
}
static void pnpPoll(void){
 if(pnpQuery)return; // do not gate the whole feature chain on a guessed C symbol
 if(CFAbsoluteTimeGetCurrent()-pnpLastQuery<1)return;
 pnpLastQuery=CFAbsoluteTimeGetCurrent();pnpQuery=YES;
 NSDictionary *d=pnpNowPlayingInfo();
 pnpApplyNowPlaying(d);
 pnpQuery=NO;pnpRefresh();
}
static void(*pnpLayoutOrig)(id,SEL);
static void pnpLayout(id obj,SEL cmd){pnpLayoutOrig(obj,cmd);UIView *v=obj;if([NSStringFromClass(v.class) containsString:@"Activity"])return;[pnpRoots addObject:v];pnpApply(v);}
static void pnpInstall(void){
 static BOOL installed=NO;
 pnp31Install();if(installed)return;
 Class c=NSClassFromString(@"MRUNowPlayingView");if(!c)return;
 MSHookMessageEx(c,@selector(layoutSubviews),(IMP)pnpLayout,(IMP *)&pnpLayoutOrig);installed=YES;
 void(*disable)(BOOL)=(void(*)(BOOL))dlsym(RTLD_DEFAULT,"_Z28NPRSetArtworkRotationEnabledb");if(disable)disable(NO);
}
__attribute__((constructor))static void pnpStart(void){
 if(![NSProcessInfo.processInfo.processName isEqual:@"SpringBoard"])return;
 dispatch_async(dispatch_get_main_queue(),^{
  pnpRoots=[NSHashTable weakObjectsHashTable];pnpReload();
  int token;notify_register_dispatch("com.local.playerexact/artwork-changed",&token,dispatch_get_main_queue(),^(int t){(void)t;pnpReload();});
  for(int delay: {2,6,12,30})dispatch_after(dispatch_time(DISPATCH_TIME_NOW,delay*NSEC_PER_SEC),dispatch_get_main_queue(),^{pnpInstall();});
  NSTimer *timer=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t){(void)t;pnpInstall();pnpPoll();}];[NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
 });
}
