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
//! This implementation also detects inflection points in cubic bezier curves
//! and treats them as color change boundaries, which is critical for proper
//! rendering of S-curves and similar shapes.

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

/// Represents a point where color should change - either a corner between edges
/// or an inflection point within an edge.
const ColorBoundary = struct {
    edge_index: usize,
    /// If >= 0, this is an inflection point at parameter t within the edge.
    /// If < 0, this is a corner at the start of the edge.
    t_param: f64,

    fn isCorner(self: ColorBoundary) bool {
        return self.t_param < 0;
    }

    fn isInflection(self: ColorBoundary) bool {
        return self.t_param >= 0;
    }
};

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

    // Single edge contour: check for inflection points
    if (edge_count == 1) {
        const inflections = contour.edges[0].findInflectionPoints();
        if (inflections.count > 0) {
            // Single edge with inflection - use white but mark as having features
            // In practice, this edge should be split, but for now we use white
            contour.edges[0].setColor(.white);
        } else {
            contour.edges[0].setColor(.white);
        }
        return;
    }

    // Two edge contour: alternate colors
    if (edge_count == 2) {
        contour.edges[0].setColor(.cyan);
        contour.edges[1].setColor(.magenta);
        return;
    }

    // Find all color boundaries: corners AND inflection points
    var boundaries_buffer: [512]ColorBoundary = undefined;
    var boundaries_len: usize = 0;

    for (0..edge_count) |i| {
        const prev_idx = if (i == 0) edge_count - 1 else i - 1;

        const prev_edge = contour.edges[prev_idx];
        const curr_edge = contour.edges[i];

        // Get outgoing direction of previous edge and incoming direction of current edge
        const prev_dir = prev_edge.direction(1.0).normalize();
        const curr_dir = curr_edge.direction(0.0).normalize();

        // Calculate angle between directions
        const angle = angleBetween(prev_dir, curr_dir);

        // Check for corner
        if (angle > angle_threshold) {
            if (boundaries_len < boundaries_buffer.len) {
                boundaries_buffer[boundaries_len] = .{
                    .edge_index = i,
                    .t_param = -1.0, // Negative indicates corner at edge start
                };
                boundaries_len += 1;
            }
        }

        // Check for inflection points within current edge
        const inflections = curr_edge.findInflectionPoints();
        for (0..inflections.count) |j| {
            if (boundaries_len < boundaries_buffer.len) {
                boundaries_buffer[boundaries_len] = .{
                    .edge_index = i,
                    .t_param = inflections.points[j],
                };
                boundaries_len += 1;
            }
        }
    }

    // If no boundaries detected (no corners AND no inflection points),
    // treat the whole contour as smooth - use simple alternating colors
    if (boundaries_len == 0) {
        const colors = [_]EdgeColor{ .cyan, .magenta, .yellow };
        for (contour.edges, 0..) |*e, i| {
            e.setColor(colors[i % 3]);
        }
        return;
    }

    // Color edges based on boundaries
    // Each segment between boundaries gets a different color
    colorWithBoundaries(contour, boundaries_buffer[0..boundaries_len]);
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

