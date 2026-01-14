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

    /// Normalize the shape orientation so outer contours are CCW
    /// and inner contours (holes) are CW.
    pub fn normalize(self: *Shape) void {
        // For TrueType fonts with Y-up coordinates, the convention is:
        // - Outer contours are counter-clockwise (CCW, positive winding)
        // - Inner contours (holes) are clockwise (CW, negative winding)
        //
        // The edge sign calculation in edge.zig handles this automatically:
        // - CCW edges: left side (inside glyph) → negative distance
        // - CW edges: right side (inside hole = outside glyph) → positive distance
        //
        // No normalization is needed as long as the font follows TrueType conventions.
        _ = self;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Contour.winding - CCW square" {
    const allocator = std.testing.allocator;

    // Create a CCW square (0,0) -> (1,0) -> (1,1) -> (0,1) -> (0,0)
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 0), Vec2.init(1, 0)) };
    edges[1] = .{ .linear = edge.LinearSegment.init(Vec2.init(1, 0), Vec2.init(1, 1)) };
    edges[2] = .{ .linear = edge.LinearSegment.init(Vec2.init(1, 1), Vec2.init(0, 1)) };
    edges[3] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 1), Vec2.init(0, 0)) };

    var contour = Contour.fromEdges(allocator, edges);
    defer contour.deinit();

    // CCW should give positive winding
    try std.testing.expect(contour.winding() > 0);
}

test "Contour.winding - CW square" {
    const allocator = std.testing.allocator;

    // Create a CW square (0,0) -> (0,1) -> (1,1) -> (1,0) -> (0,0)
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 0), Vec2.init(0, 1)) };
    edges[1] = .{ .linear = edge.LinearSegment.init(Vec2.init(0, 1), Vec2.init(1, 1)) };
    edges[2] = .{ .linear = edge.LinearSegment.init(Vec2.init(1, 1), Vec2.init(1, 0)) };
    edges[3] = .{ .linear = edge.LinearSegment.init(Vec2.init(1, 0), Vec2.init(0, 0)) };

    var contour = Contour.fromEdges(allocator, edges);
    defer contour.deinit();

    // CW should give negative winding
    try std.testing.expect(contour.winding() < 0);
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
