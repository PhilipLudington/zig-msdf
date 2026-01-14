//! Edge segment types for MSDF generation.
//!
//! Provides edge color representation and various curve segment types
//! (linear, quadratic, cubic) with signed distance computation.

const std = @import("std");
const math = @import("math.zig");
const Vec2 = math.Vec2;
const SignedDistance = math.SignedDistance;
const Bounds = math.Bounds;

/// Edge colors used in multi-channel signed distance field generation.
/// Each color represents a channel or combination of channels.
pub const EdgeColor = enum(u3) {
    black = 0,
    cyan = 1, // Green + Blue
    magenta = 2, // Red + Blue
    yellow = 3, // Red + Green
    white = 7, // Red + Green + Blue

    /// Check if this edge color contributes to the red channel.
    pub fn hasRed(self: EdgeColor) bool {
        return self == .magenta or self == .yellow or self == .white;
    }

    /// Check if this edge color contributes to the green channel.
    pub fn hasGreen(self: EdgeColor) bool {
        return self == .cyan or self == .yellow or self == .white;
    }

    /// Check if this edge color contributes to the blue channel.
    pub fn hasBlue(self: EdgeColor) bool {
        return self == .cyan or self == .magenta or self == .white;
    }
};

/// A linear edge segment (straight line between two points).
pub const LinearSegment = struct {
    p0: Vec2,
    p1: Vec2,
    color: EdgeColor = .white,

    /// Create a linear segment from two endpoints.
    pub fn init(p0: Vec2, p1: Vec2) LinearSegment {
        return .{ .p0 = p0, .p1 = p1 };
    }

    /// Evaluate the point on the segment at parameter t in [0, 1].
    pub fn point(self: LinearSegment, t: f64) Vec2 {
        return self.p0.lerp(self.p1, t);
    }

    /// Get the direction (tangent) of the segment at parameter t.
    /// For a line, this is constant.
    pub fn direction(self: LinearSegment, t: f64) Vec2 {
        _ = t;
        return self.p1.sub(self.p0);
    }

    /// Compute the signed distance from a point to this segment.
    pub fn signedDistance(self: LinearSegment, origin: Vec2) SignedDistance {
        const dir = self.p1.sub(self.p0);
        const aq = origin.sub(self.p0);

        // Project point onto line, clamped to segment
        const t = std.math.clamp(aq.dot(dir) / dir.lengthSquared(), 0.0, 1.0);

        // Vector from closest point on segment to origin
        const closest = self.p0.add(dir.scale(t));
        const d = origin.sub(closest);

        // Distance magnitude
        const dist = d.length();

        // Determine sign using cross product (inside/outside)
        const sign: f64 = if (dir.cross(aq) < 0) -1.0 else 1.0;

        // Orthogonality: how perpendicular is the distance vector to the edge
        const ortho = if (dist == 0) 0.0 else @abs(dir.normalize().cross(d.normalize()));

        return SignedDistance.init(sign * dist, ortho);
    }

    /// Get the bounding box of this segment.
    pub fn bounds(self: LinearSegment) Bounds {
        return Bounds.empty.include(self.p0).include(self.p1);
    }
};

