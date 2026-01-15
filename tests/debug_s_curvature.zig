const std = @import("std");
const msdf = @import("msdf");

const Shape = msdf.contour.Shape;
const EdgeSegment = msdf.edge.EdgeSegment;

// Helper to load a glyph shape from a font
fn loadGlyphShape(allocator: std.mem.Allocator, font: msdf.Font, codepoint: u21) !Shape {
    // Parse required tables
    const head_data = font.getTableData("head") orelse return error.MissingTable;
    const head = msdf.head_maxp.HeadTable.parse(head_data) catch return error.InvalidHeadTable;

    const maxp_data = font.getTableData("maxp") orelse return error.MissingTable;
    const maxp = msdf.head_maxp.MaxpTable.parse(maxp_data) catch return error.InvalidMaxpTable;

    _ = font.getTableData("cmap") orelse return error.MissingTable;
    const cmap_table_offset = font.findTable("cmap").?.offset;
    const cmap_table = msdf.cmap.CmapTable.parse(font.data, cmap_table_offset) catch return error.InvalidCmapTable;

    // Look up glyph index from codepoint
    const glyph_index = cmap_table.getGlyphIndex(codepoint) catch return error.InvalidCmapTable;

    // Parse glyph outline (TrueType)
    const loca_table = font.findTable("loca") orelse return error.MissingTable;
    const glyf_table = font.findTable("glyf") orelse return error.MissingTable;

    return msdf.glyf.parseGlyph(
        allocator,
        font.data,
        loca_table.offset,
        glyf_table.offset,
        glyph_index,
        maxp.num_glyphs,
        head.usesLongLocaFormat(),
    );
}

test "debug S character curvature" {
    const allocator = std.testing.allocator;

    var font = msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf") catch |err| {
        std.debug.print("Error loading font: {}\n", .{err});
        return;
    };
    defer font.deinit();

    // Get the S glyph
    var shape = loadGlyphShape(allocator, font, 'S') catch |err| {
        std.debug.print("Error getting shape: {}\n", .{err});
        return;
    };
    defer shape.deinit();

    std.debug.print("\n=== S character BEFORE coloring ===\n", .{});
    printShapeInfo(&shape);

    // Now color the edges and see what happens
    msdf.coloring.colorEdgesSimple(&shape);

    std.debug.print("\n=== S character AFTER coloring ===\n", .{});
    printShapeInfo(&shape);
}

test "debug D character curvature" {
    const allocator = std.testing.allocator;

    var font = msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf") catch |err| {
        std.debug.print("Error loading font: {}\n", .{err});
        return;
    };
    defer font.deinit();

    // Get the D glyph
    var shape = loadGlyphShape(allocator, font, 'D') catch |err| {
        std.debug.print("Error getting shape: {}\n", .{err});
        return;
    };
    defer shape.deinit();

    std.debug.print("\n=== D character BEFORE coloring ===\n", .{});
    printShapeInfo(&shape);

    // Now color the edges and see what happens
    msdf.coloring.colorEdgesSimple(&shape);

    std.debug.print("\n=== D character AFTER coloring ===\n", .{});
    printShapeInfo(&shape);
}

fn printShapeInfo(shape: *const Shape) void {
    std.debug.print("Contours: {d}\n", .{shape.contours.len});

    for (shape.contours, 0..) |contour, ci| {
        std.debug.print("\nContour {d}: {d} edges\n", .{ ci, contour.edges.len });

        var prev_curv: f64 = 0;
        for (contour.edges, 0..) |edge, ei| {
            const curv = edge.curvatureSign();
            const color = edge.getColor();
            const color_str = switch (color) {
                .black => "black",
                .yellow => "yellow",
                .magenta => "magenta",
                .cyan => "cyan",
                .white => "white",
            };

            const edge_type = switch (edge) {
                .linear => "linear",
                .quadratic => "quad",
                .cubic => "cubic",
            };

            // Check for curvature reversal
            var reversal_marker: []const u8 = "";
            if (ei > 0) {
                const opposite = (prev_curv > 0 and curv < 0) or (prev_curv < 0 and curv > 0);
                const min_curv = @min(@abs(prev_curv), @abs(curv));
                const max_curv = @max(@abs(prev_curv), @abs(curv));
                const meaningful = max_curv > 0 and min_curv > max_curv * 0.01;
                if (opposite and meaningful) {
                    reversal_marker = " <-- REVERSAL";
                }
            }

            // Get start/end points
            const start = edge.startPoint();
            const end = edge.endPoint();

            std.debug.print("  [{d:2}] {s:6} curv={d:10.2} color={s:7} ({d:.1},{d:.1})->({d:.1},{d:.1}){s}\n", .{
                ei,
                edge_type,
                curv,
                color_str,
                start.x,
                start.y,
                end.x,
                end.y,
                reversal_marker,
            });

            prev_curv = curv;
        }
    }
}
