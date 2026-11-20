//
//  UIWindowScene+TouchVisualizer.m
//  LNTouchVisualizer
//
//  Created by Leo Natan on 3/24/21.
//

#import <LNTouchVisualizer/LNTouchVisualizerWindow.h>
#import <LNTouchVisualizer/UIWindowScene+TouchVisualizer.h>

#import <objc/runtime.h>

#import "TouchViz-Swift.h"
#import "DITVZSceneSafety.h"

static const void *LNTouchVisualizerWindowKey = &LNTouchVisualizerWindowKey;

__attribute__((visibility("hidden")))
@interface _LNSceneTouchVisualizerWindow : LNTouchVisualizerWindow
@end
@implementation _LNSceneTouchVisualizerWindow

#ifndef LNPopupControllerEnforceStrictClean
+ (void)load {
    @autoreleasepool {
        NSMutableString *name = [@"_" mutableCopy];
        [name appendString:@"canAffect"];
        [name appendString:[NSStringFromClass(UIStatusBarManager.class) substringWithRange:NSMakeRange(2, 9)]];
        [name appendString:[NSStringFromClass(UIBarAppearance.class) substringFromIndex:5]];

        Method m = class_getInstanceMethod(self, @selector(_cASBA));
        class_addMethod(self, NSSelectorFromString(name), method_getImplementation(m), method_getTypeEncoding(m));

        name = [@"_" mutableCopy];
        [name appendString:[NSStringFromSelector(@selector(canBecomeFirstResponder)) substringToIndex:9]];
        [name appendString:[NSStringFromSelector(@selector(isKeyWindow)) substringFromIndex:2]];

        m = class_getInstanceMethod(self, @selector(_cASBA));
        class_addMethod(self, NSSelectorFromString(name), method_getImplementation(m), method_getTypeEncoding(m));
    }
}

//_canAffectStatusBarAppearance
- (BOOL)_cASBA {
    return NO;
}

//_canBecomeKeyWindow
- (BOOL)_cBKW {
    return NO;
}
#endif

- (UIWindow *)overlayWindow {
    return self;
}

@end

__attribute__((visibility("hidden")))
@interface UIWindow (TouchVisualizerForwarding)
@end
@implementation UIWindow (TouchVisualizerForwarding)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      Method m1 = class_getInstanceMethod(self, @selector(sendEvent:));
      Method m2 = class_getInstanceMethod(self, @selector(__ln_vis_sendEvent:));
      method_exchangeImplementations(m1, m2);
    });
}

- (void)__ln_vis_sendEvent:(UIEvent *)event {
    if(DITVZIs17()){
        if([self isKindOfClass:_LNSceneTouchVisualizerWindow.class])return;
        // System dispatch happens exactly once; never catch/swallow system errors.
        [self __ln_vis_sendEvent:event];
        if(event.type!=UIEventTypeTouches || !NSThread.isMainThread)return;
        // _UISystemGestureWindow has a separate observer. Avoid a duplicate feed.
        Class gesture=NSClassFromString(@"_UISystemGestureWindow");
        if(gesture && [self isKindOfClass:gesture])return;
        @try{
            UIWindowScene *scene=self.windowScene;
            LNTouchVisualizerWindow *overlay=objc_getAssociatedObject(scene,LNTouchVisualizerWindowKey);
            if(overlay && !overlay.hidden && DITVZEligibleScene(scene)){
                [overlay sendTouchEvent:event];
                [overlay sendQuickPathEvent:event];
            }
        }@catch(NSException *exception){
            NSLog(@"[轨迹安全321] 观察触摸失败 %@: %@",exception.name,exception.reason);
            LNTouchVisualizerWindow *overlay=objc_getAssociatedObject(self.windowScene,LNTouchVisualizerWindowKey);
            overlay.hidden=YES;
        }
        return;
    }

    if ([self isKindOfClass:[_LNSceneTouchVisualizerWindow class]]) {
        return;
    }

    if (self.windowScene.touchVisualizerEnabled) {
        [self.windowScene.touchVisualizerWindow sendEvent:event];
    }

    [self __ln_vis_sendEvent:event];
}

@end

@implementation UIWindowScene (TouchVisualizer)

- (LNTouchVisualizerWindow *)touchVisualizerWindow {
    LNTouchVisualizerWindow *rv = objc_getAssociatedObject(self, LNTouchVisualizerWindowKey);

    NSString *processName = [[NSProcessInfo processInfo] processName];
    if(DITVZIs17() && !DITVZEligibleScene(self))return rv;
    if (rv == nil && [processName isEqualToString:@"SpringBoard"]) {
        rv = [_LNSceneTouchVisualizerWindow new];
        rv.windowLevel = CGFLOAT_MAX;
        rv.backgroundColor = [UIColor.greenColor colorWithAlphaComponent:0.0];
        rv.hidden = YES;
        rv.userInteractionEnabled = NO;
        rv.frame = UIScreen.mainScreen.bounds;
        rv.windowScene = self;

        objc_setAssociatedObject(self, LNTouchVisualizerWindowKey, rv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    return rv;
}

- (void)setTouchVisualizerEnabled:(BOOL)touchVisualizerEnabled {
    self.touchVisualizerWindow.hidden = touchVisualizerEnabled == NO;
}

- (BOOL)touchVisualizerEnabled {
    if(DITVZIs17()){
        LNTouchVisualizerWindow *existing=objc_getAssociatedObject(self,LNTouchVisualizerWindowKey);
        return existing && !existing.hidden;
    }
    return self.touchVisualizerWindow.hidden == NO;
}

@end
