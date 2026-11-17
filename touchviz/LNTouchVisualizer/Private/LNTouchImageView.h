//
//  LNTouchSpotView.h
//  LNTouchVisualizer
//
//  Created by Joseph Blau on 11/30/17.
//  Copyright © 2017 conopsys. All rights reserved.
//

#import <UIKit/UIKit.h>

__attribute__((visibility("hidden")))
@interface LNTouchImageView : UIImageView

@property(nonatomic) NSTimeInterval timestamp;
@property(nonatomic) BOOL shouldAutomaticallyRemoveAfterTimeout;
@property(nonatomic, getter=isFadingOut) BOOL fadingOut;

@end
