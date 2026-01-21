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

const Allocator = std.mem.Allocator;
const Vec2 = math.Vec2;
const EdgeColor = edge_mod.EdgeColor;
const EdgeSegment = edge_mod.EdgeSegment;
const Contour = contour_mod.Contour;
const Shape = contour_mod.Shape;

/// Default threshold angle (in radians) for detecting corners.
/// This value is used to compute a cross-product threshold via sin(angle).
/// msdfgen default is 3.0 radians (~172 degrees), which gives sin(3.0) ≈ 0.14.
/// This means any angle change > ~8 degrees is considered a corner.
pub const default_corner_angle_threshold = 3.0; // msdfgen default

/// Coloring algorithm mode.
pub const ColoringMode = enum {
    /// Simple corner-based coloring (fast, default).
    /// Colors are cycled at detected corners.
    simple,
    /// Distance-based graph coloring (higher quality).
    /// Edges that could create artifacts at similar distances get different colors.
    distance_based,
};

/// Simple PRNG for deterministic color selection.
/// Uses xorshift64 for fast, reproducible pseudorandom numbers.
pub const ColorRng = struct {
    state: u64,

    /// Initialize with a seed. Seed of 0 uses a default starting state.
    pub fn init(seed: u64) ColorRng {
        return .{ .state = if (seed == 0) 0x853c49e6748fea9b else seed };
    }

    /// Generate next pseudorandom number using xorshift64.
    pub fn next(self: *ColorRng) u64 {
        self.state ^= self.state << 13;
        self.state ^= self.state >> 7;
        self.state ^= self.state << 17;
        return self.state;
    }

    /// Select a color different from the current one.
    pub fn selectColor(self: *ColorRng, current: EdgeColor) EdgeColor {
        const available = switch (current) {
            .cyan => [_]EdgeColor{ .magenta, .yellow },
            .magenta => [_]EdgeColor{ .cyan, .yellow },
            .yellow => [_]EdgeColor{ .cyan, .magenta },
            else => [_]EdgeColor{ .cyan, .magenta },
        };
        return available[self.next() % 2];
    }

    /// Select a starting color (cyan, magenta, or yellow).
    pub fn selectStartColor(self: *ColorRng) EdgeColor {
        const colors = [_]EdgeColor{ .cyan, .magenta, .yellow };
        return colors[self.next() % 3];
    }
};

/// Edge coloring configuration.
pub const ColoringConfig = struct {
    /// Coloring algorithm mode (simple or distance_based).
    mode: ColoringMode = .simple,

    /// Corner angle threshold in radians (default: 3.0, ~172°).
    /// Edges meeting at angles sharper than this are colored differently.
    /// Range: 0 to π (0° to 180°).
    corner_angle_threshold: f64 = default_corner_angle_threshold,

    /// Seed for color selection (0 = deterministic default).
    /// Different seeds produce different (but valid) colorings.
    /// Same seed always produces the same result for reproducibility.
    seed: u64 = 0,

    /// Distance threshold for adjacency in distance-based mode.
    /// Edges closer than this threshold are considered adjacent for graph coloring.
    /// Only used when mode is .distance_based.
    distance_threshold: f64 = 0.5,
};

/// Color edges in a shape for MSDF generation with full configuration.
/// This is the main entry point that dispatches to the appropriate algorithm.
///
/// Parameters:
/// - allocator: Required for distance_based mode (ignored for simple mode)
/// - shape: The shape to color
/// - config: Coloring configuration options
///
/// Returns an error only for distance_based mode if allocation fails.
pub fn colorEdgesConfigured(allocator: Allocator, shape: *Shape, config: ColoringConfig) !void {
    switch (config.mode) {
        .simple => colorEdgesWithConfig(shape, config),
        .distance_based => try colorEdgesDistanceBased(allocator, shape, config),
    }
}

/// Color edges in a shape for MSDF generation using config.
/// This assigns colors to edges so that corners are preserved.
/// Note: Unlike some implementations, we do NOT split at inflection points
/// to match msdfgen's behavior exactly.
///
/// IMPORTANT: Color state persists across contours (matching msdfgen).
/// This ensures different contours get different colors for better channel diversity.
pub fn colorEdgesWithConfig(shape: *Shape, config: ColoringConfig) void {
    // Initialize RNG if seed is non-zero
    var rng_state: ?ColorRng = if (config.seed != 0) ColorRng.init(config.seed) else null;
    const rng: ?*ColorRng = if (rng_state != null) &rng_state.? else null;

    // Initialize color state - use RNG if seeded, otherwise start with cyan
    var color: EdgeColor = if (rng) |r| r.selectStartColor() else .cyan;

    for (shape.contours) |*contour| {
        color = colorContourWithStateAndRng(contour, config.corner_angle_threshold, color, rng);
    }
}

