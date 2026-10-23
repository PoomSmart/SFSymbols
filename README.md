# SFSymbols

Backports a newer SF Symbols catalog onto iOS 13 through 17. The glyph files come from the `com.ps.sfsymbolsassets` package. This tweak tells UIKit to open that catalog, and on iOS 13–15 it draws the newer layered glyphs in monochrome.

The dylib is injected into processes that link UIKit (`com.apple.UIKit`), and only into apps and generic extensions.

## Catalog

Shipped glyphs live under `/Library/Application Support/SFSymbols/`:

- `CoreGlyphs.bundle`
- `CoreGlyphsPrivate.bundle`
- `CoreGlyphsPriority.bundle`

`+[NSBundle bundleWithPath:]` returns those bundles whenever the requested path ends in one of those three names. UIKit otherwise opens `/System/Library/CoreServices/CoreGlyphs.bundle` (and the Private and Priority variants), whose `Assets.car` is the catalog built into that iOS version.

`SFSCoreGlyphsBundle` has its own accessors. `+public` and `+private` are always redirected. `+priority` is redirected only when that class method exists.

The support bundles are opened once, before these hooks are installed, and then cached. Later calls return that cache.

`+[SFSSymbolAssetInfo localeAgnosticInfo:allowsPrivate:]` and `+infoForName:allowsPrivate:` still ask the system first. When the system has no entry, the tweak builds one from `symbol_order.plist` and `name_aliases.strings` in the public bundle, then the private bundle. That is how names added after the device's iOS version still resolve.

## Monochrome drawing

`SFSInitCARCompat` runs only below iOS 16. iOS 16 and 17 already composite `monochrome-N` layers, so they keep the system renderer and only use the catalog redirect above.

A current vector glyph stores several shape classes named `monochrome-1`, `monochrome-2`, and so on. A class can set an opacity and `-sfsymbols-clear-behind`. Clear-behind is drawn with `kCGBlendModeCopy`, so an opacity of 0 punches a hole and later classes paint into it. `square.and.arrow.up` uses that for the arrow shaft.

iOS 15 CoreUI looks up `template-`, `multicolor-`, and `hierarchical-` prefixes. It has no `monochrome-` prefix, so a monochrome draw takes every shape as one fill. The clear-behind shaft is filled instead of punched, and the glyph comes out thick and holed. iOS 13 and 14 rasterize the SVG document directly and have the same result.

The replacement walks the SVG with CoreSVG:

1. Enumerate shape nodes.
2. Read each node's `monochrome-N` class tokens. A token that contains `:` is skipped.
3. Union every path that shares a class.
4. Read `.monochrome-N` for opacity and the clear-behind flag.
5. Fill classes in numeric order. Clear-behind uses `kCGBlendModeCopy`. Anything else uses normal blending. The fill alpha is the style opacity times the requested color's alpha.

If a document has no `monochrome-` tokens, the tweak calls the original method.

`referenceCanvasSize` is the layout box. The paths sit in a smaller ink rect inside it. The draw maps that ink rect onto the destination, with a Y flip, so the glyph fills the box instead of staying in the top left at its raw path size. On iOS 13, where `referenceCanvasSize` is absent, the canvas size is parsed from the SVG `viewBox`.

Node transforms come from `CUISVGNodeGetTransform` when CoreUI exports it (iOS 15). Otherwise the first `transform="matrix(...)"` in the document is used.

### Where it is installed

`CUINamedVectorGlyph`

- `image` and `rasterizeImageUsingScaleFactor:forTargetSize:` return a bitmap of the layered draw.
- `drawInContext:` and `_drawInContext:scaleFactor:targetSize:fillColor:` paint that draw into the context. SwiftUI's `_UIGraphicsView` uses `drawInContext:`.

`_UIImageCUIVectorGlyphContent`, when the class implements `_provideCGImageWithSize:scale:`

- `CGImage` is the path UIImageView and the tab bar read. The bitmap is built at `sizeInPixels`, because `UIImage.size` is `sizeInPixels / scale`. A bitmap at the glyph's own scale is then treated as too few pixels and draws small.
- `_provideCGImageWithSize:scale:` is the preview and configuration path. It renders at the size and scale UIKit asked for.

`CGContextDrawSVGDocument` is hooked only when `CUISVGNodeGetTransform` exists and the symbol itself resolved. The symbol is private, so it is `weak_import` and the link allows it to stay undefined (`-Wl,-U,_CGContextDrawSVGDocument`). iOS 13 and 14 keep their own SVG draw and go through the image and rasterize hooks instead.

Variable Color is left to the system. These hooks only replace a draw when the layered monochrome pass succeeds.
