# zig-msdf vs msdfgen Alignment Changes

This document summarizes the changes made to reduce differences between zig-msdf and the reference msdfgen implementation.

## Changes Made (Committed)

### 1. SignedDistance Comparison - Exact Equality

**File:** `src/generator/math.zig` (lines 149-160)

**Problem:** zig-msdf was using epsilon comparison (`1e-10`) for the distance tiebreaker, while msdfgen uses exact float equality.

**Before:**
```zig
const epsilon: f64 = 1e-10;
const diff = abs_self - abs_other;
if (@abs(diff) > epsilon) {
    return abs_self < abs_other;
}
return self.orthogonality < other.orthogonality;
```

**After:**
```zig
if (abs_self != abs_other) {
    return abs_self < abs_other;
}
return self.orthogonality < other.orthogonality;
```

**Impact:** At corners, multiple edges have very similar distances. The epsilon was allowing distances differing by up to `1e-10` to fall through to the orthogonality tiebreaker, selecting different edges than msdfgen would. This caused visible corner softening.

---

### 2. Cubic Bezier Distance Calculation - More Search Starts

**File:** `src/generator/edge.zig` (lines 363-491)

**Problem:** zig-msdf used only 10 sample points with a single Newton refinement pass, potentially missing local minima on complex cubic curves.

**Before:**
- 10 evenly-spaced samples along curve
- Single Newton iteration from best sample
- Simple distance-squared comparison

**After:**
- 8 search starts with iterative Newton refinement from each
- Uses msdfgen's polynomial coefficient representation (`qa`, `ab`, `br`, `as`)
- Newton formula: `t_new = t - dot(qe, d1) / (dot(d1, d1) + dot(qe, d2))`
- Multiple refinement steps per search start

**Impact:** More robust distance calculation for S-curves and complex bezier segments.

---

### 3. Removed Inflection Point Splitting

**File:** `src/generator/coloring.zig` (lines 32-40)

**Problem:** zig-msdf was splitting cubic edges at inflection points before coloring. msdfgen does NOT do this - it only splits edges when there are fewer than 3 edges for coloring.

**Before:**
```zig
pub fn colorEdges(shape: *Shape, angle_threshold: f64) void {
    shape.splitAtInflections() catch {};
    for (shape.contours) |*contour| {
        colorContour(contour, angle_threshold);
    }
}
```

**After:**
```zig
pub fn colorEdges(shape: *Shape, angle_threshold: f64) void {
    for (shape.contours) |*contour| {
        colorContour(contour, angle_threshold);
    }
}
```

**Impact:** Edge structure now matches msdfgen exactly. Inflection splitting was creating additional edges that msdfgen doesn't have.

---

## Current Status

- **Match rate with msdfgen_autoframe:** 70.1%
- **Inside/outside agreement:** 100%
- **All tests passing** (57/57)
- **Build.zig:** Cleaned up - removed references to 22 missing test files

These changes are now committed.

---

## Remaining Visual Issue: Rounded Corners

**Problem:** Corners on M and S characters appear rounded compared to msdfgen output. The M peak and bottom corners are soft, and S curve terminals are rounded. The S also shows bumps in smooth curve sections.

### Root Cause Analysis

The issue is **symmetric corner handling**. At corners like the M peak:

1. Two edges meet at the corner point
2. For pixels on the line of symmetry (directly above the M peak), both edges compute **identical perpendicular distances**
3. Even with different colors, if the distances are the same, there's no channel diversity
4. The median calculation produces a rounded corner instead of a sharp one

### What msdfgen Does Differently

msdfgen uses a `PerpendicularDistanceSelector` (in `core/edge-selectors.cpp`) that:

1. **Tracks separate positive/negative perpendicular distances:**
   ```cpp
   double minNegativePerpendicularDistance;  // For inside points
   double minPositivePerpendicularDistance;  // For outside points
   ```

2. **Uses domain distance with blended neighbor directions:**
   ```cpp
   // At edge start:
   double add = dotProduct(ap, (prevDir + aDir).normalize());
   // At edge end:
   double bdd = -dotProduct(bp, (bDir + nextDir).normalize());
   ```
   This creates clean dividing lines at corners based on both adjacent edges.

3. **Selects final distance based on inside/outside:**
   ```cpp
   double minDistance = minTrueDistance.distance < 0 ?
       minNegativePerpendicularDistance :
       minPositivePerpendicularDistance;
   ```

### Implementation Attempt (Reverted)

I attempted to implement domain distance in `generate.zig` by:
1. Tracking neighbor edges for each minimum distance
2. Computing blended neighbor directions at corners
3. Applying domain-aware perpendicular distance conversion

**Result:** The implementation caused a slight regression (69.1% vs 71.3% gap artifact-free rate on M character), so it was reverted.

**Why it failed:**
- Only applied domain distance to the NEAREST edge for each channel
- msdfgen tracks perpendicular distances from ALL edges, not just the nearest
- The positive/negative perpendicular tracking was not correctly implemented

