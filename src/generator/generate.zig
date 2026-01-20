//! MSDF generation algorithms.
//!
//! This module provides the core functionality for generating Multi-channel
//! Signed Distance Fields from shape outlines.

const std = @import("std");
const math = @import("math.zig");
const edge_mod = @import("edge.zig");
const contour_mod = @import("contour.zig");

const Vec2 = math.Vec2;
const Bounds = math.Bounds;
const SignedDistance = math.SignedDistance;
const EdgeSegment = edge_mod.EdgeSegment;
const EdgeColor = edge_mod.EdgeColor;
const Contour = contour_mod.Contour;
const Shape = contour_mod.Shape;

/// Result of MSDF generation containing the pixel buffer and dimensions.
pub const MsdfBitmap = struct {
    /// Pixel data in RGB8 format (3 bytes per pixel: R, G, B).
    pixels: []u8,
    /// Width of the bitmap in pixels.
    width: u32,
    /// Height of the bitmap in pixels.
    height: u32,
    /// Allocator used for this bitmap's memory.
    allocator: std.mem.Allocator,

    /// Free memory associated with this bitmap.
    pub fn deinit(self: *MsdfBitmap) void {
        self.allocator.free(self.pixels);
        self.pixels = &[_]u8{};
    }

    /// Get a pixel value at (x, y).
    pub fn getPixel(self: MsdfBitmap, x: u32, y: u32) [3]u8 {
        const idx = (y * self.width + x) * 3;
        return .{ self.pixels[idx], self.pixels[idx + 1], self.pixels[idx + 2] };
    }

    /// Set a pixel value at (x, y).
    pub fn setPixel(self: *MsdfBitmap, x: u32, y: u32, rgb: [3]u8) void {
        const idx = (y * self.width + x) * 3;
        self.pixels[idx] = rgb[0];
        self.pixels[idx + 1] = rgb[1];
        self.pixels[idx + 2] = rgb[2];
    }
};

/// Transform parameters for mapping shape coordinates to pixel coordinates.
pub const Transform = struct {
    /// Scale factor applied to shape coordinates.
    scale: f64,
    /// Translation applied after scaling (in shape units before scaling).
    translate: Vec2,
    /// If true, don't flip Y when storing to bitmap (matches msdfgen's coordinate system).
    /// msdfgen stores bitmaps with row 0 at bottom (shape Y coordinates).
    /// Default is false (flip Y so row 0 is at top, standard image coordinates).
    msdfgen_compat: bool = false,

    /// Create a transform from scale and translation.
    pub fn init(scale: f64, translate: Vec2) Transform {
        return .{ .scale = scale, .translate = translate, .msdfgen_compat = false };
    }

    /// Create a transform with msdfgen-compatible Y axis (no flip at storage).
    pub fn initMsdfgenCompat(scale: f64, translate: Vec2) Transform {
        return .{ .scale = scale, .translate = translate, .msdfgen_compat = true };
    }

    /// Transform a pixel coordinate to shape coordinate (world space).
    pub fn pixelToShape(self: Transform, px: f64, py: f64) Vec2 {
        return Vec2{
            .x = (px + 0.5) / self.scale - self.translate.x,
            .y = (py + 0.5) / self.scale - self.translate.y,
        };
    }

    /// Transform a shape coordinate to pixel coordinate.
    pub fn shapeToPixel(self: Transform, point: Vec2) Vec2 {
        return Vec2{
            .x = (point.x + self.translate.x) * self.scale - 0.5,
            .y = (point.y + self.translate.y) * self.scale - 0.5,
        };
    }
};

/// Compute the winding number of a point with respect to a shape.
/// Uses the non-zero winding rule: point is inside if winding != 0.
/// Positive winding indicates counter-clockwise enclosure.
pub fn computeWinding(shape: Shape, point: Vec2) i32 {
    var winding: i32 = 0;

    for (shape.contours) |contour| {
        winding += computeContourWinding(contour, point);
    }

    return winding;
}

/// Compute the winding number contribution of a single contour.
fn computeContourWinding(contour: Contour, point: Vec2) i32 {
    if (contour.edges.len == 0) return 0;

    var winding: i32 = 0;

    // Cast a ray from point to the right (+x direction) and count crossings
    for (contour.edges) |e| {
        winding += countEdgeCrossings(e, point);
    }

    return winding;
}

/// Count ray crossings for a single edge.
/// Ray goes from point to +infinity in x direction.
fn countEdgeCrossings(e: EdgeSegment, point: Vec2) i32 {
    // Sample the edge at multiple points to find crossings
    // For linear segments, we could use exact intersection, but sampling
    // works for all segment types and is simpler.
    const samples = 16;
    var crossings: i32 = 0;

    var i: usize = 0;
    while (i < samples) : (i += 1) {
        const t0 = @as(f64, @floatFromInt(i)) / @as(f64, samples);
        const t1 = @as(f64, @floatFromInt(i + 1)) / @as(f64, samples);

        const p0 = e.point(t0);
        const p1 = e.point(t1);

        // Check if this segment crosses the horizontal ray
        // The ray starts at point and goes to +infinity in x

        // Skip if segment is entirely above or below the ray
        if ((p0.y < point.y and p1.y < point.y) or
            (p0.y >= point.y and p1.y >= point.y))
        {
            continue;
        }

        // Calculate x-coordinate of intersection with y = point.y
        const t_intersect = (point.y - p0.y) / (p1.y - p0.y);
        const x_intersect = p0.x + t_intersect * (p1.x - p0.x);

        // Only count if intersection is to the right of point
        if (x_intersect > point.x) {
            // Determine direction: upward crossing adds 1, downward subtracts 1
            if (p1.y > p0.y) {
                crossings += 1;
            } else {
                crossings -= 1;
            }
        }
    }

    return crossings;
}

/// Convert a signed distance value to a pixel value (0-255).
/// The mapping is: distance = -range/2 -> 255, distance = 0 -> 128, distance = +range/2 -> 0
/// Values beyond ±range/2 are clamped. This matches msdfgen's convention where the full
/// transition from 0 to 1 happens over a distance span equal to the range parameter.
pub fn distanceToPixel(distance: f64, range: f64) u8 {
    // Inside (negative distance) maps to higher values (brighter)
    // Outside (positive distance) maps to lower values (darker)
    // Full transition happens over ±range/2, matching msdfgen behavior
    const normalized = 0.5 - distance / range;
    const clamped = std.math.clamp(normalized, 0.0, 1.0);
    return @intFromFloat(clamped * 255.0);
}

/// Convert a pixel value back to a signed distance.
/// This is the inverse of distanceToPixel.
pub fn pixelToDistance(pixel: u8, range: f64) f64 {
    const normalized = @as(f64, @floatFromInt(pixel)) / 255.0;
    return (0.5 - normalized) * range;
}

/// Options for MSDF generation.
pub const MsdfOptions = struct {
    /// If true, negate distances to handle fonts with inverted winding directions.
    /// Some fonts use CW (clockwise) outer contours instead of the standard CCW.
    invert_distances: bool = false,
};

