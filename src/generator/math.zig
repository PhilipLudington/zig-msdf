//! Core mathematical utilities for MSDF generation.
//!
//! Provides 2D vector operations, signed distance representation,
//! bounding box calculations, and polynomial root solvers.

const std = @import("std");

/// A 2D vector with floating-point components.
pub const Vec2 = struct {
    x: f64,
    y: f64,

    pub const zero = Vec2{ .x = 0, .y = 0 };

    /// Create a new Vec2 from components.
    pub fn init(x: f64, y: f64) Vec2 {
        return .{ .x = x, .y = y };
    }

    /// Add two vectors.
    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    /// Subtract two vectors.
    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    /// Scale a vector by a scalar.
    pub fn scale(self: Vec2, s: f64) Vec2 {
        return .{ .x = self.x * s, .y = self.y * s };
    }

    /// Negate a vector.
    pub fn neg(self: Vec2) Vec2 {
        return .{ .x = -self.x, .y = -self.y };
    }

    /// Compute the dot product of two vectors.
    pub fn dot(self: Vec2, other: Vec2) f64 {
        return self.x * other.x + self.y * other.y;
    }

    /// Compute the 2D cross product (returns scalar z-component).
    /// Positive if `other` is counter-clockwise from `self`.
    pub fn cross(self: Vec2, other: Vec2) f64 {
        return self.x * other.y - self.y * other.x;
    }

    /// Compute the squared length of the vector.
    pub fn lengthSquared(self: Vec2) f64 {
        return self.x * self.x + self.y * self.y;
    }

    /// Compute the length (magnitude) of the vector.
    pub fn length(self: Vec2) f64 {
        return @sqrt(self.lengthSquared());
    }

    /// Normalize the vector to unit length.
    /// Returns zero vector if the input has zero length.
    pub fn normalize(self: Vec2) Vec2 {
        const len = self.length();
        if (len == 0) return Vec2.zero;
        return self.scale(1.0 / len);
    }

    /// Compute the distance between two points.
    pub fn distance(self: Vec2, other: Vec2) f64 {
        return self.sub(other).length();
    }

    /// Compute the squared distance between two points.
    pub fn distanceSquared(self: Vec2, other: Vec2) f64 {
        return self.sub(other).lengthSquared();
    }

    /// Linear interpolation between two vectors.
    pub fn lerp(self: Vec2, other: Vec2, t: f64) Vec2 {
        return .{
            .x = self.x + (other.x - self.x) * t,
            .y = self.y + (other.y - self.y) * t,
        };
    }

    /// Get the perpendicular vector (rotated 90 degrees counter-clockwise).
    pub fn perpendicular(self: Vec2) Vec2 {
        return .{ .x = -self.y, .y = self.x };
    }

    /// Check if two vectors are approximately equal.
    pub fn approxEqual(self: Vec2, other: Vec2, epsilon: f64) bool {
        return @abs(self.x - other.x) < epsilon and @abs(self.y - other.y) < epsilon;
    }
};

/// Represents a signed distance with additional orthogonality information.
/// Used for comparing distances in MSDF generation.
pub const SignedDistance = struct {
    /// The signed distance value (negative = inside, positive = outside).
    distance: f64,
    /// Orthogonality factor (0 = parallel to edge, 1 = perpendicular).
    /// Used as a tiebreaker when distances are equal.
    orthogonality: f64,

    pub const infinite = SignedDistance{
        .distance = std.math.inf(f64),
        .orthogonality = 0,
    };

    /// Create a new SignedDistance.
    pub fn init(dist: f64, ortho: f64) SignedDistance {
        return .{ .distance = dist, .orthogonality = ortho };
    }

    /// Compare two signed distances for MSDF purposes.
    /// Returns true if `self` should be preferred over `other`.
    pub fn lessThan(self: SignedDistance, other: SignedDistance) bool {
        const abs_self = @abs(self.distance);
        const abs_other = @abs(other.distance);
        // Prefer the closer distance, or if equal, the more orthogonal one
        if (abs_self != abs_other) {
            return abs_self < abs_other;
        }
        return self.orthogonality > other.orthogonality;
    }
};

