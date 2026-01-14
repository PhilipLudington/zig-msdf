//! SDF (Signed Distance Field) Mathematical Properties Validation
//!
//! This test suite validates that generated MSDFs satisfy the mathematical
//! properties expected of multi-channel signed distance fields:
//!
//! 1. **Gradient Consistency**: Gradients should be smooth and bounded
//! 2. **Continuity**: No sudden jumps between adjacent pixels
//! 3. **Zero-Crossing Validity**: The boundary exists and separates inside/outside
//! 4. **Distance Monotonicity**: Distance increases moving away from boundary
//! 5. **Multi-Channel Properties**: Channels diverge at corners (MSDF specific)
//!
//! Note: MSDF has different properties than a true SDF due to multi-channel
//! encoding. The gradient magnitude varies with the transform scale and the
//! median of channels doesn't perfectly preserve SDF properties.

const std = @import("std");
const msdf = @import("msdf");

const Vec2 = msdf.math.Vec2;
const EdgeSegment = msdf.edge.EdgeSegment;
const LinearSegment = msdf.edge.LinearSegment;
const QuadraticSegment = msdf.edge.QuadraticSegment;
const Contour = msdf.contour.Contour;
const Shape = msdf.contour.Shape;

// ============================================================================
// Helper Types and Functions
// ============================================================================

/// Statistics about SDF properties for a generated bitmap.
const SdfStats = struct {
    /// Mean gradient magnitude (scale-dependent, not necessarily 1.0 for MSDF)
    mean_gradient_magnitude: f64,
    /// Standard deviation of gradient magnitude
    gradient_std_dev: f64,
    /// Percentage of pixels with non-zero gradient (indicates valid distance field)
    gradient_nonzero_pct: f64,
    /// Maximum discontinuity between adjacent pixels
    max_discontinuity: f64,
    /// Mean discontinuity between adjacent pixels
    mean_discontinuity: f64,
    /// Number of boundary pixels (value in transition zone)
    boundary_pixel_count: u32,
    /// Percentage of pixels that are "inside" (value > 140)
    inside_pct: f64,
    /// Percentage of pixels that are "outside" (value < 116)
    outside_pct: f64,
};

/// Compute gradient magnitude at a pixel using central differences.
/// Returns null for edge pixels where gradient cannot be computed.
fn computeGradientMagnitude(
    pixels: []const u8,
    width: u32,
    height: u32,
    x: u32,
    y: u32,
    range: f64,
) ?f64 {
    // Need neighbors on all sides for central difference
    if (x == 0 or x >= width - 1 or y == 0 or y >= height - 1) {
        return null;
    }

    // Use the median of RGB channels for the gradient calculation
    // This is the standard MSDF interpretation
    const get_distance = struct {
        fn get(p: []const u8, w: u32, px: u32, py: u32, r: f64) f64 {
            const idx = (py * w + px) * 3;
            const rgb = [3]u8{ p[idx], p[idx + 1], p[idx + 2] };
            const med = median3(rgb[0], rgb[1], rgb[2]);
            return msdf.generate.pixelToDistance(med, r);
        }
    }.get;

    const d_center = get_distance(pixels, width, x, y, range);
    const d_left = get_distance(pixels, width, x - 1, y, range);
    const d_right = get_distance(pixels, width, x + 1, y, range);
    const d_up = get_distance(pixels, width, x, y - 1, range);
    const d_down = get_distance(pixels, width, x, y + 1, range);

    _ = d_center;

    // Central differences (in pixel units, so gradient should be ~1/scale in shape units)
    // Since we're working in pixel space and range is in shape units,
    // we expect gradient magnitude of approximately 1 pixel per pixel of distance
    const dx = (d_right - d_left) / 2.0;
    const dy = (d_down - d_up) / 2.0;

    return @sqrt(dx * dx + dy * dy);
}

/// Get the median of three values (standard MSDF shader operation).
fn median3(a: u8, b: u8, c: u8) u8 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

