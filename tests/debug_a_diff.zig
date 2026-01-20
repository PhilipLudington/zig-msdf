const std = @import("std");
const msdf = @import("msdf");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load reference image
    const ref = try loadReferenceRgba(allocator, "tests/fixtures/reference/geneva_65.rgba");
    defer allocator.free(ref.pixels);

    // Load font and generate MSDF with autoframe
    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, 'A', .{
        .size = 32,
        .range = 4.0,
        .msdfgen_autoframe = true,
    });
    defer result.deinit(allocator);

    std.debug.print("=== Geneva 'A' Comparison Analysis ===\n\n", .{});
    std.debug.print("Dimensions: {d}x{d}\n\n", .{ result.width, result.height });

    // Categorize differences
    var exact_matches: u32 = 0;
    var close_matches: u32 = 0; // within ±10
    var medium_diff: u32 = 0; // within ±32
    var large_diff: u32 = 0; // >32

    var edge_pixel_diffs: u32 = 0;
    var interior_diffs: u32 = 0;
    var exterior_diffs: u32 = 0;

    const pixel_count = @as(usize, result.width) * @as(usize, result.height);

    for (0..pixel_count) |i| {
        const idx = i * 3;
        const x = @as(u32, @intCast(i % result.width));
        const y = @as(u32, @intCast(i / result.width));

        const zr = result.pixels[idx];
        const zg = result.pixels[idx + 1];
        const zb = result.pixels[idx + 2];
        const z_med = median3(zr, zg, zb);

        const mr = ref.pixels[idx];
        const mg = ref.pixels[idx + 1];
        const mb = ref.pixels[idx + 2];
        const m_med = median3(mr, mg, mb);

        const dr = if (zr > mr) zr - mr else mr - zr;
        const dg = if (zg > mg) zg - mg else mg - zg;
        const db = if (zb > mb) zb - mb else mb - zb;
        const max_diff = @max(@max(dr, dg), db);

        if (max_diff == 0) {
            exact_matches += 1;
        } else if (max_diff <= 10) {
            close_matches += 1;
        } else if (max_diff <= 32) {
            medium_diff += 1;
        } else {
            large_diff += 1;

            // Classify by region
            const is_edge = (z_med > 100 and z_med < 155) or (m_med > 100 and m_med < 155);
            const z_inside = z_med > 127;
            const m_inside = m_med > 127;

            if (is_edge) {
                edge_pixel_diffs += 1;
            } else if (z_inside or m_inside) {
                interior_diffs += 1;
            } else {
                exterior_diffs += 1;
            }

            // Print large differences (first 30)
            if (large_diff <= 30) {
                std.debug.print("({d:2},{d:2}): zig=({d:3},{d:3},{d:3}) med={d:3}  ref=({d:3},{d:3},{d:3}) med={d:3}  diff={d}\n", .{
                    x,                    y,
                    zr,                   zg,
                    zb,                   z_med,
                    mr,                   mg,
                    mb,                   m_med,
                    max_diff,
                });
            }
        }
    }

    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Total pixels: {d}\n", .{pixel_count});
    std.debug.print("Exact matches: {d} ({d:.1}%)\n", .{ exact_matches, @as(f64, @floatFromInt(exact_matches)) / @as(f64, @floatFromInt(pixel_count)) * 100 });
    std.debug.print("Close (±10): {d} ({d:.1}%)\n", .{ close_matches, @as(f64, @floatFromInt(close_matches)) / @as(f64, @floatFromInt(pixel_count)) * 100 });
    std.debug.print("Medium (±32): {d} ({d:.1}%)\n", .{ medium_diff, @as(f64, @floatFromInt(medium_diff)) / @as(f64, @floatFromInt(pixel_count)) * 100 });
    std.debug.print("Large (>32): {d} ({d:.1}%)\n", .{ large_diff, @as(f64, @floatFromInt(large_diff)) / @as(f64, @floatFromInt(pixel_count)) * 100 });

    std.debug.print("\n=== Large diff breakdown ===\n", .{});
    std.debug.print("Edge pixels: {d}\n", .{edge_pixel_diffs});
    std.debug.print("Interior: {d}\n", .{interior_diffs});
    std.debug.print("Exterior: {d}\n", .{exterior_diffs});

    const cumulative_match = exact_matches + close_matches + medium_diff;
    std.debug.print("\nMatch rate (±32): {d:.1}%\n", .{
        @as(f64, @floatFromInt(cumulative_match)) / @as(f64, @floatFromInt(pixel_count)) * 100,
    });

    // Compare medians specifically
    std.debug.print("\n=== Median comparison (what actually renders) ===\n", .{});
    var median_exact_match: u32 = 0;
    var median_close_match: u32 = 0;
    var median_mismatch: u32 = 0;

    for (0..pixel_count) |i| {
        const idx = i * 3;
        const z_med = median3(result.pixels[idx], result.pixels[idx + 1], result.pixels[idx + 2]);
        const m_med = median3(ref.pixels[idx], ref.pixels[idx + 1], ref.pixels[idx + 2]);

        const diff = if (z_med > m_med) z_med - m_med else m_med - z_med;
        if (diff == 0) {
            median_exact_match += 1;
        } else if (diff <= 5) {
            median_close_match += 1;
        } else {
            median_mismatch += 1;
        }
    }

    std.debug.print("Median exact match: {d} ({d:.1}%)\n", .{
        median_exact_match,
        @as(f64, @floatFromInt(median_exact_match)) / @as(f64, @floatFromInt(pixel_count)) * 100,
    });
    std.debug.print("Median close (±5): {d} ({d:.1}%)\n", .{
        median_close_match,
        @as(f64, @floatFromInt(median_close_match)) / @as(f64, @floatFromInt(pixel_count)) * 100,
    });
    std.debug.print("Median mismatch: {d} ({d:.1}%)\n", .{
        median_mismatch,
        @as(f64, @floatFromInt(median_mismatch)) / @as(f64, @floatFromInt(pixel_count)) * 100,
    });
    std.debug.print("\nTotal median match rate: {d:.1}%\n", .{
        @as(f64, @floatFromInt(median_exact_match + median_close_match)) / @as(f64, @floatFromInt(pixel_count)) * 100,
    });
}

