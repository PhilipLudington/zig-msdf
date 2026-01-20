const std = @import("std");
const msdf = @import("msdf");
const Vec2 = msdf.math.Vec2;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load both zig-msdf and msdfgen outputs
    const zig_data = std.fs.cwd().readFileAlloc(allocator, "/tmp/dollar_zig.ppm", 1024 * 1024) catch |err| {
        std.debug.print("Failed to read zig output: {}\n", .{err});
        std.debug.print("Run: zig build single-glyph -- /System/Library/Fonts/SFNSMono.ttf '$' /tmp/dollar_zig.ppm\n", .{});
        return;
    };
    defer allocator.free(zig_data);

    const msdf_data = std.fs.cwd().readFileAlloc(allocator, "/tmp/dollar_msdfgen.ppm", 1024 * 1024) catch |err| {
        std.debug.print("Failed to read msdfgen output: {}\n", .{err});
        std.debug.print("Run: cd ~/Fun/msdfgen/build && ./msdfgen msdf -font /System/Library/Fonts/SFNSMono.ttf 36 -dimensions 64 64 -pxrange 4 -autoframe -o /tmp/dollar_msdfgen.png && magick /tmp/dollar_msdfgen.png /tmp/dollar_msdfgen.ppm\n", .{});
        return;
    };
    defer allocator.free(msdf_data);

    // Skip PPM headers
    var zig_idx: usize = 0;
    var newlines: usize = 0;
    while (newlines < 3) : (zig_idx += 1) {
        if (zig_data[zig_idx] == '\n') newlines += 1;
    }
    const zig_pixels = zig_data[zig_idx..];

    var msdf_idx: usize = 0;
    newlines = 0;
    while (newlines < 3) : (msdf_idx += 1) {
        if (msdf_data[msdf_idx] == '\n') newlines += 1;
    }
    const msdf_pixels = msdf_data[msdf_idx..];

    const w: usize = 64;

    std.debug.print("=== SF Mono '$' Artifact Analysis ===\n\n", .{});

    // Find pixels where zig and msdfgen disagree significantly
    std.debug.print("Pixels with significant median difference (>30):\n", .{});
    var artifact_count: u32 = 0;

    for (0..64) |y| {
        for (0..64) |x| {
            const idx = (y * w + x) * 3;
            if (idx + 2 >= zig_pixels.len or idx + 2 >= msdf_pixels.len) continue;

            const zr = zig_pixels[idx];
            const zg = zig_pixels[idx + 1];
            const zb = zig_pixels[idx + 2];
            const z_med = median3(zr, zg, zb);

            const mr = msdf_pixels[idx];
            const mg = msdf_pixels[idx + 1];
            const mb = msdf_pixels[idx + 2];
            const m_med = median3(mr, mg, mb);

            const diff = if (z_med > m_med) z_med - m_med else m_med - z_med;

            // Check for inside/outside disagreement or large difference
            if (diff > 30 or ((z_med > 127) != (m_med > 127))) {
                std.debug.print("  ({d:2},{d:2}): zig=({d:3},{d:3},{d:3}) med={d:3}  msdf=({d:3},{d:3},{d:3}) med={d:3}  diff={d:3}", .{
                    x, y, zr, zg, zb, z_med, mr, mg, mb, m_med, diff,
                });
                if ((z_med > 127) != (m_med > 127)) {
                    std.debug.print(" <-- INSIDE/OUTSIDE DISAGREE\n", .{});
                } else {
                    std.debug.print("\n", .{});
                }
                artifact_count += 1;
            }
        }
    }

    std.debug.print("\nTotal artifact pixels: {d}\n", .{artifact_count});

    // Count inside/outside disagreements
    var disagree_count: u32 = 0;
    for (0..64 * 64) |i| {
        const idx = i * 3;
        if (idx + 2 >= zig_pixels.len or idx + 2 >= msdf_pixels.len) continue;
        const z_med = median3(zig_pixels[idx], zig_pixels[idx + 1], zig_pixels[idx + 2]);
        const m_med = median3(msdf_pixels[idx], msdf_pixels[idx + 1], msdf_pixels[idx + 2]);
        if ((z_med > 127) != (m_med > 127)) {
            disagree_count += 1;
        }
    }
    std.debug.print("Inside/outside disagreements: {d}\n", .{disagree_count});
}

fn median3(a: u8, b: u8, c: u8) u8 {
    return @max(@min(a, b), @min(@max(a, b), c));
}
