const std = @import("std");
const zon = @import("build.zig.zon");

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    var options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe = b.addExecutable(.{
        .root_module = rootModule(b, target, optimize, options),
        .name = @tagName(zon.name),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
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
        const reolved_target = b.resolveTargetQuery(t);
        const release_exe = b.addExecutable(.{
            .name = @tagName(zon.name),
            .root_module = rootModule(b, reolved_target, .ReleaseSafe, options),
        });

        const extension = if (reolved_target.result.os.tag == .windows) "zip" else "tar";

        const tar = b.addRunArtifact(tar_exe);
        tar.addFileArg(release_exe.getEmittedBin());
        const output = tar.addOutputFileArg("output.tar");
        tar.addArg(extension);

        const target_output = b.addInstallFile(output, b.fmt("release/{s}.{s}", .{ try t.zigTriple(b.allocator), extension }));

        release.dependOn(&target_output.step);
    }
}

fn rootModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
    options: *std.Build.Step.Options,
) *std.Build.Module {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("options", options);

    inline for ([_][]const u8{ "zig", "zls" }) |name| {
        const module = b.createModule(.{
            .root_source_file = b.path("src/shim.zig"),
            .target = target,
            .optimize = optimize,
        });
        const shim_options = b.addOptions();
        shim_options.addOption([]const u8, "path", name ++ "_path.txt");
        module.addOptions("options", shim_options);

        const exe = b.addExecutable(.{ .name = name ++ "_shim", .root_module = module });
        root_module.addAnonymousImport(name ++ "_shim", .{ .root_source_file = exe.getEmittedBin() });
    }

    return root_module;
}
