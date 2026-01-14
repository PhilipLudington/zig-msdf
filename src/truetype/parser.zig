//! TrueType font parser.
//!
//! Provides the main `Font` struct for loading and parsing TrueType font files.
//! Supports loading from both files and memory.

const std = @import("std");
const tables = @import("tables.zig");

/// Errors that can occur during font parsing.
pub const ParseError = error{
    InvalidFontData,
    UnsupportedFormat,
    TableNotFound,
    OutOfBounds,
    InvalidGlyph,
    OutOfMemory,
};

/// A parsed TrueType font.
pub const Font = struct {
    allocator: std.mem.Allocator,
    /// Raw font data.
    data: []const u8,
    /// Whether we own the data and should free it on deinit.
    owns_data: bool,
    /// Parsed table directory.
    table_directory: tables.TableDirectory,

    /// Load a font from a file path.
    pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !Font {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const data = try allocator.alloc(u8, stat.size);
        errdefer allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) {
            return ParseError.InvalidFontData;
        }

        return fromMemoryOwned(allocator, data);
    }

    /// Load a font from a byte slice. The font does not take ownership of the data.
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !Font {
        const table_directory = try tables.TableDirectory.parse(data);

        return Font{
            .allocator = allocator,
            .data = data,
            .owns_data = false,
            .table_directory = table_directory,
        };
    }

    /// Load a font from a byte slice that the font takes ownership of.
    fn fromMemoryOwned(allocator: std.mem.Allocator, data: []u8) !Font {
        const table_directory = try tables.TableDirectory.parse(data);

        return Font{
            .allocator = allocator,
            .data = data,
            .owns_data = true,
            .table_directory = table_directory,
        };
    }

    /// Free resources associated with this font.
    pub fn deinit(self: *Font) void {
        if (self.owns_data) {
            self.allocator.free(@constCast(self.data));
        }
        self.* = undefined;
    }

    /// Find a table by its 4-character tag.
    pub fn findTable(self: Font, tag: *const [4]u8) ?tables.TableRecord {
        return self.table_directory.findTable(tag);
    }

    /// Get the raw data for a table.
    pub fn getTableData(self: Font, tag: *const [4]u8) ?[]const u8 {
        const record = self.findTable(tag) orelse return null;
        if (record.offset + record.length > self.data.len) return null;
        return self.data[record.offset .. record.offset + record.length];
    }
};

// ============================================================================
// Big-endian read utilities
// ============================================================================

/// Read a big-endian u16 from a byte slice.
pub fn readU16Big(data: []const u8, offset: usize) ParseError!u16 {
    if (offset + 2 > data.len) return ParseError.OutOfBounds;
    return std.mem.readInt(u16, data[offset..][0..2], .big);
}

/// Read a big-endian u32 from a byte slice.
pub fn readU32Big(data: []const u8, offset: usize) ParseError!u32 {
    if (offset + 4 > data.len) return ParseError.OutOfBounds;
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

/// Read a big-endian i16 from a byte slice.
pub fn readI16Big(data: []const u8, offset: usize) ParseError!i16 {
    if (offset + 2 > data.len) return ParseError.OutOfBounds;
    return std.mem.readInt(i16, data[offset..][0..2], .big);
}

/// Read a big-endian i32 from a byte slice.
pub fn readI32Big(data: []const u8, offset: usize) ParseError!i32 {
    if (offset + 4 > data.len) return ParseError.OutOfBounds;
    return std.mem.readInt(i32, data[offset..][0..4], .big);
}

/// Read a single byte from a slice.
pub fn readU8(data: []const u8, offset: usize) ParseError!u8 {
    if (offset >= data.len) return ParseError.OutOfBounds;
    return data[offset];
}

// ============================================================================
// Tests
// ============================================================================

test "readU16Big" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try std.testing.expectEqual(@as(u16, 0x0102), try readU16Big(&data, 0));
    try std.testing.expectEqual(@as(u16, 0x0203), try readU16Big(&data, 1));
    try std.testing.expectEqual(@as(u16, 0x0304), try readU16Big(&data, 2));
    try std.testing.expectError(ParseError.OutOfBounds, readU16Big(&data, 3));
}

test "readU32Big" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };
    try std.testing.expectEqual(@as(u32, 0x01020304), try readU32Big(&data, 0));
    try std.testing.expectEqual(@as(u32, 0x02030405), try readU32Big(&data, 1));
    try std.testing.expectError(ParseError.OutOfBounds, readU32Big(&data, 2));
}

test "readI16Big" {
    const data = [_]u8{ 0xFF, 0xFE, 0x00, 0x01 };
    try std.testing.expectEqual(@as(i16, -2), try readI16Big(&data, 0));
    try std.testing.expectEqual(@as(i16, 1), try readI16Big(&data, 2));
}