/// A quadratic Bezier curve segment (one control point).
pub const QuadraticSegment = struct {
    p0: Vec2,
    p1: Vec2, // Control point
    p2: Vec2,
    color: EdgeColor = .white,

    /// Create a quadratic segment from three points.
    pub fn init(p0: Vec2, p1: Vec2, p2: Vec2) QuadraticSegment {
        return .{ .p0 = p0, .p1 = p1, .p2 = p2 };
    }

    /// Evaluate the point on the curve at parameter t in [0, 1].
    pub fn point(self: QuadraticSegment, t: f64) Vec2 {
        const t2 = t * t;
        const mt = 1.0 - t;
        const mt2 = mt * mt;
        return Vec2{
            .x = mt2 * self.p0.x + 2.0 * mt * t * self.p1.x + t2 * self.p2.x,
            .y = mt2 * self.p0.y + 2.0 * mt * t * self.p1.y + t2 * self.p2.y,
        };
    }

    /// Get the direction (tangent) of the curve at parameter t.
    pub fn direction(self: QuadraticSegment, t: f64) Vec2 {
        const mt = 1.0 - t;
        // Derivative: 2(1-t)(P1-P0) + 2t(P2-P1)
        const a = self.p1.sub(self.p0).scale(2.0 * mt);
        const b = self.p2.sub(self.p1).scale(2.0 * t);
        const result = a.add(b);

        // Handle degenerate cases at endpoints
        if (result.lengthSquared() < 1e-14) {
            if (t < 0.5) {
                return self.p2.sub(self.p0);
            } else {
                return self.p2.sub(self.p0);
            }
        }
        return result;
    }

    /// Compute the signed distance from a point to this segment.
    pub fn signedDistance(self: QuadraticSegment, origin: Vec2) SignedDistance {
        // Transform to coefficient form for distance calculation
        // Q(t) = (1-t)²P0 + 2(1-t)tP1 + t²P2
        // Q(t) = P0 - 2P0t + P0t² + 2P1t - 2P1t² + P2t²
        // Q(t) = P0 + t(-2P0 + 2P1) + t²(P0 - 2P1 + P2)
        const qa = self.p0;
        const qb = self.p1.scale(2).sub(self.p0.scale(2));
        const qc = self.p0.sub(self.p1.scale(2)).add(self.p2);

        // Distance squared: |Q(t) - origin|² = (qa-origin + qb*t + qc*t²)²
        // Minimize by taking derivative and setting to zero
        // This gives a cubic equation in t

        const pa = qa.sub(origin);

        // Coefficients of the derivative polynomial (cubic)
        // d/dt |Q(t) - origin|² = 2(Q(t) - origin) · Q'(t)
        // This expands to at³ + bt² + ct + d = 0

        const a = qc.dot(qc);
        const b = 3.0 * qb.dot(qc);
        const c = 2.0 * qb.dot(qb) + 2.0 * pa.dot(qc);
        const d = 2.0 * pa.dot(qb);

        // Solve for critical points
        const roots = math.solveCubic(a, b, c, d);

        // Find minimum distance among critical points and endpoints
        var min_dist = SignedDistance.infinite;

        // Check endpoints
        min_dist = checkDistance(self, 0.0, origin, min_dist);
        min_dist = checkDistance(self, 1.0, origin, min_dist);

        // Check interior critical points
        for (roots.slice()) |t| {
            if (t > 0.0 and t < 1.0) {
                min_dist = checkDistance(self, t, origin, min_dist);
            }
        }

        return min_dist;
    }

    fn checkDistance(self: QuadraticSegment, t: f64, origin: Vec2, current_min: SignedDistance) SignedDistance {
        const p = self.point(t);
        const d = origin.sub(p);
        const dist = d.length();

        // Determine sign using cross product with tangent
        const tangent = self.direction(t);
        const sign: f64 = if (tangent.cross(d) < 0) -1.0 else 1.0;

        // Orthogonality
        const ortho = if (dist == 0) 0.0 else @abs(tangent.normalize().cross(d.normalize()));

        const candidate = SignedDistance.init(sign * dist, ortho);

        if (candidate.lessThan(current_min)) {
            return candidate;
        }
        return current_min;
    }

    /// Get the bounding box of this segment.
    pub fn bounds(self: QuadraticSegment) Bounds {
        var result = Bounds.empty.include(self.p0).include(self.p2);

        // Find extrema in x and y by solving Q'(t) = 0
        // Q'(t) = 2(1-t)(P1-P0) + 2t(P2-P1) = 2[(P0-2P1+P2)t + (P1-P0)]
        const dx = self.p0.x - 2.0 * self.p1.x + self.p2.x;
        const dy = self.p0.y - 2.0 * self.p1.y + self.p2.y;

        if (@abs(dx) > 1e-14) {
            const tx = (self.p0.x - self.p1.x) / dx;
            if (tx > 0 and tx < 1) {
                result = result.include(self.point(tx));
            }
        }

        if (@abs(dy) > 1e-14) {
            const ty = (self.p0.y - self.p1.y) / dy;
            if (ty > 0 and ty < 1) {
                result = result.include(self.point(ty));
            }
        }

        return result;
    }
};

