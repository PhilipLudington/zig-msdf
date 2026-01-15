# MSDF Artifacts on Curved Glyphs

**Issue:** GitHub Issue #1
**Status:** Partially fixed, further work needed

## Problem Description

MSDF (Multi-channel Signed Distance Field) rendering shows visible jagged artifacts on curved glyphs, particularly:
- S-curve characters: S, D, G, P
- Numerals with curves: 2, 3

Artifacts are most visible at high zoom levels (8x) and appear as stair-stepping along smooth curves.

## Root Cause Analysis

MSDF works by assigning RGB channels to different edge segments. The median of RGB at each pixel reconstructs the distance field. Artifacts occur when channels disagree about inside/outside status with significant spread.

### Channel Disagreement Metrics (DejaVu Sans, 48px)

| Spread Threshold | S Artifacts | D Artifacts |
|------------------|-------------|-------------|
| > 200            | 0.0%        | 0.0%        |
| > 150            | 10.2%       | 10.3%       |
| > 100            | 29.3%       | 35.3%       |
| > 75             | 32.2%       | 37.2%       |
| > 50             | 35.2%       | 39.5%       |

**Key insight:** While extreme artifacts (spread > 150) affect ~10% of boundary pixels, moderate disagreements (spread > 100) affect ~30-35% of pixels, which still cause visible artifacts.

## Fixes Implemented

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

## Results After Fixes

### Before (Geneva font, 64px):
- S artifact-free rate: 82.1%
- D artifact-free rate: 81.4%

### After:
- S artifact-free rate: 92.6%
- D artifact-free rate: 84.5%
- 2 artifact-free rate: 92.9%
- 3 artifact-free rate: 90.2%

## Remaining Issue

Despite improvements, ~10% of boundary pixels still have high-spread artifacts (spread > 150), and ~30% have moderate artifacts (spread > 100). Visual artifacts remain visible at high zoom.

### Why Artifacts Persist

The edge coloring algorithm assigns colors to minimize conflicts, but cannot eliminate all cases where:
1. Multiple edges of the same color contribute conflicting distances
2. Thin parts of glyphs have facing edges that interfere
3. Complex curve intersections create unavoidable channel disagreements

## Recommended Next Step: Error Correction

The msdfgen reference implementation uses **error correction** as a post-processing step. This technique:

1. Scans each pixel after MSDF generation
2. Detects where channels disagree about inside/outside
3. Clamps minority channels to not cross the 0.5 threshold
4. Ensures median is determined by majority channels

### Implementation Approach

```zig
fn errorCorrection(bitmap: *MsdfBitmap) void {
    for each pixel (x, y):
        r, g, b = getPixel(x, y)

        // Count channels saying "inside" (> 127)
        inside_count = (r > 127) + (g > 127) + (b > 127)

        if inside_count == 1 or inside_count == 2:
            // Channels disagree - clamp minority to majority
            if inside_count >= 2:
                // Majority says inside - clamp low channel up
                clamp_to = 128
            else:
                // Majority says outside - clamp high channel down
                clamp_to = 127

            // Apply clamping to fix the median
            ...
}
```

## Files Modified

- `src/generator/coloring.zig` - Edge coloring algorithm
- `src/generator/edge.zig` - Added `curvatureSign()` method
- `src/generator/contour.zig` - Added `splitAtInflections()`
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

## References

- [msdfgen by Viktor Chlumsky](https://github.com/Chlumsky/msdfgen) - Reference implementation
- [MSDF paper](https://github.com/Chlumsky/msdfgen/files/3050967/thesis.pdf) - Original thesis
- GitHub Issue #1 - Original bug report
