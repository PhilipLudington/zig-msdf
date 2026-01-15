//! zig-msdf: A pure Zig library for generating Multi-channel Signed Distance Fields from OpenType fonts.
//!
//! Supports both TrueType (quadratic Bezier) and CFF (cubic Bezier) outline formats.
//!
//! ## Example Usage
//! ```zig
//! const msdf = @import("msdf");
//!
//! // Load a font
//! const font = try msdf.Font.fromFile(allocator, "path/to/font.ttf");
//! defer font.deinit();
//!
//! // Generate MSDF for a single glyph
//! const result = try msdf.generateGlyph(allocator, font, 'A', .{
//!     .size = 48,
//!     .padding = 4,
//!     .range = 4.0,
//! });
//! defer result.deinit(allocator);
//! ```

const std = @import("std");

// Generator modules
pub const math = @import("generator/math.zig");
pub const edge = @import("generator/edge.zig");
pub const contour = @import("generator/contour.zig");
pub const coloring = @import("generator/coloring.zig");
pub const generate = @import("generator/generate.zig");

// TrueType parser modules
pub const truetype_parser = @import("truetype/parser.zig");
pub const truetype_tables = @import("truetype/tables.zig");
pub const glyf = @import("truetype/glyf.zig");
pub const cmap = @import("truetype/cmap.zig");
pub const hhea_hmtx = @import("truetype/hhea_hmtx.zig");
pub const head_maxp = @import("truetype/head_maxp.zig");

// CFF parser modules
pub const cff = @import("cff/cff.zig");

/// Options for generating a single glyph MSDF.
pub const GenerateOptions = struct {
    /// Output texture size in pixels (width and height).
    size: u32 = 48,
    /// Padding around the glyph in pixels.
    padding: u32 = 4,
    /// Distance field range in pixels.
    range: f64 = 4.0,
};

/// Options for generating a font atlas.
pub const AtlasOptions = struct {
    /// Characters to include in the atlas.
    chars: []const u8 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
    /// Size of each glyph cell in pixels.
    glyph_size: u32 = 48,
    /// Padding around each glyph in pixels.
    padding: u32 = 4,
    /// Distance field range in pixels.
    range: f64 = 4.0,
};

/// Metrics for a rendered glyph.
pub const GlyphMetrics = struct {
    /// Horizontal advance (normalized to font units).
    advance_width: f32,
    /// Left side bearing.
    bearing_x: f32,
    /// Top bearing from baseline.
    bearing_y: f32,
    /// Glyph bounding box width.
    width: f32,
    /// Glyph bounding box height.
    height: f32,
};

