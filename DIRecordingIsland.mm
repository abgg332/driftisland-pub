#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <notify.h>
#include <math.h>

static NSString *const DIRIDomain=@"com.abgg332.driftisland";
static NSString *const DIRIIdentifier=@"systemApertureElementIdentifierScreenRecording";
static NSDictionary *diriPrefs;
static NSHashTable *diriViews;
static BOOL diriHooked=NO;
static id diriCall(id o,NSString *s) {
    SEL a=NSSelectorFromString(s);
    return o && [o respondsToSelector:a]?((id(*)(id,SEL))objc_msgSend)(o,a):nil;
}
static BOOL diriBool(NSString *k,BOOL d){id v=diriPrefs[k];return v?[v boolValue]:d;}
static double diriNumber(NSString *k,double d){id v=diriPrefs[k];double n=v?[v doubleValue]:d;return isfinite(n)?n:d;}
static void diriLog(NSString *s){NSLog(@"[DI录屏岛] %@",s);}
@interface DIRecordingIslandView : UIView
@property(nonatomic,strong) UIImageView *image;
@property(nonatomic,weak) UIView *source;
@property(nonatomic,assign) BOOL left;
@property(nonatomic,copy) NSString *loaded;
@property(nonatomic,assign) NSUInteger generation;
- (void)refresh;
- (void)applyAnimation;
@end
@implementation DIRecordingIslandView
- (instancetype)initWithFrame:(CGRect)f {
    if((self=[super initWithFrame:f])){
        self.userInteractionEnabled=NO;self.backgroundColor=UIColor.clearColor;self.clipsToBounds=NO;
        _image=[UIImageView new];_image.contentMode=UIViewContentModeScaleAspectFit;
        _image.userInteractionEnabled=NO;[self addSubview:_image];[diriViews addObject:self];
    }return self;
}
- (NSString *)key:(NSString *)s{return [NSString stringWithFormat:@"RecordingIsland%@%@",self.left?@"Mini":@"Trailing",s];}
- (void)refresh {
    BOOL on=diriBool(@"RecordingIslandEnabled",NO)&&diriBool([self key:@"Enabled"],YES);
    self.hidden=!on;
    if(!on){[self.image stopAnimating];return;}
    UIView *v=self.source;if(!v.window){[self.image stopAnimating];return;}
    CGFloat scale=MAX(.5,MIN(2,diriNumber([self key:@"ScalePercent"],100)/100.0));
    CGFloat size=MIN(v.bounds.size.width,v.bounds.size.height);
    if(size<2 || size>100){self.hidden=YES;return;}
    self.bounds=CGRectMake(0,0,size*scale,size*scale);
    self.center=CGPointMake(CGRectGetMidX(v.bounds)+diriNumber([self key:@"OffsetX"],0),CGRectGetMidY(v.bounds)+diriNumber([self key:@"OffsetY"],0));
    self.image.frame=self.bounds;
    NSString *name=diriPrefs[[self key:@"Asset"]];
    if(![name isKindOfClass:NSString.class]||!name.length||[name isEqualToString:@"default"]){
        name=diriPrefs[self.left?@"miniAlbumFolder":@"miniAudioFolder"];
        if(![name isKindOfClass:NSString.class]||!name.length)name=diriPrefs[@"animFolder"];
        if(![name isKindOfClass:NSString.class])name=@"";
    }
    // A material is a directory of ordered PNG/JPEG frames, not arbitrary code or a video overlay.
    if([name containsString:@"/"]||[name containsString:@".."]){self.hidden=YES;return;}
    NSString *base=@"/var/mobile/灵动岛/帧率素材";
    NSString *path=name.length?[base stringByAppendingPathComponent:name]:base;
    if(![self.loaded isEqualToString:path]){
        self.loaded=path;self.generation++;NSUInteger generation=self.generation;
        [self.image stopAnimating];self.image.animationImages=nil;self.image.image=nil;
        __weak DIRecordingIslandView *weak=self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            NSArray *names=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];
            names=[names sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b){return [a compare:b options:NSNumericSearch];}];
            NSMutableArray *frames=[NSMutableArray array];NSUInteger bytes=0;
            for(NSString *n in names){
                NSString *ext=n.pathExtension.lowercaseString;
                if(![@[@"png",@"jpg",@"jpeg",@"webp"] containsObject:ext])continue;
                UIImage *im=[UIImage imageWithContentsOfFile:[path stringByAppendingPathComponent:n]];
                if(!im)continue;
                NSUInteger cost=CGImageGetWidth(im.CGImage)*CGImageGetHeight(im.CGImage)*4;
                if(bytes+cost>32*1024*1024||frames.count>=600)break;
                bytes+=cost;[frames addObject:im];
            }
            dispatch_async(dispatch_get_main_queue(),^{
                DIRecordingIslandView *strong=weak;
                if(!strong||strong.generation!=generation)return;
                strong.image.animationImages=frames;strong.image.image=frames.firstObject;
                diriLog([NSString stringWithFormat:@"素材 %@ 帧=%lu",path,(unsigned long)frames.count]);
                [strong applyAnimation];
            });
        });
    }
    [self applyAnimation];
}
- (void)applyAnimation {
    double fps=MAX(0,MIN(1000,diriNumber([self key:@"FPS"],60)));
    if(self.hidden||!self.window||fps<=0){[self.image stopAnimating];}
    else if(self.image.animationImages.count>1){
        NSTimeInterval duration=self.image.animationImages.count/fps;
        if(fabs(self.image.animationDuration-duration)>.00001){[self.image stopAnimating];self.image.animationDuration=duration;}
        self.image.animationRepeatCount=0;if(!self.image.isAnimating)[self.image startAnimating];
    }
    BOOL rotate=diriBool([self key:@"Rotation"],NO);
    double speed=MAX(0,MIN(10,diriNumber([self key:@"RotationSpeed"],5)));
    BOOL reverse=diriBool([self key:@"Reverse"],NO);
    NSString *signature=[NSString stringWithFormat:@"%d-%.3f-%d",rotate,speed,reverse];
    if(![objc_getAssociatedObject(self.image,@selector(applyAnimation)) isEqual:signature]){
        objc_setAssociatedObject(self.image,@selector(applyAnimation),signature,OBJC_ASSOCIATION_COPY_NONATOMIC);
        [self.image.layer removeAnimationForKey:@"di.recording.rotation"];
        if(rotate&&speed>0){
            CABasicAnimation *a=[CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
            a.fromValue=@0;a.toValue=@((reverse?-1:1)*2*M_PI);a.duration=10.0/speed;
            a.repeatCount=HUGE_VALF;[self.image.layer addAnimation:a forKey:@"di.recording.rotation"];
        }
    }
}
- (void)didMoveToWindow{[super didMoveToWindow];if(!self.window)[self.image stopAnimating];else [self refresh];}
@end
static char diriKey;
static UIView *diriView(id obj,NSString *selector){id v=diriCall(obj,selector);return [v isKindOfClass:UIView.class]?v:nil;}
static void __attribute__((unused)) diriAttach(UIView *v,BOOL left){
    if(!v)return;
    DIRecordingIslandView *overlay=objc_getAssociatedObject(v,&diriKey);
    if(!diriBool(@"RecordingIslandEnabled",NO)){[overlay removeFromSuperview];return;}
    if(!overlay){overlay=[[DIRecordingIslandView alloc]initWithFrame:v.bounds];overlay.source=v;overlay.left=left;objc_setAssociatedObject(v,&diriKey,overlay,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    if(overlay.superview!=v)[v addSubview:overlay];
    [v bringSubviewToFront:overlay];[overlay refresh];
}
static BOOL diriRecording(id e){id ident=diriCall(e,@"elementIdentifier");return [ident isKindOfClass:NSString.class]&&[ident isEqualToString:DIRIIdentifier];}
static void diriApply(id e){
    if(!diriRecording(e))return;
    id host=diriCall(e,@"elementHost");
    id controller=[host isKindOfClass:NSClassFromString(@"SAUIElementViewController")]?host:nil;
    UIView *element=diriView(controller,@"_elementView");
    if(!element){diriLog(@"录屏活动已识别，但 elementHost/_elementView 尚未就绪");return;}
    // Two distinct overlays in the confirmed element view. Layout is our adaptation,
    // not an assumption that playback getters exist on a recording scene element.
    NSArray *views=objc_getAssociatedObject(element,&diriKey);
    if(![views isKindOfClass:NSArray.class]){
        NSMutableArray *created=[NSMutableArray array];
        for(int i=0;i<2;i++){
            UIView *slot=[[UIView alloc]initWithFrame:CGRectZero];slot.userInteractionEnabled=NO;slot.backgroundColor=UIColor.clearColor;slot.clipsToBounds=NO;
            DIRecordingIslandView *v=[[DIRecordingIslandView alloc]initWithFrame:CGRectZero];v.source=slot;v.left=(i==0);[slot addSubview:v];[element addSubview:slot];[created addObject:v];
        }
        views=created;objc_setAssociatedObject(element,&diriKey,views,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat side=MIN(22.0,element.bounds.size.height);
    for(NSUInteger i=0;i<views.count;i++){
        DIRecordingIslandView *v=views[i];UIView *slot=v.source;
        slot.frame=CGRectMake(i==0?CGRectGetMinX(element.bounds):CGRectGetMaxX(element.bounds)-side,CGRectGetMidY(element.bounds)-side/2,side,side);
        [v refresh];
    }
    diriLog([NSString stringWithFormat:@"录屏挂载 host=%@ element=%@ bounds=%@",NSStringFromClass([host class]),NSStringFromClass(element.class),NSStringFromCGRect(element.bounds)]);
}
static void(*diriTransitionOrig)(id,SEL,CGSize,id,id);
static void diriTransition(id self,SEL cmd,CGSize size,id container,id coordinator){
    diriTransitionOrig(self,cmd,size,container,coordinator);
    diriApply(self);
}
static void diriReload(int token){
    (void)token;CFPreferencesAppSynchronize((__bridge CFStringRef)DIRIDomain);
    diriPrefs=CFBridgingRelease(CFPreferencesCopyMultiple(NULL,(__bridge CFStringRef)DIRIDomain,kCFPreferencesCurrentUser,kCFPreferencesAnyHost))?:@{};
    for(DIRecordingIslandView *v in diriViews.allObjects){v.loaded=nil;[v refresh];}
}
static void diriInstall(void){
    if(diriHooked)return;
    Class c=NSClassFromString(@"SBSystemApertureSceneElement");
    SEL t=NSSelectorFromString(@"contentProviderWillTransitionToSize:inContainerView:transitionCoordinator:");
    if(!c||!class_getInstanceMethod(c,t))return;
    MSHookMessageEx(c,t,(IMP)diriTransition,(IMP *)&diriTransitionOrig);

    diriHooked=YES;diriLog(@"已挂 SBSystemApertureSceneElement transition / elementIdentifier / elementHost / _elementView");
}
__attribute__((constructor))static void diriStart(void){
    if(![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"])return;
    dispatch_async(dispatch_get_main_queue(),^{
        diriViews=[NSHashTable weakObjectsHashTable];diriReload(0);diriInstall();
        int token;notify_register_dispatch("com.abgg332.driftisland.reload",&token,dispatch_get_main_queue(),^(int t){diriReload(t);});
        for(int delay=1;delay<=15;delay+=7)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,delay*NSEC_PER_SEC),dispatch_get_main_queue(),^{diriInstall();});
    });
}
