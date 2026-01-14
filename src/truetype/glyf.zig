//! TrueType 'glyf' table parsing.
//!
//! The 'glyf' table contains the glyph outline data. Each glyph is either:
//! - A simple glyph: contains points and contours directly
//! - A compound glyph: references other glyphs with transformations
//!
//! This module parses glyph outlines and converts them to Shape structures
//! for MSDF generation.

const std = @import("std");
const parser = @import("parser.zig");
const head_maxp = @import("head_maxp.zig");
const math = @import("../generator/math.zig");
const edge = @import("../generator/edge.zig");
const contour = @import("../generator/contour.zig");

const readU16Big = parser.readU16Big;
const readU32Big = parser.readU32Big;
const readI16Big = parser.readI16Big;
const readU8 = parser.readU8;
const ParseError = parser.ParseError;

const Vec2 = math.Vec2;
const EdgeSegment = edge.EdgeSegment;
const LinearSegment = edge.LinearSegment;
const QuadraticSegment = edge.QuadraticSegment;
const Contour = contour.Contour;
const Shape = contour.Shape;

/// A point in a glyph outline.
const GlyphPoint = struct {
    x: i16,
    y: i16,
    on_curve: bool,
};

/// Glyph flag bits for simple glyphs.
const GlyphFlags = struct {
    /// If set, the point is on the curve; otherwise, it's a control point.
    pub const ON_CURVE_POINT: u8 = 0x01;
    /// If set, the x coordinate is 1 byte; otherwise, 2 bytes.
    pub const X_SHORT_VECTOR: u8 = 0x02;
    /// If set, the y coordinate is 1 byte; otherwise, 2 bytes.
    pub const Y_SHORT_VECTOR: u8 = 0x04;
    /// If set, the next byte specifies the repeat count.
    pub const REPEAT_FLAG: u8 = 0x08;
    /// If X_SHORT_VECTOR is set: if this is set, x is positive; else negative.
    /// If X_SHORT_VECTOR is clear: if this is set, x is same as previous; else signed delta.
    pub const X_IS_SAME_OR_POSITIVE: u8 = 0x10;
    /// If Y_SHORT_VECTOR is set: if this is set, y is positive; else negative.
    /// If Y_SHORT_VECTOR is clear: if this is set, y is same as previous; else signed delta.
    pub const Y_IS_SAME_OR_POSITIVE: u8 = 0x20;
};

/// Component flags for compound glyphs.
const ComponentFlags = struct {
    /// If set, arguments are words (2 bytes each); otherwise bytes.
    pub const ARG_1_AND_2_ARE_WORDS: u16 = 0x0001;
    /// If set, arguments are xy values; otherwise point numbers.
    pub const ARGS_ARE_XY_VALUES: u16 = 0x0002;
    /// If set, round xy values to grid.
    pub const ROUND_XY_TO_GRID: u16 = 0x0004;
    /// If set, there is a simple scale for the component.
    pub const WE_HAVE_A_SCALE: u16 = 0x0008;
    /// If set, there are more components after this one.
    pub const MORE_COMPONENTS: u16 = 0x0020;
    /// If set, there are separate x and y scales.
    pub const WE_HAVE_AN_X_AND_Y_SCALE: u16 = 0x0040;
    /// If set, there is a 2x2 transformation matrix.
    pub const WE_HAVE_A_TWO_BY_TWO: u16 = 0x0080;
    /// If set, instructions follow the component data.
    pub const WE_HAVE_INSTRUCTIONS: u16 = 0x0100;
    /// If set, use this component's metrics.
    pub const USE_MY_METRICS: u16 = 0x0200;
};

