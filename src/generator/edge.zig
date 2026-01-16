//! Edge segment types for MSDF generation.
//!
//! Provides edge color representation and various curve segment types
//! (linear, quadratic, cubic) with signed distance computation.

const std = @import("std");
const math = @import("math.zig");
const Vec2 = math.Vec2;
const SignedDistance = math.SignedDistance;
const DistanceResult = math.DistanceResult;
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
    /// For interior points (0 < t < 1), uses perpendicular distance to the infinite
    /// line, matching msdfgen behavior. For endpoint regions, uses true distance.
    pub fn signedDistance(self: LinearSegment, origin: Vec2) SignedDistance {
        return self.signedDistanceWithParam(origin).distance;
    }

    /// Compute the signed distance and closest parameter from a point to this segment.
    /// Returns both the distance and the parameter t where the closest point lies.
    /// The parameter may be outside [0,1] for points beyond the segment endpoints.
    ///
    /// This implementation matches msdfgen's LinearSegment::signedDistance exactly.
    pub fn signedDistanceWithParam(self: LinearSegment, origin: Vec2) DistanceResult {
        const aq = origin.sub(self.p0); // origin - p0
        const ab = self.p1.sub(self.p0); // direction vector
        const ab_len_sq = ab.lengthSquared();

        // Handle degenerate segment (zero length) - return infinite distance
        // This prevents division by zero and ensures degenerate edges don't affect results
        if (ab_len_sq < 1e-12) {
            return DistanceResult.init(SignedDistance.infinite, 0.0);
        }

        // Project point onto line (unclamped parameter)
        const param = aq.dot(ab) / ab_len_sq;

        // eq = closer endpoint - origin (used for endpoint distance and sign)
        const endpoint = if (param > 0.5) self.p1 else self.p0;
        const eq = endpoint.sub(origin);
        const endpoint_distance = eq.length();

        // For interior points, check if perpendicular distance is closer
        if (param > 0.0 and param < 1.0) {
            // orthoDistance = dot(ab.getOrthonormal(false), aq)
            // getOrthonormal(false) of (x,y) = (y,-x)/len, so dot with aq gives:
            // (ab.y * aq.x - ab.x * aq.y) / |ab| = cross(aq, ab) / |ab|
            const ortho_distance = aq.cross(ab) / @sqrt(ab_len_sq);

            // msdfgen: only use orthoDistance if |orthoDistance| < endpointDistance
            if (@abs(ortho_distance) < endpoint_distance) {
                return DistanceResult.init(SignedDistance.init(ortho_distance, 0.0), param);
            }
        }

        // For endpoint regions, or when perpendicular distance is farther
        // sign = nonZeroSign(crossProduct(ab, eq))
        const cross_val = ab.cross(eq);
        const sign: f64 = if (cross_val >= 0) 1.0 else -1.0;

        // Orthogonality = |dot(ab.normalize(), eq.normalize())|
        const ortho = if (endpoint_distance == 0) 0.0 else @abs(ab.normalize().dot(eq.normalize()));

        return DistanceResult.init(SignedDistance.init(sign * endpoint_distance, ortho), param);
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
        return self.signedDistanceWithParam(origin).distance;
    }

    /// Compute the signed distance and closest parameter from a point to this segment.
    pub fn signedDistanceWithParam(self: QuadraticSegment, origin: Vec2) DistanceResult {
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
        // d/dt |Q(t) - origin|² = 2(Q(t) - origin) · Q'(t) = 0
        // Expanding (pa + qb*t + qc*t²) · (qb + 2*qc*t) = 0 gives:
        // pa·qb + (2*pa·qc + qb·qb)*t + 3*qb·qc*t² + 2*qc·qc*t³ = 0
        // This is: at³ + bt² + ct + d = 0

        const a = 2.0 * qc.dot(qc);
        const b = 3.0 * qb.dot(qc);
        const c = qb.dot(qb) + 2.0 * pa.dot(qc);
        const d = pa.dot(qb);

        // Solve for critical points
        const roots = math.solveCubic(a, b, c, d);

        // Find minimum distance among critical points and endpoints
        var min_dist = SignedDistance.infinite;
        var best_t: f64 = 0.0;

        // Check endpoints
        const check0 = checkDistanceQuad(self, 0.0, origin);
        if (check0.distance.lessThan(min_dist)) {
            min_dist = check0.distance;
            best_t = 0.0;
        }

        const check1 = checkDistanceQuad(self, 1.0, origin);
        if (check1.distance.lessThan(min_dist)) {
            min_dist = check1.distance;
            best_t = 1.0;
        }

        // Check interior critical points
        for (roots.slice()) |t| {
            if (t > 0.0 and t < 1.0) {
                const check = checkDistanceQuad(self, t, origin);
                if (check.distance.lessThan(min_dist)) {
                    min_dist = check.distance;
                    best_t = t;
                }
            }
        }

        return DistanceResult.init(min_dist, best_t);
    }

    fn checkDistanceQuad(self: QuadraticSegment, t: f64, origin: Vec2) struct { distance: SignedDistance } {
        const p = self.point(t);
        const qp = p.sub(origin); // point - origin
        const dist = qp.length();

        // Determine sign using cross product - matches msdfgen exactly
        // msdfgen uses different vectors for endpoints vs interior:
        // - t=0: cross(p1-p0, p0-origin)
        // - t=1: cross(p2-p1, p2-origin)
        // - interior: cross(direction(t), point(t)-origin)
        const cross_val = if (t <= 0.0) blk: {
            // Start point: use first control leg
            const ab = self.p1.sub(self.p0);
            const qa = self.p0.sub(origin);
            break :blk ab.cross(qa);
        } else if (t >= 1.0) blk: {
            // End point: use second control leg
            const bc = self.p2.sub(self.p1);
            const qc = self.p2.sub(origin);
            break :blk bc.cross(qc);
        } else blk: {
            // Interior: use actual tangent
            const tangent = self.direction(t);
            break :blk tangent.cross(qp);
        };

        const sign: f64 = if (cross_val >= 0) 1.0 else -1.0;

        // Orthogonality = |dot(tangent, approach_dir)|
        // 0 = perpendicular (best), 1 = parallel (worst)
        // This matches msdfgen's convention
        const tangent = self.direction(t);
        const ortho = if (dist == 0) 0.0 else @abs(tangent.normalize().dot(qp.normalize()));

        return .{ .distance = SignedDistance.init(sign * dist, ortho) };
    }

    /// Get the curvature sign of this quadratic bezier.
    /// Returns positive for counter-clockwise curvature, negative for clockwise.
    /// Returns 0 for degenerate (linear) cases.
    pub fn curvatureSign(self: QuadraticSegment) f64 {
        // For a quadratic bezier, the curvature sign is constant and determined
        // by the cross product of the two control legs: (p1-p0) × (p2-p1)
        const leg1 = self.p1.sub(self.p0);
        const leg2 = self.p2.sub(self.p1);
        return leg1.cross(leg2);
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

/// Result of finding inflection points in a bezier curve.
pub const InflectionResult = struct {
    points: [2]f64,
    count: u8,
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
        return self.signedDistanceWithParam(origin).distance;
    }

    /// Compute the signed distance and closest parameter from a point to this segment.
    pub fn signedDistanceWithParam(self: CubicSegment, origin: Vec2) DistanceResult {
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
        const qp = closest.sub(origin); // point - origin
        const dist = @sqrt(best_dist_sq);

        // Determine sign using cross product - matches msdfgen exactly
        // msdfgen uses different vectors for endpoints vs interior:
        // - t=0: cross(p1-p0, p0-origin)
        // - t=1: cross(p3-p2, p3-origin)
        // - interior: cross(direction(t), point(t)-origin)
        const cross_val = if (best_t <= 0.0) blk: {
            // Start point: use first control leg
            const ab = self.p1.sub(self.p0);
            const qa = self.p0.sub(origin);
            break :blk ab.cross(qa);
        } else if (best_t >= 1.0) blk: {
            // End point: use last control leg
            const cd = self.p3.sub(self.p2);
            const qd = self.p3.sub(origin);
            break :blk cd.cross(qd);
        } else blk: {
            // Interior: use actual tangent
            const tangent = self.direction(best_t);
            break :blk tangent.cross(qp);
        };

        const sign: f64 = if (cross_val >= 0) 1.0 else -1.0;

        // Orthogonality = |dot(tangent, approach_dir)|
        // 0 = perpendicular (best), 1 = parallel (worst)
        const tangent = self.direction(best_t);
        const ortho = if (dist == 0) 0.0 else @abs(tangent.normalize().dot(qp.normalize()));

        return DistanceResult.init(SignedDistance.init(sign * dist, ortho), best_t);
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

    /// Find inflection points of this cubic bezier curve.
    /// Inflection points occur where the curvature changes sign (crosses zero).
    /// Returns t values in (0, 1) where inflection occurs.
    ///
    /// The cross product B'(t) × B''(t) = 0 at inflection points.
    /// This expands to a quadratic equation: At² + Bt + C = 0
    pub fn findInflectionPoints(self: CubicSegment) InflectionResult {
        // Compute coefficients for the inflection point equation
        // e0 = p1 - p0
        // e1 = p2 - 2*p1 + p0
        // e2 = p3 - 3*p2 + 3*p1 - p0
        //
        // Cross product B'(t) × B''(t) = 18 * (e0×e1 + e0×e2*t + e1×e2*t²)

        const e0 = self.p1.sub(self.p0);
        const e1 = self.p2.sub(self.p1.scale(2)).add(self.p0);
        const e2 = self.p3.sub(self.p2.scale(3)).add(self.p1.scale(3)).sub(self.p0);

        // Quadratic coefficients (ignoring the constant 18 factor)
        const a = e1.cross(e2); // coefficient of t²
        const b = e0.cross(e2); // coefficient of t
        const c = e0.cross(e1); // constant term

        var result = InflectionResult{ .points = undefined, .count = 0 };

        // Solve At² + Bt + C = 0
        const roots = math.solveQuadratic(a, b, c);

        // Filter roots to (0, 1) range - we only care about interior inflection points
        for (roots.slice()) |t| {
            if (t > 0.01 and t < 0.99) {
                result.points[result.count] = t;
                result.count += 1;
            }
        }

        // Sort results
        if (result.count == 2 and result.points[0] > result.points[1]) {
            const tmp = result.points[0];
            result.points[0] = result.points[1];
            result.points[1] = tmp;
        }

        return result;
    }

    /// Check if this cubic curve has any inflection points in its interior.
    pub fn hasInflectionPoints(self: CubicSegment) bool {
        return self.findInflectionPoints().count > 0;
    }

    /// Split this cubic bezier at parameter t using de Casteljau's algorithm.
    /// Returns two cubic segments: [0, t] and [t, 1].
    pub fn splitAt(self: CubicSegment, t: f64) struct { first: CubicSegment, second: CubicSegment } {
        // De Casteljau's algorithm for cubic bezier subdivision
        // Level 1: interpolate between adjacent control points
        const p01 = self.p0.lerp(self.p1, t);
        const p12 = self.p1.lerp(self.p2, t);
        const p23 = self.p2.lerp(self.p3, t);

        // Level 2: interpolate between level 1 points
        const p012 = p01.lerp(p12, t);
        const p123 = p12.lerp(p23, t);

        // Level 3: the split point
        const p0123 = p012.lerp(p123, t);

        return .{
            .first = CubicSegment{
                .p0 = self.p0,
                .p1 = p01,
                .p2 = p012,
                .p3 = p0123,
                .color = self.color,
            },
            .second = CubicSegment{
                .p0 = p0123,
                .p1 = p123,
                .p2 = p23,
                .p3 = self.p3,
                .color = self.color,
            },
        };
    }

    /// Split this cubic bezier at all inflection points.
    /// Returns 1-3 segments depending on the number of inflection points.
    pub fn splitAtInflections(self: CubicSegment) struct { segments: [3]CubicSegment, count: u8 } {
        const inflections = self.findInflectionPoints();

        if (inflections.count == 0) {
            return .{ .segments = .{ self, undefined, undefined }, .count = 1 };
        }

        if (inflections.count == 1) {
            const split = self.splitAt(inflections.points[0]);
            return .{ .segments = .{ split.first, split.second, undefined }, .count = 2 };
        }

        // Two inflection points - need to split twice
        // First split at the first inflection point
        const split1 = self.splitAt(inflections.points[0]);

        // The second inflection point needs to be remapped to the second segment's parameter space
        // Original t2 is in [0, 1], but now we need it relative to [t1, 1]
        // New parameter = (t2 - t1) / (1 - t1)
        const t1 = inflections.points[0];
        const t2 = inflections.points[1];
        const t2_remapped = (t2 - t1) / (1.0 - t1);

        const split2 = split1.second.splitAt(t2_remapped);

        return .{ .segments = .{ split1.first, split2.first, split2.second }, .count = 3 };
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

    /// Compute the signed distance and closest parameter from a point to this segment.
    /// Returns both the distance and the parameter t where the closest point lies.
    pub fn signedDistanceWithParam(self: EdgeSegment, origin: Vec2) DistanceResult {
        return switch (self) {
            .linear => |s| s.signedDistanceWithParam(origin),
            .quadratic => |s| s.signedDistanceWithParam(origin),
            .cubic => |s| s.signedDistanceWithParam(origin),
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

    /// Find inflection points within this edge segment.
    /// Only cubic beziers can have inflection points.
    /// Returns t values in (0, 1) where inflection occurs.
    pub fn findInflectionPoints(self: EdgeSegment) InflectionResult {
        return switch (self) {
            .cubic => |s| s.findInflectionPoints(),
            // Linear and quadratic segments have no inflection points
            .linear, .quadratic => InflectionResult{ .points = undefined, .count = 0 },
        };
    }

    /// Check if this edge has any inflection points.
    pub fn hasInflectionPoints(self: EdgeSegment) bool {
        return switch (self) {
            .cubic => |s| s.hasInflectionPoints(),
            .linear, .quadratic => false,
        };
    }

    /// Get the curvature sign of this edge segment.
    /// For quadratic beziers, returns the constant curvature sign.
    /// For cubic beziers, returns the curvature sign at the midpoint.
    /// For linear segments, returns 0.
    pub fn curvatureSign(self: EdgeSegment) f64 {
        return switch (self) {
            .quadratic => |s| s.curvatureSign(),
            .cubic => |s| {
                // For cubics, calculate curvature at midpoint
                // This is an approximation - cubics can have varying curvature
                const d1 = s.direction(0.5);
                const d2 = s.secondDerivative(0.5);
                return d1.cross(d2);
            },
            .linear => 0,
        };
    }
};

/// Convert a true signed distance to pseudo-distance.
///
/// This is a key function for MSDF quality. When the closest point on an edge
/// is at or beyond an endpoint (param <= 0 or param >= 1), the true distance
/// is the Euclidean distance to that endpoint. However, this causes problems
/// at corners where multiple edges meet at the same point.
///
/// Pseudo-distance instead extends the edge's tangent line infinitely and
/// uses the perpendicular distance to that extended line when the query point
/// is "beyond" the endpoint in the tangent direction.
///
/// This creates smoother transitions at corners because different colored edges
/// meeting at a corner will have different pseudo-distances based on their
/// respective tangent directions.
///
/// Algorithm (matches msdfgen):
/// - If param < 0: extend tangent at t=0 backward
///   - If point is "behind" the start (dot < 0), use perpendicular distance
/// - If param > 1: extend tangent at t=1 forward
///   - If point is "beyond" the end (dot > 0), use perpendicular distance
/// - Only update if perpendicular distance magnitude <= true distance magnitude
pub fn distanceToPseudoDistance(edge: EdgeSegment, origin: Vec2, distance: *SignedDistance, param: f64) void {
    if (param < 0) {
        // Closest point was before the segment start
        const dir = edge.direction(0).normalize();
        const aq = origin.sub(edge.startPoint());
        const ts = aq.dot(dir);

        // Only convert if the point is "behind" the start (in negative tangent direction)
        if (ts < 0) {
            // Perpendicular distance to the tangent line extension
            // msdfgen uses crossProduct(aq, dir)
            const perpendicular_distance = aq.cross(dir);
            // Only use pseudo-distance if it's closer or equal to true distance
            if (@abs(perpendicular_distance) <= @abs(distance.distance)) {
                distance.distance = perpendicular_distance;
                distance.orthogonality = 0; // Perfect orthogonality for perpendicular approach
            }
        }
    } else if (param > 1) {
        // Closest point was after the segment end
        const dir = edge.direction(1).normalize();
        const bq = origin.sub(edge.endPoint());
        const ts = bq.dot(dir);

        // Only convert if the point is "beyond" the end (in positive tangent direction)
        if (ts > 0) {
            // Perpendicular distance to the tangent line extension
            // msdfgen uses crossProduct(bq, dir)
            const perpendicular_distance = bq.cross(dir);
            // Only use pseudo-distance if it's closer or equal to true distance
            if (@abs(perpendicular_distance) <= @abs(distance.distance)) {
                distance.distance = perpendicular_distance;
                distance.orthogonality = 0; // Perfect orthogonality for perpendicular approach
            }
        }
    }
    // If param is in [0, 1], the closest point is on the interior of the segment
    // and no conversion is needed - true distance is correct
}

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
    // Edge going left-to-right along X axis: (0,0) -> (10,0)
    // Sign convention matches msdfgen reference implementation
    const seg = LinearSegment.init(Vec2.init(0, 0), Vec2.init(10, 0));

    // Point above the line - positive distance (outside in msdfgen convention)
    const d1 = seg.signedDistance(Vec2.init(5, 3));
    try std.testing.expectApproxEqAbs(@as(f64, 3), d1.distance, 1e-10);

    // Point below the line - negative distance (inside in msdfgen convention)
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

test "QuadraticSegment.signedDistance - point on curve" {
    const seg = QuadraticSegment.init(Vec2.init(0, 0), Vec2.init(5, 10), Vec2.init(10, 0));

    // Point exactly on the curve at t=0.5 (which is at (5, 5))
    const d = seg.signedDistance(Vec2.init(5, 5));
    try std.testing.expectApproxEqAbs(@as(f64, 0), @abs(d.distance), 1e-6);
}

test "QuadraticSegment.signedDistance - point above curve" {
    // Curve goes from (0,0) to (10,0) with control point at (5,10)
    // Peak is around (5,5). Sign convention matches msdfgen reference.
    const seg = QuadraticSegment.init(Vec2.init(0, 0), Vec2.init(5, 10), Vec2.init(10, 0));

    // Point above the curve peak - positive distance in msdfgen convention
    const d = seg.signedDistance(Vec2.init(5, 8));
    try std.testing.expect(d.distance > 0);
    // Distance should be approximately 3 (from (5,5) to (5,8))
    try std.testing.expectApproxEqAbs(@as(f64, 3), @abs(d.distance), 0.1);
}

test "QuadraticSegment.signedDistance - point at endpoint" {
    const seg = QuadraticSegment.init(Vec2.init(0, 0), Vec2.init(5, 10), Vec2.init(10, 0));

    // Point at start endpoint
    const d = seg.signedDistance(Vec2.init(0, 0));
    try std.testing.expectApproxEqAbs(@as(f64, 0), @abs(d.distance), 1e-10);
}

test "CubicSegment.signedDistance - point on curve" {
    const seg = CubicSegment.init(
        Vec2.init(0, 0),
        Vec2.init(0, 10),
        Vec2.init(10, 10),
        Vec2.init(10, 0),
    );

    // Point at t=0.5 (which is at (5, 7.5))
    const d = seg.signedDistance(Vec2.init(5, 7.5));
    try std.testing.expectApproxEqAbs(@as(f64, 0), @abs(d.distance), 1e-4);
}

test "CubicSegment.signedDistance - point at endpoint" {
    const seg = CubicSegment.init(
        Vec2.init(0, 0),
        Vec2.init(0, 10),
        Vec2.init(10, 10),
        Vec2.init(10, 0),
    );

    // Point at start endpoint
    const d1 = seg.signedDistance(Vec2.init(0, 0));
    try std.testing.expectApproxEqAbs(@as(f64, 0), @abs(d1.distance), 1e-10);

    // Point at end endpoint
    const d2 = seg.signedDistance(Vec2.init(10, 0));
    try std.testing.expectApproxEqAbs(@as(f64, 0), @abs(d2.distance), 1e-10);
}

test "CubicSegment.signedDistance - point away from curve" {
    const seg = CubicSegment.init(
        Vec2.init(0, 0),
        Vec2.init(0, 10),
        Vec2.init(10, 10),
        Vec2.init(10, 0),
    );

    // Point far from the curve
    const d = seg.signedDistance(Vec2.init(5, 20));
    // Should have a significant positive distance
    try std.testing.expect(@abs(d.distance) > 10);
}

test "CubicSegment.bounds" {
    const seg = CubicSegment.init(
        Vec2.init(0, 0),
        Vec2.init(0, 10),
        Vec2.init(10, 10),
        Vec2.init(10, 0),
    );
    const b = seg.bounds();

    // Endpoints are at (0,0) and (10,0)
    try std.testing.expectApproxEqAbs(@as(f64, 0), b.min.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), b.min.y, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 10), b.max.x, 1e-10);
    // Max y should be at the curve peak (around 7.5)
    try std.testing.expectApproxEqAbs(@as(f64, 7.5), b.max.y, 0.1);
}

test "CubicSegment.findInflectionPoints - S-curve has inflection" {
    // An S-curve shape: starts going up-right, then curves down-right
    // This should have one inflection point in the middle
    const seg = CubicSegment.init(
        Vec2.init(0, 0),
        Vec2.init(0, 10), // Control pulls up
        Vec2.init(10, -10), // Control pulls down
        Vec2.init(10, 0),
    );

    const result = seg.findInflectionPoints();

    // S-curve should have exactly one inflection point
    try std.testing.expectEqual(@as(u8, 1), result.count);
    // Inflection should be in the interior
    try std.testing.expect(result.points[0] > 0.1);
    try std.testing.expect(result.points[0] < 0.9);
}

test "CubicSegment.findInflectionPoints - no inflection for simple curve" {
    // A simple curve that arcs in one direction - no inflection
    const seg = CubicSegment.init(
        Vec2.init(0, 0),
        Vec2.init(3, 10),
        Vec2.init(7, 10),
        Vec2.init(10, 0),
    );

    const result = seg.findInflectionPoints();

    // Simple arc should have no interior inflection points
    try std.testing.expectEqual(@as(u8, 0), result.count);
}

test "CubicSegment.findInflectionPoints - line has no inflection" {
    // Degenerate case: a straight line (all points collinear)
    const seg = CubicSegment.init(
        Vec2.init(0, 0),
        Vec2.init(3, 3),
        Vec2.init(7, 7),
        Vec2.init(10, 10),
    );

    const result = seg.findInflectionPoints();
    try std.testing.expectEqual(@as(u8, 0), result.count);
}

test "CubicSegment.hasInflectionPoints" {
    // S-curve should have inflection
    const s_curve = CubicSegment.init(
        Vec2.init(0, 0),
        Vec2.init(0, 10),
        Vec2.init(10, -10),
        Vec2.init(10, 0),
    );
    try std.testing.expect(s_curve.hasInflectionPoints());

    // Simple arc should not
    const arc = CubicSegment.init(
        Vec2.init(0, 0),
        Vec2.init(3, 10),
        Vec2.init(7, 10),
        Vec2.init(10, 0),
    );
    try std.testing.expect(!arc.hasInflectionPoints());
}

test "EdgeSegment.findInflectionPoints - cubic" {
    const s_curve = CubicSegment.init(
        Vec2.init(0, 0),
        Vec2.init(0, 10),
        Vec2.init(10, -10),
        Vec2.init(10, 0),
    );
    const edge = EdgeSegment{ .cubic = s_curve };

    const result = edge.findInflectionPoints();
    try std.testing.expectEqual(@as(u8, 1), result.count);
}

test "EdgeSegment.findInflectionPoints - linear has none" {
    const line = LinearSegment.init(Vec2.init(0, 0), Vec2.init(10, 10));
    const edge = EdgeSegment{ .linear = line };

    const result = edge.findInflectionPoints();
    try std.testing.expectEqual(@as(u8, 0), result.count);
}

test "EdgeSegment.findInflectionPoints - quadratic has none" {
    const quad = QuadraticSegment.init(
        Vec2.init(0, 0),
        Vec2.init(5, 10),
        Vec2.init(10, 0),
    );
    const edge = EdgeSegment{ .quadratic = quad };

    const result = edge.findInflectionPoints();
    try std.testing.expectEqual(@as(u8, 0), result.count);
}
