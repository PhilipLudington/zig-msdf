//! TrueType 'head' and 'maxp' table parsing.
//!
//! The 'head' table contains global font information such as units per em,
//! bounding box, and the loca table format.
//!
//! The 'maxp' table contains the maximum values for various font properties,
//! most importantly the number of glyphs.

const std = @import("std");
const parser = @import("parser.zig");
const readU16Big = parser.readU16Big;
const readU32Big = parser.readU32Big;
const readI16Big = parser.readI16Big;
const ParseError = parser.ParseError;

/// The 'head' table contains global font information.
pub const HeadTable = struct {
    /// Major version (should be 1).
    major_version: u16,
    /// Minor version (should be 0).
    minor_version: u16,
    /// Font revision (set by font manufacturer).
    font_revision: u32,
    /// Checksum adjustment.
    checksum_adjustment: u32,
    /// Magic number (should be 0x5F0F3CF5).
    magic_number: u32,
    /// Flags.
    flags: u16,
    /// Units per em (typically 1000 or 2048).
    units_per_em: u16,
    /// Created timestamp (seconds since 1904-01-01).
    created: i64,
    /// Modified timestamp (seconds since 1904-01-01).
    modified: i64,
    /// Minimum x for all glyph bounding boxes.
    x_min: i16,
    /// Minimum y for all glyph bounding boxes.
    y_min: i16,
    /// Maximum x for all glyph bounding boxes.
    x_max: i16,
    /// Maximum y for all glyph bounding boxes.
    y_max: i16,
    /// Mac style flags.
    mac_style: u16,
    /// Smallest readable size in pixels.
    lowest_rec_ppem: u16,
    /// Font direction hint (deprecated).
    font_direction_hint: i16,
    /// Index to loc format: 0 for short (16-bit), 1 for long (32-bit).
    index_to_loc_format: i16,
    /// Glyph data format (should be 0).
    glyph_data_format: i16,

    /// Size of the head table in bytes.
    pub const SIZE: usize = 54;

    /// Magic number that should be in the head table.
    pub const MAGIC_NUMBER: u32 = 0x5F0F3CF5;

    /// Parse the 'head' table from raw table data.
    pub fn parse(data: []const u8) ParseError!HeadTable {
        if (data.len < SIZE) return ParseError.InvalidFontData;

        const magic = try readU32Big(data, 12);
        if (magic != MAGIC_NUMBER) return ParseError.InvalidFontData;

        return HeadTable{
            .major_version = try readU16Big(data, 0),
            .minor_version = try readU16Big(data, 2),
            .font_revision = try readU32Big(data, 4),
            .checksum_adjustment = try readU32Big(data, 8),
            .magic_number = magic,
            .flags = try readU16Big(data, 16),
            .units_per_em = try readU16Big(data, 18),
            .created = try readI64Big(data, 20),
            .modified = try readI64Big(data, 28),
            .x_min = try readI16Big(data, 36),
            .y_min = try readI16Big(data, 38),
            .x_max = try readI16Big(data, 40),
            .y_max = try readI16Big(data, 42),
            .mac_style = try readU16Big(data, 44),
            .lowest_rec_ppem = try readU16Big(data, 46),
            .font_direction_hint = try readI16Big(data, 48),
            .index_to_loc_format = try readI16Big(data, 50),
            .glyph_data_format = try readI16Big(data, 52),
        };
    }

    /// Returns true if the loca table uses 32-bit offsets, false for 16-bit.
    pub fn usesLongLocaFormat(self: HeadTable) bool {
        return self.index_to_loc_format == 1;
    }
};

