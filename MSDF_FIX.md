# MSDF Sign Handling Fix

## Problem Summary

The zig-msdf library produces incorrect glyph rendering because it destroys per-edge sign information when computing signed distances. This causes glyphs to appear as wrong characters (e.g., lowercase 'a' renders as uppercase 'A').

## Current Broken Code

Location: `zig-msdf/src/generator/generate.zig` lines 217-237

```zig
// Determine inside/outside using winding number
const winding = computeWinding(shape, point);
const inside = winding != 0;

var r_dist = distances[0];
var g_dist = distances[1];
var b_dist = distances[2];

if (inside) {
    r_dist = -@abs(r_dist);  // BUG: destroys per-edge sign
    g_dist = -@abs(g_dist);
    b_dist = -@abs(b_dist);
} else {
    r_dist = @abs(r_dist);   // BUG: destroys per-edge sign
    g_dist = @abs(g_dist);
    b_dist = @abs(b_dist);
}
```

## Why This Is Wrong

### How MSDF Works

Multi-channel Signed Distance Fields encode distance to glyph edges in RGB channels:

1. **Edge Coloring**: Each edge in the glyph outline is assigned a color (R, G, B, or combinations)
2. **Per-Pixel Computation**: For each pixel, find the closest edge of each color and compute signed distance
3. **Sign Convention**: Distance is negative inside the glyph, positive outside
4. **Sharp Corners**: At corners where edges of different colors meet, the channels have DIFFERENT distances

### The Critical Insight

At a sharp corner, two edges meet. If edge A is red and edge B is green:
- A pixel near the corner might be:
  - Close to edge A (small red distance)
  - Far from edge B (large green distance)
- The SIGNS of these distances encode which side of each edge the pixel is on
- The shader uses `median(R, G, B)` to reconstruct the shape

### What `@abs()` Destroys

Taking absolute values collapses the sign information:

```
Before @abs():  R = -2.0, G = +5.0, B = +3.0  (pixel inside relative to red edge, outside relative to green/blue)
After @abs():   R = -2.0, G = -5.0, B = -3.0  (if inside) - WRONG! All channels now agree incorrectly
```

The shader's `median()` function needs the channels to DISAGREE at corners to produce sharp edges.

## Correct Algorithm

Reference: [msdfgen by Chlumsky](https://github.com/Chlumsky/msdfgen)

### Step 1: Compute True Signed Distance Per Channel

For each pixel and each color channel:
1. Find the closest edge of that color
2. Compute distance to that edge
3. Determine sign based on which side of THAT SPECIFIC EDGE the pixel is on

```zig
fn computeChannelDistances(shape: Shape, point: Vec2) [3]f64 {
    var min_r = SignedDistance.infinite;
    var min_g = SignedDistance.infinite;
    var min_b = SignedDistance.infinite;

    for (shape.contours) |contour| {
        for (contour.edges) |edge| {
            const sd = edge.signedDistance(point);

            // Update minimum for channels this edge contributes to
            // The sign comes from the edge's signedDistance(), NOT from winding
            if (edge.color.hasRed() and sd.lessThan(min_r)) {
                min_r = sd;
            }
            if (edge.color.hasGreen() and sd.lessThan(min_g)) {
                min_g = sd;
            }
            if (edge.color.hasBlue() and sd.lessThan(min_b)) {
                min_b = sd;
            }
        }
    }

    // Return the signed distances directly - DO NOT take abs() or override signs
    return .{ min_r.distance, min_g.distance, min_b.distance };
}
```

### Step 2: Edge Sign Computation

The `edge.signedDistance()` method must return a properly signed distance:
- **Positive**: Point is on the "outside" of the edge (right side when traversing)
- **Negative**: Point is on the "inside" of the edge (left side when traversing)

For a linear edge from P0 to P1:
```zig
fn signedDistance(self: Edge, point: Vec2) SignedDistance {
    const edge_vec = self.p1.sub(self.p0);
    const point_vec = point.sub(self.p0);

    // Project point onto edge to find closest point
    const t = clamp(point_vec.dot(edge_vec) / edge_vec.dot(edge_vec), 0, 1);
    const closest = self.p0.add(edge_vec.scale(t));

    // Distance magnitude
    const dist = point.sub(closest).length();

    // Sign from cross product (which side of edge is point on?)
    const cross = edge_vec.cross(point_vec);
    const sign = if (cross >= 0) 1.0 else -1.0;

    return SignedDistance{ .distance = sign * dist };
}
```

### Step 3: Do NOT Use Winding for Per-Pixel Sign

The current code uses winding number to determine inside/outside and then forces all channels to have the same sign. This is incorrect.

**Remove this code entirely:**
```zig
// DELETE THIS:
const winding = computeWinding(shape, point);
const inside = winding != 0;
if (inside) {
    r_dist = -@abs(r_dist);
    // ...
}
```

The winding number is useful for:
- Determining fill rule for the overall shape
- Handling edge cases where no edges are nearby

But it should NOT override the per-edge sign information.

### Step 4: Handle Edge Cases

When a channel has no nearby edges (infinite distance), fall back to winding:

```zig
fn computeFinalDistance(edge_dist: f64, winding: i32) f64 {
    if (edge_dist == std.math.inf(f64)) {
        // No edge of this color found - use winding to determine inside/outside
        return if (winding != 0) -std.math.inf(f64) else std.math.inf(f64);
    }
    // Use the edge's signed distance directly
    return edge_dist;
}
```

## Files to Modify

1. **`src/generator/generate.zig`**
   - Remove the `@abs()` sign override in `generateMsdf()`
   - Let `computeChannelDistances()` return true signed distances

2. **`src/generator/edge.zig`**
   - Ensure `signedDistance()` methods return correctly signed values
   - Sign should be based on cross product (which side of edge)

3. **`src/generator/contour.zig`**
   - Verify contour winding direction is consistent
   - TrueType: outer contours CCW, inner contours (holes) CW

## Testing

1. **Visual Test**: Generate atlas, render "agpkAGPK" - lowercase and uppercase should be distinct
2. **Channel Test**: Dump RGB values at corner pixels - channels should disagree
3. **Reference Comparison**: Compare output to msdfgen for same font/glyph

## References

- [msdfgen paper](https://github.com/Chlumsky/msdfgen/files/3050967/thesis.pdf) - Viktor Chlumsky's thesis
- [msdfgen source](https://github.com/Chlumsky/msdfgen/blob/master/core/edge-segments.cpp) - Reference implementation
- Specifically `SignedDistance EdgeSegment::signedDistance()` methods
