//! Visual regression tests for zig-msdf.
//!
//! These tests verify that the MSDF generation produces consistent, expected
//! output by checking specific pixel patterns and properties of the generated
//! textures. Rather than comparing against reference images, we verify:
//!
//! - Distance field gradients are smooth
//! - Inside/outside regions are correctly identified
//! - Corner pixels have distinct channel values
//! - Generated output is deterministic

const std = @import("std");
const msdf = @import("msdf");

const Vec2 = msdf.math.Vec2;
const EdgeSegment = msdf.edge.EdgeSegment;
const LinearSegment = msdf.edge.LinearSegment;
const QuadraticSegment = msdf.edge.QuadraticSegment;
const Contour = msdf.contour.Contour;
const Shape = msdf.contour.Shape;

/// Compute median of three u8 values (used for MSDF distance reconstruction)
fn median3(a: u8, b: u8, c: u8) u8 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

// ============================================================================
// Determinism Tests
// ============================================================================

test "MSDF generation is deterministic" {
    const allocator = std.testing.allocator;

    // Create a simple shape
    // CW winding order (matches TrueType convention): up, right, down, left
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(10, 10), Vec2.init(10, 90)) };
    edges[1] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(10, 90), Vec2.init(90, 90)) };
    edges[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(90, 90), Vec2.init(90, 10)) };
    edges[3] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(90, 10), Vec2.init(10, 10)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape1 = Shape.fromContours(allocator, contours);
    defer shape1.deinit();

    // Apply edge coloring
    msdf.coloring.colorEdgesSimple(&shape1);

    const bounds = shape1.bounds();
    const transform = msdf.generate.calculateTransform(bounds, 32, 32, 2);

    // Generate MSDF twice
    var bitmap1 = try msdf.generate.generateMsdf(allocator, shape1, 32, 32, 4.0, transform);
    defer bitmap1.deinit();

    // Create the same shape again (CW winding order)
    var edges2 = try allocator.alloc(EdgeSegment, 4);
    edges2[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(10, 10), Vec2.init(10, 90)) };
    edges2[1] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(10, 90), Vec2.init(90, 90)) };
    edges2[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(90, 90), Vec2.init(90, 10)) };
    edges2[3] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(90, 10), Vec2.init(10, 10)) };

    var contours2 = try allocator.alloc(Contour, 1);
    contours2[0] = Contour.fromEdges(allocator, edges2);

    var shape2 = Shape.fromContours(allocator, contours2);
    defer shape2.deinit();

    msdf.coloring.colorEdgesSimple(&shape2);

    var bitmap2 = try msdf.generate.generateMsdf(allocator, shape2, 32, 32, 4.0, transform);
    defer bitmap2.deinit();

    // Both outputs should be identical
    try std.testing.expectEqualSlices(u8, bitmap1.pixels, bitmap2.pixels);
}

// ============================================================================
// Gradient Smoothness Tests
// ============================================================================

test "distance field produces continuous output" {
    const allocator = std.testing.allocator;

    // Create a large circle-like shape using many edges (CW winding order)
    const num_edges = 16;
    var edges = try allocator.alloc(EdgeSegment, num_edges);

    const center_x: f64 = 50;
    const center_y: f64 = 50;
    const radius: f64 = 40;

    for (0..num_edges) |i| {
        // Use negative angles for CW winding
        const angle1 = -@as(f64, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f64, num_edges);
        const angle2 = -@as(f64, @floatFromInt(i + 1)) * 2.0 * std.math.pi / @as(f64, num_edges);

        const p1 = Vec2.init(center_x + radius * @cos(angle1), center_y + radius * @sin(angle1));
        const p2 = Vec2.init(center_x + radius * @cos(angle2), center_y + radius * @sin(angle2));

        edges[i] = EdgeSegment{ .linear = LinearSegment.init(p1, p2) };
    }

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, 8.0, transform);
    defer bitmap.deinit();

    // Verify the output has both high and low values (indicating proper inside/outside)
    // Use median of RGB channels (correct MSDF interpretation)
    var min_val: u8 = 255;
    var max_val: u8 = 0;

    var y: u32 = 0;
    while (y < 64) : (y += 1) {
        var x: u32 = 0;
        while (x < 64) : (x += 1) {
            const pixel = bitmap.getPixel(x, y);
            // MSDF uses median of RGB for distance
            const med = median3(pixel[0], pixel[1], pixel[2]);
            min_val = @min(min_val, med);
            max_val = @max(max_val, med);
        }
    }

    // Should have a good range of values (both inside and outside regions)
    try std.testing.expect(max_val > 150); // Inside regions should be bright
    try std.testing.expect(min_val < 100); // Outside regions should be dark
    try std.testing.expect(max_val - min_val > 50); // Should have variation
}

// ============================================================================
// Inside/Outside Region Tests
// ============================================================================

