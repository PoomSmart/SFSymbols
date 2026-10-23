#import "GlyphSupport.h"
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIScreen.h>
#import <dlfcn.h>
#import <objc/runtime.h>

typedef struct CGSVGDocument *CGSVGDocumentRef;
typedef struct CGSVGNode *CGSVGNodeRef;
typedef struct CGSVGAttribute *CGSVGAttributeRef;
typedef struct CGSVGAttributeMap *CGSVGAttributeMapRef;

typedef CGSVGNodeRef (*SFSGetRootFn)(CGSVGDocumentRef);
typedef void (*SFSEnumerateFn)(CGSVGNodeRef, void *);
typedef unsigned (*SFSGetTypeFn)(CGSVGNodeRef);
typedef void *(*SFSShapePathFn)(CGSVGNodeRef);
typedef CGPathRef (*SFSCreatePathFn)(void *);
typedef CGSVGAttributeRef (*SFSFindAttributeFn)(CGSVGNodeRef, uint32_t);
typedef CFStringRef (*SFSCopyStringFn)(CGSVGAttributeRef);
typedef CGSVGAttributeMapRef (*SFSNamedStyleFn)(CGSVGDocumentRef, CFStringRef);
typedef CGSVGAttributeRef (*SFSMapGetFn)(CGSVGAttributeMapRef, uintptr_t);
typedef Boolean (*SFSGetFloatFn)(CGSVGAttributeRef, double *);
typedef uintptr_t (*SFSAtomFn)(CFStringRef);
typedef CGAffineTransform (*SFSNodeTransformFn)(CGSVGNodeRef);
typedef Boolean (*SFSBoolAttributeFn)(CGSVGAttributeRef);
typedef void (*SFSDocumentWriteFn)(CGSVGDocumentRef, CFMutableDataRef, CFDictionaryRef);

static SFSGetRootFn SFSGetRoot;
static SFSEnumerateFn SFSEnumerate;
static SFSGetTypeFn SFSGetType;
static SFSShapePathFn SFSShapePath;
static SFSCreatePathFn SFSCreatePath;
static SFSFindAttributeFn SFSFindAttribute;
static SFSCopyStringFn SFSCopyString;
static SFSNamedStyleFn SFSNamedStyle;
static SFSMapGetFn SFSMapGet;
static SFSGetFloatFn SFSGetFloat;
static SFSAtomFn SFSAtomFromString;
static SFSNodeTransformFn SFSNodeTransform;
static SFSBoolAttributeFn SFSBoolAttribute;
static SFSDocumentWriteFn SFSDocumentWrite;
static uintptr_t SFSClearBehindAtom;

static void SFSLoadSVG(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *svg = dlopen("/System/Library/PrivateFrameworks/CoreSVG.framework/CoreSVG", RTLD_LAZY);
        void *ui = dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_LAZY);
        if (!svg)
            return;
        SFSGetRoot = dlsym(svg, "CGSVGDocumentGetRootNode");
        SFSEnumerate = dlsym(svg, "CGSVGNodeEnumerate");
        SFSGetType = dlsym(svg, "CGSVGNodeGetType");
        SFSShapePath = dlsym(svg, "CGSVGShapeNodeGetPath");
        SFSCreatePath = dlsym(svg, "CGSVGPathCreateCGPath");
        SFSFindAttribute = dlsym(svg, "CGSVGNodeFindAttribute");
        SFSCopyString = dlsym(svg, "CGSVGAttributeCopyString");
        SFSNamedStyle = dlsym(svg, "CGSVGDocumentGetNamedStyle");
        SFSMapGet = dlsym(svg, "CGSVGAttributeMapGetAttribute");
        SFSGetFloat = dlsym(svg, "CGSVGAttributeGetFloat");
        SFSAtomFromString = dlsym(svg, "CGSVGAtomFromString");
        SFSDocumentWrite = dlsym(svg, "CGSVGDocumentWriteToData");
        if (ui) {
            SFSNodeTransform = dlsym(ui, "CUISVGNodeGetTransform");
            SFSBoolAttribute = dlsym(ui, "CUISVGAttributeGetBoolean");
        }
        if (SFSAtomFromString)
            SFSClearBehindAtom = SFSAtomFromString(CFSTR("-sfsymbols-clear-behind"));
    });
}