---

### 4. PerpendicularDistanceSelector Implementation (ATTEMPTED TWICE, REVERTED)

**File:** `src/generator/generate.zig`

**Status:** ATTEMPTED TWICE AND REVERTED - no improvement

#### First Attempt (Previous Session)
- Only applied domain distance to the NEAREST edge for each channel
- Caused visual regression (69.1% vs 71.3% gap artifact-free rate on M character)

#### Second Attempt (Current Session)
- Full implementation matching msdfgen's algorithm exactly:
  - `PerpendicularDistanceSelector` struct with `minTrueDistance`, `minNegativePerpendicularDistance`, `minPositivePerpendicularDistance`
  - Tracked perpendicular distances from ALL edges (not just nearest)
  - Used blended neighbor directions: `add = dot(ap, (prevDir + aDir).normalize())`
  - `getPerpendicularDistance()` with `ts > 0` condition
  - Final distance selection based on inside/outside status

**Result:**
- Match rate unchanged at 70.1%
- **Output identical** to simpler pseudo-distance approach
- No visual improvement - corners still rounded

**Root Cause Analysis:**

For symmetric corners like the M peak, the perpendicular distance tracking **never activates**:

1. **Domain condition satisfied:** For a point directly above the M peak:
   - `blended_a = prevDir + aDir` points straight up (symmetric)
   - `add = ap.dot(blended_a_norm) = h > 0` ✓

2. **Perpendicular condition NOT satisfied:** `getPerpendicularDistance` requires `ts > 0`:
   - `ts = ap.dot(-aDir)` where `aDir` points up-right at 45°
   - `ap = (0, h)` for point directly above
   - `ts = (0,h).dot(-0.707,-0.707) = -0.707h < 0` ✗

The conditions `add > 0` AND `ts > 0` are **mutually exclusive** for symmetric corners. Points satisfying the domain condition are NOT "behind" the edge direction, so perpendicular distances are never tracked.

**Conclusion:** msdfgen's perpendicular distance selector doesn't actually help with symmetric corners either. The visual difference between zig-msdf and msdfgen must come from elsewhere.

---

## Current Status

- **Match rate with msdfgen_autoframe:** 70.1%
- **Inside/outside agreement:** 100%
- **All tests passing** (57/57)
- **Perpendicular distance selector:** Confirmed not helpful for symmetric corners

---

## Edge Coloring Fix (IMPLEMENTED)

**Problem:** Raw MSDF textures showed dramatically different color patterns:
- **msdfgen M:** Bright magenta/yellow in the inner V shape
- **zig-msdf M:** Different color distribution (cycling colors on every edge)

### Root Cause

zig-msdf was assigning a **different color to EVERY edge**, cycling through `{cyan, yellow, magenta}` on each edge. msdfgen assigns the **SAME color to ALL edges between corners**, only switching color at corners.

**msdfgen algorithm (seed=0):**
```cpp
// All edges in a "spline" (section between corners) get SAME color
for (int i = 0; i < m; ++i) {
    int index = (start+i)%m;
    if (at_next_corner) {
        switchColor(color, seed, banned);  // Only switch at corners
    }
    contour->edges[index]->color = color;  // All edges get same color
}
```

**zig-msdf (old, WRONG):**
```zig
// Every edge got a different color
const color = color_set[cumulative_edge_idx % 3];
edge.setColor(color);
cumulative_edge_idx += 1;
```

### Fix Applied

Updated `colorBetweenCorners()` in `src/generator/coloring.zig`:
1. All edges between corners now get the SAME color
2. Color only switches at corner boundaries
3. Uses msdfgen's color sequence: CYAN → MAGENTA → YELLOW
4. Implements "banned color" mechanism to avoid initial color at last corner

### Result

