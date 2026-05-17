pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stdout_buf: [1024]u8 = undefined;
    var stdout_impl: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_impl.interface;
    defer stdout.flush() catch {};

    var exe_path_buf: [Dir.max_path_bytes]u8 = undefined;
    const exe_path_len = try std.process.executableDirPath(io, &exe_path_buf);
    const exe_dir: Dir = try .openDirAbsolute(io, exe_path_buf[0..exe_path_len], .{ .iterate = true });
    const data_dir = try exe_dir.createDirPathOpen(io, "zim-data", .{ .open_options = .{ .iterate = true } });

    var args_slice: []const []const u8 = try init.minimal.args.toSlice(arena);

    const completion = if (args_slice.len > 1) std.mem.eql(u8, args_slice[1], "bash-complete") else false;

    var incomplete_arg: []const u8 = undefined;

    if (completion) {
        const comp_line = init.environ_map.get("COMP_LINE") orelse return;
        const comp_point_str = init.environ_map.get("COMP_POINT") orelse "0";
        const comp_point = std.fmt.parseInt(usize, comp_point_str, 10) catch comp_line.len;
        const line = comp_line[0..@min(comp_point, comp_line.len)];

        var arglist: std.ArrayList([]const u8) = .empty;
        var args_it = std.mem.tokenizeScalar(u8, line, ' ');
        while (args_it.next()) |w| try arglist.append(arena, w);

        const is_fresh_word = line.len == 0 or line[line.len - 1] == ' ';
        incomplete_arg = if (is_fresh_word) "" else arglist.pop() orelse "";

        args_slice = arglist.items;
    }

    const ArgsIt = struct {
        args: []const []const u8,
        index: usize = 0,
        fn next(self: *@This()) ?[]const u8 {
            if (self.index >= self.args.len) return null;
            self.index += 1;
            return self.args[self.index - 1];
        }
    };
    var args: ArgsIt = .{ .args = args_slice };
    _ = args.next();

    const progress_root = std.Progress.start(io, .{ .root_name = "zim" });
    defer progress_root.end();

    var io_random: std.Random.IoSource = .{ .io = io };
    var prng: std.Random.DefaultPrng = .init(io_random.interface().int(u64));
    const random = prng.random();

    const Command = union(enum) {
        const Version = struct { version: ?[]const u8 = null, help: bool = false };
        const Fetch = struct { version: ?[]const u8 = null, force: bool = false, zls: bool = false, help: bool = false };
        const Help = struct { help: bool = false };

        none,
        unknown: []const u8,
        help,
        install: Fetch,
        use: Version,
        remove: Version,
        list: Help,
        version: Help,
    };

    const CommandTag = @typeInfo(Command).@"union".tag_type.?;
    const command_map: std.StaticStringMap(CommandTag) = .initComptime(.{
        .{ "install", .install }, .{ "i", .install },
        .{ "use", .use },         .{ "u", .use },
        .{ "remove", .remove },   .{ "rm", .remove },
        .{ "list", .list },       .{ "ls", .list },
        .{ "help", .help },       .{ "h", .help },
        .{ "--help", .help },     .{ "-h", .help },
        .{ "version", .version },
    });

    const command: Command = blk: {
        const command_str = args.next() orelse break :blk .none;
        const command = command_map.get(command_str) orelse break :blk .{ .unknown = command_str };
        switch (command) {
            .help => break :blk .help,
            .install => {
                var install: Command.Fetch = .{};
                while (args.next()) |arg| {
                    if (anyEql(arg, &.{ "-h", "--help" })) {
                        install.help = true;
                    } else if (anyEql(arg, &.{"--force"})) {
                        install.force = true;
                    } else if (anyEql(arg, &.{"--zls"})) {
                        install.zls = true;
                    } else if (std.mem.startsWith(u8, arg, "-")) {
                        if (!completion) fatal("unrecognized flag: {s}", .{arg});
                    } else {
                        install.version = arg;
                    }
                }
                break :blk .{ .install = install };
            },
            .use => {
                var use: Command.Version = .{};
                while (args.next()) |arg| {
                    if (anyEql(arg, &.{ "-h", "--help" })) {
                        use.help = true;
                    } else if (std.mem.startsWith(u8, arg, "-")) {
                        if (!completion) fatal("unrecognized flag: {s}", .{arg});
                    } else {
                        use.version = arg;
                    }
                }
                break :blk .{ .use = use };
            },
            .remove => {
                var remove: Command.Version = .{};
                while (args.next()) |arg| {
                    if (anyEql(arg, &.{ "-h", "--help" })) {
                        remove.help = true;
                    } else if (std.mem.startsWith(u8, arg, "-")) {
                        if (!completion) fatal("unrecognized flag: {s}", .{arg});
                    } else {
                        remove.version = arg;
                    }
                }
                break :blk .{ .remove = remove };
            },
            .list => {
                var list: Command.Help = .{};
                while (args.next()) |arg| {
                    if (anyEql(arg, &.{ "-h", "--help" })) {
                        list.help = true;
                    } else if (std.mem.startsWith(u8, arg, "-")) {
                        if (!completion) fatal("unrecognized flag: {s}", .{arg});
                    }
                }
                break :blk .{ .list = list };
            },
            .version => {
                var version: Command.Help = .{};
                while (args.next()) |arg| {
                    if (anyEql(arg, &.{ "-h", "--help" })) {
                        version.help = true;
                    } else if (std.mem.startsWith(u8, arg, "-")) {
                        if (!completion) fatal("unrecognized flag: {s}", .{arg});
                    }
                }
                break :blk .{ .version = version };
            },
            .unknown, .none => unreachable,
        }
    };

    if (!completion) {
        switch (command) {
            .none => fatalAndPrintUsage("missing command argument", .{}),
            .unknown => |name| fatalAndPrintUsage("invalid command: {s}", .{name}),
            .help => std.log.info("{s}", .{usage}),
            .install => |c| {
                if (c.help) {
                    std.log.info("{s}", .{install_usage});
                    return;
                }
                const v = c.version orelse fatal("missing version argument", .{});
                try installVersion(io, arena, gpa, random, progress_root, data_dir, try .parse(v), c.force, c.zls);
                try useVersion(io, arena, v, data_dir);
            },
            .use => |c| {
                if (c.help) {
                    std.log.info("{s}", .{use_usage});
                    return;
                }
                const v = c.version orelse fatal("missing version argument", .{});
                try useVersion(io, arena, v, data_dir);
            },
            .remove => |c| {
                if (c.help) {
                    std.log.info("{s}", .{remove_usage});
                    return;
                }
                const v = c.version orelse fatal("missing version argument", .{});
                try removeVersion(io, v, data_dir);
            },
            .list => |c| {
                if (c.help) {
                    std.log.info("{s}", .{list_usage});
                    return;
                }
                try listVersions(io, arena, data_dir, stdout);
            },
            .version => |c| {
                if (c.help) {
                    std.log.info("{s}", .{version_usage});
                    return;
                }
                try stdout.print("{s}\n", .{options.version});
                try stdout.flush();
            },
        }
    } else {
        const local = struct {
            fn complete(out: *std.Io.Writer, prefix: []const u8, name: []const u8, already_given: bool) void {
                if (already_given) return;
                if (!std.mem.startsWith(u8, name, prefix)) return;
                out.print("{s}\n", .{name}) catch {};
            }
        };
        switch (command) {
            .none, .unknown, .help => {},
            inline .install, .use, .remove, .list, .version => |c| {
                local.complete(stdout, incomplete_arg, "--help", c.help);
                local.complete(stdout, incomplete_arg, "-h", c.help);
            },
        }
        switch (command) {
            .none => {
                for (command_map.keys()) |key|
                    local.complete(stdout, incomplete_arg, key, false);
            },
            .list, .version, .unknown, .help => {},
            .install => |c| {
                local.complete(stdout, incomplete_arg, "--force", c.force);
                local.complete(stdout, incomplete_arg, "--zls", c.zls);
                // TODO: complete versions
            },
            .use, .remove => |c| {
                if (c.version == null) {
                    const versions_dir = openVersionsDir(io, data_dir) catch return;
                    var dir_it = versions_dir.iterate();
                    while (dir_it.next(io) catch return) |entry|
                        if (std.mem.startsWith(u8, entry.name, incomplete_arg))
                            stdout.print("{s}\n", .{entry.name}) catch return;
                }
            },
        }
    }
}

