#import "NSBundle+TVZPrefs.h"

#import <Foundation/NSFileManager.h>
#import <Foundation/NSString.h>
#import <Foundation/NSUUID.h>
#import <HBLog.h>

#import <libroot.h>

@implementation NSBundle (TouchViz)

+ (NSBundle *)tvz_supportBundle {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      NSString *tweakBundlePath = [[NSBundle mainBundle] pathForResource:@"TVZPrefs"
                                                                  ofType:@"bundle"];
      NSString *aliasBundlePath;
      aliasBundlePath = JBROOT_PATH_NSSTRING(@"/Library/PreferenceBundles/TVZPrefs.bundle");
      bundle = [NSBundle bundleWithPath:tweakBundlePath ?: aliasBundlePath];
#if TARGET_IPHONE_SIMULATOR
      if (!bundle) {
          aliasBundlePath = @"/opt/simject/PreferenceBundles/TVZPrefs.bundle";
          bundle = [NSBundle bundleWithPath:aliasBundlePath];
      }
#endif
      NSLog(@"[TouchViz] Support bundle path: %@", [bundle bundlePath]);
    });
    return bundle;
}

+ (NSString *)tvz_packageVersion {
    return @PACKAGE_VERSION;
}

+ (NSString *)tvz_fillImageRoot {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      path = JBROOT_PATH_NSSTRING(@"/var/mobile/Library/Touch-Viz");
#if DEBUG
      HBLogWarn(@"[Touch-Viz] Fill image root: %@", path);
#endif
    });
    return path;
}

+ (BOOL)tvz_ensureFillImageRoot {
    return [[NSFileManager defaultManager] createDirectoryAtPath:[self tvz_fillImageRoot]
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil];
}

+ (UIImage *)tvz_defaultFillImage {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      image = [UIImage imageNamed:@"default"
                       inBundle:[self tvz_supportBundle]
  compatibleWithTraitCollection:nil];
    });
    return image;
}

+ (UIImage *)tvz_fillImageNamed:(NSString *)name {
    if (!name || [name isEqualToString:@"default.png"]) {
        return [self tvz_defaultFillImage];
    }
    static NSTimeInterval gLastModified = 0;
    static UIImage *gFillImage = nil;
    NSString *imagePath = [[self tvz_fillImageRoot] stringByAppendingPathComponent:name];
    if (gFillImage) {
        NSDictionary *imageAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:imagePath error:nil];
        if (imageAttrs) {
            NSTimeInterval imageModified = [imageAttrs[NSFileModificationDate] timeIntervalSince1970];
            if (imageModified > gLastModified) {
                gLastModified = imageModified;
            } else {
                return gFillImage;
            }
        }
    }
    gFillImage = [UIImage imageWithContentsOfFile:imagePath];
    return gFillImage ?: [self tvz_defaultFillImage];
}

+ (NSString *)tvz_saveFillImageWithPath:(NSString *)path {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *imageExt = [path pathExtension];
    NSString *imageName = [NSString stringWithFormat:@"%@.%@", [[NSUUID UUID] UUIDString], imageExt];
    [self tvz_ensureFillImageRoot];
    NSString *imagePath = [[self tvz_fillImageRoot] stringByAppendingPathComponent:imageName];
    [fileManager removeItemAtPath:imagePath error:nil];
    BOOL copied = [fileManager copyItemAtPath:path toPath:imagePath error:nil];
    [fileManager setAttributes:@{NSFileModificationDate : [NSDate date]} ofItemAtPath:imagePath error:nil];
    return copied ? imageName : nil;
}

+ (NSString *)tvz_saveFillImageWithImage:(UIImage *)image {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *imageName = [NSString stringWithFormat:@"%@.png", [[NSUUID UUID] UUIDString]];
    [self tvz_ensureFillImageRoot];
    NSString *imagePath = [[self tvz_fillImageRoot] stringByAppendingPathComponent:imageName];
    [fileManager removeItemAtPath:imagePath error:nil];
    BOOL wrote = [UIImagePNGRepresentation(image) writeToFile:imagePath atomically:YES];
    [fileManager setAttributes:@{NSFileModificationDate : [NSDate date]} ofItemAtPath:imagePath error:nil];
    return wrote ? imageName : nil;
}

+ (BOOL)tvz_removeAllFillImages {
    [[NSFileManager defaultManager] removeItemAtPath:[self tvz_fillImageRoot] error:nil];
    return [self tvz_ensureFillImageRoot];
}

@end
