# SFSymbols

Backports a newer SF Symbols catalog onto iOS 13 through 17. The glyph files come from the `com.ps.sfsymbolsassets` package. This tweak tells UIKit to open that catalog, and on iOS 13–15 it draws the newer layered glyphs in monochrome.

The dylib is injected into processes that link UIKit (`com.apple.UIKit`), and only into apps and generic extensions.

## From a name to a glyph

`systemImageNamed:` and SwiftUI `Image(systemName:)` end at a CoreGlyphs bundle. CoreUI opens that bundle's `Assets.car` and returns a `CUINamedVectorGlyph`. The glyph's rendition holds the SVG document the drawer paints.

`SFSSymbolAssetInfo` is the iOS 16 lookup. For iOS 13-15, the name goes straight to `+[NSBundle bundleWithPath:]`.

```mermaid
flowchart TD
  call["systemImageNamed: or Image(systemName:)"]
  fw{"iOS 16 or newer?"}
  info["SFSSymbolAssetInfo"]
  known{"Name is in the system catalog?"}
  lists["symbol_order.plist and name_aliases.strings"]
  path["bundleWithPath: CoreGlyphs*.bundle"]
  bundle["Support bundle"]
  car["Assets.car"]
  glyph["CUINamedVectorGlyph"]
  svg["rendition.svgDocument"]
  draw{"iOS 16 or newer?"}
  native["CoreUI composites monochrome-N"]
  compat["SFSDrawMonochromeLayers"]

  call --> fw
  fw -->|yes| info --> known
  known -->|yes| bundle
  known -->|no| lists --> bundle
  fw -->|no| path --> bundle
  bundle --> car --> glyph --> svg --> draw
  draw -->|yes| native
  draw -->|no| compat
```

On a current OS the same bundles live in `SFSymbols.framework`, and `CoreServices/CoreGlyphs*.bundle` is a symlink there. `SFSCoreGlyphsBundle` `+public`, `+private`, and `+priority` are that framework's accessors. Older UIKit calls `+[NSBundle bundleWithPath:]` on `/System/Library/CoreServices/CoreGlyphs.bundle` and the Private and Priority variants. Both entry points are redirected at the same support copies. The assets package copies those bundles as-is. `Assets.car` is not rewritten. `Info.plist` is the only file adjusted, so the bundle declares iPhoneOS and a minimum of iOS 13.

## Inside Assets.car

`Assets.car` is a CoreUI catalog. A symbol name looks up a Vector Glyph rendition. That rendition is an SVG document, not a bitmap. The same name can also have small image renditions. Those are not the glyph UIImage draws.

The SVG tags each shape with one or more `monochrome-N` classes. A path may belong to several classes. Each class has a style, `.monochrome-N`, which can set an opacity and `-sfsymbols-clear-behind`. The drawer unions every path in a class and fills that class once, in numeric order.

```mermaid
flowchart TD
  svg["svgDocument"]
  shapes["Shape nodes"]
  group["Group by monochrome-N"]
  union["Union the paths in that class"]
  style["Read .monochrome-N"]
  order["Fill classes in numeric order"]
  copy["clear-behind: Copy blend"]
  normal["otherwise: normal blend"]

  svg --> shapes --> group --> union --> style --> order
  order --> copy
  order --> normal
```

Clear-behind with opacity 0 copies transparent pixels, so it erases. A later class can paint into that hole. `square.and.arrow.up` uses this for the arrow shaft: the shaft is cut out, then drawn back thinner. Filling every shape as one path, which is what iOS 15 does, fills the cutout as well.

The SVG group's transform scales path coordinates onto the canvas and shifts them by the alignment origin. `referenceCanvasSize` is that canvas. `alignmentRect` and `contentBounds` stay on the glyph for UIKit layout. This tweak does not change them.

Beside the car, each bundle ships `symbol_order.plist` and `name_aliases.strings`. The tweak reads those two when the system catalog has no entry for a name. Availability, category, and search plists ship with the bundle because they belong to CoreGlyphs. The draw path does not read them.

## Monochrome drawing

`SFSInitCARCompat` runs only below iOS 16. iOS 16 and 17 already composite `monochrome-N` layers, so they keep the system renderer and only use the catalog redirect above.

iOS 15 CoreUI looks up `template-`, `multicolor-`, and `hierarchical-` prefixes. It has no `monochrome-` prefix, so a monochrome draw takes every shape as one fill. iOS 13 and 14 rasterize the SVG document directly and have the same result.

The replacement walks the SVG with CoreSVG:

1. Enumerate shape nodes.
2. Read each node's `monochrome-N` class tokens. A token that contains `:` is skipped.
3. Union every path that shares a class.
4. Read `.monochrome-N` for opacity and the clear-behind flag.
5. Fill classes in numeric order. Clear-behind uses `kCGBlendModeCopy`. Anything else uses normal blending. The fill alpha is the style opacity times the requested color's alpha.

If a document has no `monochrome-` tokens, the tweak calls the original method.

`referenceCanvasSize` is the layout box. The paths sit in a smaller ink rect inside it. The draw maps that ink rect onto the destination, with a Y flip, so the glyph fills the box instead of staying in the top left at its raw path size. On iOS 13, where `referenceCanvasSize` is absent, the canvas size is parsed from the SVG `viewBox`.

Node transforms come from CoreUI on iOS 15. On iOS 13 and 14 the first `transform="matrix(...)"` in the document is used. The bitmap is sized to the image's pixel size, so an image view or tab bar icon fills its layout box. Variable Color stays with the system.