/// Color edges based on detected boundaries (corners and inflection points).
/// This is the main coloring function that handles both types of boundaries.
fn colorWithBoundaries(contour: *Contour, boundaries: []const ColorBoundary) void {
    const edge_count = contour.edges.len;

    // Available colors for alternating - these are the primary MSDF colors
    const color_set = [_]EdgeColor{ .cyan, .magenta, .yellow };

    // Sort boundaries by edge index, then by t parameter within edge
    // We need a sorted copy to process in order
    var sorted_boundaries: [512]ColorBoundary = undefined;
    @memcpy(sorted_boundaries[0..boundaries.len], boundaries);
    sortBoundaries(sorted_boundaries[0..boundaries.len]);

    // Track which color segment each edge belongs to
    var edge_colors: [512]EdgeColor = undefined;
    var segment_idx: usize = 0;

    // Process boundaries in order
    var boundary_idx: usize = 0;
    var current_edge: usize = 0;

    // Start with first color
    var current_color = color_set[0];

    // Handle wrap-around: if first boundary is not at edge 0, start from beginning
    if (boundaries.len > 0) {
        const first = sorted_boundaries[0];
        // Color edges before the first boundary
        while (current_edge < first.edge_index) {
            edge_colors[current_edge] = current_color;
            current_edge += 1;
        }

        // If first boundary is an inflection point (not at edge start), color that edge too
        if (first.isInflection()) {
            edge_colors[current_edge] = current_color;
        }
    }

    // Process each boundary
    while (boundary_idx < boundaries.len) {
        const boundary = sorted_boundaries[boundary_idx];

        // Change color at this boundary
        segment_idx += 1;
        current_color = color_set[segment_idx % color_set.len];

        // Determine the edge range for this color segment
        const next_boundary_idx = boundary_idx + 1;
        const next_edge_start: usize = if (boundary.isCorner())
            boundary.edge_index
        else
            boundary.edge_index; // Inflection points don't change the edge, just the color

        var segment_end_edge: usize = undefined;
        if (next_boundary_idx < boundaries.len) {
            const next_boundary = sorted_boundaries[next_boundary_idx];
            segment_end_edge = next_boundary.edge_index;
            // If next boundary is an inflection, include that edge
            if (next_boundary.isInflection()) {
                segment_end_edge += 1;
            }
        } else {
            // Wrap around to first boundary
            const first = sorted_boundaries[0];
            segment_end_edge = first.edge_index + edge_count;
            if (first.isInflection()) {
                segment_end_edge += 1;
            }
        }

        // Color edges in this segment
        var edge_idx = next_edge_start;
        while (edge_idx < segment_end_edge) {
            const actual_idx = edge_idx % edge_count;
            edge_colors[actual_idx] = current_color;
            edge_idx += 1;
        }

        boundary_idx += 1;
    }

    // Apply colors to edges
    for (0..edge_count) |i| {
        contour.edges[i].setColor(edge_colors[i]);
    }

    // Post-processing: ensure edges with inflection points use white
    // This provides all channels for the inflection transition
    for (0..edge_count) |i| {
        if (contour.edges[i].hasInflectionPoints()) {
            // Edges with inflection points should use white (all channels)
            // to ensure proper distance field behavior at the inflection
            contour.edges[i].setColor(.white);
        }
    }

    // Ensure adjacent edges have different colors where needed
    ensureColorDiversity(contour);
}

/// Sort boundaries by edge index, then by t parameter.
fn sortBoundaries(boundaries: []ColorBoundary) void {
    // Simple insertion sort (adequate for small arrays)
    var i: usize = 1;
    while (i < boundaries.len) : (i += 1) {
        const key = boundaries[i];
        var j: i32 = @intCast(i);
        j -= 1;
        while (j >= 0) : (j -= 1) {
            const idx: usize = @intCast(j);
            if (compareBoundaries(boundaries[idx], key)) {
                break;
            }
            boundaries[idx + 1] = boundaries[idx];
        }
        const insert_idx: usize = @intCast(j + 1);
        boundaries[insert_idx] = key;
    }
}

/// Compare two boundaries for sorting (returns true if a should come before b).
fn compareBoundaries(a: ColorBoundary, b: ColorBoundary) bool {
    if (a.edge_index != b.edge_index) {
        return a.edge_index < b.edge_index;
    }
    // For same edge, corners (t < 0) come before inflection points
    // Then sort by t parameter
    if (a.t_param < 0 and b.t_param >= 0) return true;
    if (a.t_param >= 0 and b.t_param < 0) return false;
    return a.t_param < b.t_param;
}

/// Ensure color diversity: adjacent edges at corners should have different colors.
fn ensureColorDiversity(contour: *Contour) void {
    const edge_count = contour.edges.len;
    if (edge_count < 2) return;

    const color_set = [_]EdgeColor{ .cyan, .magenta, .yellow, .white };

    // Check each pair of adjacent edges
    for (0..edge_count) |i| {
        const next_i = (i + 1) % edge_count;
        const curr_color = contour.edges[i].getColor();
        const next_color = contour.edges[next_i].getColor();

        // If colors are the same and neither is white, try to fix
        if (curr_color == next_color and curr_color != .white) {
            // Find a different color for the next edge
            for (color_set) |new_color| {
                if (new_color != curr_color) {
                    // Check if this edge has inflection points - if so, keep white
                    if (!contour.edges[next_i].hasInflectionPoints()) {
                        contour.edges[next_i].setColor(new_color);
                    }
                    break;
                }
            }
        }
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
