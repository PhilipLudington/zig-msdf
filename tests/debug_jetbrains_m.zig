const std = @import("std");
const msdf = @import("msdf");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Try common JetBrains Mono paths
    const font_paths = [_][]const u8{
        "/Users/mrphil/Fun/libkoda-terminal/deps/ghostty/src/font/res/JetBrainsMonoNerdFont-Regular.ttf",
        "/Users/mrphil/Fun/zig-msdf-examples/src/fonts/JetBrainsMono-Regular.otf",
        "/Users/mrphil/Library/Fonts/JetBrainsMono-Regular.ttf",
        "/Library/Fonts/JetBrainsMono-Regular.ttf",
    };

    var font: ?msdf.Font = null;
    var used_path: []const u8 = "";
    for (font_paths) |path| {
        font = msdf.Font.fromFile(allocator, path) catch continue;
        used_path = path;
        break;
    }

    if (font == null) {
        std.debug.print("Could not find JetBrains Mono font. Tried:\n", .{});
        for (font_paths) |path| {
            std.debug.print("  {s}\n", .{path});
        }
        return;
    }
    defer font.?.deinit();

    std.debug.print("Using font: {s}\n\n", .{used_path});

    const head_data = font.?.getTableData("head") orelse return error.MissingTable;
    const head = try msdf.head_maxp.HeadTable.parse(head_data);

    const maxp_data = font.?.getTableData("maxp") orelse return error.MissingTable;
    const maxp = try msdf.head_maxp.MaxpTable.parse(maxp_data);

    const cmap_table_offset = font.?.findTable("cmap").?.offset;
    const cmap_table = try msdf.cmap.CmapTable.parse(font.?.data, cmap_table_offset);
    const glyph_index = try cmap_table.getGlyphIndex('M');

    const loca_table = font.?.findTable("loca") orelse return error.MissingTable;
    const glyf_table = font.?.findTable("glyf") orelse return error.MissingTable;

    var shape = try msdf.glyf.parseGlyph(
        allocator,
        font.?.data,
        loca_table.offset,
        glyf_table.offset,
        glyph_index,
        maxp.num_glyphs,
        head.usesLongLocaFormat(),
    );
    defer shape.deinit();

    std.debug.print("=== JetBrains Mono 'M' Contour Analysis ===\n\n", .{});

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
