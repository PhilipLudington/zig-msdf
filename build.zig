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

    // Example: compare_A (comparison tool)
    const compare_a_exe = b.addExecutable(.{
        .name = "compare_a",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/compare_A.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(compare_a_exe);

    const run_compare_a = b.addRunArtifact(compare_a_exe);
    run_compare_a.step.dependOn(b.getInstallStep());

    const compare_a_step = b.step("compare-a", "Run the A comparison example");
    compare_a_step.dependOn(&run_compare_a.step);

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

    // M corner diagnostic tool
    const m_corner_diag_exe = b.addExecutable(.{
        .name = "m_corner_diagnostic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/m_corner_diagnostic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(m_corner_diag_exe);

    const run_m_corner_diag = b.addRunArtifact(m_corner_diag_exe);
    run_m_corner_diag.step.dependOn(b.getInstallStep());
    const m_corner_diag_step = b.step("m-corner-diag", "Debug M corner pixels in detail");
    m_corner_diag_step.dependOn(&run_m_corner_diag.step);

    // MSDF comparison tool
    const compare_msdf_exe = b.addExecutable(.{
        .name = "compare_msdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/compare_msdf.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(compare_msdf_exe);

    const run_compare_msdf = b.addRunArtifact(compare_msdf_exe);
    run_compare_msdf.step.dependOn(b.getInstallStep());
    const compare_msdf_step = b.step("compare-msdf", "Compare zig-msdf output with msdfgen reference");
    compare_msdf_step.dependOn(&run_compare_msdf.step);

    // Pixel debug tool
    const pixel_debug_exe = b.addExecutable(.{
        .name = "pixel_debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/pixel_debug.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(pixel_debug_exe);

    const run_pixel_debug = b.addRunArtifact(pixel_debug_exe);
    run_pixel_debug.step.dependOn(b.getInstallStep());
    const pixel_debug_step = b.step("pixel-debug", "Debug per-channel distances at specific pixels");
    pixel_debug_step.dependOn(&run_pixel_debug.step);

    // Corner debug tool
    const corner_debug_exe = b.addExecutable(.{
        .name = "corner_debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/corner_debug.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(corner_debug_exe);

    const run_corner_debug = b.addRunArtifact(corner_debug_exe);
    run_corner_debug.step.dependOn(b.getInstallStep());
    const corner_debug_step = b.step("corner-debug", "Debug corner pixel distances for M character");
    corner_debug_step.dependOn(&run_corner_debug.step);

    // Debug autoframe tool
    const autoframe_debug_exe = b.addExecutable(.{
        .name = "debug_autoframe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_autoframe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(autoframe_debug_exe);

    const run_autoframe_debug = b.addRunArtifact(autoframe_debug_exe);
    run_autoframe_debug.step.dependOn(b.getInstallStep());
    const autoframe_debug_step = b.step("debug-autoframe", "Debug autoframe transform calculations");
    autoframe_debug_step.dependOn(&run_autoframe_debug.step);

    // Debug edge colors tool
    const edge_colors_exe = b.addExecutable(.{
        .name = "debug_edge_colors",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_edge_colors.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(edge_colors_exe);

    const run_edge_colors = b.addRunArtifact(edge_colors_exe);
    run_edge_colors.step.dependOn(b.getInstallStep());
    const edge_colors_step = b.step("debug-edge-colors", "Debug edge coloring for 'A' glyph");
    edge_colors_step.dependOn(&run_edge_colors.step);

    // Channel diversity test tool
    const channel_diversity_exe = b.addExecutable(.{
        .name = "channel_diversity_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/channel_diversity_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(channel_diversity_exe);

    const run_channel_diversity = b.addRunArtifact(channel_diversity_exe);
    run_channel_diversity.step.dependOn(b.getInstallStep());
    const channel_diversity_step = b.step("channel-diversity", "Test channel diversity for single vs multi-contour glyphs");
    channel_diversity_step.dependOn(&run_channel_diversity.step);

    // Debug: Q character diagnostic
    const q_diag_exe = b.addExecutable(.{
        .name = "q_diagnostic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/Q_diagnostic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(q_diag_exe);

    const run_q_diag = b.addRunArtifact(q_diag_exe);
    run_q_diag.step.dependOn(b.getInstallStep());

    const q_diag_step = b.step("q-diag", "Run Q character diagnostic");
    q_diag_step.dependOn(&run_q_diag.step);

    // Debug scanline algorithm
    const debug_scanline_exe = b.addExecutable(.{
        .name = "debug_scanline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scratch/debug_scanline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_scanline_exe);

    const run_debug_scanline = b.addRunArtifact(debug_scanline_exe);
    run_debug_scanline.step.dependOn(b.getInstallStep());

    const debug_scanline_step = b.step("debug-scanline", "Debug scanline algorithm");
    debug_scanline_step.dependOn(&run_debug_scanline.step);

    // Debug artifact characters
    const debug_artifacts_exe = b.addExecutable(.{
        .name = "debug_artifacts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scratch/debug_artifacts.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_artifacts_exe);

    const run_debug_artifacts = b.addRunArtifact(debug_artifacts_exe);
    run_debug_artifacts.step.dependOn(b.getInstallStep());

    const debug_artifacts_step = b.step("debug-artifacts", "Debug artifact characters");
    debug_artifacts_step.dependOn(&run_debug_artifacts.step);

    // SF Mono full test
    const sfmono_full_test_exe = b.addExecutable(.{
        .name = "sfmono_full_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scratch/sfmono_full_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(sfmono_full_test_exe);

    const run_sfmono_full_test = b.addRunArtifact(sfmono_full_test_exe);
    run_sfmono_full_test.step.dependOn(b.getInstallStep());

    const sfmono_full_test_step = b.step("sfmono-full-test", "Test SF Mono vs Geneva comparison");
    sfmono_full_test_step.dependOn(&run_sfmono_full_test.step);

    // Debug orient algorithm
    const debug_orient_exe = b.addExecutable(.{
        .name = "debug_orient",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scratch/debug_orient.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_orient_exe);

    const run_debug_orient = b.addRunArtifact(debug_orient_exe);
    run_debug_orient.step.dependOn(b.getInstallStep());

    const debug_orient_step = b.step("debug-orient", "Debug orientContours algorithm");
    debug_orient_step.dependOn(&run_debug_orient.step);

    // Debug edge colors
    const debug_colors_exe = b.addExecutable(.{
        .name = "debug_colors",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scratch/debug_colors.zig"),
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

    const debug_colors_step = b.step("debug-colors", "Debug edge colors");
    debug_colors_step.dependOn(&run_debug_colors.step);

    // SF Mono contour diagnostic
    const sfmono_contour_diag_exe = b.addExecutable(.{
        .name = "sfmono_contour_diag",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scratch/sfmono_contour_diag.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(sfmono_contour_diag_exe);

    const run_sfmono_contour_diag = b.addRunArtifact(sfmono_contour_diag_exe);
    run_sfmono_contour_diag.step.dependOn(b.getInstallStep());

    const sfmono_contour_diag_step = b.step("sfmono-contour-diag", "Analyze SF Mono per-contour winding");
    sfmono_contour_diag_step.dependOn(&run_sfmono_contour_diag.step);

    // SF Mono winding test tool
    const sfmono_winding_exe = b.addExecutable(.{
        .name = "test_sfmono_winding",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_sfmono_winding.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(sfmono_winding_exe);

    const run_sfmono_winding = b.addRunArtifact(sfmono_winding_exe);
    run_sfmono_winding.step.dependOn(b.getInstallStep());

    const sfmono_winding_step = b.step("test-sfmono-winding", "Test SF Mono font winding inversion");
    sfmono_winding_step.dependOn(&run_sfmono_winding.step);

    // Debug gap analysis
    const debug_gap_exe = b.addExecutable(.{
        .name = "debug_gap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scratch/debug_gap.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_gap_exe);

    const run_debug_gap = b.addRunArtifact(debug_gap_exe);
    run_debug_gap.step.dependOn(b.getInstallStep());

    const debug_gap_step = b.step("debug-gap", "Debug gap between contours");
    debug_gap_step.dependOn(&run_debug_gap.step);

    // Test artifacts on problematic characters
    const test_artifacts_exe = b.addExecutable(.{
        .name = "test_artifacts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scratch/test_artifacts.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(test_artifacts_exe);

    const run_test_artifacts = b.addRunArtifact(test_artifacts_exe);
    run_test_artifacts.step.dependOn(b.getInstallStep());

    const test_artifacts_step = b.step("test-artifacts", "Test for horizontal artifacts");
    test_artifacts_step.dependOn(&run_test_artifacts.step);

    // Generate SF Mono atlas as PPM
    const gen_atlas_ppm_exe = b.addExecutable(.{
        .name = "gen_atlas_ppm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scratch/gen_atlas_ppm.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(gen_atlas_ppm_exe);

    const run_gen_atlas_ppm = b.addRunArtifact(gen_atlas_ppm_exe);
    run_gen_atlas_ppm.step.dependOn(b.getInstallStep());

    const gen_atlas_ppm_step = b.step("gen-atlas-ppm", "Generate SF Mono atlas as PPM");
    gen_atlas_ppm_step.dependOn(&run_gen_atlas_ppm.step);

    // Test @ character
    const test_at_exe = b.addExecutable(.{
        .name = "test_at",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scratch/test_at.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(test_at_exe);

    const run_test_at = b.addRunArtifact(test_at_exe);
    run_test_at.step.dependOn(b.getInstallStep());

    const test_at_step = b.step("test-at", "Test @ character");
    test_at_step.dependOn(&run_test_at.step);

    // Debug r contours
    const debug_r_exe = b.addExecutable(.{
        .name = "debug_r",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scratch/debug_r_contours.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(debug_r_exe);

    const run_debug_r = b.addRunArtifact(debug_r_exe);
    run_debug_r.step.dependOn(b.getInstallStep());

    const debug_r_step = b.step("debug-r", "Debug r character contours");
    debug_r_step.dependOn(&run_debug_r.step);

    // Check polarity
    const check_polarity_exe = b.addExecutable(.{
        .name = "check_polarity",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scratch/check_polarity.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_module },
            },
        }),
    });
    b.installArtifact(check_polarity_exe);

    const run_check_polarity = b.addRunArtifact(check_polarity_exe);
    run_check_polarity.step.dependOn(b.getInstallStep());

    const check_polarity_step = b.step("check-polarity", "Check MSDF polarity");
    check_polarity_step.dependOn(&run_check_polarity.step);

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
