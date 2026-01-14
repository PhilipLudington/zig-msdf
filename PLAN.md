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

- [x] Implement `src/generator/edge.zig`:
  - [x] `EdgeColor` enum (cyan, magenta, yellow, white) with `hasRed()`, `hasGreen()`, `hasBlue()` methods
  - [x] `LinearSegment` struct with `signedDistance(point: Vec2)` method
  - [x] `QuadraticSegment` struct with `signedDistance(point: Vec2)` method
  - [x] `CubicSegment` struct with `signedDistance(point: Vec2)` method (for future OpenType CFF support)
  - [x] `EdgeSegment` tagged union wrapping all segment types

- [x] Implement `src/generator/contour.zig`:
  - [x] `Contour` struct containing edge slice
  - [x] `winding()` method to determine contour direction
  - [x] `Shape` struct containing contour slice
  - [x] `bounds()` method for shape bounding box

## Phase 4: TrueType Parser - Foundation

- [x] Implement `src/truetype/parser.zig`:
  - [x] Big-endian read utilities: `readU16Big()`, `readU32Big()`, `readI16Big()`
  - [x] `Font` struct with all parsed table data
  - [x] `Font.fromFile()` - load font from filesystem
  - [x] `Font.fromMemory()` - load font from byte slice
  - [x] `Font.deinit()` - cleanup

- [x] Implement `src/truetype/tables.zig`:
  - [x] `TableRecord` struct (tag, checksum, offset, length)
  - [x] `TableDirectory` struct
  - [x] `parse()` - parse table directory from font data
  - [x] `findTable()` - locate table by 4-byte tag

## Phase 5: TrueType Parser - Simple Tables

- [x] Implement `src/truetype/head_maxp.zig`:
  - [x] `HeadTable` struct (units_per_em, index_to_loc_format, bounding box)
  - [x] `HeadTable.parse()` method
  - [x] `MaxpTable` struct (num_glyphs)
  - [x] `MaxpTable.parse()` method

- [x] Implement `src/truetype/hhea_hmtx.zig`:
  - [x] `HheaTable` struct (ascent, descent, line_gap, num_of_long_hor_metrics)
  - [x] `HheaTable.parse()` method
  - [x] `HmtxTable` struct
  - [x] `HmtxTable.getAdvanceWidth()` method
  - [x] `HmtxTable.getLeftSideBearing()` method

## Phase 6: TrueType Parser - Character Mapping

- [x] Implement `src/truetype/cmap.zig`:
  - [x] `CmapTable` struct (subtable_offset, format)
  - [x] `parseCmap()` - find best Unicode subtable (prefer format 12, fallback to format 4)
  - [x] `getGlyphIndex()` - map codepoint to glyph index
  - [x] `getGlyphIndexFormat4()` - BMP character lookup via segment search
  - [x] `getGlyphIndexFormat12()` - full Unicode lookup via binary search

## Phase 7: TrueType Parser - Glyph Outlines

- [x] Implement `src/truetype/glyf.zig`:
  - [x] `getGlyphOffset()` - use loca table to find glyph data location
  - [x] `parseGlyph()` - entry point, dispatch to simple or compound
  - [x] `parseSimpleGlyph()`:
    - [x] Parse end points of contours
    - [x] Skip instructions
    - [x] Parse RLE-compressed flags
    - [x] Parse delta-encoded X coordinates
    - [x] Parse delta-encoded Y coordinates
  - [x] `buildShape()` - convert point arrays to Shape with contours
  - [x] `buildContour()` - convert points to edge segments, handling:
    - [x] On-curve to on-curve (linear segments)
    - [x] On-curve to off-curve to on-curve (quadratic segments)
    - [x] Consecutive off-curve points (implicit on-curve at midpoint)
  - [x] `parseCompoundGlyph()`:
    - [x] Parse component flags and glyph indices
    - [x] Parse translation arguments (1 or 2 byte formats)
    - [x] Parse transformation matrix (scale, xy-scale, or 2x2)
    - [x] Recursively parse component glyphs
    - [x] Apply transformations to component points
    - [x] Merge all components into single Shape

## Phase 8: Edge Coloring Algorithm

- [x] Implement `src/generator/coloring.zig`:
  - [x] `colorEdges()` - main entry point
  - [x] Corner detection based on edge direction change
  - [x] Color assignment to preserve sharp corners
  - [x] Ensure adjacent edges don't share all channels
  - [x] Handle single-edge contours

