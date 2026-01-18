//! Debug tool to analyze CFF font contour orientation issues.
//!
//! Run with: zig build cff-orient-debug -- path/to/font.otf [character]
//!
//! This tool shows contour winding before and after orientContours() to help
//! diagnose why CFF fonts might have filled-in holes.

const std = @import("std");
const msdf = @import("msdf");
const contour = msdf.contour;
const math = msdf.math;
const edge = msdf.edge;
const cff = msdf.cff;
const cmap = msdf.cmap;
const head_maxp = msdf.head_maxp;

const Vec2 = math.Vec2;
const EdgeSegment = edge.EdgeSegment;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <font.otf> [character]\n", .{args[0]});
        std.debug.print("\nAnalyzes contour orientation for CFF fonts.\n", .{});
        return;
    }

    const font_path = args[1];
    const character: u21 = if (args.len > 2) blk: {
        const char_arg = args[2];
        if (char_arg.len > 0) {
            break :blk std.unicode.utf8Decode(char_arg) catch 'B';
        }
        break :blk 'B';
    } else 'B';

    std.debug.print("=== CFF Orientation Debug Tool ===\n\n", .{});
    std.debug.print("Font: {s}\n", .{font_path});
    std.debug.print("Character: {u} (U+{X:0>4})\n\n", .{ character, character });

    // Load the font
    var font = msdf.Font.fromFile(allocator, font_path) catch |err| {
        std.debug.print("Error loading font: {}\n", .{err});
        return;
    };
    defer font.deinit();

    // Check if it's a CFF font
    const cff_table = font.findTable("CFF ") orelse {
        std.debug.print("Error: Not a CFF font (no CFF table found)\n", .{});
        std.debug.print("This tool is for debugging CFF (OpenType) fonts.\n", .{});
        return;
    };

    // Get glyph index
    const cmap_table_offset = font.findTable("cmap").?.offset;
    const cmap_table = cmap.CmapTable.parse(font.data, cmap_table_offset) catch {
        std.debug.print("Error parsing cmap table\n", .{});
        return;
    };
    const glyph_index = cmap_table.getGlyphIndex(character) catch {
        std.debug.print("Error: Character not found in font\n", .{});
        return;
    };

    std.debug.print("Glyph index: {d}\n\n", .{glyph_index});

    // Parse the glyph shape
    var shape = cff.parseGlyph(
        allocator,
        font.data,
        cff_table.offset,
        glyph_index,
    ) catch |err| {
        std.debug.print("Error parsing glyph: {}\n", .{err});
        return;
    };
    defer shape.deinit();

    std.debug.print("=== BEFORE orientContours() ===\n", .{});
    std.debug.print("Number of contours: {d}\n\n", .{shape.contours.len});

    for (shape.contours, 0..) |c, i| {
        const winding = c.winding();
        const winding_type = if (winding > 0) "CCW (outer)" else if (winding < 0) "CW (hole)" else "degenerate";
        const bounds = c.bounds();

        std.debug.print("Contour {d}:\n", .{i});
        std.debug.print("  Edges: {d}\n", .{c.edges.len});
        std.debug.print("  Winding: {d:.2} -> {s}\n", .{ winding, winding_type });
        std.debug.print("  Bounds: ({d:.1}, {d:.1}) - ({d:.1}, {d:.1})\n", .{
            bounds.min.x,
            bounds.min.y,
            bounds.max.x,
            bounds.max.y,
        });

        // Print edge types
        var line_count: usize = 0;
        var quad_count: usize = 0;
        var cubic_count: usize = 0;
        for (c.edges) |e| {
            switch (e) {
                .linear => line_count += 1,
                .quadratic => quad_count += 1,
                .cubic => cubic_count += 1,
            }
        }
        std.debug.print("  Edge types: {d} linear, {d} quadratic, {d} cubic\n", .{
            line_count, quad_count, cubic_count,
        });
        std.debug.print("\n", .{});
    }

    // Check containment relationships (which contours contain which)
    std.debug.print("=== Containment Analysis ===\n", .{});
    for (shape.contours, 0..) |c, i| {
        // Get a point inside this contour for testing
        if (c.edges.len == 0) continue;
        const test_point = getContourInteriorPoint(c);
        std.debug.print("Contour {d} test point: ({d:.1}, {d:.1})\n", .{ i, test_point.x, test_point.y });

        var contained_by: [16]usize = undefined;
        var contained_count: usize = 0;

        for (shape.contours, 0..) |other, other_i| {
            if (other_i != i) {
                if (pointInsideContour(test_point, other)) {
                    if (contained_count < 16) {
                        contained_by[contained_count] = other_i;
                        contained_count += 1;
                    }
                }
            }
        }

        if (contained_count == 0) {
            std.debug.print("  -> Not contained by any other contour (outermost)\n", .{});
        } else {
            std.debug.print("  -> Contained by contour(s): ", .{});
            for (0..contained_count) |j| {
                if (j > 0) std.debug.print(", ", .{});
                std.debug.print("{d}", .{contained_by[j]});
            }
            std.debug.print("\n", .{});
        }
    }

    std.debug.print("\n=== Calling orientContours() ===\n\n", .{});
    shape.orientContours();

    std.debug.print("=== AFTER orientContours() ===\n\n", .{});

    for (shape.contours, 0..) |c, i| {
        const winding = c.winding();
        const winding_type = if (winding > 0) "CCW (outer)" else if (winding < 0) "CW (hole)" else "degenerate";

        std.debug.print("Contour {d}: winding = {d:.2} -> {s}\n", .{ i, winding, winding_type });
    }

    std.debug.print("\n=== Expected Winding (based on containment) ===\n", .{});
    for (shape.contours, 0..) |c, i| {
        if (c.edges.len == 0) continue;

        // Count how many contours contain this one
        const test_point = getContourInteriorPoint(c);
        var containment_count: usize = 0;
        for (shape.contours, 0..) |other, other_i| {
            if (other_i != i) {
                if (pointInsideContour(test_point, other)) {
                    containment_count += 1;
                }
            }
        }

        const should_be_ccw = (containment_count % 2 == 0);
        const actual_winding = c.winding();
        const is_ccw = actual_winding > 0;
        const is_correct = (should_be_ccw == is_ccw);

        std.debug.print("Contour {d}: contained by {d} -> should be {s}, is {s} -> {s}\n", .{
            i,
            containment_count,
            if (should_be_ccw) "CCW" else "CW",
            if (is_ccw) "CCW" else "CW",
            if (is_correct) "CORRECT" else "WRONG!",
        });
    }

    std.debug.print("\n=== Analysis Complete ===\n", .{});
}

