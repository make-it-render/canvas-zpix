const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const canvas_dep = b.dependency("canvas", .{ .target = target, .optimize = optimize });
    const zpix_dep = b.dependency("zpix", .{ .target = target, .optimize = optimize });

    const canvas_zpix = b.addModule(
        "canvas_zpix",
        .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    canvas_zpix.addImport("canvas", canvas_dep.module("canvas"));
    canvas_zpix.addImport("zpix", zpix_dep.module("zpix"));

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/root.zig"),
        }),
    });
    tests.root_module.addImport("canvas", canvas_dep.module("canvas"));
    tests.root_module.addImport("zpix", zpix_dep.module("zpix"));

    const run_tests = b.addRunArtifact(tests);
    const run_tests_step = b.step("test", "Run tests");
    run_tests_step.dependOn(&run_tests.step);
}