static CGAffineTransform SFSDocumentTransform(CGSVGDocumentRef document) {
    if (!SFSDocumentWrite)
        return CGAffineTransformIdentity;
    NSMutableData *data = [NSMutableData data];
    SFSDocumentWrite(document, (__bridge CFMutableDataRef)data, NULL);
    NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!xml)
        return CGAffineTransformIdentity;
    NSRegularExpression *matrix = [NSRegularExpression regularExpressionWithPattern:@"transform=\"matrix\\(([^)]*)\\)\"" options:0 error:nil];
    NSTextCheckingResult *match = [matrix firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
    if (!match)
        return CGAffineTransformIdentity;
    NSArray<NSString *> *parts = [[xml substringWithRange:[match rangeAtIndex:1]] componentsSeparatedByString:@" "];
    if (parts.count != 6)
        return CGAffineTransformIdentity;
    return CGAffineTransformMake(parts[0].doubleValue, parts[1].doubleValue, parts[2].doubleValue, parts[3].doubleValue, parts[4].doubleValue, parts[5].doubleValue);
}

// iOS 15 monochrome fills every shape as one path, so an opacity-0 knockout
// punches a hole through the glyph. Later systems draw each monochrome-N
// class on its own and copy-erase clear-behind layers first.
static BOOL SFSDrawMonochromeLayers(CGContextRef context, CGSVGDocumentRef document, CGColorRef fillColor, BOOL alreadyScaled, CGFloat scale, CGSize targetSize, CGSize canvas) {
    if (!context || !document || !SFSGetRoot || !SFSEnumerate || !SFSGetType || !SFSShapePath || !SFSCreatePath || !SFSFindAttribute || !SFSGetFloat)
        return NO;
    if (canvas.width <= 0 || canvas.height <= 0) {
        if (!SFSDocumentWrite)
            return NO;
        NSMutableData *data = [NSMutableData data];
        SFSDocumentWrite(document, (__bridge CFMutableDataRef)data, NULL);
        NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSRegularExpression *box = [NSRegularExpression regularExpressionWithPattern:@"viewBox=\"[0-9eE.+-]+\\s+[0-9eE.+-]+\\s+([0-9eE.+-]+)\\s+([0-9eE.+-]+)\"" options:0 error:nil];
        NSTextCheckingResult *match = xml ? [box firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)] : nil;
        if (!match)
            return NO;
        canvas = CGSizeMake([[xml substringWithRange:[match rangeAtIndex:1]] doubleValue], [[xml substringWithRange:[match rangeAtIndex:2]] doubleValue]);
    }
    if (canvas.width <= 0 || canvas.height <= 0)
        return NO;

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    CGAffineTransform documentTransform = SFSNodeTransform ? CGAffineTransformIdentity : SFSDocumentTransform(document);
    void (^visit)(CGSVGNodeRef, int, BOOL *) = ^(CGSVGNodeRef node, int action, BOOL *stop) {
        (void)stop;
        if (action != 0 || SFSGetType(node) != 2)
            return;
        void *shape = SFSShapePath(node);
        if (!shape)
            return;
        CGPathRef raw = SFSCreatePath(shape);
        if (!raw)
            return;
        CGAffineTransform xform = SFSNodeTransform ? SFSNodeTransform(node) : documentTransform;
        CGPathRef path = CGPathCreateCopyByTransformingPath(raw, &xform);
        CGPathRelease(raw);
        if (!path)
            return;
        CGSVGAttributeRef klass = SFSCopyString ? SFSFindAttribute(node, 4) : NULL;
        CFStringRef text = klass ? SFSCopyString(klass) : NULL;
        NSString *classString = text ? (__bridge_transfer NSString *)text : nil;
        for (NSString *token in [classString componentsSeparatedByString:@" "]) {
            if (![token hasPrefix:@"monochrome-"] || [token containsString:@":"])
                continue;
            NSMutableDictionary *group = groups[token];
            if (!group) {
                double opacity = 1;
                BOOL clear = NO;
                CGSVGAttributeMapRef style = SFSNamedStyle && SFSMapGet ? SFSNamedStyle(document, (__bridge CFStringRef)[@"." stringByAppendingString:token]) : NULL;
                if (style) {
                    double value = 1;
                    CGSVGAttributeRef opacityAttribute = SFSMapGet(style, 41);
                    if (opacityAttribute && SFSGetFloat(opacityAttribute, &value))
                        opacity = value;
                    CGSVGAttributeRef clearAttribute = SFSMapGet(style, SFSClearBehindAtom);
                    if (clearAttribute)
                        clear = SFSBoolAttribute ? SFSBoolAttribute(clearAttribute) : YES;
                }
                group = [NSMutableDictionary dictionary];
                group[@"opacity"] = @(opacity);
                group[@"clear"] = @(clear);
                group[@"path"] = (__bridge_transfer id)CGPathCreateMutable();
                groups[token] = group;
                [names addObject:token];
            }
            CGPathAddPath((__bridge CGMutablePathRef)group[@"path"], NULL, path);
        }
        CGPathRelease(path);
    };
    SFSEnumerate(SFSGetRoot(document), (__bridge void *)visit);
    if (names.count == 0)
        return NO;

    if (!fillColor) {
        static CGColorRef black;
        static dispatch_once_t blackOnce;
        dispatch_once(&blackOnce, ^{
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            const CGFloat components[4] = {0, 0, 0, 1};
            black = CGColorCreate(space, components);
            CGColorSpaceRelease(space);
        });
        fillColor = black;
    }

    [names sortUsingComparator:^NSComparisonResult(NSString *lhs, NSString *rhs) {
        return [lhs compare:rhs options:NSNumericSearch];
    }];
    // referenceCanvasSize can be the layout box. The paths only occupy the
    // smaller ink rect inside it, which otherwise stays pinned to the top left.
    CGRect ink = CGRectNull;
    for (NSString *name in names) {
        CGRect bounds = CGPathGetPathBoundingBox((__bridge CGPathRef)groups[name][@"path"]);
        if (CGRectIsNull(bounds) || CGRectIsEmpty(bounds) || !isfinite(bounds.size.width) || !isfinite(bounds.size.height))
            continue;
        ink = CGRectIsNull(ink) ? bounds : CGRectUnion(ink, bounds);
    }
    if (!(ink.size.width > 0 && ink.size.height > 0 && ink.size.width <= canvas.width * 1.05 && ink.size.height <= canvas.height * 1.05))
        ink = CGRectMake(0, 0, canvas.width, canvas.height);
    CGSize dest = alreadyScaled ? canvas : CGSizeMake(targetSize.width * scale, targetSize.height * scale);
    CGContextSaveGState(context);
    CGContextScaleCTM(context, dest.width / ink.size.width, dest.height / ink.size.height);
    CGContextScaleCTM(context, 1, -1);
    CGContextTranslateCTM(context, -ink.origin.x, -(ink.origin.y + ink.size.height));
    for (NSString *name in names) {
        NSDictionary *group = groups[name];
        CGContextSaveGState(context);
        CGContextSetBlendMode(context, [group[@"clear"] boolValue] ? kCGBlendModeCopy : kCGBlendModeNormal);
        CGColorRef color = CGColorCreateCopyWithAlpha(fillColor, [group[@"opacity"] doubleValue] * CGColorGetAlpha(fillColor));
        CGContextSetFillColorWithColor(context, color);
        CGContextAddPath(context, (__bridge CGPathRef)group[@"path"]);
        CGContextFillPath(context);
        CGColorRelease(color);
        CGContextRestoreGState(context);
    }
    CGContextRestoreGState(context);
    return YES;
}

