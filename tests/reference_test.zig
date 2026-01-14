//! Reference comparison tests for zig-msdf.
//!
//! These tests compare generated MSDF output against reference images generated
//! by msdfgen (the canonical C++ implementation by Viktor Chlumsky).
//!
//! To regenerate reference images:
//!   msdfgen msdf -font "/System/Library/Fonts/Geneva.ttf" 65 \
//!       -dimensions 32 32 -pxrange 4 -autoframe -legacyfontscaling \
//!       -format rgba -o tests/fixtures/reference/geneva_65.rgba

const std = @import("std");
const msdf = @import("msdf");

const Vec2 = msdf.math.Vec2;

/// Load reference RGBA data from msdfgen output format.
/// Format: "RGBA" magic + 4-byte width + 4-byte height + RGBA pixels
fn loadReferenceRgba(allocator: std.mem.Allocator, path: []const u8) !struct {
    pixels: []u8,
    width: u32,
    height: u32,
} {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    errdefer allocator.free(data);

    if (data.len < 12) return error.InvalidFormat;

    // Check magic
    if (!std.mem.eql(u8, data[0..4], "RGBA")) return error.InvalidFormat;

    // Read dimensions (big-endian)
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
        // Skip alpha (data[src_idx + 3])
    }

    allocator.free(data);

    return .{
        .pixels = rgb_data,
        .width = width,
        .height = height,
    };
}

/// Compute Mean Absolute Error between two images.
/// Returns average absolute difference per channel per pixel.
fn computeMAE(img1: []const u8, img2: []const u8) f64 {
    if (img1.len != img2.len or img1.len == 0) return std.math.inf(f64);

    var total_diff: u64 = 0;
    for (img1, img2) |a, b| {
        total_diff += if (a > b) a - b else b - a;
    }

    return @as(f64, @floatFromInt(total_diff)) / @as(f64, @floatFromInt(img1.len));
}

/// Compute percentage of pixels within a tolerance threshold.
fn computeMatchRate(img1: []const u8, img2: []const u8, tolerance: u8) f64 {
    if (img1.len != img2.len or img1.len == 0) return 0.0;

    var matches: usize = 0;
    for (img1, img2) |a, b| {
        const diff = if (a > b) a - b else b - a;
        if (diff <= tolerance) matches += 1;
    }

    return @as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(img1.len));
}

/// Compute structural similarity by checking inside/outside agreement.
/// Returns percentage of pixels that agree on inside (>127) vs outside (<=127).
fn computeInsideOutsideAgreement(img1: []const u8, img2: []const u8) f64 {
    if (img1.len != img2.len or img1.len == 0) return 0.0;

    // Only check one channel (R) for inside/outside determination
    var agreements: usize = 0;
    var total: usize = 0;

    var i: usize = 0;
    while (i < img1.len) : (i += 3) {
        // Use median of RGB channels for comparison
        const m1 = median3(img1[i], img1[i + 1], img1[i + 2]);
        const m2 = median3(img2[i], img2[i + 1], img2[i + 2]);

        const inside1 = m1 > 127;
        const inside2 = m2 > 127;

        if (inside1 == inside2) agreements += 1;
        total += 1;
    }

    return @as(f64, @floatFromInt(agreements)) / @as(f64, @floatFromInt(total));
}

fn median3(a: u8, b: u8, c: u8) u8 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

// ============================================================================
// Reference Comparison Tests
// ============================================================================

