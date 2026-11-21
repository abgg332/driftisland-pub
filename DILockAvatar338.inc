#include "DILockDiagnostic340.inc"
/* Lock-screen only. No custom imagery, CC changes, audio session or timer. */
@interface DILockAvatarState338 : NSObject
@property(nonatomic,assign) CGFloat radius;
@property(nonatomic,assign) BOOL clips;
@end
@implementation DILockAvatarState338 @end
static char diLockAvatarKey338,diLockAvatarPending338;
static NSHashTable<UIView *> *diLockAvatarViews338;
static CFTimeInterval diLockAvatarEpoch338;
// Lock-screen artwork may be a UIImageView inside a CS artwork host rather
// than MRUArtworkView. Reject notifications, controls, backgrounds and CC.
static BOOL diLockAvatarEligible338(UIView *v){
    if(!v.window || !diInLockScreen(v))return NO;
    BOOL art=NO,player=NO;int depth=0;
    for(UIView *p=v;p && p!=v.window && depth++<16;p=p.superview){
        NSString *n=NSStringFromClass(p.class);
        if([n containsString:@"MRUActivity"] || [n containsString:@"Aperture"] || [n containsString:@"Suggestion"] || [n containsString:@"ControlCenter"] || [n containsString:@"NotificationShortLook"] || [n containsString:@"NotificationLongLook"] || [n containsString:@"ActionButton"] || [n containsString:@"UIButton"])return NO;
        if([n containsString:@"Artwork"] || [n containsString:@"AlbumArt"]){art=YES;if([n hasPrefix:@"CS"])player=YES;}
        if([n containsString:@"NowPlaying"] || [n containsString:@"MediaControls"])player=YES;
    }
    NSString *own=NSStringFromClass(v.class);
    if([own containsString:@"Background"] || [own containsString:@"Material"] || [own containsString:@"Shadow"])return NO;
    BOOL picture=([v isKindOfClass:UIImageView.class] && ((UIImageView *)v).image!=nil) || v.layer.contents!=nil;
    BOOL named=[own containsString:@"Artwork"] || [own containsString:@"AlbumArt"];
    CGSize z=v.bounds.size;
    return art && (player || [own hasPrefix:@"CS"]) && (picture || named) && z.width>=24 && z.height>=24 && z.width<=600 && z.height<=600 && fabs(z.width-z.height)<=MAX(2,z.width*.06);
}
static void diLockAvatarApply338(UIView *v){
    DILockAvatarState338 *state=objc_getAssociatedObject(v,&diLockAvatarKey338);
    BOOL eligible=diLockAvatarEligible338(v);
    if(!enabled || !diLockAvatarOn338 || !eligible){
        [v.layer removeAnimationForKey:@"di.lockscreen.spin338"];
        if(state){v.layer.cornerRadius=state.radius;v.layer.masksToBounds=state.clips;objc_setAssociatedObject(v,&diLockAvatarKey338,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
        return;
    }
    if(!state){
        RLog(@"[锁屏头像339] 命中 %@ %.1fx%.1f window=%@",NSStringFromClass(v.class),v.bounds.size.width,v.bounds.size.height,NSStringFromClass(v.window.class));
        state=[DILockAvatarState338 new];state.radius=v.layer.cornerRadius;state.clips=v.layer.masksToBounds;objc_setAssociatedObject(v,&diLockAvatarKey338,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    [CATransaction begin];[CATransaction setDisableActions:YES];
    v.layer.cornerRadius=MIN(v.bounds.size.width,v.bounds.size.height)*.5;
    v.layer.masksToBounds=YES;
    [CATransaction commit];
    BOOL visible=!gScreenOff328 && !v.window.hidden;
    for(UIView *p=v;p && visible;p=p.superview)if(p.hidden || p.alpha<.01)visible=NO;
    if(!visible){[v.layer removeAnimationForKey:@"di.lockscreen.spin338"];return;}
    if(![v.layer animationForKey:@"di.lockscreen.spin338"]){
        CFTimeInterval now=CACurrentMediaTime();if(diLockAvatarEpoch338==0)diLockAvatarEpoch338=now;
        CABasicAnimation *spin=[CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue=@0;spin.toValue=@(2*M_PI);spin.duration=10;spin.repeatCount=HUGE_VALF;
        spin.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        spin.removedOnCompletion=NO;
        spin.beginTime=[v.layer convertTime:now-fmod(now-diLockAvatarEpoch338,10) fromLayer:nil];
        [v.layer addAnimation:spin forKey:@"di.lockscreen.spin338"];
    }
}
static void diLockAvatarObserve338(UIView *v){
    if(!NSThread.isMainThread)return;
    if(!diLockAvatarEligible338(v) && !objc_getAssociatedObject(v,&diLockAvatarKey338))return;
    if(!diLockAvatarViews338)diLockAvatarViews338=[NSHashTable weakObjectsHashTable];
    [diLockAvatarViews338 addObject:v];
    if([objc_getAssociatedObject(v,&diLockAvatarPending338) boolValue])return;
    objc_setAssociatedObject(v,&diLockAvatarPending338,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weak=v;
    dispatch_async(dispatch_get_main_queue(),^{UIView *art=weak;if(!art)return;objc_setAssociatedObject(art,&diLockAvatarPending338,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);diLockAvatarApply338(art);});
}
static void diLockAvatarRefresh338(void){
    diLockDiagnosticPublish340();
    if(diLockAvatarOn338 && !gScreenOff328){
        for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
            if(![scene isKindOfClass:UIWindowScene.class])continue;
            for(UIWindow *window in ((UIWindowScene *)scene).windows)if(diIsLockScreenWindow(window))diLockAvatarDiscover339(window);
        }
    }
    for(UIView *v in diLockAvatarViews338.allObjects)diLockAvatarApply338(v);
}
static void diLockAvatarStop338(void){
    for(UIView *v in diLockAvatarViews338.allObjects)[v.layer removeAnimationForKey:@"di.lockscreen.spin338"];
}

static void diLockAvatarDiscover339(UIView *root){
    if(!enabled || !diLockAvatarOn338 || gScreenOff328 || !root.window || !diInLockScreen(root))return;
    static BOOL pending=NO;static CFTimeInterval last=0;
    CFTimeInterval now=CACurrentMediaTime();
    if(pending || now-last<.5)return;pending=YES;last=now;
    __weak UIView *weak=root.window;
    dispatch_async(dispatch_get_main_queue(),^{
        pending=NO;UIView *view=weak;if(!view || !diLockAvatarOn338 || gScreenOff328)return;
        // Scan only the relevant lock-screen root, once per layout batch. No timer.
        NSMutableArray<UIView *> *queue=[NSMutableArray arrayWithObject:view];NSUInteger index=0,hits=0;
        while(index<queue.count && index<600){
            UIView *node=queue[index++];
            if(diLockAvatarEligible338(node)){
                BOOL nested=NO;
                for(UIView *parent=node.superview;parent && parent!=node.window;parent=parent.superview)
                    if(objc_getAssociatedObject(parent,&diLockAvatarKey338)){nested=YES;break;}
                if(!nested){diLockAvatarObserve338(node);hits++;}
                continue;
            }
            for(UIView *child in node.subviews)if(queue.count<600)[queue addObject:child];
        }
        static CFTimeInterval report=0;
        if(CACurrentMediaTime()-report>10){
            report=CACurrentMediaTime();
            RLog(@"[锁屏头像339] 查找 root=%@ nodes=%lu candidates=%lu enabled=%d",NSStringFromClass(view.class),(unsigned long)index,(unsigned long)hits,diLockAvatarOn338);
            if(!hits)diLockDiagnosticDump340(view,NO);
        }
    });
}
