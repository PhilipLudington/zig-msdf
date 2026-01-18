//! Integration tests for zig-msdf.
//!
//! These tests verify the complete MSDF generation pipeline by constructing
//! shapes programmatically and generating MSDF textures from them.

const std = @import("std");
const msdf = @import("msdf");

const Vec2 = msdf.math.Vec2;
const EdgeSegment = msdf.edge.EdgeSegment;
const LinearSegment = msdf.edge.LinearSegment;
const QuadraticSegment = msdf.edge.QuadraticSegment;
const Contour = msdf.contour.Contour;
const Shape = msdf.contour.Shape;

// ============================================================================
// Shape Construction Tests
// ============================================================================

test "build simple square shape" {
    const allocator = std.testing.allocator;

    // Create edges
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0, 0), Vec2.init(100, 0)) };
    edges[1] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(100, 0), Vec2.init(100, 100)) };
    edges[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(100, 100), Vec2.init(0, 100)) };
    edges[3] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0, 100), Vec2.init(0, 0)) };

    // Create contour
    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    // Verify shape properties
    try std.testing.expectEqual(@as(usize, 4), shape.edgeCount());
    try std.testing.expect(!shape.isEmpty());

    // Verify bounds
    const bounds = shape.bounds();
    try std.testing.expectApproxEqAbs(@as(f64, 0), bounds.min.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), bounds.min.y, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 100), bounds.max.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 100), bounds.max.y, 1e-10);
}

test "build shape with quadratic curve" {
    const allocator = std.testing.allocator;

    // Create a contour with a quadratic curve (like an arch)
    var edges = try allocator.alloc(EdgeSegment, 3);
    edges[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0, 0), Vec2.init(100, 0)) };
    edges[1] = EdgeSegment{ .quadratic = QuadraticSegment.init(
        Vec2.init(100, 0),
        Vec2.init(100, 100), // control point
        Vec2.init(50, 100),
    ) };
    edges[2] = EdgeSegment{ .quadratic = QuadraticSegment.init(
        Vec2.init(50, 100),
        Vec2.init(0, 100), // control point
        Vec2.init(0, 0),
    ) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    // Verify shape has 3 edges
    try std.testing.expectEqual(@as(usize, 3), shape.edgeCount());

    // Verify contour is closed
    try std.testing.expect(shape.contours[0].isClosed());
}

// ============================================================================
// MSDF Generation Pipeline Tests
// ============================================================================

test "generateMsdf produces correct dimensions" {
    const allocator = std.testing.allocator;

    // Create a simple shape
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0, 0), Vec2.init(100, 0)) };
    edges[1] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(100, 0), Vec2.init(100, 100)) };
    edges[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(100, 100), Vec2.init(0, 100)) };
    edges[3] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0, 100), Vec2.init(0, 0)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    // Apply edge coloring
    msdf.coloring.colorEdgesSimple(&shape);

    // Calculate transform
    const bounds = shape.bounds();
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    // Generate MSDF
    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, 8.0, transform, .{});
    defer bitmap.deinit();

    // Verify output dimensions
    try std.testing.expectEqual(@as(u32, 64), bitmap.width);
    try std.testing.expectEqual(@as(u32, 64), bitmap.height);

    // Verify pixel count (RGB8 = 3 bytes per pixel)
    try std.testing.expectEqual(@as(usize, 64 * 64 * 3), bitmap.pixels.len);
}

test "generateMsdf with empty shape returns valid bitmap" {
    const allocator = std.testing.allocator;

    // Empty shape
    var shape = Shape.init(allocator);
    defer shape.deinit();

    // Generate MSDF for empty shape
    const transform = msdf.generate.Transform{
        .scale = 1.0,
        .translate = Vec2.zero,
    };

    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 32, 32, 4.0, transform, .{});
    defer bitmap.deinit();

    // Should still produce valid output
    try std.testing.expectEqual(@as(u32, 32), bitmap.width);
    try std.testing.expectEqual(@as(u32, 32), bitmap.height);
}

test "edge coloring assigns colors to edges" {
    const allocator = std.testing.allocator;

    // Create a square with corners
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0, 0), Vec2.init(100, 0)) };
    edges[1] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(100, 0), Vec2.init(100, 100)) };
    edges[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(100, 100), Vec2.init(0, 100)) };
    edges[3] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0, 100), Vec2.init(0, 0)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    // Apply edge coloring
    msdf.coloring.colorEdgesSimple(&shape);

    // Verify that edges are colored (not black)
    for (shape.contours[0].edges) |edge| {
        const color = edge.getColor();
        try std.testing.expect(color != .black);
    }

    // Verify that we have at least 2 different colors used (for corners)
    var has_cyan = false;
    var has_magenta = false;
    var has_yellow = false;
    var has_white = false;

    for (shape.contours[0].edges) |edge| {
        switch (edge.getColor()) {
            .cyan => has_cyan = true,
            .magenta => has_magenta = true,
            .yellow => has_yellow = true,
            .white => has_white = true,
            else => {},
        }
    }

    // Should have multiple colors for proper MSDF corner handling
    const color_count = @as(u8, @intFromBool(has_cyan)) +
        @as(u8, @intFromBool(has_magenta)) +
        @as(u8, @intFromBool(has_yellow)) +
        @as(u8, @intFromBool(has_white));
    try std.testing.expect(color_count >= 2);
}

