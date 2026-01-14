# MSDF Inner Contour Issue - FIXED

## Summary

Characters with inner contours (holes) were showing lower inside/outside agreement compared to simple characters. The root cause was **zero-length degenerate edges** in the TrueType glyph parsing.

## Root Cause

The glyf parser was creating degenerate quadratic edges where `start == end`:

```
Edge 1: quadratic (277,167) -> (277,167) len=0.00
Edge 4: quadratic (277,1385) -> (277,1385) len=0.00
```

These degenerate edges caused unreliable sign calculations because:
1. The direction/tangent vector approaches zero
2. Cross product becomes numerically unstable
3. The sign becomes essentially random

## Fix Applied

Added filtering in `src/truetype/glyf.zig` to skip degenerate edges where start equals end:

```zig
// Skip degenerate edges where start equals end
if (!current.approxEqual(end_point, 1e-10)) {
    try edge_list.append(allocator, .{ .quadratic = ... });
}
```

This filter was added at all 3 locations where quadratic edges are created during contour parsing.

## Results

Before fix:
- 'A' (no hole): 99.8% inside/outside agreement
- 'B' (has hole): 94.5%
- 'O' (has hole): 83.4%
- '0' (has hole): 83.1%
- '@' (has hole): 92.5%

After fix:
- 'A' (no hole): 99.8%
- 'B' (has hole): 99.9%
- 'O' (has hole): **100.0%**
- '0' (has hole): **100.0%**
- '@' (has hole): 99.8%

## Sign Convention (Confirmed Correct)

The sign calculation in `edge.zig` is correct and matches msdfgen:

```zig
// Convention: cross < 0 means inside → negative distance
const sign: f64 = if (dir.cross(aq) < 0) -1.0 else 1.0;
```

This produces:
- **Negative distance** → inside glyph → bright pixels (high values)
- **Positive distance** → outside glyph → dark pixels (low values)

## Files Modified

- `src/truetype/glyf.zig` - Added degenerate edge filtering at lines 397-400, 411-414, 424-427
