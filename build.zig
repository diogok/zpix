const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module
    const stbz_mod = b.addModule("stbz", .{
        .root_source_file = b.path("src/stbz.zig"),
    });

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "stbz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("stbz", stbz_mod);
    exe.root_module.addIncludePath(b.path("reference"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("reference/ref_impl.c"),
        .flags = &.{"-std=c99"},
    });
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run_cmd.step);

    // Unit tests for stbz library
    const unit_tests = b.addTest(.{
        .name = "stbz-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stbz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // JPEG unit tests (behavior, edge cases, no C dependency)
    const jpeg_unit_tests = b.addTest(.{
        .name = "jpeg-unit-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_jpeg_unit.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    jpeg_unit_tests.root_module.addImport("stbz", stbz_mod);
    const run_jpeg_unit_tests = b.addRunArtifact(jpeg_unit_tests);

    // Error handling tests (corrupt/invalid files)
    const error_tests = b.addTest(.{
        .name = "error-handling-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_error_handling.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    error_tests.root_module.addImport("stbz", stbz_mod);
    const run_error_tests = b.addRunArtifact(error_tests);

    // Comparison tests (Zig vs C reference)
    const compare_tests = b.addTest(.{
        .name = "compare-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_png.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    compare_tests.root_module.addImport("stbz", stbz_mod);
    compare_tests.root_module.addIncludePath(b.path("reference"));
    compare_tests.root_module.addCSourceFile(.{
        .file = b.path("reference/ref_impl.c"),
        .flags = &.{"-std=c99"},
    });
    compare_tests.root_module.link_libc = true;

    const run_compare_tests = b.addRunArtifact(compare_tests);

    // JPEG comparison tests (Zig vs C reference)
    const jpeg_tests = b.addTest(.{
        .name = "jpeg-compare-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_jpeg.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    jpeg_tests.root_module.addImport("stbz", stbz_mod);
    jpeg_tests.root_module.addIncludePath(b.path("reference"));
    jpeg_tests.root_module.addCSourceFile(.{
        .file = b.path("reference/ref_impl.c"),
        .flags = &.{"-std=c99"},
    });
    jpeg_tests.root_module.link_libc = true;

    const run_jpeg_tests = b.addRunArtifact(jpeg_tests);

    // Separate test steps for better organization
    const test_step = b.step("test", "Run unit tests (fast, no C dependencies)");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_jpeg_unit_tests.step);
    test_step.dependOn(&run_error_tests.step);

    const integration_test_step = b.step("integration-test", "Run integration tests (compare against stb_image)");
    integration_test_step.dependOn(&run_compare_tests.step);
    integration_test_step.dependOn(&run_jpeg_tests.step);

    const test_all_step = b.step("test-all", "Run all tests (unit + integration)");
    test_all_step.dependOn(&run_unit_tests.step);
    test_all_step.dependOn(&run_jpeg_unit_tests.step);
    test_all_step.dependOn(&run_error_tests.step);
    test_all_step.dependOn(&run_compare_tests.step);
    test_all_step.dependOn(&run_jpeg_tests.step);

    // Large image test executable
    const large_test = b.addExecutable(.{
        .name = "test-large",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_large_image.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    large_test.root_module.addImport("stbz", stbz_mod);
    const run_large_test = b.addRunArtifact(large_test);
    const large_step = b.step("test-large", "Run large image streaming test");
    large_step.dependOn(&run_large_test.step);

    // Test progressive JPEG executable
    const test_progressive = b.addExecutable(.{
        .name = "test-progressive",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bin/test_progressive.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_progressive.root_module.addImport("stbz", stbz_mod);
    const run_test_progressive = b.addRunArtifact(test_progressive);
    const test_progressive_step = b.step("test-progressive", "Test progressive JPEG loading");
    test_progressive_step.dependOn(&run_test_progressive.step);

    // Compare progressive JPEG with stb_image
    const compare_progressive = b.addExecutable(.{
        .name = "compare-progressive",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bin/compare_progressive.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    compare_progressive.root_module.addImport("stbz", stbz_mod);
    compare_progressive.root_module.addIncludePath(b.path("reference"));
    compare_progressive.root_module.addCSourceFile(.{
        .file = b.path("reference/ref_impl.c"),
        .flags = &.{"-std=c99"},
    });
    compare_progressive.root_module.link_libc = true;
    const run_compare_progressive = b.addRunArtifact(compare_progressive);
    const compare_progressive_step = b.step("compare-progressive", "Compare progressive JPEG with stb_image");
    compare_progressive_step.dependOn(&run_compare_progressive.step);

    // Benchmark executable (always ReleaseFast)
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench.root_module.addImport("stbz", stbz_mod);
    bench.root_module.addIncludePath(b.path("reference"));
    bench.root_module.addCSourceFile(.{
        .file = b.path("reference/ref_impl.c"),
        .flags = &.{ "-std=c99", "-O2" },
    });
    bench.root_module.link_libc = true;

    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    run_bench.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    const bench_step = b.step("bench", "Run benchmarks (stbz vs stb_image)");
    bench_step.dependOn(&run_bench.step);

    // Format step
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "test" },
    });
    const fmt_step = b.step("fmt", "Format source code");
    fmt_step.dependOn(&fmt.step);

    // Check step (compile without codegen to find errors quickly)
    const check = b.addTest(.{
        .name = "check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stbz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const check_step = b.step("check", "Check for compile errors");
    check_step.dependOn(&check.step);
}