/// Get the offset and length of a glyph in the glyf table.
/// Uses the loca table to find the glyph data location.
pub fn getGlyphOffset(
    data: []const u8,
    loca_offset: usize,
    glyf_offset: usize,
    glyph_index: u16,
    num_glyphs: u16,
    use_long_loca: bool,
) ParseError!struct { offset: usize, length: usize } {
    if (glyph_index >= num_glyphs) return ParseError.InvalidGlyph;

    var this_offset: u32 = undefined;
    var next_offset: u32 = undefined;

    if (use_long_loca) {
        // Long format: 32-bit offsets
        const index_offset = loca_offset + @as(usize, glyph_index) * 4;
        this_offset = try readU32Big(data, index_offset);
        next_offset = try readU32Big(data, index_offset + 4);
    } else {
        // Short format: 16-bit offsets (actual offset is value * 2)
        const index_offset = loca_offset + @as(usize, glyph_index) * 2;
        this_offset = @as(u32, try readU16Big(data, index_offset)) * 2;
        next_offset = @as(u32, try readU16Big(data, index_offset + 2)) * 2;
    }

    // Validate offsets don't go backwards (would indicate corrupted loca table)
    if (next_offset < this_offset) return ParseError.InvalidFontData;

    const glyph_data_offset = glyf_offset + this_offset;
    const length = next_offset - this_offset;

    // Validate glyph data is within bounds of the font data
    if (glyph_data_offset > data.len) return ParseError.OutOfBounds;
    if (length > 0 and glyph_data_offset + length > data.len) return ParseError.OutOfBounds;

    return .{ .offset = glyph_data_offset, .length = length };
}

/// Parse a glyph and return its outline as a Shape.
/// Handles both simple and compound glyphs.
pub fn parseGlyph(
    allocator: std.mem.Allocator,
    data: []const u8,
    loca_offset: usize,
    glyf_offset: usize,
    glyph_index: u16,
    num_glyphs: u16,
    use_long_loca: bool,
) ParseError!Shape {
    const glyph_loc = try getGlyphOffset(data, loca_offset, glyf_offset, glyph_index, num_glyphs, use_long_loca);

    // Empty glyph (like space)
    if (glyph_loc.length == 0) {
        return Shape.init(allocator);
    }

    const glyph_data = data[glyph_loc.offset..];
    const number_of_contours = try readI16Big(glyph_data, 0);

    if (number_of_contours >= 0) {
        // Simple glyph
        return parseSimpleGlyph(allocator, glyph_data, @intCast(number_of_contours));
    } else {
        // Compound glyph (numberOfContours == -1)
        return parseCompoundGlyph(allocator, data, glyph_data, loca_offset, glyf_offset, num_glyphs, use_long_loca);
    }
}

