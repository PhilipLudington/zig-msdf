//! Render validation tests for zig-msdf.
//!
//! These tests verify that generated MSDFs render correctly by applying
//! the standard MSDF shader algorithm and checking the output quality.
//!
//! The MSDF shader works by taking the median of the RGB channels to get
//! a signed distance value, then thresholding to determine inside/outside.

const std = @import("std");
const msdf = @import("msdf");

/// Apply the MSDF shader to render a glyph at a specific size.
/// Returns a grayscale image where 255 = inside, 0 = outside.
fn renderMsdf(
    allocator: std.mem.Allocator,
    msdf_pixels: []const u8,
    msdf_width: u32,
    msdf_height: u32,
    output_width: u32,
    output_height: u32,
    smoothing: f32,
) ![]u8 {
    const output = try allocator.alloc(u8, @as(usize, output_width) * output_height);
    errdefer allocator.free(output);

    const scale_x = @as(f32, @floatFromInt(msdf_width)) / @as(f32, @floatFromInt(output_width));
    const scale_y = @as(f32, @floatFromInt(msdf_height)) / @as(f32, @floatFromInt(output_height));

    for (0..output_height) |oy| {
        for (0..output_width) |ox| {
            // Sample MSDF at corresponding position
            const sx = @as(f32, @floatFromInt(ox)) * scale_x;
            const sy = @as(f32, @floatFromInt(oy)) * scale_y;

            // Bilinear interpolation
            const sample = sampleMsdfBilinear(msdf_pixels, msdf_width, msdf_height, sx, sy);

            // Compute median of RGB channels (MSDF shader core algorithm)
            const signed_dist = median3f(sample[0], sample[1], sample[2]);

            // Apply smoothing and threshold
            // signed_dist is in [0, 1] range, 0.5 = edge
            const edge = 0.5;
            const alpha = std.math.clamp((signed_dist - edge) / smoothing + 0.5, 0.0, 1.0);

            output[oy * output_width + ox] = @intFromFloat(alpha * 255.0);
        }
    }

    return output;
}

/// Sample MSDF with bilinear interpolation, returns RGB in [0,1] range.
fn sampleMsdfBilinear(
    pixels: []const u8,
    width: u32,
    height: u32,
    x: f32,
    y: f32,
) [3]f32 {
    const x0 = @as(u32, @intFromFloat(@floor(x)));
    const y0 = @as(u32, @intFromFloat(@floor(y)));
    const x1 = @min(x0 + 1, width - 1);
    const y1 = @min(y0 + 1, height - 1);

    const fx = x - @floor(x);
    const fy = y - @floor(y);

    const p00 = getPixelF(pixels, width, x0, y0);
    const p10 = getPixelF(pixels, width, x1, y0);
    const p01 = getPixelF(pixels, width, x0, y1);
    const p11 = getPixelF(pixels, width, x1, y1);

    // Bilinear interpolation
    var result: [3]f32 = undefined;
    for (0..3) |i| {
        const top = p00[i] * (1.0 - fx) + p10[i] * fx;
        const bottom = p01[i] * (1.0 - fx) + p11[i] * fx;
        result[i] = top * (1.0 - fy) + bottom * fy;
    }

    return result;
}

fn getPixelF(pixels: []const u8, width: u32, x: u32, y: u32) [3]f32 {
    const idx = (y * width + x) * 3;
    return .{
        @as(f32, @floatFromInt(pixels[idx])) / 255.0,
        @as(f32, @floatFromInt(pixels[idx + 1])) / 255.0,
        @as(f32, @floatFromInt(pixels[idx + 2])) / 255.0,
    };
}

fn median3f(a: f32, b: f32, c: f32) f32 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

/// Calculate coverage (percentage of pixels that are "inside").
fn calculateCoverage(rendered: []const u8, threshold: u8) f64 {
    var inside: usize = 0;
    for (rendered) |pixel| {
        if (pixel >= threshold) inside += 1;
    }
    return @as(f64, @floatFromInt(inside)) / @as(f64, @floatFromInt(rendered.len));
}

/// Calculate edge quality by checking smoothness of transitions.
/// Returns average gradient magnitude at edge pixels.
fn calculateEdgeQuality(rendered: []const u8, width: u32, height: u32) f64 {
    var edge_count: usize = 0;
    var gradient_sum: f64 = 0;

    for (1..height - 1) |y| {
        for (1..width - 1) |x| {
            const idx = y * width + x;
            const center = rendered[idx];

            // Check if this is an edge pixel (between 64 and 192)
            if (center > 64 and center < 192) {
                // Calculate gradient using Sobel-like operator
                const left = @as(i32, rendered[idx - 1]);
                const right = @as(i32, rendered[idx + 1]);
                const up = @as(i32, rendered[idx - width]);
                const down = @as(i32, rendered[idx + width]);

                const gx = right - left;
                const gy = down - up;
                const gradient = @sqrt(@as(f64, @floatFromInt(gx * gx + gy * gy)));

                gradient_sum += gradient;
                edge_count += 1;
            }
        }
    }

    if (edge_count == 0) return 0;
    return gradient_sum / @as(f64, @floatFromInt(edge_count));
}

// ============================================================================
// Tests
// ============================================================================

