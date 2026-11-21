/* N95-style lock-screen artwork masking, confined to MediaRemoteUI cover-sheet views.
   Uses the system artworkImageView and UIView.maskView; no remote whole-card clipping. */
@interface DILockMRUMaskState342 : NSObject
@property(nonatomic,weak) UIView *host;
@property(nonatomic,weak) UIView *artwork;
@property(nonatomic,strong) UIView *maskView;
@property(nonatomic,strong) UIImageView *shapeView;
@property(nonatomic,strong) UIView *originalMaskView;
@property(nonatomic,assign) BOOL installed;
@end
@implementation DILockMRUMaskState342 @end
static char diLockMRUStateKey342;
static NSHashTable<UIView *> *diLockMRUHosts342;
static NSMutableDictionary<NSString *,NSValue *> *diLockMRUOriginals342;
static NSMutableSet<NSString *> *diLockMRUInstalled342;
static CFTimeInterval diLockMRUSpinEpoch342;
static BOOL diLockMRUScreenOff342;
static BOOL diLockMRUDisplayHooked342;
static int diLockMRUDisplayToken342=-1;
static void diLockMRUDisplayChanged342(void){
    uint64_t state=2;if(notify_get_state(diLockMRUDisplayToken342,&state)!=NOTIFY_STATUS_OK || state>1)return;
    diLockMRUScreenOff342=(state==0);
    for(UIView *v in diLockMRUHosts342.allObjects)diLockMRUApply342(v);
}
static void diLockMRUInstallDisplayHook342(void){
    if(diLockMRUDisplayHooked342)return;diLockMRUDisplayHooked342=YES;
    uint32_t r=notify_register_dispatch("com.apple.iokit.hid.displayStatus",&diLockMRUDisplayToken342,dispatch_get_main_queue(),^(int t){diLockMRUDisplayChanged342();});
    if(r==NOTIFY_STATUS_OK)diLockMRUDisplayChanged342();
}

