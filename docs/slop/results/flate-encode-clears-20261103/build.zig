const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const compress = b.dependency("compress", .{ .target = target, .optimize = .ReleaseFast });
    const exe = b.addExecutable(.{ .name = "infl", .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "compress", .module = compress.module("compress") }},
    }) });
    b.installArtifact(exe);
}
