#include "DIBackgroundAnimation327.inc"
/* 3.1.24 independent reconstruction of a container-driven island background.
 * Evidence: DynamicFX 1.0.7 arm64e 0x12c0c/0x12ebc/0x11bac/0x119ac.
 * No third-party binary, authorization, network code, or forced island activity.
 */
static BOOL diDirectBackgroundAvailable324(void){
    return NSClassFromString(@"SBSystemApertureContainerView")!=Nil;
}
// Route top-level trailing satellites, not accessory children inside a pill.
static char kDIRightRole336,kDIRightRelease336;
static BOOL diRightSatellite335(UIView *host){
    UIWindow *win=host.window;
    if(!win || ![NSStringFromClass(host.class) isEqualToString:@"SBSystemApertureContainerView"] ||
       ![NSStringFromClass(win.class) containsString:@"SystemAperture"])return NO;
    CGRect model=host.bounds;
    CALayer *present=(CALayer *)host.layer.presentationLayer;
    CGRect bounds=present?present.bounds:model;
    CGRect box=[host convertRect:model toView:win];
    CALayer *windowPresentation=(CALayer *)win.layer.presentationLayer;
    if(present && windowPresentation)box=[present convertRect:bounds toLayer:windowPresentation];
    BOOL right=CGRectGetMidX(box)>CGRectGetMidX(win.bounds)+20;
    BOOL little=bounds.size.width>=20 && bounds.size.height>=20 && bounds.size.width<=88 && bounds.size.height<=72 && bounds.size.width/bounds.size.height<1.65;
    BOOL modelLittle=model.size.width<=100 && model.size.height<=80;
    BOOL latched=[objc_getAssociatedObject(host,&kDIRightRole336) boolValue];
    // Commit trailing satellite identity, not a one-frame model size. System
    // spring/portal swaps transiently set model dimensions to the main pill.
    if(right && little && modelLittle){
        objc_setAssociatedObject(host,&kDIRightRole336,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(host,&kDIRightRelease336,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    }
    if(!latched)return NO;
    BOOL settled=fabs(bounds.size.width-model.size.width)<1 && fabs(bounds.size.height-model.size.height)<1;
    BOOL primary=settled && bounds.size.width>=110 && (!right || bounds.size.height>=85);
    NSNumber *since=objc_getAssociatedObject(host,&kDIRightRelease336);
    if(!primary){objc_setAssociatedObject(host,&kDIRightRelease336,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);return YES;}
    CFTimeInterval now=CACurrentMediaTime();
    if(!since){objc_setAssociatedObject(host,&kDIRightRelease336,@(now),OBJC_ASSOCIATION_RETAIN_NONATOMIC);return YES;}
    if(now-since.doubleValue<.4)return YES;
    objc_setAssociatedObject(host,&kDIRightRole336,@NO,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(host,&kDIRightRelease336,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return NO;
}
static BOOL diRightSatelliteAncestor335(UIView *view){
    for(UIView *p=view;p && p!=view.window;p=p.superview)
        if([NSStringFromClass(p.class) isEqualToString:@"SBSystemApertureContainerView"])return diRightSatellite335(p);
    return NO;
}
static BOOL diIsNowPlayingHostCached(UIView *host);
static char kDIBackground324,kDIBackgroundPending324;
static NSHashTable *diBackgrounds324;
@class DIIslandBackground324;
@interface DIBackgroundTicker324 : NSObject
@property(nonatomic,weak) DIIslandBackground324 *owner;
- (void)tick:(CADisplayLink *)link;
@end
@interface DIIslandBackground324 : UIView
@property(nonatomic,weak) UIView *host;
@property(nonatomic,strong) CADisplayLink *link;
@property(nonatomic,strong) DIBackgroundTicker324 *ticker;
@property(nonatomic,strong) AVQueuePlayer *compactPlayer;
@property(nonatomic,strong) AVQueuePlayer *expandedPlayer;
@property(nonatomic,strong) AVPlayerLooper *compactLooper;
@property(nonatomic,strong) AVPlayerLooper *expandedLooper;
@property(nonatomic,strong) AVPlayerLayer *compactLayer;
@property(nonatomic,strong) AVPlayerLayer *expandedLayer;
@property(nonatomic,strong) UIImageView *compactImage;
@property(nonatomic,strong) UIImageView *expandedImage;
@property(nonatomic,copy) NSString *compactPath;
@property(nonatomic,copy) NSString *expandedPath;
@property(nonatomic,copy) NSString *prefSignature;
@property(nonatomic,assign) BOOL rightSatellite335;
@property(nonatomic,assign) NSUInteger compactGeneration;
@property(nonatomic,assign) NSUInteger expandedGeneration;
@property(nonatomic,assign) NSInteger stableTicks;
@property(nonatomic,assign) BOOL expandedMode;
@property(nonatomic,assign) BOOL modeKnown;
@property(nonatomic,assign) BOOL preparing;
@property(nonatomic,assign) BOOL geometryKnown;
@property(nonatomic,assign) CGRect lastGeometry;
@property(nonatomic,assign) CGFloat lastRadius;
@property(nonatomic,assign) CFAbsoluteTime diagnosticAt;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSString *> *animationSignatures327;
@property(nonatomic,assign) BOOL mirrored327;
@property(nonatomic,assign) CGRect observedModel328;
@property(nonatomic,assign) CGFloat observedRadius328;
@property(nonatomic,assign) BOOL observed328;
@property(nonatomic,assign) CFTimeInterval warmUntil328;
@property(nonatomic,assign) NSInteger oldMode328;
@property(nonatomic,assign) BOOL displayedMode328;
@property(nonatomic,assign) BOOL displayKnown328;
@property(nonatomic,assign) CFTimeInterval requestedAt328;
@property(nonatomic,assign) CFTimeInterval report327;
@property(nonatomic,weak) CALayer *animationSource327;
@property(nonatomic,assign) BOOL geometryProbe336;
@property(nonatomic,assign) CFTimeInterval prewarmUntil337;
@property(nonatomic,assign) BOOL directExpand337;
@property(nonatomic,assign) CFTimeInterval routeReport337;
@property(nonatomic,assign) BOOL compactRequested336;
@property(nonatomic,assign) BOOL expandedRequested336;
@property(nonatomic,assign) BOOL syncing326;
@property(nonatomic,assign) CFTimeInterval lastSync326;
@property(nonatomic,assign) CFTimeInterval lastDisplay326;
@property(nonatomic,assign) double worstGap326;
@property(nonatomic,assign) NSUInteger ticks326;
@property(nonatomic,assign) NSUInteger late326;
- (void)refresh;
- (void)sync;
- (void)startBurst;
- (void)stop;
@end
@implementation DIBackgroundTicker324
- (void)tick:(CADisplayLink *)link {
    DIIslandBackground324 *o=self.owner;if(!o){[link invalidate];return;}
    CFTimeInterval now=link.timestamp;
    if(o.lastDisplay326>0){double gap=now-o.lastDisplay326;o.worstGap326=MAX(o.worstGap326,gap);double expected=link.targetTimestamp-link.timestamp;if(expected>0 && gap>expected*1.8)o.late326++;}
    o.lastDisplay326=now;o.ticks326++;
    [o sync];
}
@end
@implementation DIIslandBackground324
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])){
        self.userInteractionEnabled=NO;self.clipsToBounds=YES;
        self.backgroundColor=UIColor.clearColor;
        _compactLayer=[AVPlayerLayer layer];_expandedLayer=[AVPlayerLayer layer];
        NSDictionary *noActions=@{@"bounds":NSNull.null,@"position":NSNull.null,@"cornerRadius":NSNull.null,@"hidden":NSNull.null,@"contents":NSNull.null};
        _compactLayer.actions=noActions;_expandedLayer.actions=noActions;
        self.layer.actions=noActions;
        _compactLayer.videoGravity=AVLayerVideoGravityResizeAspectFill;
        _expandedLayer.videoGravity=AVLayerVideoGravityResizeAspectFill;
        [self.layer addSublayer:_compactLayer];[self.layer addSublayer:_expandedLayer];
        _compactImage=[UIImageView new];_expandedImage=[UIImageView new];
        for(UIImageView *v in @[_compactImage,_expandedImage]){v.contentMode=UIViewContentModeScaleAspectFill;v.userInteractionEnabled=NO;[self addSubview:v];}
        _ticker=[DIBackgroundTicker324 new];_ticker.owner=self;
        setupAudioSession(); // keep existing Ambient+Mix, no setActive
    }
    return self;
}
- (void)startBurst {
    if(gLocked || gScreenOff328)return;
    if(!self.link || self.link.paused)self.stableTicks=0;
    if(!self.link){self.link=[CADisplayLink displayLinkWithTarget:self.ticker selector:@selector(tick:)];
        // Geometry runs at 60Hz, video decoding is independent. Avoid two live
        // decoders plus 120Hz background layout on ProMotion during collapse.
        NSInteger hz=60; // bounded CPU cadence; no persistent 120Hz poll for smoothness
        self.link.preferredFrameRateRange=CAFrameRateRangeMake(60,hz,hz);
        [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];}
    self.link.paused=NO;
}
- (void)stop {
    [self.compactPlayer pause];[self.expandedPlayer pause];
    self.compactRequested336=NO;self.expandedRequested336=NO;
    self.hidden=YES;[self.link invalidate];self.link=nil;self.lastDisplay326=0;
    self.warmUntil328=0;self.prewarmUntil337=0;
    // Stop our geometric CA copies too. Never alter the system host animations.
    for(CALayer *layer in @[self.layer,self.compactLayer,self.expandedLayer,self.compactImage.layer,self.expandedImage.layer])
        for(NSString *key in layer.animationKeys)if([key hasPrefix:@"di.geometry327."])[layer removeAnimationForKey:key];
    [self.animationSignatures327 removeAllObjects];self.mirrored327=NO;
}
- (void)loadPath:(NSString *)path expanded:(BOOL)expanded {
    NSString *old=expanded?self.expandedPath:self.compactPath;
    if([old isEqualToString:path] || (!old&&!path))return;
    NSUInteger generation;
    if(expanded){self.expandedPath=path;generation=++self.expandedGeneration;}
    else{self.compactPath=path;generation=++self.compactGeneration;}
    UIImageView *image=expanded?self.expandedImage:self.compactImage;
    if(!path.length){
        if(expanded){[self.expandedPlayer pause];self.expandedLooper=nil;self.expandedPlayer=nil;self.expandedLayer.player=nil;}
        else{[self.compactPlayer pause];self.compactLooper=nil;self.compactPlayer=nil;self.compactLayer.player=nil;}
        image.image=nil;return;
    }
    __weak DIIslandBackground324 *weak=self;
    // Never parse tracks/build AVFoundation assets inside system layout callbacks.
    static dispatch_queue_t queue;static dispatch_once_t once;
    dispatch_once(&once,^{queue=dispatch_queue_create("com.abgg332.driftisland.background324",DISPATCH_QUEUE_SERIAL);});
    dispatch_async(queue,^{
        NSString *ext=path.pathExtension.lowercaseString;
        BOOL still=[@[@"png",@"jpg",@"jpeg",@"webp"] containsObject:ext];
        UIImage *picture=still?[UIImage imageWithContentsOfFile:path]:nil;
        AVMutableComposition *video=nil;
        if(!still)@try{
            AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
            AVAssetTrack *source=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
            // Container duration may include a longer audio/edit-list tail. Copy
            // exactly the video track's valid range, rebased to time zero. Do not
            // trim visible first/last frames or assume that they are black.
            CMTimeRange range=source?source.timeRange:kCMTimeRangeInvalid;
            if(source && CMTIMERANGE_IS_VALID(range) && CMTIME_IS_NUMERIC(range.start) && CMTIME_IS_NUMERIC(range.duration) && CMTimeCompare(range.duration,kCMTimeZero)>0){
                AVMutableComposition *comp=[AVMutableComposition composition];
                AVMutableCompositionTrack *track=[comp addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
                if([track insertTimeRange:range ofTrack:source atTime:kCMTimeZero error:NULL]){track.preferredTransform=source.preferredTransform;video=comp;}
            }
        }@catch(NSException *e){NSLog(@"[岛背景324] 素材解析失败 %@",e.name);}
        dispatch_async(dispatch_get_main_queue(),^{
            DIIslandBackground324 *o=weak;if(!o)return;
            if(generation!=(expanded?o.expandedGeneration:o.compactGeneration))return;
            UIImageView *iv=expanded?o.expandedImage:o.compactImage;
            if(picture){iv.image=picture;}
            else if(video){
                AVQueuePlayer *player=[AVQueuePlayer queuePlayerWithItems:@[]];
                player.muted=YES;player.volume=0;player.preventsDisplaySleepDuringVideoPlayback=NO;
                player.automaticallyWaitsToMinimizeStalling=NO;player.actionAtItemEnd=AVPlayerActionAtItemEndNone;
                AVPlayerItem *item=[AVPlayerItem playerItemWithAsset:video];
                // Queue looper only; no end observer, no seek-to-zero, no item
                // replacement at every cycle. Bound the loop to copied video.
                CMTimeRange loopRange=CMTimeRangeMake(kCMTimeZero,video.duration);
                AVPlayerLooper *looper=[AVPlayerLooper playerLooperWithPlayer:player templateItem:item timeRange:loopRange];
                RLog(@"[循环328] %@ videoDuration=%.6f 模式=%d 视频轨范围循环；不重建播放器",path.lastPathComponent,CMTimeGetSeconds(video.duration),expanded);
                if(expanded){[o.expandedPlayer pause];o.expandedLooper=looper;o.expandedPlayer=player;o.expandedLayer.player=player;}
                else{[o.compactPlayer pause];o.compactLooper=looper;o.compactPlayer=player;o.compactLayer.player=player;}
                iv.image=nil;
            }else{
                // Fail closed: do not fall back to an asset containing an audio track.
                if(expanded){[o.expandedPlayer pause];o.expandedLooper=nil;o.expandedPlayer=nil;o.expandedLayer.player=nil;}
                else{[o.compactPlayer pause];o.compactLooper=nil;o.compactPlayer=nil;o.compactLayer.player=nil;}
                iv.image=nil;RLog(@"[岛背景324] 仅视频轨加载失败 %@",path.lastPathComponent);
            }
            if(expanded)o.expandedRequested336=NO;else o.compactRequested336=NO;
            [o startBurst];[o sync];
        });
    });
}
- (BOOL)visibleHost {
    UIView *host=self.host;
    if(!enabled || (gLocked || gScreenOff328) || !host.window || host.window.hidden)return NO;
    for(UIView *v=host;v;v=v.superview)if(v.hidden || v.alpha<.01)return NO;
    if(!self.rightSatellite335 && notifyBgOff && ([objc_getAssociatedObject(host,&kHostIsNotif) boolValue] || [objc_getAssociatedObject(host,&kCapIsNotif) boolValue]))return NO;
    return host.bounds.size.width>2 && host.bounds.size.height>2;
}
- (void)refresh {
    BOOL right=diRightSatellite335(self.host);
    if(right!=self.rightSatellite335){
        self.rightSatellite335=right;
        self.modeKnown=NO;self.displayKnown328=NO;
        // Do not destroy both queues first: loadPath updates only the changed
        // asset, and its generation guard rejects obsolete asynchronous work.
        if(logEnabled)RLog(@"[独立岛336] host=%p role=%@ model=%@ recIndex=%ld",self.host,right?@"rec":@"primary",NSStringFromCGRect(self.host.bounds),(long)recIdx);
    }
    NSString *small=right?recVideoPath():materialPathFor(NO);
    NSString *large=right?nil:materialPathFor(YES);
    // Background is edge-to-edge. animScale/offset/FPS configure legacy frame
    // effects, not the canvas of this independent video background.
    NSString *sig=[NSString stringWithFormat:@"%d/%d/%d/%d/%d/%@/%@",enabled,(gLocked || gScreenOff328),right,right?recOn:smallOn,right?NO:expandOn,small?:@"",large?:@""];
    BOOL changed=![self.prefSignature isEqualToString:sig];self.prefSignature=sig;
    if(![self visibleHost]){[self stop];return;}
    if(changed){[self loadPath:small expanded:NO];[self loadPath:large expanded:YES];[self startBurst];}
    if(logEnabled && CFAbsoluteTimeGetCurrent()-self.routeReport337>8){
        self.routeReport337=CFAbsoluteTimeGetCurrent();
        RLog(@"[素材路由337] host=%p role=%@ enabled=%d path=%@ model=%@",self.host,right?@"right-rec":@"primary",right?recOn:smallOn,small.lastPathComponent?:@"none",NSStringFromCGRect(self.host.bounds));
    }
    if(self.hidden)[self startBurst];
    [self sync];
}
- (BOOL)mirrorGeometry327:(UIView *)host {
    CALayer *source=host.layer;
    // DynamicFX evidence shows geometry is commonly animated on the internal
    // Scaling/RotatingContentView layer, not the outer container. Search only
    // the system host subtree and only shallowly; never scan the rendered video.
    NSMutableArray<CALayer *> *queue=[NSMutableArray arrayWithObject:source];CALayer *best=nil;int budget=48;
    while(queue.count && budget-->0){CALayer *node=queue.firstObject;[queue removeObjectAtIndex:0];
        BOOL candidate=node.animationKeys.count>0;
        if(candidate){for(NSString *key in node.animationKeys){CAAnimation *a=[node animationForKey:key];BOOL dummy=NO;if(diBGAnimation327(a,0,1.0/MAX(1.0,UIScreen.mainScreen.scale),&dummy,0) && dummy && fabs(node.bounds.size.width-host.bounds.size.width)<1 && fabs(node.bounds.size.height-host.bounds.size.height)<1){best=node;break;}}}
        if(best)break;for(CALayer *child in node.sublayers)if(child!=self.layer && queue.count<48)[queue addObject:child];
    }
    source=best?:host.layer;self.animationSource327=source;
    if(fabs(source.bounds.origin.x)>.001 || fabs(source.bounds.origin.y)>.001 || source.speed!=1)return NO;
    CGFloat pixel=1.0/MAX(1.0,UIScreen.mainScreen.scale);
    NSMutableDictionary *animations=[NSMutableDictionary dictionary];BOOL hasBounds=NO;
    for(NSString *key in source.animationKeys){CAAnimation *a=[source animationForKey:key];BOOL bounds=NO;CAAnimation *valid=diBGAnimation327(a,0,pixel,&bounds,0);if(valid){animations[key]=a;hasBounds|=bounds;}}
    if(!hasBounds){
        if(self.mirrored327){
            for(CALayer *layer in @[self.layer,self.compactLayer,self.expandedLayer,self.compactImage.layer,self.expandedImage.layer])
                for(NSString *key in layer.animationKeys)if([key hasPrefix:@"di.geometry327."])[layer removeAnimationForKey:key];
            [self.animationSignatures327 removeAllObjects];self.mirrored327=NO;
        }
        return NO;
    }
    if(!self.animationSignatures327)self.animationSignatures327=[NSMutableDictionary dictionary];
    NSMutableSet *live=[NSMutableSet set];
    [CATransaction begin];[CATransaction setDisableActions:YES];
    CGRect model=host.bounds;
    self.layer.anchorPoint=CGPointZero;self.layer.position=CGPointZero;self.layer.bounds=model;
    CGFloat radius=source.cornerRadius;
    self.layer.cornerRadius=radius>.1?radius:MIN(model.size.width,model.size.height)*.5;
    NSArray *targets=@[self.layer,self.compactLayer,self.expandedLayer,self.compactImage.layer,self.expandedImage.layer];
    for(NSUInteger i=1;i<targets.count;i++){
        CALayer *layer=targets[i];layer.anchorPoint=CGPointZero;layer.position=CGPointMake(-pixel,-pixel);
        layer.bounds=CGRectMake(0,0,model.size.width+2*pixel,model.size.height+2*pixel);
    }
    for(NSString *key in animations){
        CAAnimation *original=animations[key];NSString *signature=diBGSignature327(original,0);
        for(NSUInteger i=0;i<targets.count;i++){
            CALayer *layer=targets[i];NSString *dest=[@"di.geometry327." stringByAppendingString:key];
            NSString *token=[NSString stringWithFormat:@"%lu/%@",(unsigned long)i,key];[live addObject:token];
            if([self.animationSignatures327[token] isEqualToString:signature] && [layer animationForKey:dest])continue;
            BOOL ignored=NO;CAAnimation *copy=diBGAnimation327(original,i==0?0:1,pixel,&ignored,0);
            if(!copy)continue;
            if(copy.beginTime!=0)copy.beginTime=[layer convertTime:original.beginTime fromLayer:source];
            [layer addAnimation:copy forKey:dest];self.animationSignatures327[token]=signature;
        }
        // When the system uses radius=0 and the old capsule fallback, derive
        // its radius from exactly the same bounds curve rather than polling.
        if(source.cornerRadius<.1){
            NSString *dest=[@"di.geometry327.radius." stringByAppendingString:key];
            NSString *token=[@"radius/" stringByAppendingString:key];[live addObject:token];
            if(![self.animationSignatures327[token] isEqualToString:signature] || ![self.layer animationForKey:dest]){
                BOOL ignored=NO;CAAnimation *copy=diBGAnimation327(original,2,pixel,&ignored,0);
                if(copy){if(copy.beginTime!=0)copy.beginTime=[self.layer convertTime:original.beginTime fromLayer:source];[self.layer addAnimation:copy forKey:dest];self.animationSignatures327[token]=signature;}
            }
        }
    }
    // Replaced/interrupted system animations must not keep an obsolete curve.
    for(NSString *token in self.animationSignatures327.allKeys)if(![live containsObject:token]){
        if([token hasPrefix:@"radius/"])[self.layer removeAnimationForKey:[@"di.geometry327.radius." stringByAppendingString:[token substringFromIndex:7]]];
        else{NSRange slash=[token rangeOfString:@"/"];NSUInteger index=[[token substringToIndex:slash.location] integerValue];if(index<targets.count)[targets[index] removeAnimationForKey:[@"di.geometry327." stringByAppendingString:[token substringFromIndex:slash.location+1]]];}
        [self.animationSignatures327 removeObjectForKey:token];
    }
    [CATransaction commit];
    self.mirrored327=YES;
    if(CACurrentMediaTime()-self.report327>2){self.report327=CACurrentMediaTime();RLog(@"[动画同步327] renderer=CA source=%@ boundsAnimations=%lu model=%@；不逐帧回写呈现尺寸",NSStringFromClass(source.class),(unsigned long)animations.count,NSStringFromCGRect(model));}
    return YES;
}
- (void)sync {
    // layoutSubviews, heartbeat and display link can all arrive in one run loop.
    // Coalesce near-identical updates and prevent child layout re-entrancy.
    CFTimeInterval now326=CACurrentMediaTime();
    if(self.syncing326 || now326-self.lastSync326<.002)return;
    self.lastSync326=now326;
    UIView *host=self.host;
    if(![self visibleHost]){[self stop];return;}
    // Classification is committed by low-rate refresh; never stop a renderer
    // merely because the model/presentation dimensions disagree during a spring.
    BOOL compositor=NO;
    if(!self.rightSatellite335){
        if(self.geometryProbe336){self.geometryProbe336=NO;compositor=[self mirrorGeometry327:host];}
        else if(self.mirrored327){
            for(NSString *key in self.layer.animationKeys)if([key hasPrefix:@"di.geometry327."]){compositor=YES;break;}
            if(!compositor)self.mirrored327=NO;
        }
    }
    BOOL compactOn=self.rightSatellite335?recOn:smallOn;
    BOOL expandedOn=!self.rightSatellite335 && expandOn;
    CALayer *present=(CALayer *)host.layer.presentationLayer;
    CGRect bounds=present?present.bounds:host.bounds;
    if(bounds.size.width<=1 || bounds.size.height<=1)bounds=host.bounds;
    if(!isfinite(bounds.size.width) || !isfinite(bounds.size.height))return;
    CGFloat modelRadius=host.layer.cornerRadius;
    CGFloat rawRadius=present?present.cornerRadius:modelRadius;
    CGFloat radius=rawRadius;
    if(radius<.1)radius=MIN(bounds.size.width,bounds.size.height)*.5;
    // Compare raw radii: a synthetic capsule fallback versus model radius=0
    // previously reported 'moving' forever and prevented stable decoder sleep.
    BOOL moving=present && (fabs(present.bounds.size.width-host.bounds.size.width)>.35 || fabs(present.bounds.size.height-host.bounds.size.height)>.35 || fabs(rawRadius-modelRadius)>.35);
    CGFloat epsilon=.1/MAX(1.0,UIScreen.mainScreen.scale);
    BOOL changed=fabs(self.frame.origin.x-bounds.origin.x)>epsilon || fabs(self.frame.origin.y-bounds.origin.y)>epsilon || fabs(self.frame.size.width-bounds.size.width)>epsilon || fabs(self.frame.size.height-bounds.size.height)>epsilon || fabs(self.layer.cornerRadius-radius)>.1;
    CGFloat height=(compositor?host.bounds:bounds).size.height;
    BOOL direct337=self.directExpand337 && !self.rightSatellite335;
    if(direct337 && host.bounds.size.width>=280 && host.bounds.size.height>=100)height=host.bounds.size.height;
    // Retain DriftIsland's compact/expanded material split, with a small hysteresis.
    if(!self.modeKnown){self.expandedMode=height>60;self.modeKnown=YES;}
    else if(height>62)self.expandedMode=YES;else if(height<58)self.expandedMode=NO;
    if(self.rightSatellite335)self.expandedMode=NO;
    BOOL requestedMode328=self.expandedMode;
    if(!self.displayKnown328){self.displayedMode328=requestedMode328;self.displayKnown328=YES;}
    if(self.oldMode328!=(requestedMode328?1:0)){
        self.oldMode328=requestedMode328?1:0;self.warmUntil328=now326+.18;self.requestedAt328=now326;
    }
    AVPlayerLayer *requestedLayer328=requestedMode328?self.expandedLayer:self.compactLayer;
    AVQueuePlayer *requestedPlayer328=requestedMode328?self.expandedPlayer:self.compactPlayer;
    UIImageView *requestedImage328=requestedMode328?self.expandedImage:self.compactImage;
    BOOL wantsRequested328=requestedMode328?expandedOn:compactOn;
    // Keep the previous visible frame until a different clip has a displayable
    // frame, for at most .25s; no seek, frame extraction, or permanent dual play.
    BOOL waiting328=wantsRequested328 && requestedPlayer328 && !requestedImage328.image && !requestedLayer328.readyForDisplay && now326-self.requestedAt328<.25;
    if(!waiting328)self.displayedMode328=requestedMode328;
    self.syncing326=YES;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    // Avoid no-op geometry writes that can invalidate layout every display tick.
    if(!compositor){
        if(!CGRectEqualToRect(self.frame,bounds))self.frame=bounds;
        if(fabs(self.layer.cornerRadius-radius)>.01)self.layer.cornerRadius=radius;
    }
    CGRect b=self.bounds;
    // Cover the entire island at every size; never inherit frame-effect insets.
    // Small overscan avoids subpixel seams without moving the visual center.
    CGFloat pixel=1.0/MAX(1.0,UIScreen.mainScreen.scale);
    CGRect video=CGRectInset(b,-pixel,-pixel);
    // Right independent circle uses the SAME edge-to-edge background surface.
    // recScale remains for the old recording accessory, not its canvas.

    AVPlayerLayer *visibleLayer=self.displayedMode328?self.expandedLayer:self.compactLayer;
    UIImageView *visibleImage=self.displayedMode328?self.expandedImage:self.compactImage;
    if(!compositor){
        if(!CGRectEqualToRect(visibleLayer.frame,video))visibleLayer.frame=video;
        if(visibleImage.image && !CGRectEqualToRect(visibleImage.frame,video))visibleImage.frame=video;
    }
    self.compactLayer.hidden=self.displayedMode328 || !compactOn;
    self.expandedLayer.hidden=!self.displayedMode328 || !expandedOn;
    self.compactImage.hidden=self.displayedMode328 || !compactOn;
    self.expandedImage.hidden=!self.displayedMode328 || !expandedOn;
    self.hidden=NO;
    [CATransaction commit];
    // Warm both only while geometry is transitioning. After settling, pause
    // the invisible decoder but retain item/looper and its last rendered frame.
    BOOL warm=now326<self.warmUntil328 || waiting328 || now326<self.prewarmUntil337;
    BOOL wantCompact=compactOn && (!requestedMode328 || warm || !self.displayedMode328);
    BOOL wantExpanded=expandedOn && (requestedMode328 || warm || self.displayedMode328);
    if(wantCompact!=self.compactRequested336){self.compactRequested336=wantCompact;if(wantCompact)[self.compactPlayer play];else [self.compactPlayer pause];}
    if(wantExpanded!=self.expandedRequested336){self.expandedRequested336=wantExpanded;if(wantExpanded)[self.expandedPlayer play];else [self.expandedPlayer pause];}
    if(logEnabled && CFAbsoluteTimeGetCurrent()-self.diagnosticAt>6 && (changed || !self.geometryKnown)){
        self.diagnosticAt=CFAbsoluteTimeGetCurrent();
        RLog(@"[铺满325] model=%@ presentation=%@ surface=%@ video=%@ legacyScale=%.2f legacyOffset=%.1f,%.1f(不应用背景) mode=%d",NSStringFromCGRect(host.bounds),NSStringFromCGRect(bounds),NSStringFromCGRect(self.frame),NSStringFromCGRect(video),animScale,animOffsetX,animOffsetY,self.expandedMode);
    }
    self.geometryKnown=YES;
    self.syncing326=NO;
    if(changed || moving || compositor || waiting328)self.stableTicks=0;else self.stableTicks++;
    if(self.stableTicks>=30){
        self.link.paused=YES;self.lastDisplay326=0;
        if(logEnabled && self.ticks326){RLog(@"[转场328] ticks=%lu late=%lu worstGap=%.2fms screenHz=%ld（回调间隔非视频解码FPS）",(unsigned long)self.ticks326,(unsigned long)self.late326,self.worstGap326*1000,(long)UIScreen.mainScreen.maximumFramesPerSecond);self.ticks326=0;self.late326=0;self.worstGap326=0;}
    } // video keeps playing in compositor
}
- (void)didMoveToWindow {[super didMoveToWindow];if(!self.window)[self stop];}
- (void)dealloc {[_link invalidate];[_compactPlayer pause];[_expandedPlayer pause];}
@end
static void diDirectBackgroundHost324(UIView *host){
    if(!NSThread.isMainThread || !host)return;
    // Exact top container only. Never add children to the content singleton,
    // scaling/rotating wrappers implicated by the 3.1.20 crash.
    if(![NSStringFromClass(host.class) isEqualToString:@"SBSystemApertureContainerView"])return;
    DIIslandBackground324 *surface=objc_getAssociatedObject(host,&kDIBackground324);
    if(!host.window || !enabled || (gLocked || gScreenOff328)){[surface stop];return;}
    if(surface){
        // A size/position change can reclassify an existing container. Defer
        // resource lookup to the existing refresh tick, hiding stale material.
        if(surface.rightSatellite335!=diRightSatellite335(host)){
            // Switch routing once in the existing resource-refresh path rather
            // than hiding and rebuilding video from a layout callback.
            if(![objc_getAssociatedObject(host,&kDIBackgroundPending324) boolValue]){
                objc_setAssociatedObject(host,&kDIBackgroundPending324,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                __weak DIIslandBackground324 *weakSurface=surface;__weak UIView *weakHost=host;
                dispatch_async(dispatch_get_main_queue(),^{objc_setAssociatedObject(weakHost,&kDIBackgroundPending324,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);[weakSurface refresh];});
            }
        }
        CGRect model=host.layer.bounds;CGFloat r=host.layer.cornerRadius;
        BOOL dirty=!surface.observed328 || !CGRectEqualToRect(surface.observedModel328,model) || fabs(surface.observedRadius328-r)>.01;
        surface.observedModel328=model;surface.observedRadius328=r;surface.observed328=YES;
        if(!dirty && !surface.hidden)return;
        surface.geometryProbe336=YES;
        surface.directExpand337=!diIsNowPlayingHostCached(host);
        if(dirty && !surface.rightSatellite335 && model.size.width>=280 && model.size.height>=100)surface.prewarmUntil337=CACurrentMediaTime()+.25;
        // Bypass same-loop sampling debounce on a NEW system destination.
        if(dirty)surface.lastSync326=0;
        [surface startBurst];
        // Display link owns transition geometry; no refresh/asset discovery here.
        // Initial alignment is needed only if resuming a hidden surface.
        [surface sync];
        return;
    }
    if([objc_getAssociatedObject(host,&kDIBackgroundPending324) boolValue])return;
    objc_setAssociatedObject(host,&kDIBackgroundPending324,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weak=host;
    dispatch_async(dispatch_get_main_queue(),^{
        UIView *h=weak;if(!h)return;
        objc_setAssociatedObject(h,&kDIBackgroundPending324,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DIIslandBackground324 *v=objc_getAssociatedObject(h,&kDIBackground324);
        if(!h.window || !enabled || (gLocked || gScreenOff328)){[v stop];return;}
        if(!v){v=[[DIIslandBackground324 alloc]initWithFrame:h.bounds];v.host=h;objc_setAssociatedObject(h,&kDIBackground324,v,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if(!diBackgrounds324)diBackgrounds324=[NSHashTable weakObjectsHashTable];[diBackgrounds324 addObject:v];
            RLog(@"[岛背景324] 已挂顶层容器 %@；背景不依赖音乐，系统内容包装层不变",NSStringFromClass(h.class));}
        if(v.superview!=h){[v removeFromSuperview];[h insertSubview:v atIndex:0];}
        v.directExpand337=!diIsNowPlayingHostCached(h);
        v.geometryProbe336=YES;[v startBurst];[v refresh];
    });
}
static void diDirectBackgroundTick324(void){
    for(DIIslandBackground324 *v in diBackgrounds324.allObjects)[v refresh];
    if(!enabled || (gLocked || gScreenOff328))return;
    static CFAbsoluteTime last=0;CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    if(now-last<3)return;last=now;
    // Catch containers which existed before hook installation, without music.
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
        if(![scene isKindOfClass:UIWindowScene.class])continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows){
            if(![NSStringFromClass(window.class) containsString:@"SystemAperture"])continue;
            NSMutableArray<UIView *> *queue=[NSMutableArray arrayWithObject:window];int budget=240;
            while(queue.count && budget-->0){
                UIView *node=queue.firstObject;[queue removeObjectAtIndex:0];
                if([NSStringFromClass(node.class) isEqualToString:@"SBSystemApertureContainerView"]){
                    if(!objc_getAssociatedObject(node,&kDIBackground324))diDirectBackgroundHost324(node);
                    continue;
                }
                for(UIView *child in node.subviews)[queue addObject:child];
            }
        }
    }
}