fn anyEql(needle: []const u8, haystack: []const []const u8) bool {
    for (haystack) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

fn fatalAndPrintUsage(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.log.info("{s}", .{usage});
    std.process.exit(1);
}

fn openVersionsDir(io: std.Io, data_dir: Dir) !Dir {
    return data_dir.openDir(io, "versions", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const versions_dir: Dir = try .createDirPathOpen(data_dir, io, "versions", .{
                .open_options = .{ .iterate = true },
            });
            // migrating old zim-data dir format
            var data_dir_it = data_dir.iterate();
            while (try data_dir_it.next(io)) |entry| {
                _ = VersionArg.parse(entry.name) catch continue;
                try data_dir.rename(entry.name, versions_dir, entry.name, io);
            }
            break :blk versions_dir;
        },
        else => |e| return e,
    };
}

fn useVersion(
    io: std.Io,
    arena: std.mem.Allocator,
    version: []const u8,
    data_dir: Dir,
) !void {
    const versions_dir = try openVersionsDir(io, data_dir);
    if (!try fileExists(io, versions_dir, version)) fatal("version {s} is not installed", .{version});

    const symlink_dir = try data_dir.createDirPathOpen(io, symlink_dir_path, .{});
    for ([_][]const u8{ "zig", "zls" }) |path| {
        symlink_dir.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    const zig_target_path = try Dir.path.join(arena, &.{ "..", "versions", version, "zig/zig" });
    try symlink_dir.symLink(io, zig_target_path, "zig", .{});

    const zls_path = try Dir.path.join(arena, &.{ version, "zls" });
    if (try fileExists(io, versions_dir, zls_path)) {
        const zls_target_path = try Dir.path.join(arena, &.{ "..", "versions", version, "zls/zls" });
        try symlink_dir.symLink(io, zls_target_path, "zls", .{});
    }

    std.log.info("active version: {s}", .{version});
}

fn listVersions(
    io: std.Io,
    arena: std.mem.Allocator,
    data_dir: Dir,
    stdout: *std.Io.Writer,
) !void {
    const versions_dir = try openVersionsDir(io, data_dir);
    var versions_dir_it = versions_dir.iterate();
    while (try versions_dir_it.next(io)) |entry| {
        try stdout.print("{s}", .{entry.name});
        const zls_path = try Dir.path.join(arena, &.{ entry.name, "zls" });
        if (try fileExists(io, versions_dir, zls_path)) {
            try stdout.print(" (+zls)", .{});
        }
        try stdout.writeByte('\n');
    }
    try stdout.flush();
}

fn removeVersion(
    io: std.Io,
    version: []const u8,
    data_dir: Dir,
) !void {
    const versions_dir = try openVersionsDir(io, data_dir);
    versions_dir.access(io, version, .{}) catch |err| switch (err) {
        error.FileNotFound => fatal("version {s} is not installed", .{version}),
        else => |e| return e,
    };
    try versions_dir.deleteTree(io, version);
    std.log.info("removed version: {s}", .{version});
}

const VersionArg = union(enum) {
    master: void,
    semver: std.SemanticVersion,

    fn parse(arg: []const u8) !VersionArg {
        return switch (std.mem.eql(u8, arg, "master")) {
            true => .master,
            false => .{ .semver = try .parse(arg) },
        };
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return switch (self) {
            .master => writer.writeAll("master"),
            .semver => |v| writer.print("{f}", .{v}),
        };
    }
};

fn installVersion(
    io: std.Io,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    random: std.Random,
    progress_node: std.Progress.Node,
    data_dir: Dir,
    version_arg: VersionArg,
    force: bool,
    zls: bool,
) !void {
    const versions_dir = try openVersionsDir(io, data_dir);

    const zig_version_index_body = try fetchZigIndex(io, arena, data_dir, progress_node);
    const zig_version_index = try std.json.parseFromSliceLeaky(std.json.Value, arena, zig_version_index_body, .{});

    const zig_version: std.SemanticVersion = switch (version_arg) {
        .master => blk: {
            const master_version_str = zig_version_index.object.get("master").?.object.get("version").?.string;
            break :blk try .parse(master_version_str);
        },
        .semver => |v| v,
    };

    const zig_version_str = try std.fmt.allocPrint(arena, "{f}", .{zig_version});

    const version_name = try std.fmt.allocPrint(arena, "{f}", .{version_arg});
    var version_sub_dir: Dir = try .createDirPathOpen(versions_dir, io, version_name, .{});
    defer version_sub_dir.close(io);

    const zig_already_installed = try fileExists(io, version_sub_dir, "zig");

    if (zig_already_installed and force) {
        try version_sub_dir.deleteTree(io, "zig");
        try version_sub_dir.deleteTree(io, "zls");
    }

    const zls_already_installed = try fileExists(io, version_sub_dir, "zls");
    const fetch_zig = force or !zig_already_installed;
    const fetch_zls = zls and !zls_already_installed;

    if (!fetch_zig and !fetch_zls) {
        std.log.info("version {s} already installed (use --force to re-install)", .{version_name});
        return;
    }

    if (fetch_zig) {
        const tarball_name = switch (zig_version.order(.{ .major = 0, .minor = 14, .patch = 1 })) {
            .lt => try std.fmt.allocPrint(arena, "zig-{t}-{t}-{s}.tar.xz", .{
                builtin.target.os.tag, builtin.target.cpu.arch, zig_version_str,
            }),
            .eq, .gt => try std.fmt.allocPrint(arena, "zig-{t}-{t}-{s}.tar.xz", .{
                builtin.target.cpu.arch, builtin.target.os.tag, zig_version_str,
            }),
        };

        const mirrors = try fetchMirrors(io, arena, data_dir, version_arg, zig_version_str, progress_node);
        std.mem.sortUnstable(Mirror, mirrors, {}, struct {
            fn f(_: void, lhs: Mirror, rhs: Mirror) bool {
                const lhs_int = if (lhs.ping) |p| p.nanoseconds else std.math.maxInt(i96);
                const rhs_int = if (rhs.ping) |p| p.nanoseconds else std.math.maxInt(i96);
                return lhs_int < rhs_int;
            }
        }.f);

        const temp_dir: std.Io.Dir = try .createDirPathOpen(data_dir, io, "temp", .{});

        for (mirrors) |mirror| {
            fetchFromMirror(
                io,
                gpa,
                arena,
                random,
                progress_node,
                mirror.url,
                tarball_name,
                zig_pubkey,
                1,
                temp_dir,
                version_sub_dir,
                "zig",
            ) catch |err| {
                std.log.warn("mirror {s} failed: {s}", .{ mirror.url, @errorName(err) });
                continue;
            };
            std.log.info("installed zig {s}", .{version_name});
            break;
        } else {
            return error.AllMirrorsFailed;
        }
    }

    if (fetch_zls) {
        const zig_version_encoded = try std.mem.replaceOwned(u8, arena, zig_version_str, "+", "%2B");
        const url = try std.fmt.allocPrint(
            arena,
            "https://releases.zigtools.org/v1/zls/select-version?zig_version={s}&compatibility=only-runtime",
            .{zig_version_encoded},
        );

        var transfer_buf: [8 * 1024]u8 = undefined;
        var select_version_get: HttpGet = undefined;
        const select_version_get_reader = try select_version_get.init(io, arena, url, &transfer_buf);
        defer select_version_get.deinit();

        var json_tokenizer: std.json.Reader = .init(arena, select_version_get_reader);
        const select_version = try std.json.parseFromTokenSourceLeaky(std.json.Value, arena, &json_tokenizer, .{});

        if (select_version.object.get("code")) |code| {
            const message = select_version.object.get("message").?.string;
            std.log.err("{d}: {s}", .{ code.integer, message });
            return error.NoCompatibleZls;
        }

        const zls_version = select_version.object.get("version").?.string;

        const tarball_name = switch (zig_version.order(.{ .major = 0, .minor = 14, .patch = 1 })) {
            .lt => try std.fmt.allocPrint(arena, "zls-{t}-{t}-{s}.tar.xz", .{
                builtin.target.os.tag, builtin.target.cpu.arch, zls_version,
            }),
            .eq, .gt => try std.fmt.allocPrint(arena, "zls-{t}-{t}-{s}.tar.xz", .{
                builtin.target.cpu.arch, builtin.target.os.tag, zls_version,
            }),
        };

        const temp_dir: std.Io.Dir = try .createDirPathOpen(data_dir, io, "temp", .{});

        try fetchFromMirror(
            io,
            gpa,
            arena,
            random,
            progress_node,
            "https://builds.zigtools.org",
            tarball_name,
            zls_pubkey,
            0,
            temp_dir,
            version_sub_dir,
            "zls",
        );
        std.log.info("installed zls {s}", .{zls_version});
    }
}

fn fileExists(io: std.Io, dir: Dir, sub_path: []const u8) !bool {
    return if (dir.access(io, sub_path, .{})) true else |err| switch (err) {
        error.FileNotFound => false,
        else => |e| e,
    };
}

const Mirror = struct {
    ping: ?std.Io.Duration,
    url: []const u8,
};

fn fetchMirrors(
    io: std.Io,
    arena: std.mem.Allocator,
    data_dir: Dir,
    version_arg: VersionArg,
    zig_version_str: []const u8,
    progress_node: std.Progress.Node,
) ![]Mirror {
    const node = progress_node.start("fetching mirrors list", 0);
    defer node.end();

    const MirrorFile = struct {
        time: std.Io.Timestamp,
        mirros: []Mirror,
    };

    const cache_file = blk: {
        const cache_file_handle = data_dir.openFile(io, zig_mirrors_cache_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => break :blk null,
            else => |e| return e,
        };

        var cache_file_reader_buf: [1024]u8 = undefined;
        var cache_file_reader = cache_file_handle.reader(io, &cache_file_reader_buf);

        var json_tokenizer: std.json.Reader = .init(arena, &cache_file_reader.interface);
        const cache_file = std.json.parseFromTokenSourceLeaky(MirrorFile, arena, &json_tokenizer, .{}) catch {
            break :blk null;
        };

        if (@abs(cache_file.time.untilNow(io, .real).toSeconds()) < 60 * 60 * 24) {
            return cache_file.mirros;
        }

        break :blk cache_file;
    };

    const body = (b: {
        var get: HttpGet = undefined;
        var buf: [1024 * 8]u8 = undefined;
        const reader = get.init(io, arena, zig_mirrors_url, &buf) catch |e| break :b e;
        defer get.deinit();
        break :b reader.allocRemaining(arena, .unlimited);
    }) catch |err| {
        if (cache_file) |c| {
            std.log.warn("failed to fetch mirror list, using cached list instead", .{});
            return c.mirros;
        }
        return err;
    };

    var mirrors: std.ArrayList(Mirror) = .empty;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        _ = std.Uri.parse(trimmed) catch continue;
        try mirrors.append(arena, .{ .ping = null, .url = trimmed });
    }

    const ziglang_url = switch (version_arg == .master) {
        false => try std.fmt.allocPrint(arena, "https://ziglang.org/download/{s}", .{zig_version_str}),
        true => "https://ziglang.org/builds",
    };
    try mirrors.append(arena, .{ .ping = null, .url = ziglang_url });

    var ping_group: std.Io.Group = .init;
    errdefer ping_group.cancel(io);
    for (mirrors.items) |*mirror| {
        ping_group.async(io, struct {
            fn f(i: std.Io, m: *Mirror) void {
                m.ping = pingUrl(i, m.url) catch null;
            }
        }.f, .{ io, mirror });
    }

    try ping_group.await(io);

    const cache_file_handle = try data_dir.createFile(io, zig_mirrors_cache_path, .{ .read = true });
    var cache_file_writer_buf: [1024]u8 = undefined;
    var cache_file_writer = cache_file_handle.writer(io, &cache_file_writer_buf);
    try std.json.Stringify.value(MirrorFile{
        .time = .now(io, .real),
        .mirros = mirrors.items,
    }, .{}, &cache_file_writer.interface);
    try cache_file_writer.flush();

    return mirrors.items;
}

