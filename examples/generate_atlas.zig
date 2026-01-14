//! Example: Generate an MSDF atlas for a font and output as PPM image.

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
        return;
    }

    const font_path = args[1];
    const output_path = if (args.len > 2) args[2] else "atlas.ppm";

    std.debug.print("Loading font: {s}\n", .{font_path});
    std.debug.print("Output: {s}\n", .{output_path});

    // TODO: Implement once Font.fromFile is available
    _ = msdf.Font.fromFile(allocator, font_path) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        std.debug.print("\nNote: Font loading not yet implemented.\n", .{});
        return;
    };
}
