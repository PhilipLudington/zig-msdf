const std = @import("std");
const msdf = @import("msdf");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/SFNSMono.ttf");
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, 'A', .{
        .size = 64,
        .range = 4.0,
        .msdfgen_autoframe = true,
    });
    defer result.deinit(allocator);

    const w = result.width;
    const h = result.height;

    std.debug.print("=== SF Mono 'A' Artifact Analysis ===\n\n", .{});

    // Focus on the crossbar region (roughly middle of glyph)
    // The crossbar should be around y = 35-45 based on the image
    std.debug.print("=== Crossbar region analysis (y=30-50) ===\n", .{});
    std.debug.print("Looking for artifacts at crossbar/leg junction\n\n", .{});

    // Show rendered structure in crossbar area
    std.debug.print("Rendered structure (median values):\n", .{});
    std.debug.print("Legend: @ = inside (>180), # = mostly inside (140-180), . = edge (100-140), - = near edge (60-100), space = outside\n\n", .{});

    for (25..55) |y| {
        std.debug.print("y={d:2}: ", .{y});
        for (0..w) |x| {
            const idx = (y * w + x) * 3;
            const r = result.pixels[idx];
            const g = result.pixels[idx + 1];
            const b = result.pixels[idx + 2];
            const med = median3(r, g, b);

            if (med > 180) {
                std.debug.print("@", .{});
            } else if (med > 140) {
                std.debug.print("#", .{});
            } else if (med > 100) {
                std.debug.print(".", .{});
            } else if (med > 60) {
                std.debug.print("-", .{});
            } else {
                std.debug.print(" ", .{});
            }
        }
        std.debug.print("\n", .{});
    }

    // Find isolated artifacts (pixels that disagree with majority of neighbors)
    std.debug.print("\n=== Isolated artifacts in crossbar region ===\n", .{});
    var artifact_count: u32 = 0;

    for (25..55) |y_usize| {
        const y: u32 = @intCast(y_usize);
        for (1..w - 1) |x_usize| {
            const x: u32 = @intCast(x_usize);
            const idx = (y * w + x) * 3;
            const med = median3(result.pixels[idx], result.pixels[idx + 1], result.pixels[idx + 2]);
            const is_inside = med > 127;

            // Check 8 neighbors
            var neighbors_inside: u32 = 0;
            var neighbors_outside: u32 = 0;

            const offsets = [_][2]i32{
                .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
                .{ -1, 0 },              .{ 1, 0 },
                .{ -1, 1 },  .{ 0, 1 },  .{ 1, 1 },
            };

            for (offsets) |off| {
                const nx = @as(i32, @intCast(x)) + off[0];
                const ny = @as(i32, @intCast(y)) + off[1];
                if (nx >= 0 and nx < w and ny >= 0 and ny < h) {
                    const nidx: usize = @intCast(@as(i32, @intCast(ny)) * @as(i32, @intCast(w)) + nx);
                    const nmed = median3(result.pixels[nidx * 3], result.pixels[nidx * 3 + 1], result.pixels[nidx * 3 + 2]);
                    if (nmed > 127) neighbors_inside += 1 else neighbors_outside += 1;
                }
            }

            // Artifact: pixel disagrees with 6+ neighbors
            const disagree_count = if (is_inside) neighbors_outside else neighbors_inside;
            if (disagree_count >= 6) {
                artifact_count += 1;
                std.debug.print("  ARTIFACT at ({d},{d}): med={d} ({s}), {d}/8 neighbors disagree\n", .{
                    x,
                    y,
                    med,
                    if (is_inside) "inside" else "outside",
                    disagree_count,
                });
                std.debug.print("    RGB=({d},{d},{d})\n", .{
                    result.pixels[idx],
                    result.pixels[idx + 1],
                    result.pixels[idx + 2],
                });
            }
        }
    }

    if (artifact_count == 0) {
        std.debug.print("  No isolated artifacts found in crossbar region.\n", .{});
    } else {
        std.debug.print("\n  Total artifacts: {d}\n", .{artifact_count});
    }

    // Write rendered image
    const rendered = try allocator.alloc(u8, w * h);
    defer allocator.free(rendered);

    for (0..h) |y| {
        for (0..w) |x| {
            const idx = (y * w + x) * 3;
            rendered[y * w + x] = median3(result.pixels[idx], result.pixels[idx + 1], result.pixels[idx + 2]);
        }
    }

    const file = try std.fs.cwd().createFile("sfmono_A_rendered.pgm", .{});
    defer file.close();
    var buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&buf, "P5\n{d} {d}\n255\n", .{ w, h });
    try file.writeAll(header);
    try file.writeAll(rendered);

    std.debug.print("\nWritten to sfmono_A_rendered.pgm\n", .{});
}

fn median3(a: u8, b: u8, c: u8) u8 {
    return @max(@min(a, b), @min(@max(a, b), c));
}
