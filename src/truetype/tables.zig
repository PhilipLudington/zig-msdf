//! TrueType table directory parsing.
//!
//! Handles parsing of the font's table directory, which contains records
//! describing the location and size of each table in the font file.

const std = @import("std");
const parser = @import("parser.zig");
const readU16Big = parser.readU16Big;
const readU32Big = parser.readU32Big;
const ParseError = parser.ParseError;

/// TrueType/OpenType sfnt version tags.
pub const SfntVersion = enum(u32) {
    /// TrueType with glyf outlines (0x00010000).
    true_type = 0x00010000,
    /// TrueType (alternative tag 'true').
    true_type_alt = 0x74727565,
    /// OpenType with CFF outlines.
    open_type_cff = 0x4F54544F,

    pub fn fromU32(value: u32) ?SfntVersion {
        return std.meta.intToEnum(SfntVersion, value) catch null;
    }
};

/// A record describing a single table in the font file.
pub const TableRecord = struct {
    /// 4-byte table tag (e.g., "head", "cmap", "glyf").
    tag: [4]u8,
    /// Checksum for the table.
    checksum: u32,
    /// Offset from the beginning of the font file.
    offset: u32,
    /// Length of the table in bytes.
    length: u32,

    /// Size of a table record in bytes.
    pub const SIZE: usize = 16;

    /// Parse a table record from raw data.
    pub fn parse(data: []const u8, offset: usize) ParseError!TableRecord {
        if (offset + SIZE > data.len) return ParseError.OutOfBounds;

        return TableRecord{
            .tag = data[offset..][0..4].*,
            .checksum = try readU32Big(data, offset + 4),
            .offset = try readU32Big(data, offset + 8),
            .length = try readU32Big(data, offset + 12),
        };
    }

    /// Check if this record matches a given tag.
    pub fn matchesTag(self: TableRecord, tag: *const [4]u8) bool {
        return std.mem.eql(u8, &self.tag, tag);
    }
};

/// The table directory at the beginning of a TrueType/OpenType font file.
pub const TableDirectory = struct {
    /// sfnt version (indicates TrueType or OpenType).
    sfnt_version: SfntVersion,
    /// Number of tables in the font.
    num_tables: u16,
    /// Search range for binary search (not used in our implementation).
    search_range: u16,
    /// Entry selector for binary search.
    entry_selector: u16,
    /// Range shift for binary search.
    range_shift: u16,
    /// Offset to the first table record.
    records_offset: usize,
    /// Raw font data for accessing table records.
    data: []const u8,

    /// Size of the table directory header in bytes.
    pub const HEADER_SIZE: usize = 12;

    /// Parse the table directory from raw font data.
    pub fn parse(data: []const u8) ParseError!TableDirectory {
        if (data.len < HEADER_SIZE) return ParseError.InvalidFontData;

        const sfnt_version_raw = try readU32Big(data, 0);
        const sfnt_version = SfntVersion.fromU32(sfnt_version_raw) orelse {
            return ParseError.UnsupportedFormat;
        };

        const num_tables = try readU16Big(data, 4);
        const search_range = try readU16Big(data, 6);
        const entry_selector = try readU16Big(data, 8);
        const range_shift = try readU16Big(data, 10);

        // Validate that we have enough data for all table records
        const required_size = HEADER_SIZE + @as(usize, num_tables) * TableRecord.SIZE;
        if (data.len < required_size) return ParseError.InvalidFontData;

        return TableDirectory{
            .sfnt_version = sfnt_version,
            .num_tables = num_tables,
            .search_range = search_range,
            .entry_selector = entry_selector,
            .range_shift = range_shift,
            .records_offset = HEADER_SIZE,
            .data = data,
        };
    }

    /// Get the table record at the given index.
    pub fn getRecord(self: TableDirectory, index: u16) ParseError!TableRecord {
        if (index >= self.num_tables) return ParseError.OutOfBounds;
        const offset = self.records_offset + @as(usize, index) * TableRecord.SIZE;
        return TableRecord.parse(self.data, offset);
    }

    /// Find a table by its 4-character tag.
    /// Returns null if the table is not found.
    ///
    /// Note: If a table record cannot be read (e.g., corrupted font data),
    /// that record is skipped and the search continues. This is intentional
    /// to allow partial recovery from minor font corruption.
    pub fn findTable(self: TableDirectory, tag: *const [4]u8) ?TableRecord {
        var i: u16 = 0;
        while (i < self.num_tables) : (i += 1) {
            // Skip records that can't be read - this allows partial recovery
            // from minor font corruption while still finding valid tables
            const record = self.getRecord(i) catch continue;
            if (record.matchesTag(tag)) {
                return record;
            }
        }
        return null;
    }

    /// Iterator for table records.
    pub fn iterator(self: TableDirectory) TableIterator {
        return TableIterator{
            .directory = self,
            .index = 0,
        };
    }
};

