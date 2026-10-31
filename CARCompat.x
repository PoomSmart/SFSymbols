#import "GlyphSupport.h"
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIScreen.h>
#import <dlfcn.h>
#import <objc/runtime.h>

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
typedef Boolean (*SFSAttrTransformFn)(CGSVGAttributeRef, CGAffineTransform *);
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
static SFSAttrTransformFn SFSAttrTransform;
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
        SFSAttrTransform = dlsym(svg, "CGSVGAttributeGetTransform");
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

// iOS 15 CoreUI reads attribute 0x3f inside CUISVGNodeGetTransform. iOS 13 and 14
// have the same attribute on the shape node, but that CoreUI function does not exist.
static CGAffineTransform SFSShapeTransform(CGSVGNodeRef node, CGAffineTransform fallback) {
    if (SFSNodeTransform)
        return SFSNodeTransform(node);
    if (SFSAttrTransform && SFSFindAttribute) {
        CGSVGAttributeRef attribute = SFSFindAttribute(node, 0x3f);
        CGAffineTransform transform;
        if (attribute && SFSAttrTransform(attribute, &transform))
            return transform;
    }
    return fallback;
}

// iOS 15 monochrome fills every shape as one path, so an opacity-0 knockout
// punches a hole through the glyph. Later systems draw each monochrome-N
// class on its own and copy-erase clear-behind layers first.
static BOOL SFSDrawMonochromeLayers(CGContextRef context, CGSVGDocumentRef document, CGColorRef fillColor, BOOL alreadyScaled, CGFloat scale, CGSize targetSize, CGSize canvas, BOOL mapInk) {
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
        CGAffineTransform xform = SFSShapeTransform(node, documentTransform);
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
    CGRect ink = CGRectNull;
    for (NSString *name in names) {
        CGRect bounds = CGPathGetPathBoundingBox((__bridge CGPathRef)groups[name][@"path"]);
        if (CGRectIsNull(bounds) || CGRectIsEmpty(bounds) || !isfinite(bounds.size.width) || !isfinite(bounds.size.height))
            continue;
        ink = CGRectIsNull(ink) ? bounds : CGRectUnion(ink, bounds);
    }
    CGRect source = CGRectMake(0, 0, canvas.width, canvas.height);
    BOOL finite = ink.size.width > 0 && ink.size.height > 0 && isfinite(ink.origin.x) && isfinite(ink.origin.y) && isfinite(ink.size.width) && isfinite(ink.size.height) && ink.size.width < 100000 && ink.size.height < 100000;
    if (finite && (mapInk || ink.size.width > canvas.width * 8 || ink.size.height > canvas.height * 8 || ink.origin.x < -canvas.width || ink.origin.y < -canvas.height))
        source = ink;
    CGSize dest = alreadyScaled ? canvas : CGSizeMake(targetSize.width * scale, targetSize.height * scale);
    CGContextSaveGState(context);
    CGContextScaleCTM(context, dest.width / source.size.width, dest.height / source.size.height);
    CGContextScaleCTM(context, 1, -1);
    CGContextTranslateCTM(context, -source.origin.x, -(source.origin.y + source.size.height));
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
    CGFloat scale = [glyph scale];
    CGFloat ratio = [glyph _requestedPointSizeRatio];
    if (ratio > 0)
        scale = (scale > 0 ? scale : 1) * ratio;
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
    BOOL mapInk = [glyph respondsToSelector:@selector(referenceCanvasSize)];
    BOOL drew = SFSDrawMonochromeLayers(context, document, NULL, NO, scale, target, canvas, mapInk);
    CGImageRef image = drew ? CGBitmapContextCreateImage(context) : NULL;
    CGContextRelease(context);
    return image;
}

static CUICatalog *SFSCatalog(NSBundle *bundle) {
    static NSMapTable *catalogs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        catalogs = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsWeakMemory valueOptions:NSPointerFunctionsStrongMemory];
    });
    if (!bundle)
        return nil;
    CUICatalog *catalog = [catalogs objectForKey:bundle];
    if (catalog)
        return catalog;
    catalog = [[%c(CUICatalog) alloc] initWithName:@"Assets" fromBundle:bundle error:nil];
    if (catalog)
        [catalogs setObject:catalog forKey:bundle];
    return catalog;
}

static CGSize SFSSymbolPointSize(CUINamedVectorGlyph *glyph) {
    CGSize box = [glyph alignmentRect].size;
    if (box.width >= 1 && box.height >= 1 && box.width <= 200 && box.height <= 200)
        return box;
    CGFloat point = [glyph referencePointSize];
    if (point >= 1 && point <= 200)
        return CGSizeMake(point, point);
    return CGSizeMake(22, 22);
}