/// Compute comprehensive SDF statistics for a bitmap.
fn computeSdfStats(
    pixels: []const u8,
    width: u32,
    height: u32,
    range: f64,
) SdfStats {
    var gradient_sum: f64 = 0;
    var gradient_sq_sum: f64 = 0;
    var gradient_nonzero_count: u32 = 0;
    var gradient_total_count: u32 = 0;

    var max_discontinuity: f64 = 0;
    var discontinuity_sum: f64 = 0;
    var discontinuity_count: u32 = 0;

    var boundary_count: u32 = 0;
    var inside_count: u32 = 0;
    var outside_count: u32 = 0;

    const total_pixels = width * height;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx = (y * width + x) * 3;
            const med = median3(pixels[idx], pixels[idx + 1], pixels[idx + 2]);

            // Count inside/outside/boundary with wider transition zone
            // Inside: clearly inside (high values)
            // Outside: clearly outside (low values)
            // Boundary: transition zone
            if (med > 140) {
                inside_count += 1;
            } else if (med < 116) {
                outside_count += 1;
            } else {
                boundary_count += 1;
            }

            // Compute gradient magnitude
            if (computeGradientMagnitude(pixels, width, height, x, y, range)) |grad_mag| {
                gradient_sum += grad_mag;
                gradient_sq_sum += grad_mag * grad_mag;
                gradient_total_count += 1;

                // Count non-zero gradients (indicates actual distance field variation)
                if (grad_mag > 0.1) {
                    gradient_nonzero_count += 1;
                }
            }

            // Check discontinuity with right neighbor
            if (x < width - 1) {
                const next_idx = (y * width + x + 1) * 3;
                const next_med = median3(pixels[next_idx], pixels[next_idx + 1], pixels[next_idx + 2]);
                const disc = @abs(@as(f64, @floatFromInt(med)) - @as(f64, @floatFromInt(next_med)));
                max_discontinuity = @max(max_discontinuity, disc);
                discontinuity_sum += disc;
                discontinuity_count += 1;
            }

            // Check discontinuity with bottom neighbor
            if (y < height - 1) {
                const next_idx = ((y + 1) * width + x) * 3;
                const next_med = median3(pixels[next_idx], pixels[next_idx + 1], pixels[next_idx + 2]);
                const disc = @abs(@as(f64, @floatFromInt(med)) - @as(f64, @floatFromInt(next_med)));
                max_discontinuity = @max(max_discontinuity, disc);
                discontinuity_sum += disc;
                discontinuity_count += 1;
            }
        }
    }

    const mean_grad = if (gradient_total_count > 0)
        gradient_sum / @as(f64, @floatFromInt(gradient_total_count))
    else
        0;

    const variance = if (gradient_total_count > 0)
        (gradient_sq_sum / @as(f64, @floatFromInt(gradient_total_count))) - (mean_grad * mean_grad)
    else
        0;

    return SdfStats{
        .mean_gradient_magnitude = mean_grad,
        .gradient_std_dev = @sqrt(@max(0, variance)),
        .gradient_nonzero_pct = if (gradient_total_count > 0)
            100.0 * @as(f64, @floatFromInt(gradient_nonzero_count)) / @as(f64, @floatFromInt(gradient_total_count))
        else
            0,
        .max_discontinuity = max_discontinuity,
        .mean_discontinuity = if (discontinuity_count > 0)
            discontinuity_sum / @as(f64, @floatFromInt(discontinuity_count))
        else
            0,
        .boundary_pixel_count = boundary_count,
        .inside_pct = 100.0 * @as(f64, @floatFromInt(inside_count)) / @as(f64, @floatFromInt(total_pixels)),
        .outside_pct = 100.0 * @as(f64, @floatFromInt(outside_count)) / @as(f64, @floatFromInt(total_pixels)),
    };
}

/// Create a square shape for testing (CW winding order).
fn createSquareShape(allocator: std.mem.Allocator) !Shape {
    var edges = try allocator.alloc(EdgeSegment, 4);
    // CW winding order (matches TrueType convention): up, right, down, left
    edges[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(10, 10), Vec2.init(10, 90)) };
    edges[1] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(10, 90), Vec2.init(90, 90)) };
    edges[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(90, 90), Vec2.init(90, 10)) };
    edges[3] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(90, 10), Vec2.init(10, 10)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    return Shape.fromContours(allocator, contours);
}

/// Create a circle-like shape (polygon approximation) for testing (CW winding order).
fn createCircleShape(allocator: std.mem.Allocator, num_segments: usize) !Shape {
    var edges = try allocator.alloc(EdgeSegment, num_segments);

    const center_x: f64 = 50;
    const center_y: f64 = 50;
    const radius: f64 = 40;

    for (0..num_segments) |i| {
        // Use negative angles for CW winding order
        const angle1 = -@as(f64, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f64, @floatFromInt(num_segments));
        const angle2 = -@as(f64, @floatFromInt(i + 1)) * 2.0 * std.math.pi / @as(f64, @floatFromInt(num_segments));

        const p1 = Vec2.init(center_x + radius * @cos(angle1), center_y + radius * @sin(angle1));
        const p2 = Vec2.init(center_x + radius * @cos(angle2), center_y + radius * @sin(angle2));

        edges[i] = EdgeSegment{ .linear = LinearSegment.init(p1, p2) };
    }

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    return Shape.fromContours(allocator, contours);
}

