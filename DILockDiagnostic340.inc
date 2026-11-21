/* Diagnostic build: inspect real payload owners, never mutate unknown views.
   Use existing SB refresh and MRU scan callbacks; no added repeating timers. */
static int diLockDiagnosticToken340=-1;
static BOOL diLockDiagnosticChannel340(void){
    static dispatch_once_t once;static BOOL ok=NO;
    dispatch_once(&once,^{ok=notify_register_check("com.abgg332.driftisland.lockavatar.diag340",&diLockDiagnosticToken340)==NOTIFY_STATUS_OK;});
    return ok;
}
static void diLockDiagnosticPublish340(void){
    if(!diLockDiagnosticChannel340())return;
    // Heartbeat timestamp prevents an exited SpringBoard leaving stale demand.
    uint64_t flags=(enabled && diLockAvatarOn338?1:0) | (!gScreenOff328?2:0) | (gLocked?4:0);
    uint64_t state=((uint64_t)(CFAbsoluteTimeGetCurrent())<<3)|flags;
    notify_set_state(diLockDiagnosticToken340,state);
}
static NSString *diLockDiagnosticOwner340(UIView *view){
    SEL sel=NSSelectorFromString(@"_viewControllerForAncestor");
    if(![view respondsToSelector:sel])return @"none";
    @try{id owner=((id(*)(id,SEL))objc_msgSend)(view,sel);return owner?NSStringFromClass([owner class]):@"none";}
    @catch(__unused NSException *e){return @"unavailable";}
}
static void diLockDiagnosticDump340(UIView *root,BOOL remote){
    if(!root)return;
    NSMutableArray<UIView *> *queue=[NSMutableArray arrayWithObject:root];NSUInteger index=0,shown=0;
    NSMutableString *report=[NSMutableString stringWithFormat:@"[锁屏定位340] proc=%@ root=%@ %@ owner=%@",NSProcessInfo.processInfo.processName,NSStringFromClass(root.class),NSStringFromCGRect(root.bounds),diLockDiagnosticOwner340(root)];
    while(index<queue.count && index<600 && shown<28 && report.length<10000){
        UIView *v=queue[index++];NSString *name=NSStringFromClass(v.class);
        CGSize size=v.bounds.size;
        BOOL named=[name containsString:@"Artwork"] || [name containsString:@"AlbumArt"] || [name containsString:@"NowPlaying"] || [name containsString:@"MediaControls"];
        BOOL square=size.width>=24 && size.width<=600 && size.height>=24 && size.height<=600 && fabs(size.width-size.height)<MAX(3,size.width*.08);
        BOOL image=[v isKindOfClass:UIImageView.class] || v.layer.contents!=nil;
        BOOL scene=[name containsString:@"ScenePresentation"] || [name containsString:@"RemoteView"] || [name containsString:@"Portal"];
        if(named || scene || (square && image)){
            shown++;NSMutableString *chain=[NSMutableString string];
            for(UIView *p=v.superview;p && chain.length<360;p=p.superview){[chain appendFormat:@"/%@",NSStringFromClass(p.class)];if(p==v.window)break;}
            CGRect win=v.window?[v convertRect:v.bounds toView:v.window]:CGRectZero;
            [report appendFormat:@"\n%@ bounds=%@ windowRect=%@ hidden=%d alpha=%.2f contents=%d mask=%@ owner=%@ parent=%@",name,NSStringFromCGRect(v.bounds),NSStringFromCGRect(win),v.hidden,v.alpha,v.layer.contents!=nil,NSStringFromClass(v.layer.mask.class),diLockDiagnosticOwner340(v),chain];
        }
        for(UIView *child in v.subviews)if(queue.count<600)[queue addObject:child];
    }
    [report appendFormat:@"\n[锁屏定位340] nodes=%lu described=%lu remote=%d（仅定位，未修改未知视图）",(unsigned long)index,(unsigned long)shown,remote];
    if(remote)diMruFileLog(report);else RLog(@"%@",report);
}
static void diLockDiagnosticRemote340(void){
    static CFAbsoluteTime last=0;CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    if(now-last<10 || !diLockDiagnosticChannel340())return;
    uint64_t state=0;if(notify_get_state(diLockDiagnosticToken340,&state)!=NOTIFY_STATUS_OK)return;
    if((state&7)!=7 || now-(double)(state>>3)>15)return;
    last=now;NSUInteger count=0;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
        if(![scene isKindOfClass:UIWindowScene.class])continue;
        for(UIWindow *w in ((UIWindowScene *)scene).windows){
            if(w.hidden || w.alpha<.01)continue;
            diLockDiagnosticDump340(w,YES);if(++count>=3)return;
        }
    }
    if(!count)diMruFileLog(@"[锁屏定位340] MRU 无可见本地窗口；封面可能由其他进程或独立远程场景承载");
}
