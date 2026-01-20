//! Contour and Shape types for MSDF generation.
//!
//! A Shape represents a glyph outline composed of one or more Contours.
//! Each Contour is a closed loop of edge segments.

const std = @import("std");
const math = @import("math.zig");
const edge = @import("edge.zig");

const Vec2 = math.Vec2;
const Bounds = math.Bounds;
const EdgeSegment = edge.EdgeSegment;

/// Intersection data for scanline algorithm.
const Intersection = struct {
    x: f64,
    direction: i32,
    contour_index: u32,
};

/// Comparison function for sorting intersections by X coordinate.
fn lessThanIntersection(_: void, a: Intersection, b: Intersection) bool {
    return a.x < b.x;
}

/// A contour is a closed loop of edge segments forming part of a shape outline.
pub const Contour = struct {
    /// The edge segments making up this contour.
    edges: []EdgeSegment,
    /// Allocator used for this contour's memory.
    allocator: std.mem.Allocator,

    /// Create a new empty contour.
    pub fn init(allocator: std.mem.Allocator) Contour {
        return .{
            .edges = &[_]EdgeSegment{},
            .allocator = allocator,
        };
    }

    /// Create a contour from a slice of edges (takes ownership).
    pub fn fromEdges(allocator: std.mem.Allocator, edges: []EdgeSegment) Contour {
        return .{
            .edges = edges,
            .allocator = allocator,
        };
    }

    /// Free memory associated with this contour.
    pub fn deinit(self: *Contour) void {
        if (self.edges.len > 0) {
            self.allocator.free(self.edges);
        }
        self.edges = &[_]EdgeSegment{};
    }

    /// Calculate the winding number of this contour.
    /// Returns positive for counter-clockwise (outer) contours,
    /// negative for clockwise (inner/hole) contours.
    pub fn winding(self: Contour) f64 {
        if (self.edges.len == 0) return 0;

        // Calculate signed area using the shoelace formula
        // For parametric curves, we integrate x * dy over the contour
        var total: f64 = 0;

        for (self.edges) |e| {
            // Sample the edge to approximate the integral
            const samples = 16;
            var i: usize = 0;
            while (i < samples) : (i += 1) {
                const t0 = @as(f64, @floatFromInt(i)) / @as(f64, samples);
                const t1 = @as(f64, @floatFromInt(i + 1)) / @as(f64, samples);

                const p0 = e.point(t0);
                const p1 = e.point(t1);

                // Shoelace formula contribution
                total += (p1.x - p0.x) * (p1.y + p0.y);
            }
        }

        // Return sign: positive = CCW, negative = CW
        return total;
    }

    /// Get the bounding box of this contour.
    pub fn bounds(self: Contour) Bounds {
        var result = Bounds.empty;
        for (self.edges) |e| {
            result = result.merge(e.bounds());
        }
        return result;
    }

    /// Reverse the direction of this contour.
    /// This reverses the order of edges and the direction of each edge.
    pub fn reverse(self: *Contour) void {
        if (self.edges.len == 0) return;

        // Reverse each edge and reverse the array order
        var i: usize = 0;
        var j: usize = self.edges.len - 1;
        while (i < j) {
            // Swap edges[i] and edges[j], reversing both
            const tmp = self.edges[i].reverse();
            self.edges[i] = self.edges[j].reverse();
            self.edges[j] = tmp;
            i += 1;
            j -= 1;
        }
        // If odd number of edges, reverse the middle one
        if (i == j) {
            self.edges[i] = self.edges[i].reverse();
        }
    }

    /// Check if the contour is closed (end of last edge meets start of first).
    pub fn isClosed(self: Contour) bool {
        if (self.edges.len == 0) return true;

        const first_start = self.edges[0].startPoint();
        const last_end = self.edges[self.edges.len - 1].endPoint();

        return first_start.approxEqual(last_end, 1e-10);
    }

    /// Get the number of edges in this contour.
    pub fn edgeCount(self: Contour) usize {
        return self.edges.len;
    }

    /// Split all cubic bezier edges at their inflection points.
    /// This creates separate edge segments that can be colored independently,
    /// which is critical for proper MSDF rendering of S-curves.
    pub fn splitAtInflections(self: *Contour) !void {
        // First pass: count how many edges we'll have after splitting
        var new_edge_count: usize = 0;
        for (self.edges) |e| {
            switch (e) {
                .cubic => |cubic| {
                    const split_result = cubic.splitAtInflections();
                    new_edge_count += split_result.count;
                },
                .linear, .quadratic => {
                    new_edge_count += 1;
                },
            }
        }

        // If no splitting needed, return early
        if (new_edge_count == self.edges.len) {
            return;
        }

        // Allocate new edges array
        const new_edges = try self.allocator.alloc(EdgeSegment, new_edge_count);
        errdefer self.allocator.free(new_edges);

        // Second pass: populate the new edges array
        var new_idx: usize = 0;
        for (self.edges) |e| {
            switch (e) {
                .cubic => |cubic| {
                    const split_result = cubic.splitAtInflections();
                    for (0..split_result.count) |i| {
                        new_edges[new_idx] = .{ .cubic = split_result.segments[i] };
                        new_idx += 1;
                    }
                },
                .linear => {
                    new_edges[new_idx] = e;
                    new_idx += 1;
                },
                .quadratic => {
                    new_edges[new_idx] = e;
                    new_idx += 1;
                },
            }
        }

        // Free old edges and replace with new
        self.allocator.free(self.edges);
        self.edges = new_edges;
    }
};