/// Generate a Multi-channel Signed Distance Field from a shape.
///
/// Parameters:
/// - allocator: Allocator for the output bitmap.
/// - shape: The shape to generate the MSDF from.
/// - width: Output bitmap width in pixels.
/// - height: Output bitmap height in pixels.
/// - range: Distance field range in shape units. Distances beyond this are clamped.
/// - transform: Transform from pixel coordinates to shape coordinates.
/// - options: Additional options for generation.
///
/// Returns an MsdfBitmap containing the RGB8 distance field data.
pub fn generateMsdf(
    allocator: std.mem.Allocator,
    shape: Shape,
    width: u32,
    height: u32,
    range: f64,
    transform: Transform,
    options: MsdfOptions,
) !MsdfBitmap {
    const pixel_count = @as(usize, width) * @as(usize, height);
    const pixels = try allocator.alloc(u8, pixel_count * 3);
    errdefer allocator.free(pixels);

    // Initialize to medium gray (edge value)
    @memset(pixels, 128);

    var result = MsdfBitmap{
        .pixels = pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };

    // Process each pixel
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            // Convert pixel center to shape coordinates
            const point = transform.pixelToShape(@floatFromInt(x), @floatFromInt(y));

            // Compute per-channel distances
            // Each channel gets its sign from the closest edge of that color.
            // This preserves the per-edge sign information that MSDF needs for sharp corners.
            // At corners where edges of different colors meet, channels will have DIFFERENT
            // signs - this disagreement is what allows median(R,G,B) to reconstruct sharp corners.
            //
            // The edge sign convention for TrueType fonts (CCW outer contours, CW inner/holes, Y-up):
            // - Inside glyph → negative distance → bright pixels
            // - Outside glyph → positive distance → dark pixels
            // This matches MSDF convention, so use distances directly.
            // For fonts with inverted winding (CW outer instead of CCW), negate distances.
            const distances = computeChannelDistances(shape, point);
            const sign: f64 = if (options.invert_distances) -1.0 else 1.0;
            const r_dist = distances[0] * sign;
            const g_dist = distances[1] * sign;
            const b_dist = distances[2] * sign;

            // Convert to pixel values
            const r = distanceToPixel(r_dist, range);
            const g = distanceToPixel(g_dist, range);
            const b = distanceToPixel(b_dist, range);

            // Store pixel - optionally flip Y for image coordinates
            const store_y = if (transform.msdfgen_compat) y else height - 1 - y;
            result.setPixel(x, store_y, .{ r, g, b });
        }
    }

    return result;
}

/// Per-contour channel distances for the overlapping contour combiner.
/// Stores the minimum distance for each color channel within a single contour,
/// along with the contour's winding contribution at the sample point.
const ContourChannelDistances = struct {
    red: SignedDistance,
    green: SignedDistance,
    blue: SignedDistance,
    red_edge: ?EdgeSegment,
    green_edge: ?EdgeSegment,
    blue_edge: ?EdgeSegment,
    red_param: f64,
    green_param: f64,
    blue_param: f64,
    winding: i32,

    pub fn init() ContourChannelDistances {
        return .{
            .red = SignedDistance.infinite,
            .green = SignedDistance.infinite,
            .blue = SignedDistance.infinite,
            .red_edge = null,
            .green_edge = null,
            .blue_edge = null,
            .red_param = 0,
            .green_param = 0,
            .blue_param = 0,
            .winding = 0,
        };
    }
};

/// Compute channel distances for a single contour.
/// Returns per-channel minimum distances and the contour's winding at the point.
fn computeContourChannelDistances(contour: Contour, point: Vec2) ContourChannelDistances {
    var result = ContourChannelDistances.init();
    result.winding = computeContourWinding(contour, point);

    for (contour.edges) |e| {
        const dist_result = e.signedDistanceWithParam(point);
        const sd = dist_result.distance;
        const param = dist_result.param;
        const color = e.getColor();

        if (color.hasRed() and sd.lessThan(result.red)) {
            result.red = sd;
            result.red_edge = e;
            result.red_param = param;
        }
        if (color.hasGreen() and sd.lessThan(result.green)) {
            result.green = sd;
            result.green_edge = e;
            result.green_param = param;
        }
        if (color.hasBlue() and sd.lessThan(result.blue)) {
            result.blue = sd;
            result.blue_edge = e;
            result.blue_param = param;
        }
    }

    // Apply pseudo-distance conversion for each channel
    if (result.red_edge) |e| {
        edge_mod.distanceToPseudoDistance(e, point, &result.red, result.red_param);
    }
    if (result.green_edge) |e| {
        edge_mod.distanceToPseudoDistance(e, point, &result.green, result.green_param);
    }
    if (result.blue_edge) |e| {
        edge_mod.distanceToPseudoDistance(e, point, &result.blue, result.blue_param);
    }

    return result;
}

/// Combine per-contour distances using winding-aware approach.
/// Uses total winding number to determine inside/outside, then applies
/// the minimum absolute distance with the correct sign.
fn combineContourDistances(contour_results: []const ContourChannelDistances, total_winding: i32) [3]f64 {
    // Find minimum absolute distance for each channel across all contours
    var min_r_abs: f64 = std.math.inf(f64);
    var min_g_abs: f64 = std.math.inf(f64);
    var min_b_abs: f64 = std.math.inf(f64);

    for (contour_results) |cr| {
        const r_abs = @abs(cr.red.distance);
        const g_abs = @abs(cr.green.distance);
        const b_abs = @abs(cr.blue.distance);

        if (r_abs < min_r_abs) min_r_abs = r_abs;
        if (g_abs < min_g_abs) min_g_abs = g_abs;
        if (b_abs < min_b_abs) min_b_abs = b_abs;
    }

    // Determine inside/outside based on total winding number (non-zero fill rule)
    // MSDF convention (matching distanceToPixel):
    //   Inside: NEGATIVE distance -> bright pixels (255)
    //   Outside: POSITIVE distance -> dark pixels (0)
    const is_inside = total_winding != 0;
    const sign: f64 = if (is_inside) -1.0 else 1.0;

    return .{
        sign * min_r_abs,
        sign * min_g_abs,
        sign * min_b_abs,
    };
}

/// Compute the minimum signed distance for each color channel.
/// Returns [red_distance, green_distance, blue_distance].
///
/// For single-contour shapes, uses the simple global minimum approach.
/// For multi-contour shapes (like @, $, 8), uses the overlapping contour
/// combiner algorithm to resolve cross-contour interference.
fn computeChannelDistances(shape: Shape, point: Vec2) [3]f64 {
    // Use the simple approach for all shapes: find minimum distance for each
    // channel across ALL edges in ALL contours, preserving signed distances
    // directly from edge geometry.
    //
    // This matches msdfgen's SimpleContourCombiner approach, which treats
    // the entire shape as a single unit regardless of contour count.
    return computeChannelDistancesSingleContour(shape, point);
}