test "MSDF renders correctly at 1x scale" {
    const allocator = std.testing.allocator;

    // Load font and generate MSDF
    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, 'A', .{
        .size = 32,
        .padding = 4,
        .range = 4.0,
    });
    defer result.deinit(allocator);

    // Render at same size as MSDF
    const rendered = try renderMsdf(
        allocator,
        result.pixels,
        result.width,
        result.height,
        32,
        32,
        0.1,
    );
    defer allocator.free(rendered);

    // Check coverage is reasonable for letter 'A' (roughly 20-40% filled)
    const coverage = calculateCoverage(rendered, 128);
    std.debug.print("\n1x render coverage: {d:.1}%\n", .{coverage * 100});
    try std.testing.expect(coverage > 0.15 and coverage < 0.50);

    // Check edge quality (should have smooth gradients)
    const edge_quality = calculateEdgeQuality(rendered, 32, 32);
    std.debug.print("1x edge quality (gradient): {d:.1}\n", .{edge_quality});
    try std.testing.expect(edge_quality > 10); // Should have meaningful gradients
}

test "MSDF renders correctly at 2x scale" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, 'A', .{
        .size = 32,
        .padding = 4,
        .range = 4.0,
    });
    defer result.deinit(allocator);

    // Render at 2x size
    const rendered = try renderMsdf(
        allocator,
        result.pixels,
        result.width,
        result.height,
        64,
        64,
        0.05, // Tighter smoothing at higher resolution
    );
    defer allocator.free(rendered);

    const coverage = calculateCoverage(rendered, 128);
    std.debug.print("\n2x render coverage: {d:.1}%\n", .{coverage * 100});
    try std.testing.expect(coverage > 0.15 and coverage < 0.50);
}

test "MSDF renders correctly at 4x scale" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, 'A', .{
        .size = 32,
        .padding = 4,
        .range = 4.0,
    });
    defer result.deinit(allocator);

    // Render at 4x size
    const rendered = try renderMsdf(
        allocator,
        result.pixels,
        result.width,
        result.height,
        128,
        128,
        0.025,
    );
    defer allocator.free(rendered);

    const coverage = calculateCoverage(rendered, 128);
    std.debug.print("\n4x render coverage: {d:.1}%\n", .{coverage * 100});
    try std.testing.expect(coverage > 0.15 and coverage < 0.50);

    // At 4x, edge quality should be even better
    const edge_quality = calculateEdgeQuality(rendered, 128, 128);
    std.debug.print("4x edge quality (gradient): {d:.1}\n", .{edge_quality});
}

test "coverage is consistent across scales" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, 'O', .{
        .size = 32,
        .padding = 4,
        .range = 4.0,
    });
    defer result.deinit(allocator);

    // Render at multiple scales
    const scales = [_]u32{ 32, 64, 128 };
    var coverages: [3]f64 = undefined;

    for (scales, 0..) |scale, i| {
        const smoothing = 0.1 / @as(f32, @floatFromInt(scale / 32));
        const rendered = try renderMsdf(
            allocator,
            result.pixels,
            result.width,
            result.height,
            scale,
            scale,
            smoothing,
        );
        defer allocator.free(rendered);

        coverages[i] = calculateCoverage(rendered, 128);
    }

    std.debug.print("\nCoverage across scales (O): {d:.1}%, {d:.1}%, {d:.1}%\n", .{
        coverages[0] * 100,
        coverages[1] * 100,
        coverages[2] * 100,
    });

    // Coverage should be similar across scales (within 5%)
    const max_diff = @max(
        @abs(coverages[0] - coverages[1]),
        @abs(coverages[1] - coverages[2]),
    );
    std.debug.print("Max coverage difference: {d:.1}%\n", .{max_diff * 100});
    try std.testing.expect(max_diff < 0.05);
}

test "different characters have appropriate coverage" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    const test_chars = [_]struct { char: u21, min_cov: f64, max_cov: f64 }{
        .{ .char = 'I', .min_cov = 0.05, .max_cov = 0.25 }, // Thin
        .{ .char = 'O', .min_cov = 0.10, .max_cov = 0.45 }, // Ring
        .{ .char = 'M', .min_cov = 0.15, .max_cov = 0.50 }, // Wide
        .{ .char = '.', .min_cov = 0.30, .max_cov = 0.70 }, // Small (fills more due to scaling)
    };

    std.debug.print("\nCharacter coverage:\n", .{});

    for (test_chars) |tc| {
        var result = try msdf.generateGlyph(allocator, font, tc.char, .{
            .size = 32,
            .padding = 4,
            .range = 4.0,
        });
        defer result.deinit(allocator);

        const rendered = try renderMsdf(
            allocator,
            result.pixels,
            result.width,
            result.height,
            64,
            64,
            0.05,
        );
        defer allocator.free(rendered);

        const coverage = calculateCoverage(rendered, 128);
        std.debug.print("  '{c}': {d:.1}% (expected {d:.0}%-{d:.0}%)\n", .{
            @as(u8, @intCast(tc.char)),
            coverage * 100,
            tc.min_cov * 100,
            tc.max_cov * 100,
        });

        try std.testing.expect(coverage >= tc.min_cov and coverage <= tc.max_cov);
    }
}

test "MSDF renders sharp corners correctly" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    // Test characters with sharp corners
    const corner_chars = [_]u21{ 'A', 'V', 'W', 'M', 'N' };

    for (corner_chars) |char| {
        var result = try msdf.generateGlyph(allocator, font, char, .{
            .size = 32,
            .padding = 4,
            .range = 4.0,
        });
        defer result.deinit(allocator);

        // Render at high resolution to check corner quality
        const rendered = try renderMsdf(
            allocator,
            result.pixels,
            result.width,
            result.height,
            128,
            128,
            0.02,
        );
        defer allocator.free(rendered);

        // Check that we have both filled and unfilled regions
        const coverage = calculateCoverage(rendered, 128);
        try std.testing.expect(coverage > 0.1 and coverage < 0.6);

        // Check edge quality
        const edge_quality = calculateEdgeQuality(rendered, 128, 128);
        try std.testing.expect(edge_quality > 5); // Should have defined edges
    }
}
