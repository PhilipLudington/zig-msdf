# Zig MSDF Library Design

A standalone, pure Zig library for generating Multi-channel Signed Distance Fields from TrueType fonts. Zero external dependencies.

## Overview

Extract the MSDF technology from AgentiteZ into a reusable library that:
- Parses TrueType font files natively in Zig
- Generates MSDF textures for text rendering
- Has no C dependencies whatsoever
- Produces output compatible with standard MSDF shaders

## Project Structure

```
zig-msdf/
├── build.zig
├── src/
│   ├── msdf.zig                 # Public API entry point
│   ├── generator/
│   │   ├── math.zig             # Vec2, polynomial solvers
│   │   ├── edge.zig             # Bezier edge segments
│   │   ├── contour.zig          # Shape and contour types
│   │   ├── coloring.zig         # Edge coloring algorithm
│   │   └── generate.zig         # Core MSDF generation
│   └── truetype/
│       ├── parser.zig           # TrueType file parser
│       ├── tables.zig           # Table directory parsing
│       ├── glyf.zig             # Glyph outline extraction
│       ├── cmap.zig             # Character to glyph mapping
│       ├── hhea_hmtx.zig        # Horizontal metrics
│       └── head_maxp.zig        # Font header and limits
└── examples/
    ├── generate_atlas.zig       # Generate a font atlas
    └── single_glyph.zig         # Generate MSDF for one glyph
```

## Public API

```zig
const msdf = @import("msdf");

// Load a font from file or memory
const font = try msdf.Font.fromFile(allocator, "path/to/font.ttf");
defer font.deinit();

// Or from memory
const font = try msdf.Font.fromMemory(allocator, font_bytes);

// Generate MSDF for a single glyph
const result = try msdf.generateGlyph(allocator, font, 'A', .{
    .size = 48,        // Output texture size in pixels
    .padding = 4,      // Padding around glyph
    .range = 4.0,      // Distance field range in pixels
});
defer result.deinit(allocator);

// result.pixels is []u8 in RGB8 format (3 bytes per pixel)
// result.width, result.height are the dimensions
// result.metrics contains advance_width, bearing_x, bearing_y

// Generate an atlas for multiple characters
const atlas = try msdf.generateAtlas(allocator, font, .{
    .chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
    .glyph_size = 48,
    .padding = 4,
    .range = 4.0,
});
defer atlas.deinit(allocator);

// atlas.pixels is the full atlas texture (RGBA8)
// atlas.glyphs is a map of codepoint -> GlyphInfo (uvs, metrics)
```

## Core Types

```zig
pub const Font = struct {
    allocator: std.mem.Allocator,
    data: []const u8,

    // Parsed table offsets
    head: HeadTable,
    maxp: MaxpTable,
    cmap: CmapTable,
    hhea: HheaTable,
    hmtx: HmtxTable,
    loca: LocaTable,
    glyf_offset: u32,

    pub fn fromFile(allocator: Allocator, path: []const u8) !Font;
    pub fn fromMemory(allocator: Allocator, data: []const u8) !Font;
    pub fn deinit(self: *Font) void;

    pub fn getGlyphIndex(self: Font, codepoint: u21) ?u16;
    pub fn getGlyphOutline(self: Font, glyph_index: u16) !Shape;
    pub fn getGlyphMetrics(self: Font, glyph_index: u16) GlyphMetrics;
    pub fn getUnitsPerEm(self: Font) u16;
};

pub const Shape = struct {
    contours: []Contour,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Shape) void;
    pub fn bounds(self: Shape) Bounds;
};

pub const Contour = struct {
    edges: []EdgeSegment,

    pub fn winding(self: Contour) i32;
};

pub const EdgeSegment = union(enum) {
    linear: LinearSegment,
    quadratic: QuadraticSegment,
    cubic: CubicSegment,

    pub fn signedDistance(self: EdgeSegment, point: Vec2) SignedDistance;
    pub fn getColor(self: EdgeSegment) EdgeColor;
    pub fn setColor(self: *EdgeSegment, color: EdgeColor) void;
};

pub const MsdfResult = struct {
    pixels: []u8,          // RGB8 format
    width: u32,
    height: u32,
    metrics: GlyphMetrics,

    pub fn deinit(self: *MsdfResult, allocator: Allocator) void;
};

pub const GlyphMetrics = struct {
    advance_width: f32,    // Horizontal advance (normalized)
    bearing_x: f32,        // Left side bearing
    bearing_y: f32,        // Top bearing from baseline
    width: f32,            // Glyph bounding box width
    height: f32,           // Glyph bounding box height
};

pub const AtlasResult = struct {
    pixels: []u8,          // RGBA8 format
    width: u32,
    height: u32,
    glyphs: std.AutoHashMap(u21, AtlasGlyph),

    pub fn deinit(self: *AtlasResult, allocator: Allocator) void;
};

pub const AtlasGlyph = struct {
    uv_min: [2]f32,
    uv_max: [2]f32,
    metrics: GlyphMetrics,
};
```

