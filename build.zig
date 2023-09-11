// tested with zig version 0.11.0
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigwin32_dep = b.dependency("zigwin32", .{});
    const zigwin32 = zigwin32_dep.module("zigwin32");

    const exe = b.addExecutable(.{
        .name = "winres",
        .root_source_file = .{ .path = "winres.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("win32", zigwin32);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
