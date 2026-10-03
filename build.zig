const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "use-llvm", "LLVM Zig backend");
    const debug_todo = b.option(bool, "debug-todo", "crash on TODOs") orelse false;

    const tt_mod = b.addModule("TrueType", .{
        .root_source_file = b.path("TrueType.zig"),
        .target = target,
        .optimize = optimize,
    });
    const options = b.addOptions();
    options.addOption(bool, "debug_todo", debug_todo);
    tt_mod.addOptions("build_options", options);

    const stb_truetype_object = b.addObject(.{
        .name = "stb_truetype",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    stb_truetype_object.root_module.addCSourceFile(.{
        .file = b.path("test/stb_truetype.c"),
    });
    const stb_truetype_bindings = b.addTranslateC(.{
        .root_source_file = b.path("test/stb_truetype.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    unit_tests.filters = b.option([]const []const u8, "test-filter", "string to match for unit tests") orelse &.{};
    unit_tests.root_module.addImport("TrueType", tt_mod);
    unit_tests.root_module.addImport("c", stb_truetype_bindings.createModule());
    unit_tests.root_module.addObject(stb_truetype_object);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const rasterizer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("rasterizer.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    rasterizer_tests.filters = unit_tests.filters;
    test_step.dependOn(&b.addRunArtifact(rasterizer_tests).step);

    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    fuzz_tests.filters = unit_tests.filters;
    fuzz_tests.root_module.addImport("TrueType", tt_mod);
    b.step("fuzz", "Run bounded parser fuzz seeds (add --fuzz=10K -Duse-llvm=true)").dependOn(&b.addRunArtifact(fuzz_tests).step);
    const replay = b.addExecutable(.{
        .name = "truetype-fuzz-replay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz_replay.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    replay.root_module.addImport("TrueType", tt_mod);
    const run_replay = b.addRunArtifact(replay);
    run_replay.has_side_effects = true;
    run_replay.addPassthruArgs();
    b.step("fuzz-replay", "Replay a raw font or deterministic mutations").dependOn(&run_replay.step);

    const benchmark = b.addExecutable(.{
        .name = "truetype-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    benchmark.root_module.addImport("TrueType", tt_mod);
    const run_benchmark = b.addRunArtifact(benchmark);
    // Timing results must be refreshed even when inputs are unchanged.
    run_benchmark.has_side_effects = true;
    b.step("bench", "Benchmark one-shot and workspace rendering (use -Doptimize=ReleaseFast)").dependOn(&run_benchmark.step);
}
