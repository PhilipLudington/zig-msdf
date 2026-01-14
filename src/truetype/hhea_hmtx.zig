//! TrueType 'hhea' and 'hmtx' table parsing.
//!
//! The 'hhea' table contains horizontal header information including metrics
//! like ascent, descent, and line gap.
//!
//! The 'hmtx' table contains horizontal metrics for each glyph, including
//! advance width and left side bearing.

const std = @import("std");
const parser = @import("parser.zig");
const readU16Big = parser.readU16Big;
const readI16Big = parser.readI16Big;
const ParseError = parser.ParseError;

/// The 'hhea' table contains horizontal header information.
pub const HheaTable = struct {
    /// Major version (should be 1).
    major_version: u16,
    /// Minor version (should be 0).
    minor_version: u16,
    /// Typographic ascent (distance from baseline to top of em square).
    ascent: i16,
    /// Typographic descent (distance from baseline to bottom of em square, negative).
    descent: i16,
    /// Typographic line gap.
    line_gap: i16,
    /// Maximum advance width in the font.
    advance_width_max: u16,
    /// Minimum left side bearing.
    min_left_side_bearing: i16,
    /// Minimum right side bearing.
    min_right_side_bearing: i16,
    /// Maximum extent (max of: lsb + (xMax - xMin)).
    x_max_extent: i16,
    /// Caret slope rise (for slanted fonts).
    caret_slope_rise: i16,
    /// Caret slope run.
    caret_slope_run: i16,
    /// Caret offset for slanted fonts.
    caret_offset: i16,
    // 4 reserved i16 fields (8 bytes)
    /// Metric data format (should be 0).
    metric_data_format: i16,
    /// Number of long horizontal metrics in hmtx table.
    num_of_long_hor_metrics: u16,

    /// Size of the hhea table in bytes.
    pub const SIZE: usize = 36;

    /// Parse the 'hhea' table from raw table data.
    pub fn parse(data: []const u8) ParseError!HheaTable {
        if (data.len < SIZE) return ParseError.InvalidFontData;

        return HheaTable{
            .major_version = try readU16Big(data, 0),
            .minor_version = try readU16Big(data, 2),
            .ascent = try readI16Big(data, 4),
            .descent = try readI16Big(data, 6),
            .line_gap = try readI16Big(data, 8),
            .advance_width_max = try readU16Big(data, 10),
            .min_left_side_bearing = try readI16Big(data, 12),
            .min_right_side_bearing = try readI16Big(data, 14),
            .x_max_extent = try readI16Big(data, 16),
            .caret_slope_rise = try readI16Big(data, 18),
            .caret_slope_run = try readI16Big(data, 20),
            .caret_offset = try readI16Big(data, 22),
            // Skip 4 reserved i16 fields (offsets 24-31)
            .metric_data_format = try readI16Big(data, 32),
            .num_of_long_hor_metrics = try readU16Big(data, 34),
        };
    }

    /// Calculate the line height (ascent - descent + line gap).
    pub fn lineHeight(self: HheaTable) i16 {
        return self.ascent - self.descent + self.line_gap;
    }
};

