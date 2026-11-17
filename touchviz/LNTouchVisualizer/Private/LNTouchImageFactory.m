//
//  LNTouchImageFactory.m
//  LNTouchVisualizer
//
//  Created by Joseph Blau on 12/2/17.
//  Copyright © 2017 conopsys. All rights reserved.
//

#import "LNTouchImageFactory.h"
#import <LNTouchVisualizer/LNTouchConfig.h>

@implementation LNTouchImageFactory

+ (UIImage *)imageWithTouchConfig:(LNTouchConfig *)touchConfig {
    CGFloat cornerRadius = touchConfig.cornerRadius;
    BOOL shouldDrawCircle = (cornerRadius >= touchConfig.radius - 1e-2);

    UIBezierPath *clipPath =
        [UIBezierPath bezierPathWithRect:CGRectMake(0.0, 0.0, touchConfig.radius * 2, touchConfig.radius * 2)];

    UIGraphicsBeginImageContextWithOptions(clipPath.bounds.size, NO, 0);

    UIImage *fillImage = touchConfig.fillImage;
    if (fillImage) {
        [fillImage drawInRect:clipPath.bounds];
    }

    UIBezierPath *drawPath;
    if (shouldDrawCircle) {
        CGPoint center = CGPointMake(touchConfig.radius, touchConfig.radius);
        drawPath = [UIBezierPath bezierPathWithArcCenter:center
                                                  radius:touchConfig.radius - touchConfig.borderWidth / 2.0
                                              startAngle:0
                                                endAngle:2 * M_PI
                                               clockwise:YES];
    } else {
        CGRect rect = CGRectMake(touchConfig.borderWidth / 2.0,
                                 touchConfig.borderWidth / 2.0,
                                 touchConfig.radius * 2 - touchConfig.borderWidth,
                                 touchConfig.radius * 2 - touchConfig.borderWidth);
        if (cornerRadius > 1e-2) {
            drawPath = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:cornerRadius];
        } else {
            drawPath = [UIBezierPath bezierPathWithRect:rect];
        }
    }

    drawPath.lineWidth = touchConfig.borderWidth;

    [touchConfig.fillColor setFill];
    [touchConfig.strokeColor setStroke];

    [drawPath fill];
    [drawPath stroke];
    [clipPath addClip];

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return image;
}

@end