## TrueType Parser Implementation

### Required Tables

The parser needs to read these TrueType tables:

| Table | Purpose | Complexity |
|-------|---------|------------|
| `head` | Font header (units_per_em, index format) | Simple |
| `maxp` | Maximum profile (num_glyphs) | Simple |
| `cmap` | Character to glyph index mapping | Medium |
| `hhea` | Horizontal header (ascent, descent) | Simple |
| `hmtx` | Horizontal metrics (advance widths) | Simple |
| `loca` | Glyph location index | Simple |
| `glyf` | Glyph outlines (the actual curves) | Complex |

### Table Directory Parsing (tables.zig)

```zig
pub const TableDirectory = struct {
    sfnt_version: u32,
    num_tables: u16,
    tables: []TableRecord,
};

pub const TableRecord = struct {
    tag: [4]u8,
    checksum: u32,
    offset: u32,
    length: u32,
};

pub fn parse(data: []const u8) !TableDirectory {
    // TrueType files start with:
    // - sfnt_version: 0x00010000 for TrueType
    // - numTables: u16
    // - searchRange, entrySelector, rangeShift: u16 each (skip)
    // - Then numTables TableRecord entries
}

pub fn findTable(dir: TableDirectory, tag: *const [4]u8) ?TableRecord {
    for (dir.tables) |table| {
        if (std.mem.eql(u8, &table.tag, tag)) return table;
    }
    return null;
}
```

### Head Table (head_maxp.zig)

```zig
pub const HeadTable = struct {
    units_per_em: u16,         // Typically 1000 or 2048
    index_to_loc_format: i16,  // 0 = short (u16), 1 = long (u32)
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

pub fn parseHead(data: []const u8, offset: u32) HeadTable {
    // Offsets within head table:
    // 18: unitsPerEm (u16)
    // 36: xMin, yMin, xMax, yMax (i16 each)
    // 50: indexToLocFormat (i16)
}

pub const MaxpTable = struct {
    num_glyphs: u16,
};

pub fn parseMaxp(data: []const u8, offset: u32) MaxpTable {
    // Offset 4: numGlyphs (u16)
}
```

### Cmap Table - Character Mapping (cmap.zig)

The cmap table maps Unicode codepoints to glyph indices. Support these formats:

```zig
pub const CmapTable = struct {
    // Store the offset to the best subtable we found
    subtable_offset: u32,
    format: u16,
};

pub fn parseCmap(data: []const u8, offset: u32) !CmapTable {
    // cmap header:
    // - version: u16 (always 0)
    // - numTables: u16
    // - Then encoding records

    // Each encoding record:
    // - platformID: u16
    // - encodingID: u16
    // - subtableOffset: u32

    // Prefer: platformID=3 (Windows), encodingID=10 (Unicode full)
    // Fallback: platformID=3, encodingID=1 (Unicode BMP)
    // Fallback: platformID=0 (Unicode), any encodingID
}

pub fn getGlyphIndex(cmap: CmapTable, data: []const u8, codepoint: u21) ?u16 {
    return switch (cmap.format) {
        4 => getGlyphIndexFormat4(data, cmap.subtable_offset, codepoint),
        12 => getGlyphIndexFormat12(data, cmap.subtable_offset, codepoint),
        else => null,
    };
}

// Format 4: Segment mapping (most common for BMP characters)
fn getGlyphIndexFormat4(data: []const u8, offset: u32, codepoint: u21) ?u16 {
    // Binary search through segments
    // Each segment: endCode, startCode, idDelta, idRangeOffset
}

// Format 12: Segmented coverage (for full Unicode including emoji)
fn getGlyphIndexFormat12(data: []const u8, offset: u32, codepoint: u21) ?u16 {
    // Groups of: startCharCode, endCharCode, startGlyphID
    // Binary search through groups
}
```

### Horizontal Metrics (hhea_hmtx.zig)

```zig
pub const HheaTable = struct {
    ascent: i16,
    descent: i16,
    line_gap: i16,
    num_of_long_hor_metrics: u16,
};

pub fn parseHhea(data: []const u8, offset: u32) HheaTable {
    // 4: ascent (i16)
    // 6: descent (i16)
    // 8: lineGap (i16)
    // 34: numOfLongHorMetrics (u16)
}

pub const HmtxTable = struct {
    offset: u32,
    num_long_metrics: u16,
};

pub fn getAdvanceWidth(hmtx: HmtxTable, data: []const u8, glyph_index: u16) u16 {
    // Each longHorMetric is 4 bytes: advanceWidth (u16), lsb (i16)
    // After numOfLongHorMetrics entries, remaining glyphs use last advance
    if (glyph_index < hmtx.num_long_metrics) {
        const entry_offset = hmtx.offset + @as(u32, glyph_index) * 4;
        return readU16Big(data, entry_offset);
    } else {
        // Use last entry's advance width
        const last_offset = hmtx.offset + (@as(u32, hmtx.num_long_metrics) - 1) * 4;
        return readU16Big(data, last_offset);
    }
}
```

### Loca Table - Glyph Locations (part of glyf.zig)

```zig
pub fn getGlyphOffset(
    data: []const u8,
    loca_offset: u32,
    glyf_offset: u32,
    glyph_index: u16,
    index_format: i16,
) struct { offset: u32, length: u32 } {
    if (index_format == 0) {
        // Short format: offsets are u16, multiply by 2
        const off1 = readU16Big(data, loca_offset + @as(u32, glyph_index) * 2);
        const off2 = readU16Big(data, loca_offset + @as(u32, glyph_index + 1) * 2);
        return .{
            .offset = glyf_offset + @as(u32, off1) * 2,
            .length = (@as(u32, off2) - @as(u32, off1)) * 2,
        };
    } else {
        // Long format: offsets are u32
        const off1 = readU32Big(data, loca_offset + @as(u32, glyph_index) * 4);
        const off2 = readU32Big(data, loca_offset + @as(u32, glyph_index + 1) * 4);
        return .{
            .offset = glyf_offset + off1,
            .length = off2 - off1,
        };
    }
}
```

### Glyf Table - Glyph Outlines (glyf.zig)

This is the most complex part. Each glyph is either simple or compound.

