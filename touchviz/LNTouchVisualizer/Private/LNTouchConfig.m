//
//  LNTouchConfig.m
//  LNTouchVisualizer
//
//  Created by Joseph Blau on 12/2/17.
//  Copyright © 2017 conopsys. All rights reserved.
//

#import <LNTouchVisualizer/LNTouchConfig.h>

static const CGFloat LNTouchConfigContactAlpha = 1.0;
static const CGFloat LNTouchConfigRippleAlpha = 1.0;

static const NSTimeInterval LNTouchConfigContactFadeDuration = 0.3;
static const NSTimeInterval LNTouchConfigRippleFadeDuration = 0.2;

@implementation LNTouchConfig

- (instancetype)init {
    self = [super init];

    if (self) {
        self.strokeColor = UIColor.labelColor;
        self.fillColor = UIColor.systemBackgroundColor;
        self.alpha = LNTouchConfigContactAlpha;
        self.radius = 20.0;
        self.liftScale = 2.0;
        self.borderWidth = 3.0;
        self.cornerRadius = 20.0;
        self.morphDelay = 0.6;
        self.morphDuration = 0.4;
        self.fadeDuration = LNTouchConfigContactFadeDuration;
        self.shouldAutoRotate = NO;
        self.fillImage = nil;
    }

    return self;
}

#pragma mark - Private

+ (LNTouchConfig *)touchConfig {
    return [LNTouchConfig new];
}

+ (LNTouchConfig *)rippleConfig {
    LNTouchConfig *rv = [LNTouchConfig new];

    rv.strokeColor = UIColor.systemBackgroundColor;
    rv.fillColor = UIColor.systemBlueColor;
    rv.alpha = LNTouchConfigRippleAlpha;
    rv.fadeDuration = LNTouchConfigRippleFadeDuration;

    return rv;
}

@end