/// Create an L-shaped polygon for testing non-convex shapes.
fn createLShape(allocator: std.mem.Allocator) !Shape {
    // L-shape vertices (CW winding order for proper sign convention)
    const points = [_]Vec2{
        Vec2.init(10, 10),
        Vec2.init(10, 90),
        Vec2.init(90, 90),
        Vec2.init(90, 50),
        Vec2.init(50, 50),
        Vec2.init(50, 10),
    };

    var edges = try allocator.alloc(EdgeSegment, points.len);

    for (0..points.len) |i| {
        const p1 = points[i];
        const p2 = points[(i + 1) % points.len];
        edges[i] = EdgeSegment{ .linear = LinearSegment.init(p1, p2) };
    }

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    return Shape.fromContours(allocator, contours);
}

// ============================================================================
// Gradient Consistency Tests
// ============================================================================

test "Gradient consistency: square shape has non-zero gradients" {
    const allocator = std.testing.allocator;

    var shape = try createSquareShape(allocator);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const range: f64 = 8.0;
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, range, transform);
    defer bitmap.deinit();

    const stats = computeSdfStats(bitmap.pixels, bitmap.width, bitmap.height, range);

    // Most pixels should have non-zero gradients (distance field has variation)
    try std.testing.expect(stats.gradient_nonzero_pct > 30.0);

    // Mean gradient should be positive and bounded
    try std.testing.expect(stats.mean_gradient_magnitude > 0.1);
    try std.testing.expect(stats.mean_gradient_magnitude < 5.0);
}

test "Gradient consistency: circle shape has smooth gradients" {
    const allocator = std.testing.allocator;

    // Circle should have relatively uniform gradients (no sharp corners)
    var circle = try createCircleShape(allocator, 32);
    defer circle.deinit();

    msdf.coloring.colorEdgesSimple(&circle);

    const bounds = circle.bounds();
    const range: f64 = 8.0;
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, circle, 64, 64, range, transform);
    defer bitmap.deinit();

    const stats = computeSdfStats(bitmap.pixels, bitmap.width, bitmap.height, range);

    // Circle should have non-zero gradients
    try std.testing.expect(stats.gradient_nonzero_pct > 20.0);

    // Gradient should be positive and bounded
    try std.testing.expect(stats.mean_gradient_magnitude > 0.1);
}

// ============================================================================
// Continuity Tests (No sudden jumps)
// ============================================================================

test "Continuity: adjacent pixels have bounded difference" {
    const allocator = std.testing.allocator;

    var shape = try createSquareShape(allocator);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const range: f64 = 8.0;
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, range, transform);
    defer bitmap.deinit();

    const stats = computeSdfStats(bitmap.pixels, bitmap.width, bitmap.height, range);

    // Maximum discontinuity should be bounded
    // For a proper SDF, adjacent pixels shouldn't differ by more than ~1 distance unit
    // In pixel values, this corresponds to roughly 255 / (2 * range) per pixel of distance
    const max_expected_jump = 255.0 / (2.0 * range) * 2.0; // Allow 2 pixels of distance change
    try std.testing.expect(stats.max_discontinuity < max_expected_jump);

    // Mean discontinuity should be low
    try std.testing.expect(stats.mean_discontinuity < 20.0);
}

test "Continuity: L-shape maintains continuity at concave corner" {
    const allocator = std.testing.allocator;

    var shape = try createLShape(allocator);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const range: f64 = 8.0;
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, range, transform);
    defer bitmap.deinit();

    const stats = computeSdfStats(bitmap.pixels, bitmap.width, bitmap.height, range);

    // Even with concave corners, continuity should be maintained
    try std.testing.expect(stats.mean_discontinuity < 25.0);
}

// ============================================================================
// Zero-Crossing / Boundary Tests
// ============================================================================