@interface CUIThemeRendition : NSObject
- (CGSVGDocumentRef)svgDocument;
@end

@interface CUINamedVectorGlyph : NSObject
- (CUIThemeRendition *)_rendition;
- (CGSize)referenceCanvasSize;
- (CGFloat)scale;
- (CGFloat)_requestedPointSizeRatio;
@end

@interface _UIImageCUIVectorGlyphContent : NSObject
- (CUINamedVectorGlyph *)vectorGlyph;
- (CGFloat)vectorScale;
- (CGFloat)scale;
- (CGSize)sizeInPixels;
@end

static CGSVGDocumentRef SFSGlyphDocument(CUINamedVectorGlyph *glyph) {
    CUIThemeRendition *rendition = [glyph _rendition];
    if (!rendition)
        return NULL;
    return [rendition svgDocument];
}

static CGSize SFSDocumentCanvas(CGSVGDocumentRef document) {
    if (!document || !SFSDocumentWrite)
        return CGSizeZero;
    NSMutableData *data = [NSMutableData data];
    SFSDocumentWrite(document, (__bridge CFMutableDataRef)data, NULL);
    NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSRegularExpression *box = [NSRegularExpression regularExpressionWithPattern:@"viewBox=\"[0-9eE.+-]+\\s+[0-9eE.+-]+\\s+([0-9eE.+-]+)\\s+([0-9eE.+-]+)\"" options:0 error:nil];
    NSTextCheckingResult *match = xml ? [box firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)] : nil;
    if (!match)
        return CGSizeZero;
    return CGSizeMake([[xml substringWithRange:[match rangeAtIndex:1]] doubleValue], [[xml substringWithRange:[match rangeAtIndex:2]] doubleValue]);
}