pub fn pingUrl(io: std.Io, url: []const u8) !std.Io.Duration {
    const uri: std.Uri = try .parse(url);
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try uri.getHost(&host_buf);
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.NoProtocol;

    const port: u16 = switch (protocol) { //TODO: protocol.port()
        .plain => 80,
        .tls => 443,
    };

    // TODO: replace select timeout with timeout from IpAddress.ConnectOptions when its implemented
    const SelectUnion = union(enum) {
        stream: std.Io.net.HostName.ConnectError!std.Io.net.Stream,
        timeout: std.Io.Cancelable!void,
    };
    var select_buf: [2]SelectUnion = undefined;
    var select: std.Io.Select(SelectUnion) = .init(io, &select_buf);
    defer while (select.cancel()) |t| switch (t) {
        .stream => |stream| if (stream) |s| s.close(io) else |_| {},
        .timeout => {},
    };

    var timer: std.Io.Timestamp = .now(io, .awake);

    select.concurrent(.stream, std.Io.net.HostName.connect, .{ host, io, port, .{ .mode = .stream } }) catch unreachable;
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } };
    select.concurrent(.timeout, std.Io.Timeout.sleep, .{ timeout, io }) catch unreachable;

    switch (try select.await()) {
        .stream => |stream| {
            const elapsed = timer.untilNow(io, .awake);
            (try stream).close(io);
            return elapsed;
        },
        .timeout => return error.Timeout,
    }
}

