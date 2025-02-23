#define CHECK_TARGET
#import <Foundation/NSBundle.h>
#import <PSHeader/iOSVersions.h>
#import <PSHeader/PS.h>
#import <UIKit/UIImage.h>
#import <UIKit/UIImageSymbolConfiguration.h>

@interface SFSSymbolAssetInfo : NSObject
- (instancetype)initWithName:(NSString *)name bundle:(NSBundle *)bundle andType:(NSInteger)type;
@end

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

static NSMutableArray <NSString *> *allPublicSymbols;
static NSMutableArray <NSString *> *allPrivateSymbols;

static NSBundle *publicBundle() {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = PS_ROOT_PATH_NS(@"/Library/Application Support/SFSymbols/CoreGlyphs.bundle");
        bundle = [NSBundle bundleWithPath:path];
    });
    return bundle;
}

static NSBundle *privateBundle() {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = PS_ROOT_PATH_NS(@"/Library/Application Support/SFSymbols/CoreGlyphsPrivate.bundle");
        bundle = [NSBundle bundleWithPath:path];
    });
    return bundle;
}

%hook NSBundle

+ (NSBundle *)bundleWithPath:(NSString *)path {
    NSBundle *bundle = nil;
    if ([path isEqualToString:@"/System/Library/CoreServices/CoreGlyphs.bundle"])
        bundle = publicBundle();
    else if ([path isEqualToString:@"/System/Library/CoreServices/CoreGlyphsPrivate.bundle"])
        bundle = privateBundle();
    return bundle ?: %orig;
}

%end

%hook SFSCoreGlyphsBundle

+ (NSBundle *)public {
    NSBundle *bundle = publicBundle();
    return bundle ?: %orig;
}

+ (NSBundle *)private {
    NSBundle *bundle = privateBundle();
    return bundle ?: %orig;
}

%end

%hook SFSSymbolAssetInfo

+ (SFSSymbolAssetInfo *)localeAgnosticInfo:(NSString *)name allowsPrivate:(BOOL)allowsPrivate {
    SFSSymbolAssetInfo *info = %orig;
    if (info == nil) {
        if ([allPublicSymbols containsObject:name])
            info = [[%c(SFSSymbolAssetInfo) alloc] initWithName:name bundle:publicBundle() andType:0];
        if (allowsPrivate && [allPrivateSymbols containsObject:name])
            info = [[%c(SFSSymbolAssetInfo) alloc] initWithName:name bundle:privateBundle() andType:1];
    }
    return info;
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
        NSBundle *public = publicBundle();
        if (public) {
            NSDictionary *aliasDict = [NSDictionary dictionaryWithContentsOfFile:[public pathForResource:@"name_aliases" ofType:@"strings"]];
            NSArray *symbolArray = [NSArray arrayWithContentsOfFile:[public pathForResource:@"symbol_order" ofType:@"plist"]];
            allPublicSymbols = aliasDict.allKeys.mutableCopy;
            [allPublicSymbols addObjectsFromArray:symbolArray];
        }
        NSBundle *private = privateBundle();
        if (private) {
            NSDictionary *aliasDict = [NSDictionary dictionaryWithContentsOfFile:[private pathForResource:@"name_aliases" ofType:@"strings"]];
            NSArray *symbolArray = [NSArray arrayWithContentsOfFile:[private pathForResource:@"symbol_order" ofType:@"plist"]];
            allPrivateSymbols = aliasDict.allKeys.mutableCopy;
            [allPrivateSymbols addObjectsFromArray:symbolArray];
        }
        %init;
        if (!IS_IOS_OR_NEWER(iOS_15_0)) {
            %init(preiOS15);
        }
    }
}