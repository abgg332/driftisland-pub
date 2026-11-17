#import <Foundation/Foundation.h>
#import <LNTouchVisualizer/LNTouchVisualizer.h>
#import <UIKit/UIKit.h>

#import <dlfcn.h>
#import <HBLog.h>
#import <notify.h>

#import "TVZPrefs/NSBundle+TVZPrefs.h"
#import "TVZPrefs/TVZUserDefaults.h"
#import "TouchViz-Swift.h"

@protocol SBReachabilityObserver <NSObject>
@optional
- (void)handleReachabilityModeActivated;
- (void)handleReachabilityModeDeactivated;
- (void)handleReachabilityYOffsetDidChange;
- (void)handleWillBeginReachabilityAnimation;
- (void)handleDidEndReachabilityAnimation;
@end

@interface SBReachabilityManager : NSObject
+ (instancetype)sharedInstance;
+ (BOOL)reachabilitySupported;
- (BOOL)reachabilityEnabled;
- (BOOL)reachabilityModeActive;
- (void)addObserver:(id<SBReachabilityObserver>)observer;
@end

@interface RPBroadcastController : NSObject
@property (nonatomic, copy) NSString *tvz_inBroadcastingExtensionIdentifier;
@property (getter=isBroadcasting, nonatomic, readonly) BOOL broadcasting;
@end

@interface RPScreenRecorder : NSObject
@property (nonatomic, copy) NSString *tvz_inBroadcastingExtensionIdentifier;
@property (nonatomic, retain) RPBroadcastController *activeBroadcastController;
@property (assign, nonatomic) BOOL broadcasting;
+ (instancetype)sharedRecorder;
- (void)setupSystemBroadcastWithExtension:(NSString *)arg1 handler:(id)arg2;
- (void)startSystemBroadcastWithHandler:(id)arg1;
- (void)stopSystemBroadcastWithHandler:(id)arg1;
@end

@interface UIColor (TVZ)
+ (UIColor *)tvz_colorWithRGBAString:(NSString *)rgbaString;
+ (UIColor *)tvz_colorWithRGBAString:(NSString *)rgbaString extraAlpha:(CGFloat)extraAlpha;
@end

@implementation UIColor (TVZ)

+ (UIColor *)tvz_colorWithRGBAString:(NSString *)rgbaString {
    return [self tvz_colorWithRGBAString:rgbaString extraAlpha:1.0];
}

