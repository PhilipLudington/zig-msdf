# MSDF Artifacts on Curved Glyphs

**Issue:** GitHub Issue #1
**Status:** IN PROGRESS - Interior gap artifacts (U, u "funny hat") still visible despite multiple fix attempts. S-curve metrics at 0%.

## Problem Description

MSDF (Multi-channel Signed Distance Field) rendering shows visible jagged artifacts on curved glyphs, particularly:
- S-curve characters: S, D, G, P
- Numerals with curves: 2, 3

Artifacts are most visible at high zoom levels (8x) and appear as stair-stepping along smooth curves.

## Root Cause: Confirmed

**The issue is definitively in zig-msdf's atlas generation, NOT the rendering code.**

This was proven by:
1. Building an atlas comparison tool (`zig build run-compare` in zig-msdf-examples)
2. Generating identical glyphs with both zig-msdf and reference msdfgen
3. Rendering both atlases with the exact same shader/rendering code
4. **Result:** msdfgen atlas renders perfectly; zig-msdf atlas shows artifacts

### Visual Evidence

Side-by-side atlas comparison (in zig-msdf-examples):
- `zig-msdf-atlas/atlas.ppm` - shows problematic color transitions
- `msdfgen-atlas/atlas.png` - shows correct MSDF color boundaries

The atlases look visibly different, particularly in edge coloring at curve inflection points.

### Comparison Metrics

| Metric | zig-msdf | msdfgen |
|--------|----------|---------|
| Atlas size | 480x480 | 332x332 |
| Glyph count | 94 | 95 |
| Visual quality | Artifacts on curves | Clean |

## Technical Analysis

MSDF works by assigning RGB channels to different edge segments. The median of RGB at each pixel reconstructs the distance field. Artifacts occur when channels disagree about inside/outside status with significant spread.

The issue is in **zig-msdf's edge coloring algorithm**. For proper MSDF rendering, edges must be colored (RGB channels) such that adjacent edges at "corners" have different colors. When this isn't done correctly, the median calculation in the shader produces artifacts.

For the "S" shape:
- The curve has an **inflection point** where curvature direction reverses
- TrueType fonts represent this as multiple quadratic beziers
- The coloring algorithm should detect where curvature sign changes and treat those points as color boundaries

### Channel Disagreement Metrics (DejaVu Sans, 48px)

| Spread Threshold | S Artifacts | D Artifacts |
|------------------|-------------|-------------|
| > 200            | 0.0%        | 0.0%        |
| > 150            | 10.2%       | 10.3%       |
| > 100            | 29.3%       | 35.3%       |
| > 75             | 32.2%       | 37.2%       |
| > 50             | 35.2%       | 39.5%       |

**Key insight:** While extreme artifacts (spread > 150) affect ~10% of boundary pixels, moderate disagreements (spread > 100) affect ~30-35% of pixels, which still cause visible artifacts.

## Fixes Implemented (Partial)

### 1. Curvature Reversal Detection (commit 85b0f5b)

TrueType fonts use quadratic beziers which don't have internal inflection points. However, S-curves are composed of multiple quadratic segments with alternating curvature signs. We now detect curvature sign reversals and create color boundaries at these points.

**Location:** `src/generator/coloring.zig`

```zig
// Detect curvature sign reversal between adjacent edges
const prev_curv = findPreviousCurvature(contour.edges, i);
const curr_curv = findCurrentCurvature(contour.edges, i);

const opposite_signs = (prev_curv > 0 and curr_curv < 0) or
                       (prev_curv < 0 and curr_curv > 0);
```

### 2. Look Past Linear Edges (commit 85b0f5b)

Linear edges have zero curvature and were breaking curvature reversal detection. Added functions to search past linear edges when comparing curvatures.

**Functions added:**
- `findPreviousCurvature()` - Searches backward for curved edge
- `findCurrentCurvature()` - Searches forward for curved edge

### 3. Color Diversity Within Long Curves (commit c0281ab)

Long curved segments with a single color cause self-interference when opposite sides of the curve are close together. Now alternates colors every 3 curved edges.

**Location:** `src/generator/coloring.zig`

```zig
const max_same_color_curves = 3;
// Switch color after max_same_color_curves curved edges
if (curved_count >= max_same_color_curves) {
    curved_count = 0;
    current_color_idx += 1;
}
```