/// The 'hmtx' table contains horizontal metrics for each glyph.
/// This struct provides access to the metrics data without copying it.
pub const HmtxTable = struct {
    /// Raw table data.
    data: []const u8,
    /// Number of long horizontal metrics (from hhea table).
    num_of_long_hor_metrics: u16,
    /// Total number of glyphs in the font (from maxp table).
    num_glyphs: u16,

    /// Size of a long horizontal metric record (advanceWidth + lsb).
    pub const LONG_METRIC_SIZE: usize = 4;

    /// Create an HmtxTable from raw data.
    /// Requires num_of_long_hor_metrics from hhea table and num_glyphs from maxp table.
    pub fn init(data: []const u8, num_of_long_hor_metrics: u16, num_glyphs: u16) ParseError!HmtxTable {
        // Calculate expected minimum size
        // Long metrics: num_of_long_hor_metrics * 4 bytes each
        // Additional left side bearings: (num_glyphs - num_of_long_hor_metrics) * 2 bytes each
        const long_metrics_size = @as(usize, num_of_long_hor_metrics) * LONG_METRIC_SIZE;
        const additional_lsb_count = if (num_glyphs > num_of_long_hor_metrics)
            num_glyphs - num_of_long_hor_metrics
        else
            0;
        const additional_lsb_size = @as(usize, additional_lsb_count) * 2;
        const min_size = long_metrics_size + additional_lsb_size;

        if (data.len < min_size) return ParseError.InvalidFontData;

        return HmtxTable{
            .data = data,
            .num_of_long_hor_metrics = num_of_long_hor_metrics,
            .num_glyphs = num_glyphs,
        };
    }

    /// Get the advance width for a glyph.
    /// For glyphs beyond num_of_long_hor_metrics, returns the last advance width.
    pub fn getAdvanceWidth(self: HmtxTable, glyph_index: u16) ParseError!u16 {
        if (glyph_index >= self.num_glyphs) return ParseError.InvalidGlyph;

        // For glyphs at or beyond num_of_long_hor_metrics, use the last advance width
        const metric_index = if (glyph_index >= self.num_of_long_hor_metrics)
            self.num_of_long_hor_metrics - 1
        else
            glyph_index;

        const offset = @as(usize, metric_index) * LONG_METRIC_SIZE;
        return readU16Big(self.data, offset);
    }

    /// Get the left side bearing for a glyph.
    pub fn getLeftSideBearing(self: HmtxTable, glyph_index: u16) ParseError!i16 {
        if (glyph_index >= self.num_glyphs) return ParseError.InvalidGlyph;

        if (glyph_index < self.num_of_long_hor_metrics) {
            // LSB is at offset 2 within the long metric record
            const offset = @as(usize, glyph_index) * LONG_METRIC_SIZE + 2;
            return readI16Big(self.data, offset);
        } else {
            // For glyphs beyond num_of_long_hor_metrics, LSB is stored separately
            const long_metrics_size = @as(usize, self.num_of_long_hor_metrics) * LONG_METRIC_SIZE;
            const lsb_index = glyph_index - self.num_of_long_hor_metrics;
            const offset = long_metrics_size + @as(usize, lsb_index) * 2;
            return readI16Big(self.data, offset);
        }
    }

    /// Get both advance width and left side bearing for a glyph.
    pub fn getMetrics(self: HmtxTable, glyph_index: u16) ParseError!struct { advance_width: u16, left_side_bearing: i16 } {
        return .{
            .advance_width = try self.getAdvanceWidth(glyph_index),
            .left_side_bearing = try self.getLeftSideBearing(glyph_index),
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "HheaTable.parse - valid table" {
    var data: [36]u8 = undefined;
    @memset(&data, 0);

    // Version 1.0
    data[0] = 0x00;
    data[1] = 0x01;
    data[2] = 0x00;
    data[3] = 0x00;

    // Ascent = 800 (0x0320)
    data[4] = 0x03;
    data[5] = 0x20;

    // Descent = -200 (0xFF38)
    data[6] = 0xFF;
    data[7] = 0x38;

    // Line gap = 90 (0x005A)
    data[8] = 0x00;
    data[9] = 0x5A;

    // Advance width max = 1000 (0x03E8)
    data[10] = 0x03;
    data[11] = 0xE8;

    // num_of_long_hor_metrics = 256 (0x0100)
    data[34] = 0x01;
    data[35] = 0x00;

    const hhea = try HheaTable.parse(&data);
    try std.testing.expectEqual(@as(u16, 1), hhea.major_version);
    try std.testing.expectEqual(@as(i16, 800), hhea.ascent);
    try std.testing.expectEqual(@as(i16, -200), hhea.descent);
    try std.testing.expectEqual(@as(i16, 90), hhea.line_gap);
    try std.testing.expectEqual(@as(u16, 1000), hhea.advance_width_max);
    try std.testing.expectEqual(@as(u16, 256), hhea.num_of_long_hor_metrics);

    // Line height = 800 - (-200) + 90 = 1090
    try std.testing.expectEqual(@as(i16, 1090), hhea.lineHeight());
}

test "HheaTable.parse - truncated data" {
    const data = [_]u8{ 0x00, 0x01 }; // Only 2 bytes
    try std.testing.expectError(ParseError.InvalidFontData, HheaTable.parse(&data));
}

test "HmtxTable - all glyphs have long metrics" {
    // 3 glyphs, all with long metrics
    var data: [12]u8 = undefined;

    // Glyph 0: advance = 500 (0x01F4), lsb = 50 (0x0032)
    data[0] = 0x01;
    data[1] = 0xF4;
    data[2] = 0x00;
    data[3] = 0x32;

    // Glyph 1: advance = 600 (0x0258), lsb = -10 (0xFFF6)
    data[4] = 0x02;
    data[5] = 0x58;
    data[6] = 0xFF;
    data[7] = 0xF6;

    // Glyph 2: advance = 700 (0x02BC), lsb = 25 (0x0019)
    data[8] = 0x02;
    data[9] = 0xBC;
    data[10] = 0x00;
    data[11] = 0x19;

    const hmtx = try HmtxTable.init(&data, 3, 3);

    try std.testing.expectEqual(@as(u16, 500), try hmtx.getAdvanceWidth(0));
    try std.testing.expectEqual(@as(i16, 50), try hmtx.getLeftSideBearing(0));

    try std.testing.expectEqual(@as(u16, 600), try hmtx.getAdvanceWidth(1));
    try std.testing.expectEqual(@as(i16, -10), try hmtx.getLeftSideBearing(1));

    try std.testing.expectEqual(@as(u16, 700), try hmtx.getAdvanceWidth(2));
    try std.testing.expectEqual(@as(i16, 25), try hmtx.getLeftSideBearing(2));

    // Invalid glyph
    try std.testing.expectError(ParseError.InvalidGlyph, hmtx.getAdvanceWidth(3));
}

test "HmtxTable - glyphs with separate lsb array" {
    // 4 glyphs, but only 2 have long metrics
    // The other 2 share the last advance width and have separate lsb values
    var data: [12]u8 = undefined;

    // Long metrics for glyph 0 and 1
    // Glyph 0: advance = 500, lsb = 50
    data[0] = 0x01;
    data[1] = 0xF4;
    data[2] = 0x00;
    data[3] = 0x32;

    // Glyph 1: advance = 600, lsb = 60
    data[4] = 0x02;
    data[5] = 0x58;
    data[6] = 0x00;
    data[7] = 0x3C;

    // Additional lsb values for glyphs 2 and 3
    // Glyph 2: lsb = 70 (0x0046)
    data[8] = 0x00;
    data[9] = 0x46;

    // Glyph 3: lsb = 80 (0x0050)
    data[10] = 0x00;
    data[11] = 0x50;

    const hmtx = try HmtxTable.init(&data, 2, 4);

    // Glyph 0: normal long metric
    try std.testing.expectEqual(@as(u16, 500), try hmtx.getAdvanceWidth(0));
    try std.testing.expectEqual(@as(i16, 50), try hmtx.getLeftSideBearing(0));

    // Glyph 1: normal long metric
    try std.testing.expectEqual(@as(u16, 600), try hmtx.getAdvanceWidth(1));
    try std.testing.expectEqual(@as(i16, 60), try hmtx.getLeftSideBearing(1));

    // Glyph 2: uses last advance width (600), separate lsb (70)
    try std.testing.expectEqual(@as(u16, 600), try hmtx.getAdvanceWidth(2));
    try std.testing.expectEqual(@as(i16, 70), try hmtx.getLeftSideBearing(2));

    // Glyph 3: uses last advance width (600), separate lsb (80)
    try std.testing.expectEqual(@as(u16, 600), try hmtx.getAdvanceWidth(3));
    try std.testing.expectEqual(@as(i16, 80), try hmtx.getLeftSideBearing(3));
}

test "HmtxTable.getMetrics" {
    var data: [4]u8 = undefined;
    data[0] = 0x01;
    data[1] = 0xF4; // advance = 500
    data[2] = 0x00;
    data[3] = 0x32; // lsb = 50

    const hmtx = try HmtxTable.init(&data, 1, 1);
    const metrics = try hmtx.getMetrics(0);

    try std.testing.expectEqual(@as(u16, 500), metrics.advance_width);
    try std.testing.expectEqual(@as(i16, 50), metrics.left_side_bearing);
}

test "HmtxTable - truncated data" {
    const data = [_]u8{ 0x01, 0xF4 }; // Only 2 bytes, need at least 4
    try std.testing.expectError(ParseError.InvalidFontData, HmtxTable.init(&data, 1, 1));
}
