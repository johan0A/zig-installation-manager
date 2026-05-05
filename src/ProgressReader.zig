child: *std.Io.Reader,
reader: std.Io.Reader,
node: std.Progress.Node,
transferred_bytes: usize,
total_bytes: ?usize,
transfer_limit: std.Io.Limit,

pub fn init(child: *std.Io.Reader, node: std.Progress.Node, total_bytes: ?usize, buffer: []u8) ProgressReader {
    if (total_bytes != null) node.setEstimatedTotalItems(100);
    return .{
        .child = child,
        .node = node,
        .transferred_bytes = 0,
        .total_bytes = total_bytes,
        .transfer_limit = if (total_bytes) |n| .limited(n / 100 + 1) else .unlimited,
        .reader = .{
            .vtable = &.{ .stream = stream },
            .buffer = buffer,
            .end = 0,
            .seek = 0,
        },
    };
}

fn advance(self: *ProgressReader, n: usize) void {
    if (self.total_bytes) |total_bytes| {
        self.transferred_bytes += n;
        const percent = self.transferred_bytes * 100 / total_bytes;
        self.node.setCompletedItems(percent);
    }
}

fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const self: *ProgressReader = @alignCast(@fieldParentPtr("reader", r));
    const n = try self.child.stream(w, limit.min(self.transfer_limit));
    self.advance(n);
    return n;
}

const std = @import("std");
const ProgressReader = @This();
