//! CFF DICT structure parsing.
//!
//! DICT is a compact representation of key-value pairs in CFF fonts.
//! It consists of operands (numbers) followed by operators (keys).
//!
//! Number encoding:
//!   32-246:     single byte, value = b0 - 139 (range: -107 to 107)
//!   247-250:    two bytes, value = (b0-247)*256 + b1 + 108 (range: 108 to 1131)
//!   251-254:    two bytes, value = -(b0-251)*256 - b1 - 108 (range: -1131 to -108)
//!   28:         three bytes, signed i16 big-endian
//!   29:         five bytes, signed i32 big-endian
//!   30:         real number in BCD format
//!
//! Operators:
//!   0-21:       single-byte operators
//!   12 xx:      two-byte operators (escape byte 12)

const std = @import("std");
const parser = @import("../truetype/parser.zig");
const ParseError = parser.ParseError;

/// Top DICT operators.
pub const TopDictOp = enum(u16) {
    version = 0,
    notice = 1,
    full_name = 2,
    family_name = 3,
    weight = 4,
    font_bbox = 5,
    unique_id = 13,
    xuid = 14,
    charset = 15,
    encoding = 16,
    char_strings = 17,
    private = 18,
    // Two-byte operators (12 xx)
    is_fixed_pitch = 12 << 8 | 1,
    italic_angle = 12 << 8 | 2,
    underline_position = 12 << 8 | 3,
    underline_thickness = 12 << 8 | 4,
    paint_type = 12 << 8 | 5,
    charstring_type = 12 << 8 | 6,
    font_matrix = 12 << 8 | 7,
    stroke_width = 12 << 8 | 8,
    synthetic_base = 12 << 8 | 20,
    post_script = 12 << 8 | 21,
    base_font_name = 12 << 8 | 22,
    base_font_blend = 12 << 8 | 23,
    ros = 12 << 8 | 30, // CIDFont operators
    cid_font_version = 12 << 8 | 31,
    cid_font_revision = 12 << 8 | 32,
    cid_font_type = 12 << 8 | 33,
    cid_count = 12 << 8 | 34,
    uid_base = 12 << 8 | 35,
    fd_array = 12 << 8 | 36,
    fd_select = 12 << 8 | 37,
    font_name = 12 << 8 | 38,
    _,
};

/// Private DICT operators.
pub const PrivateDictOp = enum(u16) {
    blue_values = 6,
    other_blues = 7,
    family_blues = 8,
    family_other_blues = 9,
    std_hw = 10,
    std_vw = 11,
    subrs = 19,
    default_width_x = 20,
    nominal_width_x = 21,
    // Two-byte operators
    blue_scale = 12 << 8 | 9,
    blue_shift = 12 << 8 | 10,
    blue_fuzz = 12 << 8 | 11,
    stem_snap_h = 12 << 8 | 12,
    stem_snap_v = 12 << 8 | 13,
    force_bold = 12 << 8 | 14,
    language_group = 12 << 8 | 17,
    expansion_factor = 12 << 8 | 18,
    initial_random_seed = 12 << 8 | 19,
    _,
};

/// Parsed Top DICT values.
pub const TopDict = struct {
    /// Offset to CharStrings INDEX (required).
    char_strings_offset: u32 = 0,
    /// Offset to charset data (default 0 = ISOAdobe).
    charset_offset: u32 = 0,
    /// Encoding offset (default 0 = Standard).
    encoding_offset: u32 = 0,
    /// Private DICT size and offset.
    private_size: u32 = 0,
    private_offset: u32 = 0,
    /// Font bounding box.
    font_bbox: [4]f64 = .{ 0, 0, 0, 0 },
    /// CharString type (1 or 2, default 2).
    charstring_type: u8 = 2,
    /// Font matrix (default identity scaled by 0.001).
    font_matrix: [6]f64 = .{ 0.001, 0, 0, 0.001, 0, 0 },
    /// CID font FDArray offset (for CID-keyed fonts).
    fd_array_offset: u32 = 0,
    /// CID font FDSelect offset.
    fd_select_offset: u32 = 0,
    /// Is this a CID-keyed font?
    is_cid: bool = false,
};

/// Parsed Private DICT values.
pub const PrivateDict = struct {
    /// Offset to local Subrs INDEX (relative to Private DICT start).
    subrs_offset: ?u32 = null,
    /// Default width for glyphs (default 0).
    default_width_x: f64 = 0,
    /// Nominal width for glyphs (default 0).
    nominal_width_x: f64 = 0,
};

/// Maximum operand stack size for DICT parsing.
const MAX_OPERAND_STACK = 48;