/// An axis-aligned bounding box.
pub const Bounds = struct {
    /// Minimum corner (bottom-left).
    min: Vec2,
    /// Maximum corner (top-right).
    max: Vec2,

    pub const empty = Bounds{
        .min = Vec2{ .x = std.math.inf(f64), .y = std.math.inf(f64) },
        .max = Vec2{ .x = -std.math.inf(f64), .y = -std.math.inf(f64) },
    };

    /// Create bounds from min and max corners.
    pub fn init(min_x: f64, min_y: f64, max_x: f64, max_y: f64) Bounds {
        return .{
            .min = Vec2.init(min_x, min_y),
            .max = Vec2.init(max_x, max_y),
        };
    }

    /// Expand bounds to include a point.
    pub fn include(self: Bounds, point: Vec2) Bounds {
        return .{
            .min = Vec2{
                .x = @min(self.min.x, point.x),
                .y = @min(self.min.y, point.y),
            },
            .max = Vec2{
                .x = @max(self.max.x, point.x),
                .y = @max(self.max.y, point.y),
            },
        };
    }

    /// Merge two bounds.
    pub fn merge(self: Bounds, other: Bounds) Bounds {
        return .{
            .min = Vec2{
                .x = @min(self.min.x, other.min.x),
                .y = @min(self.min.y, other.min.y),
            },
            .max = Vec2{
                .x = @max(self.max.x, other.max.x),
                .y = @max(self.max.y, other.max.y),
            },
        };
    }

    /// Get the width of the bounds.
    pub fn width(self: Bounds) f64 {
        return self.max.x - self.min.x;
    }

    /// Get the height of the bounds.
    pub fn height(self: Bounds) f64 {
        return self.max.y - self.min.y;
    }

    /// Get the center of the bounds.
    pub fn center(self: Bounds) Vec2 {
        return Vec2{
            .x = (self.min.x + self.max.x) * 0.5,
            .y = (self.min.y + self.max.y) * 0.5,
        };
    }

    /// Check if the bounds contain a point.
    pub fn contains(self: Bounds, point: Vec2) bool {
        return point.x >= self.min.x and point.x <= self.max.x and
            point.y >= self.min.y and point.y <= self.max.y;
    }

    /// Check if bounds are valid (non-empty).
    pub fn isValid(self: Bounds) bool {
        return self.min.x <= self.max.x and self.min.y <= self.max.y;
    }
};

/// Result of solving a polynomial equation.
/// Contains 0 to 3 real roots.
pub const PolynomialRoots = struct {
    roots: [3]f64,
    count: u8,

    pub fn init() PolynomialRoots {
        return .{ .roots = undefined, .count = 0 };
    }

    /// Get the roots as a slice.
    pub fn slice(self: *const PolynomialRoots) []const f64 {
        return self.roots[0..self.count];
    }
};

/// Solve a quadratic equation: ax² + bx + c = 0
/// Returns the real roots (0, 1, or 2 solutions).
pub fn solveQuadratic(a: f64, b: f64, c: f64) PolynomialRoots {
    var result = PolynomialRoots.init();

    // Handle degenerate cases
    if (@abs(a) < 1e-14) {
        // Linear equation: bx + c = 0
        if (@abs(b) < 1e-14) {
            // No solution (or infinite solutions if c ≈ 0)
            return result;
        }
        result.roots[0] = -c / b;
        result.count = 1;
        return result;
    }

    const discriminant = b * b - 4 * a * c;

    if (discriminant < 0) {
        // No real roots
        return result;
    } else if (discriminant == 0) {
        // One double root
        result.roots[0] = -b / (2 * a);
        result.count = 1;
    } else {
        // Two distinct roots
        // Use numerically stable formula to avoid catastrophic cancellation
        const sqrt_d = @sqrt(discriminant);
        const q = if (b >= 0)
            -0.5 * (b + sqrt_d)
        else
            -0.5 * (b - sqrt_d);

        result.roots[0] = q / a;
        result.roots[1] = c / q;
        result.count = 2;

        // Sort roots
        if (result.roots[0] > result.roots[1]) {
            const tmp = result.roots[0];
            result.roots[0] = result.roots[1];
            result.roots[1] = tmp;
        }
    }

    return result;
}

