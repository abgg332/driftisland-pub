#import "TVZUserDefaults.h"

#import <notify.h>

static NSString *const kDefaultsSuiteName = @"com.82flex.touchviz";

@implementation TVZUserDefaults {
    NSInteger _updateCount;
}

+ (TVZUserDefaults *)standardUserDefaults {
    static dispatch_once_t onceToken;
    static TVZUserDefaults *defaults = nil;
    dispatch_once(&onceToken, ^{
      defaults = [[self alloc] initWithSuiteName:kDefaultsSuiteName];
      defaults->_updateCount = 0;
      [defaults registerDefaults];
    });
    return defaults;
}

- (void)registerDefaults {
    [self registerDefaults:@{
        @"isEnabled" : @NO,
        @"isRecordingOnly" : @NO,

        @"fillColorString" : @"235,59,90,0.5",
        @"borderColorString" : @"235,59,90",

        @"alpha" : @0.5,
        @"fillSize" : @40.0,
        @"borderWidth" : @3.0,
        @"cornerRadius" : @30.0,
        @"animationDuration" : @0.3,
        @"liftScale" : @2.0,

        @"useQuickPathEffect" : @NO,
        @"quickPathFillColorString" : @"235,59,90,0.5",

        @"useMorphEffect" : @NO,
        @"useTrackingEffect" : @YES,
        @"trackingFillColorString" : @"235,59,90,0.2",
        @"trackingBorderColorString" : @"235,59,90,0.4",

        @"useImageEffect" : @NO,
        @"imageShouldAutoRotate" : @NO,
        @"imageFillName" : @"default.png",

        @"enableOverride" : @NO,
        @"disableOverride" : @NO,
        @"disableOverrideWhenRecording" : @NO,
    }];
}

- (void)beginUpdates {
    _updateCount++;
}

- (void)endUpdates {
    if (_updateCount > 0) {
        _updateCount--;
    }
    if (_updateCount == 0) {
        [self darwinNotify];
    }
}

- (void)setObject:(id)value forKey:(NSString *)key {
    [self beginUpdates];
    [super setObject:value forKey:key];
    if ([key isEqualToString:@"isEnabled"] || [key isEqualToString:@"isRecordingOnly"]) {
        [super setObject:@NO forKey:@"enableOverride"];
        [super setObject:@NO forKey:@"disableOverride"];
        [super setObject:@NO forKey:@"disableOverrideWhenRecording"];
    }
    [self endUpdates];
}

- (void)resetToDefaultValues {
    [self beginUpdates];
    for (NSString *key in self.dictionaryRepresentation.allKeys) {
        if ([key hasPrefix:@"_"]) {
            continue;
        }
        [self removeObjectForKey:key];
    }
    [self endUpdates];
}

- (void)darwinNotify {
    notify_post(TVZ_NOTIFY_NAME);
}

+ (NSSet<NSString *> *)longScreenshotterKeys {
    static NSSet<NSString *> *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      keys = [NSSet setWithArray:@[
        @"com.sugarmo.ScrollClip.ScreenRecording",
        @"com.xcvzaq.imagejoin.ScrollRecord",
        @"com.abighead.stiiitch.Scrollshot",
        @"yang6wolf.Stitch.Recorder",
        @"com.wysdev.zeta.screenrecording",
        @"com.doukan.webscreenshot.stitch",
        @"com.tailor.screenshot.picsew.TailorBroadcastUploadExtension",
        @"com.zsp.scrolling.screenshots.extension",
        @"com.mind.stitch.ScrollRecorder",
        @"com.gendago.scroll-screenshot.-----",
        @"com.fan.scrollrecord.uploader",
        @"com.keyi.changjietu.luzhi",
      ]];
    });
    return keys;
}

@end
