# zig-bencode

An implementation of [Bencode](https://en.wikipedia.org/wiki/Bencode) parser.

## Requirements
Currently tested on Zig >= 0.10.0-dev.3685+dae7aeb33.

## Installation

```shell
$ zig build
```

## Usage

```zig
const std = @import("std");
const bencode = @import("zig-bencode");

pub fn main() anyerror!void {
    var allocator = std.heap.page_allocator;

    const torrent_filepath = "./sample.torrent";

    // Load the all bytes of the torrent file.
    var file = try std.fs.cwd().openFile(torrent_filepath, .{});
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
```

## License
MIT