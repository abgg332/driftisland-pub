//
//  LNTouchVisualizerWindow.h
//  TouchVisualizer
//
//  Created by Joe Blau on 3/22/14.
//  Copyright (c) 2014 conopsys. All rights reserved.
//
#import <LNTouchVisualizer/LNTouchConfig.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("hidden")))
@interface LNTouchVisualizerWindow : UIWindow

@property(nonatomic, getter=isTouchVisualizationEnabled) BOOL touchVisualizationEnabled;
@property(nonatomic, getter=isQuickPathEnabled) BOOL quickPathEnabled;
@property(nonatomic, getter=isMorphEnabled) BOOL morphEnabled;
@property(nonatomic, getter=isTrackingEnabled) BOOL trackingEnabled;

@property(nonatomic, strong) LNTouchConfig *touchContactConfig;
@property(nonatomic, strong) LNTouchConfig *touchRippleConfig;

- (instancetype)initWithFrame:(CGRect)frame
    touchVisualizationEnabled:(BOOL)touchVisualizationEnabled
             quickPathEnabled:(BOOL)quickPathEnabled
                 morphEnabled:(BOOL)morphEnabled
              trackingEnabled:(BOOL)trackingEnabled
                contactConfig:(nullable LNTouchConfig *)contactConfig
                 rippleConfig:(nullable LNTouchConfig *)rippleConfig NS_DESIGNATED_INITIALIZER;

- (void)sendTouchEvent:(UIEvent *)event;
- (BOOL)hasAnyTouch;

@end

NS_ASSUME_NONNULL_END