/// Parse a Top DICT from raw bytes.
pub fn parseTopDict(data: []const u8) ParseError!TopDict {
    var result = TopDict{};
    var operand_stack: [MAX_OPERAND_STACK]f64 = undefined;
    var stack_top: usize = 0;
    var offset: usize = 0;

    while (offset < data.len) {
        const b0 = data[offset];

        if (isOperator(b0)) {
            // Read operator and process
            const op = readOperator(data, &offset) catch break;

            switch (@as(TopDictOp, @enumFromInt(op))) {
                .char_strings => {
                    if (stack_top >= 1) {
                        result.char_strings_offset = @intFromFloat(operand_stack[0]);
                    }
                },
                .charset => {
                    if (stack_top >= 1) {
                        result.charset_offset = @intFromFloat(operand_stack[0]);
                    }
                },
                .encoding => {
                    if (stack_top >= 1) {
                        result.encoding_offset = @intFromFloat(operand_stack[0]);
                    }
                },
                .private => {
                    if (stack_top >= 2) {
                        result.private_size = @intFromFloat(operand_stack[0]);
                        result.private_offset = @intFromFloat(operand_stack[1]);
                    }
                },
                .font_bbox => {
                    if (stack_top >= 4) {
                        result.font_bbox = .{
                            operand_stack[0],
                            operand_stack[1],
                            operand_stack[2],
                            operand_stack[3],
                        };
                    }
                },
                .charstring_type => {
                    if (stack_top >= 1) {
                        result.charstring_type = @intFromFloat(operand_stack[0]);
                    }
                },
                .font_matrix => {
                    if (stack_top >= 6) {
                        result.font_matrix = .{
                            operand_stack[0],
                            operand_stack[1],
                            operand_stack[2],
                            operand_stack[3],
                            operand_stack[4],
                            operand_stack[5],
                        };
                    }
                },
                .fd_array => {
                    if (stack_top >= 1) {
                        result.fd_array_offset = @intFromFloat(operand_stack[0]);
                    }
                },
                .fd_select => {
                    if (stack_top >= 1) {
                        result.fd_select_offset = @intFromFloat(operand_stack[0]);
                    }
                },
                .ros => {
                    result.is_cid = true;
                },
                else => {},
            }
            stack_top = 0;
        } else {
            // Read operand
            if (stack_top >= MAX_OPERAND_STACK) return ParseError.InvalidFontData;
            operand_stack[stack_top] = try parseOperand(data, &offset);
            stack_top += 1;
        }
    }

    return result;
}

/// Parse a Private DICT from raw bytes.
pub fn parsePrivateDict(data: []const u8) ParseError!PrivateDict {
    var result = PrivateDict{};
    var operand_stack: [MAX_OPERAND_STACK]f64 = undefined;
    var stack_top: usize = 0;
    var offset: usize = 0;

    while (offset < data.len) {
        const b0 = data[offset];

        if (isOperator(b0)) {
            const op = readOperator(data, &offset) catch break;

            switch (@as(PrivateDictOp, @enumFromInt(op))) {
                .subrs => {
                    if (stack_top >= 1) {
                        result.subrs_offset = @intFromFloat(operand_stack[0]);
                    }
                },
                .default_width_x => {
                    if (stack_top >= 1) {
                        result.default_width_x = operand_stack[0];
                    }
                },
                .nominal_width_x => {
                    if (stack_top >= 1) {
                        result.nominal_width_x = operand_stack[0];
                    }
                },
                else => {},
            }
            stack_top = 0;
        } else {
            if (stack_top >= MAX_OPERAND_STACK) return ParseError.InvalidFontData;
            operand_stack[stack_top] = try parseOperand(data, &offset);
            stack_top += 1;
        }
    }

    return result;
}

/// Check if a byte is an operator (not an operand).
fn isOperator(b: u8) bool {
    // Operators are 0-21 (except 12 which is escape), operands start at 28
    return b <= 21;
}

/// Read an operator (possibly two-byte).
fn readOperator(data: []const u8, offset: *usize) ParseError!u16 {
    if (offset.* >= data.len) return ParseError.OutOfBounds;

    const b0 = data[offset.*];
    offset.* += 1;

    if (b0 == 12) {
        // Two-byte operator
        if (offset.* >= data.len) return ParseError.OutOfBounds;
        const b1 = data[offset.*];
        offset.* += 1;
        return (@as(u16, 12) << 8) | @as(u16, b1);
    }

    return @as(u16, b0);
}

