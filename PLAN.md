# Implementation Plan: zig-msdf

A pure Zig library for generating Multi-channel Signed Distance Fields from TrueType fonts.

## Phase 1: Project Setup

- [x] Create directory structure (`src/`, `src/generator/`, `src/truetype/`, `examples/`)
- [x] Create `build.zig` with library target and example executables
- [x] Create `src/msdf.zig` as the public API entry point with placeholder exports

## Phase 2: Core Math Utilities

- [x] Implement `src/generator/math.zig`:
  - [x] `Vec2` struct with operations (add, sub, scale, dot, cross, normalize, distance, lerp)
  - [x] `SignedDistance` struct with distance and orthogonality fields
  - [x] `Bounds` struct for bounding box calculations
  - [x] `solveQuadratic()` - find roots of quadratic equation
  - [x] `solveCubic()` - find roots of cubic equation (needed for cubic Bezier distance)

## Phase 3: Edge and Shape Types

- [ ] Implement `src/generator/edge.zig`:
  - [ ] `EdgeColor` enum (cyan, magenta, yellow, white) with `hasRed()`, `hasGreen()`, `hasBlue()` methods
  - [ ] `LinearSegment` struct with `signedDistance(point: Vec2)` method
  - [ ] `QuadraticSegment` struct with `signedDistance(point: Vec2)` method
  - [ ] `CubicSegment` struct with `signedDistance(point: Vec2)` method (for future OpenType CFF support)
  - [ ] `EdgeSegment` tagged union wrapping all segment types

- [ ] Implement `src/generator/contour.zig`:
  - [ ] `Contour` struct containing edge slice
  - [ ] `winding()` method to determine contour direction
  - [ ] `Shape` struct containing contour slice
  - [ ] `bounds()` method for shape bounding box

## Phase 4: TrueType Parser - Foundation

- [ ] Implement `src/truetype/parser.zig`:
  - [ ] Big-endian read utilities: `readU16Big()`, `readU32Big()`, `readI16Big()`
  - [ ] `Font` struct with all parsed table data
  - [ ] `Font.fromFile()` - load font from filesystem
  - [ ] `Font.fromMemory()` - load font from byte slice
  - [ ] `Font.deinit()` - cleanup

- [ ] Implement `src/truetype/tables.zig`:
  - [ ] `TableRecord` struct (tag, checksum, offset, length)
  - [ ] `TableDirectory` struct
  - [ ] `parse()` - parse table directory from font data
  - [ ] `findTable()` - locate table by 4-byte tag

## Phase 5: TrueType Parser - Simple Tables

- [ ] Implement `src/truetype/head_maxp.zig`:
  - [ ] `HeadTable` struct (units_per_em, index_to_loc_format, bounding box)
  - [ ] `parseHead()` function
  - [ ] `MaxpTable` struct (num_glyphs)
  - [ ] `parseMaxp()` function

- [ ] Implement `src/truetype/hhea_hmtx.zig`:
  - [ ] `HheaTable` struct (ascent, descent, line_gap, num_of_long_hor_metrics)
  - [ ] `parseHhea()` function
  - [ ] `HmtxTable` struct
  - [ ] `getAdvanceWidth()` function
  - [ ] `getLeftSideBearing()` function

## Phase 6: TrueType Parser - Character Mapping

- [ ] Implement `src/truetype/cmap.zig`:
  - [ ] `CmapTable` struct (subtable_offset, format)
  - [ ] `parseCmap()` - find best Unicode subtable (prefer format 12, fallback to format 4)
  - [ ] `getGlyphIndex()` - map codepoint to glyph index
  - [ ] `getGlyphIndexFormat4()` - BMP character lookup via segment search
  - [ ] `getGlyphIndexFormat12()` - full Unicode lookup via binary search

## Phase 7: TrueType Parser - Glyph Outlines

- [ ] Implement `src/truetype/glyf.zig`:
  - [ ] `getGlyphOffset()` - use loca table to find glyph data location
  - [ ] `parseGlyph()` - entry point, dispatch to simple or compound
  - [ ] `parseSimpleGlyph()`:
    - [ ] Parse end points of contours
    - [ ] Skip instructions
    - [ ] Parse RLE-compressed flags
    - [ ] Parse delta-encoded X coordinates
    - [ ] Parse delta-encoded Y coordinates
  - [ ] `buildShape()` - convert point arrays to Shape with contours
  - [ ] `buildContour()` - convert points to edge segments, handling:
    - [ ] On-curve to on-curve (linear segments)
    - [ ] On-curve to off-curve to on-curve (quadratic segments)
    - [ ] Consecutive off-curve points (implicit on-curve at midpoint)
  - [ ] `parseCompoundGlyph()`:
    - [ ] Parse component flags and glyph indices
    - [ ] Parse translation arguments (1 or 2 byte formats)
    - [ ] Parse transformation matrix (scale, xy-scale, or 2x2)
    - [ ] Recursively parse component glyphs
    - [ ] Apply transformations to component points
    - [ ] Merge all components into single Shape

