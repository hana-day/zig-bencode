const std = @import("std");
const bencode = @import("zig-bencode");

/// Parse a given torrent file and print its contents in JSON format.
pub fn main() anyerror!void {
    var allocator = std.heap.page_allocator;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const prog = args.next() orelse unreachable;
    var torrent_filepath = args.next();
    if (torrent_filepath == null) {
        std.log.err("usage: {s} [torrent file path]", .{prog});
        std.os.exit(1);
    }

    // Load the all bytes of the torrent file.
    var file = try std.fs.cwd().openFile(torrent_filepath.?, .{});
    defer file.close();
    const max_buf_size = 32 * 1024;
    const contents = try file.readToEndAlloc(allocator, max_buf_size);

    const Torrent = struct {
        announce: []const u8,
        info: struct {
            files: []struct {
                length: usize,
                path: [][]const u8,
            },
            length: ?usize,
            name: ?[]const u8,
            @"piece length": usize,
            pieces: []const u8,
        },
    };
    // Parse the bencoded torrent file contents to Torrent struct.
    const torrent = try bencode.parse(Torrent, contents, .{ .allocator = allocator });

    // Print the torrent file contents in JSON format.
    var writer = std.io.getStdOut().writer();
    try std.json.stringify(torrent, .{}, writer);
}
