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

    // Note: Match rate may be lower (~30-50%) due to different edge coloring
    // algorithms and error correction approaches. This is acceptable as long as
    // inside/outside agreement is high. The MSDF will still render correctly
    // with different colorings.
    try std.testing.expect(match_rate > 0.30);
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

test "all printable ASCII characters" {
    const allocator = std.testing.allocator;

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    var failed_chars: [95]u8 = undefined;
    var failed_agreements: [95]f64 = undefined;

    // Test all printable ASCII characters (32-126)
    for (32..127) |code| {
        // Build reference file path
        var path_buf: [64]u8 = undefined;
        const ref_path = std.fmt.bufPrint(&path_buf, "tests/fixtures/reference/geneva_{d}.rgba", .{code}) catch continue;

        const ref = loadReferenceRgba(allocator, ref_path) catch |err| {
            if (err == error.FileNotFound) {
                skipped += 1;
                continue;
            }
            return err;
        };
        defer allocator.free(ref.pixels);

        var result = try msdf.generateGlyph(allocator, font, @intCast(code), .{
            .size = 32,
            .padding = 2,
            .range = 4.0,
        });
        defer result.deinit(allocator);

        const io_agreement = computeInsideOutsideAgreement(ref.pixels, result.pixels);

        // Each character should have high structural agreement
        if (io_agreement > 0.80) {
            passed += 1;
        } else {
            failed_chars[failed] = @intCast(code);
            failed_agreements[failed] = io_agreement;
            failed += 1;
        }
    }

    // Print summary
    std.debug.print("\nASCII test: {d} passed, {d} failed, {d} skipped\n", .{ passed, failed, skipped });

    // Print failures if any
    if (failed > 0) {
        std.debug.print("Failed characters:\n", .{});
        for (0..failed) |i| {
            const c = failed_chars[i];
            if (c >= 33 and c <= 126) {
                std.debug.print("  '{c}' ({d}): {d:.1}%\n", .{ c, c, failed_agreements[i] * 100 });
            } else {
                std.debug.print("  ({d}): {d:.1}%\n", .{ c, failed_agreements[i] * 100 });
            }
        }
    }

    // All tested characters should pass
    try std.testing.expect(failed == 0);
}

// ============================================================================
// S-Curve Edge Quality Tests
// ============================================================================

/// Compute edge smoothness by measuring gradient consistency along boundaries.
/// Returns a score from 0-1 where 1 is perfectly smooth gradients.
/// Artifacts from bad edge coloring show up as sudden jumps in gradient direction.
fn computeEdgeSmoothness(pixels: []const u8, width: u32, height: u32) f64 {
    var smooth_transitions: usize = 0;
    var total_boundary_pixels: usize = 0;

    // Scan interior pixels (skip edges)
    var y: u32 = 1;
    while (y < height - 1) : (y += 1) {
        var x: u32 = 1;
        while (x < width - 1) : (x += 1) {
            const idx = (y * width + x) * 3;

            // Get median value for this pixel
            const m = median3(pixels[idx], pixels[idx + 1], pixels[idx + 2]);

            // Check if this is a boundary pixel (near 127)
            if (m > 100 and m < 155) {
                total_boundary_pixels += 1;

                // Get neighboring medians
                const idx_left = (y * width + x - 1) * 3;
                const idx_right = (y * width + x + 1) * 3;
                const idx_up = ((y - 1) * width + x) * 3;
                const idx_down = ((y + 1) * width + x) * 3;

                const m_left = median3(pixels[idx_left], pixels[idx_left + 1], pixels[idx_left + 2]);
                const m_right = median3(pixels[idx_right], pixels[idx_right + 1], pixels[idx_right + 2]);
                const m_up = median3(pixels[idx_up], pixels[idx_up + 1], pixels[idx_up + 2]);
                const m_down = median3(pixels[idx_down], pixels[idx_down + 1], pixels[idx_down + 2]);

                // Compute gradient magnitude
                const grad_x = @as(i32, m_right) - @as(i32, m_left);
                const grad_y = @as(i32, m_down) - @as(i32, m_up);

                // Check for consistency: gradient should be smooth, not have sudden jumps
                // A smooth edge has consistent gradient direction
                const grad_mag = @abs(grad_x) + @abs(grad_y);

                // Artifacts show as very high gradients (sudden value jumps)
                // Normal boundary pixels have moderate gradients
                if (grad_mag < 100) {
                    smooth_transitions += 1;
                }
            }
        }
    }

    if (total_boundary_pixels == 0) return 1.0;
    return @as(f64, @floatFromInt(smooth_transitions)) / @as(f64, @floatFromInt(total_boundary_pixels));
}

