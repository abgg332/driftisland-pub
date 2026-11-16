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
static NSHashTable *diriScenes;
static char diriSceneKey;
static BOOL diriApplying=NO;
static NSHashTable *diriElements;
extern "C" BOOL DIRecordingIslandExclusive(void);
static BOOL diriRecording(id e);
static char diriOwnerKey;
extern "C" void DIRecordingIslandLog(NSString *message);
static id diriCall(id o,NSString *s) {
    SEL a=NSSelectorFromString(s);
    return o && [o respondsToSelector:a]?((id(*)(id,SEL))objc_msgSend)(o,a):nil;
}
static BOOL diriBool(NSString *k,BOOL d){id v=diriPrefs[k];return v?[v boolValue]:d;}
static double diriNumber(NSString *k,double d){id v=diriPrefs[k];double n=v?[v doubleValue]:d;return isfinite(n)?n:d;}
static void diriLog(NSString *s){DIRecordingIslandLog(s);}
@interface DIRecordingIslandView : UIView
@property(nonatomic,strong) UIImageView *image;
@property(nonatomic,weak) UIView *source;
@property(nonatomic,weak) id scene;
@property(nonatomic,weak) UIView *element;
@property(nonatomic,weak) UIView *nativeSlot;
@property(nonatomic,strong) NSNumber *savedAlpha;
- (void)restoreNative;
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
- (void)restoreNative {
    if(self.savedAlpha && self.nativeSlot) self.nativeSlot.layer.opacity=self.savedAlpha.floatValue;
    self.savedAlpha=nil;
}
- (void)refresh {
    BOOL on=diriBool(@"RecordingIslandEnabled",NO)&&diriBool([self key:@"Enabled"],YES)
        && self.scene && diriRecording(self.scene)
        && objc_getAssociatedObject(self.element,&diriOwnerKey)==self.scene
        && self.element.window && !self.source.hidden
        && (diriCall(diriCall(self.scene,@"elementHost"),@"_elementView")==self.element
            || diriCall(self.scene,@"elementHost")==self.element);
    self.hidden=!on;
    if(!on){[self.image stopAnimating];[self restoreNative];return;}
    UIView *v=self.source;if(!v.window){[self.image stopAnimating];return;}
    CGFloat scale=MAX(.5,MIN(2,diriNumber([self key:@"ScalePercent"],100)/100.0));
    CGFloat size=MIN(v.bounds.size.width,v.bounds.size.height);
    if(size<2 || size>100){self.hidden=YES;return;}
    self.bounds=CGRectMake(0,0,size*scale,size*scale);
    self.center=CGPointMake(CGRectGetMidX(v.bounds)+diriNumber([self key:@"OffsetX"],0),CGRectGetMidY(v.bounds)+diriNumber([self key:@"OffsetY"],0));
    self.image.frame=self.bounds;
    NSString *name=diriPrefs[[self key:@"Asset"]];
    if(![name isKindOfClass:NSString.class]||!name.length||[name isEqualToString:@"default"]){
        name=diriPrefs[self.left?@"smallAnimFolder":@"miniAudioFolder"];
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
                [strong refresh]; // revalidate scene ownership before exposing decoded frames
            });
        });
    }
    [self applyAnimation];
}
- (void)applyAnimation {
    double fps=MAX(0,MIN(1000,diriNumber([self key:@"FPS"],60)));
    if(self.hidden||!self.window||fps<=0){[self.image stopAnimating];[self restoreNative];}
    else if(self.image.image && self.nativeSlot){
        if(!self.savedAlpha)self.savedAlpha=@(self.nativeSlot.layer.opacity);
        self.nativeSlot.layer.opacity=0; // suppress pixels only; original hit testing/action remains.
    }
    if(!self.hidden && self.window && fps>0 && self.image.animationImages.count>1)
    {
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
- (void)didMoveToWindow{[super didMoveToWindow];if(!self.window){[self.image stopAnimating];[self restoreNative];}else [self refresh];}
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
static BOOL diriRecording(id e){
    id ident=diriCall(e,@"elementIdentifier");
    if(![ident isKindOfClass:NSString.class])return NO;
    // The exported constant name is not necessarily its NSString value on iOS16.
    return [ident isEqualToString:@"screenRecording"] || [ident isEqualToString:DIRIIdentifier];
}
static void diriClear(UIView *element){
    NSArray *views=objc_getAssociatedObject(element,&diriKey);
    for(DIRecordingIslandView *v in views){[v restoreNative];[v.image stopAnimating];v.generation++;[v.source removeFromSuperview];}
    objc_setAssociatedObject(element,&diriKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(element,&diriOwnerKey,nil,OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(element,&diriSceneKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
extern "C" BOOL DIRecordingIslandExclusive(void){
    if(!diriBool(@"RecordingIslandEnabled",NO))return NO;
    for(UIView *v in diriElements.allObjects){
        NSArray *overlays=objc_getAssociatedObject(v,&diriKey);
        id scene=((DIRecordingIslandView *)overlays.firstObject).scene;
        if(v.window && !v.hidden && v.alpha>0.01 && diriRecording(scene))return YES;
    }
    return NO;
}
static void diriApply(id e){
    id host=diriCall(e,@"elementHost");
    UIView *element=diriView(host,@"_elementView");
    if(!element && [host isKindOfClass:UIView.class])element=host;
    // A reused element must relinquish recording content even for non-recording callbacks.
    if(!diriRecording(e)){
        for(UIView *v in diriElements.allObjects)
            if(v==element || objc_getAssociatedObject(v,&diriOwnerKey)==e)diriClear(v);
        return;
    }
    [diriScenes addObject:e];
    if(!element)return;
    [diriElements addObject:element];
    id old=objc_getAssociatedObject(element,&diriOwnerKey);
    if(old && old!=e)diriClear(element);
    if(!diriBool(@"RecordingIslandEnabled",NO)){diriClear(element);return;}
    objc_setAssociatedObject(element,&diriOwnerKey,e,OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(element,&diriSceneKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Prefer native provided-view containers; never assume both sides exist in minimal mode.
    NSMutableArray *native=[NSMutableArray array],*queue=[NSMutableArray arrayWithObject:element];
    for(int guard=0;queue.count && guard<100;guard++){
        UIView *v=queue.firstObject;[queue removeObjectAtIndex:0];
        if([v isKindOfClass:DIRecordingIslandView.class] || [v.accessibilityIdentifier isEqualToString:@"di.recording.slot"])continue;
        if([NSStringFromClass(v.class) isEqualToString:@"_SAUIProvidedViewContainerView"]){[native addObject:v];continue;}
        [queue addObjectsFromArray:v.subviews];
    }
    NSMutableArray *transforms=[NSMutableArray array];
    for(NSString *selector in @[@"leadingTransformView",@"trailingTransformView",@"minimalTransformView"]){
        UIView *slot=diriView(element,selector);
        if(slot && !slot.hidden && slot.window && slot.bounds.size.width>1 && slot.bounds.size.height>1 && (slot==element || [slot isDescendantOfView:element])){
            if(![transforms containsObject:slot])[transforms addObject:slot];
        }
    }
    // Exclude detached/inactive presentation branches and duplicate geometry.
    NSMutableArray *distinct=[NSMutableArray array];
    for(UIView *slot in transforms){
        BOOL visible=YES;
        for(UIView *a=slot;a && a!=element;a=a.superview)if(a.hidden || a.alpha<0.01){visible=NO;break;}
        if(!visible || slot==element)continue;
        CGRect rect=[slot convertRect:slot.bounds toView:element];
        if(!CGRectIntersectsRect(rect,element.bounds))continue;
        BOOL duplicate=NO;
        for(UIView *v in distinct){
            CGRect r=[v convertRect:v.bounds toView:element];
            CGRect intersection=CGRectIntersection(rect,r);
            CGFloat area=MIN(rect.size.width*rect.size.height,r.size.width*r.size.height);
            if(area>0 && !CGRectIsNull(intersection) && intersection.size.width*intersection.size.height>area*0.65){duplicate=YES;break;}
        }
        if(!duplicate)[distinct addObject:slot];
    }
    if(distinct.count)native=distinct;
    [native sortUsingComparator:^NSComparisonResult(UIView *a,UIView *b){
        CGFloat x=[a convertPoint:CGPointZero toView:element].x,y=[b convertPoint:CGPointZero toView:element].x;
        return x<y?NSOrderedAscending:x>y?NSOrderedDescending:NSOrderedSame;
    }];
    NSArray *views=objc_getAssociatedObject(element,&diriKey);
    if(!views){
        NSMutableArray *made=[NSMutableArray array];
        for(int i=0;i<2;i++){
            UIView *slot=[UIView new];slot.accessibilityIdentifier=@"di.recording.slot";slot.userInteractionEnabled=NO;slot.clipsToBounds=NO;slot.hidden=YES;
            DIRecordingIslandView *v=[[DIRecordingIslandView alloc]initWithFrame:CGRectZero];v.source=slot;v.scene=e;v.element=element;v.left=i==0;
            [slot addSubview:v];[element addSubview:slot];[made addObject:v];
        }
        views=made;objc_setAssociatedObject(element,&diriKey,views,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for(NSUInteger i=0;i<views.count;i++){
        DIRecordingIslandView *v=views[i];UIView *target=i<native.count?native[i]:nil;
        [v restoreNative];v.nativeSlot=target;
        BOOL available=target!=nil;
        // Without a verified second slot, do not draw two materials into a 38pt island.
        if(!native.count && i==0 && element.bounds.size.width>2 && element.bounds.size.width<=60)available=YES;
        v.source.hidden=!available;
        if(available){v.source.frame=target?[target convertRect:target.bounds toView:element]:element.bounds;[element bringSubviewToFront:v.source];}
        [v refresh];
    }
    static CFAbsoluteTime last=0;
    if(CFAbsoluteTimeGetCurrent()-last>2){last=CFAbsoluteTimeGetCurrent();diriLog([NSString stringWithFormat:@"活动隔离 id=%@ element=%p bounds=%@ 原生槽=%lu",diriCall(e,@"elementIdentifier"),element,NSStringFromCGRect(element.bounds),(unsigned long)native.count]);}
}
static void(*diriTransitionOrig)(id,SEL,CGSize,id,id);
static void diriTransition(id self,SEL cmd,CGSize size,id container,id coordinator){
    diriTransitionOrig(self,cmd,size,container,coordinator);
    id ident=diriCall(self,@"elementIdentifier");
    static NSUInteger observed=0;
    if(observed++<12)diriLog([NSString stringWithFormat:@"transition 标识=%@ 类型=%@ host=%@ 容器=%@ size=%@",ident,NSStringFromClass([ident class]),NSStringFromClass([diriCall(self,@"elementHost") class]),NSStringFromClass([container class]),NSStringFromCGSize(size)]);
    diriApply(self);
    if(diriRecording(self)){
        __weak id weak=self;
        dispatch_async(dispatch_get_main_queue(),^{id scene=weak;if(scene)diriApply(scene);});
    }
}
static void diriReload(int token){
    (void)token;CFPreferencesAppSynchronize((__bridge CFStringRef)DIRIDomain);
    diriPrefs=CFBridgingRelease(CFPreferencesCopyMultiple(NULL,(__bridge CFStringRef)DIRIDomain,kCFPreferencesCurrentUser,kCFPreferencesAnyHost))?:@{};
    diriLog([NSString stringWithFormat:@"配置 总=%d 左=%@ 右=%@ scenes=%lu",diriBool(@"RecordingIslandEnabled",NO),diriPrefs[@"RecordingIslandMiniAsset"],diriPrefs[@"RecordingIslandTrailingAsset"],(unsigned long)diriScenes.count]);
    for(DIRecordingIslandView *v in diriViews.allObjects){v.loaded=nil;[v refresh];}
    for(UIView *element in diriElements.allObjects){
        NSArray *views=objc_getAssociatedObject(element,&diriKey);
        id owner=((DIRecordingIslandView *)views.firstObject).scene;
        if(owner)diriApply(owner);else diriClear(element);
    }
}
static void(*diriLayoutOrig)(id,SEL);
static void diriLayout(id self,SEL cmd){
    diriLayoutOrig(self,cmd);
    if(diriApplying || !objc_getAssociatedObject(self,&diriSceneKey))return;
    diriApplying=YES;
    NSArray *overlays=objc_getAssociatedObject(self,&diriKey);
    id scene=((DIRecordingIslandView *)overlays.firstObject).scene;
    if(scene)diriApply(scene);else diriClear(self);
    diriApplying=NO;
}
static void diriInstall(void){
    if(diriHooked)return;
    Class c=NSClassFromString(@"SBSystemApertureSceneElement");
    SEL t=NSSelectorFromString(@"contentProviderWillTransitionToSize:inContainerView:transitionCoordinator:");
    if(!c||!class_getInstanceMethod(c,t))return;
    MSHookMessageEx(c,t,(IMP)diriTransition,(IMP *)&diriTransitionOrig);

    Class view=NSClassFromString(@"SAUIElementView");
    if(view && class_getInstanceMethod(view,@selector(layoutSubviews)))MSHookMessageEx(view,@selector(layoutSubviews),(IMP)diriLayout,(IMP *)&diriLayoutOrig);
    diriHooked=YES;diriLog(@"已挂 SBSystemApertureSceneElement transition / elementIdentifier / elementHost / _elementView");
}
__attribute__((constructor))static void diriStart(void){
    if(![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"])return;
    dispatch_async(dispatch_get_main_queue(),^{
        diriViews=[NSHashTable weakObjectsHashTable];diriScenes=[NSHashTable weakObjectsHashTable];diriElements=[NSHashTable weakObjectsHashTable];diriReload(0);diriInstall();
        int token;notify_register_dispatch("com.abgg332.driftisland.reload",&token,dispatch_get_main_queue(),^(int t){diriReload(t);});
        for(int delay=1;delay<=15;delay+=7)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,delay*NSEC_PER_SEC),dispatch_get_main_queue(),^{diriInstall();});
    });
}
