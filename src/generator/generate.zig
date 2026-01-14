//! MSDF generation algorithms.
//!
//! This module provides the core functionality for generating Multi-channel
//! Signed Distance Fields from shape outlines.

const std = @import("std");
const math = @import("math.zig");
const edge_mod = @import("edge.zig");
const contour_mod = @import("contour.zig");

const Vec2 = math.Vec2;
const Bounds = math.Bounds;
const SignedDistance = math.SignedDistance;
const EdgeSegment = edge_mod.EdgeSegment;
const EdgeColor = edge_mod.EdgeColor;
const Contour = contour_mod.Contour;
const Shape = contour_mod.Shape;

/// Result of MSDF generation containing the pixel buffer and dimensions.
pub const MsdfBitmap = struct {
    /// Pixel data in RGB8 format (3 bytes per pixel: R, G, B).
    pixels: []u8,
    /// Width of the bitmap in pixels.
    width: u32,
    /// Height of the bitmap in pixels.
    height: u32,
    /// Allocator used for this bitmap's memory.
    allocator: std.mem.Allocator,

    /// Free memory associated with this bitmap.
    pub fn deinit(self: *MsdfBitmap) void {
        self.allocator.free(self.pixels);
        self.pixels = &[_]u8{};
    }

    /// Get a pixel value at (x, y).
    pub fn getPixel(self: MsdfBitmap, x: u32, y: u32) [3]u8 {
        const idx = (y * self.width + x) * 3;
        return .{ self.pixels[idx], self.pixels[idx + 1], self.pixels[idx + 2] };
    }

    /// Set a pixel value at (x, y).
    pub fn setPixel(self: *MsdfBitmap, x: u32, y: u32, rgb: [3]u8) void {
        const idx = (y * self.width + x) * 3;
        self.pixels[idx] = rgb[0];
        self.pixels[idx + 1] = rgb[1];
        self.pixels[idx + 2] = rgb[2];
    }
};

/// Transform parameters for mapping shape coordinates to pixel coordinates.
pub const Transform = struct {
    /// Scale factor applied to shape coordinates.
    scale: f64,
    /// Translation applied after scaling (in shape units before scaling).
    translate: Vec2,

    /// Create a transform from scale and translation.
    pub fn init(scale: f64, translate: Vec2) Transform {
        return .{ .scale = scale, .translate = translate };
    }

    /// Transform a pixel coordinate to shape coordinate (world space).
    pub fn pixelToShape(self: Transform, px: f64, py: f64) Vec2 {
        return Vec2{
            .x = (px + 0.5) / self.scale - self.translate.x,
            .y = (py + 0.5) / self.scale - self.translate.y,
        };
    }

    /// Transform a shape coordinate to pixel coordinate.
    pub fn shapeToPixel(self: Transform, point: Vec2) Vec2 {
        return Vec2{
            .x = (point.x + self.translate.x) * self.scale - 0.5,
            .y = (point.y + self.translate.y) * self.scale - 0.5,
        };
    }
};

/// Compute the winding number of a point with respect to a shape.
/// Uses the non-zero winding rule: point is inside if winding != 0.
/// Positive winding indicates counter-clockwise enclosure.
pub fn computeWinding(shape: Shape, point: Vec2) i32 {
    var winding: i32 = 0;

    for (shape.contours) |contour| {
        winding += computeContourWinding(contour, point);
    }

    return winding;
}

/// Compute the winding number contribution of a single contour.
fn computeContourWinding(contour: Contour, point: Vec2) i32 {
    if (contour.edges.len == 0) return 0;

    var winding: i32 = 0;

    // Cast a ray from point to the right (+x direction) and count crossings
    for (contour.edges) |e| {
        winding += countEdgeCrossings(e, point);
    }

    return winding;
}