fn fetchZigIndex(
    io: std.Io,
    arena: std.mem.Allocator,
    data_dir: Dir,
    progress_node: std.Progress.Node,
) ![]u8 {
    const node = progress_node.start("fetching zig index", 0);
    defer node.end();

    (b: {
        var get: HttpGet = undefined;
        var buf: [1024 * 8]u8 = undefined;
        const reader = get.init(io, arena, zig_version_index_url, &buf) catch |e| break :b e;
        defer get.deinit();

        const body = reader.allocRemaining(arena, .unlimited) catch |e| break :b e;

        data_dir.writeFile(io, .{ .sub_path = zig_version_index_cache_path, .data = body }) catch {};
        return body;
    }) catch {
        const body = try data_dir.readFileAlloc(io, zig_version_index_cache_path, arena, .unlimited);
        std.log.warn("failed to zig version index, using cached index instead", .{});
        return body;
    };
}

fn fetchFromMirror(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    random: std.Random,
    progress_node: std.Progress.Node,
    mirror_url: []const u8,
    tarball_name: []const u8,
    minisig_pubkey: []const u8,
    strip_components: u32,
    temp_dir: Dir,
    dir: Dir,
    sub_path: []const u8,
) !void {
    const mirror_node = progress_node.startFmt(0, "installing {s} from {s}", .{ tarball_name, mirror_url });
    defer mirror_node.end();

    const signature_url = try std.fmt.allocPrint(arena, "{s}/{s}.minisig?source=zim", .{ mirror_url, tarball_name });

    var signature_get: HttpGet = undefined;
    var buf: [1024 * 8]u8 = undefined;
    const signature_reader = try signature_get.init(io, arena, signature_url, &buf);
    defer signature_get.deinit();

    const minisig = try signature_reader.allocRemaining(arena, .unlimited);

    const tarball_url = try std.fmt.allocPrint(arena, "{s}/{s}?source=zim", .{ mirror_url, tarball_name });

    const temp_file_sub_path = ".tmp-" ++ std.fmt.hex(random.int(u64));
    const temp_file = try temp_dir.createFile(io, temp_file_sub_path, .{ .read = true });
    defer temp_file.close(io);
    defer temp_dir.deleteFile(io, temp_file_sub_path) catch {};

    {
        const download_node = progress_node.start("download", 0);
        defer download_node.end();

        var get: HttpGet = undefined;
        var transfer_buf: [1024]u8 = undefined; // TODO: readerDecompressing has undocumented minimum transfer_buf size
        const get_reader = try get.init(io, arena, tarball_url, &transfer_buf);
        defer get.deinit();

        var progress_reader: ProgressReader = .init(get_reader, download_node, get.response.head.content_length, &.{});

        var blake2: std.crypto.hash.blake2.Blake2b512 = .init(.{});
        var hash_buf: [1024 * 8]u8 = undefined;
        var hashed_reader = progress_reader.reader.hashed(&blake2, &hash_buf);

        var file_writer_buf: [1024 * 8]u8 = undefined;
        var temp_file_writer = temp_file.writer(io, &file_writer_buf);
        _ = try hashed_reader.reader.streamRemaining(&temp_file_writer.interface);
        try temp_file_writer.interface.flush();

        var hash: [64]u8 = undefined;
        hashed_reader.hasher.final(&hash);
        try verifyMinisig(&hash, minisig, minisig_pubkey, tarball_name);
    }

    {
        const extract_node = progress_node.start("extract", 0);
        defer extract_node.end();

        var read_buf: [1024 * 8]u8 = undefined;
        var file_reader = temp_file.reader(io, &read_buf);

        var progress_reader_buf: [1024 * 8]u8 = undefined;
        var progress_reader: ProgressReader = .init(&file_reader.interface, extract_node, file_reader.getSize() catch null, &progress_reader_buf);

        var xz: std.compress.xz.Decompress = try .init(&progress_reader.reader, gpa, &.{});
        defer xz.deinit();

        const dest_dir: Dir = try .createDirPathOpen(dir, io, sub_path, .{});
        try std.tar.extract(io, dest_dir, &xz.reader, .{ .strip_components = strip_components });
    }
}

