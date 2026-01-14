//! Debug test to analyze distance computation for O character

const std = @import("std");
const msdf = @import("msdf");
const Vec2 = msdf.math.Vec2;
const Shape = msdf.contour.Shape;
const glyf = msdf.glyf;
const cmap = msdf.cmap;
const head_maxp = msdf.head_maxp;

test "debug O distance computation" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    // Get the required tables
    const head_entry = font.findTable("head").?;
    const head = head_maxp.HeadTable.parse(font.data[head_entry.offset..][0..head_entry.length]) catch unreachable;

    const maxp_entry = font.findTable("maxp").?;
    const maxp = head_maxp.MaxpTable.parse(font.data[maxp_entry.offset..][0..maxp_entry.length]) catch unreachable;

    const cmap_entry = font.findTable("cmap").?;
    const cmap_table = cmap.CmapTable.parse(font.data, cmap_entry.offset) catch unreachable;

    const loca_entry = font.findTable("loca").?;
    const glyf_entry = font.findTable("glyf").?;

    const glyph_index = cmap_table.getGlyphIndex('O') catch unreachable;

    var shape = glyf.parseGlyph(
        allocator,
        font.data,
        loca_entry.offset,
        glyf_entry.offset,
        glyph_index,
        maxp.num_glyphs,
        head.usesLongLocaFormat(),
    ) catch unreachable;
    defer shape.deinit();

    std.debug.print("\n=== 'O' Shape Analysis ===\n", .{});
    std.debug.print("Number of contours: {}\n", .{shape.contours.len});

    for (shape.contours, 0..) |contour, ci| {
        const w = contour.winding();
        const winding_str: []const u8 = if (w > 0) "CCW/outer" else if (w < 0) "CW/inner" else "degenerate";
        std.debug.print("\nContour {}: {} edges, winding={d:.4} ({s})\n", .{
            ci,
            contour.edges.len,
            w,
            winding_str,
        });
    }

    const bounds = shape.bounds();
    std.debug.print("\nShape bounds: ({d:.2}, {d:.2}) to ({d:.2}, {d:.2})\n", .{
        bounds.min.x, bounds.min.y, bounds.max.x, bounds.max.y,
    });

    // Calculate transform (same as generateMsdf)
    const size: f64 = 32;
    const padding: f64 = 2;

    const shape_width = bounds.max.x - bounds.min.x;
    const shape_height = bounds.max.y - bounds.min.y;
    const scale = (size - 2 * padding) / @max(shape_width, shape_height);

    std.debug.print("Scale: {d:.6}\n", .{scale});

    // Test corner pixel (0, 0) - should be OUTSIDE
    const test_points = [_]struct { px: f64, py: f64, name: []const u8 }{
        .{ .px = 0, .py = 0, .name = "corner(0,0)" },
        .{ .px = 16, .py = 16, .name = "center(16,16)" },
        .{ .px = 16, .py = 8, .name = "in-ring(16,8)" },
    };

    for (test_points) |tp| {
        // Transform pixel to shape coords (same as generateMsdf pixelToShape)
        const shape_x = bounds.min.x + (tp.px + 0.5 - padding) / scale;
        const shape_y = bounds.min.y + (tp.py + 0.5 - padding) / scale;
        const point = Vec2.init(shape_x, shape_y);

        std.debug.print("\n--- {s} -> shape({d:.2}, {d:.2}) ---\n", .{ tp.name, shape_x, shape_y });

        // Compute distance from each contour
        for (shape.contours, 0..) |contour, ci| {
            var min_dist = msdf.math.SignedDistance.infinite;

            for (contour.edges) |e| {
                const sd = e.signedDistance(point);
                if (sd.lessThan(min_dist)) {
                    min_dist = sd;
                }
            }

            const inside_str: []const u8 = if (min_dist.distance < 0) "inside" else "outside";
            std.debug.print("  Contour {}: distance={d:.4} ({s})\n", .{
                ci,
                min_dist.distance,
                inside_str,
            });
        }

        // Compute overall (what generateMsdf would compute)
        var overall_min = msdf.math.SignedDistance.infinite;
        for (shape.contours) |contour| {
            for (contour.edges) |e| {
                const sd = e.signedDistance(point);
                if (sd.lessThan(overall_min)) {
                    overall_min = sd;
                }
            }
        }
        const overall_str: []const u8 = if (overall_min.distance < 0) "inside->bright" else "outside->dark";
        std.debug.print("  OVERALL: distance={d:.4} ({s})\n", .{
            overall_min.distance,
            overall_str,
        });

        // Also compute winding
        const winding = msdf.generate.computeWinding(shape, point);
        const winding_inside: []const u8 = if (winding != 0) "inside glyph" else "outside glyph";
        std.debug.print("  WINDING: {} ({s})\n", .{
            winding,
            winding_inside,
        });
    }
}