+ (UIColor *)tvz_colorWithRGBAString:(NSString *)rgbaString extraAlpha:(CGFloat)extraAlpha {
    NSArray<NSString *> *components = [rgbaString componentsSeparatedByString:@","];
    if (components.count < 3) {
        return nil;
    }
    CGFloat r = [components[0] doubleValue] / 255.0;
    CGFloat g = [components[1] doubleValue] / 255.0;
    CGFloat b = [components[2] doubleValue] / 255.0;
    CGFloat a = (components.count >= 4 ? [components[3] doubleValue] : 1.0) * extraAlpha;
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

@end

static UIWindowScene *_gWindowScene = nil;
static LNTouchVisualizerWindow *_gWindow = nil;
static LNTouchConfig *_gTouchConfig = nil;
static LNTouchConfig *_gRippleConfig = nil;

static BOOL _gEnabled = NO;
static BOOL _gEnabledOnlyWhenRecording = NO;

static BOOL _gEnableOverride = NO;
static BOOL _gDisableOverride = NO;
static BOOL _gDisableOverrideWhenRecording = NO;

static BOOL _gIsRecording = NO;
static BOOL _gIsBroadcasting = NO;
static BOOL _gIsInReachability = NO;

static NSInteger HomeButtonType(void) {
    typedef CFTypeRef (*MGCopyAnswerFunction)(CFStringRef key);

    static dispatch_once_t onceToken;
    static NSInteger homeButtonType = 0;
    dispatch_once(&onceToken, ^{
      MGCopyAnswerFunction MGCopyAnswer = (MGCopyAnswerFunction)dlsym(RTLD_DEFAULT, "MGCopyAnswer");
      if (!MGCopyAnswer) {
          return;
      }

      id value = CFBridgingRelease(MGCopyAnswer(CFSTR("HomeButtonType")));
      if ([value respondsToSelector:@selector(integerValue)]) {
          homeButtonType = [value integerValue];
      }
    });
    return homeButtonType;
}

static BOOL IsRealHomeButtonDevice(void) {
    return HomeButtonType() == 1;
}

static BOOL IsAnyScreenInRecording(void) {
    for (UIScreen *screen in [UIScreen screens]) {
        if ([screen isCaptured]) {
            return YES;
        }
    }
    return NO;
}

static BOOL IsEnabled(void) {
    if (!_gEnabled || _gIsInReachability) {
        return NO;
    }

    if (_gIsRecording) {
        if (_gIsBroadcasting) {
            return NO;
        }
        return !_gDisableOverrideWhenRecording;
    }

    if (_gEnabledOnlyWhenRecording) {
        if (!_gEnableOverride) {
            return NO;
        }
    } else {
        if (_gDisableOverride) {
            return NO;
        }
    }

    return YES;
}

static BOOL ShouldKeepSystemGestureTouchStreamSending(void) {
    return IsEnabled() || [_gWindow hasAnyTouch];
}

static void ReloadStats(void) {
    _gIsRecording = IsAnyScreenInRecording();
    if (!_gIsRecording) _gIsBroadcasting = NO;
    _gIsInReachability = [[%c(SBReachabilityManager) sharedInstance] reachabilityModeActive];

    BOOL isEnabled = IsEnabled();
    _gWindowScene.touchVisualizerEnabled = isEnabled;
    if (!isEnabled) {
        _gWindow.quickPathEnabled = NO;
        _gWindow.morphEnabled = NO;
        _gWindow.trackingEnabled = NO;
    }

    HBLogDebug(@"Is Recording: %@, Is Broadcasting: %@, Is In Reachability: %@, Is Enabled: %@",
                _gIsRecording ? @"YES" : @"NO",
                _gIsBroadcasting ? @"YES" : @"NO",
                _gIsInReachability ? @"YES" : @"NO",
                _gWindowScene.touchVisualizerEnabled ? @"YES" : @"NO");
}

static void ReloadPrefs(void) {
    _gWindow.quickPathEnabled = tvzBool(@"useQuickPathEffect");
    _gWindow.morphEnabled = tvzBool(@"useMorphEffect");
    _gWindow.trackingEnabled = tvzBool(@"useTrackingEffect");

    CGFloat alpha = [[TVZUserDefaults standardUserDefaults] doubleForKey:@"alpha"];
    _gTouchConfig.alpha = alpha;
    _gRippleConfig.alpha = alpha;

    NSString *fillColorString = [[TVZUserDefaults standardUserDefaults] stringForKey:@"fillColorString"];
    if (fillColorString) {
        UIColor *fillColor = [UIColor tvz_colorWithRGBAString:fillColorString];
        if (fillColor) {
            _gTouchConfig.fillColor = fillColor;
            _gRippleConfig.fillColor = _gWindow.trackingEnabled ? fillColor : [UIColor clearColor];
        }
    }

    NSString *borderColorString = [[TVZUserDefaults standardUserDefaults] stringForKey:@"borderColorString"];
    if (borderColorString) {
        UIColor *strokeColor = [UIColor tvz_colorWithRGBAString:borderColorString];
        if (strokeColor) {
            _gTouchConfig.strokeColor = strokeColor;
            _gRippleConfig.strokeColor = _gWindow.trackingEnabled ? strokeColor : [UIColor clearColor];
        }
    }

    NSString *quickPathFillColorString =
        [[TVZUserDefaults standardUserDefaults] stringForKey:@"quickPathFillColorString"];
    if (quickPathFillColorString) {
        UIColor *quickPathFillColor = [UIColor tvz_colorWithRGBAString:quickPathFillColorString extraAlpha:alpha];
        if (quickPathFillColor) {
            _gWindow.quickPathFillColor = quickPathFillColor;
        }
    }

    NSString *trackingFillColorString =
        [[TVZUserDefaults standardUserDefaults] stringForKey:@"trackingFillColorString"];
    if (trackingFillColorString) {
        UIColor *trackingFillColor = [UIColor tvz_colorWithRGBAString:trackingFillColorString];
        if (trackingFillColor) {
            _gRippleConfig.fillColor = trackingFillColor;
        }
    }

    NSString *trackingBorderColorString =
        [[TVZUserDefaults standardUserDefaults] stringForKey:@"trackingBorderColorString"];
    if (trackingBorderColorString) {
        UIColor *trackingStrokeColor = [UIColor tvz_colorWithRGBAString:trackingBorderColorString];
        if (trackingStrokeColor) {
            _gRippleConfig.strokeColor = trackingStrokeColor;
        }
    }

    BOOL useImageEffect = tvzBool(@"useImageEffect");
    UIImage *fillImage = nil;
    if (useImageEffect) {
        NSString *imageFillName = [[TVZUserDefaults standardUserDefaults] stringForKey:@"imageFillName"];
        fillImage = [NSBundle tvz_fillImageNamed:imageFillName];
        _gTouchConfig.fillImage = fillImage;
    } else {
        _gTouchConfig.fillImage = nil;
    }
    if (useImageEffect && _gWindow.trackingEnabled) {
        _gRippleConfig.fillImage = fillImage;
    } else {
        _gRippleConfig.fillImage = nil;
    }

    BOOL shouldAutoRotate = tvzBool(@"imageShouldAutoRotate");
    _gTouchConfig.shouldAutoRotate = shouldAutoRotate;
    _gRippleConfig.shouldAutoRotate = shouldAutoRotate;

    NSTimeInterval fadeDuration = [[TVZUserDefaults standardUserDefaults] doubleForKey:@"animationDuration"];
    _gTouchConfig.fadeDuration = fadeDuration;
    _gRippleConfig.fadeDuration = fadeDuration * 0.667;
    _gWindow.quickPathAnimationDuration = fadeDuration;

    CGFloat radius = [[TVZUserDefaults standardUserDefaults] doubleForKey:@"fillSize"] / 2.0;
    _gTouchConfig.radius = radius;
    _gRippleConfig.radius = radius;
    _gWindow.quickPathFillWidth = radius * 0.5;

    CGFloat borderWidth = [[TVZUserDefaults standardUserDefaults] doubleForKey:@"borderWidth"];
    _gTouchConfig.borderWidth = borderWidth;
    _gRippleConfig.borderWidth = borderWidth;

    CGFloat cornerRadius = [[TVZUserDefaults standardUserDefaults] doubleForKey:@"cornerRadius"];
    _gTouchConfig.cornerRadius = cornerRadius;
    _gRippleConfig.cornerRadius = cornerRadius;

    CGFloat liftScale = [[TVZUserDefaults standardUserDefaults] doubleForKey:@"liftScale"];
    _gTouchConfig.liftScale = liftScale;
    _gRippleConfig.liftScale = liftScale;

    _gWindow.touchContactConfig = _gTouchConfig;
    _gWindow.touchRippleConfig = _gRippleConfig;

    _gEnabled = tvzBool(@"isEnabled");
    _gEnabledOnlyWhenRecording = tvzBool(@"isRecordingOnly");

    _gEnableOverride = tvzBool(@"enableOverride");
    _gDisableOverride = tvzBool(@"disableOverride");
    _gDisableOverrideWhenRecording = tvzBool(@"disableOverrideWhenRecording");

    ReloadStats();
}

__attribute__((visibility("hidden")))
@interface TVZReachabilityObserver : NSObject <SBReachabilityObserver>
@end

@implementation TVZReachabilityObserver

- (void)handleWillBeginReachabilityAnimation {
    ReloadStats();
}

- (void)handleDidEndReachabilityAnimation {
    ReloadStats();
}

@end

@interface UIWindowScene (TouchViz)
- (void)touchviz_reload;
- (void)touchviz_setup;
@end

%group TVZSpringBoard

struct BlockDescriptor {
    unsigned long reserved;
    unsigned long size;
    void *rest[1];
};

struct Block {
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    struct BlockDescriptor *descriptor;
};

static NSString *BlockSig(id blockObj)
{
    struct Block *block = (__bridge struct Block *)blockObj;
    struct BlockDescriptor *descriptor = block->descriptor;

    int copyDisposeFlag = 1 << 25;
    int signatureFlag = 1 << 30;

    if (block->flags & signatureFlag) {
        int index = 0;
        if (block->flags & copyDisposeFlag)
            index += 2;

        const char *signature = (const char *)descriptor->rest[index];
        if (signature) {
            return [NSString stringWithUTF8String:signature];
        }
    }

    return nil;
}

%hook RPScreenRecorder

%property (nonatomic, copy) NSString *tvz_inBroadcastingExtensionIdentifier;

- (void)setupSystemBroadcastWithExtension:(NSString *)arg1 handler:(id)arg2 {
    %orig;
    self.tvz_inBroadcastingExtensionIdentifier = arg1;
    HBLogDebug(@"setupSystemBroadcastWithExtension: %@", arg1);
}

- (void)startSystemBroadcastWithHandler:(void (^)(NSError *))arg1 {
    NSString *sig1 = BlockSig(arg1);
    if (![sig1 isEqualToString:@"v16@?0@\"NSError\"8"]) {
        %orig;
        return;
    }
    void (^handler)(NSError *) = ^(NSError *error) {
      _gIsBroadcasting = (!error 
        && self.tvz_inBroadcastingExtensionIdentifier != nil 
        && [[TVZUserDefaults longScreenshotterKeys] containsObject:self.tvz_inBroadcastingExtensionIdentifier]
      );
      ReloadStats();
      if (arg1) {
        arg1(error);
      }
    };
    %orig(handler);
}

%end

%hook RPBroadcastController

%property (nonatomic, copy) NSString *tvz_inBroadcastingExtensionIdentifier;

- (instancetype)initWithExtensionBundleID:(NSString *)arg1 broadcastURL:(id)arg2 {
    RPBroadcastController *result = %orig;
    self.tvz_inBroadcastingExtensionIdentifier = arg1;
    HBLogDebug(@"initWithExtensionBundleID: %@", arg1);
    return result;
}

- (void)startSystemBroadcastWithHandler:(void (^)(NSError *))arg1 {
    NSString *sig1 = BlockSig(arg1);
    if (![sig1 isEqualToString:@"v16@?0@\"NSError\"8"]) {
        %orig;
        return;
    }
    void (^handler)(NSError *) = ^(NSError *error) {
      _gIsBroadcasting = (!error 
        && self.tvz_inBroadcastingExtensionIdentifier != nil 
        && [[TVZUserDefaults longScreenshotterKeys] containsObject:self.tvz_inBroadcastingExtensionIdentifier]
      );
      ReloadStats();
      if (arg1) {
        arg1(error);
      }
    };
    %orig(handler);
}

%end

%hook UIWindowScene

- (void)_delegate_windowDidBecomeVisible:(id)arg1 {
    %orig;

    if (![NSStringFromClass([self class]) hasPrefix:@"SB"]) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      [self touchviz_reload];
    });
}

