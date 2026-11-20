#import <UIKit/UIKit.h>

// iOS17 hosts Dynamic Island presentations in distinct system scenes. A touch
// observer must not allocate a screen-sized window in an aperture/remote scene.
static inline BOOL DITVZIs17(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 17;
}
static inline BOOL DITVZEligibleScene(UIWindowScene *scene) {
    if(!scene || scene.screen!=UIScreen.mainScreen)return NO;
    NSString *name=NSStringFromClass(scene.class).lowercaseString;
    NSString *role=scene.session.role.lowercaseString;
    for(NSString *token in @[@"aperture",@"remote",@"keyboard",@"input",@"recording"])
        if([name containsString:token] || [role containsString:token])return NO;
    CGSize screen=scene.screen.bounds.size;
    for(UIWindow *window in scene.windows){
        NSString *wn=NSStringFromClass(window.class).lowercaseString;
        if([wn containsString:@"visualizer"] || [wn containsString:@"aperture"] || [wn containsString:@"recording"])continue;
        CGSize size=window.bounds.size;
        if(!window.hidden && size.width>=screen.width*.9 && size.height>=screen.height*.9)return YES;
    }
    return NO;
}