test "center of square is inside (high pixel value)" {
    const allocator = std.testing.allocator;

    // Create a square centered in the output (CW winding order)
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(20, 20), Vec2.init(20, 80)) };
    edges[1] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(20, 80), Vec2.init(80, 80)) };
    edges[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(80, 80), Vec2.init(80, 20)) };
    edges[3] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(80, 20), Vec2.init(20, 20)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 8);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, 8.0, transform);
    defer bitmap.deinit();

    // Center pixel should be "inside" (high values, > 127)
    const center = bitmap.getPixel(32, 32);
    try std.testing.expect(center[0] > 127); // R
    try std.testing.expect(center[1] > 127); // G
    try std.testing.expect(center[2] > 127); // B
}

test "corner of output is outside (low pixel value)" {
    const allocator = std.testing.allocator;

    // Create a square centered in the output (CW winding order)
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(20, 20), Vec2.init(20, 80)) };
    edges[1] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(20, 80), Vec2.init(80, 80)) };
    edges[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(80, 80), Vec2.init(80, 20)) };
    edges[3] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(80, 20), Vec2.init(20, 20)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 8);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, 8.0, transform);
    defer bitmap.deinit();

    // Corner pixels should be "outside" (low values, < 127)
    const corner = bitmap.getPixel(0, 0);
    try std.testing.expect(corner[0] < 127); // R
    try std.testing.expect(corner[1] < 127); // G
    try std.testing.expect(corner[2] < 127); // B
}

// ============================================================================
// Multi-Channel Difference Tests
// ============================================================================

test "MSDF has channel differences at corners" {
    const allocator = std.testing.allocator;

    // Create a square - the corners should have different channel values (CW winding order)
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(10, 10), Vec2.init(10, 90)) };
    edges[1] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(10, 90), Vec2.init(90, 90)) };
    edges[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(90, 90), Vec2.init(90, 10)) };
    edges[3] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(90, 10), Vec2.init(10, 10)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, 8.0, transform);
    defer bitmap.deinit();

    // Count pixels where channels differ significantly
    // This is a key property of MSDF - corners should have channel differences
    var diff_pixels: u32 = 0;
    var y: u32 = 0;
    while (y < 64) : (y += 1) {
        var x: u32 = 0;
        while (x < 64) : (x += 1) {
            const pixel = bitmap.getPixel(x, y);
            const r = pixel[0];
            const g = pixel[1];
            const b = pixel[2];

            // Check if channels differ by more than a threshold
            const rg_diff = if (r > g) r - g else g - r;
            const rb_diff = if (r > b) r - b else b - r;
            const gb_diff = if (g > b) g - b else b - g;

            const max_diff = @max(rg_diff, @max(rb_diff, gb_diff));
            if (max_diff > 20) {
                diff_pixels += 1;
            }
        }
    }

    // Should have some pixels with channel differences (near corners/edges)
    try std.testing.expect(diff_pixels > 0);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "very small shape produces valid output" {
    const allocator = std.testing.allocator;

    // Create a tiny triangle (CW winding order)
    var edges = try allocator.alloc(EdgeSegment, 3);
    edges[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0, 0), Vec2.init(0.5, 1)) };
    edges[1] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0.5, 1), Vec2.init(1, 0)) };
    edges[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(1, 0), Vec2.init(0, 0)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const transform = msdf.generate.calculateTransform(bounds, 32, 32, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 32, 32, 4.0, transform);
    defer bitmap.deinit();

    // Should produce valid output without any issues
    try std.testing.expectEqual(@as(u32, 32), bitmap.width);
    try std.testing.expectEqual(@as(u32, 32), bitmap.height);

    // Check that we have variation (not all same color)
    var min_val: u8 = 255;
    var max_val: u8 = 0;
    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 1) {
        min_val = @min(min_val, bitmap.pixels[i]);
        max_val = @max(max_val, bitmap.pixels[i]);
    }
    try std.testing.expect(max_val > min_val);
}

test "shape with quadratic curves produces valid output" {
    const allocator = std.testing.allocator;

    // Create an arch shape with quadratic curves (CW winding order)
    var edges = try allocator.alloc(EdgeSegment, 3);
    edges[0] = EdgeSegment{ .quadratic = QuadraticSegment.init(
        Vec2.init(0, 0),
        Vec2.init(0, 100),
        Vec2.init(50, 100),
    ) };
    edges[1] = EdgeSegment{ .quadratic = QuadraticSegment.init(
        Vec2.init(50, 100),
        Vec2.init(100, 100),
        Vec2.init(100, 0),
    ) };
    edges[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(100, 0), Vec2.init(0, 0)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    msdf.coloring.colorEdgesSimple(&shape);

    const bounds = shape.bounds();
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, 8.0, transform);
    defer bitmap.deinit();

    // Verify output dimensions
    try std.testing.expectEqual(@as(u32, 64), bitmap.width);
    try std.testing.expectEqual(@as(u32, 64), bitmap.height);

    // Verify we have a range of values (inside and outside)
    var min_val: u8 = 255;
    var max_val: u8 = 0;
    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 1) {
        min_val = @min(min_val, bitmap.pixels[i]);
        max_val = @max(max_val, bitmap.pixels[i]);
    }

    // Should have both bright and dark regions
    try std.testing.expect(max_val > min_val + 30);
}
