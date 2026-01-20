const std = @import("std");
const msdf = @import("msdf");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load msdfgen reference
    const msdf_data = std.fs.cwd().readFileAlloc(allocator, "/tmp/msdfgen_sfmono_A.ppm", 1024 * 1024) catch |err| {
        std.debug.print("Failed to read msdfgen output: {}\n", .{err});
        std.debug.print("Run: cd ~/Fun/msdfgen/build && ./msdfgen msdf -font /System/Library/Fonts/SFNSMono.ttf 65 -dimensions 64 64 -pxrange 4 -autoframe -o /tmp/msdfgen_sfmono_A.png && magick /tmp/msdfgen_sfmono_A.png /tmp/msdfgen_sfmono_A.ppm\n", .{});
        return;
    };
    defer allocator.free(msdf_data);

    // Skip PPM header
    var msdf_idx: usize = 0;
    var newlines: usize = 0;
    while (newlines < 3) : (msdf_idx += 1) {
        if (msdf_data[msdf_idx] == '\n') newlines += 1;
    }
    const msdf_pixels = msdf_data[msdf_idx..];

    // Generate zig-msdf
    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/SFNSMono.ttf");
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, 'A', .{
        .size = 64,
        .range = 4.0,
        .msdfgen_autoframe = true,
    });
    defer result.deinit(allocator);

    const w: usize = result.width;

    std.debug.print("=== SF Mono 'A' Comparison at artifact locations ===\n\n", .{});

    // Check specific artifact locations
    const artifact_locs = [_][2]u32{
        .{ 21, 39 }, .{ 21, 40 }, .{ 21, 41 },
        .{ 20, 42 }, .{ 20, 43 }, .{ 43, 43 },
    };

    for (artifact_locs) |loc| {
        const x = loc[0];
        const y = loc[1];
        const idx = (y * w + x) * 3;

        const zr = result.pixels[idx];
        const zg = result.pixels[idx + 1];
        const zb = result.pixels[idx + 2];
        const z_med = median3(zr, zg, zb);

        const mr = msdf_pixels[idx];
        const mg = msdf_pixels[idx + 1];
        const mb = msdf_pixels[idx + 2];
        const m_med = median3(mr, mg, mb);

        std.debug.print("({d:2},{d:2}): zig=({d:3},{d:3},{d:3}) med={d:3}  msdf=({d:3},{d:3},{d:3}) med={d:3}", .{
            x, y, zr, zg, zb, z_med, mr, mg, mb, m_med,
        });

        if ((z_med > 127) != (m_med > 127)) {
            std.debug.print("  <-- DISAGREE!\n", .{});
        } else {
            std.debug.print("\n", .{});
        }
    }

    // Count total disagreements
    std.debug.print("\n=== Full comparison ===\n", .{});
    var disagree_count: u32 = 0;
    var total_diff: u64 = 0;

    for (0..64 * 64) |i| {
        const idx = i * 3;
        const z_med = median3(result.pixels[idx], result.pixels[idx + 1], result.pixels[idx + 2]);
        const m_med = median3(msdf_pixels[idx], msdf_pixels[idx + 1], msdf_pixels[idx + 2]);

        if ((z_med > 127) != (m_med > 127)) {
            disagree_count += 1;
        }

        const diff = if (z_med > m_med) z_med - m_med else m_med - z_med;
        total_diff += diff;
    }

    const mae = @as(f64, @floatFromInt(total_diff)) / (64 * 64);
    const agree_pct = @as(f64, @floatFromInt(64 * 64 - disagree_count)) / (64 * 64) * 100;

    std.debug.print("Inside/outside disagreements: {d}\n", .{disagree_count});
    std.debug.print("Agreement rate: {d:.1}%\n", .{agree_pct});
    std.debug.print("Mean Absolute Error (median): {d:.2}\n", .{mae});
}

fn median3(a: u8, b: u8, c: u8) u8 {
    return @max(@min(a, b), @min(@max(a, b), c));
}