static CGSize SFSGlyphCanvas(CUINamedVectorGlyph *glyph) {
    if ([glyph respondsToSelector:@selector(referenceCanvasSize)]) {
        CGSize canvas = [glyph referenceCanvasSize];
        if (canvas.width > 0 && canvas.height > 0)
            return canvas;
    }
    return SFSDocumentCanvas(SFSGlyphDocument(glyph));
}

static CGFloat SFSGlyphScale(CUINamedVectorGlyph *glyph) {
    CGFloat scale = 0;
    if ([glyph respondsToSelector:@selector(scale)])
        scale = [glyph scale];
    if ([glyph respondsToSelector:@selector(_requestedPointSizeRatio)]) {
        CGFloat ratio = [glyph _requestedPointSizeRatio];
        if (ratio > 0)
            scale = (scale > 0 ? scale : 1) * ratio;
    }
    if (scale > 0)
        return scale;
    scale = [UIScreen mainScreen].scale;
    return scale > 0 ? scale : 1;
}

static CGImageRef SFSMonochromeImage(CUINamedVectorGlyph *glyph, CGFloat scale, CGSize target) {
    if (!glyph || scale <= 0 || target.width <= 0 || target.height <= 0)
        return NULL;
    CGSVGDocumentRef document = SFSGlyphDocument(glyph);
    if (!document)
        return NULL;
    CGSize canvas = SFSGlyphCanvas(glyph);
    size_t width = (size_t)ceil(target.width * scale);
    size_t height = (size_t)ceil(target.height * scale);
    if (!width || !height)
        return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!context)
        return NULL;
    BOOL drew = SFSDrawMonochromeLayers(context, document, NULL, NO, scale, target, canvas);
    CGImageRef image = drew ? CGBitmapContextCreateImage(context) : NULL;
    CGContextRelease(context);
    return image;
}

@interface SFSCachedImage : NSObject
@property (nonatomic) CGImageRef image;
@end

@implementation SFSCachedImage
- (void)dealloc {
    if (_image)
        CGImageRelease(_image);
}
@end

// -[CUINamedVectorGlyph image] retain/autoreleases. UIImageView reads that
// through UIImage.CGImage and does not take ownership.
static CGImageRef SFSCachedGlyphImage(CUINamedVectorGlyph *glyph) {
    SFSCachedImage *cached = objc_getAssociatedObject(glyph, SFSCachedGlyphImage);
    if (cached.image)
        return (CGImageRef)CFAutorelease(CGImageRetain(cached.image));
    CGImageRef image = SFSMonochromeImage(glyph, SFSGlyphScale(glyph), SFSGlyphCanvas(glyph));
    if (!image)
        return NULL;
    cached = [SFSCachedImage new];
    cached.image = image;
    objc_setAssociatedObject(glyph, SFSCachedGlyphImage, cached, OBJC_ASSOCIATION_RETAIN);
    return (CGImageRef)CFAutorelease(CGImageRetain(image));
}