test "debug winding calculation" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    const head_entry = font.findTable("head").?;
    const head = head_maxp.HeadTable.parse(font.data[head_entry.offset..][0..head_entry.length]) catch unreachable;

    const maxp_entry = font.findTable("maxp").?;
    const maxp = head_maxp.MaxpTable.parse(font.data[maxp_entry.offset..][0..maxp_entry.length]) catch unreachable;

    const cmap_entry = font.findTable("cmap").?;
    const cmap_table = cmap.CmapTable.parse(font.data, cmap_entry.offset) catch unreachable;

    const loca_entry = font.findTable("loca").?;
    const glyf_entry = font.findTable("glyf").?;

    const glyph_index = cmap_table.getGlyphIndex('O') catch unreachable;

    var shape = glyf.parseGlyph(
        allocator,
        font.data,
        loca_entry.offset,
        glyf_entry.offset,
        glyph_index,
        maxp.num_glyphs,
        head.usesLongLocaFormat(),
    ) catch unreachable;
    defer shape.deinit();

    const bounds = shape.bounds();
    std.debug.print("\n=== Winding Debug ===\n", .{});
    std.debug.print("Shape bounds: x=[{d:.0}, {d:.0}], y=[{d:.0}, {d:.0}]\n", .{
        bounds.min.x, bounds.max.x, bounds.min.y, bounds.max.y,
    });

    // Calculate center of shape
    const center_x = (bounds.min.x + bounds.max.x) / 2;
    const center_y = (bounds.min.y + bounds.max.y) / 2;
    std.debug.print("Shape center: ({d:.0}, {d:.0})\n", .{ center_x, center_y });

    // Test points in shape coordinates
    const test_points = [_]struct { x: f64, y: f64, expected: []const u8 }{
        // Outside shape entirely
        .{ .x = 0, .y = 0, .expected = "outside" },
        .{ .x = -100, .y = center_y, .expected = "outside" },
        // Center of shape (should be in hole)
        .{ .x = center_x, .y = center_y, .expected = "hole/outside" },
        // Inside the ring (between inner and outer)
        .{ .x = bounds.min.x + 50, .y = center_y, .expected = "inside ring" },
        .{ .x = bounds.max.x - 50, .y = center_y, .expected = "inside ring" },
    };

    for (test_points) |tp| {
        const point = Vec2.init(tp.x, tp.y);
        const winding = msdf.generate.computeWinding(shape, point);
        const status: []const u8 = if (winding != 0) "INSIDE" else "OUTSIDE";
        std.debug.print("  ({d:.0}, {d:.0}): winding={}, {s} [expected: {s}]\n", .{
            tp.x, tp.y, winding, status, tp.expected,
        });
    }

    // Print first edge of each contour to understand the geometry
    std.debug.print("\nContour geometry:\n", .{});
    for (shape.contours, 0..) |contour, ci| {
        if (contour.edges.len > 0) {
            const first_edge = contour.edges[0];
            const start = first_edge.startPoint();
            const end_pt = first_edge.endPoint();
            std.debug.print("  Contour {}: first edge ({d:.0},{d:.0}) -> ({d:.0},{d:.0})\n", .{
                ci, start.x, start.y, end_pt.x, end_pt.y,
            });
        }
    }
}

