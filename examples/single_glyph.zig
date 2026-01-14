//! Example: Generate an MSDF for a single glyph and output as PPM image.

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
    std.debug.print("Character: {u} (U+{X:0>4})\n", .{ character, character });
    std.debug.print("Output: {s}\n", .{output_path});

    // TODO: Implement once Font.fromFile is available
    _ = msdf.Font.fromFile(allocator, font_path) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        std.debug.print("\nNote: Font loading not yet implemented.\n", .{});
        return;
    };
}