/// Color edges in a shape using the provided angle threshold (legacy API).
pub fn colorEdges(shape: *Shape, angle_threshold: f64) void {
    colorEdgesWithConfig(shape, .{ .corner_angle_threshold = angle_threshold });
}

/// Color edges in a shape using the default angle threshold.
pub fn colorEdgesSimple(shape: *Shape) void {
    colorEdgesWithConfig(shape, .{});
}

/// Color edges in a single contour with persistent color state and optional RNG.
/// Uses msdfgen's corner detection: dot <= 0 OR |cross| > sin(angleThreshold).
/// Returns the updated color state for the next contour.
fn colorContourWithStateAndRng(contour: *Contour, angle_threshold: f64, initial_color: EdgeColor, rng: ?*ColorRng) EdgeColor {
    const edge_count = contour.edges.len;
    var color = initial_color;

    if (edge_count == 0) return color;

    // Single edge contour: use white (all channels)
    if (edge_count == 1) {
        contour.edges[0].setColor(.white);
        return color;
    }

    // Two edge contour: switch color and alternate
    if (edge_count == 2) {
        color = switchColorWithRng(color, rng);
        contour.edges[0].setColor(color);
        color = switchColorWithRng(color, rng);
        contour.edges[1].setColor(color);
        return color;
    }

    // Find corners using msdfgen's detection method
    // Corner if: dot(a,b) <= 0 OR |cross(a,b)| > crossThreshold
    const cross_threshold = @sin(angle_threshold);
    var corners_buffer: [256]usize = undefined;
    var corners_len: usize = 0;

    for (0..edge_count) |i| {
        const prev_idx = if (i == 0) edge_count - 1 else i - 1;

        const prev_edge = contour.edges[prev_idx];
        const curr_edge = contour.edges[i];

        // Get outgoing direction of previous edge and incoming direction of current edge
        const prev_dir = prev_edge.direction(1.0).normalize();
        const curr_dir = curr_edge.direction(0.0).normalize();

        // msdfgen corner detection: dot <= 0 OR |cross| > crossThreshold
        const dot = prev_dir.dot(curr_dir);
        const cross = prev_dir.cross(curr_dir);

        if (dot <= 0 or @abs(cross) > cross_threshold) {
            if (corners_len < corners_buffer.len) {
                corners_buffer[corners_len] = i;
                corners_len += 1;
            }
        }
    }

    // If no corners or curvature changes detected (smooth contour),
    // switch color and use same color for all edges (matching msdfgen)
    if (corners_len == 0) {
        color = switchColorWithRng(color, rng);
        for (contour.edges) |*e| {
            e.setColor(color);
        }
        return color;
    }

    // "Teardrop" case: exactly 1 corner
    // msdfgen distributes 3 colors symmetrically around the contour
    if (corners_len == 1) {
        return colorTeardropContourWithRng(contour, corners_buffer[0], &color, rng);
    }

    // Color edges between corners/boundaries
    return colorBetweenCornersWithStateAndRng(contour, corners_buffer[0..corners_len], color, rng);
}