/// A cubic Bezier curve segment (two control points).
/// Needed for OpenType CFF (PostScript) font support.
pub const CubicSegment = struct {
    p0: Vec2,
    p1: Vec2, // Control point 1
    p2: Vec2, // Control point 2
    p3: Vec2,
    color: EdgeColor = .white,

    /// Create a cubic segment from four points.
    pub fn init(p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2) CubicSegment {
        return .{ .p0 = p0, .p1 = p1, .p2 = p2, .p3 = p3 };
    }

    /// Evaluate the point on the curve at parameter t in [0, 1].
    pub fn point(self: CubicSegment, t: f64) Vec2 {
        const t2 = t * t;
        const t3 = t2 * t;
        const mt = 1.0 - t;
        const mt2 = mt * mt;
        const mt3 = mt2 * mt;
        return Vec2{
            .x = mt3 * self.p0.x + 3.0 * mt2 * t * self.p1.x + 3.0 * mt * t2 * self.p2.x + t3 * self.p3.x,
            .y = mt3 * self.p0.y + 3.0 * mt2 * t * self.p1.y + 3.0 * mt * t2 * self.p2.y + t3 * self.p3.y,
        };
    }

    /// Get the direction (tangent) of the curve at parameter t.
    pub fn direction(self: CubicSegment, t: f64) Vec2 {
        const t2 = t * t;
        const mt = 1.0 - t;
        const mt2 = mt * mt;
        // Derivative: 3(1-t)²(P1-P0) + 6(1-t)t(P2-P1) + 3t²(P3-P2)
        const a = self.p1.sub(self.p0).scale(3.0 * mt2);
        const b = self.p2.sub(self.p1).scale(6.0 * mt * t);
        const c = self.p3.sub(self.p2).scale(3.0 * t2);
        const result = a.add(b).add(c);

        // Handle degenerate cases
        if (result.lengthSquared() < 1e-14) {
            // Try second derivative or fall back to chord
            return self.p3.sub(self.p0);
        }
        return result;
    }

    /// Compute the signed distance from a point to this segment.
    /// Uses iterative refinement for cubic curves.
    pub fn signedDistance(self: CubicSegment, origin: Vec2) SignedDistance {
        // For cubic curves, the distance minimization leads to a quintic equation.
        // We use a combination of subdivision and Newton iteration for robustness.

        // Sample points along the curve to find approximate minimum
        const num_samples = 10;
        var min_t: f64 = 0;
        var min_dist_sq: f64 = origin.distanceSquared(self.p0);

        var i: usize = 1;
        while (i <= num_samples) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, num_samples);
            const p = self.point(t);
            const dist_sq = origin.distanceSquared(p);
            if (dist_sq < min_dist_sq) {
                min_dist_sq = dist_sq;
                min_t = t;
            }
        }

        // Refine using Newton iteration
        var t = min_t;
        var iterations: usize = 0;
        while (iterations < 8) : (iterations += 1) {
            const p = self.point(t);
            const d = p.sub(origin);
            const tangent = self.direction(t);

            // f(t) = d · tangent (derivative of distance squared / 2)
            const f = d.dot(tangent);

            // f'(t) = tangent · tangent + d · tangent' (second derivative)
            const tangent_deriv = self.secondDerivative(t);
            const f_prime = tangent.dot(tangent) + d.dot(tangent_deriv);

            if (@abs(f_prime) < 1e-14) break;

            const delta = f / f_prime;
            t = std.math.clamp(t - delta, 0.0, 1.0);

            if (@abs(delta) < 1e-10) break;
        }

        // Also check endpoints
        var best_t = t;
        var best_dist_sq = origin.distanceSquared(self.point(t));

        const dist_0 = origin.distanceSquared(self.p0);
        if (dist_0 < best_dist_sq) {
            best_dist_sq = dist_0;
            best_t = 0;
        }

        const dist_1 = origin.distanceSquared(self.p3);
        if (dist_1 < best_dist_sq) {
            best_dist_sq = dist_1;
            best_t = 1;
        }

        // Compute final signed distance
        const closest = self.point(best_t);
        const d = origin.sub(closest);
        const dist = @sqrt(best_dist_sq);

        const tangent = self.direction(best_t);
        const sign: f64 = if (tangent.cross(d) < 0) -1.0 else 1.0;

        const ortho = if (dist == 0) 0.0 else @abs(tangent.normalize().cross(d.normalize()));

        return SignedDistance.init(sign * dist, ortho);
    }

    /// Get the second derivative of the curve at parameter t.
    fn secondDerivative(self: CubicSegment, t: f64) Vec2 {
        const mt = 1.0 - t;
        // Second derivative: 6(1-t)(P2-2P1+P0) + 6t(P3-2P2+P1)
        const a = self.p2.sub(self.p1.scale(2)).add(self.p0).scale(6.0 * mt);
        const b = self.p3.sub(self.p2.scale(2)).add(self.p1).scale(6.0 * t);
        return a.add(b);
    }

    /// Get the bounding box of this segment.
    pub fn bounds(self: CubicSegment) Bounds {
        var result = Bounds.empty.include(self.p0).include(self.p3);

        // Find extrema by solving Q'(t) = 0 for each axis
        // Q'(t) = 3(1-t)²(P1-P0) + 6(1-t)t(P2-P1) + 3t²(P3-P2)
        // This is a quadratic in t

        // X extrema
        const ax = -self.p0.x + 3.0 * self.p1.x - 3.0 * self.p2.x + self.p3.x;
        const bx = 2.0 * self.p0.x - 4.0 * self.p1.x + 2.0 * self.p2.x;
        const cx = -self.p0.x + self.p1.x;

        const x_roots = math.solveQuadratic(ax, bx, cx);
        for (x_roots.slice()) |tx| {
            if (tx > 0 and tx < 1) {
                result = result.include(self.point(tx));
            }
        }

        // Y extrema
        const ay = -self.p0.y + 3.0 * self.p1.y - 3.0 * self.p2.y + self.p3.y;
        const by = 2.0 * self.p0.y - 4.0 * self.p1.y + 2.0 * self.p2.y;
        const cy = -self.p0.y + self.p1.y;

        const y_roots = math.solveQuadratic(ay, by, cy);
        for (y_roots.slice()) |ty| {
            if (ty > 0 and ty < 1) {
                result = result.include(self.point(ty));
            }
        }

        return result;
    }
};

