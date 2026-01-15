//! Edge coloring algorithm for MSDF generation.
//!
//! The edge coloring algorithm assigns colors (channels) to edge segments
//! to ensure that corners and features are properly preserved in the
//! multi-channel signed distance field.
//!
//! The basic principle is that adjacent edges should not share all channels,
//! and corners (sharp direction changes) should have different colors on
//! each side to create a crisp intersection in the output.
//!
//! For S-curves and other shapes with inflection points, cubic bezier edges
//! are split at inflection points before coloring. This creates separate
//! edge segments that can be colored independently.

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
/// First splits cubic edges at inflection points for proper S-curve handling.
pub fn colorEdges(shape: *Shape, angle_threshold: f64) void {
    // Split edges at inflection points before coloring
    // This ensures S-curves and similar shapes get proper color boundaries
    shape.splitAtInflections() catch {
        // If splitting fails (allocation error), continue with original edges
        // The coloring will be suboptimal but still functional
    };

    for (shape.contours) |*contour| {
        colorContour(contour, angle_threshold);
    }
}

/// Color edges in a shape using the default angle threshold.
pub fn colorEdgesSimple(shape: *Shape) void {
    colorEdges(shape, corner_angle_threshold);
}

/// Color edges in a single contour.
/// Edges are assumed to already be split at inflection points (for cubics).
/// Also detects curvature sign changes between adjacent quadratic segments.
fn colorContour(contour: *Contour, angle_threshold: f64) void {
    const edge_count = contour.edges.len;
    if (edge_count == 0) return;

    // Single edge contour: use white (all channels)
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

    // Find color boundaries:
    // 1. Corners (sharp direction changes between edges)
    // 2. Curvature sign reversals (for smooth S-curves made of quadratics)
    var corners_buffer: [256]usize = undefined;
    var corners_len: usize = 0;

    for (0..edge_count) |i| {
        const prev_idx = if (i == 0) edge_count - 1 else i - 1;

        const prev_edge = contour.edges[prev_idx];
        const curr_edge = contour.edges[i];

        // Get outgoing direction of previous edge and incoming direction of current edge
        const prev_dir = prev_edge.direction(1.0).normalize();
        const curr_dir = curr_edge.direction(0.0).normalize();

        // Calculate angle between directions
        const angle = angleBetween(prev_dir, curr_dir);

        // Check for corner (sharp direction change)
        if (angle > angle_threshold) {
            if (corners_len < corners_buffer.len) {
                corners_buffer[corners_len] = i;
                corners_len += 1;
            }
        } else {
            // Check for curvature sign reversal (smooth S-curve)
            // This handles TrueType fonts where S-curves are made of multiple
            // quadratic beziers that smoothly connect but change curvature direction
            //
            // Important: Linear edges have 0 curvature, so we need to look past them
            // to find the actual curved edges and compare their curvatures
            const prev_curv = findPreviousCurvature(contour.edges, i);
            const curr_curv = findCurrentCurvature(contour.edges, i);

            // Curvature sign reversal: one is positive, the other is negative
            // Use a small relative threshold to avoid noise from near-linear segments
            const min_curv = @min(@abs(prev_curv), @abs(curr_curv));
            const max_curv = @max(@abs(prev_curv), @abs(curr_curv));

            // Only consider it a reversal if both have meaningful curvature
            // (not near-linear segments) and they have opposite signs
            const has_meaningful_curvature = max_curv > 0 and min_curv > max_curv * 0.01;
            const opposite_signs = (prev_curv > 0 and curr_curv < 0) or (prev_curv < 0 and curr_curv > 0);

            if (has_meaningful_curvature and opposite_signs) {
                if (corners_len < corners_buffer.len) {
                    corners_buffer[corners_len] = i;
                    corners_len += 1;
                }
            }
        }
    }

    // If no corners or curvature changes detected, use simple alternating colors
    if (corners_len == 0) {
        const colors = [_]EdgeColor{ .cyan, .magenta, .yellow };
        for (contour.edges, 0..) |*e, i| {
            e.setColor(colors[i % 3]);
        }
        return;
    }

    // Color edges between corners/boundaries
    colorBetweenCorners(contour, corners_buffer[0..corners_len]);
}

/// Find the curvature of the previous curved edge (looking past linear edges).
/// Returns 0 if no curved edge found within a reasonable distance.
fn findPreviousCurvature(edges: []EdgeSegment, start_idx: usize) f64 {
    const edge_count = edges.len;
    const max_search = @min(edge_count, 5); // Don't search too far back

    var search_count: usize = 0;
    var idx = if (start_idx == 0) edge_count - 1 else start_idx - 1;

    while (search_count < max_search) : (search_count += 1) {
        const curv = edges[idx].curvatureSign();
        // If this edge has meaningful curvature (not linear), return it
        if (@abs(curv) > 1.0) {
            return curv;
        }

        // Move to previous edge
        idx = if (idx == 0) edge_count - 1 else idx - 1;
    }

    return 0; // No curved edge found
}

/// Find the curvature of the current/next curved edge (looking past linear edges).
/// Returns 0 if no curved edge found within a reasonable distance.
fn findCurrentCurvature(edges: []EdgeSegment, start_idx: usize) f64 {
    const edge_count = edges.len;
    const max_search = @min(edge_count, 5); // Don't search too far forward

    var search_count: usize = 0;
    var idx = start_idx;

    while (search_count < max_search) : (search_count += 1) {
        const curv = edges[idx].curvatureSign();
        // If this edge has meaningful curvature (not linear), return it
        if (@abs(curv) > 1.0) {
            return curv;
        }

        // Move to next edge
        idx = (idx + 1) % edge_count;
    }

    return 0; // No curved edge found
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

        while (true) {
            contour.edges[i].setColor(primary_color);

            i = (i + 1) % edge_count;

            if (i == corner_end) break;
        }

        // Move to next color for the next segment
        segment_color_idx += 1;
    }
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
