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
    /// Matches msdfgen's QuadraticSegment::signedDistance exactly.
    pub fn signedDistanceWithParam(self: QuadraticSegment, origin: Vec2) DistanceResult {
        // msdfgen naming: qa = p[0]-origin, ab = p[1]-p[0], br = p[2]-p[1]-ab
        const qa = self.p0.sub(origin);
        const ab = self.p1.sub(self.p0);
        const br = self.p2.sub(self.p1).sub(ab);

        // Cubic coefficients for distance minimization
        // solveCubic(a, b, c, d) solves ax³ + bx² + cx + d = 0
        const a = br.dot(br);
        const b = 3.0 * ab.dot(br);
        const c = 2.0 * ab.dot(ab) + qa.dot(br);
        const d = qa.dot(ab);

        // Solve for critical points
        const roots = math.solveCubic(a, b, c, d);

        // Start with endpoint A (t=0)
        var ep_dir = self.direction(0);
        // msdfgen: nonZeroSign(crossProduct(qa, epDir)) - qa.cross(ep_dir), not ep_dir.cross(qa)
        var min_distance = math.nonZeroSign(qa.cross(ep_dir)) * qa.length();
        // Projected param for pseudo-distance: can be < 0
        var best_param = -qa.dot(ep_dir) / ep_dir.dot(ep_dir);

        // Check endpoint B (t=1)
        const qb = self.p2.sub(origin);
        const dist_b = qb.length();
        if (dist_b < @abs(min_distance)) {
            ep_dir = self.direction(1);
            min_distance = math.nonZeroSign(qb.cross(ep_dir)) * dist_b;
            // msdfgen: dotProduct(origin-p[1], epDir)/dotProduct(epDir, epDir)
            const origin_p1 = origin.sub(self.p1);
            best_param = origin_p1.dot(ep_dir) / ep_dir.dot(ep_dir);
        }

        // Check interior critical points - use <= to favor interior points
        for (roots.slice()) |t| {
            if (t > 0.0 and t < 1.0) {
                // qe = qa + 2*t*ab + t²*br = point(t) - origin
                const t2 = t * t;
                const qe = qa.add(ab.scale(2.0 * t)).add(br.scale(t2));
                const distance = qe.length();

                // msdfgen uses <= for interior points (favor them over endpoints)
                if (distance <= @abs(min_distance)) {
                    // Sign: cross(ab + t*br, qe) - this is the tangent direction
                    const tangent_at_t = ab.add(br.scale(t));
                    min_distance = math.nonZeroSign(tangent_at_t.cross(qe)) * distance;
                    best_param = t;
                }
            }
        }

        // Compute orthogonality based on param
        // msdfgen: interior points (param in [0,1]) get ortho=0
        // Endpoints get ortho = |dot(tangent.normalize(), approach.normalize())|
        var ortho: f64 = 0.0;
        if (best_param < 0.0 or best_param > 1.0) {
            if (best_param < 0.5) {
                // Closer to start
                const dir = self.direction(0).normalize();
                const qa_norm = if (qa.length() > 0) qa.normalize() else Vec2.init(0, 0);
                ortho = @abs(dir.dot(qa_norm));
            } else {
                // Closer to end
                const dir = self.direction(1).normalize();
                const qb_norm = if (qb.length() > 0) qb.normalize() else Vec2.init(0, 0);
                ortho = @abs(dir.dot(qb_norm));
            }
        }

        return DistanceResult.init(SignedDistance.init(min_distance, ortho), best_param);
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
    /// Uses msdfgen-compatible algorithm with multiple search starts and Newton refinement.
    /// Matches msdfgen's CubicSegment::signedDistance exactly.
    pub fn signedDistanceWithParam(self: CubicSegment, origin: Vec2) DistanceResult {
        // msdfgen naming conventions
        const qa = self.p0.sub(origin);
        const ab = self.p1.sub(self.p0);
        const br = self.p2.sub(self.p1).sub(ab);
        const as_vec = self.p3.sub(self.p2).sub(self.p2.sub(self.p1)).sub(br);

        // Start with endpoint A (t=0)
        var ep_dir = self.direction(0);
        // msdfgen: nonZeroSign(crossProduct(qa, epDir)) - qa.cross(ep_dir), not ep_dir.cross(qa)
        var min_distance = math.nonZeroSign(qa.cross(ep_dir)) * qa.length();
        // Projected param for pseudo-distance: can be < 0
        var best_param = -qa.dot(ep_dir) / ep_dir.dot(ep_dir);

        // Check endpoint B (t=1)
        const qb = self.p3.sub(origin);
        const dist_b = qb.length();
        if (dist_b < @abs(min_distance)) {
            ep_dir = self.direction(1);
            min_distance = math.nonZeroSign(qb.cross(ep_dir)) * dist_b;
            // msdfgen: dotProduct(epDir-(p[3]-origin), epDir)/dotProduct(epDir, epDir)
            // This matches the msdfgen formula exactly
            const vec_diff = ep_dir.sub(qb);
            best_param = vec_diff.dot(ep_dir) / ep_dir.dot(ep_dir);
        }

        // Iterative minimum distance search with multiple starting points
        const search_starts: usize = 4; // MSDFGEN_CUBIC_SEARCH_STARTS default
        const search_steps: usize = 4; // MSDFGEN_CUBIC_SEARCH_STEPS default

        var i: usize = 0;
        while (i <= search_starts) : (i += 1) {
            var t = @as(f64, @floatFromInt(i)) / @as(f64, search_starts);

            // qe = qa + 3*t*ab + 3*t²*br + t³*as
            const t2 = t * t;
            const t3 = t2 * t;
            var qe = qa.add(ab.scale(3 * t)).add(br.scale(3 * t2)).add(as_vec.scale(t3));

            // d1 = 3*ab + 6*t*br + 3*t²*as
            var d1 = ab.scale(3).add(br.scale(6 * t)).add(as_vec.scale(3 * t2));

            // d2 = 6*br + 6*t*as
            var d2 = br.scale(6).add(as_vec.scale(6 * t));

            // Newton step
            const denom = d1.dot(d1) + qe.dot(d2);
            if (@abs(denom) < 1e-14) {
                i += 1;
                continue;
            }

            var improved_t = t - qe.dot(d1) / denom;

            if (improved_t > 0 and improved_t < 1) {
                var remaining_steps: usize = search_steps;
                while (remaining_steps > 0) {
                    t = improved_t;
                    const t2_new = t * t;
                    const t3_new = t2_new * t;

                    qe = qa.add(ab.scale(3 * t)).add(br.scale(3 * t2_new)).add(as_vec.scale(t3_new));
                    d1 = ab.scale(3).add(br.scale(6 * t)).add(as_vec.scale(3 * t2_new));

                    remaining_steps -= 1;
                    if (remaining_steps == 0) break;

                    d2 = br.scale(6).add(as_vec.scale(6 * t));
                    const denom_new = d1.dot(d1) + qe.dot(d2);
                    if (@abs(denom_new) < 1e-14) break;

                    improved_t = t - qe.dot(d1) / denom_new;
                    if (improved_t <= 0 or improved_t >= 1) break;
                }

                // Check distance at converged t - use strict < for cubic (matches msdfgen)
                const distance = qe.length();
                if (distance < @abs(min_distance)) {
                    min_distance = math.nonZeroSign(d1.cross(qe)) * distance;
                    best_param = t;
                }
            }
        }

        // Compute orthogonality based on param
        // msdfgen: interior points (param in [0,1]) get ortho=0
        // Endpoints get ortho = |dot(tangent.normalize(), approach.normalize())|
        var ortho: f64 = 0.0;
        if (best_param < 0.0 or best_param > 1.0) {
            if (best_param < 0.5) {
                // Closer to start
                const dir = self.direction(0).normalize();
                const qa_norm = if (qa.length() > 0) qa.normalize() else Vec2.init(0, 0);
                ortho = @abs(dir.dot(qa_norm));
            } else {
                // Closer to end
                const dir = self.direction(1).normalize();
                const qb_norm = if (qb.length() > 0) qb.normalize() else Vec2.init(0, 0);
                ortho = @abs(dir.dot(qb_norm));
            }
        }

        return DistanceResult.init(SignedDistance.init(min_distance, ortho), best_param);
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

    /// Reverse the direction of this edge segment.
    /// This swaps the start and end points while preserving the shape.
    pub fn reverse(self: EdgeSegment) EdgeSegment {
        return switch (self) {
            .linear => |s| EdgeSegment{
                .linear = .{
                    .p0 = s.p1,
                    .p1 = s.p0,
                    .color = s.color,
                },
            },
            .quadratic => |s| EdgeSegment{
                .quadratic = .{
                    .p0 = s.p2,
                    .p1 = s.p1, // control point stays
                    .p2 = s.p0,
                    .color = s.color,
                },
            },
            .cubic => |s| EdgeSegment{
                .cubic = .{
                    .p0 = s.p3,
                    .p1 = s.p2, // swap control points
                    .p2 = s.p1,
                    .p3 = s.p0,
                    .color = s.color,
                },
            },
        };
    }

    /// Find scanline intersections with this edge at a given Y coordinate.
    /// Returns the X coordinates and Y-direction (+1 or -1) of each intersection.
    /// Returns the number of intersections found (0-3).
    pub fn scanlineIntersections(self: EdgeSegment, y: f64, x_out: *[3]f64, dy_out: *[3]i32) u32 {
        return switch (self) {
            .linear => |s| scanlineLinear(s, y, x_out, dy_out),
            .quadratic => |s| scanlineQuadratic(s, y, x_out, dy_out),
            .cubic => |s| scanlineCubic(s, y, x_out, dy_out),
        };
    }
};

/// Scanline intersection for linear segment.
fn scanlineLinear(s: LinearSegment, y: f64, x_out: *[3]f64, dy_out: *[3]i32) u32 {
    // Check if scanline crosses the edge
    if ((s.p0.y >= y and s.p1.y < y) or (s.p0.y < y and s.p1.y >= y)) {
        // Linear interpolation to find X at the intersection
        const t = (y - s.p0.y) / (s.p1.y - s.p0.y);
        x_out[0] = s.p0.x + t * (s.p1.x - s.p0.x);
        // Direction: positive if going up, negative if going down
        dy_out[0] = if (s.p1.y > s.p0.y) @as(i32, 1) else @as(i32, -1);
        return 1;
    }
    return 0;
}

/// Scanline intersection for quadratic bezier.
fn scanlineQuadratic(s: QuadraticSegment, y: f64, x_out: *[3]f64, dy_out: *[3]i32) u32 {
    // Solve: (1-t)^2*p0.y + 2*(1-t)*t*p1.y + t^2*p2.y = y
    // This is a quadratic in t: at^2 + bt + c = 0
    const a = s.p0.y - 2 * s.p1.y + s.p2.y;
    const b = 2 * (s.p1.y - s.p0.y);
    const c = s.p0.y - y;

    var count: u32 = 0;
    var roots: [2]f64 = undefined;
    var root_count: u32 = 0;

    if (@abs(a) < 1e-14) {
        // Linear case
        if (@abs(b) > 1e-14) {
            roots[0] = -c / b;
            root_count = 1;
        }
    } else {
        // Quadratic formula
        const discriminant = b * b - 4 * a * c;
        if (discriminant >= 0) {
            const sqrt_d = @sqrt(discriminant);
            const inv_2a = 1.0 / (2.0 * a);
            roots[0] = (-b - sqrt_d) * inv_2a;
            roots[1] = (-b + sqrt_d) * inv_2a;
            root_count = 2;
        }
    }

    for (0..root_count) |i| {
        const t = roots[i];
        if (t > 0 and t < 1) {
            x_out[count] = s.point(t).x;
            // Direction is sign of derivative at t
            const dir_y = s.direction(t).y;
            dy_out[count] = if (dir_y > 0) @as(i32, 1) else if (dir_y < 0) @as(i32, -1) else @as(i32, 0);
            count += 1;
        }
    }
    return count;
}

/// Scanline intersection for cubic bezier.
fn scanlineCubic(s: CubicSegment, y: f64, x_out: *[3]f64, dy_out: *[3]i32) u32 {
    // Solve: cubic bezier y-coordinate = y
    // Using Cardano's formula for cubic roots
    const p0 = s.p0.y - y;
    const p1 = s.p1.y - y;
    const p2 = s.p2.y - y;
    const p3 = s.p3.y - y;

    // Cubic coefficients: at^3 + bt^2 + ct + d = 0
    const a = -p0 + 3 * p1 - 3 * p2 + p3;
    const b = 3 * p0 - 6 * p1 + 3 * p2;
    const c = -3 * p0 + 3 * p1;
    const d = p0;

    var count: u32 = 0;
    var roots: [3]f64 = undefined;
    const root_count = solveCubic(&roots, a, b, c, d);

    for (0..root_count) |i| {
        const t = roots[i];
        if (t > 0 and t < 1) {
            x_out[count] = s.point(t).x;
            // Direction is sign of derivative at t
            const dir_y = s.direction(t).y;
            dy_out[count] = if (dir_y > 0) @as(i32, 1) else if (dir_y < 0) @as(i32, -1) else @as(i32, 0);
            count += 1;
        }
    }
    return count;
}

/// Solve cubic equation ax^3 + bx^2 + cx + d = 0
/// Returns number of real roots and fills roots array
fn solveCubic(roots: *[3]f64, a: f64, b: f64, c: f64, d: f64) u32 {
    const epsilon = 1e-14;

    // Handle degenerate cases
    if (@abs(a) < epsilon) {
        // Quadratic
        if (@abs(b) < epsilon) {
            // Linear
            if (@abs(c) < epsilon) {
                return 0;
            }
            roots[0] = -d / c;
            return 1;
        }
        const disc = c * c - 4 * b * d;
        if (disc < 0) return 0;
        const sqrt_disc = @sqrt(disc);
        const inv_2b = 1.0 / (2.0 * b);
        roots[0] = (-c - sqrt_disc) * inv_2b;
        roots[1] = (-c + sqrt_disc) * inv_2b;
        return 2;
    }

    // Normalize to t^3 + pt + q = 0 (Cardano's form)
    const p = (3 * a * c - b * b) / (3 * a * a);
    const q = (2 * b * b * b - 9 * a * b * c + 27 * a * a * d) / (27 * a * a * a);
    const offset = -b / (3 * a);

    const disc = q * q / 4 + p * p * p / 27;

    if (disc > epsilon) {
        // One real root
        const sqrt_disc = @sqrt(disc);
        const u = cubeRoot(-q / 2 + sqrt_disc);
        const v = cubeRoot(-q / 2 - sqrt_disc);
        roots[0] = u + v + offset;
        return 1;
    } else if (disc < -epsilon) {
        // Three real roots (casus irreducibilis)
        const r = @sqrt(-p * p * p / 27);
        const phi = std.math.acos(-q / (2 * r));
        const cube_r = cubeRoot(r);
        roots[0] = 2 * cube_r * @cos(phi / 3) + offset;
        roots[1] = 2 * cube_r * @cos((phi + 2 * std.math.pi) / 3) + offset;
        roots[2] = 2 * cube_r * @cos((phi + 4 * std.math.pi) / 3) + offset;
        return 3;
    } else {
        // Double or triple root
        const u = cubeRoot(-q / 2);
        roots[0] = 2 * u + offset;
        roots[1] = -u + offset;
        return 2;
    }
}

fn cubeRoot(x: f64) f64 {
    if (x >= 0) {
        return std.math.pow(f64, x, 1.0 / 3.0);
    } else {
        return -std.math.pow(f64, -x, 1.0 / 3.0);
    }
}

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
/// Algorithm (matching msdfgen's distanceToPerpendicularDistance):
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
    // Sign convention: cross(point - p0, direction) / |direction|
    //   - Negative = point is to the LEFT of edge direction
    //   - Positive = point is to the RIGHT of edge direction
    const seg = LinearSegment.init(Vec2.init(0, 0), Vec2.init(10, 0));

    // Point above the line (y=3) is to the LEFT of "rightward" direction
    // LEFT = negative distance
    const d1 = seg.signedDistance(Vec2.init(5, 3));
    try std.testing.expectApproxEqAbs(@as(f64, -3), d1.distance, 1e-10);

    // Point below the line (y=-3) is to the RIGHT of "rightward" direction
    // RIGHT = positive distance
    const d2 = seg.signedDistance(Vec2.init(5, -3));
    try std.testing.expectApproxEqAbs(@as(f64, 3), d2.distance, 1e-10);

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