## Phase 9: MSDF Generation

- [x] Implement `src/generator/generate.zig`:
  - [x] `generateMsdf()` - core generation function:
    - [x] Allocate output pixel buffer (RGB8)
    - [x] For each pixel, compute world-space position
    - [x] Find minimum signed distance per channel (R, G, B)
    - [x] Apply winding number to determine inside/outside
    - [x] Convert distances to pixel values
  - [x] `computeWinding()` - determine if point is inside shape
  - [x] `distanceToPixel()` - map distance to 0-255 range
  - [x] `MsdfBitmap` struct with pixels, dimensions, allocator
  - [x] `Transform` struct for pixel-to-shape coordinate mapping
  - [x] `calculateTransform()` - fit shape into bitmap with padding

## Phase 10: High-Level Public API

- [x] Complete `src/msdf.zig`:
  - [x] Re-export `Font` type
  - [x] `GenerateOptions` struct (size, padding, range)
  - [x] `generateGlyph()` - generate MSDF for single character:
    - [x] Look up glyph index from codepoint
    - [x] Parse glyph outline
    - [x] Apply edge coloring
    - [x] Calculate scale and translation from options
    - [x] Generate MSDF
    - [x] Return MsdfResult with metrics
  - [x] `GlyphMetrics` struct (advance_width, bearing_x, bearing_y, width, height)

## Phase 11: Atlas Generation

- [x] Add atlas support to `src/msdf.zig`:
  - [x] `AtlasOptions` struct (chars, glyph_size, padding, range)
  - [x] `AtlasGlyph` struct (UV coordinates, metrics)
  - [x] `AtlasResult` struct (pixels RGBA8, dimensions, glyph map)
  - [x] `generateAtlas()` function:
    - [x] Generate MSDF for each character
    - [x] Pack glyphs into atlas texture (simple row-based or shelf packing)
    - [x] Calculate UV coordinates for each glyph
    - [x] Return combined result

## Phase 12: Examples

- [x] Create `examples/single_glyph.zig`:
  - [x] Load font file
  - [x] Generate MSDF for a single character
  - [x] Output as PPM image (simple, no dependencies)

- [x] Create `examples/generate_atlas.zig`:
  - [x] Load font file
  - [x] Generate atlas for ASCII characters
  - [x] Output atlas as PPM image
  - [x] Print glyph metrics/UVs to stdout

## Phase 13: Testing

- [x] Add unit tests for math utilities (Vec2 operations, polynomial solvers)
- [x] Add unit tests for TrueType parsing (test with embedded font data or test fixtures)
- [x] Add integration tests:
  - [x] Build shapes programmatically and generate MSDF
  - [x] Verify glyph outlines have expected number of contours/edges
  - [x] Verify MSDF output dimensions match requested size
- [x] Visual regression tests (verify output properties like inside/outside, channel differences)

## Phase 14: Polish and Optimization

- [x] Review error handling throughout (use descriptive error types)
  - Added table-specific error types: InvalidHeadTable, InvalidMaxpTable, InvalidCmapTable, InvalidHheaTable, InvalidHmtxTable, InvalidGlyfTable
- [x] Add bounds checking for all font data access
  - Added validation in getGlyphOffset for corrupted loca offsets and bounds
  - Added minimum size validation in parseSimpleGlyph and parseCompoundGlyph
  - Added num_points sanity check to prevent excessive allocations
- [x] Profile MSDF generation performance
  - Benchmarked at ~4.6ms/glyph in ReleaseFast mode (95 glyphs in 440ms)
  - Performance is acceptable for font rendering use cases
- [x] Consider SIMD optimization for distance calculations (optional)
  - Current performance is acceptable; SIMD could be added later if needed
- [x] Ensure all allocations are properly freed on error paths
  - Verified all allocations have proper errdefer chains
  - Documented intentional error handling patterns (e.g., findTable catch continue)

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

**Phase 14 complete** - All phases of the zig-msdf implementation are now complete.

The library provides:
- Complete TrueType font parsing (simple and compound glyphs)
- Multi-channel signed distance field generation
- Edge coloring for sharp corner preservation
- Atlas generation for multiple glyphs
- Example programs demonstrating usage
- Comprehensive test suite