test "compare against msdfgen reference - Geneva A" {
    const allocator = std.testing.allocator;

    // Load reference image
    const ref = loadReferenceRgba(allocator, "tests/fixtures/reference/geneva_65.rgba") catch |err| {
        // Skip test if reference file not found
        if (err == error.FileNotFound) {
            std.debug.print("Reference file not found, skipping test\n", .{});
            return;
        }
        return err;
    };
    defer allocator.free(ref.pixels);

    // Load font and generate MSDF
    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, 'A', .{
        .size = 32,
        .padding = 2, // msdfgen autoframe uses minimal padding
        .range = 4.0,
    });
    defer result.deinit(allocator);

    // Verify dimensions match
    try std.testing.expectEqual(ref.width, result.width);
    try std.testing.expectEqual(ref.height, result.height);

    // Compute similarity metrics
    const mae = computeMAE(ref.pixels, result.pixels);
    const match_rate = computeMatchRate(ref.pixels, result.pixels, 32); // 32/255 tolerance
    const io_agreement = computeInsideOutsideAgreement(ref.pixels, result.pixels);

    std.debug.print("\nComparison metrics for Geneva 'A':\n", .{});
    std.debug.print("  Mean Absolute Error: {d:.2}\n", .{mae});
    std.debug.print("  Match rate (±32): {d:.1}%\n", .{match_rate * 100});
    std.debug.print("  Inside/outside agreement: {d:.1}%\n", .{io_agreement * 100});

    // Inside/outside agreement should be high (shapes match)
    // This is the most important metric - it verifies the shape is correct
    try std.testing.expect(io_agreement > 0.95);

    // Note: Match rate may be lower (~40-50%) due to different edge coloring
    // algorithms. This is acceptable as long as inside/outside agreement is high.
    // The MSDF will still render correctly with different colorings.
    try std.testing.expect(match_rate > 0.35);
}

test "structural comparison - shape boundaries match" {
    const allocator = std.testing.allocator;

    const ref = loadReferenceRgba(allocator, "tests/fixtures/reference/geneva_65.rgba") catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(ref.pixels);

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, 'A', .{
        .size = 32,
        .padding = 2,
        .range = 4.0,
    });
    defer result.deinit(allocator);

    // Check that boundary pixels (near 127) are in similar locations
    var boundary_agreement: usize = 0;
    var boundary_total: usize = 0;

    const pixel_count = @as(usize, ref.width) * @as(usize, ref.height);
    for (0..pixel_count) |i| {
        const idx = i * 3;
        const ref_median = median3(ref.pixels[idx], ref.pixels[idx + 1], ref.pixels[idx + 2]);
        const our_median = median3(result.pixels[idx], result.pixels[idx + 1], result.pixels[idx + 2]);

        // Check if ref pixel is near boundary (100-155 range)
        if (ref_median > 100 and ref_median < 155) {
            boundary_total += 1;
            // Our pixel should also be near boundary
            if (our_median > 80 and our_median < 175) {
                boundary_agreement += 1;
            }
        }
    }

    if (boundary_total > 0) {
        const boundary_match_rate = @as(f64, @floatFromInt(boundary_agreement)) / @as(f64, @floatFromInt(boundary_total));
        std.debug.print("\nBoundary agreement: {d:.1}% ({d}/{d} pixels)\n", .{
            boundary_match_rate * 100,
            boundary_agreement,
            boundary_total,
        });

        // Boundary pixels should mostly agree
        try std.testing.expect(boundary_match_rate > 0.7);
    }
}

test "multiple characters consistency" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    // Test characters: A, B, O, 0, @
    const test_chars = [_]struct { code: u21, ref_file: []const u8 }{
        .{ .code = 'A', .ref_file = "tests/fixtures/reference/geneva_65.rgba" },
        .{ .code = 'B', .ref_file = "tests/fixtures/reference/geneva_66.rgba" },
        .{ .code = 'O', .ref_file = "tests/fixtures/reference/geneva_79.rgba" },
        .{ .code = '0', .ref_file = "tests/fixtures/reference/geneva_48.rgba" },
        .{ .code = '@', .ref_file = "tests/fixtures/reference/geneva_64.rgba" },
    };

    for (test_chars) |tc| {
        const ref = loadReferenceRgba(allocator, tc.ref_file) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        defer allocator.free(ref.pixels);

        var result = try msdf.generateGlyph(allocator, font, tc.code, .{
            .size = 32,
            .padding = 2,
            .range = 4.0,
        });
        defer result.deinit(allocator);

        const io_agreement = computeInsideOutsideAgreement(ref.pixels, result.pixels);

        std.debug.print("Character '{c}': inside/outside agreement = {d:.1}%\n", .{
            @as(u8, @intCast(tc.code)),
            io_agreement * 100,
        });

        // Each character should have high structural agreement
        try std.testing.expect(io_agreement > 0.80);
    }
}