## Phase 8: Edge Coloring Algorithm

- [ ] Implement `src/generator/coloring.zig`:
  - [ ] `colorEdges()` - main entry point
  - [ ] Corner detection based on edge direction change
  - [ ] Color assignment to preserve sharp corners
  - [ ] Ensure adjacent edges don't share all channels
  - [ ] Handle single-edge contours

## Phase 9: MSDF Generation

- [ ] Implement `src/generator/generate.zig`:
  - [ ] `generateMsdf()` - core generation function:
    - [ ] Allocate output pixel buffer (RGB8)
    - [ ] For each pixel, compute world-space position
    - [ ] Find minimum signed distance per channel (R, G, B)
    - [ ] Apply winding number to determine inside/outside
    - [ ] Convert distances to pixel values
  - [ ] `computeWinding()` - determine if point is inside shape
  - [ ] `distanceToPixel()` - map distance to 0-255 range
  - [ ] `MsdfResult` struct with pixels, dimensions, metrics

## Phase 10: High-Level Public API

- [ ] Complete `src/msdf.zig`:
  - [ ] Re-export `Font` type
  - [ ] `GenerateOptions` struct (size, padding, range)
  - [ ] `generateGlyph()` - generate MSDF for single character:
    - [ ] Look up glyph index from codepoint
    - [ ] Parse glyph outline
    - [ ] Apply edge coloring
    - [ ] Calculate scale and translation from options
    - [ ] Generate MSDF
    - [ ] Return MsdfResult with metrics
  - [ ] `GlyphMetrics` struct (advance_width, bearing_x, bearing_y, width, height)

## Phase 11: Atlas Generation

- [ ] Add atlas support to `src/msdf.zig`:
  - [ ] `AtlasOptions` struct (chars, glyph_size, padding, range)
  - [ ] `AtlasGlyph` struct (UV coordinates, metrics)
  - [ ] `AtlasResult` struct (pixels RGBA8, dimensions, glyph map)
  - [ ] `generateAtlas()` function:
    - [ ] Generate MSDF for each character
    - [ ] Pack glyphs into atlas texture (simple row-based or shelf packing)
    - [ ] Calculate UV coordinates for each glyph
    - [ ] Return combined result

## Phase 12: Examples

- [ ] Create `examples/single_glyph.zig`:
  - [ ] Load font file
  - [ ] Generate MSDF for a single character
  - [ ] Output as PPM image (simple, no dependencies)

- [ ] Create `examples/generate_atlas.zig`:
  - [ ] Load font file
  - [ ] Generate atlas for ASCII characters
  - [ ] Output atlas as PPM image
  - [ ] Print glyph metrics/UVs to stdout

## Phase 13: Testing

- [ ] Add unit tests for math utilities (Vec2 operations, polynomial solvers)
- [ ] Add unit tests for TrueType parsing (test with embedded font data or test fixtures)
- [ ] Add integration tests:
  - [ ] Load real font files
  - [ ] Verify glyph outlines have expected number of contours/edges
  - [ ] Verify MSDF output dimensions match requested size
- [ ] Visual regression tests (compare output against known-good renders)

## Phase 14: Polish and Optimization

- [ ] Review error handling throughout (use descriptive error types)
- [ ] Add bounds checking for all font data access
- [ ] Profile MSDF generation performance
- [ ] Consider SIMD optimization for distance calculations (optional)
- [ ] Ensure all allocations are properly freed on error paths

---

## Dependencies Between Phases

```
Phase 1 (Setup)
    │
    ▼
Phase 2 (Math) ──────────────────────┐
    │                                │
    ▼                                │
Phase 3 (Edge/Shape)                 │
    │                                │
    ├───────────────────┐            │
    ▼                   ▼            │
Phase 4 (Parser)    Phase 8 (Color)  │
    │                   │            │
    ▼                   │            │
Phase 5 (Simple Tables) │            │
    │                   │            │
    ▼                   │            │
Phase 6 (cmap)          │            │
    │                   │            │
    ▼                   │            │
Phase 7 (glyf) ─────────┤            │
    │                   │            │
    └───────┬───────────┘            │
            ▼                        │
        Phase 9 (Generate) ◄─────────┘
            │
            ▼
        Phase 10 (API)
            │
            ▼
        Phase 11 (Atlas)
            │
            ▼
        Phase 12 (Examples)
            │
            ▼
        Phase 13 (Testing)
            │
            ▼
        Phase 14 (Polish)
```

## Current Status

**Phase 2 complete** - Ready to begin Phase 3 (Edge and Shape Types).