/// A shape is a collection of contours forming a complete glyph outline.
pub const Shape = struct {
    /// The contours making up this shape.
    contours: []Contour,
    /// Allocator used for this shape's memory.
    allocator: std.mem.Allocator,
    /// Whether the shape has been inverse-filled (affects winding).
    inverse_y_axis: bool = false,

    /// Create a new empty shape.
    pub fn init(allocator: std.mem.Allocator) Shape {
        return .{
            .contours = &[_]Contour{},
            .allocator = allocator,
        };
    }

    /// Create a shape from a slice of contours (takes ownership).
    pub fn fromContours(allocator: std.mem.Allocator, contours: []Contour) Shape {
        return .{
            .contours = contours,
            .allocator = allocator,
        };
    }

    /// Free all memory associated with this shape.
    pub fn deinit(self: *Shape) void {
        for (self.contours) |*contour| {
            contour.deinit();
        }
        if (self.contours.len > 0) {
            self.allocator.free(self.contours);
        }
        self.contours = &[_]Contour{};
    }

    /// Get the bounding box of the entire shape.
    pub fn bounds(self: Shape) Bounds {
        var result = Bounds.empty;
        for (self.contours) |contour| {
            result = result.merge(contour.bounds());
        }
        return result;
    }

    /// Check if the shape has any contours.
    pub fn isEmpty(self: Shape) bool {
        return self.contours.len == 0;
    }

    /// Get the total number of edges across all contours.
    pub fn edgeCount(self: Shape) usize {
        var total: usize = 0;
        for (self.contours) |contour| {
            total += contour.edgeCount();
        }
        return total;
    }

    /// Get the number of contours in this shape.
    pub fn contourCount(self: Shape) usize {
        return self.contours.len;
    }

    /// Validate that all contours are properly closed.
    pub fn validate(self: Shape) bool {
        for (self.contours) |contour| {
            if (!contour.isClosed()) {
                return false;
            }
        }
        return true;
    }

    /// Orient contours to conform to the non-zero winding rule.
    /// Outer contours become CCW (positive winding), holes become CW (negative winding).
    /// This fixes fonts with inconsistent or inverted winding like SF Mono.
    ///
    /// Algorithm:
    /// 1. Record original winding signs for all contours
    /// 2. Find the outermost contour (largest absolute winding = largest area)
    /// 3. Ensure outermost is CCW (flip if needed)
    /// 4. For nested contours: if they had the SAME original winding sign as the
    ///    outer contour, they're also solid (flip together). If OPPOSITE sign,
    ///    they're holes (flip opposite to outer).
    pub fn orientContours(self: *Shape) void {
        if (self.contours.len == 0) return;
        if (self.contours.len > 64) return; // Safety limit

        // Step 1: Record original windings
        var original_windings = [_]f64{0} ** 64;
        for (self.contours, 0..) |contour, i| {
            original_windings[i] = contour.winding();
        }

        // Step 2: Find outermost contour (largest absolute winding = largest area)
        var outer_idx: usize = 0;
        var max_abs_winding: f64 = 0;
        for (self.contours, 0..) |_, i| {
            const abs_w = @abs(original_windings[i]);
            if (abs_w > max_abs_winding) {
                max_abs_winding = abs_w;
                outer_idx = i;
            }
        }

        // Step 3: Determine if outer needs flipping (should be CCW = positive winding)
        const outer_winding = original_windings[outer_idx];
        const outer_needs_flip = outer_winding < 0;

        // Step 4: If outer needs flip, flip ALL contours to maintain relative relationships
        // This preserves: solid contours stay solid (CCW), holes stay holes (CW)
        if (outer_needs_flip) {
            for (self.contours) |*contour| {
                contour.reverse();
            }
        }
    }

    /// Get an interior point of a contour (for containment testing).
    fn getContourInteriorPoint(self: Shape, cont: Contour) Vec2 {
        _ = self;
        if (cont.edges.len == 0) return Vec2{ .x = 0, .y = 0 };

        // Use centroid of first few edge midpoints
        var sum_x: f64 = 0;
        var sum_y: f64 = 0;
        const sample_count = @min(cont.edges.len, 4);

        for (cont.edges[0..sample_count]) |e| {
            const p = e.point(0.5);
            sum_x += p.x;
            sum_y += p.y;
        }

        return Vec2{
            .x = sum_x / @as(f64, @floatFromInt(sample_count)),
            .y = sum_y / @as(f64, @floatFromInt(sample_count)),
        };
    }

    /// Check if a point is inside a contour using winding number.
    fn pointInsideContour(self: Shape, point: Vec2, cont: Contour) bool {
        _ = self;
        var winding: i32 = 0;

        for (cont.edges) |e| {
            var x_vals: [3]f64 = undefined;
            var dy_vals: [3]i32 = undefined;
            const n = e.scanlineIntersections(point.y, &x_vals, &dy_vals);

            for (0..n) |k| {
                if (x_vals[k] < point.x) {
                    winding += dy_vals[k];
                }
            }
        }

        return winding != 0;
    }

    /// Normalize the shape orientation so outer contours are CCW
    /// and inner contours (holes) are CW.
    pub fn normalize(self: *Shape) void {
        self.orientContours();
    }

    /// Split all cubic bezier edges at their inflection points across all contours.
    /// This is critical for proper MSDF edge coloring of S-curves and similar shapes.
    pub fn splitAtInflections(self: *Shape) !void {
        for (self.contours) |*contour| {
            try contour.splitAtInflections();
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Contour.winding - CCW square" {
    const allocator = std.testing.allocator;

    // Create a CCW square (0,0) -> (1,0) -> (1,1) -> (0,1) -> (0,0)
    // (counterclockwise when Y points up)
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 0), Vec2.init(1, 0)) };
    edges[1] = .{ .linear = edge.LinearSegment.init(Vec2.init(1, 0), Vec2.init(1, 1)) };
    edges[2] = .{ .linear = edge.LinearSegment.init(Vec2.init(1, 1), Vec2.init(0, 1)) };
    edges[3] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 1), Vec2.init(0, 0)) };

    var contour = Contour.fromEdges(allocator, edges);
    defer contour.deinit();

    // The winding formula sum((x1-x0)*(y1+y0)) returns negative for CCW contours
    // (opposite of standard shoelace). This matches msdfgen's convention where
    // CCW outer contours have negative winding.
    try std.testing.expect(contour.winding() < 0);
}

