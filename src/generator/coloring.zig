//! Edge coloring algorithm for MSDF generation.
//!
//! The edge coloring algorithm assigns colors (channels) to edge segments
//! to ensure that corners and features are properly preserved in the
//! multi-channel signed distance field.
//!
//! The basic principle is that adjacent edges should not share all channels,
//! and corners (sharp direction changes) should have different colors on
//! each side to create a crisp intersection in the output.

const std = @import("std");
const math = @import("math.zig");
const edge_mod = @import("edge.zig");
const contour_mod = @import("contour.zig");

const Vec2 = math.Vec2;
const EdgeColor = edge_mod.EdgeColor;
const EdgeSegment = edge_mod.EdgeSegment;
const Contour = contour_mod.Contour;
const Shape = contour_mod.Shape;

/// Threshold angle (in radians) for detecting corners.
/// Edges meeting at an angle greater than this are considered corners.
const corner_angle_threshold = std.math.pi / 3.0; // 60 degrees

/// Color edges in a shape for MSDF generation.
/// This assigns colors to edges so that corners are preserved.
pub fn colorEdges(shape: *Shape, angle_threshold: f64) void {
    for (shape.contours) |*contour| {
        colorContour(contour, angle_threshold);
    }
}

/// Color edges in a shape using the default angle threshold.
pub fn colorEdgesSimple(shape: *Shape) void {
    colorEdges(shape, corner_angle_threshold);
}

/// Color edges in a single contour.
fn colorContour(contour: *Contour, angle_threshold: f64) void {
    const edge_count = contour.edges.len;
    if (edge_count == 0) return;

    // Single edge contour: just use white (all channels)
    if (edge_count == 1) {
        contour.edges[0].setColor(.white);
        return;
    }

    // Two edge contour: alternate colors
    if (edge_count == 2) {
        contour.edges[0].setColor(.cyan);
        contour.edges[1].setColor(.magenta);
        return;
    }

    // Find corners (sharp direction changes between edges)
    // A corner is where the direction changes significantly
    var corners = std.BoundedArray(usize, 256){};

    for (0..edge_count) |i| {
        const prev_idx = if (i == 0) edge_count - 1 else i - 1;

        const prev_edge = contour.edges[prev_idx];
        const curr_edge = contour.edges[i];

        // Get outgoing direction of previous edge and incoming direction of current edge
        const prev_dir = prev_edge.direction(1.0).normalize();
        const curr_dir = curr_edge.direction(0.0).normalize();

        // Calculate angle between directions
        const angle = angleBetween(prev_dir, curr_dir);

        if (angle > angle_threshold) {
            corners.append(i) catch break;
        }
    }

    // If no corners detected, treat the whole contour as smooth
    // Use simple alternating colors
    if (corners.len == 0) {
        // Smooth contour: use a pattern that ensures adjacent edges differ
        const colors = [_]EdgeColor{ .cyan, .magenta, .yellow };
        for (contour.edges, 0..) |*e, i| {
            e.setColor(colors[i % 3]);
        }
        return;
    }

    // Color edges between corners
    // Each "smooth segment" between corners gets its own color scheme
    colorBetweenCorners(contour, corners.slice());
}

/// Calculate the angle between two direction vectors (in radians).
fn angleBetween(a: Vec2, b: Vec2) f64 {
    // Use cross product and dot product to get signed angle
    const dot = a.dot(b);
    const cross = a.cross(b);

    // Clamp dot product to valid range for acos
    const clamped_dot = std.math.clamp(dot, -1.0, 1.0);

    // For corner detection, we care about the absolute angle change
    // Use atan2 to get the full angle
    const angle = std.math.atan2(cross, clamped_dot);
    return @abs(angle);
}

/// Color edges between identified corners.
fn colorBetweenCorners(contour: *Contour, corners: []const usize) void {
    const edge_count = contour.edges.len;

    // Available colors for alternating
    const color_set = [_]EdgeColor{ .cyan, .magenta, .yellow };

    // Process each segment between corners
    var segment_color_idx: usize = 0;

    for (corners, 0..) |corner_start, corner_idx| {
        const corner_end = if (corner_idx + 1 < corners.len)
            corners[corner_idx + 1]
        else
            corners[0]; // Wrap around

        // Determine the color for this segment
        const primary_color = color_set[segment_color_idx % color_set.len];

        // Color all edges from corner_start to corner_end (exclusive)
        var i = corner_start;
        var edge_in_segment: usize = 0;

        while (true) {
            // For segments with multiple edges, we might want to alternate
            // within the segment, but using the same primary color ensures
            // the corner on each side has different colors
            contour.edges[i].setColor(getSegmentColor(primary_color, edge_in_segment));

            edge_in_segment += 1;
            i = (i + 1) % edge_count;

            if (i == corner_end) break;
        }

        // Move to next color for the next segment
        segment_color_idx += 1;
    }
}

