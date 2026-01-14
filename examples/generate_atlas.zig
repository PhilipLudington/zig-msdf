//! Example: Generate an MSDF atlas for a font and output as PPM image.
//!
//! Usage: generate_atlas <font.ttf> [output.ppm]
//!
//! This example loads a TrueType font, generates an MSDF atlas containing
//! all printable ASCII characters, and saves the result as a PPM image file.
//! It also prints UV coordinates and metrics for each glyph to stdout.

const std = @import("std");
const msdf = @import("msdf");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <font.ttf> [output.ppm]\n", .{args[0]});
        std.debug.print("\nGenerates an MSDF atlas for ASCII characters.\n", .{});
        std.debug.print("\nArguments:\n", .{});
        std.debug.print("  font.ttf    Path to a TrueType font file\n", .{});
        std.debug.print("  output.ppm  Output PPM file path (default: 'atlas.ppm')\n", .{});
        return;
    }

    const font_path = args[1];
    const output_path = if (args.len > 2) args[2] else "atlas.ppm";

    std.debug.print("Loading font: {s}\n", .{font_path});

    // Load the font
    var font = msdf.Font.fromFile(allocator, font_path) catch |err| {
        std.debug.print("Error loading font: {}\n", .{err});
        return;
    };
    defer font.deinit();

    // Define printable ASCII characters (space through tilde)
    const ascii_chars = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";

    std.debug.print("Generating atlas for {d} characters...\n", .{ascii_chars.len});

    // Generate atlas
    var atlas = msdf.generateAtlas(allocator, font, .{
        .chars = ascii_chars,
        .glyph_size = 48,
        .padding = 4,
        .range = 4.0,
    }) catch |err| {
        std.debug.print("Error generating atlas: {}\n", .{err});
        return;
    };
    defer atlas.deinit(allocator);

    std.debug.print("Generated {d}x{d} atlas texture\n", .{ atlas.width, atlas.height });
    std.debug.print("Glyphs in atlas: {d}\n", .{atlas.glyphs.count()});

    // Write atlas as PPM (RGBA8 -> RGB8 conversion)
    writeAtlasPpm(allocator, output_path, atlas.pixels, atlas.width, atlas.height) catch |err| {
        std.debug.print("Error writing PPM: {}\n", .{err});
        return;
    };

    std.debug.print("Output: {s}\n", .{output_path});

    // Print glyph metrics/UVs to stdout
    std.debug.print("\n--- Glyph Data ---\n", .{});
    std.debug.print("{s:>6} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{
        "Char",
        "UV.minX",
        "UV.minY",
        "UV.maxX",
        "UV.maxY",
        "Advance",
        "Width",
        "Height",
    });
    std.debug.print("{s:-<6} {s:-<10} {s:-<10} {s:-<10} {s:-<10} {s:-<10} {s:-<10} {s:-<10}\n", .{
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
    });

    // Print in ASCII order
    for (ascii_chars) |char| {
        const codepoint: u21 = char;
        if (atlas.glyphs.get(codepoint)) |glyph| {
            const char_display: u8 = if (char == ' ') '_' else char;
            std.debug.print("{c:>6} {d:>10.4} {d:>10.4} {d:>10.4} {d:>10.4} {d:>10.4} {d:>10.4} {d:>10.4}\n", .{
                char_display,
                glyph.uv_min[0],
                glyph.uv_min[1],
                glyph.uv_max[0],
                glyph.uv_max[1],
                glyph.metrics.advance_width,
                glyph.metrics.width,
                glyph.metrics.height,
            });
        }
    }
}

/// Write RGBA8 atlas pixel data to a PPM file (converts to RGB8).
fn writeAtlasPpm(allocator: std.mem.Allocator, path: []const u8, pixels: []const u8, width: u32, height: u32) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    // PPM header (P6 = binary RGB)
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height }) catch unreachable;
    try file.writeAll(header);

    // Convert RGBA8 to RGB8 and write
    const pixel_count = @as(usize, width) * @as(usize, height);
    const rgb_data = try allocator.alloc(u8, pixel_count * 3);
    defer allocator.free(rgb_data);

    var i: usize = 0;
    while (i < pixel_count) : (i += 1) {
        rgb_data[i * 3 + 0] = pixels[i * 4 + 0]; // R
        rgb_data[i * 3 + 1] = pixels[i * 4 + 1]; // G
        rgb_data[i * 3 + 2] = pixels[i * 4 + 2]; // B
        // Alpha is discarded
    }

    try file.writeAll(rgb_data);
}