test "verify sign vs winding consistency" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    const head_entry = font.findTable("head").?;
    const head = head_maxp.HeadTable.parse(font.data[head_entry.offset..][0..head_entry.length]) catch unreachable;

    const maxp_entry = font.findTable("maxp").?;
    const maxp = head_maxp.MaxpTable.parse(font.data[maxp_entry.offset..][0..maxp_entry.length]) catch unreachable;

    const cmap_entry = font.findTable("cmap").?;
    const cmap_table = cmap.CmapTable.parse(font.data, cmap_entry.offset) catch unreachable;

    const loca_entry = font.findTable("loca").?;
    const glyf_entry = font.findTable("glyf").?;

    const glyph_index = cmap_table.getGlyphIndex('O') catch unreachable;

    var shape = glyf.parseGlyph(
        allocator,
        font.data,
        loca_entry.offset,
        glyf_entry.offset,
        glyph_index,
        maxp.num_glyphs,
        head.usesLongLocaFormat(),
    ) catch unreachable;
    defer shape.deinit();

    const bounds = shape.bounds();
    const center_y = (bounds.min.y + bounds.max.y) / 2;

    std.debug.print("\n=== Sign vs Winding Consistency Check ===\n", .{});

    // Points that we know should be inside (winding confirmed)
    const inside_points = [_]Vec2{
        Vec2.init(143, center_y),  // left side of ring
        Vec2.init(1362, center_y), // right side of ring
    };

    // Points that we know should be outside
    const outside_points = [_]Vec2{
        Vec2.init(0, 0),           // far corner
        Vec2.init(-100, center_y), // left of shape
        Vec2.init(753, center_y),  // center (hole)
    };

    std.debug.print("\nINSIDE points (winding != 0, should have negative distance):\n", .{});
    for (inside_points) |point| {
        var min_dist = msdf.math.SignedDistance.infinite;
        for (shape.contours) |contour| {
            for (contour.edges) |e| {
                const sd = e.signedDistance(point);
                if (sd.lessThan(min_dist)) {
                    min_dist = sd;
                }
            }
        }
        const winding = msdf.generate.computeWinding(shape, point);
        const sign_str: []const u8 = if (min_dist.distance < 0) "negative" else "positive";
        const match_str: []const u8 = if ((winding != 0) == (min_dist.distance < 0)) "OK" else "MISMATCH!";
        std.debug.print("  ({d:.0}, {d:.0}): winding={}, dist={d:.2} ({s}) [{s}]\n", .{
            point.x, point.y, winding, min_dist.distance, sign_str, match_str,
        });
    }

    std.debug.print("\nOUTSIDE points (winding == 0, should have positive distance):\n", .{});
    for (outside_points) |point| {
        var min_dist = msdf.math.SignedDistance.infinite;
        for (shape.contours) |contour| {
            for (contour.edges) |e| {
                const sd = e.signedDistance(point);
                if (sd.lessThan(min_dist)) {
                    min_dist = sd;
                }
            }
        }
        const winding = msdf.generate.computeWinding(shape, point);
        const sign_str: []const u8 = if (min_dist.distance < 0) "negative" else "positive";
        const match_str: []const u8 = if ((winding != 0) == (min_dist.distance < 0)) "OK" else "MISMATCH!";
        std.debug.print("  ({d:.0}, {d:.0}): winding={}, dist={d:.2} ({s}) [{s}]\n", .{
            point.x, point.y, winding, min_dist.distance, sign_str, match_str,
        });
    }
}