/// Result of generating an MSDF for a single glyph.
pub const MsdfResult = struct {
    /// Pixel data in RGB8 format (3 bytes per pixel).
    pixels: []u8,
    /// Width of the texture in pixels.
    width: u32,
    /// Height of the texture in pixels.
    height: u32,
    /// Glyph metrics.
    metrics: GlyphMetrics,

    pub fn deinit(self: *MsdfResult, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// Information about a glyph in an atlas.
pub const AtlasGlyph = struct {
    /// Minimum UV coordinates (bottom-left).
    uv_min: [2]f32,
    /// Maximum UV coordinates (top-right).
    uv_max: [2]f32,
    /// Glyph metrics.
    metrics: GlyphMetrics,
};

/// Result of generating a font atlas.
pub const AtlasResult = struct {
    /// Pixel data in RGBA8 format (4 bytes per pixel).
    pixels: []u8,
    /// Width of the atlas texture in pixels.
    width: u32,
    /// Height of the atlas texture in pixels.
    height: u32,
    /// Map of codepoint to glyph information.
    glyphs: std.AutoHashMap(u21, AtlasGlyph),

    pub fn deinit(self: *AtlasResult, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.glyphs.deinit();
        self.* = undefined;
    }
};

/// A parsed TrueType font.
pub const Font = truetype_parser.Font;

/// Errors that can occur during MSDF generation.
pub const MsdfError = error{
    /// A required font table is missing.
    MissingTable,
    /// The font data is invalid or corrupted.
    InvalidFontData,
    /// The 'head' table data is invalid.
    InvalidHeadTable,
    /// The 'maxp' table data is invalid.
    InvalidMaxpTable,
    /// The 'cmap' table data is invalid.
    InvalidCmapTable,
    /// The 'hhea' table data is invalid.
    InvalidHheaTable,
    /// The 'hmtx' table data is invalid.
    InvalidHmtxTable,
    /// The 'glyf' table data is invalid or glyph outline is corrupted.
    InvalidGlyfTable,
    /// The CFF table data is invalid or glyph outline is corrupted.
    InvalidCffTable,
    /// Memory allocation failed.
    OutOfMemory,
    /// The requested glyph is not in the font.
    GlyphNotFound,
    /// The font format is not supported.
    UnsupportedFormat,
};

/// Generate an MSDF texture for a single glyph.
///
/// Parameters:
/// - allocator: Allocator for output bitmap and intermediate data.
/// - font: The TrueType font to use.
/// - codepoint: Unicode codepoint of the character to render.
/// - options: Generation options (size, padding, range).
///
/// Returns an MsdfResult containing the MSDF texture and glyph metrics.
/// Caller owns the returned result and must call `deinit()` to free it.
pub fn generateGlyph(
    allocator: std.mem.Allocator,
    font: Font,
    codepoint: u21,
    options: GenerateOptions,
) MsdfError!MsdfResult {
    // Parse required tables
    const head_data = font.getTableData("head") orelse return MsdfError.MissingTable;
    const head = head_maxp.HeadTable.parse(head_data) catch return MsdfError.InvalidHeadTable;

    const maxp_data = font.getTableData("maxp") orelse return MsdfError.MissingTable;
    const maxp = head_maxp.MaxpTable.parse(maxp_data) catch return MsdfError.InvalidMaxpTable;

    _ = font.getTableData("cmap") orelse return MsdfError.MissingTable;
    const cmap_table_offset = font.findTable("cmap").?.offset;
    const cmap_table = cmap.CmapTable.parse(font.data, cmap_table_offset) catch return MsdfError.InvalidCmapTable;

    const hhea_data = font.getTableData("hhea") orelse return MsdfError.MissingTable;
    const hhea = hhea_hmtx.HheaTable.parse(hhea_data) catch return MsdfError.InvalidHheaTable;

    const hmtx_data = font.getTableData("hmtx") orelse return MsdfError.MissingTable;
    const hmtx = hhea_hmtx.HmtxTable.init(hmtx_data, hhea.num_of_long_hor_metrics, maxp.num_glyphs) catch return MsdfError.InvalidHmtxTable;

    // Look up glyph index from codepoint
    const glyph_index = cmap_table.getGlyphIndex(codepoint) catch return MsdfError.InvalidCmapTable;

    // Parse glyph outline - detect CFF vs TrueType
    var shape: contour.Shape = undefined;
    const is_cff = font.findTable("CFF ") != null;

    if (is_cff) {
        // CFF font - use CFF parser
        const cff_table = font.findTable("CFF ").?;
        shape = cff.parseGlyph(
            allocator,
            font.data,
            cff_table.offset,
            glyph_index,
        ) catch return MsdfError.InvalidCffTable;
    } else {
        // TrueType font - use glyf parser
        const loca_table = font.findTable("loca") orelse return MsdfError.MissingTable;
        const glyf_table = font.findTable("glyf") orelse return MsdfError.MissingTable;

        shape = glyf.parseGlyph(
            allocator,
            font.data,
            loca_table.offset,
            glyf_table.offset,
            glyph_index,
            maxp.num_glyphs,
            head.usesLongLocaFormat(),
        ) catch return MsdfError.InvalidGlyfTable;
    }
    defer shape.deinit();

    // Get glyph metrics
    const advance_width = hmtx.getAdvanceWidth(glyph_index) catch return MsdfError.InvalidHmtxTable;
    const left_side_bearing = hmtx.getLeftSideBearing(glyph_index) catch return MsdfError.InvalidHmtxTable;

    // Calculate glyph bounding box
    const shape_bounds = shape.bounds();
    const units_per_em: f64 = @floatFromInt(head.units_per_em);

    // Apply edge coloring for MSDF
    coloring.colorEdgesSimple(&shape);

    // Calculate transform to fit glyph in output size with padding
    const size = options.size;
    const padding = options.padding;

    // Calculate the distance range in font units
    // The range in the output should map to options.range pixels
    const available_size = size - 2 * padding;
    const scale_factor = @as(f64, @floatFromInt(available_size)) / units_per_em;
    const range_in_font_units = options.range / scale_factor;

    // Calculate transform
    const transform = generate.calculateTransform(
        shape_bounds,
        size,
        size,
        padding,
    );

    // Generate MSDF
    var bitmap = generate.generateMsdf(
        allocator,
        shape,
        size,
        size,
        range_in_font_units,
        transform,
    ) catch return MsdfError.OutOfMemory;

    // Apply error correction to fix artifacts where channels disagree
    generate.correctErrors(&bitmap);

    // Calculate metrics (normalized to font units, caller can scale as needed)
    const metrics = GlyphMetrics{
        .advance_width = @as(f32, @floatFromInt(advance_width)) / @as(f32, @floatFromInt(head.units_per_em)),
        .bearing_x = @as(f32, @floatFromInt(left_side_bearing)) / @as(f32, @floatFromInt(head.units_per_em)),
        .bearing_y = @as(f32, @floatCast(shape_bounds.max.y)) / @as(f32, @floatFromInt(head.units_per_em)),
        .width = @as(f32, @floatCast(shape_bounds.width())) / @as(f32, @floatFromInt(head.units_per_em)),
        .height = @as(f32, @floatCast(shape_bounds.height())) / @as(f32, @floatFromInt(head.units_per_em)),
    };

    return MsdfResult{
        .pixels = bitmap.pixels,
        .width = bitmap.width,
        .height = bitmap.height,
        .metrics = metrics,
    };
}

/// Generate an MSDF atlas for multiple glyphs.
///
/// Generates MSDF textures for each character in the options and packs them
/// into a single atlas texture using shelf packing. The atlas is output in
/// RGBA8 format with the RGB channels containing the MSDF data and alpha set to 255.
///
/// Parameters:
/// - allocator: Allocator for output bitmap and intermediate data.
/// - font: The TrueType font to use.
/// - options: Atlas generation options (characters, glyph size, padding, range).
///
/// Returns an AtlasResult containing the atlas texture, dimensions, and glyph map.
/// Caller owns the returned result and must call `deinit()` to free it.
pub fn generateAtlas(
    allocator: std.mem.Allocator,
    font: Font,
    options: AtlasOptions,
) MsdfError!AtlasResult {
    const chars = options.chars;
    const glyph_size = options.glyph_size;

    if (chars.len == 0) {
        // Empty atlas
        const glyphs = std.AutoHashMap(u21, AtlasGlyph).init(allocator);
        return AtlasResult{
            .pixels = &[_]u8{},
            .width = 0,
            .height = 0,
            .glyphs = glyphs,
        };
    }

    // Calculate atlas dimensions using shelf packing
    // We'll use a simple approach: compute the number of columns that gives us
    // a roughly square atlas
    const num_glyphs = chars.len;
    const cols = std.math.sqrt(num_glyphs) + 1;
    const rows = (num_glyphs + cols - 1) / cols;

    const atlas_width: u32 = @intCast(cols * glyph_size);
    const atlas_height: u32 = @intCast(rows * glyph_size);

    // Allocate atlas pixels (RGBA8 format)
    const pixel_count = @as(usize, atlas_width) * @as(usize, atlas_height) * 4;
    const atlas_pixels = allocator.alloc(u8, pixel_count) catch return MsdfError.OutOfMemory;
    errdefer allocator.free(atlas_pixels);

    // Initialize to black with full alpha (outside all glyphs)
    var i: usize = 0;
    while (i < pixel_count) : (i += 4) {
        atlas_pixels[i] = 0; // R
        atlas_pixels[i + 1] = 0; // G
        atlas_pixels[i + 2] = 0; // B
        atlas_pixels[i + 3] = 255; // A
    }

    // Initialize glyph map
    var glyphs = std.AutoHashMap(u21, AtlasGlyph).init(allocator);
    errdefer glyphs.deinit();

    // Generate each glyph and pack into atlas
    var glyph_index: usize = 0;
    for (chars) |char| {
        const codepoint: u21 = char;
        const col = glyph_index % cols;
        const row = glyph_index / cols;

        const x_offset: u32 = @intCast(col * glyph_size);
        const y_offset: u32 = @intCast(row * glyph_size);

        // Generate MSDF for this glyph
        const glyph_result = generateGlyph(allocator, font, codepoint, .{
            .size = glyph_size,
            .padding = options.padding,
            .range = options.range,
        }) catch |err| {
            // Skip glyphs that fail to generate (e.g., missing glyphs)
            if (err == MsdfError.GlyphNotFound) {
                glyph_index += 1;
                continue;
            }
            return err;
        };
        defer {
            var result_copy = glyph_result;
            result_copy.deinit(allocator);
        }

        // Copy glyph pixels to atlas (RGB8 -> RGBA8)
        copyGlyphToAtlas(
            atlas_pixels,
            atlas_width,
            glyph_result.pixels,
            glyph_result.width,
            glyph_result.height,
            x_offset,
            y_offset,
        );

        // Calculate UV coordinates (normalized 0-1)
        const uv_min_x = @as(f32, @floatFromInt(x_offset)) / @as(f32, @floatFromInt(atlas_width));
        const uv_min_y = @as(f32, @floatFromInt(y_offset)) / @as(f32, @floatFromInt(atlas_height));
        const uv_max_x = @as(f32, @floatFromInt(x_offset + glyph_size)) / @as(f32, @floatFromInt(atlas_width));
        const uv_max_y = @as(f32, @floatFromInt(y_offset + glyph_size)) / @as(f32, @floatFromInt(atlas_height));

        // Store glyph info
        glyphs.put(codepoint, AtlasGlyph{
            .uv_min = .{ uv_min_x, uv_min_y },
            .uv_max = .{ uv_max_x, uv_max_y },
            .metrics = glyph_result.metrics,
        }) catch return MsdfError.OutOfMemory;

        glyph_index += 1;
    }

    return AtlasResult{
        .pixels = atlas_pixels,
        .width = atlas_width,
        .height = atlas_height,
        .glyphs = glyphs,
    };
}

/// Copy a glyph's RGB8 pixels to the atlas RGBA8 buffer.
fn copyGlyphToAtlas(
    atlas_pixels: []u8,
    atlas_width: u32,
    glyph_pixels: []const u8,
    glyph_width: u32,
    glyph_height: u32,
    x_offset: u32,
    y_offset: u32,
) void {
    var y: u32 = 0;
    while (y < glyph_height) : (y += 1) {
        var x: u32 = 0;
        while (x < glyph_width) : (x += 1) {
            const glyph_idx = (y * glyph_width + x) * 3;
            const atlas_x = x_offset + x;
            const atlas_y = y_offset + y;
            const atlas_idx = (atlas_y * atlas_width + atlas_x) * 4;

            // Copy RGB from glyph, set A to 255
            atlas_pixels[atlas_idx] = glyph_pixels[glyph_idx]; // R
            atlas_pixels[atlas_idx + 1] = glyph_pixels[glyph_idx + 1]; // G
            atlas_pixels[atlas_idx + 2] = glyph_pixels[glyph_idx + 2]; // B
            atlas_pixels[atlas_idx + 3] = 255; // A
        }
    }
}

test "placeholder" {
    // Placeholder test to verify the module compiles
    const options = GenerateOptions{};
    try std.testing.expectEqual(@as(u32, 48), options.size);
}