%new
- (void)touchviz_reload {
    _gWindowScene = self;
    _gWindow = self.touchVisualizerWindow;
    _gTouchConfig = _gWindow.touchContactConfig;
    _gRippleConfig = _gWindow.touchRippleConfig;

    ReloadPrefs();

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      [self touchviz_setup];
    });
}

%new
- (void)touchviz_setup {
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(touchviz_screenCapturedDidChange:)
                                               name:UIScreenCapturedDidChangeNotification
                                             object:nil];

    static TVZReachabilityObserver *_gReachabilityObserver = nil;
    _gReachabilityObserver = [TVZReachabilityObserver new];
    [[%c(SBReachabilityManager) sharedInstance] addObserver:_gReachabilityObserver];

    int _gNotifyToken;
    notify_register_dispatch(TVZ_NOTIFY_NAME, &_gNotifyToken, dispatch_get_main_queue(), ^(int token) {
      ReloadPrefs();
    });
}

%new
- (void)touchviz_screenCapturedDidChange:(NSNotification *)notification {
    ReloadStats();
}

%end

%hook _UISystemGestureWindow

- (void)sendEvent:(UIEvent *)event {
    %orig;

    if (event.type != UIEventTypeTouches) {
        return;
    }

    if (IsEnabled() || [_gWindow hasAnyTouch]) {
        [_gWindow sendTouchEvent:event];
        [_gWindow sendQuickPathEvent:event];
    }
}

%end

%end

%group TVZLegacyHomeButtonTouchStream

%hook __UISystemGestureManager

- (unsigned char)_dispatchModeForExternalGestureCompletion {
    unsigned char dispatchMode = %orig;
    if (dispatchMode == 1 && ShouldKeepSystemGestureTouchStreamSending()) {
        return 2;
    }
    return dispatchMode;
}

%end

%end

%ctor {
    NSString *bid = [NSBundle.mainBundle bundleIdentifier];
    BOOL isSpringBoard = [bid isEqualToString:@"com.apple.springboard"];
    if (isSpringBoard) {
        %init(TVZSpringBoard);
        if (IsRealHomeButtonDevice()) {
            %init(TVZLegacyHomeButtonTouchStream);
        }
    }
}