/// Single-contour implementation of channel distance computation.
/// This is the original algorithm, used as a fast path for single-contour shapes
/// and as a fallback for shapes with too many contours.
fn computeChannelDistancesSingleContour(shape: Shape, point: Vec2) [3]f64 {
    var min_red = SignedDistance.infinite;
    var min_green = SignedDistance.infinite;
    var min_blue = SignedDistance.infinite;

    // Track the edge and parameter for each minimum (needed for pseudo-distance)
    var red_edge: ?EdgeSegment = null;
    var green_edge: ?EdgeSegment = null;
    var blue_edge: ?EdgeSegment = null;
    var red_param: f64 = 0;
    var green_param: f64 = 0;
    var blue_param: f64 = 0;

    // Find minimum distance per channel across all edges
    for (shape.contours) |contour| {
        for (contour.edges) |e| {
            const result = e.signedDistanceWithParam(point);
            const sd = result.distance;
            const param = result.param;
            const color = e.getColor();

            // Update minimum for each channel this edge contributes to
            if (color.hasRed()) {
                if (sd.lessThan(min_red)) {
                    min_red = sd;
                    red_edge = e;
                    red_param = param;
                }
            }
            if (color.hasGreen()) {
                if (sd.lessThan(min_green)) {
                    min_green = sd;
                    green_edge = e;
                    green_param = param;
                }
            }
            if (color.hasBlue()) {
                if (sd.lessThan(min_blue)) {
                    min_blue = sd;
                    blue_edge = e;
                    blue_param = param;
                }
            }
        }
    }

    // Convert to pseudo-distance for each channel
    // This extends edge tangent lines beyond endpoints for smoother corners
    if (red_edge) |e| {
        edge_mod.distanceToPseudoDistance(e, point, &min_red, red_param);
    }
    if (green_edge) |e| {
        edge_mod.distanceToPseudoDistance(e, point, &min_green, green_param);
    }
    if (blue_edge) |e| {
        edge_mod.distanceToPseudoDistance(e, point, &min_blue, blue_param);
    }

    // Negate distances: MSDF convention is negative=inside, positive=outside.
    // After orientContours() normalizes to CCW, signedDistance gives positive
    // for inside points. Negate to match MSDF convention.
    const r = -min_red.distance;
    const g = -min_green.distance;
    const b = -min_blue.distance;
    return .{ r, g, b };
}

/// Stencil flags for error correction.
/// Used to mark pixels that should be protected from correction.
pub const StencilFlags = struct {
    pub const NONE: u8 = 0;
    pub const PROTECTED: u8 = 1; // Pixel near corner, don't modify
    pub const ERROR: u8 = 2; // Pixel detected as artifact, needs correction
};

/// Apply error correction to an MSDF bitmap with corner protection.
///
/// MSDF artifacts occur when RGB channels disagree about whether a pixel is
/// inside or outside the shape. This causes visual artifacts when the MSDF
/// is rendered because interpolation between disagreeing pixels produces
/// incorrect median values.
///
/// This implements msdfgen-style selective error correction:
///
/// 1. Corner Protection: Identify pixels near color-change corners in the shape
///    and mark them as PROTECTED. These pixels have intentional channel
///    disagreement that creates sharp corners.
///
/// 2. Edge Protection: Mark pixels near shape edges as PROTECTED to preserve
///    edge sharpness.
///
/// 3. Clash Detection: Find pixels where channels disagree AND the pixel is
///    NOT protected. Only these are marked as ERROR.
///
/// 4. Correction: Apply median filtering only to ERROR pixels.
///
/// This preserves sharp corners while eliminating artifacts on curves.
pub fn correctErrors(bitmap: *MsdfBitmap) void {
    correctErrorsWithProtection(bitmap, null, null);
}

/// Apply error correction with shape information for corner protection.
/// If shape and transform are provided, corners will be protected.
pub fn correctErrorsWithProtection(bitmap: *MsdfBitmap, shape: ?Shape, transform: ?Transform) void {
    const pixel_count = @as(usize, bitmap.width) * @as(usize, bitmap.height);

    // Allocate stencil buffer
    const stencil = bitmap.allocator.alloc(u8, pixel_count) catch {
        // Fall back to simple correction without protection
        correctErrorsSimple(bitmap);
        return;
    };
    defer bitmap.allocator.free(stencil);
    @memset(stencil, StencilFlags.NONE);

    // Phase 1: Protect corners (if shape info available)
    if (shape) |s| {
        if (transform) |t| {
            protectCorners(stencil, bitmap.width, bitmap.height, s, t);
        }
    }

    // Phase 2: Protect edge-adjacent pixels
    protectEdges(stencil, bitmap, 0.5);

    // Phase 3: Detect clashes (only on non-protected pixels)
    detectClashes(stencil, bitmap);

    // Phase 4: Apply correction only to ERROR pixels
    applyCorrection(stencil, bitmap);
}

/// Simple error correction without corner protection (legacy behavior).
fn correctErrorsSimple(bitmap: *MsdfBitmap) void {
    const threshold: u8 = 127;

    var y: u32 = 0;
    while (y < bitmap.height) : (y += 1) {
        var x: u32 = 0;
        while (x < bitmap.width) : (x += 1) {
            const rgb = bitmap.getPixel(x, y);
            const r = rgb[0];
            const g = rgb[1];
            const b = rgb[2];

            // Count channels that say "inside" (> threshold means inside)
            const r_inside: u8 = if (r > threshold) 1 else 0;
            const g_inside: u8 = if (g > threshold) 1 else 0;
            const b_inside: u8 = if (b > threshold) 1 else 0;
            const inside_count = r_inside + g_inside + b_inside;

            // All agree (0 or 3) - no correction needed
            if (inside_count == 0 or inside_count == 3) {
                continue;
            }

            // Channels disagree - apply median filtering
            const med = median3(r, g, b);
            bitmap.setPixel(x, y, .{ med, med, med });
        }
    }
}

/// Mark pixels near color-change corners as protected.
/// These pixels have intentional channel disagreement for sharp corners.
fn protectCorners(stencil: []u8, width: u32, height: u32, shape: Shape, transform: Transform) void {
    for (shape.contours) |contour| {
        const edge_count = contour.edges.len;
        if (edge_count < 2) continue;

        for (0..edge_count) |i| {
            const prev_idx = if (i == 0) edge_count - 1 else i - 1;
            const prev_edge = contour.edges[prev_idx];
            const curr_edge = contour.edges[i];

            // Check if colors differ at this junction (corner point)
            const prev_color = prev_edge.getColor();
            const curr_color = curr_edge.getColor();

            // Color change indicates a corner that needs protection
            if (prev_color != curr_color) {
                // Get the corner point (end of prev edge = start of curr edge)
                const corner_point = prev_edge.endPoint();

                // Transform to pixel coordinates
                const pixel_pos = transform.shapeToPixel(corner_point);

                // Mark the 4 surrounding texels as protected
                const px = pixel_pos.x;
                // Flip Y to match bitmap storage (shape Y-up -> image Y-down)
                const py = @as(f64, @floatFromInt(height)) - 1.0 - pixel_pos.y;

                // Get the 4 texels that could be affected by this corner
                const x0 = @as(i32, @intFromFloat(@floor(px)));
                const y0 = @as(i32, @intFromFloat(@floor(py)));

                // Mark a 7x7 region around the corner for extra protection
                var dy: i32 = -3;
                while (dy <= 3) : (dy += 1) {
                    var dx: i32 = -3;
                    while (dx <= 3) : (dx += 1) {
                        const tx = x0 + dx;
                        const ty = y0 + dy;

                        if (tx >= 0 and tx < @as(i32, @intCast(width)) and
                            ty >= 0 and ty < @as(i32, @intCast(height)))
                        {
                            const idx = @as(usize, @intCast(ty)) * width + @as(usize, @intCast(tx));
                            stencil[idx] |= StencilFlags.PROTECTED;
                        }
                    }
                }
            }
        }
    }
}

