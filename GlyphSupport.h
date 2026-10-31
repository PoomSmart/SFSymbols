#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIImage.h>
#import <UIKit/UIImageAsset.h>
#import <UIKit/UIImageConfiguration.h>

void SFSInitCARCompat(void);
UIImage *SFSMonochromeSymbolImage(NSBundle *bundle, NSString *name);

typedef struct CGSVGDocument *CGSVGDocumentRef;

@interface CUIThemeRendition : NSObject
- (CGSVGDocumentRef)svgDocument;
@end

@interface CUINamedVectorGlyph : NSObject
- (CUIThemeRendition *)_rendition;
- (CGSize)referenceCanvasSize;
- (CGRect)alignmentRect;
- (CGFloat)referencePointSize;
- (CGFloat)scale;
- (CGFloat)_requestedPointSizeRatio;
- (CGImageRef)image;
- (CGImageRef)rasterizeImageUsingScaleFactor:(CGFloat)scale forTargetSize:(CGSize)target;
- (void)drawInContext:(CGContextRef)context;
- (void)_drawInContext:(CGContextRef)context scaleFactor:(CGFloat)scale targetSize:(CGSize)target fillColor:(CGColorRef)fill;
@end

@interface CUICatalog : NSObject
- (instancetype)initWithName:(NSString *)name fromBundle:(NSBundle *)bundle error:(NSError **)error;
- (CUINamedVectorGlyph *)namedVectorGlyphWithName:(NSString *)name scaleFactor:(CGFloat)scale deviceIdiom:(NSInteger)idiom layoutDirection:(NSInteger)direction glyphSize:(NSInteger)glyphSize glyphWeight:(NSInteger)weight glyphPointSize:(CGFloat)pointSize appearanceName:(NSString *)appearance;
@end

@interface _UIImageCUIVectorGlyphContent : NSObject
- (CUINamedVectorGlyph *)vectorGlyph;
- (CGFloat)vectorScale;
- (CGSize)sizeInPixels;
- (CGImageRef)CGImage;
- (CGImageRef)_provideCGImageWithSize:(CGSize)size scale:(CGFloat)scale;
- (CGImageRef)_CGImageWithSize:(CGSize)size scale:(CGFloat)scale;
@end

@interface UIImage (SFSSymbolContent)
- (id)content;
+ (UIImage *)_generateCompositedSymbolImageForAsset:(UIImageAsset *)asset usingLayers:(NSArray *)layers configuration:(UIImageConfiguration *)configuration alignUsingBaselines:(BOOL)align;
@end

@interface UIImageAsset (SFSName)
- (NSString *)assetName;
@end

@interface _UIImageSymbolLayer : NSObject
- (UIImageAsset *)asset;
@end

@interface SFSSymbolAssetInfo : NSObject
- (instancetype)initWithName:(NSString *)name bundle:(NSBundle *)bundle andType:(NSInteger)type;
@end
