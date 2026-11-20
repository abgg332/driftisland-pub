/* 3.1.24 independent reconstruction of a container-driven island background.
 * Evidence: DynamicFX 1.0.7 arm64e 0x12c0c/0x12ebc/0x11bac/0x119ac.
 * No third-party binary, authorization, network code, or forced island activity.
 */
static BOOL diDirectBackgroundAvailable324(void){
    return NSClassFromString(@"SBSystemApertureContainerView")!=Nil;
}
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
@property(nonatomic,assign) NSUInteger compactGeneration;
@property(nonatomic,assign) NSUInteger expandedGeneration;
@property(nonatomic,assign) NSInteger stableTicks;
@property(nonatomic,assign) BOOL expandedMode;
@property(nonatomic,assign) BOOL modeKnown;
@property(nonatomic,assign) BOOL preparing;
- (void)refresh;
- (void)sync;
- (void)startBurst;
- (void)stop;
@end
@implementation DIBackgroundTicker324
- (void)tick:(CADisplayLink *)link {DIIslandBackground324 *o=self.owner;if(o)[o sync];else [link invalidate];}
@end
@implementation DIIslandBackground324
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])){
        self.userInteractionEnabled=NO;self.clipsToBounds=YES;
        self.backgroundColor=UIColor.clearColor;
        _compactLayer=[AVPlayerLayer layer];_expandedLayer=[AVPlayerLayer layer];
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
    self.stableTicks=0;
    if(!self.link){self.link=[CADisplayLink displayLinkWithTarget:self.ticker selector:@selector(tick:)];
        NSInteger max=UIScreen.mainScreen.maximumFramesPerSecond;
        self.link.preferredFrameRateRange=CAFrameRateRangeMake(30,MAX(60,max),MAX(60,max));
        [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];}
    self.link.paused=NO;
}
- (void)stop {
    [self.compactPlayer pause];[self.expandedPlayer pause];
    self.hidden=YES;self.link.paused=YES;
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
            if(source && CMTIME_IS_NUMERIC(asset.duration) && CMTimeCompare(asset.duration,kCMTimeZero)>0){
                AVMutableComposition *comp=[AVMutableComposition composition];
                AVMutableCompositionTrack *track=[comp addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
                if([track insertTimeRange:CMTimeRangeMake(kCMTimeZero,asset.duration) ofTrack:source atTime:kCMTimeZero error:NULL]){track.preferredTransform=source.preferredTransform;video=comp;}
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
                AVPlayerLooper *looper=[AVPlayerLooper playerLooperWithPlayer:player templateItem:item];
                if(expanded){[o.expandedPlayer pause];o.expandedLooper=looper;o.expandedPlayer=player;o.expandedLayer.player=player;}
                else{[o.compactPlayer pause];o.compactLooper=looper;o.compactPlayer=player;o.compactLayer.player=player;}
                iv.image=nil;
            }else{
                // Fail closed: do not fall back to an asset containing an audio track.
                if(expanded){[o.expandedPlayer pause];o.expandedLooper=nil;o.expandedPlayer=nil;o.expandedLayer.player=nil;}
                else{[o.compactPlayer pause];o.compactLooper=nil;o.compactPlayer=nil;o.compactLayer.player=nil;}
                iv.image=nil;RLog(@"[岛背景324] 仅视频轨加载失败 %@",path.lastPathComponent);
            }
            [o startBurst];[o sync];
        });
    });
}
- (BOOL)visibleHost {
    UIView *host=self.host;
    if(!enabled || gLocked || !host.window || host.window.hidden)return NO;
    for(UIView *v=host;v;v=v.superview)if(v.hidden || v.alpha<.01)return NO;
    if(notifyBgOff && ([objc_getAssociatedObject(host,&kHostIsNotif) boolValue] || [objc_getAssociatedObject(host,&kCapIsNotif) boolValue]))return NO;
    return host.bounds.size.width>2 && host.bounds.size.height>2;
}
- (void)refresh {
    NSString *small=materialPathFor(NO),*large=materialPathFor(YES);
    NSString *sig=[NSString stringWithFormat:@"%d/%d/%d/%d/%@/%@/%.3f/%.3f/%.3f/%.2f",enabled,gLocked,smallOn,expandOn,small?:@"",large?:@"",animScale,animOffsetX,animOffsetY,animFPS];
    BOOL changed=![self.prefSignature isEqualToString:sig];self.prefSignature=sig;
    if(![self visibleHost]){[self stop];return;}
    if(changed){[self loadPath:small expanded:NO];[self loadPath:large expanded:YES];[self startBurst];}
    if(self.hidden)[self startBurst];
    [self sync];
}
- (void)sync {
    UIView *host=self.host;
    if(![self visibleHost]){[self stop];return;}
    CALayer *present=(CALayer *)host.layer.presentationLayer;
    CGRect bounds=present?present.bounds:host.bounds;
    if(bounds.size.width<=1 || bounds.size.height<=1)bounds=host.bounds;
    if(!isfinite(bounds.size.width) || !isfinite(bounds.size.height))return;
    CGFloat radius=present?present.cornerRadius:host.layer.cornerRadius;
    if(radius<.1)radius=MIN(bounds.size.width,bounds.size.height)*.5;
    BOOL moving=present && (fabs(present.bounds.size.width-host.bounds.size.width)>.35 || fabs(present.bounds.size.height-host.bounds.size.height)>.35 || fabs(radius-host.layer.cornerRadius)>.35);
    BOOL changed=!CGRectEqualToRect(self.frame,bounds) || fabs(self.layer.cornerRadius-radius)>.1;
    CGFloat height=bounds.size.height;
    // Retain DriftIsland's compact/expanded material split, with a small hysteresis.
    if(!self.modeKnown){self.expandedMode=height>60;self.modeKnown=YES;}
    else if(height>62)self.expandedMode=YES;else if(height<58)self.expandedMode=NO;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    self.frame=bounds;self.layer.cornerRadius=radius;
    CGRect b=self.bounds;
    CGFloat scale=isfinite(animScale)?MAX(.1,MIN(4,animScale)):1;
    CGRect video=CGRectMake(CGRectGetMidX(b)-b.size.width*scale*.5+animOffsetX,CGRectGetMidY(b)-b.size.height*scale*.5+animOffsetY,b.size.width*scale,b.size.height*scale);
    self.compactLayer.frame=video;self.expandedLayer.frame=video;
    self.compactImage.frame=video;self.expandedImage.frame=video;
    self.compactLayer.hidden=self.expandedMode || !smallOn;
    self.expandedLayer.hidden=!self.expandedMode || !expandOn;
    self.compactImage.hidden=self.expandedMode || !smallOn;
    self.expandedImage.hidden=!self.expandedMode || !expandOn;
    self.hidden=NO;
    [CATransaction commit];
    AVQueuePlayer *current=self.expandedMode?self.expandedPlayer:self.compactPlayer;
    AVQueuePlayer *other=self.expandedMode?self.compactPlayer:self.expandedPlayer;
    BOOL allowed=self.expandedMode?expandOn:smallOn;
    if(allowed){float rate=MAX(.1,MIN(4,animFPS/50.0));if(fabs(current.rate-rate)>.01)[current setRate:rate];}else [current pause];
    // Pause the other decoder only after transition settles; keep the looper/item.
    if(!moving)[other pause];
    if(changed || moving)self.stableTicks=0;else self.stableTicks++;
    if(self.stableTicks>=30)self.link.paused=YES; // video keeps playing in compositor
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
    if(!host.window || !enabled || gLocked){[surface stop];return;}
    if([objc_getAssociatedObject(host,&kDIBackgroundPending324) boolValue])return;
    objc_setAssociatedObject(host,&kDIBackgroundPending324,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weak=host;
    dispatch_async(dispatch_get_main_queue(),^{
        UIView *h=weak;if(!h)return;
        objc_setAssociatedObject(h,&kDIBackgroundPending324,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DIIslandBackground324 *v=objc_getAssociatedObject(h,&kDIBackground324);
        if(!h.window || !enabled || gLocked){[v stop];return;}
        if(!v){v=[[DIIslandBackground324 alloc]initWithFrame:h.bounds];v.host=h;objc_setAssociatedObject(h,&kDIBackground324,v,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if(!diBackgrounds324)diBackgrounds324=[NSHashTable weakObjectsHashTable];[diBackgrounds324 addObject:v];
            RLog(@"[岛背景324] 已挂顶层容器 %@；背景不依赖音乐，系统内容包装层不变",NSStringFromClass(h.class));}
        if(v.superview!=h){[v removeFromSuperview];[h insertSubview:v atIndex:0];}
        [v startBurst];[v refresh];
    });
}
static void diDirectBackgroundTick324(void){
    for(DIIslandBackground324 *v in diBackgrounds324.allObjects)[v refresh];
    if(!enabled || gLocked)return;
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
