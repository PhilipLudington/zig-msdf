//! Diagnostic tool for investigating curve artifacts.
//!
//! This tool generates detailed analysis of where artifacts occur
//! in relation to segment boundaries.

const std = @import("std");
const msdf = @import("msdf");

const Vec2 = msdf.math.Vec2;
const SignedDistance = msdf.math.SignedDistance;
const EdgeSegment = msdf.edge.EdgeSegment;
const Shape = msdf.contour.Shape;
const Transform = msdf.generate.Transform;

fn median3(a: u8, b: u8, c: u8) u8 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

/// Parse glyph shape from font (replicating what generateGlyph does internally)
fn parseGlyphShape(allocator: std.mem.Allocator, font: msdf.Font, codepoint: u21) !Shape {
    // Parse required tables
    const head_data = font.getTableData("head") orelse return error.MissingTable;
    const head = try msdf.head_maxp.HeadTable.parse(head_data);

    const maxp_data = font.getTableData("maxp") orelse return error.MissingTable;
    const maxp = try msdf.head_maxp.MaxpTable.parse(maxp_data);

    const cmap_table_offset = font.findTable("cmap").?.offset;
    const cmap_table = try msdf.cmap.CmapTable.parse(font.data, cmap_table_offset);

    // Look up glyph index from codepoint
    const glyph_index = try cmap_table.getGlyphIndex(codepoint);

    // Parse glyph outline
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

/// Analyze artifacts in a generated glyph
fn analyzeArtifacts(
    pixels: []const u8,
    width: u32,
    height: u32,
    shape: Shape,
    transform: Transform,
) !void {
    std.debug.print("\n=== Artifact Analysis ===\n", .{});

    var artifact_count: usize = 0;
    var total_boundary: usize = 0;
    var endpoint_artifacts: usize = 0;

    // Find all artifact pixels and analyze their relationship to segment boundaries
    var y: u32 = 1;
    while (y < height - 1) : (y += 1) {
        var x: u32 = 1;
        while (x < width - 1) : (x += 1) {
            const idx = (y * width + x) * 3;
            const r = pixels[idx];
            const g = pixels[idx + 1];
            const b = pixels[idx + 2];
            const med = median3(r, g, b);

            // Check boundary pixels
            if (med > 90 and med < 165) {
                total_boundary += 1;

                // Artifact detection
                const r_inside = r > 127;
                const g_inside = g > 127;
                const b_inside = b > 127;

                var inside_count: u8 = 0;
                if (r_inside) inside_count += 1;
                if (g_inside) inside_count += 1;
                if (b_inside) inside_count += 1;

                const max_channel = @max(r, @max(g, b));
                const min_channel = @min(r, @min(g, b));
                const spread = max_channel - min_channel;

                const is_artifact = (inside_count == 1 or inside_count == 2) and spread > 100;

                if (is_artifact) {
                    artifact_count += 1;

                    // Analyze this artifact's relationship to segments
                    const point = transform.pixelToShape(@floatFromInt(x), @floatFromInt(height - 1 - y));

                    // Find closest segment and check if we're near an endpoint
                    var closest_dist: f64 = std.math.inf(f64);
                    var closest_t: f64 = 0;
                    var segment_idx: usize = 0;
                    var closest_color: msdf.edge.EdgeColor = .white;

                    var seg_num: usize = 0;
                    for (shape.contours) |contour| {
                        for (contour.edges) |e| {
                            const sd = e.signedDistance(point);
                            const abs_dist = @abs(sd.distance);

                            if (abs_dist < closest_dist) {
                                closest_dist = abs_dist;
                                segment_idx = seg_num;
                                closest_color = e.getColor();

                                // Find the parameter t
                                closest_t = findClosestT(e, point);
                            }
                            seg_num += 1;
                        }
                    }

                    const closest_is_endpoint = closest_t < 0.02 or closest_t > 0.98;
                    const color_str = switch (closest_color) {
                        .black => "K",
                        .cyan => "C",
                        .magenta => "M",
                        .yellow => "Y",
                        .white => "W",
                    };
                    if (closest_is_endpoint) {
                        endpoint_artifacts += 1;
                    }

                    if (artifact_count <= 10) {
                        // Get actual distance values from each channel
                        var red_min = SignedDistance.infinite;
                        var green_min = SignedDistance.infinite;
                        var blue_min = SignedDistance.infinite;

                        for (shape.contours) |contour| {
                            for (contour.edges) |e| {
                                const sd = e.signedDistance(point);
                                const color = e.getColor();

                                if (color.hasRed() and sd.lessThan(red_min)) red_min = sd;
                                if (color.hasGreen() and sd.lessThan(green_min)) green_min = sd;
                                if (color.hasBlue() and sd.lessThan(blue_min)) blue_min = sd;
                            }
                        }

                        std.debug.print("Artifact ({d},{d}): RGB={d},{d},{d} seg={d}({s}) t={d:.2}\n", .{
                            x, y, r, g, b, segment_idx, color_str, closest_t,
                        });
                        std.debug.print("  Distances: R={d:.2}, G={d:.2}, B={d:.2}\n", .{
                            red_min.distance, green_min.distance, blue_min.distance,
                        });
                    }
                }
            }
        }
    }

    std.debug.print("\nTotal boundary pixels: {d}\n", .{total_boundary});
    std.debug.print("Artifact pixels: {d} ({d:.1}%)\n", .{ artifact_count, @as(f64, @floatFromInt(artifact_count)) / @as(f64, @floatFromInt(total_boundary)) * 100 });
    if (artifact_count > 0) {
        std.debug.print("Artifacts near endpoints: {d} ({d:.1}%)\n", .{ endpoint_artifacts, @as(f64, @floatFromInt(endpoint_artifacts)) / @as(f64, @floatFromInt(artifact_count)) * 100 });
    }
}

/// Find the parameter t for the closest point on an edge to a given point
fn findClosestT(edge: EdgeSegment, point: Vec2) f64 {
    // Sample along the edge to find approximate closest point
    var best_t: f64 = 0;
    var best_dist: f64 = std.math.inf(f64);

    const samples = 100;
    var i: usize = 0;
    while (i <= samples) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, samples);
        const p = edge.point(t);
        const dist = point.distanceSquared(p);
        if (dist < best_dist) {
            best_dist = dist;
            best_t = t;
        }
    }

    return best_t;
}