/// A tagged union representing any edge segment type.
pub const EdgeSegment = union(enum) {
    linear: LinearSegment,
    quadratic: QuadraticSegment,
    cubic: CubicSegment,

    /// Get the color of this edge.
    pub fn getColor(self: EdgeSegment) EdgeColor {
        return switch (self) {
            .linear => |s| s.color,
            .quadratic => |s| s.color,
            .cubic => |s| s.color,
        };
    }

    /// Set the color of this edge.
    pub fn setColor(self: *EdgeSegment, color: EdgeColor) void {
        switch (self.*) {
            .linear => |*s| s.color = color,
            .quadratic => |*s| s.color = color,
            .cubic => |*s| s.color = color,
        }
    }

    /// Evaluate the point on the segment at parameter t in [0, 1].
    pub fn point(self: EdgeSegment, t: f64) Vec2 {
        return switch (self) {
            .linear => |s| s.point(t),
            .quadratic => |s| s.point(t),
            .cubic => |s| s.point(t),
        };
    }

    /// Get the direction (tangent) of the segment at parameter t.
    pub fn direction(self: EdgeSegment, t: f64) Vec2 {
        return switch (self) {
            .linear => |s| s.direction(t),
            .quadratic => |s| s.direction(t),
            .cubic => |s| s.direction(t),
        };
    }

    /// Compute the signed distance from a point to this segment.
    pub fn signedDistance(self: EdgeSegment, origin: Vec2) SignedDistance {
        return switch (self) {
            .linear => |s| s.signedDistance(origin),
            .quadratic => |s| s.signedDistance(origin),
            .cubic => |s| s.signedDistance(origin),
        };
    }

    /// Get the bounding box of this segment.
    pub fn bounds(self: EdgeSegment) Bounds {
        return switch (self) {
            .linear => |s| s.bounds(),
            .quadratic => |s| s.bounds(),
            .cubic => |s| s.bounds(),
        };
    }

    /// Get the start point of this segment.
    pub fn startPoint(self: EdgeSegment) Vec2 {
        return switch (self) {
            .linear => |s| s.p0,
            .quadratic => |s| s.p0,
            .cubic => |s| s.p0,
        };
    }

    /// Get the end point of this segment.
    pub fn endPoint(self: EdgeSegment) Vec2 {
        return switch (self) {
            .linear => |s| s.p1,
            .quadratic => |s| s.p2,
            .cubic => |s| s.p3,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "EdgeColor.hasRed" {
    try std.testing.expect(!EdgeColor.black.hasRed());
    try std.testing.expect(!EdgeColor.cyan.hasRed());
    try std.testing.expect(EdgeColor.magenta.hasRed());
    try std.testing.expect(EdgeColor.yellow.hasRed());
    try std.testing.expect(EdgeColor.white.hasRed());
}

test "EdgeColor.hasGreen" {
    try std.testing.expect(!EdgeColor.black.hasGreen());
    try std.testing.expect(EdgeColor.cyan.hasGreen());
    try std.testing.expect(!EdgeColor.magenta.hasGreen());
    try std.testing.expect(EdgeColor.yellow.hasGreen());
    try std.testing.expect(EdgeColor.white.hasGreen());
}

test "EdgeColor.hasBlue" {
    try std.testing.expect(!EdgeColor.black.hasBlue());
    try std.testing.expect(EdgeColor.cyan.hasBlue());
    try std.testing.expect(EdgeColor.magenta.hasBlue());
    try std.testing.expect(!EdgeColor.yellow.hasBlue());
    try std.testing.expect(EdgeColor.white.hasBlue());
}

test "LinearSegment.point" {
    const seg = LinearSegment.init(Vec2.init(0, 0), Vec2.init(10, 10));
    const mid = seg.point(0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 5), mid.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 5), mid.y, 1e-10);
}

test "LinearSegment.signedDistance" {
    const seg = LinearSegment.init(Vec2.init(0, 0), Vec2.init(10, 0));

    // Point above the line (should be positive, outside)
    const d1 = seg.signedDistance(Vec2.init(5, 3));
    try std.testing.expectApproxEqAbs(@as(f64, 3), d1.distance, 1e-10);

    // Point below the line (should be negative, inside for CCW contour)
    const d2 = seg.signedDistance(Vec2.init(5, -3));
    try std.testing.expectApproxEqAbs(@as(f64, -3), d2.distance, 1e-10);

    // Point on the line
    const d3 = seg.signedDistance(Vec2.init(5, 0));
    try std.testing.expectApproxEqAbs(@as(f64, 0), @abs(d3.distance), 1e-10);
}

test "QuadraticSegment.point" {
    const seg = QuadraticSegment.init(Vec2.init(0, 0), Vec2.init(5, 10), Vec2.init(10, 0));

    // Endpoints
    const start = seg.point(0);
    try std.testing.expectApproxEqAbs(@as(f64, 0), start.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), start.y, 1e-10);

    const end_pt = seg.point(1);
    try std.testing.expectApproxEqAbs(@as(f64, 10), end_pt.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), end_pt.y, 1e-10);

    // Midpoint (should be at (5, 5) for this symmetric curve)
    const mid = seg.point(0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 5), mid.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 5), mid.y, 1e-10);
}