/// Count ray crossings for a single edge.
/// Ray goes from point to +infinity in x direction.
fn countEdgeCrossings(e: EdgeSegment, point: Vec2) i32 {
    // Sample the edge at multiple points to find crossings
    // For linear segments, we could use exact intersection, but sampling
    // works for all segment types and is simpler.
    const samples = 16;
    var crossings: i32 = 0;

    var i: usize = 0;
    while (i < samples) : (i += 1) {
        const t0 = @as(f64, @floatFromInt(i)) / @as(f64, samples);
        const t1 = @as(f64, @floatFromInt(i + 1)) / @as(f64, samples);

        const p0 = e.point(t0);
        const p1 = e.point(t1);

        // Check if this segment crosses the horizontal ray
        // The ray starts at point and goes to +infinity in x

        // Skip if segment is entirely above or below the ray
        if ((p0.y < point.y and p1.y < point.y) or
            (p0.y >= point.y and p1.y >= point.y))
        {
            continue;
        }

        // Calculate x-coordinate of intersection with y = point.y
        const t_intersect = (point.y - p0.y) / (p1.y - p0.y);
        const x_intersect = p0.x + t_intersect * (p1.x - p0.x);

        // Only count if intersection is to the right of point
        if (x_intersect > point.x) {
            // Determine direction: upward crossing adds 1, downward subtracts 1
            if (p1.y > p0.y) {
                crossings += 1;
            } else {
                crossings -= 1;
            }
        }
    }

    return crossings;
}

/// Convert a signed distance value to a pixel value (0-255).
/// The mapping is: distance = -range -> 255, distance = 0 -> 128, distance = +range -> 0
pub fn distanceToPixel(distance: f64, range: f64) u8 {
    // Normalize distance to [-1, 1] range, then map to [0, 1]
    // Inside (negative distance) maps to higher values (brighter)
    // Outside (positive distance) maps to lower values (darker)
    const normalized = 0.5 - distance / (2.0 * range);
    const clamped = std.math.clamp(normalized, 0.0, 1.0);
    return @intFromFloat(clamped * 255.0);
}

/// Convert a pixel value back to a signed distance.
pub fn pixelToDistance(pixel: u8, range: f64) f64 {
    const normalized = @as(f64, @floatFromInt(pixel)) / 255.0;
    return (0.5 - normalized) * 2.0 * range;
}

/// Generate a Multi-channel Signed Distance Field from a shape.
///
/// Parameters:
/// - allocator: Allocator for the output bitmap.
/// - shape: The shape to generate the MSDF from.
/// - width: Output bitmap width in pixels.
/// - height: Output bitmap height in pixels.
/// - range: Distance field range in shape units. Distances beyond this are clamped.
/// - transform: Transform from pixel coordinates to shape coordinates.
///
/// Returns an MsdfBitmap containing the RGB8 distance field data.
pub fn generateMsdf(
    allocator: std.mem.Allocator,
    shape: Shape,
    width: u32,
    height: u32,
    range: f64,
    transform: Transform,
) !MsdfBitmap {
    const pixel_count = @as(usize, width) * @as(usize, height);
    const pixels = try allocator.alloc(u8, pixel_count * 3);
    errdefer allocator.free(pixels);

    // Initialize to medium gray (edge value)
    @memset(pixels, 128);

    var result = MsdfBitmap{
        .pixels = pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };

    // Process each pixel
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            // Convert pixel center to shape coordinates
            const point = transform.pixelToShape(@floatFromInt(x), @floatFromInt(y));

            // Compute per-channel distances
            const distances = computeChannelDistances(shape, point);

            // Determine inside/outside using winding number
            const winding = computeWinding(shape, point);
            const inside = winding != 0;

            // Apply sign based on inside/outside
            // If inside, distances should be negative (or we negate positive distances)
            // If outside, distances should be positive
            var r_dist = distances[0];
            var g_dist = distances[1];
            var b_dist = distances[2];

            // The edge signedDistance methods return positive for points "outside"
            // the edge's left side. For proper inside/outside determination with
            // the winding rule, we need to ensure the sign matches.
            if (inside) {
                // Point is inside - distances should be negative
                r_dist = -@abs(r_dist);
                g_dist = -@abs(g_dist);
                b_dist = -@abs(b_dist);
            } else {
                // Point is outside - distances should be positive
                r_dist = @abs(r_dist);
                g_dist = @abs(g_dist);
                b_dist = @abs(b_dist);
            }

            // Convert to pixel values
            const r = distanceToPixel(r_dist, range);
            const g = distanceToPixel(g_dist, range);
            const b = distanceToPixel(b_dist, range);

            // Flip Y when storing: font coordinates have Y-up, images have Y-down
            result.setPixel(x, height - 1 - y, .{ r, g, b });
        }
    }

    return result;
}

