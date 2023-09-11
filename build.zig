// tested with zig version 0.11.0
const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // This option exists in case build.zig.zon has issues
    const clone_zigwin32 = b.option(
        bool,
        "clone-zigwin32",
        "Use GitRepoStep instead of build.zig.zon to get zigwin32",
    ) orelse false;
    const zigwin32_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marlersoft/zigwin32",
        .branch = "15.0.2-preview",
        .sha = "007649ade45ffb544de3aafbb112de25064d3d92",
        .fetch_enabled = true,
    });
    const zigwin32 = blk: {
        if (clone_zigwin32) break :blk b.createModule(.{
            .source_file = .{ .path = b.pathJoin(&.{zigwin32_repo.path, "win32.zig"}), },
        });
        const zigwin32_dep = b.dependency("zigwin32", .{});
        break :blk zigwin32_dep.module("zigwin32");
    };

    const exe = b.addExecutable(.{
        .name = "winres",
        .root_source_file = .{ .path = "winres.zig" },
        .target = target,
        .optimize = optimize,
    });

    if (clone_zigwin32) {
        exe.step.dependOn(&zigwin32_repo.step);
    }
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