### 4. Error Correction Post-Processing (commits d5cf487, 79d422f)

Added MSDF error correction as a post-processing step.

## Results After Fixes

### Before All Fixes (Geneva font, 64px):
- S artifact-free rate: ~75%
- D artifact-free rate: ~80%

### After Initial Fixes (2025):
- S artifact-free rate: 92.6%
- D artifact-free rate: 84.5%
- 2 artifact-free rate: 92.9%
- 3 artifact-free rate: 90.2%

### After January 2026 Fixes:
- S artifact-free rate: **100%**
- D artifact-free rate: **100%** (was 17.7% before sign correction)
- 2 artifact-free rate: **99.9%**
- 3 artifact-free rate: **100%**

## January 2026 Major Fixes

### 5. Tiebreaker Direction Fix (`math.zig`)

The SignedDistance comparison was preferring parallel approaches instead of perpendicular. Changed `<` to `>` in `lessThan()` to prefer higher orthogonality (perpendicular approaches), which produces sharper corners.

### 6. Per-Edge Color Alternation (`coloring.zig`)

Changed edge coloring to alternate colors for EVERY edge (not every 3 curved edges). This ensures all RGB channels have nearby edges at any point along a curve.

Color order: cyan (G+B) → yellow (R+G) → magenta (R+B) → cyan...
Adjacent colors share one channel for smooth transitions.

### 7. Perpendicular Distance for Linear Segments (`edge.zig`)

For linear segment interiors (0 < t < 1), now uses perpendicular distance to the infinite line instead of true distance to the segment. This matches msdfgen behavior and creates sharper equidistant contours.

### 8. Inter-Contour Sign Correction (`generate.zig`)

