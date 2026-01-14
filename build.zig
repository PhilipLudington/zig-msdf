const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module
    const msdf_module = b.addModule("msdf", .{
        .root_source_file = b.path("src/msdf.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Example: single glyph
    const single_glyph_exe = b.addExecutable(.{
        .name = "single_glyph",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/single_glyph.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(single_glyph_exe);

    const run_single_glyph = b.addRunArtifact(single_glyph_exe);
    run_single_glyph.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_single_glyph.addArgs(args);
    }

    const single_glyph_step = b.step("single-glyph", "Run the single glyph example");
    single_glyph_step.dependOn(&run_single_glyph.step);

    // Example: generate atlas
    const generate_atlas_exe = b.addExecutable(.{
        .name = "generate_atlas",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/generate_atlas.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(generate_atlas_exe);

    const run_generate_atlas = b.addRunArtifact(generate_atlas_exe);
    run_generate_atlas.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_generate_atlas.addArgs(args);
    }

    const generate_atlas_step = b.step("generate-atlas", "Run the atlas generation example");
    generate_atlas_step.dependOn(&run_generate_atlas.step);

    // Unit tests
    const lib_tests = b.addTest(.{
        .root_module = msdf_module,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