test "CubicSegment.point" {
    const seg = CubicSegment.init(
        Vec2.init(0, 0),
        Vec2.init(0, 10),
        Vec2.init(10, 10),
        Vec2.init(10, 0),
    );

    // Endpoints
    const start = seg.point(0);
    try std.testing.expectApproxEqAbs(@as(f64, 0), start.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), start.y, 1e-10);

    const end_pt = seg.point(1);
    try std.testing.expectApproxEqAbs(@as(f64, 10), end_pt.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), end_pt.y, 1e-10);

    // Midpoint (should be at (5, 7.5) for this curve)
    const mid = seg.point(0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 5), mid.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 7.5), mid.y, 1e-10);
}

test "EdgeSegment union" {
    var edge = EdgeSegment{ .linear = LinearSegment.init(Vec2.init(0, 0), Vec2.init(10, 0)) };

    // Test point evaluation
    const mid = edge.point(0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 5), mid.x, 1e-10);

    // Test color
    try std.testing.expectEqual(EdgeColor.white, edge.getColor());
    edge.setColor(.cyan);
    try std.testing.expectEqual(EdgeColor.cyan, edge.getColor());

    // Test start/end points
    try std.testing.expectApproxEqAbs(@as(f64, 0), edge.startPoint().x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 10), edge.endPoint().x, 1e-10);
}

test "LinearSegment.bounds" {
    const seg = LinearSegment.init(Vec2.init(2, 3), Vec2.init(8, 7));
    const b = seg.bounds();
    try std.testing.expectApproxEqAbs(@as(f64, 2), b.min.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 3), b.min.y, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 8), b.max.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 7), b.max.y, 1e-10);
}

test "QuadraticSegment.bounds" {
    // Curve that extends beyond its endpoints
    const seg = QuadraticSegment.init(Vec2.init(0, 0), Vec2.init(5, 10), Vec2.init(10, 0));
    const b = seg.bounds();

    // Min should be at endpoints (0,0) and (10,0)
    try std.testing.expectApproxEqAbs(@as(f64, 0), b.min.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), b.min.y, 1e-10);

    // Max y should be at the curve peak (5, 5)
    try std.testing.expectApproxEqAbs(@as(f64, 10), b.max.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 5), b.max.y, 1e-10);
}