fn getContourInteriorPoint(c: contour.Contour) Vec2 {
    if (c.edges.len == 0) return Vec2{ .x = 0, .y = 0 };

    // Use centroid of first few edge midpoints
    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    const sample_count = @min(c.edges.len, 4);

    for (0..sample_count) |i| {
        const p = c.edges[i].point(0.5);
        sum_x += p.x;
        sum_y += p.y;
    }

    return Vec2{
        .x = sum_x / @as(f64, @floatFromInt(sample_count)),
        .y = sum_y / @as(f64, @floatFromInt(sample_count)),
    };
}

fn pointInsideContour(point: Vec2, c: contour.Contour) bool {
    // Use winding number test
    var winding: f64 = 0;
    for (c.edges) |e| {
        winding += edgeWindingContribution(e, point);
    }
    return @abs(winding) > 0.5;
}

fn edgeWindingContribution(e: EdgeSegment, point: Vec2) f64 {
    // Sample the edge and sum angle changes
    const samples = 16;
    var total: f64 = 0;

    for (0..samples) |i| {
        const t0 = @as(f64, @floatFromInt(i)) / @as(f64, samples);
        const t1 = @as(f64, @floatFromInt(i + 1)) / @as(f64, samples);

        const p0 = e.point(t0);
        const p1 = e.point(t1);

        // Cross product for winding contribution
        const v0x = p0.x - point.x;
        const v0y = p0.y - point.y;
        const v1x = p1.x - point.x;
        const v1y = p1.y - point.y;

        total += std.math.atan2(v0x * v1y - v0y * v1x, v0x * v1x + v0y * v1y);
    }

    return total / (2 * std.math.pi);
}