Detects when one RGB channel has opposite sign from the other two with significantly larger magnitude (2x+). This indicates inter-contour interference where a channel is finding an edge on a different contour (e.g., D's inner hole affecting pixels near the outer edge).

Only corrects when magnitude difference is large to preserve intentional sign disagreement at corners.

## Remaining Issue: Rounded Corners - FIXED

~~Despite improvements to artifacts, corners appear rounded compared to msdfgen output.~~

**Fixed in January 2026** by implementing msdfgen-style selective error correction with corner protection.

### The Fix

The issue was that error correction was too aggressive - it flattened ALL pixels with channel disagreement to the median value. But at corners, channels SHOULD disagree - this is what creates sharp corners.

**Solution implemented in `src/generator/generate.zig`:**

1. **Stencil buffer** - Added `StencilFlags` with PROTECTED and ERROR flags
2. **Corner protection** (`protectCorners`) - Finds edges where colors change, marks 3x3 region around corner points as PROTECTED
3. **Edge protection** (`protectEdges`) - Marks edge-adjacent pixels with low channel spread as PROTECTED
4. **Selective clash detection** (`detectClashes`) - Only marks non-protected pixels with actual artifacts as ERROR
5. **Targeted correction** (`applyCorrection`) - Only applies median to ERROR pixels, leaving PROTECTED pixels intact

### Results

- M corners: Now sharp (previously rounded)
- A, W, V corners: Improved
- Line-curve junctions: Better defined

### Previous Issue (for reference)

This was most visible on:
- Angular characters: M, A, W, V (line-line junctions)
- Mixed characters: D, P, B (line-curve junctions)

### Investigation Summary (January 2026)

#### What msdfgen Does Differently

Deep study of msdfgen's `core/edge-segments.cpp` revealed key differences:

1. **Perpendicular Distance for Linear Segments**

   For interior points (0 < param < 1), msdfgen uses perpendicular distance to the infinite line, not true distance to the segment:
   ```cpp
   // msdfgen LinearSegment::signedDistance
   if (param > 0 && param < 1) {
       double orthoDistance = dotProduct(ab.getOrthonormal(false), aq);
       if (fabs(orthoDistance) < endpointDistance)
           return SignedDistance(orthoDistance, 0);
   }
   ```
   This creates sharper corners because equidistant contours are straight lines, not arcs.

2. **Orthogonality Tiebreaker**

   When distances are equal, msdfgen uses orthogonality as a tiebreaker:
   - Interior points: orthogonality = 0 (best - perpendicular approach)
   - Endpoint regions: orthogonality = `abs(dot(direction, distance_vector))` (alignment)

3. **Sign Convention**

   msdfgen uses `nonZeroSign(crossProduct(aq, ab))` which equals `-dir.cross(aq)`.
   Our convention `dir.cross(aq) < 0` is equivalent but inverted in naming.

#### Attempted Fixes and Results

| Change | Result |
|--------|--------|
| Perpendicular distance for LinearSegment interior | 'M' corners sharp, but artifacts appeared elsewhere |
| Changed orthogonality from `cross` to `dot` | Major artifacts through 'S', 'D' - broke tiebreaking |
| Combined perpendicular + orthogonality changes | Made everything worse |
| Perpendicular only, keep original orthogonality | 'M' became rounded, artifacts appeared |

#### Key Observations

1. **Without error correction**: 'M' had sharp corners with perpendicular distance, but 'S' had major artifacts
2. **With error correction**: Error correction may be destroying the channel differences that create sharp corners
3. **The changes interact**: Perpendicular distance, orthogonality, and error correction form a complex system

#### Why It's Hard

The rounded corner issue is subtle because:
1. MSDF corner sharpness depends on multiple interacting systems
2. Distance calculation affects which edge "wins" at each pixel
3. Error correction can undo the channel differences needed for corners
4. The tiebreaker (orthogonality) determines behavior when distances are equal

### Possible Root Causes

1. **Error Correction Too Aggressive** - Currently replaces disagreeing pixels with median, destroying corner information
2. **Edge Coloring at Corners** - Colors may not differ enough across corners
3. **Distance Function Subtle Differences** - Small numerical differences accumulate
4. **Orthogonality Tiebreaker** - Our `cross` vs msdfgen's `dot` changes which edge wins ties

### Brainstorm: Next Steps

1. **Smarter Error Correction**
   - msdfgen's error correction is more selective
   - Only fix pixels that would cause interpolation artifacts
   - Preserve intentional channel disagreement at corners
   - Look at msdfgen's `msdf-error-correction.cpp`

2. **Edge Coloring Review**
   - Ensure edges at true corners have maximally different colors
   - Check if coloring algorithm detects all corners
   - Compare edge colors directly with msdfgen output

3. **Instrument and Compare**
   - Add debug output showing which edge wins at each pixel
   - Compare pixel-by-pixel with msdfgen to find where they diverge
   - Create a minimal test case (single corner) for debugging

4. **Alternative Approach**
   - Instead of matching msdfgen exactly, focus on visual quality
   - Accept some differences if corners are "sharp enough"
   - Consider different error correction strategies

5. **Study msdfgen Error Correction**
   - msdfgen has sophisticated error correction in `msdf-error-correction.cpp`
   - Uses "clash detection" to find problematic interpolation regions
   - Preserves corner information while fixing artifacts

## Curve Artifacts Investigation (January 2026)

**Status:** Metrics improved but visual artifacts remain severe

### Visual Evidence (8x zoom)

Despite test metrics showing 84-93% "artifact-free" rates, visual inspection at 8x zoom reveals:
- **'S'**: Multiple "bite" artifacts along both curves
- **'D'**: Jagged edges on the curved portion
- **'M'**: Corners now sharp (corner protection working)

**The "artifact-free" metric does not capture perceptual quality.** A few severe artifacts are more noticeable than many minor ones.

### Root Cause Found

**The "edge segment boundary" hypothesis was WRONG.** Diagnostic analysis revealed:

1. **Only 2.7% of artifacts occur at segment endpoints** (t < 0.02 or t > 0.98)
2. **Artifacts span entire segments** - t values from 0.02 to 0.97
3. **No sign consistency issues at junctions** - 0% problematic junctions

### Actual Root Cause: Missing Color Diversity

Local changes to `coloring.zig` had **removed** the color diversity fix (commit c0281ab):

| Feature | Committed Version | Local Changes |
|---------|-------------------|---------------|
| Corner threshold | 60° | 90° |
| Curvature reversal detection | ✓ | ✗ |
| Color diversity in long curves | Every 3 edges | None |
| No-corner fallback | Alternating colors | Single color (cyan) |

The changes gave **all edges of smooth curves the same color** (cyan = G+B). This left the R channel with no nearby edges - its distance came from the opposite side of the glyph, causing massive channel disagreement.

**Example artifact pixel analysis (before fix):**
```
RGB=(91,255,91) → R=G=91 (outside), B=255 (inside)
Distances: R=41.01, G=-518.06, B=41.01
```
The G channel distance of -518 came from a far-away edge!

### The Fix: Restore Color Diversity

Reverting `coloring.zig` to the committed version restored:
- 60° corner threshold (more corners detected)
- Curvature sign reversal detection
- Color switching every 3 curved edges
- Alternating colors for smooth contours

### Test Metrics After Fix

| Character | Before | After | Improvement |
|-----------|--------|-------|-------------|
| S | 83.9% | **92.6%** | +8.7% |
| D | 81.5% | **84.5%** | +3.0% |
| 2 | 87.3% | **93.0%** | +5.7% |
| 3 | 87.1% | **91.1%** | +4.0% |

**⚠️ WARNING: These metrics are misleading.** Visual inspection shows severe artifacts remain.
The metric counts pixels, but a single severe artifact is more visible than many minor ones.

### Diagnostic Tool Created

Added `tests/artifact_diagnostic.zig` with:
- Per-pixel artifact analysis showing segment index, parameter t, and color
- Distance values for each RGB channel
- Sign consistency analysis at segment junctions
- Edge color visualization

Run with: `zig build artifact-diag`

### Critical Remaining Work

**The library is NOT production-ready.** Visual artifacts on S and D are unacceptable.

#### Priority 1: Understand Why msdfgen Works

msdfgen produces clean output with the same font. We need to understand:
1. **Pseudo-distance calculation** - msdfgen uses a different distance approach
2. **Edge coloring differences** - Compare color assignments pixel-by-pixel
3. **Error correction algorithm** - Study `msdf-error-correction.cpp` in detail

#### Priority 2: Per-Pixel Comparison Tool

Build a tool to compare zig-msdf and msdfgen output:
- Overlay mode showing differences
- Per-pixel distance value comparison
- Identify exactly WHERE they diverge

#### Priority 3: Consider Alternative Approaches

If matching msdfgen is too difficult:
1. **SDF instead of MSDF** - Simpler, no color artifacts (but rounded corners)
2. **Higher resolution** - Reduce artifacts by increasing atlas size
3. **Different font rendering** - Use system font rasterizer + distance transform

#### Interior Tangent Fix

The `edge.zig` interior tangent fix (t=0.01/0.99 for sign determination) is implemented and may help edge cases.

### Relevant Code Locations

| File | What |
|------|------|
| `src/generator/edge.zig` | Distance calculations (LinearSegment, QuadraticSegment, CubicSegment) |
| `src/generator/generate.zig` | Error correction (`correctErrors`, `correctErrorsWithProtection`) |
| `src/generator/coloring.zig` | Edge coloring algorithm |
| msdfgen `core/edge-segments.cpp` | Reference distance calculations |
| msdfgen `msdf-error-correction.cpp` | Reference error correction |

## Comparison Tool

A comparison tool was built in zig-msdf-examples to aid debugging:

```bash
cd ../zig-msdf-examples
zig build run-compare
```

Controls:
- SPACE - Toggle between zig-msdf and msdfgen atlas
- T - Toggle atlas view / text view
- E - Export zig-msdf atlas to `zig-msdf-atlas/` directory
- UP/DOWN or Mouse wheel - Adjust scale
- ESC - Exit

## Interior Gap Artifact Fix (January 2026)

### Problem

Characters with interior gaps (U, H, A, M, etc.) showed triangular artifacts pointing into the gap. For example, the "U" had a visible diamond/spike artifact at the top center between the two vertical strokes - appearing as a "funny hat" on the lowercase 'u'.

### Root Cause Analysis

1. **Same-color edges on opposite sides of gaps**: Edge coloring cycles through cyan→yellow→magenta. For the "U", both top horizontal edges (left and right sides of the inner opening) ended up as cyan.

2. **Channel finding wrong edges**: Pixels in the center gap would have G and B channels find the cyan horizontal edges and compute "inside", while R channel found the distant vertical edges and computed "outside".

3. **Corner protection too broad**: The 3x3 corner protection was marking pixels in the gap as protected because corners at the bottom of the gap (where the curve starts) projected up into the gap region.

4. **Threshold boundary artifacts**: Some artifacts occur where channel values are very close to 127 (the inside/outside threshold). Small differences (e.g., R=126 G=126 B=131) cause channels to disagree about inside/outside status.

### Solution Attempts

Modified `detectClashes()` in `generate.zig` with multiple detection strategies:

#### 1. Pattern-based gap artifact detection (BEFORE protection check)
```zig
// Check if two channels agree and one is an outlier
// R and G agree, B is outlier pattern:
if (rg_diff <= 30) {  // agreement_threshold
    const avg_rg = (@as(u16, r) + @as(u16, g)) / 2;
    const b_from_avg = abs(b - avg_rg);
    if (b_from_avg > 10) {  // outlier_threshold
        is_gap_artifact = true;
    }
}
// Similar checks for R+B agree/G outlier and G+B agree/R outlier
```

#### 2. Threshold boundary detection
```zig
// Channels near 127 that disagree about inside/outside
if (inside_count == 1 or inside_count == 2) {
    const near_threshold: u8 = 20;
    // If at least 2 channels are within ±20 of 127
    if ((r_near and g_near) or (r_near and b_near) or (g_near and b_near)) {
        mark_as_error();
    }
}
```

### Current Status: IN PROGRESS

**Issue remains visible.** The "funny hat" artifact on lowercase 'u' is still present after multiple fix attempts. Visual comparison with msdfgen shows our output is not as sharp and still has the gap artifacts.

#### What's been tried:
- Pattern-based detection for "two channels agree, one outlier"
- Threshold boundary detection (±20 around 127)
- Overriding corner protection for severe disagreements
- Lowering detection thresholds

#### Debug tool created:
```bash
zig build debug-coloring
```
Analyzes edge coloring, corner positions, and channel disagreement for 'U' and 'u' characters.

### Next Steps to Try

1. **Investigate edge coloring algorithm**: The fundamental issue may be that opposite sides of gaps get the same color. Consider:
   - Detecting gap geometry and forcing different colors
   - Using spatial awareness in coloring (not just sequential edge ordering)

2. **Compare with msdfgen pixel-by-pixel**: Build tool to show exact differences

3. **Study msdfgen's error correction**: Their `msdf-error-correction.cpp` may have different heuristics

4. **Consider pseudo-distance**: msdfgen uses pseudo-distance which may handle these cases differently

## Files Modified

- `src/generator/coloring.zig` - Edge coloring algorithm, corner angle threshold (now 90°)
- `src/generator/edge.zig` - Added `curvatureSign()` method, interior tangent fix for endpoints
- `src/generator/contour.zig` - Added `splitAtInflections()`
- `src/generator/generate.zig` - Selective error correction with corner/edge protection:
  - `StencilFlags` - PROTECTED and ERROR pixel flags
  - `correctErrorsWithProtection()` - Main entry point with shape/transform
  - `protectCorners()` - Marks 3x3 region around color-change points
  - `protectEdges()` - Marks edge pixels where channels agree
  - `detectClashes()` - Finds artifacts, includes spike detection
  - `applyCorrection()` - Neighbor-weighted smoothing for error pixels
- `src/msdf.zig` - Calls `correctErrorsWithProtection()` with shape info
- `tests/reference_test.zig` - Artifact detection tests
- `tests/analyze_artifacts.zig` - Detailed artifact analysis

## Test Commands

```bash
# Run S-curve quality tests
zig build test --summary all

# Analyze artifacts in detail
zig build analyze-artifacts

# Debug edge coloring for specific characters
zig build debug-s-curvature

# Test with DejaVu Sans font
zig build test-dejavu
```

## Environment

- Font: DejaVu Sans (TrueType, quadratic beziers)
- Glyph size: 48px
- px_range: 4.0
- Platform: macOS (Metal shaders) / Linux (SPIR-V)

## References

- [msdfgen by Viktor Chlumsky](https://github.com/Chlumsky/msdfgen) - Reference implementation
- [MSDF paper](https://github.com/Chlumsky/msdfgen/files/3050967/thesis.pdf) - Original thesis
- GitHub Issue #1 - Original bug report