/// Parse a simple glyph (one with direct point data).
fn parseSimpleGlyph(allocator: std.mem.Allocator, glyph_data: []const u8, num_contours: u16) ParseError!Shape {
    if (num_contours == 0) {
        return Shape.init(allocator);
    }

    // Glyph header: numberOfContours (i16), xMin, yMin, xMax, yMax (all i16)
    const HEADER_SIZE: usize = 10;

    // Validate minimum glyph data size for header + endpoint array
    const min_size = HEADER_SIZE + @as(usize, num_contours) * 2 + 2; // +2 for instruction length
    if (glyph_data.len < min_size) return ParseError.OutOfBounds;

    // Read end points of contours
    var end_points = allocator.alloc(u16, num_contours) catch return ParseError.OutOfMemory;
    defer allocator.free(end_points);

    var offset: usize = HEADER_SIZE;
    for (0..num_contours) |i| {
        end_points[i] = try readU16Big(glyph_data, offset);
        offset += 2;
    }

    // Total number of points is one more than the last endpoint
    const num_points: usize = @as(usize, end_points[num_contours - 1]) + 1;

    // Validate num_points is reasonable (prevent excessive allocation)
    if (num_points > 65536) return ParseError.InvalidFontData;

    // Read instruction length and skip instructions
    const instruction_length = try readU16Big(glyph_data, offset);
    offset += 2;

    // Validate instruction length doesn't exceed remaining data
    if (offset + instruction_length > glyph_data.len) return ParseError.OutOfBounds;
    offset += instruction_length;

    // Read flags (RLE compressed)
    var flags = allocator.alloc(u8, num_points) catch return ParseError.OutOfMemory;
    defer allocator.free(flags);

    var point_index: usize = 0;
    while (point_index < num_points) {
        const flag = try readU8(glyph_data, offset);
        offset += 1;

        flags[point_index] = flag;
        point_index += 1;

        // Check for repeat flag
        if ((flag & GlyphFlags.REPEAT_FLAG) != 0) {
            const repeat_count = try readU8(glyph_data, offset);
            offset += 1;

            for (0..repeat_count) |_| {
                if (point_index >= num_points) break;
                flags[point_index] = flag;
                point_index += 1;
            }
        }
    }

    // Read X coordinates (delta-encoded)
    var x_coords = allocator.alloc(i16, num_points) catch return ParseError.OutOfMemory;
    defer allocator.free(x_coords);

    var x: i16 = 0;
    for (0..num_points) |i| {
        const flag = flags[i];
        if ((flag & GlyphFlags.X_SHORT_VECTOR) != 0) {
            // 1-byte coordinate
            const dx = try readU8(glyph_data, offset);
            offset += 1;
            if ((flag & GlyphFlags.X_IS_SAME_OR_POSITIVE) != 0) {
                x += @intCast(dx);
            } else {
                x -= @intCast(dx);
            }
        } else {
            // 2-byte coordinate or same as previous
            if ((flag & GlyphFlags.X_IS_SAME_OR_POSITIVE) != 0) {
                // Same as previous (no change)
            } else {
                // Signed 2-byte delta
                x += try readI16Big(glyph_data, offset);
                offset += 2;
            }
        }
        x_coords[i] = x;
    }

    // Read Y coordinates (delta-encoded)
    var y_coords = allocator.alloc(i16, num_points) catch return ParseError.OutOfMemory;
    defer allocator.free(y_coords);

    var y: i16 = 0;
    for (0..num_points) |i| {
        const flag = flags[i];
        if ((flag & GlyphFlags.Y_SHORT_VECTOR) != 0) {
            // 1-byte coordinate
            const dy = try readU8(glyph_data, offset);
            offset += 1;
            if ((flag & GlyphFlags.Y_IS_SAME_OR_POSITIVE) != 0) {
                y += @intCast(dy);
            } else {
                y -= @intCast(dy);
            }
        } else {
            // 2-byte coordinate or same as previous
            if ((flag & GlyphFlags.Y_IS_SAME_OR_POSITIVE) != 0) {
                // Same as previous (no change)
            } else {
                // Signed 2-byte delta
                y += try readI16Big(glyph_data, offset);
                offset += 2;
            }
        }
        y_coords[i] = y;
    }

    // Build points array
    var points = allocator.alloc(GlyphPoint, num_points) catch return ParseError.OutOfMemory;
    defer allocator.free(points);

    for (0..num_points) |i| {
        points[i] = GlyphPoint{
            .x = x_coords[i],
            .y = y_coords[i],
            .on_curve = (flags[i] & GlyphFlags.ON_CURVE_POINT) != 0,
        };
    }

    // Build shape from points and contour endpoints
    return buildShape(allocator, points, end_points);
}

/// Build a Shape from parsed glyph points.
fn buildShape(allocator: std.mem.Allocator, points: []const GlyphPoint, end_points: []const u16) ParseError!Shape {
    const num_contours = end_points.len;

    var contours = allocator.alloc(Contour, num_contours) catch return ParseError.OutOfMemory;
    errdefer {
        for (contours) |*c| {
            c.deinit();
        }
        allocator.free(contours);
    }

    var start_point: usize = 0;
    for (0..num_contours) |i| {
        const end_point: usize = @as(usize, end_points[i]) + 1;
        const contour_points = points[start_point..end_point];

        contours[i] = try buildContour(allocator, contour_points);
        start_point = end_point;
    }

    return Shape.fromContours(allocator, contours);
}

