//! Example: Generate MSDF from a CFF (OpenType) font.
//!
//! Usage: cff_font <font.otf> [character] [output.ppm]
//!
//! This example demonstrates loading OpenType fonts with CFF outlines (.otf files).
//! CFF fonts use cubic Bezier curves (PostScript-style) instead of TrueType's
//! quadratic curves. The library automatically detects the font format.
//!
//! Common CFF fonts include: Source Sans Pro, Source Code Pro, Noto Sans (OTF versions),
//! and most Adobe fonts.

const std = @import("std");
const msdf = @import("msdf");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <font.otf> [character] [output.ppm]\n", .{args[0]});
        std.debug.print("\nGenerates an MSDF texture from a CFF (OpenType) font.\n", .{});
        std.debug.print("\nArguments:\n", .{});
        std.debug.print("  font.otf    Path to an OpenType font file with CFF outlines\n", .{});
        std.debug.print("  character   Character to render (default: 'A')\n", .{});
        std.debug.print("  output.ppm  Output PPM file path (default: 'cff_glyph.ppm')\n", .{});
        std.debug.print("\nNote: This works with both .otf (CFF) and .ttf (TrueType) fonts.\n", .{});
        std.debug.print("The library automatically detects the outline format.\n", .{});
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
    const output_path = if (args.len > 3) args[3] else "cff_glyph.ppm";

    std.debug.print("Loading font: {s}\n", .{font_path});

    // Load the font
    var font = msdf.Font.fromFile(allocator, font_path) catch |err| {
        std.debug.print("Error loading font: {}\n", .{err});
        return;
    };
    defer font.deinit();

    // Detect font format
    const is_cff = font.findTable("CFF ") != null;
    const format_name = if (is_cff) "CFF (cubic Bezier)" else "TrueType (quadratic Bezier)";
    std.debug.print("Font format: {s}\n", .{format_name});

    // Print some font tables for debugging
    std.debug.print("Tables found: ", .{});
    const table_tags = [_]*const [4]u8{ "head", "maxp", "cmap", "hhea", "hmtx", "glyf", "loca", "CFF ", "post", "name" };
    var first = true;
    for (table_tags) |tag| {
        if (font.findTable(tag)) |_| {
            if (!first) std.debug.print(", ", .{});
            std.debug.print("{s}", .{tag});
            first = false;
        }
    }
    std.debug.print("\n", .{});

    std.debug.print("Character: {u} (U+{X:0>4})\n", .{ character, character });

    // Generate MSDF
    const size: u32 = 64; // Larger size for better detail
    const padding: u32 = 4;
    const range: f64 = 4.0;

    std.debug.print("Generating {d}x{d} MSDF (padding={d}, range={d})...\n", .{ size, size, padding, range });

    var result = msdf.generateGlyph(allocator, font, character, .{
        .size = size,
        .padding = padding,
        .range = range,
    }) catch |err| {
        std.debug.print("Error generating glyph: {}\n", .{err});
        return;
    };
    defer result.deinit(allocator);

    // Print metrics
    std.debug.print("\nGlyph metrics (normalized to em):\n", .{});
    std.debug.print("  Advance width: {d:.4}\n", .{result.metrics.advance_width});
    std.debug.print("  Bearing X:     {d:.4}\n", .{result.metrics.bearing_x});
    std.debug.print("  Bearing Y:     {d:.4}\n", .{result.metrics.bearing_y});
    std.debug.print("  Width:         {d:.4}\n", .{result.metrics.width});
    std.debug.print("  Height:        {d:.4}\n", .{result.metrics.height});

    // Write PPM file
    std.debug.print("\nWriting {s}...\n", .{output_path});

    const file = std.fs.cwd().createFile(output_path, .{}) catch |err| {
        std.debug.print("Error creating file: {}\n", .{err});
        return;
    };
    defer file.close();

    // PPM header (P6 = binary RGB)
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ result.width, result.height }) catch unreachable;
    file.writeAll(header) catch |err| {
        std.debug.print("Error writing header: {}\n", .{err});
        return;
    };

    // Write RGB pixels
    file.writeAll(result.pixels) catch |err| {
        std.debug.print("Error writing pixels: {}\n", .{err});
        return;
    };

    std.debug.print("Done! Output: {s} ({d}x{d})\n", .{ output_path, result.width, result.height });

    // Provide viewing suggestions
    std.debug.print("\nTo view the output:\n", .{});
    std.debug.print("  macOS:  open {s}\n", .{output_path});
    std.debug.print("  Linux:  display {s}  (ImageMagick)\n", .{output_path});
    std.debug.print("  Any:    convert {s} output.png  (ImageMagick)\n", .{output_path});
}
