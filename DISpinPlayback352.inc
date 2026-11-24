/* Freeze only our rotation animations; never pause a whole layer (particles,
   masks and native layout must continue independently). Main-thread only. */
static NSHashTable<CALayer *> *diSpinLayers352;
static NSArray<NSString *> *diSpinKeys352(void){return @[@"di.art.spin",@"di.lockscreen.spin343",@"di.lock.background.spin351"];}
static void diSpinSync352(void){
    if(!NSThread.isMainThread||gDIPlayRateState<0)return;
    for(CALayer *layer in diSpinLayers352.allObjects){
        id dg=layer.delegate;
        if([dg isKindOfClass:UIView.class]&&diArtSkipNotify354((UIView *)dg))continue;
        if([dg isKindOfClass:UIView.class]&&diArtSuggestion354((UIView *)dg))continue;
        for(NSString *key in diSpinKeys352()){
            CAAnimation *animation=[layer animationForKey:key];if(!animation)continue;
            BOOL pause=gDIPlayRateState==0;BOOL stopped=animation.speed==0;
            if(pause==stopped)continue;
            CAAnimation *copy=[animation copy];CFTimeInterval local=[layer convertTime:CACurrentMediaTime() fromLayer:nil];
            if(pause){
                CFTimeInterval begin=copy.beginTime;
                if(begin==0)begin=local;
                copy.timeOffset=fmax(0,(local-begin)*copy.speed+copy.timeOffset);
                copy.speed=0;copy.beginTime=local;
            }else{
                CFTimeInterval offset=copy.timeOffset;copy.speed=1;copy.timeOffset=0;copy.beginTime=local-offset;
            }
            [layer addAnimation:copy forKey:key];
        }
    }
}
static BOOL diArtSkipNotify354(UIView *v);
static BOOL diArtSuggestion354(UIView *v);
static void diSpinRegister352(CALayer *layer){
    if(!layer||!NSThread.isMainThread)return;
    id dg=layer.delegate;
    if([dg isKindOfClass:UIView.class]&&diArtSkipNotify354((UIView *)dg))return;
    /* 推荐格照旧旋转(3.1.51 行为), 但不纳入暂停冻结 —— 用户只要求主专辑跟播放状态走。 */
    if([dg isKindOfClass:UIView.class]&&diArtSuggestion354((UIView *)dg))return;
    if(!diSpinLayers352)diSpinLayers352=[NSHashTable weakObjectsHashTable];
    [diSpinLayers352 addObject:layer];diSpinSync352();
}