/// Get the color for an edge within a segment.
/// This ensures adjacent edges within smooth segments still have some variation.
fn getSegmentColor(primary: EdgeColor, index: usize) EdgeColor {
    // For smooth segments, we could alternate slightly, but for now
    // we keep it simple: use the primary color for all edges in the segment.
    // The key is that adjacent segments (across corners) have different colors.
    _ = index;
    return primary;
}

/// Detect if a junction between two edges forms a corner.
pub fn isCorner(prev_dir: Vec2, curr_dir: Vec2, threshold: f64) bool {
    const angle = angleBetween(prev_dir.normalize(), curr_dir.normalize());
    return angle > threshold;
}

/// Get the default corner angle threshold.
pub fn defaultAngleThreshold() f64 {
    return corner_angle_threshold;
}

// ============================================================================
// Tests
// ============================================================================

test "angleBetween - same direction" {
    const a = Vec2.init(1, 0);
    const b = Vec2.init(1, 0);
    const angle = angleBetween(a, b);
    try std.testing.expectApproxEqAbs(@as(f64, 0), angle, 1e-10);
}

test "angleBetween - perpendicular" {
    const a = Vec2.init(1, 0);
    const b = Vec2.init(0, 1);
    const angle = angleBetween(a, b);
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, angle, 1e-10);
}

test "angleBetween - opposite" {
    const a = Vec2.init(1, 0);
    const b = Vec2.init(-1, 0);
    const angle = angleBetween(a, b);
    try std.testing.expectApproxEqAbs(std.math.pi, angle, 1e-10);
}

test "isCorner - sharp corner" {
    const prev_dir = Vec2.init(1, 0);
    const curr_dir = Vec2.init(0, 1);
    try std.testing.expect(isCorner(prev_dir, curr_dir, corner_angle_threshold));
}

test "isCorner - smooth transition" {
    const prev_dir = Vec2.init(1, 0);
    const curr_dir = Vec2.init(1, 0.1); // Almost same direction
    try std.testing.expect(!isCorner(prev_dir, curr_dir, corner_angle_threshold));
}

test "colorEdgesSimple - single edge" {
    const allocator = std.testing.allocator;

    var edges = try allocator.alloc(EdgeSegment, 1);
    edges[0] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(0, 0), Vec2.init(1, 0)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    colorEdgesSimple(&shape);

    // Single edge should be white
    try std.testing.expectEqual(EdgeColor.white, shape.contours[0].edges[0].getColor());
}

test "colorEdgesSimple - two edges" {
    const allocator = std.testing.allocator;

    var edges = try allocator.alloc(EdgeSegment, 2);
    edges[0] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(0, 0), Vec2.init(1, 0)) };
    edges[1] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(1, 0), Vec2.init(0, 0)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    colorEdgesSimple(&shape);

    // Two edges should have different colors
    const color0 = shape.contours[0].edges[0].getColor();
    const color1 = shape.contours[0].edges[1].getColor();
    try std.testing.expect(color0 != color1);
}

test "colorEdgesSimple - square with corners" {
    const allocator = std.testing.allocator;

    // Create a square: 4 edges with 90-degree corners
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(0, 0), Vec2.init(1, 0)) };
    edges[1] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(1, 0), Vec2.init(1, 1)) };
    edges[2] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(1, 1), Vec2.init(0, 1)) };
    edges[3] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(0, 1), Vec2.init(0, 0)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    colorEdgesSimple(&shape);

    // All edges should have colors assigned (not black)
    for (shape.contours[0].edges) |e| {
        try std.testing.expect(e.getColor() != .black);
    }

    // Adjacent edges at corners should have different colors
    // (This is the key property for MSDF corner preservation)
    for (0..4) |i| {
        const curr = shape.contours[0].edges[i].getColor();
        const next = shape.contours[0].edges[(i + 1) % 4].getColor();
        // At least one channel should differ between adjacent edges at corners
        const differs = (curr.hasRed() != next.hasRed()) or
            (curr.hasGreen() != next.hasGreen()) or
            (curr.hasBlue() != next.hasBlue());
        try std.testing.expect(differs);
    }
}

test "colorEdgesSimple - multiple contours" {
    const allocator = std.testing.allocator;

    // Contour 1: triangle
    var edges1 = try allocator.alloc(EdgeSegment, 3);
    edges1[0] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(0, 0), Vec2.init(1, 0)) };
    edges1[1] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(1, 0), Vec2.init(0.5, 1)) };
    edges1[2] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(0.5, 1), Vec2.init(0, 0)) };

    // Contour 2: line segment pair
    var edges2 = try allocator.alloc(EdgeSegment, 2);
    edges2[0] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(2, 0), Vec2.init(3, 0)) };
    edges2[1] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(3, 0), Vec2.init(2, 0)) };

    var contours = try allocator.alloc(Contour, 2);
    contours[0] = Contour.fromEdges(allocator, edges1);
    contours[1] = Contour.fromEdges(allocator, edges2);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    colorEdgesSimple(&shape);

    // Both contours should be colored
    for (shape.contours[0].edges) |e| {
        try std.testing.expect(e.getColor() != .black);
    }
    for (shape.contours[1].edges) |e| {
        try std.testing.expect(e.getColor() != .black);
    }
}
