const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module
    const zpix_mod = b.addModule("zpix", .{
        .root_source_file = b.path("src/zpix.zig"),
    });

    // CLI executable (pure Zig, no C dependencies)
    const exe = b.addExecutable(.{
        .name = "zpix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zpix", zpix_mod);

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run_cmd.step);

    // Unit tests for zpix library
    const unit_tests = b.addTest(.{
        .name = "zpix-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zpix.zig"),
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
    jpeg_unit_tests.root_module.addImport("zpix", zpix_mod);
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
    error_tests.root_module.addImport("zpix", zpix_mod);
    const run_error_tests = b.addRunArtifact(error_tests);

    // Translate the aggregated stb header once; consumers import it as `c`.
    const translate_stb = b.addTranslateC(.{
        .root_source_file = b.path("reference/stb.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_stb.addIncludePath(b.path("reference"));
    const stb_c_mod = translate_stb.createModule();

    // Integration tests: compare zpix output against stb_image (C reference).
    // The stb C dependency is only compiled when these targets are requested.
    const compare_tests = b.addTest(.{
        .name = "compare-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_png.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    compare_tests.root_module.addImport("zpix", zpix_mod);
    compare_tests.root_module.addImport("c", stb_c_mod);
    linkStbReference(compare_tests, b, &.{"-std=c99"});

    const run_compare_tests = b.addRunArtifact(compare_tests);

    const jpeg_tests = b.addTest(.{
        .name = "jpeg-compare-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_jpeg.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    jpeg_tests.root_module.addImport("zpix", zpix_mod);
    jpeg_tests.root_module.addImport("c", stb_c_mod);
    linkStbReference(jpeg_tests, b, &.{"-std=c99"});

    const run_jpeg_tests = b.addRunArtifact(jpeg_tests);

    const jpeg_encode_tests = b.addTest(.{
        .name = "jpeg-encode-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_jpeg_encode.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    jpeg_encode_tests.root_module.addImport("zpix", zpix_mod);
    jpeg_encode_tests.root_module.addImport("c", stb_c_mod);
    linkStbReference(jpeg_encode_tests, b, &.{"-std=c99"});
    const run_jpeg_encode_tests = b.addRunArtifact(jpeg_encode_tests);

    // Separate test steps for better organization
    const test_step = b.step("test", "Run unit tests (fast, no C dependencies)");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_jpeg_unit_tests.step);
    test_step.dependOn(&run_error_tests.step);

    const integration_test_step = b.step("integration-test", "Run integration tests (compare against stb_image)");
    integration_test_step.dependOn(&run_compare_tests.step);
    integration_test_step.dependOn(&run_jpeg_tests.step);
    integration_test_step.dependOn(&run_jpeg_encode_tests.step);

    const test_all_step = b.step("test-all", "Run all tests (unit + integration)");
    test_all_step.dependOn(&run_unit_tests.step);
    test_all_step.dependOn(&run_jpeg_unit_tests.step);
    test_all_step.dependOn(&run_error_tests.step);
    test_all_step.dependOn(&run_compare_tests.step);
    test_all_step.dependOn(&run_jpeg_tests.step);
    test_all_step.dependOn(&run_jpeg_encode_tests.step);

    // Bulk load test executable (loads all images from ~/RPG/Eberron/Images/)
    const bulk_test = b.addExecutable(.{
        .name = "test-bulk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_bulk_load.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bulk_test.root_module.addImport("zpix", zpix_mod);
    const run_bulk_test = b.addRunArtifact(bulk_test);
    const bulk_step = b.step("test-bulk", "Run bulk image load test against ~/RPG/Eberron/Images/");
    bulk_step.dependOn(&run_bulk_test.step);

    // Benchmark executable (always ReleaseFast, uses stb_image for comparison)
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench.root_module.addImport("zpix", zpix_mod);
    bench.root_module.addImport("c", stb_c_mod);
    linkStbReference(bench, b, &.{ "-std=c99", "-O2" });

    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    run_bench.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    const bench_step = b.step("bench", "Run benchmarks (zpix vs stb_image)");
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
            .root_source_file = b.path("src/zpix.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const check_step = b.step("check", "Check for compile errors");
    check_step.dependOn(&check.step);

    // Docs step (generate API documentation)
    const docs = b.addTest(.{
        .name = "docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zpix.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/api",
    });
    const docs_step = b.step("docs", "Generate API documentation");
    docs_step.dependOn(&install_docs.step);
}

/// Link the stb_image C reference implementation (reference/ref_impl.c).
/// Used only for integration tests and benchmarks — not required by the library or CLI.
fn linkStbReference(step: *std.Build.Step.Compile, b: *std.Build, flags: []const []const u8) void {
    step.root_module.addIncludePath(b.path("reference"));
    step.root_module.addCSourceFile(.{
        .file = b.path("reference/ref_impl.c"),
        .flags = flags,
    });
    step.root_module.link_libc = true;
}
