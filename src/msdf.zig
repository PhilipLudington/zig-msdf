//! zig-msdf: A pure Zig library for generating Multi-channel Signed Distance Fields from TrueType fonts.
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
// pub const edge = @import("generator/edge.zig");
// pub const contour = @import("generator/contour.zig");
// pub const coloring = @import("generator/coloring.zig");
// pub const generate = @import("generator/generate.zig");

// TrueType parser modules
pub const truetype_parser = @import("truetype/parser.zig");
pub const truetype_tables = @import("truetype/tables.zig");
// pub const glyf = @import("truetype/glyf.zig");
// pub const cmap = @import("truetype/cmap.zig");
// pub const hhea_hmtx = @import("truetype/hhea_hmtx.zig");
// pub const head_maxp = @import("truetype/head_maxp.zig");

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

/// Generate an MSDF texture for a single glyph.
pub fn generateGlyph(
    _: std.mem.Allocator,
    _: Font,
    _: u21,
    _: GenerateOptions,
) !MsdfResult {
    // TODO: Implement glyph generation
    return error.NotImplemented;
}

/// Generate an MSDF atlas for multiple glyphs.
pub fn generateAtlas(
    _: std.mem.Allocator,
    _: Font,
    _: AtlasOptions,
) !AtlasResult {
    // TODO: Implement atlas generation
    return error.NotImplemented;
}

test "placeholder" {
    // Placeholder test to verify the module compiles
    const options = GenerateOptions{};
    try std.testing.expectEqual(@as(u32, 48), options.size);
}
