const std = @import("std");
const msdf = @import("msdf");
const Vec2 = msdf.math.Vec2;
const Shape = msdf.contour.Shape;
const EdgeSegment = msdf.edge.EdgeSegment;
const EdgeColor = msdf.edge.EdgeColor;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load font
    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/SFNSMono.ttf");
    defer font.deinit();

    // Get shape for 'A'
    const head_data = font.getTableData("head") orelse return error.MissingTable;
    const head = try msdf.head_maxp.HeadTable.parse(head_data);

    const maxp_data = font.getTableData("maxp") orelse return error.MissingTable;
    const maxp = try msdf.head_maxp.MaxpTable.parse(maxp_data);

    const cmap_table_offset = font.findTable("cmap").?.offset;
    const cmap_table = try msdf.cmap.CmapTable.parse(font.data, cmap_table_offset);
    const glyph_index = try cmap_table.getGlyphIndex('A');

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

    // Check ORIGINAL windings before orientation
    std.debug.print("=== BEFORE orientContours ===\n", .{});
    for (shape.contours, 0..) |contour, i| {
        const w = contour.winding();
        std.debug.print("  Contour {d}: winding={d:.2} ({s})\n", .{
            i,
            w,
            if (w > 0) "CCW" else if (w < 0) "CW" else "unknown",
        });
    }
    std.debug.print("\n", .{});

    // Apply coloring before orientation (matching pipeline)
    msdf.coloring.colorEdgesSimple(&shape);
    shape.orientContours();

    std.debug.print("=== AFTER orientContours ===\n", .{});

    // Get bounds and compute transform (matching autoframe)
    const bounds = shape.bounds();
    const dims = Vec2{ .x = bounds.max.x - bounds.min.x, .y = bounds.max.y - bounds.min.y };
    const px_range: f64 = 4.0;
    const width: u32 = 64;
    const height: u32 = 64;

    const frame_x = @as(f64, @floatFromInt(width)) - px_range;
    const frame_y = @as(f64, @floatFromInt(height)) - px_range;

    const scale = @min(frame_x / dims.x, frame_y / dims.y);
    var translate = Vec2{
        .x = (frame_x - dims.x * scale) / 2.0 - bounds.min.x * scale,
        .y = (frame_y - dims.y * scale) / 2.0 - bounds.min.y * scale,
    };
    translate.x += (px_range / 2.0) / scale;
    translate.y += (px_range / 2.0) / scale;

    std.debug.print("=== Debug pixel (21, 39) for SF Mono A ===\n\n", .{});
    std.debug.print("Transform: scale={d:.6}, translate=({d:.2},{d:.2})\n", .{ scale, translate.x, translate.y });
    std.debug.print("Bounds: ({d:.2},{d:.2}) to ({d:.2},{d:.2})\n\n", .{ bounds.min.x, bounds.min.y, bounds.max.x, bounds.max.y });

    // Convert pixel (21, 39) to shape coordinates
    const px: f64 = 21.0 + 0.5;
    const py: f64 = 39.0 + 0.5;
    const shape_x = (px / scale) - translate.x;
    const shape_y = (@as(f64, @floatFromInt(height)) - py) / scale - translate.y;
    const point = Vec2{ .x = shape_x, .y = shape_y };

    std.debug.print("Pixel (21, 39) -> Shape point ({d:.2}, {d:.2})\n\n", .{ shape_x, shape_y });

    // Check winding of each contour
    std.debug.print("Contour windings:\n", .{});
    for (shape.contours, 0..) |contour, i| {
        const w = contour.winding();
        std.debug.print("  Contour {d}: winding={d:.2} ({s})\n", .{
            i,
            w,
            if (w > 0) "CCW=solid" else if (w < 0) "CW=hole" else "unknown",
        });
    }
    std.debug.print("\n", .{});

    // Find distances to all edges
    std.debug.print("=== Distances to all edges ===\n", .{});

    for (shape.contours, 0..) |contour, ci| {
        std.debug.print("\nContour {d} ({d} edges):\n", .{ ci, contour.edges.len });

        for (contour.edges, 0..) |edge, ei| {
            const result = edge.signedDistanceWithParam(point);
            const dist = result.distance;

            const color_str = switch (edge.getColor()) {
                .white => "white",
                .black => "black",
                .yellow => "yellow",
                .cyan => "cyan",
                .magenta => "magenta",
            };

            // Check if this is a significant edge (close to point)
            const marker = if (@abs(dist.distance) < 200) " <-- CLOSE" else "";

            const segment_type = switch (edge) {
                .linear => "linear",
                .quadratic => "quadratic",
                .cubic => "cubic",
            };
            std.debug.print("  Edge {d} ({s}, {s}): dist={d:.2}, param={d:.3}, ortho={d:.3}{s}\n", .{
                ei,
                segment_type,
                color_str,
                dist.distance,
                result.param,
                dist.orthogonality,
                marker,
            });

            // Print edge endpoints
            const start = edge.startPoint();
            const end = edge.endPoint();
            std.debug.print("    start=({d:.1},{d:.1}) end=({d:.1},{d:.1})\n", .{ start.x, start.y, end.x, end.y });
        }
    }
}
