const std = @import("std");
const zon = @import("build.zig.zon");

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
};

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .root_module = root_module,
        .name = @tagName(zon.name),
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "");
    run_step.dependOn(&run.step);

    const release = b.step("release", "");

    const tar_exe = b.addExecutable(.{
        .name = "tar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("./src/tar.zig"),
            .optimize = .Debug,
            .target = b.graph.host,
        }),
    });

    for (targets) |t| {
        const release_exe = b.addExecutable(.{
            .name = @tagName(zon.name),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(t),
                .optimize = .ReleaseSafe,
            }),
        });

        const tar = b.addRunArtifact(tar_exe);
        tar.addFileArg(release_exe.getEmittedBin());
        const output = tar.addOutputFileArg("output.tar");

        const target_output = b.addInstallFile(output, b.fmt("release/{s}.tar", .{try t.zigTriple(b.allocator)}));

        release.dependOn(&target_output.step);
    }
}
