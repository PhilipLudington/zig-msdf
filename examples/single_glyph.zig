//! Example: Generate an MSDF for a single glyph and output as PPM image.
//!
//! Usage: single_glyph <font.ttf> [character] [options...]
//!
//! This example loads a TrueType font, generates an MSDF texture for a single
//! character, and saves the result as a PPM image file. PPM is a simple image
//! format that can be viewed with many image viewers without dependencies.

const std = @import("std");
const msdf = @import("msdf");

const Options = struct {
    args: [][:0]u8, // Keep args alive
    font_path: []const u8 = "",
    character: u21 = 'A',
    output_path: []const u8 = "glyph.ppm",
    size: u32 = 64,
    coloring_mode: msdf.coloring.ColoringMode = .simple,
    seed: u64 = 0,
    corner_threshold: f64 = msdf.coloring.default_corner_angle_threshold,
    distance_threshold: f64 = 0.5,
    correct_overlaps: bool = false,

    pub fn deinit(self: Options, allocator: std.mem.Allocator) void {
        std.process.argsFree(allocator, self.args);
    }
};

fn parseArgs(allocator: std.mem.Allocator) !?Options {
    const args = try std.process.argsAlloc(allocator);

    if (args.len < 2) {
        printUsage(args[0]);
        std.process.argsFree(allocator, args);
        return null;
    }

    // Check for help flag first
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage(args[0]);
            std.process.argsFree(allocator, args);
            return null;
        }
    }

    var opts = Options{ .args = args };
    opts.font_path = args[1];

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage(args[0]);
            std.process.argsFree(allocator, args);
            return null;
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --output requires a path\n", .{});
                std.process.argsFree(allocator, args);
                return null;
            }
            opts.output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--size") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --size requires a value\n", .{});
                std.process.argsFree(allocator, args);
                return null;
            }
            opts.size = std.fmt.parseInt(u32, args[i], 10) catch 64;
        } else if (std.mem.eql(u8, arg, "--mode") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --mode requires 'simple' or 'distance'\n", .{});
                std.process.argsFree(allocator, args);
                return null;
            }
            if (std.mem.eql(u8, args[i], "distance")) {
                opts.coloring_mode = .distance_based;
            } else {
                opts.coloring_mode = .simple;
            }
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --seed requires a value\n", .{});
                std.process.argsFree(allocator, args);
                return null;
            }
            opts.seed = std.fmt.parseInt(u64, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--corner-threshold")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --corner-threshold requires a value\n", .{});
                std.process.argsFree(allocator, args);
                return null;
            }
            opts.corner_threshold = std.fmt.parseFloat(f64, args[i]) catch 3.0;
        } else if (std.mem.eql(u8, arg, "--distance-threshold")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --distance-threshold requires a value\n", .{});
                std.process.argsFree(allocator, args);
                return null;
            }
            opts.distance_threshold = std.fmt.parseFloat(f64, args[i]) catch 0.5;
        } else if (std.mem.eql(u8, arg, "--correct-overlaps")) {
            opts.correct_overlaps = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument: character
            if (arg.len > 0) {
                opts.character = std.unicode.utf8Decode(arg) catch 'A';
            }
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            std.process.argsFree(allocator, args);
            return null;
        }
    }

    return opts;
}

fn printUsage(prog: []const u8) void {
    std.debug.print("Usage: {s} <font.ttf> [character] [options...]\n", .{prog});
    std.debug.print("\nGenerates an MSDF texture for a single glyph.\n", .{});
    std.debug.print("\nArguments:\n", .{});
    std.debug.print("  font.ttf              Path to a TrueType font file\n", .{});
    std.debug.print("  character             Character to render (default: 'A')\n", .{});
    std.debug.print("\nOptions:\n", .{});
    std.debug.print("  -o, --output PATH     Output PPM file path (default: 'glyph.ppm')\n", .{});
    std.debug.print("  -s, --size SIZE       Output texture size (default: 64)\n", .{});
    std.debug.print("  -m, --mode MODE       Coloring mode: 'simple' or 'distance' (default: simple)\n", .{});
    std.debug.print("  --seed VALUE          Coloring seed for reproducible variations (default: 0)\n", .{});
    std.debug.print("  --corner-threshold    Corner detection threshold in radians (default: 3.0)\n", .{});
    std.debug.print("  --distance-threshold  Edge distance threshold for distance mode (default: 0.5)\n", .{});
    std.debug.print("  --correct-overlaps    Enable overlapping contour correction\n", .{});
    std.debug.print("\nExamples:\n", .{});
    std.debug.print("  {s} font.ttf A -o output.ppm\n", .{prog});
    std.debug.print("  {s} font.ttf S --mode distance --seed 42\n", .{prog});
    std.debug.print("  {s} font.ttf B --corner-threshold 2.5 --correct-overlaps\n", .{prog});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const opts = try parseArgs(allocator) orelse return;
    defer opts.deinit(allocator);

    std.debug.print("Loading font: {s}\n", .{opts.font_path});

    // Load the font
    var font = msdf.Font.fromFile(allocator, opts.font_path) catch |err| {
        std.debug.print("Error loading font: {}\n", .{err});
        return;
    };
    defer font.deinit();

    std.debug.print("Character: {u} (U+{X:0>4})\n", .{ opts.character, opts.character });
    std.debug.print("Coloring mode: {s}\n", .{if (opts.coloring_mode == .simple) "simple" else "distance_based"});
    if (opts.seed != 0) {
        std.debug.print("Seed: {d}\n", .{opts.seed});
    }

    // Generate MSDF for the character
    var result = msdf.generateGlyph(allocator, font, opts.character, .{
        .size = opts.size,
        .padding = 4,
        .range = 4.0,
        .msdfgen_autoframe = true,
        .coloring_config = .{
            .mode = opts.coloring_mode,
            .seed = opts.seed,
            .corner_angle_threshold = opts.corner_threshold,
            .distance_threshold = opts.distance_threshold,
        },
        .correct_overlaps = opts.correct_overlaps,
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
    writePpm(opts.output_path, result.pixels, result.width, result.height) catch |err| {
        std.debug.print("Error writing PPM: {}\n", .{err});
        return;
    };

    std.debug.print("Output: {s}\n", .{opts.output_path});
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