```zig
pub fn parseGlyph(
    allocator: Allocator,
    data: []const u8,
    offset: u32,
    length: u32,
) !Shape {
    if (length == 0) {
        // Empty glyph (e.g., space)
        return Shape{ .contours = &[_]Contour{}, .allocator = allocator };
    }

    const num_contours = readI16Big(data, offset);

    if (num_contours >= 0) {
        return parseSimpleGlyph(allocator, data, offset, @intCast(num_contours));
    } else {
        return parseCompoundGlyph(allocator, data, offset);
    }
}

fn parseSimpleGlyph(
    allocator: Allocator,
    data: []const u8,
    offset: u32,
    num_contours: u16,
) !Shape {
    // Simple glyph header:
    // 0: numberOfContours (i16) - already read
    // 2: xMin, yMin, xMax, yMax (i16 each) - bounding box
    // 10: endPtsOfContours[numberOfContours] (u16 each)
    // Then: instructionLength (u16)
    // Then: instructions[instructionLength] (skip these)
    // Then: flags[] (variable length, RLE compressed)
    // Then: xCoordinates[] (variable, 1 or 2 bytes each)
    // Then: yCoordinates[] (variable, 1 or 2 bytes each)

    var pos: u32 = offset + 10;

    // Read end points of each contour
    var end_points = try allocator.alloc(u16, num_contours);
    defer allocator.free(end_points);

    for (0..num_contours) |i| {
        end_points[i] = readU16Big(data, pos);
        pos += 2;
    }

    const num_points = if (num_contours > 0) end_points[num_contours - 1] + 1 else 0;

    // Skip instructions
    const instruction_length = readU16Big(data, pos);
    pos += 2 + instruction_length;

    // Parse flags (RLE compressed)
    var flags = try allocator.alloc(u8, num_points);
    defer allocator.free(flags);

    var flag_idx: usize = 0;
    while (flag_idx < num_points) {
        const flag = data[pos];
        pos += 1;
        flags[flag_idx] = flag;
        flag_idx += 1;

        // Check repeat flag (bit 3)
        if (flag & 0x08 != 0) {
            const repeat_count = data[pos];
            pos += 1;
            for (0..repeat_count) |_| {
                flags[flag_idx] = flag;
                flag_idx += 1;
            }
        }
    }

    // Parse X coordinates
    var x_coords = try allocator.alloc(i16, num_points);
    defer allocator.free(x_coords);

    var x: i16 = 0;
    for (0..num_points) |i| {
        const flag = flags[i];
        if (flag & 0x02 != 0) {
            // X is 1 byte
            const dx = data[pos];
            pos += 1;
            if (flag & 0x10 != 0) {
                x += @intCast(dx);  // Positive
            } else {
                x -= @intCast(dx);  // Negative
            }
        } else if (flag & 0x10 == 0) {
            // X is 2 bytes (signed)
            x += readI16Big(data, pos);
            pos += 2;
        }
        // else: X is same as previous (delta = 0)
        x_coords[i] = x;
    }

    // Parse Y coordinates (same logic, different flag bits)
    var y_coords = try allocator.alloc(i16, num_points);
    defer allocator.free(y_coords);

    var y: i16 = 0;
    for (0..num_points) |i| {
        const flag = flags[i];
        if (flag & 0x04 != 0) {
            // Y is 1 byte
            const dy = data[pos];
            pos += 1;
            if (flag & 0x20 != 0) {
                y += @intCast(dy);
            } else {
                y -= @intCast(dy);
            }
        } else if (flag & 0x20 == 0) {
            y += readI16Big(data, pos);
            pos += 2;
        }
        y_coords[i] = y;
    }

    // Convert points to contours with edge segments
    return buildShape(allocator, x_coords, y_coords, flags, end_points);
}

fn buildShape(
    allocator: Allocator,
    x_coords: []i16,
    y_coords: []i16,
    flags: []u8,
    end_points: []u16,
) !Shape {
    // TrueType uses quadratic Beziers only
    // On-curve points (flag bit 0 = 1) are endpoints
    // Off-curve points (flag bit 0 = 0) are control points
    // Two consecutive off-curve points have implicit on-curve between them

    var contours = std.ArrayList(Contour).init(allocator);
    errdefer {
        for (contours.items) |*c| c.deinit();
        contours.deinit();
    }

    var start_idx: usize = 0;
    for (end_points) |end_idx| {
        const contour = try buildContour(
            allocator,
            x_coords[start_idx..end_idx + 1],
            y_coords[start_idx..end_idx + 1],
            flags[start_idx..end_idx + 1],
        );
        try contours.append(contour);
        start_idx = end_idx + 1;
    }

    return Shape{
        .contours = try contours.toOwnedSlice(),
        .allocator = allocator,
    };
}

fn buildContour(
    allocator: Allocator,
    x: []i16,
    y: []i16,
    flags: []u8,
) !Contour {
    var edges = std.ArrayList(EdgeSegment).init(allocator);
    errdefer edges.deinit();

    const n = x.len;
    if (n == 0) return Contour{ .edges = &[_]EdgeSegment{} };

    // Find first on-curve point to start
    var first_on: ?usize = null;
    for (0..n) |i| {
        if (flags[i] & 1 != 0) {
            first_on = i;
            break;
        }
    }

    // Handle all off-curve (rare but possible)
    if (first_on == null) {
        // Create implicit on-curve at midpoint of first two off-curve
        // ... handle this edge case
    }

    var i = first_on.?;
    const start = i;

    while (true) {
        const curr_x = x[i];
        const curr_y = y[i];

        const next_i = (i + 1) % n;
        const next_flag = flags[next_i];
        const next_x = x[next_i];
        const next_y = y[next_i];

        if (next_flag & 1 != 0) {
            // Next is on-curve: linear segment
            try edges.append(.{ .linear = .{
                .p0 = .{ .x = @floatFromInt(curr_x), .y = @floatFromInt(curr_y) },
                .p1 = .{ .x = @floatFromInt(next_x), .y = @floatFromInt(next_y) },
                .color = .white,
            }});
            i = next_i;
        } else {
            // Next is off-curve: quadratic Bezier
            const ctrl_x = next_x;
            const ctrl_y = next_y;

            const after_i = (next_i + 1) % n;
            const after_flag = flags[after_i];

            var end_x: i16 = undefined;
            var end_y: i16 = undefined;

            if (after_flag & 1 != 0) {
                // After is on-curve: use it as endpoint
                end_x = x[after_i];
                end_y = y[after_i];
                i = after_i;
            } else {
                // After is also off-curve: implicit on-curve at midpoint
                end_x = @divTrunc(ctrl_x + x[after_i], 2);
                end_y = @divTrunc(ctrl_y + y[after_i], 2);
                i = next_i;
            }

            try edges.append(.{ .quadratic = .{
                .p0 = .{ .x = @floatFromInt(curr_x), .y = @floatFromInt(curr_y) },
                .p1 = .{ .x = @floatFromInt(ctrl_x), .y = @floatFromInt(ctrl_y) },
                .p2 = .{ .x = @floatFromInt(end_x), .y = @floatFromInt(end_y) },
                .color = .white,
            }});
        }

        if (i == start) break;
    }

    return Contour{ .edges = try edges.toOwnedSlice() };
}

fn parseCompoundGlyph(
    allocator: Allocator,
    data: []const u8,
    offset: u32,
) !Shape {
    // Compound glyphs reference other glyphs with transformations
    // Used for accented characters, ligatures, etc.

    // Header same as simple: numContours (negative), bbox
    var pos: u32 = offset + 10;

    var all_contours = std.ArrayList(Contour).init(allocator);
    errdefer {
        for (all_contours.items) |*c| c.deinit();
        all_contours.deinit();
    }

    while (true) {
        const flags = readU16Big(data, pos);
        pos += 2;
        const glyph_index = readU16Big(data, pos);
        pos += 2;

        // Read transform arguments based on flags
        var arg1: i16 = 0;
        var arg2: i16 = 0;

        if (flags & 0x0001 != 0) {
            // ARG_1_AND_2_ARE_WORDS
            arg1 = readI16Big(data, pos);
            pos += 2;
            arg2 = readI16Big(data, pos);
            pos += 2;
        } else {
            arg1 = @as(i16, @bitCast(@as(u16, data[pos])));
            pos += 1;
            arg2 = @as(i16, @bitCast(@as(u16, data[pos])));
            pos += 1;
        }

        // Read transform matrix if present
        var scale_x: f32 = 1.0;
        var scale_y: f32 = 1.0;
        var scale_01: f32 = 0.0;
        var scale_10: f32 = 0.0;

        if (flags & 0x0008 != 0) {
            // WE_HAVE_A_SCALE
            scale_x = @as(f32, @floatFromInt(readI16Big(data, pos))) / 16384.0;
            scale_y = scale_x;
            pos += 2;
        } else if (flags & 0x0040 != 0) {
            // WE_HAVE_AN_X_AND_Y_SCALE
            scale_x = @as(f32, @floatFromInt(readI16Big(data, pos))) / 16384.0;
            pos += 2;
            scale_y = @as(f32, @floatFromInt(readI16Big(data, pos))) / 16384.0;
            pos += 2;
        } else if (flags & 0x0080 != 0) {
            // WE_HAVE_A_TWO_BY_TWO
            scale_x = @as(f32, @floatFromInt(readI16Big(data, pos))) / 16384.0;
            pos += 2;
            scale_01 = @as(f32, @floatFromInt(readI16Big(data, pos))) / 16384.0;
            pos += 2;
            scale_10 = @as(f32, @floatFromInt(readI16Big(data, pos))) / 16384.0;
            pos += 2;
            scale_y = @as(f32, @floatFromInt(readI16Big(data, pos))) / 16384.0;
            pos += 2;
        }

        // Recursively parse the component glyph
        // Apply transform to all points
        // Add to all_contours

        // (Implementation would call parseGlyph recursively and transform)

        // Check MORE_COMPONENTS flag
        if (flags & 0x0020 == 0) break;
    }

    return Shape{
        .contours = try all_contours.toOwnedSlice(),
        .allocator = allocator,
    };
}
```

