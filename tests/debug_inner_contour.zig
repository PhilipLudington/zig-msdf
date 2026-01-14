//! Debug test to analyze inner contour issues

const std = @import("std");
const msdf = @import("msdf");

fn median3(a: u8, b: u8, c: u8) u8 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

fn loadReferenceRgba(allocator: std.mem.Allocator, path: []const u8) !struct {
    pixels: []u8,
    width: u32,
    height: u32,
} {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    errdefer allocator.free(data);

    if (data.len < 12) return error.InvalidFormat;
    if (!std.mem.eql(u8, data[0..4], "RGBA")) return error.InvalidFormat;

    const width = std.mem.readInt(u32, data[4..8], .big);
    const height = std.mem.readInt(u32, data[8..12], .big);

    const pixel_count = @as(usize, width) * @as(usize, height);
    const rgb_data = try allocator.alloc(u8, pixel_count * 3);
    errdefer allocator.free(rgb_data);

    for (0..pixel_count) |i| {
        const src_idx = 12 + i * 4;
        const dst_idx = i * 3;
        rgb_data[dst_idx] = data[src_idx];
        rgb_data[dst_idx + 1] = data[src_idx + 1];
        rgb_data[dst_idx + 2] = data[src_idx + 2];
    }

    allocator.free(data);
    return .{ .pixels = rgb_data, .width = width, .height = height };
}

test "debug A character corners" {
    const allocator = std.testing.allocator;

    const ref = loadReferenceRgba(allocator, "tests/fixtures/reference/geneva_65.rgba") catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Reference file not found\n", .{});
            return;
        }
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

    std.debug.print("\n=== 'A' Character Corner Analysis ===\n", .{});
    std.debug.print("Image size: {}x{}\n", .{ ref.width, ref.height });

    // Check specific corners
    const corners = [_]struct { x: u32, y: u32, name: []const u8 }{
        .{ .x = 0, .y = 0, .name = "top-left" },
        .{ .x = 31, .y = 0, .name = "top-right" },
        .{ .x = 0, .y = 31, .name = "bottom-left" },
        .{ .x = 31, .y = 31, .name = "bottom-right" },
    };

    for (corners) |c| {
        const i = c.y * ref.width + c.x;
        const idx = @as(usize, i) * 3;
        const ref_median = median3(ref.pixels[idx], ref.pixels[idx + 1], ref.pixels[idx + 2]);
        const our_median = median3(result.pixels[idx], result.pixels[idx + 1], result.pixels[idx + 2]);

        std.debug.print("  {s}: ref={} ({s}), ours={} ({s})\n", .{
            c.name,
            ref_median,
            if (ref_median > 127) "IN" else "OUT",
            our_median,
            if (our_median > 127) "IN" else "OUT",
        });
    }
}