/// Legacy wrapper for colorContourWithStateAndRng without RNG.
fn colorContourWithState(contour: *Contour, angle_threshold: f64, initial_color: EdgeColor) EdgeColor {
    return colorContourWithStateAndRng(contour, angle_threshold, initial_color, null);
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

/// Switch to next color using msdfgen's algorithm with optional RNG.
/// If RNG is provided, select randomly from valid next colors.
/// Otherwise uses deterministic cycle: CYAN -> MAGENTA -> YELLOW -> CYAN -> ...
fn switchColorWithRng(color: EdgeColor, rng: ?*ColorRng) EdgeColor {
    if (rng) |r| {
        return r.selectColor(color);
    }
    // Deterministic version: CYAN (6) -> MAGENTA (5) -> YELLOW (3) -> CYAN (6)
    return switch (color) {
        .cyan => .magenta,
        .magenta => .yellow,
        .yellow => .cyan,
        else => .cyan,
    };
}

/// Switch to next color using msdfgen's algorithm (deterministic).
/// msdfgen uses: shifted = color << (1 + seed_bit); color = (shifted | shifted>>3) & WHITE
/// With seed=0, this gives: CYAN -> MAGENTA -> YELLOW -> CYAN -> ...
fn switchColor(color: EdgeColor) EdgeColor {
    return switchColorWithRng(color, null);
}

/// Symmetrical trichotomy function from msdfgen.
/// For each position < n, returns -1, 0, or 1 depending on whether the position
/// is closer to the beginning, middle, or end respectively.
/// The total for positions 0 through n-1 will be zero (balanced).
fn symmetricalTrichotomy(position: usize, n: usize) i32 {
    if (n <= 1) return 0;
    const pos_f: f64 = @floatFromInt(position);
    const n_f: f64 = @floatFromInt(n - 1);
    // msdfgen formula: int(3 + 2.875 * position / (n-1) - 1.4375 + 0.5) - 3
    const result = @as(i32, @intFromFloat(3.0 + 2.875 * pos_f / n_f - 1.4375 + 0.5)) - 3;
    return result;
}

/// Handle the "teardrop" case: exactly 1 corner detected, with optional RNG.
/// msdfgen distributes 3 colors (color1, WHITE, color2) symmetrically around the contour.
/// This ensures good channel diversity even for smooth S-curves with only one corner.
fn colorTeardropContourWithRng(contour: *Contour, corner: usize, color: *EdgeColor, rng: ?*ColorRng) EdgeColor {
    const edge_count = contour.edges.len;

    // Get three colors: color1, WHITE, color2
    var colors: [3]EdgeColor = undefined;
    color.* = switchColorWithRng(color.*, rng);
    colors[0] = color.*;
    colors[1] = .white;
    color.* = switchColorWithRng(color.*, rng);
    colors[2] = color.*;

    if (edge_count >= 3) {
        // Distribute colors symmetrically using trichotomy
        // Position 0 (at corner) gets middle color (WHITE), positions before get colors[0],
        // positions after get colors[2]
        const m = edge_count;
        for (0..m) |i| {
            const index = (corner + i) % m;
            // trichotomy returns -1 (beginning), 0 (middle), or 1 (end)
            const trich = symmetricalTrichotomy(i, m);
            // Map -1 -> colors[0], 0 -> colors[1], 1 -> colors[2]
            const color_idx: usize = @intCast(trich + 1);
            contour.edges[index].setColor(colors[color_idx]);
        }
    } else if (edge_count == 2) {
        // Two edges: give them different colors
        contour.edges[corner].setColor(colors[0]);
        contour.edges[(corner + 1) % 2].setColor(colors[2]);
    } else if (edge_count == 1) {
        // Single edge: use white
        contour.edges[0].setColor(.white);
    }

    return color.*;
}

/// Legacy wrapper for colorTeardropContourWithRng without RNG.
fn colorTeardropContour(contour: *Contour, corner: usize, color: *EdgeColor) EdgeColor {
    return colorTeardropContourWithRng(contour, corner, color, null);
}

/// Color edges between identified corners with persistent color state and optional RNG.
/// Matches msdfgen's algorithm: ALL edges between corners get the SAME color,
/// and we only switch color at corners.
/// Returns the updated color state for the next contour.
fn colorBetweenCornersWithStateAndRng(contour: *Contour, corners: []const usize, initial_color: EdgeColor, rng: ?*ColorRng) EdgeColor {
    const edge_count = contour.edges.len;
    const corner_count = corners.len;

    // Standard algorithm for 3+ corners
    // Switch color before starting (matching msdfgen)
    var color = switchColorWithRng(initial_color, rng);
    const contour_initial_color = color;

    var spline: usize = 0;
    const start = corners[0];

    var i: usize = 0;
    while (i < edge_count) : (i += 1) {
        const index = (start + i) % edge_count;

        // Check if we've reached the next corner
        if (spline + 1 < corner_count and corners[spline + 1] == index) {
            spline += 1;
            // At the last corner, avoid using contour_initial_color (banned color mechanism)
            if (spline == corner_count - 1) {
                color = switchColorWithRng(color, rng);
                // If we ended up with contour_initial_color, switch again
                if (color == contour_initial_color) {
                    color = switchColorWithRng(color, rng);
                }
            } else {
                color = switchColorWithRng(color, rng);
            }
        }

        contour.edges[index].setColor(color);
    }

    return color;
}

/// Legacy wrapper for colorBetweenCornersWithStateAndRng without RNG.
fn colorBetweenCornersWithState(contour: *Contour, corners: []const usize, initial_color: EdgeColor) EdgeColor {
    return colorBetweenCornersWithStateAndRng(contour, corners, initial_color, null);
}

/// Special handling for contours with few corners but many edges.
/// Distributes 3 colors using trichotomy within each spline for better MSDF diversity.
/// This handles S-curves, smooth arcs, and other shapes with poor natural corner distribution.
fn colorFewCornersTrichotomy(contour: *Contour, corners: []const usize, initial_color: EdgeColor) EdgeColor {
    const edge_count = contour.edges.len;
    const corner_count = corners.len;

    // Get three colors
    const color = switchColor(initial_color);
    const colors = [3]EdgeColor{
        color,
        switchColor(color),
        switchColor(switchColor(color)),
    };

    // For each spline (section between corners), distribute colors using trichotomy
    for (0..corner_count) |spline_idx| {
        const start_corner = corners[spline_idx];
        const end_corner = corners[(spline_idx + 1) % corner_count];

        // Calculate spline size
        const spline_size = if (end_corner > start_corner)
            end_corner - start_corner
        else
            edge_count - start_corner + end_corner;

        if (spline_size == 0) continue;

        // Rotate color palette for each spline for better overall diversity
        const color_offset = spline_idx % 3;
        const spline_colors = [3]EdgeColor{
            colors[color_offset],
            colors[(color_offset + 1) % 3],
            colors[(color_offset + 2) % 3],
        };

        // Distribute colors within this spline using trichotomy
        for (0..spline_size) |i| {
            const index = (start_corner + i) % edge_count;
            const trich = symmetricalTrichotomy(i, spline_size);
            const color_idx: usize = @intCast(trich + 1);
            contour.edges[index].setColor(spline_colors[color_idx]);
        }
    }

    // Return the last color used for state continuity
    return colors[2];
}

/// Detect if a junction between two edges forms a corner.
/// Uses msdfgen's method: dot <= 0 OR |cross| > sin(threshold).
pub fn isCorner(prev_dir: Vec2, curr_dir: Vec2, threshold: f64) bool {
    const a = prev_dir.normalize();
    const b = curr_dir.normalize();
    const cross_threshold = @sin(threshold);
    return a.dot(b) <= 0 or @abs(a.cross(b)) > cross_threshold;
}

/// Get the default corner angle threshold.
pub fn defaultAngleThreshold() f64 {
    return default_corner_angle_threshold;
}

// ============================================================================
// Distance-Based Edge Coloring
// ============================================================================

/// Edge adjacency information for graph coloring.
const EdgeAdjacency = struct {
    contour_idx: usize,
    edge_idx: usize,
    neighbors: std.ArrayListUnmanaged(usize),
    color: EdgeColor,

    fn deinit(self: *EdgeAdjacency, allocator: Allocator) void {
        self.neighbors.deinit(allocator);
    }
};

/// Compute minimum distance between two edge segments using sampling.
fn edgeDistance(e1: EdgeSegment, e2: EdgeSegment) f64 {
    const samples = 8;
    var min_dist: f64 = std.math.inf(f64);

    for (0..samples) |i| {
        const t1 = @as(f64, @floatFromInt(i)) / @as(f64, samples - 1);
        const p1 = e1.point(t1);

        for (0..samples) |j| {
            const t2 = @as(f64, @floatFromInt(j)) / @as(f64, samples - 1);
            const p2 = e2.point(t2);

            const dx = p1.x - p2.x;
            const dy = p1.y - p2.y;
            const dist = @sqrt(dx * dx + dy * dy);
            min_dist = @min(min_dist, dist);
        }
    }
    return min_dist;
}

/// Build adjacency graph for distance-based coloring.
/// Edges are adjacent if they're neighbors in the same contour or
/// if their minimum distance is below the threshold.
fn buildAdjacencyGraph(
    allocator: Allocator,
    shape: *const Shape,
    distance_threshold: f64,
) ![]EdgeAdjacency {
    // Count total edges
    var total_edges: usize = 0;
    for (shape.contours) |contour| {
        total_edges += contour.edges.len;
    }

    if (total_edges == 0) return &[_]EdgeAdjacency{};

    // Create adjacency list for each edge
    var adjacencies = try allocator.alloc(EdgeAdjacency, total_edges);
    errdefer {
        for (adjacencies) |*adj| adj.deinit(allocator);
        allocator.free(adjacencies);
    }

    // Initialize adjacencies
    var flat_idx: usize = 0;
    for (shape.contours, 0..) |contour, ci| {
        for (0..contour.edges.len) |ei| {
            adjacencies[flat_idx] = .{
                .contour_idx = ci,
                .edge_idx = ei,
                .neighbors = .{},
                .color = .white,
            };
            flat_idx += 1;
        }
    }

    // Build flat edge list for distance comparison
    var edge_list = try allocator.alloc(struct { edge: EdgeSegment, contour: usize, idx: usize, flat: usize }, total_edges);
    defer allocator.free(edge_list);

    flat_idx = 0;
    for (shape.contours, 0..) |contour, ci| {
        for (contour.edges, 0..) |edge, ei| {
            edge_list[flat_idx] = .{ .edge = edge, .contour = ci, .idx = ei, .flat = flat_idx };
            flat_idx += 1;
        }
    }

    // Build adjacency based on distance and contour neighbors
    for (edge_list, 0..) |e1, i| {
        for (edge_list, 0..) |e2, j| {
            if (i == j) continue;

            var is_neighbor = false;

            // Adjacent edges in same contour are always neighbors
            if (e1.contour == e2.contour) {
                const contour = shape.contours[e1.contour];
                const edge_count = contour.edges.len;
                const diff = if (e1.idx > e2.idx) e1.idx - e2.idx else e2.idx - e1.idx;
                // Adjacent if indices differ by 1, or wrap around
                if (diff == 1 or diff == edge_count - 1) {
                    is_neighbor = true;
                }
            }

            // Check distance-based adjacency
            if (!is_neighbor and distance_threshold > 0) {
                const dist = edgeDistance(e1.edge, e2.edge);
                if (dist < distance_threshold) {
                    is_neighbor = true;
                }
            }

            if (is_neighbor) {
                try adjacencies[i].neighbors.append(allocator, j);
            }
        }
    }

    return adjacencies;
}

/// Apply greedy graph coloring to the adjacency structure.
fn colorGraphGreedy(adjacencies: []EdgeAdjacency, rng: ?*ColorRng) void {
    const colors = [_]EdgeColor{ .cyan, .magenta, .yellow };

    for (adjacencies) |*adj| {
        // Find colors used by neighbors
        var used = [_]bool{ false, false, false };
        for (adj.neighbors.items) |neighbor_idx| {
            const neighbor_color = adjacencies[neighbor_idx].color;
            const color_idx: ?usize = switch (neighbor_color) {
                .cyan => 0,
                .magenta => 1,
                .yellow => 2,
                else => null,
            };
            if (color_idx) |idx| {
                used[idx] = true;
            }
        }

        // Pick first available color (or use RNG if seeded)
        var selected: ?EdgeColor = null;
        if (rng) |r| {
            const start = r.next() % 3;
            for (0..3) |offset| {
                const idx = (start + offset) % 3;
                if (!used[idx]) {
                    selected = colors[idx];
                    break;
                }
            }
        } else {
            for (colors, 0..) |color, idx| {
                if (!used[idx]) {
                    selected = color;
                    break;
                }
            }
        }

        // Fallback if all colors used (shouldn't happen with 3-colorable graph)
        adj.color = selected orelse .cyan;
    }
}

/// Distance-based edge coloring using graph coloring approach.
/// Treats edges as nodes in a graph where adjacency is based on:
/// 1. Sequential edges in the same contour
/// 2. Edges from different contours that are within distance_threshold
///
/// Uses greedy graph coloring to assign colors such that no two
/// adjacent edges share the same color.
fn colorEdgesDistanceBased(allocator: Allocator, shape: *Shape, config: ColoringConfig) !void {
    // Initialize RNG if seed is non-zero
    var rng_state: ?ColorRng = if (config.seed != 0) ColorRng.init(config.seed) else null;
    const rng: ?*ColorRng = if (rng_state != null) &rng_state.? else null;

    // Build adjacency graph
    const adjacencies = try buildAdjacencyGraph(allocator, shape, config.distance_threshold);
    defer {
        for (adjacencies) |*adj| adj.deinit(allocator);
        allocator.free(adjacencies);
    }

    // Apply greedy coloring
    colorGraphGreedy(adjacencies, rng);

    // Apply colors back to shape
    var flat_idx: usize = 0;
    for (shape.contours) |*contour| {
        for (contour.edges) |*edge| {
            edge.setColor(adjacencies[flat_idx].color);
            flat_idx += 1;
        }
    }
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
    try std.testing.expect(isCorner(prev_dir, curr_dir, defaultAngleThreshold()));
}

test "isCorner - smooth transition" {
    const prev_dir = Vec2.init(1, 0);
    const curr_dir = Vec2.init(1, 0.1); // Almost same direction
    try std.testing.expect(!isCorner(prev_dir, curr_dir, defaultAngleThreshold()));
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