/// Detect artifact pixels - places where channel values create bad median behavior.
/// MSDF artifacts show as pixels where channels disagree about inside/outside.
/// Returns the percentage of boundary pixels that are artifact-free.
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

            // Check boundary pixels (where artifacts are visible)
            if (m > 90 and m < 165) {
                total_boundary_pixels += 1;

                // Artifact detection: channels should not wildly disagree about inside/outside
                // An artifact occurs when one channel says "inside" (>127) while another
                // says "outside" (<127) AND the difference is extreme
                const r_inside = r > 127;
                const g_inside = g > 127;
                const b_inside = b > 127;

                // Count how many channels say "inside"
                var inside_count: u8 = 0;
                if (r_inside) inside_count += 1;
                if (g_inside) inside_count += 1;
                if (b_inside) inside_count += 1;

                // If all agree (0 or 3) or most agree (1 or 2), it's fine
                // Artifacts occur when channels strongly disagree with extreme values
                const max_channel = @max(r, @max(g, b));
                const min_channel = @min(r, @min(g, b));
                const spread = max_channel - min_channel;

                // An artifact is: channels disagree AND spread is extreme
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

test "S-curve characters edge quality - S" {
    const allocator = std.testing.allocator;

    var font = msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf") catch |err| {
        std.debug.print("Skipping test, font not found: {}\n", .{err});
        return;
    };
    defer font.deinit();

    // Generate at higher resolution to better detect artifacts
    var result = try msdf.generateGlyph(allocator, font, 'S', .{
        .size = 64,
        .padding = 4,
        .range = 4.0,
    });
    defer result.deinit(allocator);

    const smoothness = computeEdgeSmoothness(result.pixels, result.width, result.height);
    const artifact_free = computeArtifactFreeRate(result.pixels, result.width, result.height);

    std.debug.print("\nS-curve test 'S':\n", .{});
    std.debug.print("  Edge smoothness: {d:.1}%\n", .{smoothness * 100});
    std.debug.print("  Artifact-free rate: {d:.1}%\n", .{artifact_free * 100});

    // S has inflection points - these thresholds detect coloring artifacts
    try std.testing.expect(smoothness > 0.70);
    try std.testing.expect(artifact_free > 0.80);
}

test "S-curve characters edge quality - D" {
    const allocator = std.testing.allocator;

    var font = msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf") catch |err| {
        std.debug.print("Skipping test, font not found: {}\n", .{err});
        return;
    };
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, 'D', .{
        .size = 64,
        .padding = 4,
        .range = 4.0,
    });
    defer result.deinit(allocator);

    const smoothness = computeEdgeSmoothness(result.pixels, result.width, result.height);
    const artifact_free = computeArtifactFreeRate(result.pixels, result.width, result.height);

    std.debug.print("\nS-curve test 'D':\n", .{});
    std.debug.print("  Edge smoothness: {d:.1}%\n", .{smoothness * 100});
    std.debug.print("  Artifact-free rate: {d:.1}%\n", .{artifact_free * 100});

    try std.testing.expect(smoothness > 0.70);
    try std.testing.expect(artifact_free > 0.80);
}

test "S-curve characters edge quality - 2" {
    const allocator = std.testing.allocator;

    var font = msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf") catch |err| {
        std.debug.print("Skipping test, font not found: {}\n", .{err});
        return;
    };
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, '2', .{
        .size = 64,
        .padding = 4,
        .range = 4.0,
    });
    defer result.deinit(allocator);

    const smoothness = computeEdgeSmoothness(result.pixels, result.width, result.height);
    const artifact_free = computeArtifactFreeRate(result.pixels, result.width, result.height);

    std.debug.print("\nS-curve test '2':\n", .{});
    std.debug.print("  Edge smoothness: {d:.1}%\n", .{smoothness * 100});
    std.debug.print("  Artifact-free rate: {d:.1}%\n", .{artifact_free * 100});

    try std.testing.expect(smoothness > 0.70);
    try std.testing.expect(artifact_free > 0.80);
}