/// Solve a cubic equation: ax³ + bx² + cx + d = 0
/// Uses Cardano's formula with numerical stability improvements.
/// Returns the real roots (1, 2, or 3 solutions).
pub fn solveCubic(a: f64, b: f64, c: f64, d: f64) PolynomialRoots {
    var result = PolynomialRoots.init();

    // Handle degenerate case: not actually cubic
    if (@abs(a) < 1e-14) {
        return solveQuadratic(b, c, d);
    }

    // Normalize to monic form: x³ + px² + qx + r = 0
    const p = b / a;
    const q = c / a;
    const r = d / a;

    // Substitute x = t - p/3 to get depressed cubic: t³ + pt + q = 0
    // where p = (3q - p²)/3 and q = (2p³ - 9pq + 27r)/27
    const p_sq = p * p;
    const p_3 = p / 3.0;

    const dep_p = q - p_sq / 3.0;
    const dep_q = (2.0 * p_sq * p - 9.0 * p * q + 27.0 * r) / 27.0;

    // Discriminant for depressed cubic
    const discriminant = dep_q * dep_q / 4.0 + dep_p * dep_p * dep_p / 27.0;

    if (discriminant > 1e-14) {
        // One real root (Cardano's formula)
        const sqrt_d = @sqrt(discriminant);
        const u = cubeRoot(-dep_q / 2.0 + sqrt_d);
        const v = cubeRoot(-dep_q / 2.0 - sqrt_d);

        result.roots[0] = u + v - p_3;
        result.count = 1;
    } else if (discriminant < -1e-14) {
        // Three real roots (trigonometric method)
        const m = 2.0 * @sqrt(-dep_p / 3.0);
        const theta = std.math.acos(3.0 * dep_q / (dep_p * m)) / 3.0;

        result.roots[0] = m * @cos(theta) - p_3;
        result.roots[1] = m * @cos(theta - 2.0 * std.math.pi / 3.0) - p_3;
        result.roots[2] = m * @cos(theta - 4.0 * std.math.pi / 3.0) - p_3;
        result.count = 3;

        // Sort roots
        sortRoots(&result);
    } else {
        // Discriminant ≈ 0: repeated roots
        if (@abs(dep_p) < 1e-14) {
            // Triple root
            result.roots[0] = -p_3;
            result.count = 1;
        } else {
            // One single root and one double root
            const single = 3.0 * dep_q / dep_p - p_3;
            const double_root = -3.0 * dep_q / (2.0 * dep_p) - p_3;

            if (single < double_root) {
                result.roots[0] = single;
                result.roots[1] = double_root;
            } else {
                result.roots[0] = double_root;
                result.roots[1] = single;
            }
            result.count = 2;
        }
    }

    return result;
}

/// Compute the real cube root of a number (handles negative values).
fn cubeRoot(x: f64) f64 {
    if (x >= 0) {
        return std.math.pow(f64, x, 1.0 / 3.0);
    } else {
        return -std.math.pow(f64, -x, 1.0 / 3.0);
    }
}

/// Sort roots in ascending order.
fn sortRoots(result: *PolynomialRoots) void {
    if (result.count < 2) return;

    // Simple insertion sort for small arrays
    var i: u8 = 1;
    while (i < result.count) : (i += 1) {
        const key = result.roots[i];
        var j: i16 = @as(i16, i) - 1;
        while (j >= 0 and result.roots[@intCast(j)] > key) : (j -= 1) {
            result.roots[@intCast(j + 1)] = result.roots[@intCast(j)];
        }
        result.roots[@intCast(j + 1)] = key;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Vec2.add" {
    const a = Vec2.init(1, 2);
    const b = Vec2.init(3, 4);
    const c = a.add(b);
    try std.testing.expectEqual(@as(f64, 4), c.x);
    try std.testing.expectEqual(@as(f64, 6), c.y);
}

test "Vec2.sub" {
    const a = Vec2.init(5, 7);
    const b = Vec2.init(2, 3);
    const c = a.sub(b);
    try std.testing.expectEqual(@as(f64, 3), c.x);
    try std.testing.expectEqual(@as(f64, 4), c.y);
}

test "Vec2.scale" {
    const a = Vec2.init(2, 3);
    const b = a.scale(2.5);
    try std.testing.expectEqual(@as(f64, 5), b.x);
    try std.testing.expectEqual(@as(f64, 7.5), b.y);
}

test "Vec2.dot" {
    const a = Vec2.init(1, 2);
    const b = Vec2.init(3, 4);
    try std.testing.expectEqual(@as(f64, 11), a.dot(b));
}

test "Vec2.cross" {
    const a = Vec2.init(1, 0);
    const b = Vec2.init(0, 1);
    try std.testing.expectEqual(@as(f64, 1), a.cross(b));
    try std.testing.expectEqual(@as(f64, -1), b.cross(a));
}

test "Vec2.length" {
    const a = Vec2.init(3, 4);
    try std.testing.expectEqual(@as(f64, 5), a.length());
}

test "Vec2.normalize" {
    const a = Vec2.init(3, 4);
    const n = a.normalize();
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), n.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), n.y, 1e-10);

    // Zero vector should return zero
    const zero = Vec2.zero.normalize();
    try std.testing.expectEqual(@as(f64, 0), zero.x);
    try std.testing.expectEqual(@as(f64, 0), zero.y);
}

test "Vec2.distance" {
    const a = Vec2.init(0, 0);
    const b = Vec2.init(3, 4);
    try std.testing.expectEqual(@as(f64, 5), a.distance(b));
}

