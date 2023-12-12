const std = @import("std");
const mach_core = @import("mach_core");
const mach_freetype = @import("mach_freetype");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mach_core_dep = b.dependency("mach_core", .{
        .target = target,
        .optimize = optimize,
    });
    const mach_freetype_dep = b.dependency("mach_freetype", .{
        .target = target,
        .optimize = optimize,
    });
    const app = try mach_core.App.init(b, mach_core_dep.builder, .{
        .name = "silk",
        .src = "src/main.zig",
        .target = target,
        .optimize = optimize,
        .deps = &[_]std.build.ModuleDependency{
            .{
                .name = "mach-freetype",
                .module = mach_freetype_dep.module("mach-freetype"),
            },
            .{
                .name = "mach-harfbuzz",
                .module = mach_freetype_dep.module("mach-harfbuzz"),
            },
        },
    });
    mach_freetype.linkFreetype(mach_freetype_dep.builder, app.compile);
    mach_freetype.linkHarfbuzz(mach_freetype_dep.builder, app.compile);
    // NOTE: We use dynamically link system fontconfig because it is often
    //       built with OS/distribution-dependent search paths in case of
    //       no `FC_` env-vars set.
    app.compile.linkSystemLibrary("fontconfig");
    if (b.args) |args| app.run.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&app.run.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
