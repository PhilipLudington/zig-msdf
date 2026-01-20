const std = @import("std");
const msdf = @import("msdf");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, 'A', .{
        .size = 64,
        .range = 4.0,
        .msdfgen_autoframe = true,
    });
    defer result.deinit(allocator);

    std.debug.print("=== Geneva 'A' Artifact Analysis (64x64) ===\n\n", .{});
    std.debug.print("Dimensions: {d}x{d}\n\n", .{ result.width, result.height });

    // Look for potential artifacts:
    // 1. Pixels where median disagrees with neighbors (isolated artifacts)
    // 2. Pixels with extreme single-channel values that could cause issues
    // 3. Interior pixels that look like exterior (holes)

    std.debug.print("=== Potential artifacts (median contradicts neighbors) ===\n", .{});

    var artifact_count: u32 = 0;
    const w = result.width;
    const h = result.height;

    for (1..h - 1) |y_usize| {
        const y: u32 = @intCast(y_usize);
        for (1..w - 1) |x_usize| {
            const x: u32 = @intCast(x_usize);
            const idx = (y * w + x) * 3;

            const r = result.pixels[idx];
            const g = result.pixels[idx + 1];
            const b = result.pixels[idx + 2];
            const med = median3(r, g, b);
            const is_inside = med > 127;

            // Check 4 neighbors
            var neighbors_inside: u32 = 0;
            var neighbors_outside: u32 = 0;

            const neighbors = [_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
            for (neighbors) |n| {
                const nx: u32 = @intCast(@as(i32, @intCast(x)) + n[0]);
                const ny: u32 = @intCast(@as(i32, @intCast(y)) + n[1]);
                const nidx = (ny * w + nx) * 3;
                const nmed = median3(result.pixels[nidx], result.pixels[nidx + 1], result.pixels[nidx + 2]);
                if (nmed > 127) neighbors_inside += 1 else neighbors_outside += 1;
            }

            // Artifact: pixel disagrees with all 4 neighbors
            if ((is_inside and neighbors_inside == 0) or (!is_inside and neighbors_outside == 0)) {
                artifact_count += 1;
                std.debug.print("  ({d:2},{d:2}): med={d:3} ({s}) but ALL neighbors are {s}\n", .{
                    x,
                    y,
                    med,
                    if (is_inside) "inside" else "outside",
                    if (is_inside) "outside" else "inside",
                });
                std.debug.print("           RGB=({d:3},{d:3},{d:3})\n", .{ r, g, b });
            }
        }
    }

    if (artifact_count == 0) {
        std.debug.print("  No isolated artifacts found.\n", .{});
    }

    // Check for edge artifacts (single-channel extremes at boundary)
    std.debug.print("\n=== Edge pixels with extreme single-channel values ===\n", .{});
    var edge_artifact_count: u32 = 0;

    for (0..h) |y_usize| {
        const y: u32 = @intCast(y_usize);
        for (0..w) |x_usize| {
            const x: u32 = @intCast(x_usize);
            const idx = (y * w + x) * 3;

            const r = result.pixels[idx];
            const g = result.pixels[idx + 1];
            const b = result.pixels[idx + 2];
            const med = median3(r, g, b);

            // Look for boundary pixels (median near 127) with extreme channels
            if (med > 100 and med < 155) {
                const max_channel = @max(@max(r, g), b);
                const min_channel = @min(@min(r, g), b);
                const channel_spread = max_channel - min_channel;

                // Large spread indicates potential rendering issue
                if (channel_spread > 200) {
                    edge_artifact_count += 1;
                    if (edge_artifact_count <= 20) {
                        std.debug.print("  ({d:2},{d:2}): med={d:3} RGB=({d:3},{d:3},{d:3}) spread={d}\n", .{ x, y, med, r, g, b, channel_spread });
                    }
                }
            }
        }
    }

    std.debug.print("Total edge artifacts with >200 spread: {d}\n", .{edge_artifact_count});

    // Show the glyph structure visually
    std.debug.print("\n=== Glyph structure (median values) ===\n", .{});
    std.debug.print("Legend: # = inside (>127), . = boundary (100-155), space = outside\n\n", .{});

    for (0..h) |y_usize| {
        const y: u32 = @intCast(y_usize);
        for (0..w) |x_usize| {
            const x: u32 = @intCast(x_usize);
            const idx = (y * w + x) * 3;
            const med = median3(result.pixels[idx], result.pixels[idx + 1], result.pixels[idx + 2]);

            if (med > 155) {
                std.debug.print("#", .{});
            } else if (med > 100) {
                std.debug.print(".", .{});
            } else {
                std.debug.print(" ", .{});
            }
        }
        std.debug.print("\n", .{});
    }
}

fn median3(a: u8, b: u8, c: u8) u8 {
    return @max(@min(a, b), @min(@max(a, b), c));
}