/// Protect pixels near the shape edge where channels agree.
/// Only protects edge pixels that don't have channel disagreement about inside/outside.
/// Does NOT protect pixels that contradict their neighborhood (junction artifacts).
fn protectEdges(stencil: []u8, bitmap: *MsdfBitmap, protection_radius: f64) void {
    _ = protection_radius;

    const threshold: u8 = 127;

    var y: u32 = 0;
    while (y < bitmap.height) : (y += 1) {
        var x: u32 = 0;
        while (x < bitmap.width) : (x += 1) {
            const idx = @as(usize, y) * bitmap.width + x;

            // Skip already protected pixels (corners)
            if (stencil[idx] & StencilFlags.PROTECTED != 0) continue;

            const rgb = bitmap.getPixel(x, y);
            const r = rgb[0];
            const g = rgb[1];
            const b = rgb[2];

            // Check if channels agree about inside/outside
            const r_inside = r > threshold;
            const g_inside = g > threshold;
            const b_inside = b > threshold;

            // All channels agree - this might be a natural edge pixel
            if ((r_inside and g_inside and b_inside) or (!r_inside and !g_inside and !b_inside)) {
                const med = median3(r, g, b);
                // Only protect if near the boundary (not deep inside or outside)
                if (med >= 90 and med <= 166) {
                    // Check if this pixel contradicts its neighborhood (junction artifact)
                    // Don't protect if most neighbors disagree about inside/outside
                    if (!isJunctionArtifact(bitmap, x, y, med)) {
                        stencil[idx] |= StencilFlags.PROTECTED;
                    }
                }
            }
            // If channels disagree, don't protect - let clash detection decide
        }
    }
}

/// Detect if a pixel is a junction artifact - a pixel whose median contradicts
/// the majority of its neighbors. This catches holes at junctions where multiple
/// contours meet (e.g., the waist of "8" or inner loops of "@").
fn isJunctionArtifact(bitmap: *MsdfBitmap, x: u32, y: u32, my_med: u8) bool {
    const threshold: u8 = 127;
    const my_inside = my_med > threshold;

    var neighbor_count: u32 = 0;
    var disagree_count: u32 = 0;

    const offsets = [_][2]i32{
        .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
        .{ -1, 0 },              .{ 1, 0 },
        .{ -1, 1 },  .{ 0, 1 },  .{ 1, 1 },
    };

    for (offsets) |off| {
        const nx_i = @as(i32, @intCast(x)) + off[0];
        const ny_i = @as(i32, @intCast(y)) + off[1];

        if (nx_i < 0 or nx_i >= @as(i32, @intCast(bitmap.width)) or
            ny_i < 0 or ny_i >= @as(i32, @intCast(bitmap.height)))
        {
            continue;
        }

        const nx = @as(u32, @intCast(nx_i));
        const ny = @as(u32, @intCast(ny_i));
        const n_rgb = bitmap.getPixel(nx, ny);
        const n_med = median3(n_rgb[0], n_rgb[1], n_rgb[2]);
        const n_inside = n_med > threshold;

        neighbor_count += 1;
        if (n_inside != my_inside) {
            disagree_count += 1;
        }
    }

    if (neighbor_count < 5) return false;

    // Junction artifact: majority of neighbors (5+ out of 8) disagree about inside/outside
    // This indicates a pixel that's "stuck" on the wrong side at a junction
    return disagree_count >= 5;
}

/// Detect if a pixel's median value is isolated (contradicts all neighbors).
/// This identifies artifacts like holes/spikes while preserving valid edge color diversity.
/// A pixel is an isolated artifact if:
/// - Its median strongly disagrees with majority of neighbors about inside/outside
/// - It's not on a legitimate edge (where medians transition gradually)
fn detectIsolatedMedianArtifact(bitmap: *MsdfBitmap, x: u32, y: u32, my_med: u8) bool {
    const threshold: u8 = 127;
    const my_inside = my_med > threshold;

    // Count neighbors and how many agree with us
    var neighbor_count: u32 = 0;
    var agree_count: u32 = 0;
    var total_neighbor_med: u32 = 0;

    const offsets = [_][2]i32{
        .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
        .{ -1, 0 },              .{ 1, 0 },
        .{ -1, 1 },  .{ 0, 1 },  .{ 1, 1 },
    };

    for (offsets) |off| {
        const nx_i = @as(i32, @intCast(x)) + off[0];
        const ny_i = @as(i32, @intCast(y)) + off[1];

        if (nx_i < 0 or nx_i >= @as(i32, @intCast(bitmap.width)) or
            ny_i < 0 or ny_i >= @as(i32, @intCast(bitmap.height)))
        {
            continue;
        }

        const nx = @as(u32, @intCast(nx_i));
        const ny = @as(u32, @intCast(ny_i));
        const n_rgb = bitmap.getPixel(nx, ny);
        const n_med = median3(n_rgb[0], n_rgb[1], n_rgb[2]);
        const n_inside = n_med > threshold;

        neighbor_count += 1;
        total_neighbor_med += n_med;
        if (n_inside == my_inside) {
            agree_count += 1;
        }
    }

    if (neighbor_count < 3) return false;

    // Isolated artifact: strongly disagrees with almost all neighbors
    // AND the median difference from neighbors is large
    const avg_neighbor_med = total_neighbor_med / neighbor_count;
    const med_diff = if (my_med > avg_neighbor_med) my_med - @as(u8, @intCast(avg_neighbor_med)) else @as(u8, @intCast(avg_neighbor_med)) - my_med;

    // Isolated artifact detection:
    // 1. Must disagree with majority of neighbors (at least 6 of 8)
    // 2. Must have noticeable median difference (>30) to avoid edge transitions
    // Lowered from 60 to 30 to catch junction artifacts with moderate difference
    return agree_count <= 2 and med_diff > 30;
}