fn verifyMinisig(
    file_hash: *const [64]u8,
    minisig: []const u8,
    pubkey_str: []const u8,
    expected_filename: []const u8,
) !void {
    var public_key_buf: [42]u8 = undefined;
    _ = try std.base64.standard.Decoder.decode(&public_key_buf, pubkey_str);
    const public_key_id = public_key_buf[2..10];
    const public_key: Ed25519.PublicKey = try .fromBytes(public_key_buf[10..].*);

    var lines = std.mem.splitScalar(u8, minisig, '\n');
    _ = lines.next() orelse return error.InvalidSignature;

    const signature_line = lines.next() orelse return error.InvalidSignature;
    var signature_buf: [74]u8 = undefined;
    _ = try std.base64.standard.Decoder.decode(&signature_buf, signature_line);

    if (!std.mem.eql(u8, signature_buf[0..2], "ED")) return error.InvalidSignature;
    if (!std.mem.eql(u8, signature_buf[2..10], public_key_id)) return error.InvalidSignature;
    const signature_bytes = signature_buf[10..74].*;

    const signature: Ed25519.Signature = .fromBytes(signature_bytes);
    try signature.verify(file_hash, public_key);

    const trusted_comment_line = lines.next() orelse return error.InvalidSignature;
    const trusted_comment_prefix = "trusted comment: ";
    if (!std.mem.startsWith(u8, trusted_comment_line, trusted_comment_prefix)) return error.InvalidSignature;

    const trusted_comment = trusted_comment_line[trusted_comment_prefix.len..];
    if (trusted_comment.len > 1024) return error.InvalidSignature;

    const global_signature_line = lines.next() orelse return error.InvalidSignature;
    var global_signature_buf: [64]u8 = undefined;
    _ = try std.base64.standard.Decoder.decode(
        &global_signature_buf,
        std.mem.trim(u8, global_signature_line, &std.ascii.whitespace),
    );
    const global_signature: Ed25519.Signature = .fromBytes(global_signature_buf);

    var global_msg: [64 + 1024]u8 = undefined;
    @memcpy(global_msg[0..64], &signature_bytes);
    @memcpy(global_msg[64..][0..trusted_comment.len], trusted_comment);
    try global_signature.verify(global_msg[0 .. 64 + trusted_comment.len], public_key);

    const file_prefix = "file:";
    const file_prefix_index = std.mem.find(u8, trusted_comment, file_prefix) orelse return error.FilenameMismatch;
    const after_prefix = trusted_comment[file_prefix_index + file_prefix.len ..];
    const filename_end = std.mem.findAny(u8, after_prefix, &std.ascii.whitespace) orelse after_prefix.len;
    if (!std.mem.eql(u8, after_prefix[0..filename_end], expected_filename)) return error.FilenameMismatch;
}