/// Compute the minimum signed distance for each color channel.
/// Returns [red_distance, green_distance, blue_distance].
fn computeChannelDistances(shape: Shape, point: Vec2) [3]f64 {
    var min_red = SignedDistance.infinite;
    var min_green = SignedDistance.infinite;
    var min_blue = SignedDistance.infinite;

    // Find minimum distance per channel across all edges
    for (shape.contours) |contour| {
        for (contour.edges) |e| {
            const sd = e.signedDistance(point);
            const color = e.getColor();

            // Update minimum for each channel this edge contributes to
            if (color.hasRed()) {
                if (sd.lessThan(min_red)) {
                    min_red = sd;
                }
            }
            if (color.hasGreen()) {
                if (sd.lessThan(min_green)) {
                    min_green = sd;
                }
            }
            if (color.hasBlue()) {
                if (sd.lessThan(min_blue)) {
                    min_blue = sd;
                }
            }
        }
    }

    return .{
        min_red.distance,
        min_green.distance,
        min_blue.distance,
    };
}

/// Calculate the transform needed to fit a shape into a bitmap with padding.
///
/// Parameters:
/// - shape_bounds: Bounding box of the shape.
/// - width: Output bitmap width in pixels.
/// - height: Output bitmap height in pixels.
/// - padding: Padding in pixels around the shape.
///
/// Returns a Transform that maps pixel coordinates to shape coordinates.
pub fn calculateTransform(shape_bounds: Bounds, width: u32, height: u32, padding: u32) Transform {
    const shape_width = shape_bounds.width();
    const shape_height = shape_bounds.height();

    // Available space in pixels (after removing padding)
    const available_width = @as(f64, @floatFromInt(width)) - 2.0 * @as(f64, @floatFromInt(padding));
    const available_height = @as(f64, @floatFromInt(height)) - 2.0 * @as(f64, @floatFromInt(padding));

    // Calculate scale to fit shape into available space
    // Use the smaller scale to maintain aspect ratio
    var scale: f64 = 1.0;
    if (shape_width > 0 and shape_height > 0) {
        const scale_x = available_width / shape_width;
        const scale_y = available_height / shape_height;
        scale = @min(scale_x, scale_y);
    } else if (shape_width > 0) {
        scale = available_width / shape_width;
    } else if (shape_height > 0) {
        scale = available_height / shape_height;
    }

    // Calculate translation to center the shape
    // After scaling, the shape occupies (shape_width * scale, shape_height * scale)
    // We want to center it in the available space
    const scaled_width = shape_width * scale;
    const scaled_height = shape_height * scale;

    const offset_x = @as(f64, @floatFromInt(padding)) + (available_width - scaled_width) / 2.0;
    const offset_y = @as(f64, @floatFromInt(padding)) + (available_height - scaled_height) / 2.0;

    // The translation needs to account for the shape's minimum corner
    // translate.x = offset_x / scale - shape_bounds.min.x
    const translate = Vec2{
        .x = offset_x / scale - shape_bounds.min.x,
        .y = offset_y / scale - shape_bounds.min.y,
    };

    return Transform.init(scale, translate);
}

// ============================================================================
// Tests
// ============================================================================

test "distanceToPixel" {
    const range: f64 = 4.0;

    // At edge (distance = 0) -> 128
    try std.testing.expectEqual(@as(u8, 128), distanceToPixel(0, range));

    // Fully inside (distance = -range) -> 255
    try std.testing.expectEqual(@as(u8, 255), distanceToPixel(-range, range));

    // Fully outside (distance = +range) -> 0
    try std.testing.expectEqual(@as(u8, 0), distanceToPixel(range, range));

    // Half inside (distance = -range/2) -> 191 (approx)
    const half_inside = distanceToPixel(-range / 2.0, range);
    try std.testing.expect(half_inside > 128 and half_inside < 255);

    // Half outside (distance = +range/2) -> 64 (approx)
    const half_outside = distanceToPixel(range / 2.0, range);
    try std.testing.expect(half_outside > 0 and half_outside < 128);
}