/// Build a Contour from a sequence of glyph points.
/// Handles TrueType's on-curve/off-curve point semantics:
/// - On-curve to on-curve: linear segment
/// - On-curve to off-curve to on-curve: quadratic Bezier
/// - Consecutive off-curve points: implicit on-curve at midpoint
fn buildContour(allocator: std.mem.Allocator, points: []const GlyphPoint) ParseError!Contour {
    if (points.len == 0) {
        return Contour.init(allocator);
    }

    // First, we need to find the starting point
    // TrueType contours can start with an off-curve point, in which case
    // we need to find or create an on-curve starting point

    var edge_list: std.ArrayList(EdgeSegment) = .{};
    errdefer edge_list.deinit(allocator);

    const n = points.len;

    // Find the first on-curve point, or create one at midpoint if none exists
    var first_on_curve_index: ?usize = null;
    for (0..n) |i| {
        if (points[i].on_curve) {
            first_on_curve_index = i;
            break;
        }
    }

    // If no on-curve point, create implicit one between first two off-curve points
    var implicit_start: ?Vec2 = null;
    var start_index: usize = 0;
    if (first_on_curve_index) |idx| {
        start_index = idx;
    } else {
        // All points are off-curve - create implicit on-curve at midpoint of first two
        const p0 = points[0];
        const p1 = points[1 % n];
        implicit_start = Vec2.init(
            @as(f64, @floatFromInt(p0.x + p1.x)) / 2.0,
            @as(f64, @floatFromInt(p0.y + p1.y)) / 2.0,
        );
        start_index = 0;
    }

    // Walk through the contour, building edge segments
    var current: Vec2 = undefined;
    if (implicit_start) |start| {
        current = start;
    } else {
        const p = points[start_index];
        current = Vec2.init(@floatFromInt(p.x), @floatFromInt(p.y));
    }

    var i: usize = 0;
    while (i < n) {
        const curr_idx = (start_index + i) % n;
        const next_idx = (start_index + i + 1) % n;

        const curr_point = points[curr_idx];
        const next_point = points[next_idx];

        if (curr_point.on_curve) {
            // Current point is on-curve
            if (next_point.on_curve) {
                // Next is also on-curve: straight line
                const next_vec = Vec2.init(@floatFromInt(next_point.x), @floatFromInt(next_point.y));
                try edge_list.append(allocator, .{ .linear = LinearSegment.init(current, next_vec) });
                current = next_vec;
                i += 1;
            } else {
                // Next is off-curve: need to find the end point
                const control = Vec2.init(@floatFromInt(next_point.x), @floatFromInt(next_point.y));
                const after_idx = (start_index + i + 2) % n;
                const after_point = points[after_idx];

                var end_point: Vec2 = undefined;
                var advance: usize = 2;

                if (after_point.on_curve) {
                    // Explicit on-curve end point
                    end_point = Vec2.init(@floatFromInt(after_point.x), @floatFromInt(after_point.y));
                } else {
                    // Implicit on-curve at midpoint of two off-curve points
                    end_point = Vec2.init(
                        (@as(f64, @floatFromInt(next_point.x)) + @as(f64, @floatFromInt(after_point.x))) / 2.0,
                        (@as(f64, @floatFromInt(next_point.y)) + @as(f64, @floatFromInt(after_point.y))) / 2.0,
                    );
                    advance = 1; // Only advance by 1, the implicit point becomes current
                }

                try edge_list.append(allocator, .{ .quadratic = QuadraticSegment.init(current, control, end_point) });
                current = end_point;
                i += advance;
            }
        } else {
            // Current point is off-curve (we're coming from an implicit on-curve)
            const control = Vec2.init(@floatFromInt(curr_point.x), @floatFromInt(curr_point.y));

            if (next_point.on_curve) {
                // Next is on-curve
                const end_point = Vec2.init(@floatFromInt(next_point.x), @floatFromInt(next_point.y));
                try edge_list.append(allocator, .{ .quadratic = QuadraticSegment.init(current, control, end_point) });
                current = end_point;
                i += 1;
            } else {
                // Next is also off-curve: implicit on-curve at midpoint
                const next_control = Vec2.init(@floatFromInt(next_point.x), @floatFromInt(next_point.y));
                const end_point = Vec2.init(
                    (control.x + next_control.x) / 2.0,
                    (control.y + next_control.y) / 2.0,
                );
                try edge_list.append(allocator, .{ .quadratic = QuadraticSegment.init(current, control, end_point) });
                current = end_point;
                i += 1;
            }
        }
    }

    // Close the contour if needed
    const start_point = if (implicit_start) |start| start else Vec2.init(
        @floatFromInt(points[start_index].x),
        @floatFromInt(points[start_index].y),
    );

    if (!current.approxEqual(start_point, 1e-10)) {
        // We may need to add a closing segment
        // Check if there are off-curve points between current and start
        const last_idx = (start_index + n - 1) % n;
        const last_point = points[last_idx];

        if (!last_point.on_curve) {
            // Last point is off-curve, need to close with a curve
            const control = Vec2.init(@floatFromInt(last_point.x), @floatFromInt(last_point.y));
            if (!control.approxEqual(current, 1e-10)) {
                try edge_list.append(allocator, .{ .quadratic = QuadraticSegment.init(current, control, start_point) });
            }
        } else if (!current.approxEqual(start_point, 1e-10)) {
            // Close with a straight line
            try edge_list.append(allocator, .{ .linear = LinearSegment.init(current, start_point) });
        }
    }

    const edges = edge_list.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
    return Contour.fromEdges(allocator, edges);
}