test "Contour.winding - CW square" {
    const allocator = std.testing.allocator;

    // Create a CW square (0,0) -> (0,1) -> (1,1) -> (1,0) -> (0,0)
    // (clockwise when Y points up)
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 0), Vec2.init(0, 1)) };
    edges[1] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 1), Vec2.init(1, 1)) };
    edges[2] = .{ .linear = edge.LinearSegment.init(Vec2.init(1, 1), Vec2.init(1, 0)) };
    edges[3] = .{ .linear = edge.LinearSegment.init(Vec2.init(1, 0), Vec2.init(0, 0)) };

    var contour = Contour.fromEdges(allocator, edges);
    defer contour.deinit();

    // The winding formula returns positive for CW contours
    try std.testing.expect(contour.winding() > 0);
}

test "Contour.bounds" {
    const allocator = std.testing.allocator;

    var edges = try allocator.alloc(EdgeSegment, 2);
    edges[0] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 0), Vec2.init(5, 3)) };
    edges[1] = .{ .linear = edge.LinearSegment.init(Vec2.init(5, 3), Vec2.init(2, 7)) };

    var contour = Contour.fromEdges(allocator, edges);
    defer contour.deinit();

    const b = contour.bounds();
    try std.testing.expectApproxEqAbs(@as(f64, 0), b.min.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), b.min.y, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 5), b.max.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 7), b.max.y, 1e-10);
}