test "pixelToDistance roundtrip" {
    const range: f64 = 4.0;
    const test_distances = [_]f64{ -4.0, -2.0, 0.0, 2.0, 4.0 };

    for (test_distances) |dist| {
        const pixel = distanceToPixel(dist, range);
        const recovered = pixelToDistance(pixel, range);
        // Allow some error due to quantization
        try std.testing.expectApproxEqAbs(dist, recovered, 0.05);
    }
}

test "computeWinding - point inside square" {
    const allocator = std.testing.allocator;

    // Create a CCW square (0,0) -> (10,0) -> (10,10) -> (0,10) -> (0,0)
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(0, 0), Vec2.init(10, 0)) };
    edges[1] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(10, 0), Vec2.init(10, 10)) };
    edges[2] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(10, 10), Vec2.init(0, 10)) };
    edges[3] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(0, 10), Vec2.init(0, 0)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    // Point inside should have non-zero winding
    const inside_winding = computeWinding(shape, Vec2.init(5, 5));
    try std.testing.expect(inside_winding != 0);

    // Point outside should have zero winding
    const outside_winding = computeWinding(shape, Vec2.init(15, 5));
    try std.testing.expectEqual(@as(i32, 0), outside_winding);
}

test "Transform.pixelToShape" {
    const transform = Transform.init(2.0, Vec2.init(10, 20));

    // Pixel (0, 0) with scale 2 and translate (10, 20)
    // shape.x = (0 + 0.5) / 2 - 10 = 0.25 - 10 = -9.75
    // shape.y = (0 + 0.5) / 2 - 20 = 0.25 - 20 = -19.75
    const point = transform.pixelToShape(0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, -9.75), point.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, -19.75), point.y, 1e-10);
}

test "calculateTransform - centers shape" {
    const shape_bounds = Bounds.init(0, 0, 100, 100);
    const transform = calculateTransform(shape_bounds, 64, 64, 4);

    // With 64x64 output and 4px padding, available space is 56x56
    // Shape is 100x100, so scale = 56/100 = 0.56
    try std.testing.expectApproxEqAbs(@as(f64, 0.56), transform.scale, 1e-10);
}

test "generateMsdf - empty shape" {
    const allocator = std.testing.allocator;

    var shape = Shape.init(allocator);
    defer shape.deinit();

    const transform = Transform.init(1.0, Vec2.zero);
    var bitmap = try generateMsdf(allocator, shape, 8, 8, 4.0, transform);
    defer bitmap.deinit();

    // With empty shape, all pixels should be "outside" (128 or less)
    // Actually with no edges, all channels will use infinite distance -> outside -> 0
    // But we initialize to 128, and with no edges, the distance stays infinite
    try std.testing.expectEqual(@as(u32, 8), bitmap.width);
    try std.testing.expectEqual(@as(u32, 8), bitmap.height);
}

test "generateMsdf - simple square" {
    const allocator = std.testing.allocator;

    // Create a square shape
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(0, 0), Vec2.init(10, 0)) };
    edges[1] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(10, 0), Vec2.init(10, 10)) };
    edges[2] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(10, 10), Vec2.init(0, 10)) };
    edges[3] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(0, 10), Vec2.init(0, 0)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    // Calculate transform to fit shape
    const bounds = shape.bounds();
    const transform = calculateTransform(bounds, 32, 32, 4);

    var bitmap = try generateMsdf(allocator, shape, 32, 32, 4.0, transform);
    defer bitmap.deinit();

    try std.testing.expectEqual(@as(u32, 32), bitmap.width);
    try std.testing.expectEqual(@as(u32, 32), bitmap.height);

    // Center pixel should be inside (high values)
    const center = bitmap.getPixel(16, 16);
    try std.testing.expect(center[0] > 128);
    try std.testing.expect(center[1] > 128);
    try std.testing.expect(center[2] > 128);

    // Corner pixel should be outside (low values)
    const corner = bitmap.getPixel(0, 0);
    try std.testing.expect(corner[0] < 128);
    try std.testing.expect(corner[1] < 128);
    try std.testing.expect(corner[2] < 128);
}