fn median3(a: u8, b: u8, c: u8) u8 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

const ReferenceImage = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

fn loadReferenceRgba(allocator: std.mem.Allocator, path: []const u8) !ReferenceImage {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    errdefer allocator.free(data);

    if (data.len < 12) return error.InvalidFormat;

    // Check magic
    if (!std.mem.eql(u8, data[0..4], "RGBA")) return error.InvalidFormat;

    // Read dimensions (big-endian as per reference_test.zig)
    const width = std.mem.readInt(u32, data[4..8], .big);
    const height = std.mem.readInt(u32, data[8..12], .big);

    const expected_size: usize = 12 + @as(usize, width) * @as(usize, height) * 4;
    if (data.len < expected_size) return error.InvalidFormat;

    // Extract RGB from RGBA (skip alpha channel)
    const pixel_count = @as(usize, width) * @as(usize, height);
    const rgb_data = try allocator.alloc(u8, pixel_count * 3);
    errdefer allocator.free(rgb_data);

    for (0..pixel_count) |i| {
        const src_idx = 12 + i * 4;
        const dst_idx = i * 3;
        rgb_data[dst_idx] = data[src_idx]; // R
        rgb_data[dst_idx + 1] = data[src_idx + 1]; // G
        rgb_data[dst_idx + 2] = data[src_idx + 2]; // B
    }

    allocator.free(data);

    return ReferenceImage{
        .width = width,
        .height = height,
        .pixels = rgb_data,
    };
}