// UIImageView reads -[CUINamedVectorGlyph image] through UIImage.CGImage.
// SwiftUI calls -[CUINamedVectorGlyph drawInContext:].
extern void CGContextDrawSVGDocument(CGContextRef context, CGSVGDocumentRef document) __attribute__((weak_import));

%group GlyphHooks
%hook CUINamedVectorGlyph

- (CGImageRef)image {
    CGImageRef image = SFSCachedGlyphImage(self);
    if (image)
        return image;
    return %orig;
}

- (CGImageRef)rasterizeImageUsingScaleFactor:(CGFloat)scale forTargetSize:(CGSize)target {
    CGImageRef image = SFSMonochromeImage(self, scale, target);
    if (image)
        return image;
    return %orig;
}

- (void)drawInContext:(CGContextRef)context {
    CGSize canvas = SFSGlyphCanvas(self);
    CGSVGDocumentRef document = SFSGlyphDocument(self);
    if (document && SFSDrawMonochromeLayers(context, document, NULL, NO, SFSGlyphScale(self), canvas, canvas))
        return;
    %orig;
}

- (void)_drawInContext:(CGContextRef)context scaleFactor:(CGFloat)scale targetSize:(CGSize)target fillColor:(CGColorRef)fill {
    CGSVGDocumentRef document = SFSGlyphDocument(self);
    if (document && SFSDrawMonochromeLayers(context, document, fill, NO, scale, target, SFSGlyphCanvas(self)))
        return;
    %orig;
}

%end
%end

%group DrawSVG
%hookf(void, CGContextDrawSVGDocument, CGContextRef context, CGSVGDocumentRef document) {
    if (SFSDrawMonochromeLayers(context, document, NULL, YES, 1, CGSizeZero, CGSizeZero))
        return;
    %orig;
}
%end

%group ImageContent
%hook _UIImageCUIVectorGlyphContent

- (CGImageRef)CGImage {
    // UIImage.size is sizeInPixels / vectorScale. A CGImage at the glyph's own
    // scale (often 1) is then treated as that many pixels at the screen scale,
    // so the icon draws small and out of place.
    SFSCachedImage *cached = objc_getAssociatedObject(self, SFSCachedGlyphImage);
    if (cached.image)
        return (CGImageRef)CFAutorelease(CGImageRetain(cached.image));
    CUINamedVectorGlyph *glyph = [self vectorGlyph];
    CGFloat scale = 0;
    if ([self respondsToSelector:@selector(vectorScale)])
        scale = [self vectorScale];
    if (scale <= 0 && [self respondsToSelector:@selector(scale)])
        scale = [self scale];
    CGSize target = CGSizeZero;
    if (scale > 0 && [self respondsToSelector:@selector(sizeInPixels)]) {
        CGSize pixels = [self sizeInPixels];
        target = CGSizeMake(pixels.width / scale, pixels.height / scale);
    }
    if (target.width <= 0 || target.height <= 0)
        target = SFSGlyphCanvas(glyph);
    if (scale <= 0)
        scale = SFSGlyphScale(glyph);
    CGImageRef image = SFSMonochromeImage(glyph, scale, target);
    if (!image)
        return %orig;
    cached = [SFSCachedImage new];
    cached.image = image;
    objc_setAssociatedObject(self, SFSCachedGlyphImage, cached, OBJC_ASSOCIATION_RETAIN);
    return (CGImageRef)CFAutorelease(CGImageRetain(image));
}

- (CGImageRef)_provideCGImageWithSize:(CGSize)size scale:(CGFloat)scale {
    CGImageRef image = SFSMonochromeImage([self vectorGlyph], scale, size);
    if (image)
        return (CGImageRef)CFAutorelease(image);
    return %orig;
}

%end
%end

void SFSInitCARCompat(void) {
    SFSLoadSVG();
    %init(GlyphHooks);
    Class content = %c(_UIImageCUIVectorGlyphContent);
    if (content && [content instancesRespondToSelector:@selector(_provideCGImageWithSize:scale:)])
        %init(ImageContent);
    if (SFSNodeTransform && CGContextDrawSVGDocument)
        %init(DrawSVG);
}
