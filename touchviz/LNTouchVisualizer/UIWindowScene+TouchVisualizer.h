//
//  UIWindowScene+TouchVisualizer.h
//  LNTouchVisualizer
//
//  Created by Leo Natan on 3/24/21.
//

#import <LNTouchVisualizer/LNTouchVisualizer.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("hidden")))
@interface UIWindowScene (TouchVisualizer)

@property(nonatomic, assign) BOOL touchVisualizerEnabled;
@property(nonatomic, strong, readonly) LNTouchVisualizerWindow *touchVisualizerWindow;

@end

NS_ASSUME_NONNULL_END