test "Vec2.lerp" {
    const a = Vec2.init(0, 0);
    const b = Vec2.init(10, 20);
    const mid = a.lerp(b, 0.5);
    try std.testing.expectEqual(@as(f64, 5), mid.x);
    try std.testing.expectEqual(@as(f64, 10), mid.y);
}

test "Vec2.perpendicular" {
    const a = Vec2.init(1, 0);
    const p = a.perpendicular();
    try std.testing.expectEqual(@as(f64, 0), p.x);
    try std.testing.expectEqual(@as(f64, 1), p.y);
}

test "SignedDistance.lessThan" {
    const near = SignedDistance.init(1.0, 0.5);
    const far = SignedDistance.init(2.0, 0.5);
    try std.testing.expect(near.lessThan(far));
    try std.testing.expect(!far.lessThan(near));

    // Equal distance: prefer higher orthogonality
    const low_ortho = SignedDistance.init(1.0, 0.3);
    const high_ortho = SignedDistance.init(1.0, 0.7);
    try std.testing.expect(high_ortho.lessThan(low_ortho));
}

test "Bounds.include" {
    var bounds = Bounds.empty;
    bounds = bounds.include(Vec2.init(1, 2));
    bounds = bounds.include(Vec2.init(3, 4));

    try std.testing.expectEqual(@as(f64, 1), bounds.min.x);
    try std.testing.expectEqual(@as(f64, 2), bounds.min.y);
    try std.testing.expectEqual(@as(f64, 3), bounds.max.x);
    try std.testing.expectEqual(@as(f64, 4), bounds.max.y);
}

test "Bounds.merge" {
    const a = Bounds.init(0, 0, 10, 10);
    const b = Bounds.init(5, 5, 15, 15);
    const merged = a.merge(b);

    try std.testing.expectEqual(@as(f64, 0), merged.min.x);
    try std.testing.expectEqual(@as(f64, 0), merged.min.y);
    try std.testing.expectEqual(@as(f64, 15), merged.max.x);
    try std.testing.expectEqual(@as(f64, 15), merged.max.y);
}

test "Bounds.contains" {
    const bounds = Bounds.init(0, 0, 10, 10);
    try std.testing.expect(bounds.contains(Vec2.init(5, 5)));
    try std.testing.expect(bounds.contains(Vec2.init(0, 0)));
    try std.testing.expect(bounds.contains(Vec2.init(10, 10)));
    try std.testing.expect(!bounds.contains(Vec2.init(-1, 5)));
    try std.testing.expect(!bounds.contains(Vec2.init(11, 5)));
}

test "solveQuadratic - two roots" {
    // x² - 5x + 6 = 0 has roots x = 2, x = 3
    const result = solveQuadratic(1, -5, 6);
    try std.testing.expectEqual(@as(u8, 2), result.count);
    try std.testing.expectApproxEqAbs(@as(f64, 2), result.roots[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 3), result.roots[1], 1e-10);
}

test "solveQuadratic - one root" {
    // x² - 2x + 1 = 0 has root x = 1 (double)
    const result = solveQuadratic(1, -2, 1);
    try std.testing.expectEqual(@as(u8, 1), result.count);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.roots[0], 1e-10);
}

test "solveQuadratic - no real roots" {
    // x² + 1 = 0 has no real roots
    const result = solveQuadratic(1, 0, 1);
    try std.testing.expectEqual(@as(u8, 0), result.count);
}

test "solveQuadratic - linear degenerate" {
    // 0x² + 2x - 4 = 0 is linear: x = 2
    const result = solveQuadratic(0, 2, -4);
    try std.testing.expectEqual(@as(u8, 1), result.count);
    try std.testing.expectApproxEqAbs(@as(f64, 2), result.roots[0], 1e-10);
}

test "solveCubic - one root" {
    // x³ + x = 0 at x = 0 (and two complex roots)
    // Actually x³ + x = x(x² + 1) = 0, so only x = 0
    const result = solveCubic(1, 0, 1, 0);
    try std.testing.expectEqual(@as(u8, 1), result.count);
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.roots[0], 1e-10);
}

test "solveCubic - three roots" {
    // x³ - 6x² + 11x - 6 = 0 has roots x = 1, 2, 3
    const result = solveCubic(1, -6, 11, -6);
    try std.testing.expectEqual(@as(u8, 3), result.count);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.roots[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 2), result.roots[1], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 3), result.roots[2], 1e-10);
}

test "solveCubic - quadratic degenerate" {
    // 0x³ + x² - 5x + 6 = 0 reduces to quadratic with roots 2, 3
    const result = solveCubic(0, 1, -5, 6);
    try std.testing.expectEqual(@as(u8, 2), result.count);
    try std.testing.expectApproxEqAbs(@as(f64, 2), result.roots[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 3), result.roots[1], 1e-10);
}
