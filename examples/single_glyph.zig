//! Example: Generate an MSDF for a single glyph and output as PPM image.
//!
//! Usage: single_glyph <font.ttf> [character] [output.ppm]
//!
//! This example loads a TrueType font, generates an MSDF texture for a single
//! character, and saves the result as a PPM image file. PPM is a simple image
//! format that can be viewed with many image viewers without dependencies.

const std = @import("std");
const msdf = @import("msdf");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <font.ttf> [character] [output.ppm]\n", .{args[0]});
        std.debug.print("\nGenerates an MSDF texture for a single glyph.\n", .{});
        std.debug.print("\nArguments:\n", .{});
        std.debug.print("  font.ttf    Path to a TrueType font file\n", .{});
        std.debug.print("  character   Character to render (default: 'A')\n", .{});
        std.debug.print("  output.ppm  Output PPM file path (default: 'glyph.ppm')\n", .{});
        return;
    }

    const font_path = args[1];
    const character: u21 = if (args.len > 2) blk: {
        const char_arg = args[2];
        if (char_arg.len > 0) {
            break :blk std.unicode.utf8Decode(char_arg) catch 'A';
        }
        break :blk 'A';
    } else 'A';
    const output_path = if (args.len > 3) args[3] else "glyph.ppm";

    std.debug.print("Loading font: {s}\n", .{font_path});

    // Load the font
    var font = msdf.Font.fromFile(allocator, font_path) catch |err| {
        std.debug.print("Error loading font: {}\n", .{err});
        return;
    };
    defer font.deinit();

    std.debug.print("Character: {u} (U+{X:0>4})\n", .{ character, character });

    // Generate MSDF for the character
    var result = msdf.generateGlyph(allocator, font, character, .{
        .size = 64,
        .padding = 4,
        .range = 4.0,
    }) catch |err| {
        std.debug.print("Error generating MSDF: {}\n", .{err});
        return;
    };
    defer result.deinit(allocator);

    std.debug.print("Generated {d}x{d} MSDF texture\n", .{ result.width, result.height });
    std.debug.print("Glyph metrics:\n", .{});
    std.debug.print("  advance_width: {d:.4}\n", .{result.metrics.advance_width});
    std.debug.print("  bearing_x: {d:.4}\n", .{result.metrics.bearing_x});
    std.debug.print("  bearing_y: {d:.4}\n", .{result.metrics.bearing_y});
    std.debug.print("  width: {d:.4}\n", .{result.metrics.width});
    std.debug.print("  height: {d:.4}\n", .{result.metrics.height});

    // Write PPM file
    writePpm(output_path, result.pixels, result.width, result.height) catch |err| {
        std.debug.print("Error writing PPM: {}\n", .{err});
        return;
    };

    std.debug.print("Output: {s}\n", .{output_path});
}

/// Write RGB8 pixel data to a PPM file.
fn writePpm(path: []const u8, pixels: []const u8, width: u32, height: u32) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    // PPM header (P6 = binary RGB)
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height }) catch unreachable;
    try file.writeAll(header);

    // Write pixel data (RGB8 format, which matches PPM P6)
    try file.writeAll(pixels);
}