/// Analyze sign consistency at segment boundaries
fn analyzeSignConsistency(
    shape: Shape,
    transform: Transform,
    width: u32,
    height: u32,
) !void {
    std.debug.print("\n=== Sign Consistency at Segment Boundaries ===\n", .{});

    var total_junctions: usize = 0;
    var problematic_junctions: usize = 0;

    // For each segment boundary, sample a few pixels near it
    for (shape.contours) |contour| {
        const edge_count = contour.edges.len;
        if (edge_count < 2) continue;

        for (0..edge_count) |i| {
            const curr_edge = contour.edges[i];
            const next_idx = (i + 1) % edge_count;
            const next_edge = contour.edges[next_idx];

            // Get the junction point
            const junction = curr_edge.endPoint();
            const pixel_pos = transform.shapeToPixel(junction);

            // Check if junction is within image bounds
            if (pixel_pos.x < 0 or pixel_pos.x >= @as(f64, @floatFromInt(width)) or
                pixel_pos.y < 0 or pixel_pos.y >= @as(f64, @floatFromInt(height)))
            {
                continue;
            }

            total_junctions += 1;

            // Sample a few points near the junction
            const offsets = [_][2]f64{ .{ 0.5, 0 }, .{ -0.5, 0 }, .{ 0, 0.5 }, .{ 0, -0.5 } };

            var sign_flips: usize = 0;
            for (offsets) |offset| {
                const sample_point = Vec2.init(
                    junction.x + offset[0] / transform.scale,
                    junction.y + offset[1] / transform.scale,
                );

                const curr_sd = curr_edge.signedDistance(sample_point);
                const next_sd = next_edge.signedDistance(sample_point);

                // Check if signs differ for the same point
                const curr_sign = curr_sd.distance < 0;
                const next_sign = next_sd.distance < 0;

                // Also check which segment "wins"
                const curr_abs = @abs(curr_sd.distance);
                const next_abs = @abs(next_sd.distance);

                if (curr_abs < 0.5 and next_abs < 0.5 and curr_sign != next_sign) {
                    sign_flips += 1;
                }
            }

            if (sign_flips > 0) {
                problematic_junctions += 1;
                if (problematic_junctions <= 5) {
                    std.debug.print("Junction {d}: sign inconsistency ({d}/4 samples)\n", .{ i, sign_flips });
                }
            }
        }
    }

    std.debug.print("\nTotal junctions analyzed: {d}\n", .{total_junctions});
    std.debug.print("Problematic junctions: {d} ({d:.1}%)\n", .{ problematic_junctions, if (total_junctions > 0) @as(f64, @floatFromInt(problematic_junctions)) / @as(f64, @floatFromInt(total_junctions)) * 100 else 0.0 });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test with 'S' character which has known artifacts
    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    const test_chars = [_]u8{ 'S', 'D', '2', '3' };

    for (test_chars) |ch| {
        std.debug.print("\n\n========== Character '{c}' ==========\n", .{ch});

        var result = try msdf.generateGlyph(allocator, font, ch, .{
            .size = 64,
            .padding = 4,
            .range = 4.0,
        });
        defer result.deinit(allocator);

        // Get shape info for analysis (before coloring)
        var shape = parseGlyphShape(allocator, font, ch) catch |err| {
            std.debug.print("Failed to parse shape: {}\n", .{err});
            continue;
        };
        defer shape.deinit();

        // Apply coloring like generateGlyph does
        msdf.coloring.colorEdgesSimple(&shape);

        // Calculate transform (same as generateGlyph)
        const bounds = shape.bounds();
        const transform = msdf.generate.calculateTransform(bounds, result.width, result.height, 4);

        // Debug: print edge colors
        std.debug.print("\n=== Edge Colors ===\n", .{});
        var seg_idx: usize = 0;
        for (shape.contours, 0..) |contour, c_idx| {
            std.debug.print("Contour {d}: {d} edges\n", .{ c_idx, contour.edges.len });
            for (contour.edges, 0..) |e, e_idx| {
                const color = e.getColor();
                const color_str = switch (color) {
                    .black => "black",
                    .cyan => "cyan",
                    .magenta => "magenta",
                    .yellow => "yellow",
                    .white => "white",
                };
                const edge_type = switch (e) {
                    .linear => "L",
                    .quadratic => "Q",
                    .cubic => "C",
                };
                std.debug.print("  seg {d} (edge {d}): {s} {s}\n", .{ seg_idx, e_idx, edge_type, color_str });
                seg_idx += 1;
            }
        }

        try analyzeArtifacts(result.pixels, result.width, result.height, shape, transform);
        try analyzeSignConsistency(shape, transform, result.width, result.height);
    }
}

test "artifact diagnostic runs" {
    // This test just verifies the diagnostic compiles and runs
    const allocator = std.testing.allocator;

    var font = msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf") catch return;
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, 'S', .{
        .size = 64,
        .padding = 4,
        .range = 4.0,
    });
    defer result.deinit(allocator);
}