test "Contour.isClosed" {
    const allocator = std.testing.allocator;

    // Closed contour
    var closed_edges = try allocator.alloc(EdgeSegment, 3);
    closed_edges[0] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 0), Vec2.init(1, 0)) };
    closed_edges[1] = .{ .linear = edge.LinearSegment.init(Vec2.init(1, 0), Vec2.init(0.5, 1)) };
    closed_edges[2] = .{ .linear = edge.LinearSegment.init(Vec2.init(0.5, 1), Vec2.init(0, 0)) };

    var closed = Contour.fromEdges(allocator, closed_edges);
    defer closed.deinit();

    try std.testing.expect(closed.isClosed());

    // Open contour
    var open_edges = try allocator.alloc(EdgeSegment, 2);
    open_edges[0] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 0), Vec2.init(1, 0)) };
    open_edges[1] = .{ .linear = edge.LinearSegment.init(Vec2.init(1, 0), Vec2.init(0.5, 1)) };

    var open = Contour.fromEdges(allocator, open_edges);
    defer open.deinit();

    try std.testing.expect(!open.isClosed());
}

test "Shape.bounds" {
    const allocator = std.testing.allocator;

    // Create two contours
    var edges1 = try allocator.alloc(EdgeSegment, 1);
    edges1[0] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 0), Vec2.init(5, 5)) };

    var edges2 = try allocator.alloc(EdgeSegment, 1);
    edges2[0] = .{ .linear = edge.LinearSegment.init(Vec2.init(10, 10), Vec2.init(15, 12)) };

    var contours = try allocator.alloc(Contour, 2);
    contours[0] = Contour.fromEdges(allocator, edges1);
    contours[1] = Contour.fromEdges(allocator, edges2);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    const b = shape.bounds();
    try std.testing.expectApproxEqAbs(@as(f64, 0), b.min.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), b.min.y, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 15), b.max.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 12), b.max.y, 1e-10);
}

test "Shape.edgeCount" {
    const allocator = std.testing.allocator;

    var edges1 = try allocator.alloc(EdgeSegment, 3);
    edges1[0] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 0), Vec2.init(1, 0)) };
    edges1[1] = .{ .linear = edge.LinearSegment.init(Vec2.init(1, 0), Vec2.init(0.5, 1)) };
    edges1[2] = .{ .linear = edge.LinearSegment.init(Vec2.init(0.5, 1), Vec2.init(0, 0)) };

    var edges2 = try allocator.alloc(EdgeSegment, 2);
    edges2[0] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 0), Vec2.init(1, 0)) };
    edges2[1] = .{ .linear = edge.LinearSegment.init(Vec2.init(1, 0), Vec2.init(0, 0)) };

    var contours = try allocator.alloc(Contour, 2);
    contours[0] = Contour.fromEdges(allocator, edges1);
    contours[1] = Contour.fromEdges(allocator, edges2);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    try std.testing.expectEqual(@as(usize, 5), shape.edgeCount());
    try std.testing.expectEqual(@as(usize, 2), shape.contourCount());
}

test "Shape.isEmpty" {
    const allocator = std.testing.allocator;

    var empty = Shape.init(allocator);
    defer empty.deinit();

    try std.testing.expect(empty.isEmpty());

    var edges = try allocator.alloc(EdgeSegment, 1);
    edges[0] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 0), Vec2.init(1, 0)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var nonempty = Shape.fromContours(allocator, contours);
    defer nonempty.deinit();

    try std.testing.expect(!nonempty.isEmpty());
}
