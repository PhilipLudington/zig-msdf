const std = @import("std");
const msdf = @import("msdf");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/SFNSMono.ttf");
    defer font.deinit();

    const head_data = font.getTableData("head") orelse return error.MissingTable;
    const head = try msdf.head_maxp.HeadTable.parse(head_data);

    const maxp_data = font.getTableData("maxp") orelse return error.MissingTable;
    const maxp = try msdf.head_maxp.MaxpTable.parse(maxp_data);

    const cmap_table_offset = font.findTable("cmap").?.offset;
    const cmap_table = try msdf.cmap.CmapTable.parse(font.data, cmap_table_offset);
    const glyph_index = try cmap_table.getGlyphIndex('$');

    const loca_table = font.findTable("loca") orelse return error.MissingTable;
    const glyf_table = font.findTable("glyf") orelse return error.MissingTable;

    var shape = try msdf.glyf.parseGlyph(
        allocator,
        font.data,
        loca_table.offset,
        glyf_table.offset,
        glyph_index,
        maxp.num_glyphs,
        head.usesLongLocaFormat(),
    );
    defer shape.deinit();

    std.debug.print("=== SF Mono '$' Contour Analysis ===\n\n", .{});

    std.debug.print("BEFORE orientContours:\n", .{});
    for (shape.contours, 0..) |contour, i| {
        const w = contour.winding();
        const bounds = contour.bounds();
        std.debug.print("  Contour {d}: winding={d:.0} ({s}), {d} edges\n", .{
            i,
            w,
            if (w > 0) "CCW" else if (w < 0) "CW" else "zero",
            contour.edges.len,
        });
        std.debug.print("    bounds: ({d:.0},{d:.0}) to ({d:.0},{d:.0})\n", .{
            bounds.min.x, bounds.min.y, bounds.max.x, bounds.max.y,
        });
    }

    shape.orientContours();

    std.debug.print("\nAFTER orientContours:\n", .{});
    for (shape.contours, 0..) |contour, i| {
        const w = contour.winding();
        std.debug.print("  Contour {d}: winding={d:.0} ({s})\n", .{
            i,
            w,
            if (w > 0) "CCW=solid" else if (w < 0) "CW=hole" else "zero",
        });
    }
}
