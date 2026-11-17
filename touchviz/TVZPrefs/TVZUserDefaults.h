#import <UIKit/UIKit.h>

#define tvzBool(key) [[TVZUserDefaults standardUserDefaults] boolForKey:key]
#define TVZ_NOTIFY_NAME "com.82flex.touchviz.reload-prefs"
#define TVZ_COLOR [UIColor colorWithRed:235.0 / 255 green:59.0 / 255 blue:90.0 / 255 alpha:1.0]

NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("hidden")))
@interface TVZUserDefaults : NSUserDefaults

+ (NSSet<NSString *> *)longScreenshotterKeys;

@property(class, readonly, strong) TVZUserDefaults *standardUserDefaults;

- (void)beginUpdates;
- (void)endUpdates;

- (void)resetToDefaultValues;
- (void)darwinNotify;

@end

NS_ASSUME_NONNULL_END