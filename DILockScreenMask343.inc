/* Lock-screen MRUArtworkView adapter only. Reuses the existing PlayerMaskAsset
   and PlayerMaskOn exported by SpringBoard; no window-tree scans or CC hooks. */
@interface DILockScreenMaskState343 : NSObject
@property(nonatomic,weak) UIView *host;
@property(nonatomic,weak) UIView *art;
@property(nonatomic,strong) UIImageView *mask;
@property(nonatomic,strong) UIView *originalMask;
@property(nonatomic,assign) BOOL maskInstalled;
@end
@implementation DILockScreenMaskState343 @end
static char diLockScreenMaskStateKey343;
static NSHashTable<UIView *> *diLockScreenMaskHosts343;
static IMP diLockScreenOrigLayout343,diLockScreenOrigMove343,diLockScreenOrigVisibility343,diLockScreenOrigInit343;
static BOOL diLockScreenHooked343,diLockScreenDisplayOff343,diLockScreenDisplayHooked343;
static int diLockScreenDisplayToken343=-1;
static CFTimeInterval diLockScreenSpinEpoch343;
static void diLockScreenApply343(UIView *host);

static BOOL diLockScreenCover343(UIView *host){
    Class artClass=NSClassFromString(@"MRUArtworkView");
    if(!artClass||![host isKindOfClass:artClass])return NO;
    UIViewController *owner=diActivityAncestorVC(host);
    if([NSStringFromClass(owner.class) isEqualToString:@"MRUActivityNowPlayingViewController"])return NO;
    NSString *wn=NSStringFromClass(host.window.class);
    BOOL wallpaper=[wn isEqualToString:@"_SBWallpaperSecureWindow"];
    BOOL cover=diInLockScreen(host)||wallpaper,cc=NO;NSUInteger depth=0;
    for(UIView *p=host;p&&depth++<24;p=p.superview){
        NSString *n=NSStringFromClass(p.class);
        if([n containsString:@"ControlCenter"]||[n containsString:@"Aperture"])cc=YES;
        if([n isEqualToString:@"MRUCoverSheetView"])cover=YES;
        if([p isKindOfClass:UIWindow.class])break;
    }
    return cover&&!cc;
}
static void diLockScreenDisplayChanged343(void){
    uint64_t s=2;if(notify_get_state(diLockScreenDisplayToken343,&s)!=NOTIFY_STATUS_OK||s>1)return;
    diLockScreenDisplayOff343=(s==0);
    for(UIView *v in diLockScreenMaskHosts343.allObjects)diLockScreenApply343(v);
}
static void diLockScreenDisplayInstall343(void){
    if(diLockScreenDisplayHooked343)return;diLockScreenDisplayHooked343=YES;
    if(notify_register_dispatch("com.apple.iokit.hid.displayStatus",&diLockScreenDisplayToken343,dispatch_get_main_queue(),^(int t){diLockScreenDisplayChanged343();})==NOTIFY_STATUS_OK)diLockScreenDisplayChanged343();
}
static void diLockScreenFlags343(BOOL *lockOn,BOOL *maskOn){
    if([NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]){
        if(lockOn)*lockOn=enabled && diPrefBoolNow(@"LockScreenAvatarOn",NO);
        if(maskOn)*maskOn=diArtMaskWanted();
        return;
    }

    static CFAbsoluteTime last=0;static BOOL cachedLock=NO,cachedMask=NO;CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    if(!last||now-last>.25){last=now;NSDictionary *d=[NSDictionary dictionaryWithContentsOfFile:[diMruSelfDir() stringByAppendingPathComponent:@"params.plist"]];
        id l=d[@"lockAvatar"],m=d[@"pmOn"];
        if(l)cachedLock=[l respondsToSelector:@selector(boolValue)]?[l boolValue]:NO;else diMruReadFilePref(@"LockScreenAvatarOn",&cachedLock);
        if(m)cachedMask=[m respondsToSelector:@selector(boolValue)]?[m boolValue]:NO;else diMruReadFilePref(@"PlayerMaskOn",&cachedMask);
    }
    if(lockOn)*lockOn=cachedLock;if(maskOn)*maskOn=cachedMask;
}
static UIView *diLockScreenArtwork343(UIView *host){
    SEL s=NSSelectorFromString(@"artworkImageView");
    if([host respondsToSelector:s]){@try{id v=((id(*)(id,SEL))objc_msgSend)(host,s);if([v isKindOfClass:UIImageView.class])return (UIView *)v;}@catch(__unused NSException *e){}}
    if([NSStringFromClass(host.class) isEqualToString:@"MRUActivityArtworkView"]){
        SEL layerSel=NSSelectorFromString(@"artworkLayer");
        if([host respondsToSelector:layerSel]){@try{id l=((id(*)(id,SEL))objc_msgSend)(host,layerSel);if([l isKindOfClass:CALayer.class]){id c=[(CALayer *)l contents];if(c&&CFGetTypeID((__bridge CFTypeRef)c)==CGImageGetTypeID())return host;}}@catch(__unused NSException *e){}}
        for(NSString *key in @[@"imageView",@"coverArtImageView"]){SEL q=NSSelectorFromString(key);if([host respondsToSelector:q]){@try{id v=((id(*)(id,SEL))objc_msgSend)(host,q);if([v isKindOfClass:UIImageView.class])return (UIView *)v;}@catch(__unused NSException *e){}}}
    }
    CGSize z=host.bounds.size;NSMutableArray<UIView *> *todo=[NSMutableArray arrayWithArray:host.subviews];NSUInteger i=0;
    while(i<todo.count&&i<40){UIView *v=todo[i++];if([v isKindOfClass:UIImageView.class]&&fabs(v.bounds.size.width-z.width)<2&&fabs(v.bounds.size.height-z.height)<2)return v;for(UIView *x in v.subviews)if(todo.count<40)[todo addObject:x];}
    return nil;
}
static void diLockScreenTeardown343(UIView *host,DILockScreenMaskState343 *st){
    if(!st)return;[st.art.layer removeAnimationForKey:@"di.lockscreen.spin343"];
    if(st.maskInstalled&&st.art.maskView==st.mask)st.art.maskView=st.originalMask;
    objc_setAssociatedObject(host,&diLockScreenMaskStateKey343,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void diLockScreenApply343(UIView *host){
    Class artworkClass=NSClassFromString(@"MRUArtworkView");
    BOOL isLockArtwork=artworkClass&&[host isKindOfClass:artworkClass];
    if(!NSThread.isMainThread||!isLockArtwork)return;
    DILockScreenMaskState343 *st=objc_getAssociatedObject(host,&diLockScreenMaskStateKey343);
    if(!diLockScreenCover343(host)){
        static CFTimeInterval rejectAt=0;CFTimeInterval now=CACurrentMediaTime();
        if(host.bounds.size.width>=140 && now-rejectAt>8){rejectAt=now;RLog(@"[锁屏拒绝347] class=%@ bounds=%@ window=%@ owner=%@",NSStringFromClass(host.class),NSStringFromCGRect(host.bounds),NSStringFromClass(host.window.class),NSStringFromClass(diActivityAncestorVC(host).class));}
        if(st)diLockScreenTeardown343(host,st);return;
    }
    BOOL lockOn=NO,maskOn=NO;diLockScreenFlags343(&lockOn,&maskOn);
    if(!lockOn){if(st)diLockScreenTeardown343(host,st);return;}
    diLockScreenDisplayInstall343();
    UIView *art=diLockScreenArtwork343(host);if(!art||art.bounds.size.width<12||art.bounds.size.height<12)return;
    if(!st) {
        RLog(@"[锁屏载体347] proc=%@ host=%@ hostBounds=%@ image=%@ imageBounds=%@ window=%@ owner=%@",NSProcessInfo.processInfo.processName,NSStringFromClass(host.class),NSStringFromCGRect(host.bounds),NSStringFromClass(art.class),NSStringFromCGRect(art.bounds),NSStringFromClass(host.window.class),NSStringFromClass(diActivityAncestorVC(host).class));
    }
    if(st&&st.art!=art){diLockScreenTeardown343(host,st);st=nil;}
    if(!st){st=[DILockScreenMaskState343 new];st.host=host;st.art=art;st.originalMask=art.maskView;objc_setAssociatedObject(host,&diLockScreenMaskStateKey343,st,OBJC_ASSOCIATION_RETAIN_NONATOMIC);if(!diLockScreenMaskHosts343)diLockScreenMaskHosts343=[NSHashTable weakObjectsHashTable];[diLockScreenMaskHosts343 addObject:host];
        RLog(@"[锁屏共享遮罩347] 命中 %@ %.0fx%.0f PlayerMaskOn=%d",NSStringFromClass(host.class),art.bounds.size.width,art.bounds.size.height,maskOn);
    }
    UIImage *sharedShape=maskOn?diArtMaskImage():nil;
    if(maskOn && sharedShape){
        if(!st.mask){st.mask=[UIImageView new];st.mask.userInteractionEnabled=NO;st.mask.opaque=NO;st.mask.backgroundColor=UIColor.clearColor;st.mask.contentMode=UIViewContentModeScaleToFill;}
        UIImage *shape=sharedShape;
        if(st.mask.image!=shape)st.mask.image=shape;if(!CGRectEqualToRect(st.mask.frame,art.bounds))st.mask.frame=art.bounds;
        if(art.maskView!=st.mask)art.maskView=st.mask;st.maskInstalled=YES;
    }else if(st.maskInstalled){if(art.maskView==st.mask)art.maskView=st.originalMask;st.maskInstalled=NO;}
    BOOL visible=!diLockScreenDisplayOff343&&!host.hidden&&!art.hidden&&host.alpha>.01&&art.alpha>.01;
    for(UIView *p=host.superview;p&&visible;p=p.superview)if(p.hidden||p.alpha<.01)visible=NO;
    if(visible&&![art.layer animationForKey:@"di.lockscreen.spin343"]){
        CFTimeInterval now=CACurrentMediaTime();if(!diLockScreenSpinEpoch343)diLockScreenSpinEpoch343=now;
        CABasicAnimation *a=[CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];a.fromValue=@0;a.toValue=@(2*M_PI);a.duration=10;a.repeatCount=HUGE_VALF;a.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];a.removedOnCompletion=NO;
        a.beginTime=[art.layer convertTime:now-fmod(now-diLockScreenSpinEpoch343,10) fromLayer:nil];[art.layer addAnimation:a forKey:@"di.lockscreen.spin343"];
    }else if(!visible)[art.layer removeAnimationForKey:@"di.lockscreen.spin343"];
}
static void diLockScreenLayout343(id self,SEL cmd){if(diLockScreenOrigLayout343)((void(*)(id,SEL))diLockScreenOrigLayout343)(self,cmd);diLockScreenApply343((UIView *)self);}
static void diLockScreenMove343(id self,SEL cmd){if(diLockScreenOrigMove343)((void(*)(id,SEL))diLockScreenOrigMove343)(self,cmd);diLockScreenApply343((UIView *)self);}
static void diLockScreenVisibility343(id self,SEL cmd){if(diLockScreenOrigVisibility343)((void(*)(id,SEL))diLockScreenOrigVisibility343)(self,cmd);diLockScreenApply343((UIView *)self);}
static id diLockScreenInit343(id self,SEL cmd){id r=diLockScreenOrigInit343?((id(*)(id,SEL))diLockScreenOrigInit343)(self,cmd):self;if(r)diLockScreenApply343((UIView *)r);return r;}
static BOOL diLockScreenDirect343(Class c,SEL sel){
    unsigned int n=0;Method *m=class_copyMethodList(c,&n);BOOL found=NO;
    for(unsigned int i=0;i<n;i++)if(method_getName(m[i])==sel){found=YES;break;}
    free(m);return found;
}
static BOOL diLockScreenVoid343(Class c,SEL s){Method m=diLockScreenDirect343(c,s)?class_getInstanceMethod(c,s):NULL;if(!m||method_getNumberOfArguments(m)!=2)return NO;char *r=method_copyReturnType(m);BOOL ok=r&&!strcmp(r,"v");free(r);return ok;}
static BOOL diLockScreenObject343(Class c,SEL s){Method m=diLockScreenDirect343(c,s)?class_getInstanceMethod(c,s):NULL;if(!m||method_getNumberOfArguments(m)!=2)return NO;char *r=method_copyReturnType(m);BOOL ok=r&&!strcmp(r,"@");free(r);return ok;}
static void diLockScreenInstall343(void){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{diLockScreenInstall343();});return;}
    NSString *bid=NSBundle.mainBundle.bundleIdentifier.lowercaseString,*proc=NSProcessInfo.processInfo.processName;
    BOOL spring=[bid isEqualToString:@"com.apple.springboard"]||[proc isEqualToString:@"SpringBoard"];
    if(!spring&&![bid isEqualToString:@"com.apple.mediaremoteui"]&&![proc isEqualToString:@"MediaRemoteUI"])return;
    if(diLockScreenHooked343)return;
    Class c=NSClassFromString(@"MRUArtworkView");if(!c||![c isSubclassOfClass:UIView.class])return;diLockScreenHooked343=YES;diLockScreenDisplayInstall343();
    SEL s=@selector(layoutSubviews);if(!spring&&diLockScreenVoid343(c,s))MSHookMessageEx(c,s,(IMP)diLockScreenLayout343,&diLockScreenOrigLayout343);
    s=@selector(didMoveToSuperview);if(diLockScreenVoid343(c,s))MSHookMessageEx(c,s,(IMP)diLockScreenMove343,&diLockScreenOrigMove343);
    s=NSSelectorFromString(@"updateVisibility");if(diLockScreenVoid343(c,s))MSHookMessageEx(c,s,(IMP)diLockScreenVisibility343,&diLockScreenOrigVisibility343);
    s=@selector(init);if(diLockScreenObject343(c,s))MSHookMessageEx(c,s,(IMP)diLockScreenInit343,&diLockScreenOrigInit343);
    RLog(@"[锁屏接入347] proc=%@ class=%@ init=%d move=%d layout=%@",proc,NSStringFromClass(c),diLockScreenOrigInit343!=NULL,diLockScreenOrigMove343!=NULL,spring?@"existingSB":@"dedicatedMRU");
}
static void diLockScreenRefresh343(void){diLockScreenInstall343();for(UIView *v in diLockScreenMaskHosts343.allObjects)diLockScreenApply343(v);}