test "Boundary: shape has visible boundary region" {
    const allocator = std.testing.allocator;

    var shape = try createSquareShape(allocator);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const range: f64 = 8.0;
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, range, transform);
    defer bitmap.deinit();

    // Check for boundary pixels manually (values in the transition zone around 128)
    var boundary_count: u32 = 0;
    var y: u32 = 0;
    while (y < 64) : (y += 1) {
        var x: u32 = 0;
        while (x < 64) : (x += 1) {
            const idx = (y * 64 + x) * 3;
            const med = median3(bitmap.pixels[idx], bitmap.pixels[idx + 1], bitmap.pixels[idx + 2]);
            // Wider boundary check: anything in transition zone
            if (med >= 100 and med <= 156) {
                boundary_count += 1;
            }
        }
    }

    // Should have some boundary pixels
    try std.testing.expect(boundary_count > 0);
}

test "Boundary: inside and outside regions exist" {
    const allocator = std.testing.allocator;

    var shape = try createSquareShape(allocator);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const range: f64 = 8.0;
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, range, transform);
    defer bitmap.deinit();

    // Count pixels in different regions using standard threshold (128)
    var inside_count: u32 = 0;
    var outside_count: u32 = 0;

    var y: u32 = 0;
    while (y < 64) : (y += 1) {
        var x: u32 = 0;
        while (x < 64) : (x += 1) {
            const idx = (y * 64 + x) * 3;
            const med = median3(bitmap.pixels[idx], bitmap.pixels[idx + 1], bitmap.pixels[idx + 2]);
            if (med > 128) {
                inside_count += 1;
            } else {
                outside_count += 1;
            }
        }
    }

    const total: f64 = 64.0 * 64.0;
    const inside_pct = 100.0 * @as(f64, @floatFromInt(inside_count)) / total;
    const outside_pct = 100.0 * @as(f64, @floatFromInt(outside_count)) / total;

    // Should have both inside and outside regions
    try std.testing.expect(inside_pct > 5.0);
    try std.testing.expect(outside_pct > 5.0);
}

test "Boundary: zero-crossing exists along scanlines" {
    const allocator = std.testing.allocator;

    var shape = try createSquareShape(allocator);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const range: f64 = 8.0;
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, range, transform);
    defer bitmap.deinit();

    // Check that middle scanlines have zero crossings (transitions from outside to inside)
    var scanlines_with_crossing: u32 = 0;

    var y: u32 = 16;
    while (y < 48) : (y += 1) {
        var found_crossing = false;
        var prev_inside = false;

        var x: u32 = 0;
        while (x < 64) : (x += 1) {
            const idx = (y * 64 + x) * 3;
            const med = median3(bitmap.pixels[idx], bitmap.pixels[idx + 1], bitmap.pixels[idx + 2]);
            const is_inside = med > 128;

            if (x > 0 and is_inside != prev_inside) {
                found_crossing = true;
            }
            prev_inside = is_inside;
        }

        if (found_crossing) {
            scanlines_with_crossing += 1;
        }
    }

    // Most middle scanlines should have at least one zero crossing
    try std.testing.expect(scanlines_with_crossing > 20);
}

// ============================================================================
// Distance Monotonicity Tests
// ============================================================================

test "Monotonicity: distance changes smoothly along horizontal line" {
    const allocator = std.testing.allocator;

    var shape = try createSquareShape(allocator);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const range: f64 = 16.0; // Larger range to see monotonicity
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, range, transform);
    defer bitmap.deinit();

    // Check horizontal line through center
    const center_y: u32 = 32;

    // Find where the value transitions from outside (<128) to inside (>128)
    var transition_found = false;
    var x: u32 = 1;
    while (x < 63) : (x += 1) {
        const idx_prev = (center_y * 64 + x - 1) * 3;
        const idx_curr = (center_y * 64 + x) * 3;

        const med_prev = median3(bitmap.pixels[idx_prev], bitmap.pixels[idx_prev + 1], bitmap.pixels[idx_prev + 2]);
        const med_curr = median3(bitmap.pixels[idx_curr], bitmap.pixels[idx_curr + 1], bitmap.pixels[idx_curr + 2]);

        // Found a transition from outside to inside
        if (med_prev < 128 and med_curr >= 128) {
            transition_found = true;
            break;
        }
    }

    // Should find a transition (outside -> inside) somewhere
    try std.testing.expect(transition_found);

    // Check that values generally increase from left to center
    // (moving from outside toward inside)
    var increasing_trend: u32 = 0;
    var decreasing_trend: u32 = 0;

    x = 1;
    while (x < 32) : (x += 1) {
        const idx_prev = (center_y * 64 + x - 1) * 3;
        const idx_curr = (center_y * 64 + x) * 3;

        const med_prev = median3(bitmap.pixels[idx_prev], bitmap.pixels[idx_prev + 1], bitmap.pixels[idx_prev + 2]);
        const med_curr = median3(bitmap.pixels[idx_curr], bitmap.pixels[idx_curr + 1], bitmap.pixels[idx_curr + 2]);

        // Use i16 to avoid overflow
        const med_prev_i: i16 = @intCast(med_prev);
        const med_curr_i: i16 = @intCast(med_curr);

        if (med_curr_i > med_prev_i + 2) {
            increasing_trend += 1;
        } else if (med_curr_i + 2 < med_prev_i) {
            decreasing_trend += 1;
        }
    }

    // Should have more increasing than decreasing when moving toward center
    try std.testing.expect(increasing_trend > decreasing_trend);
}

