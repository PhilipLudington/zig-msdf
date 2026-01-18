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

## Current Status

- **Match rate with msdfgen_autoframe:** 78.2%
- **Inside/outside agreement:** 100%
- **Color patterns:** Match msdfgen

---

## Remaining Investigation Areas

The 22% mismatch could be due to:

1. **Cubic bezier distance:** Subtle differences in Newton iteration or endpoint handling
2. **Error correction:** msdfgen's error correction algorithm may differ
3. **Floating point:** Accumulated precision differences
4. **Transform/positioning:** Pixel sampling locations might differ slightly

The simple pseudo-distance approach (nearest edge only) works identically to the full perpendicular distance selector for this codebase.
