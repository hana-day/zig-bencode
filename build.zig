const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    var bencode_pkg = std.build.Pkg{
        .name = "zig-bencode",
        .source = std.build.FileSource{ .path = "src/main.zig" },
    };

    const lib = b.addStaticLibrary("zig-bencode", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    const main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const exe = b.addExecutable("torrent-example", "example/torrent.zig");
    exe.setBuildMode(mode);
    exe.addPackage(bencode_pkg);
    exe.linkLibrary(lib);
    b.default_step.dependOn(&exe.step);
    exe.install();
}