// ============================================================================
// Transform Calculation Tests
// ============================================================================

test "calculateTransform centers shape in output" {
    // Create bounds for a 100x100 shape at origin
    const bounds = msdf.math.Bounds.init(0, 0, 100, 100);

    // Calculate transform for 64x64 output with 4px padding
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    // Available space = 64 - 2*4 = 56x56
    // Shape is 100x100, so scale = 56/100 = 0.56
    try std.testing.expectApproxEqAbs(@as(f64, 0.56), transform.scale, 0.01);
}

test "calculateTransform handles non-square shapes" {
    // Create bounds for a 200x100 shape (wider than tall)
    const bounds = msdf.math.Bounds.init(0, 0, 200, 100);

    // Calculate transform for 64x64 output with 4px padding
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    // Available space = 56x56, width-limited: scale = min(56/200, 56/100) = 0.28
    try std.testing.expectApproxEqAbs(@as(f64, 0.28), transform.scale, 0.01);
}

// ============================================================================
// Distance Calculation Tests
// ============================================================================

test "computeWinding for point inside square" {
    const allocator = std.testing.allocator;

    // Create a CCW square
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0, 0), Vec2.init(100, 0)) };
    edges[1] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(100, 0), Vec2.init(100, 100)) };
    edges[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(100, 100), Vec2.init(0, 100)) };
    edges[3] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0, 100), Vec2.init(0, 0)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    // Point inside should have positive winding
    const winding_inside = msdf.generate.computeWinding(shape, Vec2.init(50, 50));
    try std.testing.expect(winding_inside != 0);

    // Point outside should have zero winding
    const winding_outside = msdf.generate.computeWinding(shape, Vec2.init(150, 50));
    try std.testing.expectEqual(@as(i32, 0), winding_outside);
}

// ============================================================================
// Pixel Value Tests
// ============================================================================

test "distanceToPixel maps correctly" {
    // Distance of 0 (on boundary) should map to ~127-128 (0.5 * 255 = 127.5)
    const on_boundary = msdf.generate.distanceToPixel(0, 8.0);
    try std.testing.expectEqual(@as(u8, 127), on_boundary);

    // Positive distance (outside) should map to < 127 (darker)
    const outside = msdf.generate.distanceToPixel(4.0, 8.0);
    try std.testing.expect(outside < 127);

    // Negative distance (inside) should map to > 127 (brighter)
    const inside = msdf.generate.distanceToPixel(-4.0, 8.0);
    try std.testing.expect(inside > 127);
}

// ============================================================================
// Full Pipeline Test
// ============================================================================

test "full pipeline: shape to colored MSDF" {
    const allocator = std.testing.allocator;

    // Create a letter "L" shape
    var edges = try allocator.alloc(EdgeSegment, 6);
    edges[0] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0, 0), Vec2.init(50, 0)) }; // bottom
    edges[1] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(50, 0), Vec2.init(50, 30)) }; // right lower
    edges[2] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(50, 30), Vec2.init(20, 30)) }; // inner horizontal
    edges[3] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(20, 30), Vec2.init(20, 100)) }; // inner vertical
    edges[4] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(20, 100), Vec2.init(0, 100)) }; // top
    edges[5] = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0, 100), Vec2.init(0, 0)) }; // left

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    // Verify shape is closed
    try std.testing.expect(shape.contours[0].isClosed());

    // Apply edge coloring
    msdf.coloring.colorEdgesSimple(&shape);

    // Verify edges got colored
    for (shape.contours[0].edges) |edge| {
        const color = edge.getColor();
        // Should be colored (not black)
        try std.testing.expect(color != .black);
    }

    // Calculate transform
    const bounds = shape.bounds();
    const transform = msdf.generate.calculateTransform(bounds, 64, 64, 4);

    // Generate MSDF
    var bitmap = try msdf.generate.generateMsdf(allocator, shape, 64, 64, 8.0, transform, .{});
    defer bitmap.deinit();

    // Verify output
    try std.testing.expectEqual(@as(u32, 64), bitmap.width);
    try std.testing.expectEqual(@as(u32, 64), bitmap.height);

    // Verify we have some variation in pixel values (not all same color)
    var min_r: u8 = 255;
    var max_r: u8 = 0;
    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 3) {
        min_r = @min(min_r, bitmap.pixels[i]);
        max_r = @max(max_r, bitmap.pixels[i]);
    }
    // Should have variation in pixel values
    try std.testing.expect(max_r > min_r);
}
