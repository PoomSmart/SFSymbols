#define CHECK_TARGET
#import <Foundation/NSBundle.h>
#import <PSHeader/PS.h>
#import <UIKit/UIImage.h>
#import <version.h>

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