/// The 'maxp' table contains maximum values for various font properties.
pub const MaxpTable = struct {
    /// Table version (0x00010000 for TrueType, 0x00005000 for CFF).
    version: u32,
    /// Number of glyphs in the font.
    num_glyphs: u16,
    /// Maximum points in a non-composite glyph (TrueType only).
    max_points: ?u16,
    /// Maximum contours in a non-composite glyph (TrueType only).
    max_contours: ?u16,
    /// Maximum points in a composite glyph (TrueType only).
    max_composite_points: ?u16,
    /// Maximum contours in a composite glyph (TrueType only).
    max_composite_contours: ?u16,
    /// Maximum zones (1 for no twilight zone, 2 for twilight zone).
    max_zones: ?u16,
    /// Maximum twilight points.
    max_twilight_points: ?u16,
    /// Maximum storage area locations.
    max_storage: ?u16,
    /// Maximum function definitions.
    max_function_defs: ?u16,
    /// Maximum instruction definitions.
    max_instruction_defs: ?u16,
    /// Maximum stack elements.
    max_stack_elements: ?u16,
    /// Maximum size of instructions.
    max_size_of_instructions: ?u16,
    /// Maximum number of components at top level.
    max_component_elements: ?u16,
    /// Maximum levels of component nesting.
    max_component_depth: ?u16,

    /// Minimum size for version 0.5 (CFF).
    pub const MIN_SIZE_CFF: usize = 6;
    /// Size for version 1.0 (TrueType).
    pub const SIZE_TRUETYPE: usize = 32;

    /// Parse the 'maxp' table from raw table data.
    pub fn parse(data: []const u8) ParseError!MaxpTable {
        if (data.len < MIN_SIZE_CFF) return ParseError.InvalidFontData;

        const version = try readU32Big(data, 0);
        const num_glyphs = try readU16Big(data, 4);

        // Version 0.5 (CFF) only has version and numGlyphs
        if (version == 0x00005000) {
            return MaxpTable{
                .version = version,
                .num_glyphs = num_glyphs,
                .max_points = null,
                .max_contours = null,
                .max_composite_points = null,
                .max_composite_contours = null,
                .max_zones = null,
                .max_twilight_points = null,
                .max_storage = null,
                .max_function_defs = null,
                .max_instruction_defs = null,
                .max_stack_elements = null,
                .max_size_of_instructions = null,
                .max_component_elements = null,
                .max_component_depth = null,
            };
        }

        // Version 1.0 (TrueType) has additional fields
        if (data.len < SIZE_TRUETYPE) return ParseError.InvalidFontData;

        return MaxpTable{
            .version = version,
            .num_glyphs = num_glyphs,
            .max_points = try readU16Big(data, 6),
            .max_contours = try readU16Big(data, 8),
            .max_composite_points = try readU16Big(data, 10),
            .max_composite_contours = try readU16Big(data, 12),
            .max_zones = try readU16Big(data, 14),
            .max_twilight_points = try readU16Big(data, 16),
            .max_storage = try readU16Big(data, 18),
            .max_function_defs = try readU16Big(data, 20),
            .max_instruction_defs = try readU16Big(data, 22),
            .max_stack_elements = try readU16Big(data, 24),
            .max_size_of_instructions = try readU16Big(data, 26),
            .max_component_elements = try readU16Big(data, 28),
            .max_component_depth = try readU16Big(data, 30),
        };
    }

    /// Returns true if this is a TrueType font (version 1.0).
    pub fn isTrueType(self: MaxpTable) bool {
        return self.version == 0x00010000;
    }
};

/// Read a big-endian i64 from a byte slice.
fn readI64Big(data: []const u8, offset: usize) ParseError!i64 {
    if (offset + 8 > data.len) return ParseError.OutOfBounds;
    return std.mem.readInt(i64, data[offset..][0..8], .big);
}

// ============================================================================
// Tests
// ============================================================================

