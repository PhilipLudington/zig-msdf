//! TrueType 'cmap' table parsing.
//!
//! The 'cmap' table maps character codes (Unicode codepoints) to glyph indices.
//! This implementation supports Format 4 (BMP characters) and Format 12 (full Unicode).

const std = @import("std");
const parser = @import("parser.zig");
const readU16Big = parser.readU16Big;
const readU32Big = parser.readU32Big;
const readI16Big = parser.readI16Big;
const ParseError = parser.ParseError;

/// Supported cmap subtable formats.
pub const SubtableFormat = enum(u16) {
    /// Format 4: Segment mapping to delta values (BMP only).
    format_4 = 4,
    /// Format 12: Segmented coverage (full Unicode).
    format_12 = 12,
};

/// The 'cmap' table maps character codes to glyph indices.
pub const CmapTable = struct {
    /// Raw font data.
    data: []const u8,
    /// Offset to the start of the cmap table within the font data.
    table_offset: usize,
    /// Offset to the selected subtable (relative to table start).
    subtable_offset: usize,
    /// Format of the selected subtable.
    format: SubtableFormat,

    /// Platform ID for Unicode.
    pub const PLATFORM_UNICODE: u16 = 0;
    /// Platform ID for Windows.
    pub const PLATFORM_WINDOWS: u16 = 3;
    /// Encoding ID for Unicode BMP (platform 0).
    pub const ENCODING_UNICODE_BMP: u16 = 3;
    /// Encoding ID for Unicode full repertoire (platform 0).
    pub const ENCODING_UNICODE_FULL: u16 = 4;
    /// Encoding ID for Windows Unicode BMP.
    pub const ENCODING_WINDOWS_BMP: u16 = 1;
    /// Encoding ID for Windows Unicode full repertoire.
    pub const ENCODING_WINDOWS_FULL: u16 = 10;

    /// Parse the 'cmap' table and find the best Unicode subtable.
    /// Prefers Format 12 (full Unicode), falls back to Format 4 (BMP).
    pub fn parse(data: []const u8, table_offset: usize) ParseError!CmapTable {
        // cmap header: version (u16), numTables (u16)
        const version = try readU16Big(data, table_offset);
        if (version != 0) return ParseError.InvalidFontData;

        const num_tables = try readU16Big(data, table_offset + 2);

        // Track best subtable found (prefer format 12 over format 4)
        var best_offset: ?usize = null;
        var best_format: ?SubtableFormat = null;

        // Encoding record: platformID (u16), encodingID (u16), offset (u32)
        const ENCODING_RECORD_SIZE: usize = 8;

        var i: u16 = 0;
        while (i < num_tables) : (i += 1) {
            const record_offset = table_offset + 4 + @as(usize, i) * ENCODING_RECORD_SIZE;
            const platform_id = try readU16Big(data, record_offset);
            const encoding_id = try readU16Big(data, record_offset + 2);
            const subtable_offset = try readU32Big(data, record_offset + 4);

            // Check if this is a Unicode subtable we can use
            const is_unicode = isUnicodeSubtable(platform_id, encoding_id);
            if (!is_unicode) continue;

            // Read the subtable format
            const format_offset = table_offset + subtable_offset;
            const format_value = try readU16Big(data, format_offset);

            // Check if we support this format
            if (format_value == 12) {
                // Format 12 is preferred - use it immediately
                best_offset = subtable_offset;
                best_format = .format_12;
                break; // No need to look further
            } else if (format_value == 4 and best_format == null) {
                // Format 4 is acceptable if we haven't found format 12
                best_offset = subtable_offset;
                best_format = .format_4;
            }
        }

        if (best_offset == null or best_format == null) {
            return ParseError.UnsupportedFormat;
        }

        return CmapTable{
            .data = data,
            .table_offset = table_offset,
            .subtable_offset = best_offset.?,
            .format = best_format.?,
        };
    }

    /// Get the glyph index for a Unicode codepoint.
    /// Returns 0 (the .notdef glyph) if the codepoint is not mapped.
    pub fn getGlyphIndex(self: CmapTable, codepoint: u32) ParseError!u16 {
        return switch (self.format) {
            .format_4 => self.getGlyphIndexFormat4(codepoint),
            .format_12 => self.getGlyphIndexFormat12(codepoint),
        };
    }

    /// Format 4: Segment mapping to delta values.
    /// Used for BMP characters (U+0000 to U+FFFF).
    fn getGlyphIndexFormat4(self: CmapTable, codepoint: u32) ParseError!u16 {
        // Format 4 only supports BMP
        if (codepoint > 0xFFFF) return 0;

        const subtable_start = self.table_offset + self.subtable_offset;

        // Format 4 header:
        // format (u16), length (u16), language (u16), segCountX2 (u16),
        // searchRange (u16), entrySelector (u16), rangeShift (u16)
        const seg_count_x2 = try readU16Big(self.data, subtable_start + 6);
        const seg_count = seg_count_x2 / 2;

        // Arrays follow the header:
        // endCode[segCount], reservedPad (u16), startCode[segCount],
        // idDelta[segCount], idRangeOffset[segCount], glyphIdArray[]
        const end_codes_offset = subtable_start + 14;
        const start_codes_offset = end_codes_offset + seg_count_x2 + 2; // +2 for reservedPad
        const id_delta_offset = start_codes_offset + seg_count_x2;
        const id_range_offset_offset = id_delta_offset + seg_count_x2;

        // Binary search for the segment containing the codepoint
        const code: u16 = @intCast(codepoint);
        var low: u16 = 0;
        var high: u16 = seg_count;

        while (low < high) {
            const mid = low + (high - low) / 2;
            const end_code = try readU16Big(self.data, end_codes_offset + @as(usize, mid) * 2);

            if (code > end_code) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        if (low >= seg_count) return 0;

        const segment_index = low;
        const end_code = try readU16Big(self.data, end_codes_offset + @as(usize, segment_index) * 2);
        const start_code = try readU16Big(self.data, start_codes_offset + @as(usize, segment_index) * 2);

        // Check if codepoint is within this segment
        if (code < start_code or code > end_code) return 0;

        const id_delta = try readI16Big(self.data, id_delta_offset + @as(usize, segment_index) * 2);
        const id_range_offset = try readU16Big(self.data, id_range_offset_offset + @as(usize, segment_index) * 2);

        if (id_range_offset == 0) {
            // Use delta directly
            const glyph_index = @as(i32, code) + @as(i32, id_delta);
            return @intCast(@as(u32, @bitCast(glyph_index)) & 0xFFFF);
        } else {
            // Use glyph ID array
            // The offset is from the idRangeOffset entry itself
            const range_offset_pos = id_range_offset_offset + @as(usize, segment_index) * 2;
            const glyph_index_offset = range_offset_pos + id_range_offset + @as(usize, code - start_code) * 2;

            const glyph_index = try readU16Big(self.data, glyph_index_offset);
            if (glyph_index == 0) return 0;

            // Apply delta to glyph index
            const result = @as(i32, glyph_index) + @as(i32, id_delta);
            return @intCast(@as(u32, @bitCast(result)) & 0xFFFF);
        }
    }

    /// Format 12: Segmented coverage.
    /// Supports the full Unicode range (U+0000 to U+10FFFF).
    fn getGlyphIndexFormat12(self: CmapTable, codepoint: u32) ParseError!u16 {
        const subtable_start = self.table_offset + self.subtable_offset;

        // Format 12 header:
        // format (u16), reserved (u16), length (u32), language (u32), numGroups (u32)
        const num_groups = try readU32Big(self.data, subtable_start + 12);

        // Sequential map groups follow the header:
        // startCharCode (u32), endCharCode (u32), startGlyphID (u32)
        const GROUP_SIZE: usize = 12;
        const groups_offset = subtable_start + 16;

        // Binary search for the group containing the codepoint
        var low: u32 = 0;
        var high: u32 = num_groups;

        while (low < high) {
            const mid = low + (high - low) / 2;
            const group_offset = groups_offset + @as(usize, mid) * GROUP_SIZE;
            const end_char_code = try readU32Big(self.data, group_offset + 4);

            if (codepoint > end_char_code) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        if (low >= num_groups) return 0;

        const group_offset = groups_offset + @as(usize, low) * GROUP_SIZE;
        const start_char_code = try readU32Big(self.data, group_offset);
        const end_char_code = try readU32Big(self.data, group_offset + 4);
        const start_glyph_id = try readU32Big(self.data, group_offset + 8);

        // Check if codepoint is within this group
        if (codepoint < start_char_code or codepoint > end_char_code) return 0;

        // Calculate glyph index
        const glyph_index = start_glyph_id + (codepoint - start_char_code);

        // Clamp to u16 (glyph indices are 16-bit)
        if (glyph_index > 0xFFFF) return 0;
        return @intCast(glyph_index);
    }
};

/// Check if a platform/encoding combination represents a Unicode subtable.
fn isUnicodeSubtable(platform_id: u16, encoding_id: u16) bool {
    return switch (platform_id) {
        CmapTable.PLATFORM_UNICODE => switch (encoding_id) {
            CmapTable.ENCODING_UNICODE_BMP, CmapTable.ENCODING_UNICODE_FULL => true,
            0, 1, 2 => true, // Other valid Unicode encodings
            else => false,
        },
        CmapTable.PLATFORM_WINDOWS => switch (encoding_id) {
            CmapTable.ENCODING_WINDOWS_BMP, CmapTable.ENCODING_WINDOWS_FULL => true,
            else => false,
        },
        else => false,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "CmapTable.parse - format 4 subtable" {
    // Build a minimal cmap table with a Format 4 subtable
    var data: [512]u8 = undefined;
    @memset(&data, 0);

    const table_offset: usize = 0;

    // cmap header
    data[0] = 0x00;
    data[1] = 0x00; // version = 0
    data[2] = 0x00;
    data[3] = 0x01; // numTables = 1

    // Encoding record: platform 3 (Windows), encoding 1 (BMP)
    data[4] = 0x00;
    data[5] = 0x03; // platformID = 3
    data[6] = 0x00;
    data[7] = 0x01; // encodingID = 1
    data[8] = 0x00;
    data[9] = 0x00;
    data[10] = 0x00;
    data[11] = 0x0C; // offset = 12

    // Format 4 subtable at offset 12
    const subtable_offset: usize = 12;

    // Format 4 header
    data[subtable_offset + 0] = 0x00;
    data[subtable_offset + 1] = 0x04; // format = 4
    data[subtable_offset + 2] = 0x00;
    data[subtable_offset + 3] = 0x20; // length = 32 (minimal)
    data[subtable_offset + 4] = 0x00;
    data[subtable_offset + 5] = 0x00; // language = 0
    data[subtable_offset + 6] = 0x00;
    data[subtable_offset + 7] = 0x04; // segCountX2 = 4 (2 segments)
    data[subtable_offset + 8] = 0x00;
    data[subtable_offset + 9] = 0x04; // searchRange = 4
    data[subtable_offset + 10] = 0x00;
    data[subtable_offset + 11] = 0x01; // entrySelector = 1
    data[subtable_offset + 12] = 0x00;
    data[subtable_offset + 13] = 0x00; // rangeShift = 0

    // endCode[2]: 'Z' (90), 0xFFFF
    data[subtable_offset + 14] = 0x00;
    data[subtable_offset + 15] = 0x5A; // 'Z' = 90
    data[subtable_offset + 16] = 0xFF;
    data[subtable_offset + 17] = 0xFF; // 0xFFFF (end marker)

    // reservedPad
    data[subtable_offset + 18] = 0x00;
    data[subtable_offset + 19] = 0x00;

    // startCode[2]: 'A' (65), 0xFFFF
    data[subtable_offset + 20] = 0x00;
    data[subtable_offset + 21] = 0x41; // 'A' = 65
    data[subtable_offset + 22] = 0xFF;
    data[subtable_offset + 23] = 0xFF; // 0xFFFF (end marker)

    // idDelta[2]: delta to map 'A'-'Z' to glyphs 1-26, 1 for end marker
    // 'A' (65) should map to glyph 1, so delta = 1 - 65 = -64 = 0xFFC0
    data[subtable_offset + 24] = 0xFF;
    data[subtable_offset + 25] = 0xC0; // -64
    data[subtable_offset + 26] = 0x00;
    data[subtable_offset + 27] = 0x01; // delta = 1 for end marker

    // idRangeOffset[2]: 0, 0 (use delta)
    data[subtable_offset + 28] = 0x00;
    data[subtable_offset + 29] = 0x00;
    data[subtable_offset + 30] = 0x00;
    data[subtable_offset + 31] = 0x00;

    const cmap = try CmapTable.parse(&data, table_offset);
    try std.testing.expectEqual(SubtableFormat.format_4, cmap.format);

    // Test lookups
    try std.testing.expectEqual(@as(u16, 1), try cmap.getGlyphIndex('A')); // 'A' -> 1
    try std.testing.expectEqual(@as(u16, 2), try cmap.getGlyphIndex('B')); // 'B' -> 2
    try std.testing.expectEqual(@as(u16, 26), try cmap.getGlyphIndex('Z')); // 'Z' -> 26
    try std.testing.expectEqual(@as(u16, 0), try cmap.getGlyphIndex('@')); // '@' (64) -> 0 (not mapped)
    try std.testing.expectEqual(@as(u16, 0), try cmap.getGlyphIndex('[')); // '[' (91) -> 0 (not mapped)
}

test "CmapTable.parse - format 12 subtable" {
    // Build a minimal cmap table with a Format 12 subtable
    var data: [512]u8 = undefined;
    @memset(&data, 0);

    const table_offset: usize = 0;

    // cmap header
    data[0] = 0x00;
    data[1] = 0x00; // version = 0
    data[2] = 0x00;
    data[3] = 0x01; // numTables = 1

    // Encoding record: platform 0 (Unicode), encoding 4 (full)
    data[4] = 0x00;
    data[5] = 0x00; // platformID = 0
    data[6] = 0x00;
    data[7] = 0x04; // encodingID = 4 (full repertoire)
    data[8] = 0x00;
    data[9] = 0x00;
    data[10] = 0x00;
    data[11] = 0x0C; // offset = 12

    // Format 12 subtable at offset 12
    const subtable_offset: usize = 12;

    // Format 12 header
    data[subtable_offset + 0] = 0x00;
    data[subtable_offset + 1] = 0x0C; // format = 12
    data[subtable_offset + 2] = 0x00;
    data[subtable_offset + 3] = 0x00; // reserved = 0
    data[subtable_offset + 4] = 0x00;
    data[subtable_offset + 5] = 0x00;
    data[subtable_offset + 6] = 0x00;
    data[subtable_offset + 7] = 0x1C; // length = 28 (header + 1 group)
    data[subtable_offset + 8] = 0x00;
    data[subtable_offset + 9] = 0x00;
    data[subtable_offset + 10] = 0x00;
    data[subtable_offset + 11] = 0x00; // language = 0
    data[subtable_offset + 12] = 0x00;
    data[subtable_offset + 13] = 0x00;
    data[subtable_offset + 14] = 0x00;
    data[subtable_offset + 15] = 0x01; // numGroups = 1

    // Group 0: map emoji range U+1F600-U+1F64F to glyphs 100-179
    // startCharCode = 0x1F600
    data[subtable_offset + 16] = 0x00;
    data[subtable_offset + 17] = 0x01;
    data[subtable_offset + 18] = 0xF6;
    data[subtable_offset + 19] = 0x00;
    // endCharCode = 0x1F64F
    data[subtable_offset + 20] = 0x00;
    data[subtable_offset + 21] = 0x01;
    data[subtable_offset + 22] = 0xF6;
    data[subtable_offset + 23] = 0x4F;
    // startGlyphID = 100
    data[subtable_offset + 24] = 0x00;
    data[subtable_offset + 25] = 0x00;
    data[subtable_offset + 26] = 0x00;
    data[subtable_offset + 27] = 0x64;

    const cmap = try CmapTable.parse(&data, table_offset);
    try std.testing.expectEqual(SubtableFormat.format_12, cmap.format);

    // Test lookups
    try std.testing.expectEqual(@as(u16, 100), try cmap.getGlyphIndex(0x1F600)); // First emoji -> 100
    try std.testing.expectEqual(@as(u16, 101), try cmap.getGlyphIndex(0x1F601)); // Second emoji -> 101
    try std.testing.expectEqual(@as(u16, 179), try cmap.getGlyphIndex(0x1F64F)); // Last emoji -> 179
    try std.testing.expectEqual(@as(u16, 0), try cmap.getGlyphIndex(0x1F5FF)); // Before range -> 0
    try std.testing.expectEqual(@as(u16, 0), try cmap.getGlyphIndex(0x1F650)); // After range -> 0
}

test "CmapTable.parse - prefers format 12 over format 4" {
    // Build a cmap table with both Format 4 and Format 12 subtables
    var data: [512]u8 = undefined;
    @memset(&data, 0);

    const table_offset: usize = 0;

    // cmap header
    data[0] = 0x00;
    data[1] = 0x00; // version = 0
    data[2] = 0x00;
    data[3] = 0x02; // numTables = 2

    // Encoding record 1: platform 3 (Windows), encoding 1 (BMP) -> Format 4
    data[4] = 0x00;
    data[5] = 0x03; // platformID = 3
    data[6] = 0x00;
    data[7] = 0x01; // encodingID = 1
    data[8] = 0x00;
    data[9] = 0x00;
    data[10] = 0x00;
    data[11] = 0x14; // offset = 20

    // Encoding record 2: platform 3 (Windows), encoding 10 (full) -> Format 12
    data[12] = 0x00;
    data[13] = 0x03; // platformID = 3
    data[14] = 0x00;
    data[15] = 0x0A; // encodingID = 10
    data[16] = 0x00;
    data[17] = 0x00;
    data[18] = 0x00;
    data[19] = 0x40; // offset = 64

    // Format 4 subtable at offset 20 (minimal, just to be recognized)
    data[20] = 0x00;
    data[21] = 0x04; // format = 4
    // ... rest can be zeros for this test

    // Format 12 subtable at offset 64
    data[64] = 0x00;
    data[65] = 0x0C; // format = 12
    data[66] = 0x00;
    data[67] = 0x00; // reserved
    data[68] = 0x00;
    data[69] = 0x00;
    data[70] = 0x00;
    data[71] = 0x10; // length = 16 (header only, no groups)
    data[72] = 0x00;
    data[73] = 0x00;
    data[74] = 0x00;
    data[75] = 0x00; // language = 0
    data[76] = 0x00;
    data[77] = 0x00;
    data[78] = 0x00;
    data[79] = 0x00; // numGroups = 0

    const cmap = try CmapTable.parse(&data, table_offset);
    // Should prefer Format 12 even though Format 4 appears first
    try std.testing.expectEqual(SubtableFormat.format_12, cmap.format);
}

test "CmapTable.parse - no unicode subtable" {
    // Build a cmap table with no Unicode subtables
    var data: [32]u8 = undefined;
    @memset(&data, 0);

    // cmap header
    data[0] = 0x00;
    data[1] = 0x00; // version = 0
    data[2] = 0x00;
    data[3] = 0x01; // numTables = 1

    // Encoding record: platform 1 (Macintosh), encoding 0 (Roman)
    data[4] = 0x00;
    data[5] = 0x01; // platformID = 1 (not Unicode or Windows)
    data[6] = 0x00;
    data[7] = 0x00; // encodingID = 0
    data[8] = 0x00;
    data[9] = 0x00;
    data[10] = 0x00;
    data[11] = 0x0C; // offset = 12

    // Some format (Format 0)
    data[12] = 0x00;
    data[13] = 0x00; // format = 0

    try std.testing.expectError(ParseError.UnsupportedFormat, CmapTable.parse(&data, 0));
}

test "isUnicodeSubtable" {
    // Unicode platform
    try std.testing.expect(isUnicodeSubtable(0, 0)); // Default
    try std.testing.expect(isUnicodeSubtable(0, 1)); // 1.1
    try std.testing.expect(isUnicodeSubtable(0, 2)); // ISO/IEC 10646
    try std.testing.expect(isUnicodeSubtable(0, 3)); // BMP
    try std.testing.expect(isUnicodeSubtable(0, 4)); // Full
    try std.testing.expect(!isUnicodeSubtable(0, 100)); // Invalid

    // Windows platform
    try std.testing.expect(isUnicodeSubtable(3, 1)); // BMP
    try std.testing.expect(isUnicodeSubtable(3, 10)); // Full
    try std.testing.expect(!isUnicodeSubtable(3, 0)); // Symbol
    try std.testing.expect(!isUnicodeSubtable(3, 2)); // ShiftJIS

    // Other platforms
    try std.testing.expect(!isUnicodeSubtable(1, 0)); // Macintosh
    try std.testing.expect(!isUnicodeSubtable(2, 0)); // ISO
}