static void diLockScreenDiscover347(void){
    if(!NSThread.isMainThread)return;
    static CFTimeInterval last=0;CFTimeInterval now=CACurrentMediaTime();if(now-last<.3)return;last=now;
    if(!diPrefBoolNow(@"LockScreenAvatarOn",NO))return;
    diLockScreenInstall343();NSUInteger artCount=0,scenes=0;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
        if(![scene isKindOfClass:UIWindowScene.class])continue;
        for(UIWindow *w in ((UIWindowScene *)scene).windows){
            NSString *wn=NSStringFromClass(w.class);
            if(w.hidden||w.alpha<.01||(!diIsLockScreenWindow(w)&&![wn isEqualToString:@"_SBWallpaperSecureWindow"]))continue;
            NSMutableArray<UIView *> *q=[NSMutableArray arrayWithObject:w];NSUInteger i=0,reported=0;
            while(i<q.count&&i<1400){UIView *v=q[i++];NSString *n=NSStringFromClass(v.class);CGSize z=v.bounds.size;
                Class ac=NSClassFromString(@"MRUArtworkView");
                if(ac&&[v isKindOfClass:ac]){artCount++;diLockScreenApply343(v);}
                BOOL named=[n containsString:@"Artwork"]||[n containsString:@"Album"]||[n containsString:@"NowPlaying"]||[n containsString:@"Scene"];
                BOOL picture=[v isKindOfClass:UIImageView.class]&&((UIImageView *)v).image;
                if(reported<24&&!v.hidden&&z.width>=140&&z.height>=140&&(named||picture)){
                    reported++;NSMutableString *chain=[NSMutableString string];NSUInteger d=0;
                    for(UIView *p=v.superview;p&&d++<8;p=p.superview)[chain appendFormat:@"/%@",NSStringFromClass(p.class)];
                    RLog(@"[锁屏显示链347] window=%@ view=%@ bounds=%@ owner=%@ parents=%@",wn,n,NSStringFromCGRect(v.bounds),NSStringFromClass(diActivityAncestorVC(v).class),chain);
                }
                for(UIView *child in v.subviews)if(q.count<1400)[q addObject:child];
            }
            RLog(@"[锁屏接入347] window=%@ visited=%lu knownArt=%lu",wn,(unsigned long)i,(unsigned long)artCount);scenes++;
        }
    }
    RLog(@"[锁屏接入347] event windows=%lu knownArt=%lu",(unsigned long)scenes,(unsigned long)artCount);
}
