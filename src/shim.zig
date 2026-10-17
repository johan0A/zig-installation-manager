const std = @import("std");
const Dir = std.Io.Dir;

const options = @import("options");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var exe_path_buf: [Dir.max_path_bytes]u8 = undefined;
    const exe_path_len = try std.process.executableDirPath(io, &exe_path_buf);
    const exe_dir: Dir = try .openDirAbsolute(io, exe_path_buf[0..exe_path_len], .{});
    const real_zig = try exe_dir.readFileAlloc(io, options.path, arena, .unlimited);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, real_zig);
    try argv.appendSlice(arena, args[1..]);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .exe = .{ .explicit = .{ .dir = exe_dir, .path = real_zig } },
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}
