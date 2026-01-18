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

    // Debug S curvature test
    const s_curvature_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_s_curvature.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });

    const run_s_curvature = b.addRunArtifact(s_curvature_tests);
    const s_curvature_step = b.step("debug-s-curvature", "Debug S character curvature values");
    s_curvature_step.dependOn(&run_s_curvature.step);

    // DejaVu Sans test (uses font from examples repo)
    const dejavu_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/dejavu_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });

    const run_dejavu = b.addRunArtifact(dejavu_tests);
    const dejavu_step = b.step("test-dejavu", "Test DejaVu Sans font S-curves");
    dejavu_step.dependOn(&run_dejavu.step);

    // Detailed artifact analysis test
    const analyze_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/analyze_artifacts.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });

    const run_analyze = b.addRunArtifact(analyze_tests);
    const analyze_step = b.step("analyze-artifacts", "Analyze MSDF artifacts in detail");
    analyze_step.dependOn(&run_analyze.step);

    // Artifact diagnostic tool
    const artifact_diag_exe = b.addExecutable(.{
        .name = "artifact_diagnostic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/artifact_diagnostic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(artifact_diag_exe);

    const run_artifact_diag = b.addRunArtifact(artifact_diag_exe);
    run_artifact_diag.step.dependOn(b.getInstallStep());
    const artifact_diag_step = b.step("artifact-diag", "Run artifact diagnostic tool");
    artifact_diag_step.dependOn(&run_artifact_diag.step);

    // Debug coloring tool
    const debug_coloring_exe = b.addExecutable(.{
        .name = "debug_coloring",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_coloring.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_coloring_exe);

    const run_debug_coloring = b.addRunArtifact(debug_coloring_exe);
    run_debug_coloring.step.dependOn(b.getInstallStep());
    const debug_coloring_step = b.step("debug-coloring", "Debug edge coloring for glyphs");
    debug_coloring_step.dependOn(&run_debug_coloring.step);

    // CFF orientation debug tool
    const cff_orient_debug_exe = b.addExecutable(.{
        .name = "cff_orient_debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cff_orientation_debug.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(cff_orient_debug_exe);

    const run_cff_orient_debug = b.addRunArtifact(cff_orient_debug_exe);
    run_cff_orient_debug.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cff_orient_debug.addArgs(args);
    }

    const cff_orient_debug_step = b.step("cff-orient-debug", "Debug CFF font contour orientation");
    cff_orient_debug_step.dependOn(&run_cff_orient_debug.step);
}
