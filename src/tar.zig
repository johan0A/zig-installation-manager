pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.next();
    const in_path = args.next().?;
    const out_path = args.next().?;

    const cwd: std.Io.Dir = .cwd();
    const in_file = try cwd.openFile(init.io, in_path, .{});
    defer in_file.close(init.io);
    const out_file = try cwd.createFile(init.io, out_path, .{});
    defer out_file.close(init.io);

    var write_buffer: [1024 * 8]u8 = undefined;
    var out_file_writer: std.Io.File.Writer = .init(out_file, init.io, &write_buffer);

    var read_buffer: [1024 * 8]u8 = undefined;
    var in_file_reader: std.Io.File.Reader = .init(in_file, init.io, &read_buffer);

    var tar_write: std.tar.Writer = .{ .underlying_writer = &out_file_writer.interface };
    try tar_write.writeFile(
        std.Io.Dir.path.basename(in_path),
        &in_file_reader,
        0,
    );

    try out_file_writer.flush();
}

const std = @import("std");