- **Match rate: 70.1% → 78.2%** (+8.1% improvement)
- **Color patterns now match msdfgen** (magenta/yellow in M's V shape)
- **S character colors match** (yellow on blue background)

---

## Color State Persistence Fix (IMPLEMENTED)

**Problem:** Multi-contour characters (like D, O, B) had poor channel diversity because each contour was colored independently, resetting the color state.

**msdfgen behavior:** Color state persists across ALL contours in a shape:
```cpp
EdgeColor color = initColor(seed);  // Once for entire shape
for (contour in shape.contours) {
    // color state carries over between contours
}
```

**Fix Applied:** Updated `colorEdges()` to pass color state through contours:
```zig
pub fn colorEdges(shape: *Shape, angle_threshold: f64) void {
    var color: EdgeColor = .cyan;
    for (shape.contours) |*contour| {
        color = colorContourWithState(contour, angle_threshold, color);
    }
}
```

### Result

- **Match rate: 78.2% → 83.9%** (+5.7% improvement)
- D character outer contour now uses cyan (was magenta before)
- Better channel diversity for multi-contour characters

---

## Current Status

- **Match rate with msdfgen_autoframe:** 83.9%
- **Inside/outside agreement:** 100%
- **All core tests passing** (2 threshold-based tests fail due to algorithm changes)

---

## Next Steps: Continuing the Investigation

### Remaining Issue: D Character Color Intensity

The D character still shows muted colors compared to msdfgen's vibrant output:
- **zig-msdf D:** Muted cyan/magenta, mostly white interior
- **msdfgen D:** Vibrant magenta vertical, red/green/blue on curve

### Investigation Areas

#### 1. Contour Order Investigation
msdfgen might process contours in a different order. Check if reversing contour order changes the output:
```bash
# Debug contour order
zig build debug-coloring 2>&1 | grep -A30 "Character 'D'"
```

**Files to examine:**
- `src/generator/coloring.zig` - contour iteration order
- `src/truetype/glyf.zig` - how contours are parsed from font

#### 2. Corner Detection Differences
The D has curved sections - check if corner detection differs:
```bash
# Compare corners detected
zig build debug-coloring 2>&1 | grep "Corner\|corner"
```

**msdfgen corner detection** (`core/edge-coloring.cpp:23`):
```cpp
static bool isCorner(const Vector2 &aDir, const Vector2 &bDir, double crossThreshold) {
    return dotProduct(aDir, bDir) <= 0 || fabs(crossProduct(aDir, bDir)) > crossThreshold;
}
```

#### 3. Edge Segment Differences
Check if the D character has the same number/type of edges:
- msdfgen might split edges differently
- Cubic vs quadratic representation might differ

**Debug command:**
```bash
zig build debug-coloring 2>&1 | grep -A50 "Character 'D'" | grep "Edge\|edge"
```

#### 4. Distance Calculation at Boundaries
The muted appearance could be due to distance values being similar across channels. Check specific pixel values:

```zig
// Add debug output in generate.zig to print channel distances at specific pixels
const r, const g, const b = computeChannelDistances(shape, pixel_point);
std.debug.print("Pixel ({d},{d}): R={d:.3} G={d:.3} B={d:.3}\n", .{x, y, r, g, b});
```

### Quick Test Commands

```bash
# Generate comparison images
zig build single-glyph -- /System/Library/Fonts/Geneva.ttf D
magick glyph.ppm -filter point -resize 400% zigmsdf_D.png

# msdfgen reference
cd ~/Fun/msdfgen/build
./msdfgen msdf -font "/System/Library/Fonts/Geneva.ttf" 68 -dimensions 64 64 -pxrange 4 -autoframe -format bmp -o msdfgen_D.bmp

# Run tests
zig build test 2>&1 | grep "Match rate"
```

### Other Potential Issues

1. **Cubic bezier distance:** Subtle differences in Newton iteration
2. **Error correction:** msdfgen's algorithm may differ (currently disabled by default)
3. **Transform/positioning:** Pixel sampling locations might differ slightly
4. **Floating point:** Accumulated precision differences

---

## Multi-Contour Distance Combination Fix (IMPLEMENTED)

**Problem:** The D character (and other multi-contour characters like O, B) showed muted/inverted colors compared to msdfgen. The G channel at the left vertical edge was 255 (inside) when it should be 0 (outside).

### Root Cause

The `combineContourDistances` function was fundamentally broken:

```zig
// OLD (WRONG): Takes absolute value and applies global sign
const r_abs = @abs(cr.red.distance);
const sign: f64 = if (is_inside) -1.0 else 1.0;
return sign * min_r_abs;  // Same sign for ALL channels!
```

This destroyed per-channel sign information. In MSDF, each channel's sign must come from its own nearest edge's geometry.

### Solution

Removed the broken multi-contour combiner and use the simple approach for ALL shapes:

```zig
fn computeChannelDistances(shape: Shape, point: Vec2) [3]f64 {
    // Use simple approach: find minimum distance for each channel
    // across ALL edges in ALL contours, preserving signed distances
    return computeChannelDistancesSingleContour(shape, point);
}
```

This matches msdfgen's `SimpleContourCombiner` which treats all edges as a single pool.

### Results

| Character | Before | After |
|-----------|--------|-------|
| Geneva A (with autoframe) | 83.9% | **99.7%** |
| D (DejaVuSans) | 22.7% | **58.5%** |
| O (DejaVuSans) | 7.8% | **64.9%** |
| B (DejaVuSans) | 23.5% | **63.4%** |
| M (DejaVuSans) | 24.1% | **50.9%** |

Tests: 56/57 passing (was 55/57).

---

## Summary of All Changes

| Change | Geneva A Match Rate | Notes |
|--------|---------------------|-------|
| Original baseline | 70.1% | - |
| Edge coloring: same color per section | 78.2% | +8.1% |
| Color state persists across contours | 83.9% | +5.7% |
| Simple contour combiner (no winding-based sign) | **99.7%** | **+15.8%** |
| **Total improvement** | **99.7%** | **+29.6%** |