## MSDF Generator (from AgentiteZ)

The existing MSDF code from AgentiteZ transfers almost directly:

### math.zig
- `Vec2` struct with add, sub, scale, dot, cross, normalize, distance, lerp
- `SignedDistance` struct with distance and orthogonality
- `solveQuadratic()` and `solveCubic()` for Bezier distance

### edge.zig
- `LinearSegment`, `QuadraticSegment`, `CubicSegment`
- Each has `signedDistance(point: Vec2) -> SignedDistance`
- `EdgeColor` enum: cyan, magenta, yellow, white

### coloring.zig
- `colorEdges(shape: *Shape, angle_threshold: f64)`
- Assigns colors to preserve corners

### generate.zig
```zig
pub fn generateMsdf(
    allocator: Allocator,
    shape: Shape,
    width: u32,
    height: u32,
    range: f64,
    translate: Vec2,
    scale: Vec2,
) ![]u8 {
    const pixels = try allocator.alloc(u8, width * height * 3);
    errdefer allocator.free(pixels);

    for (0..height) |py| {
        for (0..width) |px| {
            const p = Vec2{
                .x = (@as(f64, @floatFromInt(px)) + 0.5 - translate.x) / scale.x,
                .y = (@as(f64, @floatFromInt(py)) + 0.5 - translate.y) / scale.y,
            };

            var min_dist_r = SignedDistance.infinite();
            var min_dist_g = SignedDistance.infinite();
            var min_dist_b = SignedDistance.infinite();

            for (shape.contours) |contour| {
                for (contour.edges) |edge| {
                    const dist = edge.signedDistance(p);
                    const color = edge.getColor();

                    if (color.hasRed() and dist.isCloser(min_dist_r))
                        min_dist_r = dist;
                    if (color.hasGreen() and dist.isCloser(min_dist_g))
                        min_dist_g = dist;
                    if (color.hasBlue() and dist.isCloser(min_dist_b))
                        min_dist_b = dist;
                }
            }

            // Apply winding to determine sign
            const winding = computeWinding(shape, p);
            if (winding != 0) {
                min_dist_r.distance = -@abs(min_dist_r.distance);
                min_dist_g.distance = -@abs(min_dist_g.distance);
                min_dist_b.distance = -@abs(min_dist_b.distance);
            } else {
                min_dist_r.distance = @abs(min_dist_r.distance);
                min_dist_g.distance = @abs(min_dist_g.distance);
                min_dist_b.distance = @abs(min_dist_b.distance);
            }

            const idx = (py * width + px) * 3;
            pixels[idx + 0] = distanceToPixel(min_dist_r.distance, range);
            pixels[idx + 1] = distanceToPixel(min_dist_g.distance, range);
            pixels[idx + 2] = distanceToPixel(min_dist_b.distance, range);
        }
    }

    return pixels;
}

fn distanceToPixel(distance: f64, range: f64) u8 {
    const normalized = 0.5 - distance / (2.0 * range);
    const clamped = std.math.clamp(normalized, 0.0, 1.0);
    return @intFromFloat(clamped * 255.0);
}
```