UIImage *SFSMonochromeSymbolImage(NSBundle *bundle, NSString *name) {
    if (!bundle || name.length == 0)
        return nil;
    CUICatalog *catalog = SFSCatalog(bundle);
    if (!catalog)
        return nil;
    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale <= 0)
        scale = 1;
    id found = [catalog namedVectorGlyphWithName:name scaleFactor:scale deviceIdiom:0 layoutDirection:5 glyphSize:2 glyphWeight:4 glyphPointSize:22 appearanceName:nil];
    if (![found isKindOfClass:%c(CUINamedVectorGlyph)])
        return nil;
    CUINamedVectorGlyph *glyph = found;
    CGImageRef rendered = SFSMonochromeImage(glyph, scale, SFSSymbolPointSize(glyph));
    if (!rendered)
        return nil;
    UIImage *image = [[UIImage imageWithCGImage:rendered scale:scale orientation:UIImageOrientationUp] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    CGImageRelease(rendered);
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
    CGSize target = [glyph alignmentRect].size;
    if (target.width < 1 || target.height < 1)
        target = SFSGlyphCanvas(glyph);
    CGFloat scale = [glyph scale];
    if (scale <= 0)
        scale = SFSGlyphScale(glyph);
    CGImageRef image = SFSMonochromeImage(glyph, scale, target);
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

%end
%end

// drawInContext: tail-branches into the five-argument draw, so a hook on the
// public method does not see that call. Both methods exist together on iOS 15.
%group GlyphDraw
%hook CUINamedVectorGlyph

- (void)drawInContext:(CGContextRef)context {
    CGSize canvas = SFSGlyphCanvas(self);
    CGSVGDocumentRef document = SFSGlyphDocument(self);
    if (document && SFSDrawMonochromeLayers(context, document, NULL, NO, SFSGlyphScale(self), canvas, canvas, YES))
        return;
    %orig;
}

- (void)_drawInContext:(CGContextRef)context scaleFactor:(CGFloat)scale targetSize:(CGSize)target fillColor:(CGColorRef)fill {
    CGSVGDocumentRef document = SFSGlyphDocument(self);
    if (document && SFSDrawMonochromeLayers(context, document, fill, NO, scale, target, SFSGlyphCanvas(self), YES))
        return;
    %orig;
}

%end
%end

%group DrawSVG
%hookf(void, CGContextDrawSVGDocument, CGContextRef context, CGSVGDocumentRef document) {
    if (SFSDrawMonochromeLayers(context, document, NULL, YES, 1, CGSizeZero, CGSizeZero, YES))
        return;
    %orig;
}
%end

%group ContentImage
%hook _UIImageCUIVectorGlyphContent

- (CGImageRef)CGImage {
    // UIImage.size is sizeInPixels / vectorScale. A CGImage at the glyph's own
    // scale (often 1) is then treated as that many pixels at the screen scale,
    // so the icon draws small and out of place.
    SFSCachedImage *cached = objc_getAssociatedObject(self, SFSCachedGlyphImage);
    if (cached.image)
        return (CGImageRef)CFAutorelease(CGImageRetain(cached.image));
    CUINamedVectorGlyph *glyph = [self vectorGlyph];
    CGFloat scale = [self vectorScale];
    CGSize target = CGSizeZero;
    if (scale > 0) {
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

%end
%end

// Callers CGImageRelease this. rasterizeImageUsingScaleFactor:forTargetSize: has the same ownership.
%group ContentProvide
%hook _UIImageCUIVectorGlyphContent

- (CGImageRef)_provideCGImageWithSize:(CGSize)size scale:(CGFloat)scale {
    CGImageRef image = SFSMonochromeImage([self vectorGlyph], scale, size);
    if (image)
        return image;
    return %orig;
}

%end
%end

%group ContentSized
%hook _UIImageCUIVectorGlyphContent

- (CGImageRef)_CGImageWithSize:(CGSize)size scale:(CGFloat)scale {
    CGImageRef image = SFSMonochromeImage([self vectorGlyph], scale, size);
    if (image)
        return image;
    return %orig;
}

%end
%end

// CoreUI returns nil when glyphPointSize is 0. A zero glyph size misses the
// medium rendition. Layout direction 0 only matches undirected glyphs, so
// left-to-right becomes pointing-right (5) and right-to-left becomes
// pointing-left (4). Those searches still fall back to an undirected glyph.
%group CatalogLookup
%hook CUICatalog

- (CUINamedVectorGlyph *)namedVectorGlyphWithName:(NSString *)name scaleFactor:(CGFloat)scale deviceIdiom:(NSInteger)idiom layoutDirection:(NSInteger)direction glyphSize:(NSInteger)glyphSize glyphWeight:(NSInteger)weight glyphPointSize:(CGFloat)pointSize appearanceName:(NSString *)appearance {
    if (!(pointSize > 0))
        pointSize = 22;
    if (glyphSize <= 0)
        glyphSize = 2;
    if (weight <= 0)
        weight = 4;
    if (direction == 0)
        direction = 5;
    else if (direction == 1)
        direction = 4;
    return %orig(name, scale, idiom, direction, glyphSize, weight, pointSize, appearance);
}

%end
%end

static BOOL SFSClassImplements(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

void SFSInitCARCompat(void) {
    SFSLoadSVG();
    %init(CatalogLookup);
    %init(GlyphHooks);
    Class glyph = %c(CUINamedVectorGlyph);
    if (glyph && SFSClassImplements(glyph, @selector(drawInContext:)) && SFSClassImplements(glyph, @selector(_drawInContext:scaleFactor:targetSize:fillColor:)))
        %init(GlyphDraw);
    Class content = %c(_UIImageCUIVectorGlyphContent);
    if (content && SFSClassImplements(content, @selector(CGImage)))
        %init(ContentImage);
    if (content && SFSClassImplements(content, @selector(_provideCGImageWithSize:scale:)))
        %init(ContentProvide);
    if (content && SFSClassImplements(content, @selector(_CGImageWithSize:scale:)))
        %init(ContentSized);
    if (SFSNodeTransform && CGContextDrawSVGDocument)
        %init(DrawSVG);
}