/// Parse a compound glyph (one that references other glyphs).
fn parseCompoundGlyph(
    allocator: std.mem.Allocator,
    data: []const u8,
    glyph_data: []const u8,
    loca_offset: usize,
    glyf_offset: usize,
    num_glyphs: u16,
    use_long_loca: bool,
) ParseError!Shape {
    // Validate minimum size for header + at least one component (flags + glyph index)
    if (glyph_data.len < 14) return ParseError.OutOfBounds;

    // Skip glyph header (10 bytes)
    var offset: usize = 10;

    // Collect all contours from components
    var all_contours: std.ArrayList(Contour) = .{};
    errdefer {
        for (all_contours.items) |*c| {
            c.deinit();
        }
        all_contours.deinit(allocator);
    }

    var has_more_components = true;
    while (has_more_components) {
        const flags = try readU16Big(glyph_data, offset);
        const glyph_index = try readU16Big(glyph_data, offset + 2);
        offset += 4;

        // Read translation arguments
        var arg1: i32 = 0;
        var arg2: i32 = 0;

        if ((flags & ComponentFlags.ARG_1_AND_2_ARE_WORDS) != 0) {
            arg1 = try readI16Big(glyph_data, offset);
            arg2 = try readI16Big(glyph_data, offset + 2);
            offset += 4;
        } else {
            // Arguments are bytes (can be signed or unsigned depending on ARGS_ARE_XY_VALUES)
            if ((flags & ComponentFlags.ARGS_ARE_XY_VALUES) != 0) {
                // Signed bytes for offsets
                arg1 = @as(i8, @bitCast(try readU8(glyph_data, offset)));
                arg2 = @as(i8, @bitCast(try readU8(glyph_data, offset + 1)));
            } else {
                // Unsigned bytes for point indices
                arg1 = try readU8(glyph_data, offset);
                arg2 = try readU8(glyph_data, offset + 1);
            }
            offset += 2;
        }

        // Read transformation matrix
        var a: f64 = 1.0;
        var b: f64 = 0.0;
        var c: f64 = 0.0;
        var d: f64 = 1.0;

        if ((flags & ComponentFlags.WE_HAVE_A_SCALE) != 0) {
            a = @as(f64, @floatFromInt(try readI16Big(glyph_data, offset))) / 16384.0;
            d = a;
            offset += 2;
        } else if ((flags & ComponentFlags.WE_HAVE_AN_X_AND_Y_SCALE) != 0) {
            a = @as(f64, @floatFromInt(try readI16Big(glyph_data, offset))) / 16384.0;
            d = @as(f64, @floatFromInt(try readI16Big(glyph_data, offset + 2))) / 16384.0;
            offset += 4;
        } else if ((flags & ComponentFlags.WE_HAVE_A_TWO_BY_TWO) != 0) {
            a = @as(f64, @floatFromInt(try readI16Big(glyph_data, offset))) / 16384.0;
            b = @as(f64, @floatFromInt(try readI16Big(glyph_data, offset + 2))) / 16384.0;
            c = @as(f64, @floatFromInt(try readI16Big(glyph_data, offset + 4))) / 16384.0;
            d = @as(f64, @floatFromInt(try readI16Big(glyph_data, offset + 6))) / 16384.0;
            offset += 8;
        }

        // Translation
        var dx: f64 = 0;
        var dy: f64 = 0;
        if ((flags & ComponentFlags.ARGS_ARE_XY_VALUES) != 0) {
            dx = @floatFromInt(arg1);
            dy = @floatFromInt(arg2);
        }
        // Note: point matching (ARGS_ARE_XY_VALUES not set) is not implemented
        // as it's rarely used and requires access to the parent glyph's points

        // Parse the component glyph
        var component_shape = try parseGlyph(
            allocator,
            data,
            loca_offset,
            glyf_offset,
            glyph_index,
            num_glyphs,
            use_long_loca,
        );
        defer component_shape.deinit();

        // Apply transformation to component and add to our contours
        for (component_shape.contours) |component_contour| {
            var transformed_edges = allocator.alloc(EdgeSegment, component_contour.edges.len) catch return ParseError.OutOfMemory;
            errdefer allocator.free(transformed_edges);

            for (component_contour.edges, 0..) |e, i| {
                transformed_edges[i] = transformEdge(e, a, b, c, d, dx, dy);
            }

            const new_contour = Contour.fromEdges(allocator, transformed_edges);
            all_contours.append(allocator, new_contour) catch return ParseError.OutOfMemory;
        }

        has_more_components = (flags & ComponentFlags.MORE_COMPONENTS) != 0;
    }

    // Skip instructions if present (we already parsed all components)
    // The WE_HAVE_INSTRUCTIONS flag would have been in the last component's flags

    const contours_slice = all_contours.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
    return Shape.fromContours(allocator, contours_slice);
}

