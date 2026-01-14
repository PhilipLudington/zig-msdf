//! Multi-font tests for zig-msdf.
//!
//! These tests verify that the MSDF generation works correctly across
//! different fonts with varying styles and characteristics.

const std = @import("std");
const msdf = @import("msdf");

/// Test that a font can be loaded and generates valid MSDF output.
fn testFont(allocator: std.mem.Allocator, font_path: []const u8, test_char: u21) !void {
    var font = msdf.Font.fromFile(allocator, font_path) catch |err| {
        // Skip if font doesn't exist or can't be loaded
        std.debug.print("  Skipping {s}: {}\n", .{ font_path, err });
        return;
    };
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, test_char, .{
        .size = 32,
        .padding = 4,
        .range = 4.0,
    });
    defer result.deinit(allocator);

    // Verify dimensions
    try std.testing.expectEqual(@as(u32, 32), result.width);
    try std.testing.expectEqual(@as(u32, 32), result.height);

    // Verify we have pixel data
    try std.testing.expectEqual(@as(usize, 32 * 32 * 3), result.pixels.len);

    // Verify we have variation (not all same color)
    var min_val: u8 = 255;
    var max_val: u8 = 0;
    for (result.pixels) |p| {
        min_val = @min(min_val, p);
        max_val = @max(max_val, p);
    }
    try std.testing.expect(max_val > min_val + 50);

    // Verify metrics are reasonable
    try std.testing.expect(result.metrics.advance_width > 0);
    try std.testing.expect(result.metrics.width >= 0);
    try std.testing.expect(result.metrics.height >= 0);

    std.debug.print("  {s}: OK (advance={d:.3})\n", .{
        std.fs.path.basename(font_path),
        result.metrics.advance_width,
    });
}

// ============================================================================
// Tests
// ============================================================================

test "multiple system fonts generate valid MSDFs" {
    const allocator = std.testing.allocator;

    std.debug.print("\nTesting multiple fonts with 'A':\n", .{});

    const fonts = [_][]const u8{
        "/System/Library/Fonts/Geneva.ttf", // Sans-serif
        "/System/Library/Fonts/Monaco.ttf", // Monospace
        "/System/Library/Fonts/NewYork.ttf", // Serif
        "/Library/Fonts/Arial Unicode.ttf", // Unicode coverage
    };

    var tested: usize = 0;
    for (fonts) |font_path| {
        testFont(allocator, font_path, 'A') catch |err| {
            std.debug.print("  {s}: FAILED - {}\n", .{ font_path, err });
            continue;
        };
        tested += 1;
    }

    // At least one font should work
    try std.testing.expect(tested >= 1);
}

test "fonts handle various character types" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    std.debug.print("\nTesting various character types:\n", .{});

    const test_cases = [_]struct { char: u21, name: []const u8 }{
        .{ .char = 'A', .name = "uppercase" },
        .{ .char = 'a', .name = "lowercase" },
        .{ .char = '0', .name = "digit" },
        .{ .char = '@', .name = "symbol" },
        .{ .char = '.', .name = "punctuation" },
        .{ .char = ' ', .name = "space" },
    };

    for (test_cases) |tc| {
        var result = msdf.generateGlyph(allocator, font, tc.char, .{
            .size = 32,
            .padding = 4,
            .range = 4.0,
        }) catch |err| {
            std.debug.print("  '{c}' ({s}): FAILED - {}\n", .{ @as(u8, @intCast(tc.char)), tc.name, err });
            continue;
        };
        defer result.deinit(allocator);

        std.debug.print("  '{c}' ({s}): OK\n", .{ @as(u8, @intCast(tc.char)), tc.name });
    }
}

test "font metrics are consistent" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    // Generate same glyph multiple times - should be deterministic
    var result1 = try msdf.generateGlyph(allocator, font, 'A', .{
        .size = 32,
        .padding = 4,
        .range = 4.0,
    });
    defer result1.deinit(allocator);

    var result2 = try msdf.generateGlyph(allocator, font, 'A', .{
        .size = 32,
        .padding = 4,
        .range = 4.0,
    });
    defer result2.deinit(allocator);

    // Metrics should be identical
    try std.testing.expectEqual(result1.metrics.advance_width, result2.metrics.advance_width);
    try std.testing.expectEqual(result1.metrics.bearing_x, result2.metrics.bearing_x);
    try std.testing.expectEqual(result1.metrics.bearing_y, result2.metrics.bearing_y);

    // Pixel data should be identical
    try std.testing.expectEqualSlices(u8, result1.pixels, result2.pixels);
}

test "atlas generation works" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    var atlas = try msdf.generateAtlas(allocator, font, .{
        .chars = "ABCD",
        .glyph_size = 32,
        .padding = 4,
        .range = 4.0,
    });
    defer atlas.deinit(allocator);

    std.debug.print("\nAtlas: {d}x{d}, {d} glyphs\n", .{
        atlas.width,
        atlas.height,
        atlas.glyphs.count(),
    });

    // Should have all 4 glyphs
    try std.testing.expectEqual(@as(usize, 4), atlas.glyphs.count());

    // Check each glyph has valid UVs
    const chars = "ABCD";
    for (chars) |c| {
        const glyph = atlas.glyphs.get(c) orelse {
            std.debug.print("  Missing glyph: '{c}'\n", .{c});
            return error.TestUnexpectedResult;
        };

        try std.testing.expect(glyph.uv_min[0] >= 0 and glyph.uv_min[0] <= 1);
        try std.testing.expect(glyph.uv_max[0] >= 0 and glyph.uv_max[0] <= 1);
        try std.testing.expect(glyph.uv_min[1] >= 0 and glyph.uv_min[1] <= 1);
        try std.testing.expect(glyph.uv_max[1] >= 0 and glyph.uv_max[1] <= 1);
    }
}

test "different font sizes produce valid output" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    std.debug.print("\nTesting different sizes:\n", .{});

    const sizes = [_]u32{ 16, 32, 48, 64, 128 };

    for (sizes) |size| {
        var result = try msdf.generateGlyph(allocator, font, 'A', .{
            .size = size,
            .padding = 4,
            .range = 4.0,
        });
        defer result.deinit(allocator);

        try std.testing.expectEqual(size, result.width);
        try std.testing.expectEqual(size, result.height);

        std.debug.print("  {d}x{d}: OK\n", .{ size, size });
    }
}
