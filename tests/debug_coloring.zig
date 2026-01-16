const std = @import("std");
const msdf = @import("msdf");

const Shape = msdf.contour.Shape;

/// Parse glyph shape from font (replicating what generateGlyph does internally)
fn parseGlyphShape(allocator: std.mem.Allocator, font: msdf.Font, codepoint: u21) !Shape {
    const head_data = font.getTableData("head") orelse return error.MissingTable;
    const head = try msdf.head_maxp.HeadTable.parse(head_data);

    const maxp_data = font.getTableData("maxp") orelse return error.MissingTable;
    const maxp = try msdf.head_maxp.MaxpTable.parse(maxp_data);

    const cmap_table_offset = font.findTable("cmap").?.offset;
    const cmap_table = try msdf.cmap.CmapTable.parse(font.data, cmap_table_offset);

    const glyph_index = try cmap_table.getGlyphIndex(codepoint);

    const is_cff = font.findTable("CFF ") != null;

    if (is_cff) {
        const cff_table = font.findTable("CFF ").?;
        return msdf.cff.parseGlyph(allocator, font.data, cff_table.offset, glyph_index);
    } else {
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
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var font = msdf.Font.fromFile(allocator, "/Users/mrphil/Fun/zig-msdf-examples/src/fonts/DejaVuSans.ttf") catch |err| {
        std.debug.print("Failed to load font: {}\n", .{err});
        return;
    };
    defer font.deinit();

    for ([_]u8{ 'u', 'U', 'S', 'D', 'M' }) |char| {
        std.debug.print("\n\n========== Character '{c}' ==========\n", .{char});

        var result = msdf.generateGlyph(allocator, font, char, .{
            .size = 64,
            .padding = 4,
            .range = 4.0,
        }) catch |err| {
            std.debug.print("Failed to generate glyph: {}\n", .{err});
            continue;
        };
        defer result.deinit(allocator);

        std.debug.print("Generated {d}x{d} bitmap\n", .{ result.width, result.height });

        // Export PPM file for visual verification
        if (char == 'u') {
            const ppm_path = "/tmp/u_glyph.ppm";
            var ppm_file = std.fs.cwd().createFile(ppm_path, .{}) catch |err| {
                std.debug.print("Failed to create PPM: {}\n", .{err});
                continue;
            };
            defer ppm_file.close();

            var header_buf: [64]u8 = undefined;
            const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ result.width, result.height }) catch unreachable;
            ppm_file.writeAll(header) catch {};
            ppm_file.writeAll(result.pixels) catch {};
            std.debug.print("Exported to {s}\n", .{ppm_path});
        }

        // Debug: show where corners would be protected
        if (char == 'U' or char == 'u') {
            var shape_for_corners = parseGlyphShape(allocator, font, char) catch continue;
            defer shape_for_corners.deinit();
            msdf.coloring.colorEdgesSimple(&shape_for_corners);

            const bounds = shape_for_corners.bounds();
            const transform = msdf.generate.calculateTransform(bounds, result.width, result.height, 4);

            std.debug.print("\n  === Corner positions in pixel coords ===\n", .{});
            for (shape_for_corners.contours) |contour| {
                const edge_count = contour.edges.len;
                for (0..edge_count) |i| {
                    const prev_idx = if (i == 0) edge_count - 1 else i - 1;
                    const prev_edge = contour.edges[prev_idx];
                    const curr_edge = contour.edges[i];
                    const prev_color = prev_edge.getColor();
                    const curr_color = curr_edge.getColor();

                    if (prev_color != curr_color) {
                        const corner_point = prev_edge.endPoint();
                        const pixel_pos = transform.shapeToPixel(corner_point);
                        std.debug.print("    Edge {d}->{d}: color change at ({d:.1},{d:.1})\n", .{ prev_idx, i, pixel_pos.x, pixel_pos.y });
                    }
                }
            }
        }

        // Analyze artifact region for 'U' - the top center area
        if (char == 'U' or char == 'u') {
            std.debug.print("\n  === Full Grid Analysis (top region, y=4-12) ===\n", .{});
            // Print a grid view of the top region
            var y: u32 = 4;
            while (y < 14) : (y += 1) {
                std.debug.print("y={d:2}: ", .{y});
                var x: u32 = 15;
                while (x < 50) : (x += 1) {
                    const idx = (y * result.width + x) * 3;
                    const r = result.pixels[idx];
                    const g = result.pixels[idx + 1];
                    const b = result.pixels[idx + 2];
                    const med = @max(@min(r, g), @min(@max(r, g), b));

                    // Check for channel disagreement
                    const r_inside = r > 127;
                    const g_inside = g > 127;
                    const b_inside = b > 127;
                    const inside_count: u8 = (if (r_inside) @as(u8, 1) else 0) + (if (g_inside) @as(u8, 1) else 0) + (if (b_inside) @as(u8, 1) else 0);

                    // Print character based on state
                    if (inside_count == 3) {
                        std.debug.print("#", .{}); // Inside
                    } else if (inside_count == 0) {
                        if (med > 100) {
                            std.debug.print(".", .{}); // Outside but near edge
                        } else {
                            std.debug.print(" ", .{}); // Outside far from edge
                        }
                    } else {
                        // Channel disagreement - potential artifact
                        if (inside_count == 1) {
                            std.debug.print("!", .{}); // 1 channel says inside
                        } else {
                            std.debug.print("?", .{}); // 2 channels say inside
                        }
                    }
                }
                std.debug.print("\n", .{});
            }

            std.debug.print("\n  === ALL pixels in center gap (x=28-36, y=4-10) ===\n", .{});
            std.debug.print("  (showing actual values - gap should be OUTSIDE, values < 127)\n", .{});
            y = 4;
            while (y <= 10) : (y += 1) {
                std.debug.print("  y={d}: ", .{y});
                var x: u32 = 28;
                while (x <= 36) : (x += 1) {
                    const idx = (y * result.width + x) * 3;
                    const r = result.pixels[idx];
                    const g = result.pixels[idx + 1];
                    const b = result.pixels[idx + 2];
                    const med = @max(@min(r, g), @min(@max(r, g), b));
                    if (med > 127) {
                        std.debug.print("{d:3}! ", .{med}); // ! = wrongly inside
                    } else {
                        std.debug.print("{d:3}  ", .{med});
                    }
                }
                std.debug.print("\n", .{});
            }

            // Show all remaining disagreement pixels
            std.debug.print("\n  === All disagreement pixels (full scan) ===\n", .{});
            y = 4;
            while (y < 12) : (y += 1) {
                var x: u32 = 4;
                while (x < 60) : (x += 1) {
                    const idx = (y * result.width + x) * 3;
                    const r = result.pixels[idx];
                    const g = result.pixels[idx + 1];
                    const b = result.pixels[idx + 2];
                    const r_inside = r > 127;
                    const g_inside = g > 127;
                    const b_inside = b > 127;
                    const all_agree = (r_inside == g_inside) and (g_inside == b_inside);
                    if (!all_agree) {
                        const med = @max(@min(r, g), @min(@max(r, g), b));
                        std.debug.print("    ({d},{d}): R={d} G={d} B={d} med={d}\n", .{ x, y, r, g, b, med });
                    }
                }
            }
        }

        var shape = parseGlyphShape(allocator, font, char) catch |err| {
            std.debug.print("Failed to parse shape: {}\n", .{err});
            continue;
        };
        defer shape.deinit();

        // Apply coloring
        msdf.coloring.colorEdgesSimple(&shape);

        std.debug.print("Contours: {d}\n", .{shape.contours.len});

        for (shape.contours, 0..) |contour, ci| {
            std.debug.print("\n  Contour {d}: {d} edges\n", .{ ci, contour.edges.len });

            var cyan_count: usize = 0;
            var yellow_count: usize = 0;
            var magenta_count: usize = 0;
            var white_count: usize = 0;

            for (contour.edges) |edge| {
                const color = edge.getColor();
                switch (color) {
                    .cyan => cyan_count += 1,
                    .yellow => yellow_count += 1,
                    .magenta => magenta_count += 1,
                    .white => white_count += 1,
                    else => {},
                }
            }

            std.debug.print("  Colors: cyan={d} yellow={d} magenta={d} white={d}\n", .{ cyan_count, yellow_count, magenta_count, white_count });

            const has_red = yellow_count > 0 or magenta_count > 0 or white_count > 0;
            const has_green = cyan_count > 0 or yellow_count > 0 or white_count > 0;
            const has_blue = cyan_count > 0 or magenta_count > 0 or white_count > 0;

            std.debug.print("  Channel coverage: R={} G={} B={}\n", .{ has_red, has_green, has_blue });

            if (!has_red or !has_green or !has_blue) {
                std.debug.print("  WARNING: Missing channel coverage!\n", .{});
            }

            std.debug.print("\n  Edge details:\n", .{});
            for (contour.edges, 0..) |edge, ei| {
                const start = edge.startPoint();
                const end = edge.endPoint();
                const color = edge.getColor();
                const color_name = switch (color) {
                    .cyan => "cyan",
                    .yellow => "yellow",
                    .magenta => "magenta",
                    .white => "white",
                    else => "other",
                };
                const edge_type = switch (edge) {
                    .linear => "linear",
                    .quadratic => "quadratic",
                    .cubic => "cubic",
                };
                std.debug.print("    Edge {d}: {s} {s} ({d:.1},{d:.1}) -> ({d:.1},{d:.1})\n", .{ ei, color_name, edge_type, start.x, start.y, end.x, end.y });
            }
        }
    }
}
