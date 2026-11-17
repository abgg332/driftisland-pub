#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("hidden")))
@interface NSBundle (TouchViz)

@property(class, nonatomic, readonly) NSBundle *tvz_supportBundle;
@property(class, nonatomic, readonly) NSString *tvz_packageVersion;

+ (UIImage *)tvz_fillImageNamed:(NSString *)name;
+ (NSString *_Nullable)tvz_saveFillImageWithPath:(NSString *)path;
+ (NSString *_Nullable)tvz_saveFillImageWithImage:(UIImage *)image;
+ (BOOL)tvz_removeAllFillImages;

@end

NS_ASSUME_NONNULL_END