/// Transform a point by a 2x2 matrix plus translation.
fn transformPoint(p: Vec2, a: f64, b: f64, c: f64, d: f64, dx: f64, dy: f64) Vec2 {
    return Vec2.init(
        a * p.x + c * p.y + dx,
        b * p.x + d * p.y + dy,
    );
}

/// Transform an edge segment by a 2x2 matrix plus translation.
fn transformEdge(e: EdgeSegment, a: f64, b: f64, c: f64, d: f64, dx: f64, dy: f64) EdgeSegment {
    return switch (e) {
        .linear => |lin| .{
            .linear = LinearSegment{
                .p0 = transformPoint(lin.p0, a, b, c, d, dx, dy),
                .p1 = transformPoint(lin.p1, a, b, c, d, dx, dy),
                .color = lin.color,
            },
        },
        .quadratic => |quad| .{
            .quadratic = QuadraticSegment{
                .p0 = transformPoint(quad.p0, a, b, c, d, dx, dy),
                .p1 = transformPoint(quad.p1, a, b, c, d, dx, dy),
                .p2 = transformPoint(quad.p2, a, b, c, d, dx, dy),
                .color = quad.color,
            },
        },
        .cubic => |cub| .{
            .cubic = edge.CubicSegment{
                .p0 = transformPoint(cub.p0, a, b, c, d, dx, dy),
                .p1 = transformPoint(cub.p1, a, b, c, d, dx, dy),
                .p2 = transformPoint(cub.p2, a, b, c, d, dx, dy),
                .p3 = transformPoint(cub.p3, a, b, c, d, dx, dy),
                .color = cub.color,
            },
        },
    };
}

// ============================================================================
// Tests
// ============================================================================

test "getGlyphOffset - short loca format" {
    // Build minimal loca table (short format: 16-bit values, actual offset = value * 2)
    var data: [256]u8 = undefined;
    @memset(&data, 0);

    const loca_offset: usize = 0;
    const glyf_offset: usize = 100;

    // Glyph 0: offset 0, length 10
    data[0] = 0x00;
    data[1] = 0x00; // offset 0
    data[2] = 0x00;
    data[3] = 0x05; // offset 10 (5 * 2)

    // Glyph 1: offset 10, length 20
    data[4] = 0x00;
    data[5] = 0x0F; // offset 30 (15 * 2)

    const result0 = try getGlyphOffset(&data, loca_offset, glyf_offset, 0, 2, false);
    try std.testing.expectEqual(@as(usize, 100), result0.offset);
    try std.testing.expectEqual(@as(usize, 10), result0.length);

    const result1 = try getGlyphOffset(&data, loca_offset, glyf_offset, 1, 2, false);
    try std.testing.expectEqual(@as(usize, 110), result1.offset);
    try std.testing.expectEqual(@as(usize, 20), result1.length);
}