/// Parse an operand (number) from DICT data.
pub fn parseOperand(data: []const u8, offset: *usize) ParseError!f64 {
    if (offset.* >= data.len) return ParseError.OutOfBounds;

    const b0 = data[offset.*];
    offset.* += 1;

    // Integer encoding
    if (b0 >= 32 and b0 <= 246) {
        // Single byte: value = b0 - 139
        return @as(f64, @floatFromInt(@as(i16, b0) - 139));
    } else if (b0 >= 247 and b0 <= 250) {
        // Two bytes positive: value = (b0-247)*256 + b1 + 108
        if (offset.* >= data.len) return ParseError.OutOfBounds;
        const b1 = data[offset.*];
        offset.* += 1;
        const value = (@as(i32, b0) - 247) * 256 + @as(i32, b1) + 108;
        return @as(f64, @floatFromInt(value));
    } else if (b0 >= 251 and b0 <= 254) {
        // Two bytes negative: value = -(b0-251)*256 - b1 - 108
        if (offset.* >= data.len) return ParseError.OutOfBounds;
        const b1 = data[offset.*];
        offset.* += 1;
        const value = -(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108;
        return @as(f64, @floatFromInt(value));
    } else if (b0 == 28) {
        // Three bytes: signed i16 big-endian
        if (offset.* + 2 > data.len) return ParseError.OutOfBounds;
        const value = std.mem.readInt(i16, data[offset.*..][0..2], .big);
        offset.* += 2;
        return @as(f64, @floatFromInt(value));
    } else if (b0 == 29) {
        // Five bytes: signed i32 big-endian
        if (offset.* + 4 > data.len) return ParseError.OutOfBounds;
        const value = std.mem.readInt(i32, data[offset.*..][0..4], .big);
        offset.* += 4;
        return @as(f64, @floatFromInt(value));
    } else if (b0 == 30) {
        // Real number in BCD format
        return parseRealNumber(data, offset);
    }

    return ParseError.InvalidFontData;
}

/// Parse a BCD-encoded real number.
fn parseRealNumber(data: []const u8, offset: *usize) ParseError!f64 {
    var result: f64 = 0;
    var fraction_digits: i32 = 0;
    var in_fraction = false;
    var is_negative = false;
    var exponent: i32 = 0;
    var exp_negative = false;
    var in_exponent = false;

    while (offset.* < data.len) {
        const byte = data[offset.*];
        offset.* += 1;

        // Process high nibble then low nibble
        const nibbles = [2]u4{ @truncate(byte >> 4), @truncate(byte & 0x0F) };

        for (nibbles) |nibble| {
            switch (nibble) {
                0...9 => {
                    if (in_exponent) {
                        exponent = exponent * 10 + @as(i32, nibble);
                    } else if (in_fraction) {
                        result = result + @as(f64, @floatFromInt(nibble)) * std.math.pow(f64, 10.0, @as(f64, @floatFromInt(-fraction_digits)));
                        fraction_digits += 1;
                    } else {
                        result = result * 10.0 + @as(f64, @floatFromInt(nibble));
                    }
                },
                0xa => {
                    // Decimal point
                    in_fraction = true;
                    fraction_digits = 1;
                },
                0xb => {
                    // Positive exponent
                    in_exponent = true;
                },
                0xc => {
                    // Negative exponent
                    in_exponent = true;
                    exp_negative = true;
                },
                0xd => {
                    // Reserved
                },
                0xe => {
                    // Minus sign
                    is_negative = true;
                },
                0xf => {
                    // End of number
                    if (is_negative) result = -result;
                    if (in_exponent) {
                        if (exp_negative) exponent = -exponent;
                        result = result * std.math.pow(f64, 10.0, @as(f64, @floatFromInt(exponent)));
                    }
                    return result;
                },
            }
        }
    }

    return ParseError.InvalidFontData;
}

// ============================================================================
// Tests
// ============================================================================

test "parseOperand - single byte positive" {
    // Value 0: encoded as 139
    const data = [_]u8{139};
    var offset: usize = 0;
    const value = try parseOperand(&data, &offset);
    try std.testing.expectApproxEqAbs(@as(f64, 0), value, 0.001);
}

test "parseOperand - single byte negative" {
    // Value -107: encoded as 32
    const data = [_]u8{32};
    var offset: usize = 0;
    const value = try parseOperand(&data, &offset);
    try std.testing.expectApproxEqAbs(@as(f64, -107), value, 0.001);
}

test "parseOperand - single byte positive max" {
    // Value 107: encoded as 246
    const data = [_]u8{246};
    var offset: usize = 0;
    const value = try parseOperand(&data, &offset);
    try std.testing.expectApproxEqAbs(@as(f64, 107), value, 0.001);
}

test "parseOperand - two bytes positive" {
    // Value 108: encoded as 247, 0
    const data = [_]u8{ 247, 0 };
    var offset: usize = 0;
    const value = try parseOperand(&data, &offset);
    try std.testing.expectApproxEqAbs(@as(f64, 108), value, 0.001);
}

test "parseOperand - two bytes positive larger" {
    // Value 1000: (b0-247)*256 + b1 + 108 = 1000
    // 1000 - 108 = 892 = (b0-247)*256 + b1
    // 892 = 3*256 + 124, so b0 = 250, b1 = 124
    const data = [_]u8{ 250, 124 };
    var offset: usize = 0;
    const value = try parseOperand(&data, &offset);
    try std.testing.expectApproxEqAbs(@as(f64, 1000), value, 0.001);
}

test "parseOperand - two bytes negative" {
    // Value -108: encoded as 251, 0
    const data = [_]u8{ 251, 0 };
    var offset: usize = 0;
    const value = try parseOperand(&data, &offset);
    try std.testing.expectApproxEqAbs(@as(f64, -108), value, 0.001);
}

test "parseOperand - three bytes signed i16" {
    // Value 1000: encoded as 28, 0x03, 0xE8
    const data = [_]u8{ 28, 0x03, 0xE8 };
    var offset: usize = 0;
    const value = try parseOperand(&data, &offset);
    try std.testing.expectApproxEqAbs(@as(f64, 1000), value, 0.001);
}

test "parseOperand - three bytes signed i16 negative" {
    // Value -1000: encoded as 28, 0xFC, 0x18
    const data = [_]u8{ 28, 0xFC, 0x18 };
    var offset: usize = 0;
    const value = try parseOperand(&data, &offset);
    try std.testing.expectApproxEqAbs(@as(f64, -1000), value, 0.001);
}

test "parseOperand - five bytes signed i32" {
    // Value 100000: encoded as 29, 0x00, 0x01, 0x86, 0xA0
    const data = [_]u8{ 29, 0x00, 0x01, 0x86, 0xA0 };
    var offset: usize = 0;
    const value = try parseOperand(&data, &offset);
    try std.testing.expectApproxEqAbs(@as(f64, 100000), value, 0.001);
}

test "parseOperand - real number simple" {
    // Value 0.5: encoded as 30, 0x0A, 0x5F (0 . 5 END)
    const data = [_]u8{ 30, 0x0A, 0x5F };
    var offset: usize = 0;
    const value = try parseOperand(&data, &offset);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), value, 0.001);
}

