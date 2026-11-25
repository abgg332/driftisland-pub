/* ===== 3.1.55: 岛上专辑旋转跟随播放状态 =====
   用户 D3247115: 锁屏/控制中心都对了, 只剩小岛与展开岛暂停后还在转。
   岛上这颗是 MediaRemoteUI 进程自绘的(两个键):
     · di.spin  —— SpringBoard 侧玻璃层(15771)
     · diSpin   —— MRU 自绘 _artView(4686)
   3.1.52 的冻结在 SpringBoard 侧只认 di.art.spin / di.lockscreen.spin343 /
   di.lock.background.spin351, 完全没覆盖 MRU 进程(它在独立沙盒里, 看不到那边的
   gDIPlayRateState)。这里在本进程内直接查 PlaybackRate 并把这两条动画冻结/续转。
   做法与 3.1.52 一致: 只改动画的 speed/timeOffset, 绝不暂停整层
   (不然粒子/律动/遮罩一起停)。 */

/* -1 未知 / 0 暂停·停止 / 1 播放中 */
static NSInteger gDIMruPlayState355 = -1;
static CFTimeInterval gDIMruPlayAt355 = 0;
static BOOL gDIMruPlayAsked355 = NO;

static void diMruSpinSync355(void);
static NSHashTable<CALayer *> *gDIMruSpinLayers355;
static void diMruPlayPoll355(void) {
    if (!NSThread.isMainThread) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gDIMruPlayAt355 < 0.45) return;
    gDIMruPlayAt355 = now;
    diNPLoadMediaRemote();
    if (!gMRGetNowPlayingInfo) return;
    if (gDIMruPlayAsked355) return;
    gDIMruPlayAsked355 = YES;
    gMRGetNowPlayingInfo(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(CFDictionaryRef info) {
        @autoreleasepool { @try {
            if (!info) { gDIMruPlayAsked355 = NO; return; }   /* 取不到就保持上次判断 */
            CFStringRef key = (gMRRateKeyPtr && *gMRRateKeyPtr) ? *gMRRateKeyPtr : NULL;
            if (!key) { gDIMruPlayAsked355 = NO; return; }
            id rv = (__bridge id)CFDictionaryGetValue(info, key);
            if (![rv isKindOfClass:NSNumber.class]) { gDIMruPlayAsked355 = NO; return; }
            NSInteger st = ([rv doubleValue] > 0.01) ? 1 : 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                gDIMruPlayAsked355 = NO;
                if (gDIMruPlayState355 == st) return;
                gDIMruPlayState355 = st;
                diMruFileLog([NSString stringWithFormat:@"[岛旋转355] 播放状态=%@ 跟随=%@ 层数=%lu",
                              st ? @"播放" : @"暂停", st ? @"续转" : @"停转",
                              (unsigned long)gDIMruSpinLayers355.allObjects.count]);
                diMruSpinSync355();
            });
        } @catch (__unused NSException *e) { gDIMruPlayAsked355 = NO; } }
    });
}

static NSArray<NSString *> *diMruSpinKeys355(void) { return @[@"di.spin", @"diSpin"]; }

static void diMruSpinSyncLayer355(CALayer *layer) {
    if (!layer) return;
    for (NSString *key in diMruSpinKeys355()) {
        CAAnimation *animation = [layer animationForKey:key];
        if (!animation) continue;
        BOOL pause = (gDIMruPlayState355 == 0);
        BOOL stopped = (animation.speed == 0);
        if (pause == stopped) continue;
        CFTimeInterval local = [layer convertTime:CACurrentMediaTime() fromLayer:nil];
        CAAnimation *copy = [animation copy];
        if (pause) {
            CFTimeInterval begin = copy.beginTime;
            if (begin == 0) begin = local;
            copy.timeOffset = fmax(0, (local - begin) * copy.speed + copy.timeOffset);
            copy.speed = 0;
            copy.beginTime = local;
        } else {
            CFTimeInterval offset = copy.timeOffset;
            copy.speed = 1;
            copy.timeOffset = 0;
            copy.beginTime = local - offset;
        }
        [layer addAnimation:copy forKey:key];
    }
}

/* 汇总: 玻璃层与自绘 _artView 都在本进程登记; 只有登记过才起一个 0.9s 心跳。 */
static dispatch_source_t gDIMruSpinTimer355;
static void diMruSpinRegister355(CALayer *layer) {
    if (!layer || !NSThread.isMainThread) return;
    if (!gDIMruSpinLayers355) gDIMruSpinLayers355 = [NSHashTable weakObjectsHashTable];
    [gDIMruSpinLayers355 addObject:layer];
    diMruSpinSyncLayer355(layer);
    /* 只在本进程确实挂过岛旋转时才起心跳, 避免无谓常驻。周期 0.9s, 与既有 1s 轮询同量级。 */
    if (!gDIMruSpinTimer355) {
        gDIMruSpinTimer355 = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                    dispatch_get_main_queue());
        if (gDIMruSpinTimer355) {
            dispatch_source_set_timer(gDIMruSpinTimer355,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                (uint64_t)(0.9 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gDIMruSpinTimer355, ^{
                diMruPlayPoll355();
                diMruSpinSync355();
            });
            dispatch_resume(gDIMruSpinTimer355);
        }
    }
    diMruPlayPoll355();
}
static void diMruSpinSync355(void) {
    if (!NSThread.isMainThread || gDIMruPlayState355 < 0) return;
    for (CALayer *layer in gDIMruSpinLayers355.allObjects) diMruSpinSyncLayer355(layer);
}
