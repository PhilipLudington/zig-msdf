const std = @import("std");
const msdf = @import("msdf");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const font_path = "/Users/mrphil/Fun/zig-msdf-examples/src/fonts/JetBrainsMono-Regular.otf";

    var font = msdf.Font.fromFile(allocator, font_path) catch |err| {
        std.debug.print("Failed to load font: {}\n", .{err});
        return;
    };
    defer font.deinit();

    std.debug.print("=== JetBrains Mono OTF Analysis ===\n", .{});
    std.debug.print("Font: {s}\n\n", .{font_path});

    // Check problematic characters
    const chars = [_]u8{ 'M', 'N', 'W', 'w', '{', '}', '|' };

    for (chars) |char| {
        std.debug.print("=== Character '{c}' (U+{X:0>4}) ===\n", .{ char, char });

        // Get glyph index
        const cmap_table_offset = font.findTable("cmap").?.offset;
        const cmap_table = msdf.cmap.CmapTable.parse(font.data, cmap_table_offset) catch {
            std.debug.print("  Error parsing cmap\n\n", .{});
            continue;
        };
        const glyph_index = cmap_table.getGlyphIndex(char) catch {
            std.debug.print("  Error getting glyph index\n\n", .{});
            continue;
        };

        // Parse CFF glyph
        const cff_table = font.findTable("CFF ") orelse {
            std.debug.print("  No CFF table found\n\n", .{});
            continue;
        };

        var shape = msdf.cff.parseGlyph(allocator, font.data, cff_table.offset, glyph_index) catch |err| {
            std.debug.print("  Error parsing glyph: {}\n\n", .{err});
            continue;
        };
        defer shape.deinit();

        std.debug.print("  Contours (before orient): {d}\n", .{shape.contours.len});

        for (shape.contours, 0..) |contour, i| {
            const w = contour.winding();
            const bounds = contour.bounds();
            std.debug.print("    Contour {d}: winding={d:.0} ({s}), {d} edges\n", .{
                i,
                w,
                if (w > 0) "CCW" else if (w < 0) "CW" else "zero",
                contour.edges.len,
            });
            std.debug.print("      bounds: ({d:.0},{d:.0}) to ({d:.0},{d:.0})\n", .{
                bounds.min.x, bounds.min.y, bounds.max.x, bounds.max.y,
            });
        }

        shape.orientContours();

        std.debug.print("  After orientContours:\n", .{});
        for (shape.contours, 0..) |contour, i| {
            const w = contour.winding();
            std.debug.print("    Contour {d}: winding={d:.0} ({s})\n", .{
                i,
                w,
                if (w > 0) "CCW=solid" else if (w < 0) "CW=hole" else "zero",
            });
        }
        std.debug.print("\n", .{});
    }
}
