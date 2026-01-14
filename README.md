# zig-msdf

A pure Zig library for generating Multi-channel Signed Distance Fields (MSDF) from OpenType fonts.

## Features

- **TrueType and CFF support**: Works with both TrueType (`.ttf`) and OpenType CFF (`.otf`) fonts
- **Single glyph generation**: Generate MSDF textures for individual characters
- **Atlas generation**: Pack multiple glyphs into a single texture atlas
- **Pure Zig**: No external dependencies, works with the Zig build system
- **Cross-platform**: Compiles for any target Zig supports

## What is MSDF?

Multi-channel Signed Distance Fields are a technique for rendering sharp vector graphics (like text) using GPU texture sampling. Unlike traditional bitmap fonts, MSDF textures can be scaled to any size without losing quality, making them ideal for game development and real-time graphics.

## Installation

Add zig-msdf as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .msdf = .{
        .url = "https://github.com/mrphil/zig-msdf/archive/refs/heads/main.tar.gz",
        .hash = "...", // Use `zig fetch` to get the hash
    },
},
```

Then in your `build.zig`:

```zig
const msdf = b.dependency("msdf", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("msdf", msdf.module("msdf"));
```

## Usage

### Loading a Font

```zig
const msdf = @import("msdf");

// Load from file
var font = try msdf.Font.fromFile(allocator, "path/to/font.ttf");
defer font.deinit();

// Or load from memory
var font = try msdf.Font.fromMemory(allocator, font_data);
defer font.deinit();
```

### Generating a Single Glyph

```zig
var result = try msdf.generateGlyph(allocator, font, 'A', .{
    .size = 48,      // Output texture size in pixels
    .padding = 4,    // Padding around the glyph
    .range = 4.0,    // Distance field range in pixels
});
defer result.deinit(allocator);

// result.pixels contains RGB8 data (3 bytes per pixel)
// result.width and result.height are the texture dimensions
// result.metrics contains glyph metrics (advance, bearing, etc.)
```

### Generating a Font Atlas

```zig
var atlas = try msdf.generateAtlas(allocator, font, .{
    .chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
    .glyph_size = 48,
    .padding = 4,
    .range = 4.0,
});
defer atlas.deinit(allocator);

// atlas.pixels contains RGBA8 data (4 bytes per pixel)
// atlas.width and atlas.height are the atlas dimensions
// atlas.glyphs is a map of codepoint -> AtlasGlyph with UV coordinates
```

### Accessing Glyph Metrics

```zig
// From single glyph result
const metrics = result.metrics;
std.debug.print("Advance: {d}\n", .{metrics.advance_width});
std.debug.print("Bearing: ({d}, {d})\n", .{metrics.bearing_x, metrics.bearing_y});
std.debug.print("Size: {d} x {d}\n", .{metrics.width, metrics.height});

// From atlas
if (atlas.glyphs.get('A')) |glyph| {
    std.debug.print("UV: ({d}, {d}) to ({d}, {d})\n", .{
        glyph.uv_min[0], glyph.uv_min[1],
        glyph.uv_max[0], glyph.uv_max[1],
    });
}
```

## Building

```bash
# Build the library
zig build

# Run tests
zig build test

# Build and run examples
zig build run-single-glyph -- path/to/font.ttf
zig build run-generate-atlas -- path/to/font.ttf
```

## Examples

The `examples/` directory contains working examples:

- **single_glyph.zig**: Generate an MSDF for a single character and output as PPM
- **generate_atlas.zig**: Generate a font atlas and output as PPM with glyph metrics

## API Reference

### Types

| Type | Description |
|------|-------------|
| `Font` | A parsed TrueType/OpenType font |
| `GenerateOptions` | Options for single glyph generation |
| `AtlasOptions` | Options for atlas generation |
| `MsdfResult` | Result of single glyph generation |
| `AtlasResult` | Result of atlas generation |
| `GlyphMetrics` | Metrics for a rendered glyph |
| `AtlasGlyph` | Glyph info in atlas (UV coords + metrics) |

### Functions

| Function | Description |
|----------|-------------|
| `Font.fromFile(allocator, path)` | Load font from file path |
| `Font.fromMemory(allocator, data)` | Load font from byte slice |
| `generateGlyph(allocator, font, codepoint, options)` | Generate MSDF for one glyph |
| `generateAtlas(allocator, font, options)` | Generate MSDF atlas for multiple glyphs |

## Rendering MSDF in Shaders

Here's a basic GLSL fragment shader for rendering MSDF text:

```glsl
uniform sampler2D msdfTexture;
uniform float pxRange; // Distance field range in pixels (e.g., 4.0)

float median(float r, float g, float b) {
    return max(min(r, g), min(max(r, g), b));
}

void main() {
    vec3 sample = texture(msdfTexture, uv).rgb;
    float dist = median(sample.r, sample.g, sample.b);
    float pxDist = pxRange * (dist - 0.5);
    float opacity = clamp(pxDist + 0.5, 0.0, 1.0);
    gl_FragColor = vec4(textColor.rgb, textColor.a * opacity);
}
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

This implementation is based on the MSDF technique developed by Viktor Chlumsky. See the [msdfgen](https://github.com/Chlumsky/msdfgen) project for the original C++ implementation and research paper.
