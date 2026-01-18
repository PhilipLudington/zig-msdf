# zig-msdf vs msdfgen Alignment Changes

This document summarizes the changes made to reduce differences between zig-msdf and the reference msdfgen implementation.

## Changes Made (Uncommitted)

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

The uncommitted changes above do NOT significantly affect visual quality or test metrics.

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

### 4. PerpendicularDistanceSelector Implementation (REVERTED)

**File:** `src/generator/generate.zig`

**Status:** ATTEMPTED AND REVERTED - caused visual regression

**What was implemented:**
- PerpendicularDistanceSelector struct matching msdfgen's algorithm
- Tracked perpendicular distances from ALL edges (not just nearest)
- Used blended neighbor directions for domain computation
- Tracked separate positive/negative perpendicular distances

**Result:**
- Match rate unchanged at 70.1% (metrics didn't improve)
- Visual regression: bigger rounded corners and more imperfections
- Implementation reverted to original `computeChannelDistancesSingleContour`

**Analysis:**

For symmetric corners like the M peak, the perpendicular distance tracking conditions are rarely satisfied:

1. **Domain condition (`add > 0`):** Blended direction at symmetric corners is horizontal, so points above/below have `add ≈ 0`

2. **Direction condition (`ts > 0`):** Points must be "behind" the edge direction, which conflicts with the domain condition for inside points

The implementation was technically correct but:
- Didn't trigger perpendicular distance tracking in most cases (fell back to `distanceToPseudoDistance`)
- When it did trigger, it may have produced worse results than the simpler nearest-edge approach

---

## Current Status

- **Match rate with msdfgen_autoframe:** 70.1%
- **Inside/outside agreement:** 100%
- **All tests passing** (57/57)

## Files with Uncommitted Changes

1. `src/generator/math.zig` - SignedDistance exact equality
2. `src/generator/edge.zig` - Cubic distance algorithm
3. `src/generator/coloring.zig` - Removed inflection point splitting

---

## Remaining Investigation Areas

The 30% mismatch could be due to:

1. **Cubic bezier distance:** Subtle differences in Newton iteration or endpoint handling
2. **Error correction:** msdfgen's error correction algorithm may differ
3. **Edge coloring:** Color assignment at corners may vary
4. **Floating point:** Accumulated precision differences

The simple pseudo-distance approach (nearest edge only) appears to work better visually than the full perpendicular distance selector for this codebase.