const HttpGet = struct {
    client: std.http.Client,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    decompress: std.http.Decompress,

    fn init(self: *HttpGet, io: std.Io, arena: std.mem.Allocator, url: []const u8, transfer_buffer: []u8) !*std.Io.Reader {
        self.client = .{ .allocator = arena, .io = io };
        errdefer self.client.deinit();

        self.request = try self.client.request(.GET, try .parse(url), .{});
        errdefer self.request.deinit();
        try self.request.sendBodiless();

        var redirect_buf: [8000]u8 = undefined;
        self.response = try self.request.receiveHead(&redirect_buf);

        const decompress_buffer = try arena.alloc(u8, self.response.head.content_encoding.minBufferCapacity());

        switch (self.response.head.status.class()) {
            .success => {},
            else => |class| {
                std.log.err("HTTP {d} {s}", .{
                    @intFromEnum(self.response.head.status),
                    self.response.head.status.phrase() orelse "",
                });
                return switch (class) {
                    .informational => error.HttpInformational,
                    .redirect => error.HttpRedirect,
                    .client_error => error.HttpClientError,
                    .server_error => error.HttpServerError,
                    .success => unreachable,
                };
            },
        }

        return self.response.readerDecompressing(
            transfer_buffer,
            &self.decompress,
            decompress_buffer,
        );
    }

    fn deinit(self: *HttpGet) void {
        self.request.deinit();
        self.client.deinit();
    }
};