/// Iterator over table records in a font.
/// Note: If a table record cannot be read, iteration stops and returns null.
pub const TableIterator = struct {
    directory: TableDirectory,
    index: u16,

    /// Returns the next table record, or null if no more records or on error.
    /// Unlike findTable, iteration stops on error rather than skipping.
    pub fn next(self: *TableIterator) ?TableRecord {
        if (self.index >= self.directory.num_tables) return null;
        const record = self.directory.getRecord(self.index) catch return null;
        self.index += 1;
        return record;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TableRecord.parse" {
    // Create a mock table record
    const data = [_]u8{
        'h', 'e', 'a', 'd', // tag
        0x12, 0x34, 0x56, 0x78, // checksum
        0x00, 0x00, 0x01, 0x00, // offset = 256
        0x00, 0x00, 0x00, 0x36, // length = 54
    };

    const record = try TableRecord.parse(&data, 0);
    try std.testing.expectEqualSlices(u8, "head", &record.tag);
    try std.testing.expectEqual(@as(u32, 0x12345678), record.checksum);
    try std.testing.expectEqual(@as(u32, 256), record.offset);
    try std.testing.expectEqual(@as(u32, 54), record.length);
}

test "TableRecord.matchesTag" {
    const data = [_]u8{
        'c', 'm', 'a', 'p',
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
    };

    const record = try TableRecord.parse(&data, 0);
    try std.testing.expect(record.matchesTag("cmap"));
    try std.testing.expect(!record.matchesTag("head"));
}

test "TableDirectory.parse - valid TrueType header" {
    // Minimal valid TrueType font header with 1 table
    var data: [28]u8 = undefined;

    // sfnt version = 0x00010000 (TrueType)
    data[0..4].* = .{ 0x00, 0x01, 0x00, 0x00 };
    // numTables = 1
    data[4..6].* = .{ 0x00, 0x01 };
    // searchRange = 16
    data[6..8].* = .{ 0x00, 0x10 };
    // entrySelector = 0
    data[8..10].* = .{ 0x00, 0x00 };
    // rangeShift = 0
    data[10..12].* = .{ 0x00, 0x00 };
    // One table record (head)
    data[12..16].* = .{ 'h', 'e', 'a', 'd' };
    data[16..20].* = .{ 0x00, 0x00, 0x00, 0x00 }; // checksum
    data[20..24].* = .{ 0x00, 0x00, 0x00, 0x1C }; // offset = 28
    data[24..28].* = .{ 0x00, 0x00, 0x00, 0x36 }; // length = 54

    const dir = try TableDirectory.parse(&data);
    try std.testing.expectEqual(SfntVersion.true_type, dir.sfnt_version);
    try std.testing.expectEqual(@as(u16, 1), dir.num_tables);
}

test "TableDirectory.findTable" {
    // Create a mock font with 2 tables
    var data: [44]u8 = undefined;

    // Header
    data[0..4].* = .{ 0x00, 0x01, 0x00, 0x00 }; // sfnt version
    data[4..6].* = .{ 0x00, 0x02 }; // numTables = 2
    data[6..8].* = .{ 0x00, 0x20 }; // searchRange
    data[8..10].* = .{ 0x00, 0x01 }; // entrySelector
    data[10..12].* = .{ 0x00, 0x00 }; // rangeShift

    // Table record 1: head
    data[12..16].* = .{ 'h', 'e', 'a', 'd' };
    data[16..20].* = .{ 0x00, 0x00, 0x00, 0x00 };
    data[20..24].* = .{ 0x00, 0x00, 0x00, 0x64 }; // offset = 100
    data[24..28].* = .{ 0x00, 0x00, 0x00, 0x36 }; // length = 54

    // Table record 2: cmap
    data[28..32].* = .{ 'c', 'm', 'a', 'p' };
    data[32..36].* = .{ 0x00, 0x00, 0x00, 0x00 };
    data[36..40].* = .{ 0x00, 0x00, 0x00, 0xC8 }; // offset = 200
    data[40..44].* = .{ 0x00, 0x00, 0x01, 0x00 }; // length = 256

    const dir = try TableDirectory.parse(&data);

    // Find head table
    const head = dir.findTable("head");
    try std.testing.expect(head != null);
    try std.testing.expectEqual(@as(u32, 100), head.?.offset);
    try std.testing.expectEqual(@as(u32, 54), head.?.length);

    // Find cmap table
    const cmap = dir.findTable("cmap");
    try std.testing.expect(cmap != null);
    try std.testing.expectEqual(@as(u32, 200), cmap.?.offset);
    try std.testing.expectEqual(@as(u32, 256), cmap.?.length);

    // Try to find non-existent table
    const glyf = dir.findTable("glyf");
    try std.testing.expect(glyf == null);
}

test "TableDirectory - invalid sfnt version" {
    var data: [12]u8 = undefined;
    data[0..4].* = .{ 0xFF, 0xFF, 0xFF, 0xFF }; // invalid version
    data[4..12].* = .{ 0, 0, 0, 0, 0, 0, 0, 0 };

    try std.testing.expectError(ParseError.UnsupportedFormat, TableDirectory.parse(&data));
}

test "TableDirectory - truncated data" {
    const data = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x00 }; // Only 5 bytes
    try std.testing.expectError(ParseError.InvalidFontData, TableDirectory.parse(&data));
}
