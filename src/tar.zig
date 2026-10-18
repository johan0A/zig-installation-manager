const std = @import("std");
const zip = std.zip;
const File = std.Io.File;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.next();
    const in_path = args.next().?;
    const out_path = args.next().?;
    const format = args.next().?;

    const cwd: std.Io.Dir = .cwd();
    const in_file = try cwd.openFile(init.io, in_path, .{});
    defer in_file.close(init.io);
    const out_file = try cwd.createFile(init.io, out_path, .{});
    defer out_file.close(init.io);

    var write_buffer: [1024 * 8]u8 = undefined;
    var out_file_writer: std.Io.File.Writer = .init(out_file, init.io, &write_buffer);

    var read_buffer: [1024 * 8]u8 = undefined;
    var in_file_reader: std.Io.File.Reader = .init(in_file, init.io, &read_buffer);

    if (std.mem.eql(u8, format, "tar")) {
        var tar_write: std.tar.Writer = .{ .underlying_writer = &out_file_writer.interface };
        try tar_write.writeFile(
            std.Io.Dir.path.basename(in_path),
            &in_file_reader,
            0,
        );
    } else {
        try writeFileZip(
            &in_file_reader,
            &out_file_writer.interface,
            std.Io.Dir.path.basename(in_path),
        );
    }

    try out_file_writer.flush();
}

pub fn writeFileZip(
    fr: *File.Reader,
    w: *std.Io.Writer,
    name: []const u8,
) !void {
    try fr.seekTo(0);
    var crc = std.hash.Crc32.init();
    var size: u64 = 0;
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = fr.interface.readSliceShort(&chunk) catch return fr.err.?;
        if (n == 0) break;
        crc.update(chunk[0..n]);
        size += n;
    }
    const crc32 = crc.final();

    const filename_len: u16 = @intCast(name.len);
    const cd_offset: u64 = @sizeOf(zip.LocalFileHeader) + name.len + size;
    const cd_size: u64 = @sizeOf(zip.CentralDirectoryFileHeader) + name.len;
    if (size >= std.math.maxInt(u32) or cd_offset >= std.math.maxInt(u32))
        return error.Zip64Unsupported;
    const size32: u32 = @intCast(size);

    const no_flags: u16 = 0;

    try w.writeStruct(zip.LocalFileHeader{
        .signature = zip.local_file_header_sig,
        .version_needed_to_extract = 10, // 1.0: stored
        .flags = @bitCast(no_flags),
        .compression_method = .store,
        .last_modification_time = 0,
        .last_modification_date = (0 << 9) | (1 << 5) | 1,
        .crc32 = crc32,
        .compressed_size = size32,
        .uncompressed_size = size32,
        .filename_len = filename_len,
        .extra_len = 0,
    }, .little);
    try w.writeAll(name);

    try fr.seekTo(0);
    fr.interface.streamExact64(w, size) catch |err| switch (err) {
        error.ReadFailed => |e| return fr.err orelse e,
        error.WriteFailed => |e| return e,
        error.EndOfStream => return error.FileChangedWhileZipping,
    };

    try w.writeStruct(zip.CentralDirectoryFileHeader{
        .signature = zip.central_file_header_sig,
        .version_made_by = (3 << 8) | 20, // 2.0
        .version_needed_to_extract = 10,
        .flags = @bitCast(no_flags),
        .compression_method = .store,
        .last_modification_time = 0,
        .last_modification_date = (0 << 9) | (1 << 5) | 1, // 1 January 1970
        .crc32 = crc32,
        .compressed_size = size32,
        .uncompressed_size = size32,
        .filename_len = filename_len,
        .extra_len = 0,
        .comment_len = 0,
        .disk_number = 0,
        .internal_file_attributes = 0,
        .external_file_attributes = @as(u32, 0o100644) << 16, // rw-r--r--
        .local_file_header_offset = 0,
    }, .little);
    try w.writeAll(name);

    try w.writeStruct(zip.EndRecord{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = 1,
        .record_count_total = 1,
        .central_directory_size = @intCast(cd_size),
        .central_directory_offset = @intCast(cd_offset),
        .comment_len = 0,
    }, .little);
}