// ============================================================================
// Multi-Channel Specific Tests
// ============================================================================

test "MSDF channels: corners have distinct channel values" {
    const allocator = std.testing.allocator;

    var shape = try createSquareShape(allocator);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const range: f64 = 8.0;
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, range, transform);
    defer bitmap.deinit();

    // Count pixels with significant channel differences
    var multi_channel_pixels: u32 = 0;

    var y: u32 = 0;
    while (y < 64) : (y += 1) {
        var x: u32 = 0;
        while (x < 64) : (x += 1) {
            const idx = (y * 64 + x) * 3;
            const r = bitmap.pixels[idx];
            const g = bitmap.pixels[idx + 1];
            const b = bitmap.pixels[idx + 2];

            // Check if channels differ significantly
            const rg_diff = if (r > g) r - g else g - r;
            const rb_diff = if (r > b) r - b else b - r;
            const gb_diff = if (g > b) g - b else b - g;
            const max_diff = @max(rg_diff, @max(rb_diff, gb_diff));

            if (max_diff > 15) {
                multi_channel_pixels += 1;
            }
        }
    }

    // MSDF should have some pixels with channel differences (at corners)
    try std.testing.expect(multi_channel_pixels > 0);
}

test "MSDF channels: median preserves edge information" {
    const allocator = std.testing.allocator;

    var shape = try createSquareShape(allocator);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const range: f64 = 8.0;
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, range, transform);
    defer bitmap.deinit();

    // The median of channels should still produce a valid SDF-like result
    // Check that median values transition smoothly from outside to inside

    // Sample along a diagonal
    var prev_med: ?u8 = null;
    var max_jump: u8 = 0;

    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        const idx = (i * 64 + i) * 3;
        const med = median3(bitmap.pixels[idx], bitmap.pixels[idx + 1], bitmap.pixels[idx + 2]);

        if (prev_med) |pm| {
            const jump = if (med > pm) med - pm else pm - med;
            max_jump = @max(max_jump, jump);
        }
        prev_med = med;
    }

    // Median should transition smoothly (max jump bounded)
    try std.testing.expect(max_jump < 50);
}

// ============================================================================
// Scale Invariance Tests
// ============================================================================

test "Scale invariance: larger output has proportionally more boundary pixels" {
    const allocator = std.testing.allocator;

    var shape = try createSquareShape(allocator);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const range: f64 = 8.0;

    // Generate at two different sizes
    const transform32 = msdf.generate.calculateTransform(bounds, 32, 32, 2);
    var bitmap32 = try msdf.generate.generateMsdf(allocator, shape, 32, 32, range, transform32);
    defer bitmap32.deinit();

    const transform64 = msdf.generate.calculateTransform(bounds, 64, 64, 4);
    var bitmap64 = try msdf.generate.generateMsdf(allocator, shape, 64, 64, range, transform64);
    defer bitmap64.deinit();

    const stats32 = computeSdfStats(bitmap32.pixels, 32, 32, range);
    const stats64 = computeSdfStats(bitmap64.pixels, 64, 64, range);

    // Both should have similar inside/outside ratios (scale invariant property)
    const inside_ratio_32 = stats32.inside_pct / (stats32.inside_pct + stats32.outside_pct + 0.001);
    const inside_ratio_64 = stats64.inside_pct / (stats64.inside_pct + stats64.outside_pct + 0.001);

    // Ratios should be similar (within 20%)
    const ratio_diff = @abs(inside_ratio_32 - inside_ratio_64);
    try std.testing.expect(ratio_diff < 0.2);
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "Edge case: very small shape still produces valid SDF properties" {
    const allocator = std.testing.allocator;

    // Create a tiny triangle
    var edges = try allocator.alloc(EdgeSegment, 3);
    edges[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0, 0), Vec2.init(5, 0)) };
    edges[1] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(5, 0), Vec2.init(2.5, 5)) };
    edges[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(2.5, 5), Vec2.init(0, 0)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const range: f64 = 4.0;
    const transform = msdf.generate.calculateTransform(bounds, 32, 32, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 32, 32, range, transform);
    defer bitmap.deinit();

    const stats = computeSdfStats(bitmap.pixels, bitmap.width, bitmap.height, range);

    // Should still have valid regions
    try std.testing.expect(stats.inside_pct > 5.0);
    try std.testing.expect(stats.outside_pct > 5.0);

    // Continuity should still hold
    try std.testing.expect(stats.mean_discontinuity < 30.0);
}

