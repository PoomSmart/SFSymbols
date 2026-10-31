#define CHECK_TARGET
#import "GlyphSupport.h"
#import <Foundation/NSBundle.h>
#import <HBLog.h>
#import <PSHeader/iOSVersions.h>
#import <PSHeader/PS.h>
#import <objc/runtime.h>

static NSMutableArray <NSString *> *allPublicSymbols;
static NSMutableArray <NSString *> *allPrivateSymbols;

static NSBundle *bundleAtSupportPath(NSString *name) {
    NSString *path = PS_ROOT_PATH_NS(([@"/Library/Application Support/SFSymbols/" stringByAppendingString:name]));
    return [NSBundle bundleWithPath:path];
}

static NSBundle *publicBundle() {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundle = bundleAtSupportPath(@"CoreGlyphs.bundle");
    });
    return bundle;
}

static NSBundle *privateBundle() {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundle = bundleAtSupportPath(@"CoreGlyphsPrivate.bundle");
    });
    return bundle;
}

static NSBundle *priorityBundle() {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundle = bundleAtSupportPath(@"CoreGlyphsPriority.bundle");
    });
    return bundle;
}

static SFSSymbolAssetInfo *fillMissingAssetInfo(SFSSymbolAssetInfo *info, NSString *name, BOOL allowsPrivate) {
    if (info != nil)
        return info;
    if ([allPublicSymbols containsObject:name])
        return [[%c(SFSSymbolAssetInfo) alloc] initWithName:name bundle:publicBundle() andType:0];
    if (allowsPrivate && [allPrivateSymbols containsObject:name])
        return [[%c(SFSSymbolAssetInfo) alloc] initWithName:name bundle:privateBundle() andType:1];
    return info;
}

%hook NSBundle

+ (NSBundle *)bundleWithPath:(NSString *)path {
    NSBundle *bundle = nil;
    if ([path hasSuffix:@"/CoreGlyphs.bundle"])
        bundle = publicBundle();
    else if ([path hasSuffix:@"/CoreGlyphsPrivate.bundle"])
        bundle = privateBundle();
    else if ([path hasSuffix:@"/CoreGlyphsPriority.bundle"])
        bundle = priorityBundle();
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

%group priorityBundleHook

%hook SFSCoreGlyphsBundle

+ (NSBundle *)priority {
    NSBundle *bundle = priorityBundle();
    return bundle ?: %orig;
}

%end

%end

static UIImage *SFSImageOrDrawn(NSString *name, UIImage *image) {
    if (image || name.length == 0)
        return image;
    return SFSMonochromeSymbolImage(publicBundle(), name) ?: SFSMonochromeSymbolImage(privateBundle(), name);
}

%group CompositeLayers

%hook UIImage

// Safari's toolbar asks for these names with a symbol configuration. iOS 14's
// CoreGlyphs lookup returns nil when that configuration misses, and the button
// then shows its accessibility title.
+ (UIImage *)systemImageNamed:(NSString *)name {
    UIImage *image = %orig;
    return SFSImageOrDrawn(name, image);
}

+ (UIImage *)systemImageNamed:(NSString *)name withConfiguration:(UIImageConfiguration *)configuration {
    UIImage *image = %orig;
    return SFSImageOrDrawn(name, image);
}

// A layer whose image has no content is inserted with addObject: and throws.
+ (UIImage *)_generateCompositedSymbolImageForAsset:(UIImageAsset *)asset usingLayers:(NSArray *)layers configuration:(UIImageConfiguration *)configuration alignUsingBaselines:(BOOL)align {
    static __thread int depth;
    if (depth > 3)
        return nil;
    if (layers.count == 0)
        return %orig;

    NSMutableArray *usable = [NSMutableArray arrayWithCapacity:layers.count];
    depth++;
    for (_UIImageSymbolLayer *layer in layers) {
        UIImage *image = [[layer asset] imageWithConfiguration:configuration];
        if ([image content])
            [usable addObject:layer];
    }
    depth--;
    if (usable.count == 0)
        return SFSMonochromeSymbolImage(publicBundle(), [asset assetName]) ?: SFSMonochromeSymbolImage(privateBundle(), [asset assetName]);
    if (usable.count == layers.count)
        return %orig;
    return %orig(asset, usable, configuration, align);
}

%end

%end

%hook SFSSymbolAssetInfo

+ (SFSSymbolAssetInfo *)localeAgnosticInfo:(NSString *)name allowsPrivate:(BOOL)allowsPrivate {
    SFSSymbolAssetInfo *info = %orig;
    return fillMissingAssetInfo(info, name, allowsPrivate);
}

+ (SFSSymbolAssetInfo *)infoForName:(NSString *)name allowsPrivate:(BOOL)allowsPrivate {
    SFSSymbolAssetInfo *info = %orig;
    return fillMissingAssetInfo(info, name, allowsPrivate);
}

%end

%ctor {
    if (!isTarget(TargetTypeApps | TargetTypeGenericExtensions)) return;
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
    if (!IS_IOS_OR_NEWER(iOS_16_0))
        SFSInitCARCompat();
    if (!IS_IOS_OR_NEWER(iOS_15_0))
        %init(CompositeLayers);
    Class bundleClass = %c(SFSCoreGlyphsBundle);
    if (bundleClass && class_getClassMethod(bundleClass, @selector(priority)))
        %init(priorityBundleHook);
}