## Reference Shader

Include a reference GLSL shader for users:

```glsl
// msdf_text.frag
#version 330 core

in vec2 v_texcoord;
in vec4 v_color;

out vec4 frag_color;

uniform sampler2D u_msdf;
uniform float u_pxRange;  // Usually 4.0

float median(vec3 v) {
    return max(min(v.r, v.g), min(max(v.r, v.g), v.b));
}

void main() {
    vec3 sample = texture(u_msdf, v_texcoord).rgb;
    float sigDist = median(sample) - 0.5;

    float w = fwidth(sigDist);
    float opacity = clamp(sigDist / w + 0.5, 0.0, 1.0);

    frag_color = vec4(v_color.rgb, v_color.a * opacity);
}
```

## Implementation Plan

### Phase 1: Project Setup
- [ ] Create repository structure
- [ ] Set up build.zig with library and example targets
- [ ] Copy math utilities from AgentiteZ

### Phase 2: TrueType Parser
- [ ] Table directory parsing
- [ ] head and maxp tables
- [ ] cmap table (format 4 and 12)
- [ ] hhea and hmtx tables
- [ ] loca table
- [ ] Simple glyph parsing (glyf)
- [ ] Compound glyph parsing
- [ ] Test with multiple fonts

### Phase 3: MSDF Generator
- [ ] Port edge.zig (adapt from AgentiteZ)
- [ ] Port contour.zig (remove stb_truetype dependency)
- [ ] Port edge_coloring.zig
- [ ] Port msdf_generator.zig
- [ ] Integrate with new font parser

### Phase 4: High-Level API
- [ ] Font struct with convenient methods
- [ ] Single glyph generation
- [ ] Atlas generation with packing
- [ ] Output to raw bytes (let user handle image encoding)

### Phase 5: Polish
- [ ] Comprehensive tests
- [ ] Example programs
- [ ] Performance optimization (SIMD for distance calculations?)
- [ ] Documentation

## Testing Strategy

1. **Font parsing**: Compare glyph outlines against stb_truetype output
2. **MSDF output**: Compare against msdfgen reference implementation
3. **Visual tests**: Render test strings at various sizes
4. **Font coverage**: Test with:
   - Simple fonts (Roboto, Open Sans)
   - Complex fonts (Noto CJK has compound glyphs)
   - Variable fonts (if supporting)

## Size Estimate

| Component | Lines of Code |
|-----------|---------------|
| TrueType parser | ~800-1,200 |
| MSDF generator (ported) | ~1,600 |
| High-level API | ~300-400 |
| Tests | ~500 |
| **Total** | ~3,200-3,700 |

## Dependencies

**None.** Pure Zig standard library only.

Optional build-time dependencies for examples:
- Image encoding (PPM is trivial, PNG would need stb_image_write or Zig port)
