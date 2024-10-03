const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tt_mod = b.addModule("TrueType", .{
        .root_source_file = b.path("TrueType.zig"),
        .target = target,
        .optimize = optimize,
    });

    const stb_truetype_object = b.addObject(.{
        .name = "stb_truetype",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    stb_truetype_object.addCSourceFile(.{
        .file = b.path("test/stb_truetype.c"),
    });

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("test/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("TrueType", tt_mod);
    unit_tests.addObject(stb_truetype_object);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
