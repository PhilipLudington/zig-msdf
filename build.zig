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

    // SF Mono S debug tool
    const debug_sfmono_s_exe = b.addExecutable(.{
        .name = "debug_sfmono_s",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_sfmono_s.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_sfmono_s_exe);

    const run_debug_sfmono_s = b.addRunArtifact(debug_sfmono_s_exe);
    run_debug_sfmono_s.step.dependOn(b.getInstallStep());
    const debug_sfmono_s_step = b.step("debug-sfmono-s", "Debug SF Mono S character");
    debug_sfmono_s_step.dependOn(&run_debug_sfmono_s.step);

    // Pixel distance debug tool
    const debug_pixel_dist_exe = b.addExecutable(.{
        .name = "debug_pixel_dist",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_pixel_dist.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_pixel_dist_exe);

    const run_debug_pixel_dist = b.addRunArtifact(debug_pixel_dist_exe);
    run_debug_pixel_dist.step.dependOn(b.getInstallStep());
    const debug_pixel_dist_step = b.step("debug-pixel-dist", "Debug pixel distance calculations");
    debug_pixel_dist_step.dependOn(&run_debug_pixel_dist.step);

    // Edge structure debug tool
    const debug_edge_struct_exe = b.addExecutable(.{
        .name = "debug_edge_struct",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_edge_structure.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_edge_struct_exe);

    const run_debug_edge_struct = b.addRunArtifact(debug_edge_struct_exe);
    run_debug_edge_struct.step.dependOn(b.getInstallStep());
    const debug_edge_struct_step = b.step("debug-edge-struct", "Debug edge structure");
    debug_edge_struct_step.dependOn(&run_debug_edge_struct.step);

    // Median artifact debug tool
    const debug_median_exe = b.addExecutable(.{
        .name = "debug_median",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_median_artifacts.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_median_exe);

    const run_debug_median = b.addRunArtifact(debug_median_exe);
    run_debug_median.step.dependOn(b.getInstallStep());
    const debug_median_step = b.step("debug-median", "Debug median artifacts");
    debug_median_step.dependOn(&run_debug_median.step);

    // Colors after orient debug tool
    const debug_colors_exe = b.addExecutable(.{
        .name = "debug_colors",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_colors_after_orient.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_colors_exe);

    const run_debug_colors = b.addRunArtifact(debug_colors_exe);
    run_debug_colors.step.dependOn(b.getInstallStep());
    const debug_colors_step = b.step("debug-colors", "Debug edge colors after orient");
    debug_colors_step.dependOn(&run_debug_colors.step);

    // Channel selection debug tool
    const debug_channel_exe = b.addExecutable(.{
        .name = "debug_channel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_channel_selection.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_channel_exe);

    const run_debug_channel = b.addRunArtifact(debug_channel_exe);
    run_debug_channel.step.dependOn(b.getInstallStep());
    const debug_channel_step = b.step("debug-channel", "Debug channel edge selection");
    debug_channel_step.dependOn(&run_debug_channel.step);

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

    // Edge artifact diagnostic tool
    const edge_artifact_diag_exe = b.addExecutable(.{
        .name = "edge_artifact_diagnostic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/edge_artifact_diagnostic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(edge_artifact_diag_exe);

    const run_edge_artifact_diag = b.addRunArtifact(edge_artifact_diag_exe);
    run_edge_artifact_diag.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_edge_artifact_diag.addArgs(args);
    }

    const edge_artifact_diag_step = b.step("edge-artifact-diag", "Diagnose MSDF edge artifacts");
    edge_artifact_diag_step.dependOn(&run_edge_artifact_diag.step);

    // Interior artifact diagnostic tool
    const interior_artifact_diag_exe = b.addExecutable(.{
        .name = "interior_artifact_diagnostic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/interior_artifact_diagnostic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(interior_artifact_diag_exe);

    const run_interior_artifact_diag = b.addRunArtifact(interior_artifact_diag_exe);
    run_interior_artifact_diag.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_interior_artifact_diag.addArgs(args);
    }

    const interior_artifact_diag_step = b.step("interior-artifact-diag", "Diagnose MSDF interior artifacts");
    interior_artifact_diag_step.dependOn(&run_interior_artifact_diag.step);

    // JetBrains Mono S debug tool
    const debug_jetbrains_s_exe = b.addExecutable(.{
        .name = "debug_jetbrains_s",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_jetbrains_s.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_jetbrains_s_exe);

    const run_debug_jetbrains_s = b.addRunArtifact(debug_jetbrains_s_exe);
    run_debug_jetbrains_s.step.dependOn(b.getInstallStep());

    const debug_jetbrains_s_step = b.step("debug-jetbrains-s", "Debug JetBrains Mono S character edge coloring");
    debug_jetbrains_s_step.dependOn(&run_debug_jetbrains_s.step);

    // Compare MSDF tool
    const compare_msdf_exe = b.addExecutable(.{
        .name = "compare_msdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/compare_msdf.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(compare_msdf_exe);

    const run_compare_msdf = b.addRunArtifact(compare_msdf_exe);
    run_compare_msdf.step.dependOn(b.getInstallStep());

    const compare_msdf_step = b.step("compare-msdf", "Compare zig-msdf and msdfgen output");
    compare_msdf_step.dependOn(&run_compare_msdf.step);

    // Debug pixel tool
    const debug_pixel_exe = b.addExecutable(.{
        .name = "debug_pixel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_pixel.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_pixel_exe);

    const run_debug_pixel = b.addRunArtifact(debug_pixel_exe);
    run_debug_pixel.step.dependOn(b.getInstallStep());

    const debug_pixel_step = b.step("debug-pixel", "Debug per-pixel distance calculations");
    debug_pixel_step.dependOn(&run_debug_pixel.step);

    // Debug S coloring
    const debug_s_coloring_exe = b.addExecutable(.{
        .name = "debug_s_coloring",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_s_coloring.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_s_coloring_exe);

    const run_debug_s_coloring = b.addRunArtifact(debug_s_coloring_exe);
    run_debug_s_coloring.step.dependOn(b.getInstallStep());

    const debug_s_coloring_step = b.step("debug-s-coloring", "Debug S character edge coloring");
    debug_s_coloring_step.dependOn(&run_debug_s_coloring.step);
}