const VersionIndex = struct {};

pub const usage =
    \\Usage: zim <command> [args]
    \\
    \\Commands:
    \\  install, i     Download a Zig version
    \\  use, u         Select an installed version
    \\  list, ls       List installed zig versions
    \\  remove, rm     Delete a installed version
    \\  help, h        Show this message
    \\
    \\General options:
    \\  -h, --help     Show command-specific usage
    \\
;

pub const install_usage =
    \\Usage: zim install <version> [options]
    \\
    \\Fetch a version of Zig (and optionally ZLS) and select it
    \\as the active version. <version> is a semver like `0.14.1`
    \\or `master`.
    \\
    \\Options:
    \\  --zls          Also install ZLS
    \\  --force        Re-install if already present
    \\  -h, --help     Show this help
    \\
;

pub const use_usage =
    \\Usage: zim use <version>
    \\
    \\Activate a previously installed version by updating the
    \\`bin` symlink in the zim-data directory. <version> is a
    \\semver like `0.14.1` or `master`.
    \\
    \\Options:
    \\  -h, --help     Show this help
    \\
;

pub const list_usage =
    \\Usage: zim list
    \\
    \\List currently installed versions of Zig and Zls
    \\
    \\Options:
    \\  -h, --help     Show this help
    \\
;

pub const remove_usage =
    \\Usage: zim remove <version>
    \\
    \\Delete a locally installed version. <version> is a semver
    \\like `0.14.1` or `master`.
    \\
    \\Options:
    \\  -h, --help     Show this help
    \\
;

pub const version_usage =
    \\Usage: zim version
    \\
    \\Print the version number of zim
    \\
    \\Options:
    \\  -h, --help     Show this help
    \\
;

const zig_pubkey = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";
const zls_pubkey = "RWR+9B91GBZ0zOjh6Lr17+zKf5BoSuFvrx2xSeDE57uIYvnKBGmMjOex";

const zig_version_index_url = "https://ziglang.org/download/index.json";
const zig_version_index_cache_path = "zig-index.json";

const zig_mirrors_url = "https://ziglang.org/download/community-mirrors.txt";
const zig_mirrors_cache_path = "zig-mirrors.json";

const symlink_dir_path = "bin";

const std = @import("std");
const builtin = @import("builtin");
const Ed25519 = std.crypto.sign.Ed25519;
const ProgressReader = @import("ProgressReader.zig");
const Dir = std.Io.Dir;

const options = @import("options");
