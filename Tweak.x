#define CHECK_TARGET
#import <Foundation/NSBundle.h>
#import <PSHeader/iOSVersions.h>
#import <PSHeader/PS.h>
#import <UIKit/UIImage.h>
#import <UIKit/UIImageSymbolConfiguration.h>

@interface UIColor (Private)
+ (instancetype)tintColor;
@end

@interface UIImage (Private)
- (NSUInteger)_numberOfHierarchyLayers;
@end

@interface UIImageSymbolConfiguration (Compat)
+ (instancetype)configurationWithPaletteColors:(NSArray <UIColor *> *)colors;
@end

@interface UIImageSymbolConfiguration (Private)
- (NSArray <UIColor *> *)_colors;
@end

%hook NSBundle

+ (NSBundle *)bundleWithPath:(NSString *)path {
    NSString *origPath = path;
    if ([path isEqualToString:@"/System/Library/CoreServices/CoreGlyphs.bundle"])
        path = PS_ROOT_PATH_NS(@"/Library/Application Support/SFSymbols/CoreGlyphs.bundle");
    else if ([path isEqualToString:@"/System/Library/CoreServices/CoreGlyphsPrivate.bundle"])
        path = PS_ROOT_PATH_NS(@"/Library/Application Support/SFSymbols/CoreGlyphsPrivate.bundle");
    NSBundle *bundle = %orig(path);
    return bundle ?: %orig(origPath);
}

%end

%hook SFSCoreGlyphsBundle

+ (NSBundle *)public {
    NSString *path = PS_ROOT_PATH_NS(@"/Library/Application Support/SFSymbols/CoreGlyphs.bundle");
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    return bundle ?: %orig;
}

+ (NSBundle *)private {
    NSString *path = PS_ROOT_PATH_NS(@"/Library/Application Support/SFSymbols/CoreGlyphsPrivate.bundle");
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    return bundle ?: %orig;
}

%end

%hook UIImage

+ (UIImage *)systemImageNamed:(NSString *)name withConfiguration:(UIImageConfiguration *)configuration {
    UIImage *image = %orig;
    if (IS_IOS_BETWEEN_EEX(iOS_15_0, iOS_16_0) && [configuration isKindOfClass:UIImageSymbolConfiguration.class] && [(UIImageSymbolConfiguration *)configuration _colors].count == 0) {
        NSUInteger layerCount = [image _numberOfHierarchyLayers];
        NSMutableArray <UIColor *> *colors = [NSMutableArray arrayWithCapacity:layerCount];
        for (NSUInteger i = 0; i < layerCount; i++)
            [colors addObject:UIColor.tintColor];
        configuration = [configuration configurationByApplyingConfiguration:[UIImageSymbolConfiguration configurationWithPaletteColors:colors]];
        image = [image imageWithConfiguration:configuration];
    }
    return image;
}

%end

%group preiOS15

%hook UITableConstants_IOS

- (UIImage *)defaultDeleteImageWithTintColor:(UIColor *)tintColor backgroundColor:(UIColor *)backgroundColor {
    UIImage *image = [UIImage systemImageNamed:@"minus.circle.fill"];
    if (tintColor)
        image = [image imageWithTintColor:tintColor];
    return image;
}

%end

%end

%ctor {
    if (isTarget(TargetTypeApps | TargetTypeGenericExtensions)) {
        %init;
        if (!IS_IOS_OR_NEWER(iOS_15_0)) {
            %init(preiOS15);
        }
    }
}