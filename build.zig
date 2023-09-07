// tested with zig version 0.11.0
const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigwin32_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marlersoft/zigwin32",
        .branch = "15.0.2-preview",
        .sha = "007649ade45ffb544de3aafbb112de25064d3d92",
        .fetch_enabled = true,
    });
    const zigwin32 = b.addModule("win32", .{
        .source_file = .{ .path = b.pathJoin(&.{zigwin32_repo.path, "win32.zig"}), },
    });

    const exe = b.addExecutable(.{
        .name = "winres",
        .root_source_file = .{ .path = "main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.step.dependOn(&zigwin32_repo.step);
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
