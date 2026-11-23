/* Confirmed by device scene definition: osservice<com.apple.MediaRemoteUI>,
   SBUIBackgroundContentSceneSpecification. Never modify the scene/window itself. */
@interface DILockBackgroundArt351 : NSObject
@property(nonatomic,weak) UIImageView *image;
@property(nonatomic,strong) UIImageView *mask;
@property(nonatomic,strong) UIView *originalMask;
@property(nonatomic,assign) BOOL installed;
@end
@implementation DILockBackgroundArt351 @end
static NSHashTable<UIImageView *> *diLockBackgroundImages351;
static char diLockBackgroundState351;
static BOOL diLockBackgroundStarted351;
static void diLockBackgroundApply351(UIImageView *image);
static BOOL diLockBackgroundScene351(UIScene *scene){
    id fbs=diLockObject349(scene,@"_FBSScene");
    id spec=diLockObject349(fbs,@"specification");
    if(!spec)spec=diLockObject349(diLockObject349(fbs,@"definition"),@"specification");
    return [NSStringFromClass([spec class]) containsString:@"BackgroundContentSceneSpecification"];
}
static void diLockBackgroundRestore351(UIImageView *image){
    DILockBackgroundArt351 *st=objc_getAssociatedObject(image,&diLockBackgroundState351);
    if(!st)return;
    if(st.installed&&image.maskView==st.mask)image.maskView=st.originalMask;
    [image.layer removeAnimationForKey:@"di.lock.background.spin351"];
    st.installed=NO;
}
static void diLockBackgroundApply351(UIImageView *image){
    if(!image)return;
    BOOL scoped=diLockBackgroundScene351(image.window.windowScene);
    BOOL lock=NO,mask=NO;diLockScreenFlags343(&lock,&mask);
    BOOL visible=scoped&&lock&&!diLockScreenDisplayOff343&&image.image!=nil;
    for(UIView *p=image;p&&visible;p=p.superview)if(p.hidden||p.alpha<.01)visible=NO;
    if(!visible){diLockBackgroundRestore351(image);return;}
    DILockBackgroundArt351 *st=objc_getAssociatedObject(image,&diLockBackgroundState351);
    if(!st){st=[DILockBackgroundArt351 new];st.image=image;st.originalMask=image.maskView;st.mask=[UIImageView new];st.mask.userInteractionEnabled=NO;st.mask.opaque=NO;st.mask.backgroundColor=UIColor.clearColor;st.mask.contentMode=UIViewContentModeScaleToFill;st.mask.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;objc_setAssociatedObject(image,&diLockBackgroundState351,st,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    UIImage *asset=mask?diArtMaskImage():nil;
    if(asset){
        if(!st.installed)st.originalMask=image.maskView;
        if(st.mask.image!=asset)st.mask.image=asset;
        if(!CGRectEqualToRect(st.mask.frame,image.bounds))st.mask.frame=image.bounds;
        if(image.maskView!=st.mask)image.maskView=st.mask;
        st.installed=YES;
    }else if(st.installed){if(image.maskView==st.mask)image.maskView=st.originalMask;st.installed=NO;}
    if(![image.layer animationForKey:@"di.lock.background.spin351"]){
        CABasicAnimation *a=[CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];a.fromValue=@0;a.toValue=@(2*M_PI);a.duration=10;a.repeatCount=HUGE_VALF;a.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        a.beginTime=[image.layer convertTime:CACurrentMediaTime() fromLayer:nil];
        [image.layer addAnimation:a forKey:@"di.lock.background.spin351"];diSpinRegister352(image.layer);
    }
}
static void diLockBackgroundInspect351(UIScene *scene){
    if(![scene isKindOfClass:UIWindowScene.class])return;
    id fbs=diLockObject349(scene,@"_FBSScene"),spec=diLockObject349(fbs,@"specification");
    BOOL scoped=diLockBackgroundScene351(scene);
    NSString *identifier=diLockObject349(scene,@"_sceneIdentifier");
    if(!identifier)identifier=scene.session.persistentIdentifier;
    static NSMutableSet *reported;if(!reported)reported=[NSMutableSet set];
    NSString *sig=[NSString stringWithFormat:@"%@:%d",identifier,scoped];
    if(![reported containsObject:sig]){[reported addObject:sig];diMruFileLog([NSString stringWithFormat:@"[背景场景351] id=%@ class=%@ spec=%@ eligible=%d windows=%lu",identifier,NSStringFromClass(scene.class),NSStringFromClass([spec class]),scoped,(unsigned long)((UIWindowScene *)scene).windows.count]);}
    if(!scoped)return;
    for(UIWindow *window in ((UIWindowScene *)scene).windows){
        if(window.hidden||window.alpha<.01)continue;
        NSMutableArray<UIView *> *queue=[NSMutableArray arrayWithObject:window];NSUInteger index=0;
        NSMutableArray<UIImageView *> *candidates=[NSMutableArray array];
        while(index<queue.count&&index<600){UIView *v=queue[index++];CGSize z=v.bounds.size;
            if([v isKindOfClass:UIImageView.class]&&((UIImageView *)v).image&&z.width>=140&&z.height>=140&&fabs(z.width-z.height)<MAX(3,z.width*.04)){
                BOOL shown=YES;for(UIView *p=v;p&&shown;p=p.superview)if(p.hidden||p.alpha<.01)shown=NO;
                if(shown)[candidates addObject:(UIImageView *)v];
            }
            for(UIView *child in v.subviews)if(queue.count<600)[queue addObject:child];
        }
        // A single large square bitmap is required. Ambiguous content remains untouched.
        if(candidates.count==1){UIImageView *image=candidates.firstObject;
            if(!diLockBackgroundImages351)diLockBackgroundImages351=[NSHashTable weakObjectsHashTable];
            if(![diLockBackgroundImages351 containsObject:image]){
                [diLockBackgroundImages351 addObject:image];
                NSMutableString *chain=[NSMutableString string];NSUInteger n=0;for(UIView *p=image;p&&n++<12;p=p.superview)[chain appendFormat:@"/%@",NSStringFromClass(p.class)];
                diMruFileLog([NSString stringWithFormat:@"[背景封面351] scene=%@ view=%@ bounds=%@ imagePixels=%.0fx%.0f root=%@ chain=%@",identifier,NSStringFromClass(image.class),NSStringFromCGRect(image.bounds),image.image.size.width*image.image.scale,image.image.size.height*image.image.scale,NSStringFromClass(window.rootViewController.class),chain]);
            }
            diLockBackgroundApply351(image);
        }else{
            static CFTimeInterval last=0;CFTimeInterval now=CACurrentMediaTime();if(now-last>5){last=now;NSMutableString *views=[NSMutableString string];NSUInteger count=0;for(UIView *v in queue){if(++count>45)break;[views appendFormat:@" %@:%@",NSStringFromClass(v.class),NSStringFromCGRect(v.bounds)];}diMruFileLog([NSString stringWithFormat:@"[背景未适配351] scene=%@ candidates=%lu root=%@ nodes=%lu tree=%@",identifier,(unsigned long)candidates.count,NSStringFromClass(window.rootViewController.class),(unsigned long)index,views]);}
        }
    }
}
static void diLockBackgroundClientTick351(void){
    if(!diLockBackgroundStarted351||!NSThread.isMainThread)return;
    for(UIImageView *image in diLockBackgroundImages351.allObjects)diLockBackgroundApply351(image);
    static CFTimeInterval last=0;CFTimeInterval now=CACurrentMediaTime();if(now-last<3)return;last=now;
    // Reuses existing MRU heartbeat, and walks only confirmed background scenes.
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes)diLockBackgroundInspect351(scene);
}
static void diLockBackgroundClientStart351(void){
    if(diLockBackgroundStarted351)return;diLockBackgroundStarted351=YES;
    for(NSNotificationName name in @[UISceneDidActivateNotification,UISceneWillEnterForegroundNotification,UISceneWillConnectNotification]){
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
            if(![note.object isKindOfClass:UIScene.class])return;UIScene *scene=note.object;
            for(double delay : {0.0,.25,.8})dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{diLockBackgroundInspect351(scene);});
        }];
    }
    diMruFileLog(@"[背景场景351] client adapter started; only SBUIBackgroundContentSceneSpecification");
    diLockBackgroundClientTick351();
}
