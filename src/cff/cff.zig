//! CFF (Compact Font Format) table parser.
//!
//! CFF is an alternative to TrueType outlines used in OpenType fonts.
//! It uses cubic Bezier curves and stores glyph outlines as CharString
//! bytecode programs.
//!
//! CFF Table Structure:
//!   Header (4 bytes)
//!   Name INDEX
//!   Top DICT INDEX
//!   String INDEX
//!   Global Subr INDEX
//!   [CharStrings INDEX at offset from Top DICT]
//!   [Private DICT at offset from Top DICT]
//!   [Local Subr INDEX at offset from Private DICT]

const std = @import("std");
const Allocator = std.mem.Allocator;

const parser = @import("../truetype/parser.zig");
const ParseError = parser.ParseError;

const index_mod = @import("index.zig");
const Index = index_mod.Index;

const dict_mod = @import("dict.zig");
const TopDict = dict_mod.TopDict;
const PrivateDict = dict_mod.PrivateDict;

const charstring_mod = @import("charstring.zig");
const Interpreter = charstring_mod.Interpreter;

const contour_mod = @import("../generator/contour.zig");
const Shape = contour_mod.Shape;

/// CFF table header.
pub const CffHeader = struct {
    major: u8,
    minor: u8,
    hdr_size: u8,
    off_size: u8,
};

/// Parsed CFF table.
pub const CffTable = struct {
    /// Raw CFF table data.
    data: []const u8,
    /// Parsed header.
    header: CffHeader,
    /// Top DICT values.
    top_dict: TopDict,
    /// Private DICT values.
    private_dict: PrivateDict,
    /// Global subroutines INDEX.
    global_subrs: ?Index,
    /// Local subroutines INDEX.
    local_subrs: ?Index,
    /// CharStrings INDEX.
    char_strings: Index,

    /// Parse a CFF table from raw data.
    pub fn parse(data: []const u8) ParseError!CffTable {
        if (data.len < 4) return ParseError.InvalidFontData;

        // Parse header
        const header = CffHeader{
            .major = data[0],
            .minor = data[1],
            .hdr_size = data[2],
            .off_size = data[3],
        };

        // Validate version (we support CFF version 1.x)
        if (header.major != 1) return ParseError.UnsupportedFormat;

        var offset: usize = header.hdr_size;

        // Parse Name INDEX (skip it, we don't need font names)
        const name_index = try Index.parse(data, offset);
        offset += name_index.byteSize();

        // Parse Top DICT INDEX
        const top_dict_index = try Index.parse(data, offset);
        offset += top_dict_index.byteSize();

        // Parse the first (and usually only) Top DICT
        if (top_dict_index.count == 0) return ParseError.InvalidFontData;
        const top_dict_data = try top_dict_index.getObject(0);
        const top_dict = try dict_mod.parseTopDict(top_dict_data);

        // Validate required fields
        if (top_dict.char_strings_offset == 0) return ParseError.InvalidFontData;

        // Parse String INDEX (skip it, we don't need custom strings)
        const string_index = try Index.parse(data, offset);
        offset += string_index.byteSize();

        // Parse Global Subr INDEX
        var global_subrs: ?Index = null;
        if (offset < data.len) {
            const gs_index = try Index.parse(data, offset);
            if (gs_index.count > 0) {
                global_subrs = gs_index;
            }
        }

        // Parse CharStrings INDEX
        const char_strings = try Index.parse(data, top_dict.char_strings_offset);

        // Parse Private DICT and Local Subrs
        var private_dict = PrivateDict{};
        var local_subrs: ?Index = null;

        if (top_dict.private_size > 0 and top_dict.private_offset > 0) {
            const private_start = top_dict.private_offset;
            const private_end = private_start + top_dict.private_size;

            if (private_end <= data.len) {
                const private_data = data[private_start..private_end];
                private_dict = try dict_mod.parsePrivateDict(private_data);

                // Parse Local Subrs if present
                if (private_dict.subrs_offset) |subrs_off| {
                    const local_subrs_offset = private_start + subrs_off;
                    if (local_subrs_offset < data.len) {
                        const ls_index = try Index.parse(data, local_subrs_offset);
                        if (ls_index.count > 0) {
                            local_subrs = ls_index;
                        }
                    }
                }
            }
        }

        return CffTable{
            .data = data,
            .header = header,
            .top_dict = top_dict,
            .private_dict = private_dict,
            .global_subrs = global_subrs,
            .local_subrs = local_subrs,
            .char_strings = char_strings,
        };
    }

    /// Get the CharString data for a glyph.
    pub fn getCharString(self: CffTable, glyph_index: u16) ParseError![]const u8 {
        return self.char_strings.getObject(glyph_index);
    }

    /// Get the number of glyphs in this CFF font.
    pub fn glyphCount(self: CffTable) u16 {
        return self.char_strings.count;
    }
};

/// Parse a glyph from CFF data and return its outline as a Shape.
/// This is the CFF equivalent of glyf.parseGlyph().
pub fn parseGlyph(
    allocator: Allocator,
    data: []const u8,
    cff_offset: usize,
    glyph_index: u16,
) ParseError!Shape {
    // Get CFF table data
    const cff_data = data[cff_offset..];

    // Parse CFF table structure
    const cff = try CffTable.parse(cff_data);

    // Check glyph index bounds
    if (glyph_index >= cff.char_strings.count) {
        return ParseError.InvalidGlyph;
    }

    // Get CharString for this glyph
    const charstring_data = try cff.getCharString(glyph_index);

    // Empty charstring = space or similar
    if (charstring_data.len == 0) {
        return Shape.init(allocator);
    }

    // Interpret the CharString
    var interpreter = Interpreter.init(allocator);
    errdefer interpreter.deinit();

    const shape = interpreter.interpret(
        charstring_data,
        cff.global_subrs,
        cff.local_subrs,
        cff.private_dict.default_width_x,
        cff.private_dict.nominal_width_x,
    ) catch |err| {
        // Convert CharString errors to ParseError
        return switch (err) {
            charstring_mod.CharStringError.OutOfMemory => ParseError.OutOfMemory,
            else => ParseError.InvalidGlyph,
        };
    };

    return shape;
}

/// Check if a font has CFF outlines by looking for the CFF table.
pub fn hasCffOutlines(font_data: []const u8) bool {
    // Quick check: look for "OTTO" signature (OpenType with CFF)
    if (font_data.len >= 4) {
        if (std.mem.eql(u8, font_data[0..4], "OTTO")) {
            return true;
        }
    }
    return false;
}

// Re-export sub-modules for direct access if needed
pub const index = index_mod;
pub const dict = dict_mod;
pub const charstring = charstring_mod;

// ============================================================================
// Tests
// ============================================================================

test "CffHeader parsing" {
    // Minimal CFF header
    const data = [_]u8{
        1,    0, 4, 1, // Header: major=1, minor=0, hdrSize=4, offSize=1
        0x00, 0x00, // Empty Name INDEX (count=0)
        0x00, 0x00, // Empty Top DICT INDEX (count=0)
    };

    // This should fail because Top DICT INDEX is empty
    try std.testing.expectError(ParseError.InvalidFontData, CffTable.parse(&data));
}

test "hasCffOutlines" {
    const otto_sig = [_]u8{ 'O', 'T', 'T', 'O', 0, 0, 0, 0 };
    try std.testing.expect(hasCffOutlines(&otto_sig));

    const truetype_sig = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0 };
    try std.testing.expect(!hasCffOutlines(&truetype_sig));
}