test "debug O character disagreements" {
    const allocator = std.testing.allocator;

    const ref = loadReferenceRgba(allocator, "tests/fixtures/reference/geneva_79.rgba") catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Reference file not found\n", .{});
            return;
        }
        return err;
    };
    defer allocator.free(ref.pixels);

    var font = try msdf.Font.fromFile(allocator, "/System/Library/Fonts/Geneva.ttf");
    defer font.deinit();

    var result = try msdf.generateGlyph(allocator, font, 'O', .{
        .size = 32,
        .padding = 2,
        .range = 4.0,
    });
    defer result.deinit(allocator);

    std.debug.print("\n=== 'O' Character Analysis ===\n", .{});
    std.debug.print("Image size: {}x{}\n\n", .{ ref.width, ref.height });

    // Categorize disagreements
    var inside_inside: usize = 0; // both say inside
    var outside_outside: usize = 0; // both say outside
    var ref_inside_ours_outside: usize = 0; // ref says inside, we say outside
    var ref_outside_ours_inside: usize = 0; // ref says outside, we say inside

    // Track positions of disagreements
    const PosInfo = struct { x: u32, y: u32, ref_val: u8, our_val: u8 };
    var disagree_positions = std.ArrayListUnmanaged(PosInfo){};
    defer disagree_positions.deinit(allocator);

    const pixel_count = @as(usize, ref.width) * @as(usize, ref.height);
    for (0..pixel_count) |i| {
        const idx = i * 3;
        const ref_median = median3(ref.pixels[idx], ref.pixels[idx + 1], ref.pixels[idx + 2]);
        const our_median = median3(result.pixels[idx], result.pixels[idx + 1], result.pixels[idx + 2]);

        const ref_inside = ref_median > 127;
        const our_inside = our_median > 127;

        const x: u32 = @intCast(i % ref.width);
        const y: u32 = @intCast(i / ref.width);

        if (ref_inside and our_inside) {
            inside_inside += 1;
        } else if (!ref_inside and !our_inside) {
            outside_outside += 1;
        } else if (ref_inside and !our_inside) {
            ref_inside_ours_outside += 1;
            if (disagree_positions.items.len < 50) {
                try disagree_positions.append(allocator, .{ .x = x, .y = y, .ref_val = ref_median, .our_val = our_median });
            }
        } else {
            ref_outside_ours_inside += 1;
            if (disagree_positions.items.len < 50) {
                try disagree_positions.append(allocator, .{ .x = x, .y = y, .ref_val = ref_median, .our_val = our_median });
            }
        }
    }

    const total = inside_inside + outside_outside + ref_inside_ours_outside + ref_outside_ours_inside;
    std.debug.print("Agreement breakdown:\n", .{});
    std.debug.print("  Both inside:  {} ({d:.1}%)\n", .{ inside_inside, @as(f64, @floatFromInt(inside_inside)) / @as(f64, @floatFromInt(total)) * 100 });
    std.debug.print("  Both outside: {} ({d:.1}%)\n", .{ outside_outside, @as(f64, @floatFromInt(outside_outside)) / @as(f64, @floatFromInt(total)) * 100 });
    std.debug.print("  Ref inside, ours outside: {} ({d:.1}%)\n", .{ ref_inside_ours_outside, @as(f64, @floatFromInt(ref_inside_ours_outside)) / @as(f64, @floatFromInt(total)) * 100 });
    std.debug.print("  Ref outside, ours inside: {} ({d:.1}%)\n", .{ ref_outside_ours_inside, @as(f64, @floatFromInt(ref_outside_ours_inside)) / @as(f64, @floatFromInt(total)) * 100 });

    std.debug.print("\nFirst {} disagreement positions:\n", .{disagree_positions.items.len});
    for (disagree_positions.items) |pos| {
        const type_str = if (pos.ref_val > 127) "ref=IN, ours=OUT" else "ref=OUT, ours=IN";
        std.debug.print("  ({}, {}): ref={}, ours={} [{s}]\n", .{ pos.x, pos.y, pos.ref_val, pos.our_val, type_str });
    }

    // Print visual map of disagreements (30x30 center region)
    std.debug.print("\nDisagreement map (center region, X=disagree):\n", .{});
    const start_x: u32 = if (ref.width > 20) (ref.width - 20) / 2 else 0;
    const start_y: u32 = if (ref.height > 20) (ref.height - 20) / 2 else 0;
    const end_x: u32 = @min(start_x + 20, ref.width);
    const end_y: u32 = @min(start_y + 20, ref.height);

    var y = start_y;
    while (y < end_y) : (y += 1) {
        var x = start_x;
        while (x < end_x) : (x += 1) {
            const i = y * ref.width + x;
            const idx = @as(usize, i) * 3;
            const ref_median = median3(ref.pixels[idx], ref.pixels[idx + 1], ref.pixels[idx + 2]);
            const our_median = median3(result.pixels[idx], result.pixels[idx + 1], result.pixels[idx + 2]);

            const ref_inside = ref_median > 127;
            const our_inside = our_median > 127;

            if (ref_inside != our_inside) {
                std.debug.print("X", .{});
            } else if (ref_inside) {
                std.debug.print("#", .{}); // inside
            } else {
                std.debug.print(".", .{}); // outside
            }
        }
        std.debug.print("\n", .{});
    }
}