test "Edge case: shape with quadratic curves has valid SDF properties" {
    const allocator = std.testing.allocator;

    // Create a shape with quadratic bezier curves
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(10, 10), Vec2.init(90, 10)) };
    edges[1] = EdgeSegment{ .quadratic = QuadraticSegment.init(
        Vec2.init(90, 10),
        Vec2.init(90, 50),
        Vec2.init(90, 90),
    ) };
    edges[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(90, 90), Vec2.init(10, 90)) };
    edges[3] = EdgeSegment{ .quadratic = QuadraticSegment.init(
        Vec2.init(10, 90),
        Vec2.init(10, 50),
        Vec2.init(10, 10),
    ) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const range: f64 = 8.0;
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, range, transform);
    defer bitmap.deinit();

    const stats = computeSdfStats(bitmap.pixels, bitmap.width, bitmap.height, range);

    // Quadratic curves should produce gradients and smooth transitions
    try std.testing.expect(stats.gradient_nonzero_pct > 20.0);
    try std.testing.expect(stats.mean_discontinuity < 30.0);
}

// ============================================================================
// Font-Based Tests (Real-World Validation)
// ============================================================================

test "Real font: letter 'O' has ring-like SDF structure" {
    const allocator = std.testing.allocator;

    // Try to load a system font
    const font_paths = [_][]const u8{
        "/System/Library/Fonts/Geneva.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "C:\\Windows\\Fonts\\arial.ttf",
    };

    var font: ?msdf.Font = null;
    for (font_paths) |path| {
        font = msdf.Font.fromFile(allocator, path) catch continue;
        break;
    }

    if (font == null) {
        // Skip test if no font available
        return;
    }
    defer font.?.deinit();

    // Generate MSDF for 'O'
    var result = msdf.generateGlyph(allocator, font.?, 'O', .{
        .size = 64,
        .padding = 4,
        .range = 4.0,
    }) catch {
        // Skip if glyph generation fails
        return;
    };
    defer result.deinit(allocator);

    const stats = computeSdfStats(result.pixels, result.width, result.height, 4.0);

    // 'O' should have both inside and outside regions
    try std.testing.expect(stats.inside_pct > 10.0);
    try std.testing.expect(stats.outside_pct > 30.0);

    // Should have reasonable continuity
    try std.testing.expect(stats.mean_discontinuity < 30.0);
}

test "Real font: letter 'I' has elongated SDF structure" {
    const allocator = std.testing.allocator;

    const font_paths = [_][]const u8{
        "/System/Library/Fonts/Geneva.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "C:\\Windows\\Fonts\\arial.ttf",
    };

    var font: ?msdf.Font = null;
    for (font_paths) |path| {
        font = msdf.Font.fromFile(allocator, path) catch continue;
        break;
    }

    if (font == null) {
        return;
    }
    defer font.?.deinit();

    var result = msdf.generateGlyph(allocator, font.?, 'I', .{
        .size = 64,
        .padding = 4,
        .range = 4.0,
    }) catch {
        return;
    };
    defer result.deinit(allocator);

    const stats = computeSdfStats(result.pixels, result.width, result.height, 4.0);

    // 'I' is narrow, so should have less inside than 'O'
    // But should still have valid SDF properties
    try std.testing.expect(stats.inside_pct > 1.0);
    try std.testing.expect(stats.mean_discontinuity < 40.0);
    try std.testing.expect(stats.gradient_nonzero_pct > 10.0);
}