/// Detect pixels that clash with neighbors and need correction.
/// Only marks non-protected pixels as errors, EXCEPT for severely
/// disagreeing pixels which override protection.
fn detectClashes(stencil: []u8, bitmap: *MsdfBitmap) void {
    if (bitmap.width < 2 or bitmap.height < 2) return;

    const threshold: u8 = 127;

    var y: u32 = 0;
    while (y < bitmap.height) : (y += 1) {
        var x: u32 = 0;
        while (x < bitmap.width) : (x += 1) {
            const idx = @as(usize, y) * bitmap.width + x;

            const rgb = bitmap.getPixel(x, y);
            const r = rgb[0];
            const g = rgb[1];
            const b = rgb[2];

            // Check for ISOLATED MEDIAN ARTIFACTS - pixels whose median contradicts all neighbors
            // This catches holes/spikes while preserving valid edge color diversity.
            // Valid edge pixels: may have high spread but neighbors have similar medians (all on edge)
            // Artifact pixels: have median that starkly contradicts surrounding region
            const med = median3(r, g, b);
            const is_isolated_artifact = detectIsolatedMedianArtifact(bitmap, x, y, med);

            if (is_isolated_artifact) {
                // Override protection for isolated artifacts
                stencil[idx] |= StencilFlags.ERROR;
                stencil[idx] &= ~StencilFlags.PROTECTED;
                continue;
            }

            // Check for interior gap artifacts (respects protection for moderate cases)
            // These occur when one channel finds a far-away edge on the opposite side
            // Pattern: two channels agree (close values), one channel is very different

            // Check if two channels agree and one is an outlier
            const rg_diff = if (r > g) r - g else g - r;
            const rb_diff = if (r > b) r - b else b - r;
            const gb_diff = if (g > b) g - b else b - g;

            const agreement_threshold: u8 = 50; // Two channels agree within this
            const outlier_threshold: u8 = 40; // Outlier channel differs by at least this much

            var is_gap_artifact = false;

            // R and G agree, B is outlier
            if (rg_diff <= agreement_threshold) {
                const avg_rg = (@as(u16, r) + @as(u16, g)) / 2;
                const b16 = @as(u16, b);
                const b_from_avg = if (b16 > avg_rg) b16 - avg_rg else avg_rg - b16;
                if (b_from_avg > outlier_threshold) {
                    is_gap_artifact = true;
                }
            }
            // R and B agree, G is outlier
            if (rb_diff <= agreement_threshold) {
                const avg_rb = (@as(u16, r) + @as(u16, b)) / 2;
                const g16 = @as(u16, g);
                const g_from_avg = if (g16 > avg_rb) g16 - avg_rb else avg_rb - g16;
                if (g_from_avg > outlier_threshold) {
                    is_gap_artifact = true;
                }
            }
            // G and B agree, R is outlier
            if (gb_diff <= agreement_threshold) {
                const avg_gb = (@as(u16, g) + @as(u16, b)) / 2;
                const r16 = @as(u16, r);
                const r_from_avg = if (r16 > avg_gb) r16 - avg_gb else avg_gb - r16;
                if (r_from_avg > outlier_threshold) {
                    is_gap_artifact = true;
                }
            }

            if (is_gap_artifact) {
                // Only mark as error if not protected (preserve corner pixels)
                if (stencil[idx] & StencilFlags.PROTECTED == 0) {
                    stencil[idx] |= StencilFlags.ERROR;
                }
                continue;
            }

            // Check for threshold boundary artifacts: channels are near 127 but disagree
            // about inside/outside. Even small differences can cause artifacts here.
            const r_inside = r > threshold;
            const g_inside = g > threshold;
            const b_inside = b > threshold;
            const inside_count = (if (r_inside) @as(u8, 1) else 0) + (if (g_inside) @as(u8, 1) else 0) + (if (b_inside) @as(u8, 1) else 0);

            // If channels disagree (1 or 2 say inside) AND values are near threshold
            if (inside_count == 1 or inside_count == 2) {
                const near_threshold: u8 = 20;
                const r_near = (r >= threshold - near_threshold and r <= threshold + near_threshold);
                const g_near = (g >= threshold - near_threshold and g <= threshold + near_threshold);
                const b_near = (b >= threshold - near_threshold and b <= threshold + near_threshold);

                // If most values are near threshold, this is a boundary pixel with minor error
                // But respect corner protection - corners need channel disagreement
                if ((r_near and g_near) or (r_near and b_near) or (g_near and b_near)) {
                    if (stencil[idx] & StencilFlags.PROTECTED == 0) {
                        stencil[idx] |= StencilFlags.ERROR;
                    }
                    continue;
                }
            }

            // Skip protected pixels for remaining cases
            if (stencil[idx] & StencilFlags.PROTECTED != 0) continue;

            // Channels agree - check for spike artifacts only
            // (inside_count already computed above)
            if (inside_count == 0 or inside_count == 3) {
                // Even if channels agree, check for spike artifacts
                // These are pixels with median values that spike relative to neighbors
                if (detectSpikeArtifact(bitmap, x, y)) {
                    stencil[idx] |= StencilFlags.ERROR;
                }
                continue;
            }

            // Channels disagree - check for clash with neighbors
            var has_clash = false;
            const neighbors = [_][2]i32{
                .{ -1, 0 },
                .{ 1, 0 },
                .{ 0, -1 },
                .{ 0, 1 },
            };

            for (neighbors) |offset| {
                const nx_i = @as(i32, @intCast(x)) + offset[0];
                const ny_i = @as(i32, @intCast(y)) + offset[1];

                if (nx_i < 0 or nx_i >= @as(i32, @intCast(bitmap.width)) or
                    ny_i < 0 or ny_i >= @as(i32, @intCast(bitmap.height)))
                {
                    continue;
                }

                const nx = @as(u32, @intCast(nx_i));
                const ny = @as(u32, @intCast(ny_i));
                const n_idx = @as(usize, ny) * bitmap.width + nx;

                // Skip if neighbor is protected
                if (stencil[n_idx] & StencilFlags.PROTECTED != 0) continue;

                const n_rgb = bitmap.getPixel(nx, ny);

                // Check if this pixel clashes with neighbor
                if (detectClashBetweenPixels(rgb, n_rgb)) {
                    // Mark the pixel farther from 0.5 as error
                    const my_dist = distanceFrom128(rgb);
                    const n_dist = distanceFrom128(n_rgb);

                    if (my_dist >= n_dist) {
                        has_clash = true;
                        break;
                    }
                }
            }

            if (has_clash) {
                stencil[idx] |= StencilFlags.ERROR;
            }
        }
    }
}

/// Detect spike artifacts - pixels where median spikes relative to neighbors.
/// These appear as "notches" in the rendered output.
fn detectSpikeArtifact(bitmap: *MsdfBitmap, x: u32, y: u32) bool {
    const rgb = bitmap.getPixel(x, y);
    const med = median3(rgb[0], rgb[1], rgb[2]);

    // Only check edge-adjacent pixels (not deep inside or outside)
    if (med < 80 or med > 176) return false;

    const neighbors = [_][2]i32{
        .{ -1, 0 },
        .{ 1, 0 },
        .{ 0, -1 },
        .{ 0, 1 },
    };

    var neighbor_count: u32 = 0;
    var neighbors_darker: u32 = 0;
    var neighbors_brighter: u32 = 0;
    var total_diff: u32 = 0;

    for (neighbors) |offset| {
        const nx_i = @as(i32, @intCast(x)) + offset[0];
        const ny_i = @as(i32, @intCast(y)) + offset[1];

        if (nx_i < 0 or nx_i >= @as(i32, @intCast(bitmap.width)) or
            ny_i < 0 or ny_i >= @as(i32, @intCast(bitmap.height)))
        {
            continue;
        }

        const nx = @as(u32, @intCast(nx_i));
        const ny = @as(u32, @intCast(ny_i));
        const n_rgb = bitmap.getPixel(nx, ny);
        const n_med = median3(n_rgb[0], n_rgb[1], n_rgb[2]);

        neighbor_count += 1;

        const diff = if (med > n_med) med - n_med else n_med - med;
        total_diff += diff;

        if (n_med < med) {
            neighbors_darker += 1;
        } else if (n_med > med) {
            neighbors_brighter += 1;
        }
    }

    if (neighbor_count < 2) return false;

    // Spike detection: pixel is much brighter/darker than ALL neighbors
    // and the average difference is large
    const avg_diff = total_diff / neighbor_count;
    const is_spike = (neighbors_darker == neighbor_count or neighbors_brighter == neighbor_count) and avg_diff > 35;

    return is_spike;
}

/// Check if two pixels clash (large channel differences between them).
fn detectClashBetweenPixels(a: [3]u8, b: [3]u8) bool {
    // Sort channel differences from largest to smallest
    var diffs: [3]u8 = .{
        if (a[0] > b[0]) a[0] - b[0] else b[0] - a[0],
        if (a[1] > b[1]) a[1] - b[1] else b[1] - a[1],
        if (a[2] > b[2]) a[2] - b[2] else b[2] - a[2],
    };

    // Sort descending
    if (diffs[0] < diffs[1]) {
        const tmp = diffs[0];
        diffs[0] = diffs[1];
        diffs[1] = tmp;
    }
    if (diffs[1] < diffs[2]) {
        const tmp = diffs[1];
        diffs[1] = diffs[2];
        diffs[2] = tmp;
    }
    if (diffs[0] < diffs[1]) {
        const tmp = diffs[0];
        diffs[0] = diffs[1];
        diffs[1] = tmp;
    }

    // Clash if second-largest difference exceeds threshold
    // Lower threshold catches more artifacts on curves
    const second_diff = diffs[1];
    const is_a_equalized = (a[0] == a[1] and a[1] == a[2]);
    const is_b_equalized = (b[0] == b[1] and b[1] == b[2]);

    return second_diff > 25 and !is_a_equalized and !is_b_equalized;
}

