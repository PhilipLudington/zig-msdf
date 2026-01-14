//! CFF INDEX structure parsing.
//!
//! INDEX is the fundamental array structure in CFF fonts. It stores variable-length
//! objects (strings, charstrings, dictionaries, etc.) with a count, offset size,
//! and offset array followed by the data.
//!
//! Structure:
//!   count (2 bytes) - number of objects
//!   offSize (1 byte) - size of each offset entry (1-4)
//!   offsets (offSize * (count+1) bytes) - offset array (1-indexed, first offset is always 1)
//!   data (variable) - concatenated object data

const std = @import("std");
const parser = @import("../truetype/parser.zig");
const ParseError = parser.ParseError;

/// A parsed CFF INDEX structure.
pub const Index = struct {
    /// Number of objects in the index.
    count: u16,
    /// Size of each offset entry (1-4 bytes).
    off_size: u8,
    /// Raw data containing the entire INDEX (header + offsets + data).
    data: []const u8,
    /// Offset within data where the offset array starts.
    offsets_start: usize,
    /// Offset within data where the actual object data starts.
    data_start: usize,

    /// Parse an INDEX structure from raw data at the given offset.
    /// Returns the parsed Index and the total size consumed.
    pub fn parse(data: []const u8, offset: usize) ParseError!Index {
        if (offset + 2 > data.len) return ParseError.OutOfBounds;

        const count = try parser.readU16Big(data, offset);

        // Empty INDEX (count = 0) has no offSize or offset array
        if (count == 0) {
            return Index{
                .count = 0,
                .off_size = 0,
                .data = data,
                .offsets_start = offset + 2,
                .data_start = offset + 2,
            };
        }

        if (offset + 3 > data.len) return ParseError.OutOfBounds;
        const off_size = try parser.readU8(data, offset + 2);

        if (off_size < 1 or off_size > 4) return ParseError.InvalidFontData;

        const offsets_start = offset + 3;
        const num_offsets = @as(usize, count) + 1;
        const offsets_size = num_offsets * @as(usize, off_size);

        if (offsets_start + offsets_size > data.len) return ParseError.OutOfBounds;

        // Data starts after the offset array
        // The first offset value is always 1 (1-indexed), and offsets are relative to data_start - 1
        const data_start = offsets_start + offsets_size;

        return Index{
            .count = count,
            .off_size = off_size,
            .data = data,
            .offsets_start = offsets_start,
            .data_start = data_start,
        };
    }

    /// Get the total size of this INDEX structure in bytes.
    pub fn totalSize(self: Index) usize {
        if (self.count == 0) {
            return 2; // Just the count field
        }

        // Read the last offset to determine data size
        const last_offset = self.readOffset(self.count) catch return 0;
        // Offsets are 1-indexed, so last_offset - 1 = total data size
        return self.data_start + last_offset - 1 - (self.data_start - self.offsets_start - 3 - @as(usize, self.off_size) * (@as(usize, self.count) + 1));
    }

    /// Calculate the byte size of this INDEX from its starting offset.
    pub fn byteSize(self: Index) usize {
        if (self.count == 0) {
            return 2; // Just the count field
        }

        const last_offset = self.readOffset(self.count) catch return 0;
        // 2 (count) + 1 (offSize) + (count+1)*offSize (offsets) + (last_offset - 1) (data)
        return 3 + (@as(usize, self.count) + 1) * @as(usize, self.off_size) + (last_offset - 1);
    }

    /// Get the byte slice for object at the given index (0-indexed).
    pub fn getObject(self: Index, index: u16) ParseError![]const u8 {
        if (index >= self.count) return ParseError.OutOfBounds;

        const start_offset = try self.readOffset(index);
        const end_offset = try self.readOffset(index + 1);

        if (end_offset < start_offset) return ParseError.InvalidFontData;

        // Offsets are 1-indexed, so subtract 1 to get actual byte position
        const start = self.data_start + start_offset - 1;
        const end = self.data_start + end_offset - 1;

        if (end > self.data.len) return ParseError.OutOfBounds;

        return self.data[start..end];
    }

    /// Read an offset value at the given index in the offset array.
    fn readOffset(self: Index, index: u16) ParseError!usize {
        const pos = self.offsets_start + @as(usize, index) * @as(usize, self.off_size);

        return switch (self.off_size) {
            1 => @as(usize, try parser.readU8(self.data, pos)),
            2 => @as(usize, try parser.readU16Big(self.data, pos)),
            3 => blk: {
                if (pos + 3 > self.data.len) return ParseError.OutOfBounds;
                const b0 = @as(usize, self.data[pos]);
                const b1 = @as(usize, self.data[pos + 1]);
                const b2 = @as(usize, self.data[pos + 2]);
                break :blk (b0 << 16) | (b1 << 8) | b2;
            },
            4 => @as(usize, try parser.readU32Big(self.data, pos)),
            else => return ParseError.InvalidFontData,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Index.parse - empty index" {
    // Empty INDEX: count = 0
    const data = [_]u8{ 0x00, 0x00 };
    const index = try Index.parse(&data, 0);

    try std.testing.expectEqual(@as(u16, 0), index.count);
    try std.testing.expectEqual(@as(usize, 2), index.byteSize());
}

test "Index.parse - single object" {
    // INDEX with 1 object containing "ABC"
    const data = [_]u8{
        0x00, 0x01, // count = 1
        0x01, // offSize = 1
        0x01, 0x04, // offsets: 1, 4 (object is 3 bytes)
        'A',  'B', 'C', // data
    };
    const index = try Index.parse(&data, 0);

    try std.testing.expectEqual(@as(u16, 1), index.count);
    try std.testing.expectEqual(@as(u8, 1), index.off_size);

    const obj = try index.getObject(0);
    try std.testing.expectEqualSlices(u8, "ABC", obj);
}

test "Index.parse - two objects" {
    // INDEX with 2 objects: "AB" and "XYZ"
    const data = [_]u8{
        0x00, 0x02, // count = 2
        0x01, // offSize = 1
        0x01, 0x03, 0x06, // offsets: 1, 3, 6
        'A',  'B', // object 0 (2 bytes)
        'X',  'Y', 'Z', // object 1 (3 bytes)
    };
    const index = try Index.parse(&data, 0);

    try std.testing.expectEqual(@as(u16, 2), index.count);

    const obj0 = try index.getObject(0);
    try std.testing.expectEqualSlices(u8, "AB", obj0);

    const obj1 = try index.getObject(1);
    try std.testing.expectEqualSlices(u8, "XYZ", obj1);
}

test "Index.parse - two-byte offsets" {
    // INDEX with 1 object using 2-byte offsets
    const data = [_]u8{
        0x00, 0x01, // count = 1
        0x02, // offSize = 2
        0x00, 0x01, // offset[0] = 1
        0x00, 0x05, // offset[1] = 5 (object is 4 bytes)
        'T',  'E', 'S', 'T', // data
    };
    const index = try Index.parse(&data, 0);

    try std.testing.expectEqual(@as(u16, 1), index.count);
    try std.testing.expectEqual(@as(u8, 2), index.off_size);

    const obj = try index.getObject(0);
    try std.testing.expectEqualSlices(u8, "TEST", obj);
}

test "Index.parse - out of bounds" {
    const data = [_]u8{ 0x00, 0x01, 0x01 }; // Incomplete INDEX
    try std.testing.expectError(ParseError.OutOfBounds, Index.parse(&data, 0));
}

test "Index.getObject - out of bounds index" {
    const data = [_]u8{
        0x00, 0x01, // count = 1
        0x01, // offSize = 1
        0x01, 0x02, // offsets
        'X', // data
    };
    const index = try Index.parse(&data, 0);

    try std.testing.expectError(ParseError.OutOfBounds, index.getObject(1));
    try std.testing.expectError(ParseError.OutOfBounds, index.getObject(100));
}

test "Index.byteSize" {
    // INDEX with 2 objects totaling 5 bytes of data
    const data = [_]u8{
        0x00, 0x02, // count = 2
        0x01, // offSize = 1
        0x01, 0x03, 0x06, // offsets (3 bytes)
        'A',  'B', 'X', 'Y', 'Z', // data (5 bytes)
    };
    const index = try Index.parse(&data, 0);

    // 2 + 1 + 3 + 5 = 11 bytes
    try std.testing.expectEqual(@as(usize, 11), index.byteSize());
}
