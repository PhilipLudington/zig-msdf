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

    // Example: CFF font
    const cff_font_exe = b.addExecutable(.{
        .name = "cff_font",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/cff_font.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(cff_font_exe);

    const run_cff_font = b.addRunArtifact(cff_font_exe);
    run_cff_font.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cff_font.addArgs(args);
    }

    const cff_font_step = b.step("cff-font", "Run the CFF font example");
    cff_font_step.dependOn(&run_cff_font.step);

    // Unit tests
    const lib_tests = b.addTest(.{
        .root_module = msdf_module,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);

    // Visual regression tests
    const visual_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/visual_regression_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });

    const run_visual_tests = b.addRunArtifact(visual_tests);
    test_step.dependOn(&run_visual_tests.step);

    // Reference comparison tests (against msdfgen output)
    const reference_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/reference_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });

    const run_reference_tests = b.addRunArtifact(reference_tests);
    test_step.dependOn(&run_reference_tests.step);

    // Render validation tests
    const render_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/render_validation_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });

    const run_render_tests = b.addRunArtifact(render_tests);
    test_step.dependOn(&run_render_tests.step);

    // Multi-font tests
    const multi_font_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/multi_font_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });

    const run_multi_font_tests = b.addRunArtifact(multi_font_tests);
    test_step.dependOn(&run_multi_font_tests.step);

    // SDF properties validation tests
    const sdf_properties_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sdf_properties_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });

    const run_sdf_properties_tests = b.addRunArtifact(sdf_properties_tests);
    test_step.dependOn(&run_sdf_properties_tests.step);

    // Debug inner contour test (separate step)
    const debug_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_inner_contour.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });

    const run_debug_tests = b.addRunArtifact(debug_tests);
    const debug_step = b.step("debug-test", "Run debug inner contour test");
    debug_step.dependOn(&run_debug_tests.step);

    // Debug contour structure test
    const contour_debug_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_contours.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });

    const run_contour_debug = b.addRunArtifact(contour_debug_tests);
    const contour_step = b.step("debug-contours", "Run contour structure debug test");
    contour_step.dependOn(&run_contour_debug.step);
}