test "HeadTable.parse - valid table" {
    var data: [54]u8 = undefined;
    @memset(&data, 0);

    // Version 1.0
    data[0] = 0x00;
    data[1] = 0x01;
    data[2] = 0x00;
    data[3] = 0x00;

    // Magic number at offset 12
    data[12] = 0x5F;
    data[13] = 0x0F;
    data[14] = 0x3C;
    data[15] = 0xF5;

    // Units per em = 2048 (0x0800) at offset 18
    data[18] = 0x08;
    data[19] = 0x00;

    // Bounding box
    // x_min = -100 at offset 36
    data[36] = 0xFF;
    data[37] = 0x9C;
    // y_min = -200 at offset 38
    data[38] = 0xFF;
    data[39] = 0x38;
    // x_max = 1000 at offset 40
    data[40] = 0x03;
    data[41] = 0xE8;
    // y_max = 800 at offset 42
    data[42] = 0x03;
    data[43] = 0x20;

    // index_to_loc_format = 1 (long) at offset 50
    data[50] = 0x00;
    data[51] = 0x01;

    const head = try HeadTable.parse(&data);
    try std.testing.expectEqual(@as(u16, 1), head.major_version);
    try std.testing.expectEqual(@as(u16, 2048), head.units_per_em);
    try std.testing.expectEqual(@as(i16, -100), head.x_min);
    try std.testing.expectEqual(@as(i16, -200), head.y_min);
    try std.testing.expectEqual(@as(i16, 1000), head.x_max);
    try std.testing.expectEqual(@as(i16, 800), head.y_max);
    try std.testing.expectEqual(@as(i16, 1), head.index_to_loc_format);
    try std.testing.expect(head.usesLongLocaFormat());
}

test "HeadTable.parse - invalid magic number" {
    var data: [54]u8 = undefined;
    @memset(&data, 0);
    // Wrong magic number
    data[12] = 0x00;
    data[13] = 0x00;
    data[14] = 0x00;
    data[15] = 0x00;

    try std.testing.expectError(ParseError.InvalidFontData, HeadTable.parse(&data));
}

test "HeadTable.parse - truncated data" {
    const data = [_]u8{ 0x00, 0x01 }; // Only 2 bytes
    try std.testing.expectError(ParseError.InvalidFontData, HeadTable.parse(&data));
}

test "MaxpTable.parse - TrueType version" {
    var data: [32]u8 = undefined;
    @memset(&data, 0);

    // Version 1.0
    data[0] = 0x00;
    data[1] = 0x01;
    data[2] = 0x00;
    data[3] = 0x00;

    // numGlyphs = 500
    data[4] = 0x01;
    data[5] = 0xF4;

    // maxPoints = 100
    data[6] = 0x00;
    data[7] = 0x64;

    // maxContours = 10
    data[8] = 0x00;
    data[9] = 0x0A;

    const maxp = try MaxpTable.parse(&data);
    try std.testing.expectEqual(@as(u32, 0x00010000), maxp.version);
    try std.testing.expectEqual(@as(u16, 500), maxp.num_glyphs);
    try std.testing.expectEqual(@as(u16, 100), maxp.max_points.?);
    try std.testing.expectEqual(@as(u16, 10), maxp.max_contours.?);
    try std.testing.expect(maxp.isTrueType());
}

test "MaxpTable.parse - CFF version" {
    var data: [6]u8 = undefined;

    // Version 0.5
    data[0] = 0x00;
    data[1] = 0x00;
    data[2] = 0x50;
    data[3] = 0x00;

    // numGlyphs = 256
    data[4] = 0x01;
    data[5] = 0x00;

    const maxp = try MaxpTable.parse(&data);
    try std.testing.expectEqual(@as(u32, 0x00005000), maxp.version);
    try std.testing.expectEqual(@as(u16, 256), maxp.num_glyphs);
    try std.testing.expect(maxp.max_points == null);
    try std.testing.expect(!maxp.isTrueType());
}

test "MaxpTable.parse - truncated data" {
    const data = [_]u8{ 0x00, 0x01 }; // Only 2 bytes
    try std.testing.expectError(ParseError.InvalidFontData, MaxpTable.parse(&data));
}
