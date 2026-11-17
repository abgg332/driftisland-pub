//
//  LNTouchConfig.h
//  LNTouchVisualizer
//
//  Created by Joseph Blau on 12/2/17.
//  Copyright © 2017 conopsys. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("hidden")))
@interface LNTouchConfig : NSObject

@property(nonatomic, assign) CGFloat alpha;
@property(nonatomic, assign) CGFloat radius;
@property(nonatomic, assign) CGFloat liftScale;
@property(nonatomic, assign) CGFloat borderWidth;
@property(nonatomic, assign) CGFloat cornerRadius;
@property(nonatomic, assign) NSTimeInterval fadeDuration;

@property(nonatomic, assign) NSTimeInterval morphDelay;
@property(nonatomic, assign) NSTimeInterval morphDuration;

@property(nonatomic, assign) BOOL shouldAutoRotate;
@property(nonatomic, strong, nullable) UIImage *fillImage;

@property(nonatomic, strong, nullable) UIColor *strokeColor;
@property(nonatomic, strong, nullable) UIColor *fillColor;

@property(nonatomic, class, strong, readonly) LNTouchConfig *rippleConfig;
@property(nonatomic, class, strong, readonly) LNTouchConfig *touchConfig;

@end

NS_ASSUME_NONNULL_END
