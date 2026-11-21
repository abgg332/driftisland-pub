/* Lock-screen only. No custom imagery, CC changes, audio session or timer. */
@interface DILockAvatarState338 : NSObject
@property(nonatomic,assign) CGFloat radius;
@property(nonatomic,assign) BOOL clips;
@end
@implementation DILockAvatarState338 @end
static char diLockAvatarKey338,diLockAvatarPending338;
static NSHashTable<UIView *> *diLockAvatarViews338;
static CFTimeInterval diLockAvatarEpoch338;
static BOOL diLockAvatarEligible338(UIView *v){
    if(!v.window || !diInLockScreen(v))return NO;
    BOOL player=NO;
    for(UIView *p=v;p && p!=v.window;p=p.superview){
        NSString *n=NSStringFromClass(p.class);
        if([n containsString:@"Activity"] || [n containsString:@"Aperture"] || [n containsString:@"Suggestion"] || [n containsString:@"ControlCenter"])return NO;
        if([n containsString:@"NowPlaying"] || [n containsString:@"MediaControls"])player=YES;
    }
    CGSize z=v.bounds.size;
    return player && z.width>=24 && z.height>=24 && z.width<=600 && z.height<=600 && fabs(z.width-z.height)<=MAX(2,z.width*.06);
}
static void diLockAvatarApply338(UIView *v){
    DILockAvatarState338 *state=objc_getAssociatedObject(v,&diLockAvatarKey338);
    BOOL eligible=diLockAvatarEligible338(v);
    if(!enabled || !diLockAvatarOn338 || !eligible){
        [v.layer removeAnimationForKey:@"di.lockscreen.spin338"];
        if(state){v.layer.cornerRadius=state.radius;v.layer.masksToBounds=state.clips;objc_setAssociatedObject(v,&diLockAvatarKey338,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
        return;
    }
    if(!state){state=[DILockAvatarState338 new];state.radius=v.layer.cornerRadius;state.clips=v.layer.masksToBounds;objc_setAssociatedObject(v,&diLockAvatarKey338,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
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
    for(UIView *v in diLockAvatarViews338.allObjects)diLockAvatarApply338(v);
}
static void diLockAvatarStop338(void){
    for(UIView *v in diLockAvatarViews338.allObjects)[v.layer removeAnimationForKey:@"di.lockscreen.spin338"];
}