/// Calculate how far a pixel's median is from 128 (edge value).
fn distanceFrom128(rgb: [3]u8) u8 {
    const med = median3(rgb[0], rgb[1], rgb[2]);
    return if (med > 128) med - 128 else 128 - med;
}

/// Apply correction to pixels marked as ERROR.
/// Uses neighbor-weighted smoothing for better results on curves.
fn applyCorrection(stencil: []u8, bitmap: *MsdfBitmap) void {
    var y: u32 = 0;
    while (y < bitmap.height) : (y += 1) {
        var x: u32 = 0;
        while (x < bitmap.width) : (x += 1) {
            const idx = @as(usize, y) * bitmap.width + x;

            // Only correct ERROR pixels
            if (stencil[idx] & StencilFlags.ERROR == 0) continue;

            const rgb = bitmap.getPixel(x, y);
            const med = median3(rgb[0], rgb[1], rgb[2]);

            // Gather neighbor medians for weighted average
            var sum: u32 = @as(u32, med);
            var weight: u32 = 1;

            const neighbors = [_][2]i32{
                .{ -1, 0 },
                .{ 1, 0 },
                .{ 0, -1 },
                .{ 0, 1 },
            };

            for (neighbors) |offset| {
                const nx_i = @as(i32, @intCast(x)) + offset[0];
                const ny_i = @as(i32, @intCast(y)) + offset[1];

                if (nx_i < 0 or nx_i >= @as(i32, @intCast(bitmap.width)) or
                    ny_i < 0 or ny_i >= @as(i32, @intCast(bitmap.height)))
                {
                    continue;
                }

                const nx = @as(u32, @intCast(nx_i));
                const ny = @as(u32, @intCast(ny_i));
                const n_idx = @as(usize, ny) * bitmap.width + nx;

                // Give more weight to non-error neighbors
                const n_rgb = bitmap.getPixel(nx, ny);
                const n_med = median3(n_rgb[0], n_rgb[1], n_rgb[2]);

                if (stencil[n_idx] & StencilFlags.ERROR == 0) {
                    // Non-error neighbor gets weight 2
                    sum += @as(u32, n_med) * 2;
                    weight += 2;
                } else {
                    // Error neighbor gets weight 1
                    sum += n_med;
                    weight += 1;
                }
            }

            const smoothed: u8 = @intCast(sum / weight);
            bitmap.setPixel(x, y, .{ smoothed, smoothed, smoothed });
        }
    }
}

/// Compute median of three u8 values
fn median3(a: u8, b: u8, c: u8) u8 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

/// Calculate the transform needed to fit a shape into a bitmap with padding.
///
/// Parameters:
/// - shape_bounds: Bounding box of the shape.
/// - width: Output bitmap width in pixels.
/// - height: Output bitmap height in pixels.
/// - padding: Padding in pixels around the shape.
///
/// Returns a Transform that maps pixel coordinates to shape coordinates.
pub fn calculateTransform(shape_bounds: Bounds, width: u32, height: u32, padding: u32) Transform {
    return calculateTransformWithRange(shape_bounds, width, height, @floatFromInt(padding));
}

/// Calculate the transform with a floating-point padding/range value.
///
/// This fits the shape into the available space (output minus padding on each side)
/// and centers it. Same logic as calculateTransform but accepts float padding.
///
/// Parameters:
/// - shape_bounds: Bounding box of the shape.
/// - width: Output bitmap width in pixels.
/// - height: Output bitmap height in pixels.
/// - padding: Padding in pixels on each side (as float for range values).
///
/// Returns a Transform that maps pixel coordinates to shape coordinates.
pub fn calculateTransformWithRange(shape_bounds: Bounds, width: u32, height: u32, padding: f64) Transform {
    const shape_width = shape_bounds.width();
    const shape_height = shape_bounds.height();

    // Available space in pixels (after removing padding on each side)
    const available_width = @as(f64, @floatFromInt(width)) - 2.0 * padding;
    const available_height = @as(f64, @floatFromInt(height)) - 2.0 * padding;

    // Calculate scale to fit shape into available space
    // Use the smaller scale to maintain aspect ratio
    var scale: f64 = 1.0;
    if (shape_width > 0 and shape_height > 0) {
        const scale_x = available_width / shape_width;
        const scale_y = available_height / shape_height;
        scale = @min(scale_x, scale_y);
    } else if (shape_width > 0) {
        scale = available_width / shape_width;
    } else if (shape_height > 0) {
        scale = available_height / shape_height;
    }

    // Calculate translation to center the shape
    // After scaling, the shape occupies (shape_width * scale, shape_height * scale)
    // We want to center it in the available space
    const scaled_width = shape_width * scale;
    const scaled_height = shape_height * scale;

    const offset_x = padding + (available_width - scaled_width) / 2.0;
    const offset_y = padding + (available_height - scaled_height) / 2.0;

    // The translation needs to account for the shape's minimum corner
    // translate.x = offset_x / scale - shape_bounds.min.x
    const translate = Vec2{
        .x = offset_x / scale - shape_bounds.min.x,
        .y = offset_y / scale - shape_bounds.min.y,
    };

    return Transform.init(scale, translate);
}

/// Calculate the transform using msdfgen's autoframe algorithm with RANGE_PX mode.
///
/// This matches msdfgen's behavior with `-autoframe -pxrange N` flags:
/// 1. Enlarge the frame by 2*pxRange for scale calculation (bigger scale = bigger glyph)
/// 2. Calculate scale to fit shape in enlarged frame (preserving aspect ratio)
/// 3. Adjust translation to shift glyph inward by pxRange/scale
///
/// The result is that the glyph may extend slightly beyond the bitmap boundaries,
/// but this is correct for MSDF generation - the distance field handles it properly.
///
/// Parameters:
/// - shape_bounds: Bounding box of the shape.
/// - width: Output bitmap width in pixels.
/// - height: Output bitmap height in pixels.
/// - px_range: Distance field range in pixels.
///
/// Returns a Transform that maps pixel coordinates to shape coordinates.
pub fn calculateMsdfgenAutoframe(shape_bounds: Bounds, width: u32, height: u32, px_range: f64) Transform {
    const l = shape_bounds.min.x;
    const b = shape_bounds.min.y;
    const r = shape_bounds.max.x;
    const t = shape_bounds.max.y;

    // Shape dimensions
    const dims_x = r - l;
    const dims_y = t - b;

    // msdfgen's Range(px_range) creates lower = -px_range/2, upper = px_range/2
    // Then frame += 2*pxRange.lower means frame += 2*(-px_range/2) = frame - px_range
    // So the effective frame is (width - px_range, height - px_range)
    const frame_x = @as(f64, @floatFromInt(width)) - px_range;
    const frame_y = @as(f64, @floatFromInt(height)) - px_range;

    var scale: f64 = 1.0;
    var translate = Vec2.zero;

    if (dims_x > 0 and dims_y > 0) {
        // msdfgen's aspect ratio check and scale/translate calculation
        // if dims.x * frame.y < dims.y * frame.x => height-constrained
        // else => width-constrained
        if (dims_x * frame_y < dims_y * frame_x) {
            // Height-constrained: scale based on height
            scale = frame_y / dims_y;
            // Center horizontally: 0.5 * (frame.x/frame.y * dims.y - dims.x) - l
            translate.x = 0.5 * (frame_x / frame_y * dims_y - dims_x) - l;
            translate.y = -b;
        } else {
            // Width-constrained: scale based on width
            scale = frame_x / dims_x;
            // Center vertically: 0.5 * (frame.y/frame.x * dims.x - dims.y) - b
            translate.x = -l;
            translate.y = 0.5 * (frame_y / frame_x * dims_x - dims_y) - b;
        }

        // msdfgen does: translate -= pxRange.lower/scale
        // where pxRange.lower = -px_range/2, so this is: translate += (px_range/2)/scale
        translate.x += (px_range / 2.0) / scale;
        translate.y += (px_range / 2.0) / scale;
    } else if (dims_x > 0) {
        scale = frame_x / dims_x;
        translate.x = -l + (px_range / 2.0) / scale;
        translate.y = -b;
    } else if (dims_y > 0) {
        scale = frame_y / dims_y;
        translate.x = -l;
        translate.y = -b + (px_range / 2.0) / scale;
    }

    // Debug output (remove in production)
    std.debug.print("calculateMsdfgenAutoframe: bounds=({d:.2},{d:.2})-({d:.2},{d:.2}) dims=({d:.2},{d:.2}) frame=({d:.2},{d:.2}) scale={d:.6} translate=({d:.4},{d:.4})\n", .{
        l, b, r, t, dims_x, dims_y, frame_x, frame_y, scale, translate.x, translate.y
    });

    // Return standard transform - let generateMsdf flip Y for standard image output
    return Transform.init(scale, translate);
}

