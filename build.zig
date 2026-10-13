// tested with zig version 0.11.0
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const patched_std = b.dependency("patch", .{
        .std_patches = &[_]std.Build.LazyPath{
            b.dependency("staticio", .{}).namedLazyPath("std.patch"),
        },
    }).module("std");

    const win32_dep = b.dependency("win32", .{});
    const win32_mod = win32_dep.module("win32");

    const exe = b.addExecutable(.{
        .name = "winres",
        .root_module = b.createModule(.{
            .root_source_file = b.path("winres.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "std", .module = patched_std },
                .{ .name = "win32", .module = win32_mod },
            },
        }),
    });

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