test "debug specific problematic point" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    const head_entry = font.findTable("head").?;
    const head = head_maxp.HeadTable.parse(font.data[head_entry.offset..][0..head_entry.length]) catch unreachable;

    const maxp_entry = font.findTable("maxp").?;
    const maxp = head_maxp.MaxpTable.parse(font.data[maxp_entry.offset..][0..maxp_entry.length]) catch unreachable;

    const cmap_entry = font.findTable("cmap").?;
    const cmap_table = cmap.CmapTable.parse(font.data, cmap_entry.offset) catch unreachable;

    const loca_entry = font.findTable("loca").?;
    const glyf_entry = font.findTable("glyf").?;

    const glyph_index = cmap_table.getGlyphIndex('O') catch unreachable;

    var shape = glyf.parseGlyph(
        allocator,
        font.data,
        loca_entry.offset,
        glyf_entry.offset,
        glyph_index,
        maxp.num_glyphs,
        head.usesLongLocaFormat(),
    ) catch unreachable;
    defer shape.deinit();

    std.debug.print("\n=== Testing Problematic Point (4.88, -135.13) ===\n", .{});

    const point = Vec2.init(4.88, -135.13);

    // Test each contour
    for (shape.contours, 0..) |contour, ci| {
        var min_dist = msdf.math.SignedDistance.infinite;
        var closest_edge_idx: usize = 0;

        for (contour.edges, 0..) |e, ei| {
            const sd = e.signedDistance(point);
            if (sd.lessThan(min_dist)) {
                min_dist = sd;
                closest_edge_idx = ei;
            }
        }

        const closest_edge = contour.edges[closest_edge_idx];
        const edge_start = closest_edge.startPoint();
        const edge_end = closest_edge.endPoint();

        const sign_str: []const u8 = if (min_dist.distance < 0) "inside" else "outside";
        std.debug.print("  Contour {}: closest edge {} ({d:.0},{d:.0})->({d:.0},{d:.0}), dist={d:.2} ({s})\n", .{
            ci, closest_edge_idx, edge_start.x, edge_start.y, edge_end.x, edge_end.y, min_dist.distance, sign_str,
        });
    }

    const winding = msdf.generate.computeWinding(shape, point);
    const winding_str: []const u8 = if (winding != 0) "inside" else "outside";
    std.debug.print("  WINDING: {} ({s})\n", .{ winding, winding_str });

    // Compare with a point we know is outside: (0, 0)
    std.debug.print("\n=== Comparing with (0, 0) ===\n", .{});
    const point2 = Vec2.init(0, 0);

    for (shape.contours, 0..) |contour, ci| {
        var min_dist = msdf.math.SignedDistance.infinite;
        var closest_edge_idx: usize = 0;

        for (contour.edges, 0..) |e, ei| {
            const sd = e.signedDistance(point2);
            if (sd.lessThan(min_dist)) {
                min_dist = sd;
                closest_edge_idx = ei;
            }
        }

        const closest_edge = contour.edges[closest_edge_idx];
        const edge_start = closest_edge.startPoint();
        const edge_end = closest_edge.endPoint();

        const sign_str: []const u8 = if (min_dist.distance < 0) "inside" else "outside";
        std.debug.print("  Contour {}: closest edge {} ({d:.0},{d:.0})->({d:.0},{d:.0}), dist={d:.2} ({s})\n", .{
            ci, closest_edge_idx, edge_start.x, edge_start.y, edge_end.x, edge_end.y, min_dist.distance, sign_str,
        });
    }

    const winding2 = msdf.generate.computeWinding(shape, point2);
    const winding2_str: []const u8 = if (winding2 != 0) "inside" else "outside";
    std.debug.print("  WINDING: {} ({s})\n", .{ winding2, winding2_str });
}

test "inspect edge types" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    const head_entry = font.findTable("head").?;
    const head = head_maxp.HeadTable.parse(font.data[head_entry.offset..][0..head_entry.length]) catch unreachable;

    const maxp_entry = font.findTable("maxp").?;
    const maxp = head_maxp.MaxpTable.parse(font.data[maxp_entry.offset..][0..maxp_entry.length]) catch unreachable;

    const cmap_entry = font.findTable("cmap").?;
    const cmap_table = cmap.CmapTable.parse(font.data, cmap_entry.offset) catch unreachable;

    const loca_entry = font.findTable("loca").?;
    const glyf_entry = font.findTable("glyf").?;

    const glyph_index = cmap_table.getGlyphIndex('O') catch unreachable;

    var shape = glyf.parseGlyph(
        allocator,
        font.data,
        loca_entry.offset,
        glyf_entry.offset,
        glyph_index,
        maxp.num_glyphs,
        head.usesLongLocaFormat(),
    ) catch unreachable;
    defer shape.deinit();

    std.debug.print("\n=== Edge Types in Contour 0 ===\n", .{});
    for (shape.contours[0].edges, 0..) |e, i| {
        const start = e.startPoint();
        const end_pt = e.endPoint();
        const edge_type: []const u8 = switch (e) {
            .linear => "linear",
            .quadratic => "quadratic",
            .cubic => "cubic",
        };
        const length = start.distance(end_pt);
        std.debug.print("  Edge {}: {s} ({d:.0},{d:.0}) -> ({d:.0},{d:.0}) len={d:.2}\n", .{
            i, edge_type, start.x, start.y, end_pt.x, end_pt.y, length,
        });
    }
}
