//! Test MSDF generation with DejaVu Sans font
const std = @import("std");
const msdf = @import("msdf");

fn median3(a: u8, b: u8, c: u8) u8 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

fn computeArtifactFreeRate(pixels: []const u8, width: u32, height: u32) f64 {
    var artifact_free: usize = 0;
    var total_boundary_pixels: usize = 0;

    var y: u32 = 1;
    while (y < height - 1) : (y += 1) {
        var x: u32 = 1;
        while (x < width - 1) : (x += 1) {
            const idx = (y * width + x) * 3;
            const r = pixels[idx];
            const g = pixels[idx + 1];
            const b = pixels[idx + 2];
            const m = median3(r, g, b);

            if (m > 90 and m < 165) {
                total_boundary_pixels += 1;

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

                const is_artifact = (inside_count == 1 or inside_count == 2) and spread > 150;

                if (!is_artifact) {
                    artifact_free += 1;
                }
            }
        }
    }

    if (total_boundary_pixels == 0) return 1.0;
    return @as(f64, @floatFromInt(artifact_free)) / @as(f64, @floatFromInt(total_boundary_pixels));
}

test "DejaVu Sans S-curve quality" {
    const allocator = std.testing.allocator;

    var font = msdf.Font.fromFile(allocator, "/Users/mrphil/Fun/zig-msdf-examples/src/fonts/DejaVuSans.ttf") catch |err| {
        std.debug.print("Skipping test, font not found: {}\n", .{err});
        return;
    };
    defer font.deinit();

    // Test S character with same params as demo
    std.debug.print("\nDejaVu Sans (glyph_size=48, range=4.0):\n", .{});

    var result_s = try msdf.generateGlyph(allocator, font, 'S', .{
        .size = 48,
        .padding = 4,
        .range = 4.0,
    });
    defer result_s.deinit(allocator);

    // Save to PPM
    {
        const file = try std.fs.cwd().createFile("/tmp/dejavu_S_48.ppm", .{});
        defer file.close();

        var buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&buf, "P6\n{} {}\n255\n", .{ result_s.width, result_s.height });
        try file.writeAll(header);

        const pixel_count = @as(usize, result_s.width) * @as(usize, result_s.height);
        for (0..pixel_count) |i| {
            try file.writeAll(result_s.pixels[i * 3 .. i * 3 + 3]);
        }
    }

    var result_d = try msdf.generateGlyph(allocator, font, 'D', .{
        .size = 48,
        .padding = 4,
        .range = 4.0,
    });
    defer result_d.deinit(allocator);

    // Save D to PPM
    {
        const file = try std.fs.cwd().createFile("/tmp/dejavu_D_48.ppm", .{});
        defer file.close();

        var buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&buf, "P6\n{} {}\n255\n", .{ result_d.width, result_d.height });
        try file.writeAll(header);

        const pixel_count = @as(usize, result_d.width) * @as(usize, result_d.height);
        for (0..pixel_count) |i| {
            try file.writeAll(result_d.pixels[i * 3 .. i * 3 + 3]);
        }
    }

    const art_s = computeArtifactFreeRate(result_s.pixels, result_s.width, result_s.height);
    const art_d = computeArtifactFreeRate(result_d.pixels, result_d.width, result_d.height);
    std.debug.print("  'S' artifact-free: {d:.1}%\n", .{art_s * 100});
    std.debug.print("  'D' artifact-free: {d:.1}%\n", .{art_d * 100});
    std.debug.print("  Saved to /tmp/dejavu_S_48.ppm and /tmp/dejavu_D_48.ppm\n", .{});

    try std.testing.expect(art_s > 0.80);
    try std.testing.expect(art_d > 0.80);
}
