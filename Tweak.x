#define CHECK_TARGET
#import "GlyphSupport.h"
#import <Foundation/NSBundle.h>
#import <HBLog.h>
#import <PSHeader/iOSVersions.h>
#import <PSHeader/PS.h>
#import <UIKit/UIImage.h>
#import <objc/runtime.h>

@interface SFSSymbolAssetInfo : NSObject
- (instancetype)initWithName:(NSString *)name bundle:(NSBundle *)bundle andType:(NSInteger)type;
@end

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
    Class bundleClass = %c(SFSCoreGlyphsBundle);
    if (bundleClass && class_getClassMethod(bundleClass, @selector(priority)))
        %init(priorityBundleHook);
}