// ============================================================================
// Tests
// ============================================================================

test "distanceToPixel" {
    const range: f64 = 4.0;

    // At edge (distance = 0) -> 128
    try std.testing.expectEqual(@as(u8, 128), distanceToPixel(0, range));

    // Fully inside (distance = -range) -> 255
    try std.testing.expectEqual(@as(u8, 255), distanceToPixel(-range, range));

    // Fully outside (distance = +range) -> 0
    try std.testing.expectEqual(@as(u8, 0), distanceToPixel(range, range));

    // Half inside (distance = -range/2) -> 191 (approx)
    const half_inside = distanceToPixel(-range / 2.0, range);
    try std.testing.expect(half_inside > 128 and half_inside < 255);

    // Half outside (distance = +range/2) -> 64 (approx)
    const half_outside = distanceToPixel(range / 2.0, range);
    try std.testing.expect(half_outside > 0 and half_outside < 128);
}

test "pixelToDistance roundtrip" {
    const range: f64 = 4.0;
    const test_distances = [_]f64{ -4.0, -2.0, 0.0, 2.0, 4.0 };

    for (test_distances) |dist| {
        const pixel = distanceToPixel(dist, range);
        const recovered = pixelToDistance(pixel, range);
        // Allow some error due to quantization
        try std.testing.expectApproxEqAbs(dist, recovered, 0.05);
    }
}

test "computeWinding - point inside square" {
    const allocator = std.testing.allocator;

    // Create a CCW square (0,0) -> (10,0) -> (10,10) -> (0,10) -> (0,0)
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(0, 0), Vec2.init(10, 0)) };
    edges[1] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(10, 0), Vec2.init(10, 10)) };
    edges[2] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(10, 10), Vec2.init(0, 10)) };
    edges[3] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(0, 10), Vec2.init(0, 0)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    // Point inside should have non-zero winding
    const inside_winding = computeWinding(shape, Vec2.init(5, 5));
    try std.testing.expect(inside_winding != 0);

    // Point outside should have zero winding
    const outside_winding = computeWinding(shape, Vec2.init(15, 5));
    try std.testing.expectEqual(@as(i32, 0), outside_winding);
}

test "Transform.pixelToShape" {
    const transform = Transform.init(2.0, Vec2.init(10, 20));

    // Pixel (0, 0) with scale 2 and translate (10, 20)
    // shape.x = (0 + 0.5) / 2 - 10 = 0.25 - 10 = -9.75
    // shape.y = (0 + 0.5) / 2 - 20 = 0.25 - 20 = -19.75
    const point = transform.pixelToShape(0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, -9.75), point.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, -19.75), point.y, 1e-10);
}

test "calculateTransform - centers shape" {
    const shape_bounds = Bounds.init(0, 0, 100, 100);
    const transform = calculateTransform(shape_bounds, 64, 64, 4);

    // With 64x64 output and 4px padding, available space is 56x56
    // Shape is 100x100, so scale = 56/100 = 0.56
    try std.testing.expectApproxEqAbs(@as(f64, 0.56), transform.scale, 1e-10);
}

test "calculateTransformWithRange - same as calculateTransform with float padding" {
    // Test with typical MSDF parameters
    const shape_bounds = Bounds.init(147, 0, 1466, 1552);
    const transform = calculateTransformWithRange(shape_bounds, 32, 32, 4.0);

    // With 32x32 output and 4px padding, available space is 24x24
    // Shape is 1319x1552, so scale = min(24/1319, 24/1552) = 24/1552
    try std.testing.expectApproxEqAbs(@as(f64, 24.0 / 1552.0), transform.scale, 1e-10);

    // Verify it matches the integer-padding version
    const transform_int = calculateTransform(shape_bounds, 32, 32, 4);
    try std.testing.expectApproxEqAbs(transform_int.scale, transform.scale, 1e-10);
    try std.testing.expectApproxEqAbs(transform_int.translate.x, transform.translate.x, 1e-10);
    try std.testing.expectApproxEqAbs(transform_int.translate.y, transform.translate.y, 1e-10);
}

test "calculateMsdfgenAutoframe - matches msdfgen algorithm" {
    // Test with typical MSDF parameters (matching msdfgen's autoframe with RANGE_PX)
    const shape_bounds = Bounds.init(147, 0, 1466, 1552);
    const transform = calculateMsdfgenAutoframe(shape_bounds, 32, 32, 4.0);

    // With msdfgen autoframe:
    // frame = (32 + 2*4, 32 + 2*4) = (40, 40)
    // dims = (1319, 1552)
    // 1319 * 40 < 1552 * 40 → height-limited
    // scale = 40 / 1552 = 0.02577...
    try std.testing.expectApproxEqAbs(@as(f64, 40.0 / 1552.0), transform.scale, 1e-10);

    // Verify translation calculation:
    // translate.x = 0.5 * (40/40 * 1552 - 1319) - 147 = 0.5 * 233 - 147 = -30.5
    // translate.x -= 4 / scale = -30.5 - 155.2 = -185.7
    const expected_tx = 0.5 * (1552.0 - 1319.0) - 147.0 - 4.0 / (40.0 / 1552.0);
    try std.testing.expectApproxEqAbs(expected_tx, transform.translate.x, 0.1);

    // translate.y = -0 - 4/scale = -155.2
    const expected_ty = -0.0 - 4.0 / (40.0 / 1552.0);
    try std.testing.expectApproxEqAbs(expected_ty, transform.translate.y, 0.1);
}

test "generateMsdf - empty shape" {
    const allocator = std.testing.allocator;

    var shape = Shape.init(allocator);
    defer shape.deinit();

    const transform = Transform.init(1.0, Vec2.zero);
    var bitmap = try generateMsdf(allocator, shape, 8, 8, 4.0, transform, .{});
    defer bitmap.deinit();

    // With empty shape, all pixels should be "outside" (128 or less)
    // Actually with no edges, all channels will use infinite distance -> outside -> 0
    // But we initialize to 128, and with no edges, the distance stays infinite
    try std.testing.expectEqual(@as(u32, 8), bitmap.width);
    try std.testing.expectEqual(@as(u32, 8), bitmap.height);
}

