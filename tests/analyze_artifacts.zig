//! Detailed artifact analysis for debugging MSDF issues
const std = @import("std");
const msdf = @import("msdf");

fn median3(a: u8, b: u8, c: u8) u8 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

/// Analyze artifacts in an MSDF image at different sensitivity levels
fn analyzeArtifacts(pixels: []const u8, width: u32, height: u32) void {
    std.debug.print("\nDetailed artifact analysis:\n", .{});

    // Count artifacts at different spread thresholds
    const thresholds = [_]u8{ 200, 150, 100, 75, 50 };

    for (thresholds) |threshold| {
        var artifact_count: usize = 0;
        var boundary_count: usize = 0;

        var y: u32 = 1;
        while (y < height - 1) : (y += 1) {
            var x: u32 = 1;
            while (x < width - 1) : (x += 1) {
                const idx = (y * width + x) * 3;
                const r = pixels[idx];
                const g = pixels[idx + 1];
                const b = pixels[idx + 2];
                const m = median3(r, g, b);

                // Check boundary pixels
                if (m > 90 and m < 165) {
                    boundary_count += 1;

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

                    if ((inside_count == 1 or inside_count == 2) and spread > threshold) {
                        artifact_count += 1;
                    }
                }
            }
        }

        const artifact_rate = if (boundary_count > 0)
            @as(f64, @floatFromInt(artifact_count)) / @as(f64, @floatFromInt(boundary_count)) * 100.0
        else
            0.0;

        std.debug.print("  Spread > {d}: {d} artifacts in {d} boundary pixels ({d:.1}%)\n", .{
            threshold,
            artifact_count,
            boundary_count,
            artifact_rate,
        });
    }

    // Also analyze gradient discontinuities (another source of visible artifacts)
    var gradient_issues: usize = 0;
    var total_boundary: usize = 0;

    var y: u32 = 2;
    while (y < height - 2) : (y += 1) {
        var x: u32 = 2;
        while (x < width - 2) : (x += 1) {
            const idx = (y * width + x) * 3;
            const r = pixels[idx];
            const g = pixels[idx + 1];
            const b = pixels[idx + 2];
            const m = median3(r, g, b);

            if (m > 90 and m < 165) {
                total_boundary += 1;

                // Get 3x3 neighborhood medians
                var neighbors: [9]u8 = undefined;
                var ni: usize = 0;
                var dy: i32 = -1;
                while (dy <= 1) : (dy += 1) {
                    var dx: i32 = -1;
                    while (dx <= 1) : (dx += 1) {
                        const ny = @as(u32, @intCast(@as(i32, @intCast(y)) + dy));
                        const nx = @as(u32, @intCast(@as(i32, @intCast(x)) + dx));
                        const nidx = (ny * width + nx) * 3;
                        neighbors[ni] = median3(pixels[nidx], pixels[nidx + 1], pixels[nidx + 2]);
                        ni += 1;
                    }
                }

                // Check for large median jumps (gradient discontinuity)
                var max_jump: u8 = 0;
                for (neighbors) |n| {
                    const diff = if (n > m) n - m else m - n;
                    if (diff > max_jump) max_jump = diff;
                }

                // A jump > 60 in a 1-pixel neighborhood suggests a sharp discontinuity
                if (max_jump > 60) {
                    gradient_issues += 1;
                }
            }
        }
    }

    const gradient_rate = if (total_boundary > 0)
        @as(f64, @floatFromInt(gradient_issues)) / @as(f64, @floatFromInt(total_boundary)) * 100.0
    else
        0.0;

    std.debug.print("  Gradient discontinuities: {d} ({d:.1}% of boundary pixels)\n", .{
        gradient_issues,
        gradient_rate,
    });
}

test "analyze S artifacts" {
    const allocator = std.testing.allocator;

    var font = msdf.Font.fromFile(allocator, "/Users/mrphil/Fun/zig-msdf-examples/src/fonts/DejaVuSans.ttf") catch |err| {
        std.debug.print("Skipping test, font not found: {}\n", .{err});
        return;
    };
    defer font.deinit();

    std.debug.print("\n=== DejaVu Sans 'S' at 48px ===\n", .{});
    var result = try msdf.generateGlyph(allocator, font, 'S', .{
        .size = 48,
        .padding = 4,
        .range = 4.0,
    });
    defer result.deinit(allocator);

    analyzeArtifacts(result.pixels, result.width, result.height);

    // Also test at higher resolution
    std.debug.print("\n=== DejaVu Sans 'S' at 96px ===\n", .{});
    var result_96 = try msdf.generateGlyph(allocator, font, 'S', .{
        .size = 96,
        .padding = 8,
        .range = 8.0,
    });
    defer result_96.deinit(allocator);

    analyzeArtifacts(result_96.pixels, result_96.width, result_96.height);
}

test "analyze D artifacts" {
    const allocator = std.testing.allocator;

    var font = msdf.Font.fromFile(allocator, "/Users/mrphil/Fun/zig-msdf-examples/src/fonts/DejaVuSans.ttf") catch |err| {
        std.debug.print("Skipping test, font not found: {}\n", .{err});
        return;
    };
    defer font.deinit();

    std.debug.print("\n=== DejaVu Sans 'D' at 48px ===\n", .{});
    var result = try msdf.generateGlyph(allocator, font, 'D', .{
        .size = 48,
        .padding = 4,
        .range = 4.0,
    });
    defer result.deinit(allocator);

    analyzeArtifacts(result.pixels, result.width, result.height);
}