test "getGlyphOffset - long loca format" {
    var data: [256]u8 = undefined;
    @memset(&data, 0);

    const loca_offset: usize = 0;
    const glyf_offset: usize = 100;

    // Glyph 0: offset 0, length 50
    data[0] = 0x00;
    data[1] = 0x00;
    data[2] = 0x00;
    data[3] = 0x00;
    data[4] = 0x00;
    data[5] = 0x00;
    data[6] = 0x00;
    data[7] = 0x32; // 50

    // Glyph 1: offset 50, length 100
    data[8] = 0x00;
    data[9] = 0x00;
    data[10] = 0x00;
    data[11] = 0x96; // 150

    const result0 = try getGlyphOffset(&data, loca_offset, glyf_offset, 0, 2, true);
    try std.testing.expectEqual(@as(usize, 100), result0.offset);
    try std.testing.expectEqual(@as(usize, 50), result0.length);

    const result1 = try getGlyphOffset(&data, loca_offset, glyf_offset, 1, 2, true);
    try std.testing.expectEqual(@as(usize, 150), result1.offset);
    try std.testing.expectEqual(@as(usize, 100), result1.length);
}

test "getGlyphOffset - invalid glyph index" {
    var data: [16]u8 = undefined;
    @memset(&data, 0);

    try std.testing.expectError(ParseError.InvalidGlyph, getGlyphOffset(&data, 0, 100, 5, 2, false));
}

test "buildContour - simple triangle (all on-curve)" {
    const allocator = std.testing.allocator;

    const points = [_]GlyphPoint{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 100, .y = 0, .on_curve = true },
        .{ .x = 50, .y = 100, .on_curve = true },
    };

    var c = try buildContour(allocator, &points);
    defer c.deinit();

    // Should have 3 linear segments
    try std.testing.expectEqual(@as(usize, 3), c.edges.len);
    try std.testing.expect(c.isClosed());

    // Check first edge
    const e0 = c.edges[0].linear;
    try std.testing.expectApproxEqAbs(@as(f64, 0), e0.p0.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), e0.p0.y, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 100), e0.p1.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), e0.p1.y, 1e-10);
}

test "buildContour - quadratic curve" {
    const allocator = std.testing.allocator;

    // A simple curved segment: on-curve, off-curve, on-curve
    const points = [_]GlyphPoint{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 50, .y = 100, .on_curve = false }, // control point
        .{ .x = 100, .y = 0, .on_curve = true },
    };

    var c = try buildContour(allocator, &points);
    defer c.deinit();

    // Should have 2 edges: one quadratic and one linear (to close)
    try std.testing.expect(c.edges.len >= 1);
    try std.testing.expect(c.isClosed());

    // First edge should be quadratic
    const e0 = c.edges[0].quadratic;
    try std.testing.expectApproxEqAbs(@as(f64, 0), e0.p0.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), e0.p0.y, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 50), e0.p1.x, 1e-10); // control
    try std.testing.expectApproxEqAbs(@as(f64, 100), e0.p1.y, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 100), e0.p2.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), e0.p2.y, 1e-10);
}

test "buildContour - consecutive off-curve points" {
    const allocator = std.testing.allocator;

    // Consecutive off-curve points create implicit on-curve at midpoint
    const points = [_]GlyphPoint{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 50, .y = 100, .on_curve = false },
        .{ .x = 100, .y = 100, .on_curve = false }, // implicit on-curve at (75, 100)
        .{ .x = 150, .y = 0, .on_curve = true },
    };

    var c = try buildContour(allocator, &points);
    defer c.deinit();

    // Should have multiple edges with implicit midpoint
    try std.testing.expect(c.edges.len >= 2);
    try std.testing.expect(c.isClosed());
}

test "transformPoint" {
    // Identity transform
    const p1 = transformPoint(Vec2.init(10, 20), 1, 0, 0, 1, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 10), p1.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 20), p1.y, 1e-10);

    // Translation only
    const p2 = transformPoint(Vec2.init(10, 20), 1, 0, 0, 1, 5, 10);
    try std.testing.expectApproxEqAbs(@as(f64, 15), p2.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 30), p2.y, 1e-10);

    // Scale
    const p3 = transformPoint(Vec2.init(10, 20), 2, 0, 0, 0.5, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 20), p3.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 10), p3.y, 1e-10);
}

test "parseSimpleGlyph - empty glyph" {
    const allocator = std.testing.allocator;

    var glyph_data: [10]u8 = undefined;
    @memset(&glyph_data, 0);

    // numberOfContours = 0
    glyph_data[0] = 0x00;
    glyph_data[1] = 0x00;

    var shape = try parseSimpleGlyph(allocator, &glyph_data, 0);
    defer shape.deinit();

    try std.testing.expect(shape.isEmpty());
}