test "S-curve characters edge quality - 3" {
    const allocator = std.testing.allocator;

    var font = msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf") catch |err| {
        std.debug.print("Skipping test, font not found: {}\n", .{err});
        return;
    };
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, '3', .{
        .size = 64,
        .padding = 4,
        .range = 4.0,
    });
    defer result.deinit(allocator);

    const smoothness = computeEdgeSmoothness(result.pixels, result.width, result.height);
    const artifact_free = computeArtifactFreeRate(result.pixels, result.width, result.height);

    std.debug.print("\nS-curve test '3':\n", .{});
    std.debug.print("  Edge smoothness: {d:.1}%\n", .{smoothness * 100});
    std.debug.print("  Artifact-free rate: {d:.1}%\n", .{artifact_free * 100});

    try std.testing.expect(smoothness > 0.70);
    try std.testing.expect(artifact_free > 0.80);
}

test "compare S-curve vs angular character quality" {
    const allocator = std.testing.allocator;

    var font = msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf") catch |err| {
        std.debug.print("Skipping test, font not found: {}\n", .{err});
        return;
    };
    defer font.deinit();

    std.debug.print("\nComparing edge quality (angular vs S-curve):\n", .{});

    // Test angular character (should be high quality)
    var result_a = try msdf.generateGlyph(allocator, font, 'A', .{
        .size = 64,
        .padding = 4,
        .range = 4.0,
    });
    defer result_a.deinit(allocator);

    const smoothness_a = computeEdgeSmoothness(result_a.pixels, result_a.width, result_a.height);
    const artifact_free_a = computeArtifactFreeRate(result_a.pixels, result_a.width, result_a.height);
    std.debug.print("  'A' (angular):  smoothness = {d:.1}%, artifact-free = {d:.1}%\n", .{ smoothness_a * 100, artifact_free_a * 100 });

    // Test S-curve character
    var result_s = try msdf.generateGlyph(allocator, font, 'S', .{
        .size = 64,
        .padding = 4,
        .range = 4.0,
    });
    defer result_s.deinit(allocator);

    const smoothness_s = computeEdgeSmoothness(result_s.pixels, result_s.width, result_s.height);
    const artifact_free_s = computeArtifactFreeRate(result_s.pixels, result_s.width, result_s.height);
    std.debug.print("  'S' (S-curve):  smoothness = {d:.1}%, artifact-free = {d:.1}%\n", .{ smoothness_s * 100, artifact_free_s * 100 });

    // Test digit with curves
    var result_3 = try msdf.generateGlyph(allocator, font, '3', .{
        .size = 64,
        .padding = 4,
        .range = 4.0,
    });
    defer result_3.deinit(allocator);

    const smoothness_3 = computeEdgeSmoothness(result_3.pixels, result_3.width, result_3.height);
    const artifact_free_3 = computeArtifactFreeRate(result_3.pixels, result_3.width, result_3.height);
    std.debug.print("  '3' (S-curve):  smoothness = {d:.1}%, artifact-free = {d:.1}%\n", .{ smoothness_3 * 100, artifact_free_3 * 100 });

    // If edge coloring is working well, S-curve chars should have similar quality to angular
    // A large gap indicates the coloring algorithm isn't handling inflection points
    const smoothness_gap = smoothness_a - @min(smoothness_s, smoothness_3);
    const artifact_gap = artifact_free_a - @min(artifact_free_s, artifact_free_3);
    std.debug.print("  Smoothness gap (A vs worst S-curve): {d:.1}%\n", .{smoothness_gap * 100});
    std.debug.print("  Artifact gap (A vs worst S-curve): {d:.1}%\n", .{artifact_gap * 100});

    // Allow some gap but not too much - if inflection handling is broken, gap will be large
    try std.testing.expect(smoothness_gap < 0.25);
    // Artifact gap threshold - a significant gap indicates edge coloring issues
    try std.testing.expect(artifact_gap < 0.15);
}