static BOOL diLockMRUOn342(void){
    static CFAbsoluteTime last=0;static BOOL on=NO;CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    if(now-last>.5){last=now;NSDictionary *d=[NSDictionary dictionaryWithContentsOfFile:[diMruSelfDir() stringByAppendingPathComponent:@"params.plist"]];
        id v=d[@"lockAvatar"];if(v)on=[v respondsToSelector:@selector(boolValue)]?[v boolValue]:NO;
        else {BOOL file=NO;if(diMruReadFilePref(@"LockScreenAvatarOn",&file))on=file;else on=NO;}}
    return on;
}
static NSString *diLockMRUController342(UIView *host){
    NSMutableArray<NSString *> *names=[NSMutableArray array];UIViewController *vc=diActivityAncestorVC(host);
    for(UIViewController *c=vc;c;c=c.parentViewController){NSString *n=NSStringFromClass(c.class);if(n.length)[names addObject:n];if(names.count>=8)break;}
    if(!names.count){for(UIResponder *r=host;r;r=r.nextResponder){if([r isKindOfClass:UIViewController.class]){NSString *n=NSStringFromClass(r.class);if(n.length)[names addObject:n];if(names.count>=8)break;}}}
    return names.count?[names componentsJoinedByString:@"<-"]:@"(none)";
}
static BOOL diLockMRUIsCover342(UIView *host,NSString **ownerOut){
    NSString *owner=diLockMRUController342(host);if(ownerOut)*ownerOut=owner;
    if([owner containsString:@"CoverSheet"] || [owner containsString:@"LockScreen"])return YES;
    // The iOS 17 activity artwork is owned by this MRU controller. Accept it
    // only when no active compact/expanded island form owns the same content.
    if([owner containsString:@"MRUActivityNowPlayingViewController"])return diMruFormFromIsland()<0;
    for(UIView *p=host;p;p=p.superview){NSString *n=NSStringFromClass(p.class);if([n containsString:@"CoverSheet"]||[n containsString:@"LockScreen"])return YES;}
    return NO;
}
static BOOL diLockMRUHostClass342(UIView *v){
    NSString *n=NSStringFromClass(v.class);
    return [n isEqualToString:@"MRUArtworkView"] || [n isEqualToString:@"MRUActivityArtworkView"] || [n isEqualToString:@"MRUFlippingArtworkView"];
}
static UIView *diLockMRUArtworkView342(UIView *host){
    for(NSString *s in @[@"artworkImageView",@"coverArtImageView",@"albumCoverImageView"]){SEL sel=NSSelectorFromString(s);
        if([host respondsToSelector:sel]){@try{id v=((id(*)(id,SEL))objc_msgSend)(host,sel);if([v isKindOfClass:UIImageView.class])return v;}@catch(__unused NSException *e){}}}
    if([NSStringFromClass(host.class) isEqualToString:@"MRUFlippingArtworkView"]){
        UIImage *image=nil;SEL imageSel=NSSelectorFromString(@"artworkImage");
        if([host respondsToSelector:imageSel]){@try{id v=((id(*)(id,SEL))objc_msgSend)(host,imageSel);if([v isKindOfClass:UIImage.class])image=v;}@catch(__unused NSException *e){}}
        SEL layerSel=NSSelectorFromString(@"artworkLayer");if(!image && [host respondsToSelector:layerSel]){@try{id l=((id(*)(id,SEL))objc_msgSend)(host,layerSel);if([l isKindOfClass:CALayer.class]){id c=[(CALayer *)l contents];if(c&&CFGetTypeID((__bridge CFTypeRef)c)==CGImageGetTypeID())image=[UIImage imageWithCGImage:(__bridge CGImageRef)c];}}@catch(__unused NSException *e){}}
        if(image)return host;
    }
    return nil;
}
static UIImage *diLockMRUShape342(void){
    NSString *path=[diMruSelfDir() stringByAppendingPathComponent:@"mask.png"];
    UIImage *asset=diMaskAlphaCached(path);if(asset)return asset;
    static UIImage *circle;static dispatch_once_t once;dispatch_once(&once,^{
        CGSize z=CGSizeMake(256,256);UIGraphicsBeginImageContextWithOptions(z,NO,1.0);CGContextRef c=UIGraphicsGetCurrentContext();
        CGContextSetShouldAntialias(c,YES);CGContextSetFillColorWithColor(c,UIColor.whiteColor.CGColor);
        CGContextFillEllipseInRect(c,CGRectInset((CGRect){CGPointZero,z},1,1));
        circle=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();
    });return circle;
}
static NSString *diLockMRUKey342(Class cls,SEL sel){return [NSString stringWithFormat:@"%@|%@",NSStringFromClass(cls),NSStringFromSelector(sel)];}
static IMP diLockMRUOrig342(id self,SEL sel){
    for(Class c=object_getClass(self);c;c=class_getSuperclass(c)){NSValue *v=diLockMRUOriginals342[diLockMRUKey342(c,sel)];if(v)return (IMP)v.pointerValue;}
    return NULL;
}
static BOOL diLockMRUVisible342(UIView *v){
    if(diLockMRUScreenOff342 || !v || v.hidden || v.alpha<.01)return NO;
    for(UIView *p=v.superview;p;p=p.superview)if(p.hidden||p.alpha<.01)return NO;
    return YES;
}
static void diLockMRUTeardown342(UIView *host,DILockMRUMaskState342 *st){
    if(!st)return;UIView *art=st.artwork;
    [art.layer removeAnimationForKey:@"di.lockscreen.spin342"];
    if(art.maskView==st.maskView)art.maskView=st.originalMaskView;
    st.installed=NO;objc_setAssociatedObject(host,&diLockMRUStateKey342,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void diLockMRUApply342(UIView *host){
    if(!NSThread.isMainThread || !host || !diLockMRUHostClass342(host))return;
    DILockMRUMaskState342 *st=objc_getAssociatedObject(host,&diLockMRUStateKey342);
    NSString *owner=nil;BOOL lockContext=diLockMRUIsCover342(host,&owner),on=diLockMRUOn342();
    if(on && !lockContext){static NSMutableDictionary<NSString *,NSNumber *> *last;static dispatch_once_t once;dispatch_once(&once,^{last=[NSMutableDictionary dictionary];});NSString *k=NSStringFromClass(host.class);CFTimeInterval now=CFAbsoluteTimeGetCurrent();if(now-[last[k] doubleValue]>10){last[k]=@(now);diMruFileLog([NSString stringWithFormat:@"[锁屏蒙版342] 候选 %@ 未应用：owner=%@（等待CoverSheet上下文）",k,owner?:@"?"]);}}
    if(!on || !lockContext){if(st)diLockMRUTeardown342(host,st);return;}
    UIView *art=diLockMRUArtworkView342(host);
    if(!art || art.bounds.size.width<12 || art.bounds.size.height<12)return;
    if(st && st.artwork!=art){diLockMRUTeardown342(host,st);st=nil;}
    if(!st){st=[DILockMRUMaskState342 new];st.host=host;st.artwork=art;st.originalMaskView=art.maskView;
        st.maskView=[UIView new];st.maskView.userInteractionEnabled=NO;st.maskView.opaque=NO;st.maskView.backgroundColor=UIColor.clearColor;
        st.maskView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        st.shapeView=[UIImageView new];st.shapeView.frame=st.maskView.bounds;st.shapeView.userInteractionEnabled=NO;st.shapeView.opaque=NO;st.shapeView.backgroundColor=UIColor.clearColor;
        st.shapeView.contentMode=UIViewContentModeScaleToFill;st.shapeView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[st.maskView addSubview:st.shapeView];
        objc_setAssociatedObject(host,&diLockMRUStateKey342,st,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RLog(@"[锁屏蒙版342] 命中 host=%@ artwork=%@ size=%.0fx%.0f owner=%@",NSStringFromClass(host.class),NSStringFromClass(art.class),art.bounds.size.width,art.bounds.size.height,owner?:@"?");
    }
    UIImage *shape=diLockMRUShape342();if(st.shapeView.image!=shape)st.shapeView.image=shape;
    if(!CGRectEqualToRect(st.maskView.frame,art.bounds))st.maskView.frame=art.bounds;
    if(!CGRectEqualToRect(st.shapeView.frame,st.maskView.bounds))st.shapeView.frame=st.maskView.bounds;
    if(art.maskView!=st.maskView)art.maskView=st.maskView;
    st.installed=YES;
    if(diLockMRUVisible342(host) && ![art.layer animationForKey:@"di.lockscreen.spin342"]){
        CFTimeInterval now=CACurrentMediaTime();if(diLockMRUSpinEpoch342==0)diLockMRUSpinEpoch342=now;
        CABasicAnimation *a=[CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];a.fromValue=@0;a.toValue=@(2*M_PI);a.duration=10;a.repeatCount=HUGE_VALF;
        a.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];a.removedOnCompletion=NO;
        a.beginTime=[art.layer convertTime:now-fmod(now-diLockMRUSpinEpoch342,10) fromLayer:nil];[art.layer addAnimation:a forKey:@"di.lockscreen.spin342"];
    }else if(!diLockMRUVisible342(host))[art.layer removeAnimationForKey:@"di.lockscreen.spin342"];
}
static void diLockMRUScanView342(UIView *root){
    if(!root)return;NSMutableArray<UIView *> *q=[NSMutableArray arrayWithObject:root];NSUInteger i=0;
    while(i<q.count && i<1500){UIView *v=q[i++];if(diLockMRUHostClass342(v)){diLockMRUApply342(v);continue;}for(UIView *x in v.subviews)if(q.count<1500)[q addObject:x];}
}
static void diLockMRUTrack342(id self){
    if(!NSThread.isMainThread || !self)return;
    if([self isKindOfClass:UIViewController.class]){diLockMRUScanView342(((UIViewController *)self).view);return;}
    if(![self isKindOfClass:UIView.class])return;
    UIView *v=(UIView *)self;
    if(diLockMRUHostClass342(v)){
        if(!diLockMRUHosts342)diLockMRUHosts342=[NSHashTable weakObjectsHashTable];[diLockMRUHosts342 addObject:v];diLockMRUApply342(v);
    }else if([NSStringFromClass(v.class) containsString:@"NowPlaying"] || [NSStringFromClass(v.class) isEqualToString:@"MRUCoverSheetViewController"]){
        UIView *root=[v isKindOfClass:UIViewController.class]?((UIViewController *)v).view:v;diLockMRUScanView342(root);
    }
}
static void diLockMRULayout342(id self,SEL cmd){IMP o=diLockMRUOrig342(self,cmd);if(o)((void(*)(id,SEL))o)(self,cmd);diLockMRUTrack342(self);}
static void diLockMRUMoveSuperview342(id self,SEL cmd){IMP o=diLockMRUOrig342(self,cmd);if(o)((void(*)(id,SEL))o)(self,cmd);diLockMRUTrack342(self);}
static void diLockMRUMoveWindow342(id self,SEL cmd){IMP o=diLockMRUOrig342(self,cmd);if(o)((void(*)(id,SEL))o)(self,cmd);diLockMRUTrack342(self);}
static void diLockMRUVisibility342(id self,SEL cmd){IMP o=diLockMRUOrig342(self,cmd);if(o)((void(*)(id,SEL))o)(self,cmd);diLockMRUTrack342(self);}
static id diLockMRUInit342(id self,SEL cmd){IMP o=diLockMRUOrig342(self,cmd);id r=o?((id(*)(id,SEL))o)(self,cmd):self;if(r)diLockMRUTrack342(r);return r;}
static BOOL diLockMRUVoid2Args342(Class cls,SEL sel){Method m=class_getInstanceMethod(cls,sel);if(!m||method_getNumberOfArguments(m)!=2)return NO;char *r=method_copyReturnType(m);BOOL ok=r&&!strcmp(r,"v");free(r);return ok;}
static BOOL diLockMRUObject2Args342(Class cls,SEL sel){Method m=class_getInstanceMethod(cls,sel);if(!m||method_getNumberOfArguments(m)!=2)return NO;char *r=method_copyReturnType(m);BOOL ok=r&&!strcmp(r,"@");free(r);return ok;}
static void diLockMRUHook342(Class cls,SEL sel,IMP replacement,BOOL objectReturn){
    if(!cls)return;NSString *key=diLockMRUKey342(cls,sel);if(diLockMRUInstalled342 && [diLockMRUInstalled342 containsObject:key])return;
    Method m=class_getInstanceMethod(cls,sel);if(!m)return;
    // A superclass hook already covers inherited implementations; avoid stacking it twice.
    unsigned int n=0;Method *ms=class_copyMethodList(cls,&n);BOOL direct=NO;for(unsigned int i=0;i<n;i++)if(method_getName(ms[i])==sel){direct=YES;break;}free(ms);if(!direct)return;
    IMP old=NULL;MSHookMessageEx(cls,sel,replacement,&old);if(!old)return;
    if(!diLockMRUOriginals342)diLockMRUOriginals342=[NSMutableDictionary dictionary];if(!diLockMRUInstalled342)diLockMRUInstalled342=[NSMutableSet set];
    diLockMRUOriginals342[key]=[NSValue valueWithPointer:(void *)old];[diLockMRUInstalled342 addObject:key];
    diMruFileLog([NSString stringWithFormat:@"lock hook %@ %@ orig=%p",NSStringFromClass(cls),NSStringFromSelector(sel),old]);
}
static void diLockMRUInstall342(void){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{diLockMRUInstall342();});return;}
    diLockMRUInstallDisplayHook342();
    for(NSString *name in @[@"MRUArtworkView",@"MRUActivityArtworkView",@"MRUFlippingArtworkView",@"MRUNowPlayingView"]){Class c=NSClassFromString(name);if(!c||![c isSubclassOfClass:UIView.class])continue;
        SEL layout=@selector(layoutSubviews);if(diLockMRUVoid2Args342(c,layout))diLockMRUHook342(c,layout,(IMP)diLockMRULayout342,NO);
        SEL move=@selector(didMoveToSuperview);if(diLockMRUVoid2Args342(c,move))diLockMRUHook342(c,move,(IMP)diLockMRUMoveSuperview342,NO);
        SEL win=@selector(didMoveToWindow);if(diLockMRUVoid2Args342(c,win))diLockMRUHook342(c,win,(IMP)diLockMRUMoveWindow342,NO);
        SEL vis=NSSelectorFromString(@"updateVisibility");if(diLockMRUVoid2Args342(c,vis))diLockMRUHook342(c,vis,(IMP)diLockMRUVisibility342,NO);
        SEL init=@selector(init);if(diLockMRUObject2Args342(c,init))diLockMRUHook342(c,init,(IMP)diLockMRUInit342,YES);
    }
    Class vc=NSClassFromString(@"MRUCoverSheetViewController");SEL vdl=@selector(viewDidLayoutSubviews);
    if(vc&&diLockMRUVoid2Args342(vc,vdl))diLockMRUHook342(vc,vdl,(IMP)diLockMRULayout342,NO);
    if(diLockMRUOn342()){
        UIApplication *app=UIApplication.sharedApplication;
        for(UIScene *s in app.connectedScenes)if([s isKindOfClass:UIWindowScene.class])for(UIWindow *w in ((UIWindowScene *)s).windows)diLockMRUScanView342(w);
    }
}
static void diLockMRURefresh342(void){
    diLockMRUInstall342();
    for(UIView *v in diLockMRUHosts342.allObjects)diLockMRUApply342(v);
    if(diLockMRUOn342()){
        for(UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if([s isKindOfClass:UIWindowScene.class])for(UIWindow *w in ((UIWindowScene *)s).windows)diLockMRUScanView342(w);
    }
}
