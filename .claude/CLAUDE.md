# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

zig-msdf is a pure Zig library for generating Multi-channel Signed Distance Fields (MSDF) from OpenType fonts. It supports both TrueType (.ttf) and CFF/OpenType (.otf) fonts. The implementation is based on Viktor Chlumsky's msdfgen algorithm.

## Build Commands

```bash
zig build              # Build library and examples
zig build test         # Run all tests (56 total)
zig fmt src/           # Format source code
```

### Run Examples
```bash
zig build single-glyph -- path/to/font.ttf    # Generate single glyph MSDF
zig build generate-atlas -- path/to/font.ttf  # Generate font atlas
zig build cff-font -- path/to/font.otf        # CFF font demo
zig build compare-a                            # Compare output with msdfgen
```

### Debug Tools
```bash
zig build compare-msdf     # Compare with msdfgen reference
zig build pixel-debug      # Debug per-channel distances
zig build corner-debug     # Debug corner pixel distances
zig build debug-coloring   # Debug edge coloring
zig build m-corner-diag    # Debug M character corners
zig build artifact-diag    # Analyze MSDF artifacts
```

## Architecture

### Core Pipeline

```
Font File → Parser → Shape (contours/edges) → Coloring → MSDF Generation → Bitmap
```

### Module Structure

**Public API** (`src/msdf.zig`):
- `Font.fromFile()` / `Font.fromMemory()` - Load fonts
- `generateGlyph()` - Generate MSDF for single character
- `generateAtlas()` - Generate atlas for multiple characters
- `GenerateOptions` / `AtlasOptions` - Configuration structs

**Generator** (`src/generator/`):
- `math.zig` - Vec2, Bounds, SignedDistance, Bezier math
- `edge.zig` - EdgeSegment (line, quadratic, cubic), distance calculations
- `contour.zig` - Contour and Shape types, winding calculation
- `coloring.zig` - Edge coloring algorithm (assigns R/G/B channels)
- `generate.zig` - MSDF generation, transform calculation, error correction

**Font Parsing**:
- `src/truetype/` - TrueType tables (glyf, cmap, head, maxp, hhea, hmtx, loca)
- `src/cff/` - CFF/Type2 charstring parsing (cubic Beziers)

### Key Types

```zig
Shape           // Collection of contours forming a glyph
Contour         // Closed path of edge segments
EdgeSegment     // Line, quadratic Bezier, or cubic Bezier
EdgeColor       // .white, .red, .green, .blue, .yellow, .cyan, .magenta
Transform       // Scale + translate for shape-to-pixel mapping
SignedDistance  // Distance value with sign (inside/outside)
```

### Transform Calculation

Two modes available via `GenerateOptions.msdfgen_autoframe`:
- `false` (default): Conservative - glyph stays within bitmap bounds
- `true`: msdfgen-compatible - may extend slightly beyond bounds for larger glyphs

## Reference Implementation

The reference C++ msdfgen is at `/Users/mrphil/Fun/msdfgen`. Use for comparison:

```bash
msdfgen msdf -font "/System/Library/Fonts/Geneva.ttf" 65 \
    -dimensions 32 32 -pxrange 4 -autoframe -legacyfontscaling \
    -format rgba -o reference.rgba
```

## Current Development Status

All 56 tests passing. Active work on reducing differences between zig-msdf and msdfgen output. Key metrics tracked: Mean Absolute Error (MAE), match rate, inside/outside agreement.

## Coding Standards

This project uses CarbideZig standards (see `carbide/CARBIDE.md` and `carbide/STANDARDS.md`):
- Explicit allocator injection
- `defer`/`errdefer` immediately after resource acquisition
- Specific error sets per domain
- `init()`/`deinit()` lifecycle pattern