test "parseTopDict - basic" {
    // Simple Top DICT with just CharStrings offset
    // 1000 (29, 0x00, 0x00, 0x03, 0xE8) followed by operator 17 (char_strings)
    const data = [_]u8{
        29,   0x00, 0x00, 0x03, 0xE8, // operand: 1000
        17, // operator: char_strings
    };
    const dict = try parseTopDict(&data);
    try std.testing.expectEqual(@as(u32, 1000), dict.char_strings_offset);
}

test "parseTopDict - private dict" {
    // Private DICT with size 100 at offset 2000
    // 100 (encoded), 2000 (encoded), operator 18
    const data = [_]u8{
        // 100: (b0-247)*256 + b1 + 108 = 100, so 100-108 = -8 -> use single byte: 139-100+100 = 139+(-8) doesn't work
        // Actually 100 = 139 + 100 - 139 = needs encoding. 100 is in range -107..107? No, 100 is positive.
        // 32-246 encodes -107 to 107. So 100 is encoded as 139 + 100 = 239
        239, // 100
        // 2000: needs 3-byte encoding. 28, high, low where value = i16
        28,   0x07, 0xD0, // 2000
        18, // operator: private
    };
    const dict = try parseTopDict(&data);
    try std.testing.expectEqual(@as(u32, 100), dict.private_size);
    try std.testing.expectEqual(@as(u32, 2000), dict.private_offset);
}

test "parsePrivateDict - subrs and widths" {
    // Private DICT with subrs at 500, default_width 600, nominal_width 700
    const data = [_]u8{
        // 500: 28, 0x01, 0xF4
        28,   0x01, 0xF4, // 500
        19, // subrs
        // 600: 28, 0x02, 0x58
        28,   0x02, 0x58, // 600
        20, // default_width_x
        // 700: 28, 0x02, 0xBC
        28,   0x02, 0xBC, // 700
        21, // nominal_width_x
    };
    const dict = try parsePrivateDict(&data);
    try std.testing.expectEqual(@as(u32, 500), dict.subrs_offset.?);
    try std.testing.expectApproxEqAbs(@as(f64, 600), dict.default_width_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 700), dict.nominal_width_x, 0.001);
}