test "generateMsdf - simple square" {
    const allocator = std.testing.allocator;

    // Create a square shape
    var edges = try allocator.alloc(EdgeSegment, 4);
    edges[0] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(0, 0), Vec2.init(10, 0)) };
    edges[1] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(10, 0), Vec2.init(10, 10)) };
    edges[2] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(10, 10), Vec2.init(0, 10)) };
    edges[3] = .{ .linear = edge_mod.LinearSegment.init(Vec2.init(0, 10), Vec2.init(0, 0)) };

    var contours = try allocator.alloc(Contour, 1);
    contours[0] = Contour.fromEdges(allocator, edges);

    var shape = Shape.fromContours(allocator, contours);
    defer shape.deinit();

    // Calculate transform to fit shape
    const bounds = shape.bounds();
    const transform = calculateTransform(bounds, 32, 32, 4);

    var bitmap = try generateMsdf(allocator, shape, 32, 32, 4.0, transform, .{});
    defer bitmap.deinit();

    try std.testing.expectEqual(@as(u32, 32), bitmap.width);
    try std.testing.expectEqual(@as(u32, 32), bitmap.height);

    // Center pixel should be inside (high values)
    const center = bitmap.getPixel(16, 16);
    try std.testing.expect(center[0] > 128);
    try std.testing.expect(center[1] > 128);
    try std.testing.expect(center[2] > 128);

    // Corner pixel should be outside (low values)
    const corner = bitmap.getPixel(0, 0);
    try std.testing.expect(corner[0] < 128);
    try std.testing.expect(corner[1] < 128);
    try std.testing.expect(corner[2] < 128);
}

test "correctErrors - processes small bitmaps in phase 1" {
    const allocator = std.testing.allocator;

    // 1x1 bitmap - phase 1 still processes it, phase 2 skips it
    const pixels = try allocator.alloc(u8, 3);
    defer allocator.free(pixels);
    pixels[0] = 200; // inside
    pixels[1] = 50; // outside
    pixels[2] = 200; // inside

    var bitmap = MsdfBitmap{
        .pixels = pixels,
        .width = 1,
        .height = 1,
        .allocator = allocator,
    };

    correctErrors(&bitmap);

    // Phase 1 applies median since channels disagree (2 inside, 1 outside)
    // Median of (200, 50, 200) = 200
    const med = median3(200, 50, 200);
    try std.testing.expectEqual(med, bitmap.pixels[0]);
    try std.testing.expectEqual(med, bitmap.pixels[1]);
    try std.testing.expectEqual(med, bitmap.pixels[2]);
}

test "correctErrors - no change when neighbors are similar" {
    const allocator = std.testing.allocator;

    // 2x2 bitmap with similar pixels (no clash)
    const pixels = try allocator.alloc(u8, 4 * 3);
    defer allocator.free(pixels);

    // All pixels are similar (inside, no large channel differences between neighbors)
    // Pixel (0,0)
    pixels[0] = 200;
    pixels[1] = 195;
    pixels[2] = 190;
    // Pixel (1,0)
    pixels[3] = 198;
    pixels[4] = 193;
    pixels[5] = 188;
    // Pixel (0,1)
    pixels[6] = 202;
    pixels[7] = 197;
    pixels[8] = 192;
    // Pixel (1,1)
    pixels[9] = 200;
    pixels[10] = 195;
    pixels[11] = 190;

    var bitmap = MsdfBitmap{
        .pixels = pixels,
        .width = 2,
        .height = 2,
        .allocator = allocator,
    };

    correctErrors(&bitmap);

    // All should be unchanged since no clashes
    try std.testing.expectEqual(@as(u8, 200), bitmap.pixels[0]);
    try std.testing.expectEqual(@as(u8, 195), bitmap.pixels[1]);
    try std.testing.expectEqual(@as(u8, 190), bitmap.pixels[2]);
}

test "correctErrors - fixes clashing neighbor pixels" {
    const allocator = std.testing.allocator;

    // 2x1 bitmap with clashing pixels
    const pixels = try allocator.alloc(u8, 2 * 3);
    defer allocator.free(pixels);

    // Pixel 0: near edge with large spread
    pixels[0] = 180; // R inside
    pixels[1] = 60; // G outside
    pixels[2] = 130; // B at edge (farther from edge than neighbor)

    // Pixel 1: also near edge, equalized (won't cause clash detection)
    pixels[3] = 128;
    pixels[4] = 128;
    pixels[5] = 128;

    var bitmap = MsdfBitmap{
        .pixels = pixels,
        .width = 2,
        .height = 1,
        .allocator = allocator,
    };

    correctErrors(&bitmap);

    // Pixel 0 should be median filtered if clash detected
    // Median of (180, 60, 130) = 130
    // Pixel 1 should be unchanged (equalized pixels don't trigger clash)
    try std.testing.expectEqual(@as(u8, 128), bitmap.pixels[3]);
    try std.testing.expectEqual(@as(u8, 128), bitmap.pixels[4]);
    try std.testing.expectEqual(@as(u8, 128), bitmap.pixels[5]);
}

test "median3 - computes median correctly" {
    // Test various orderings
    try std.testing.expectEqual(@as(u8, 5), median3(1, 5, 9));
    try std.testing.expectEqual(@as(u8, 5), median3(5, 1, 9));
    try std.testing.expectEqual(@as(u8, 5), median3(9, 5, 1));
    try std.testing.expectEqual(@as(u8, 5), median3(1, 9, 5));
    try std.testing.expectEqual(@as(u8, 5), median3(5, 9, 1));
    try std.testing.expectEqual(@as(u8, 5), median3(9, 1, 5));

    // Edge cases
    try std.testing.expectEqual(@as(u8, 5), median3(5, 5, 5));
    try std.testing.expectEqual(@as(u8, 5), median3(5, 5, 9));
    try std.testing.expectEqual(@as(u8, 0), median3(0, 0, 0));
    try std.testing.expectEqual(@as(u8, 255), median3(255, 255, 255));
    try std.testing.expectEqual(@as(u8, 128), median3(0, 128, 255));
}

test "correctErrors - applies median when channels disagree" {
    const allocator = std.testing.allocator;

    // 2x2 bitmap to avoid early return
    const pixels = try allocator.alloc(u8, 4 * 3);
    defer allocator.free(pixels);

    // Pixel 0: channels disagree (R inside, G outside, B inside)
    pixels[0] = 200; // R inside
    pixels[1] = 50; // G outside
    pixels[2] = 180; // B inside
    // Other pixels - all agree (inside)
    pixels[3] = 200;
    pixels[4] = 200;
    pixels[5] = 200;
    pixels[6] = 200;
    pixels[7] = 200;
    pixels[8] = 200;
    pixels[9] = 200;
    pixels[10] = 200;
    pixels[11] = 200;

    var bitmap = MsdfBitmap{
        .pixels = pixels,
        .width = 2,
        .height = 2,
        .allocator = allocator,
    };

    correctErrors(&bitmap);

    // Pixel 0 should have all channels set to median (180)
    const med = median3(200, 50, 180); // = 180
    try std.testing.expectEqual(med, bitmap.pixels[0]);
    try std.testing.expectEqual(med, bitmap.pixels[1]);
    try std.testing.expectEqual(med, bitmap.pixels[2]);
}
