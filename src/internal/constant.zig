//! Copies that start from a comptime constant.
//!
//! `fastmem.copy` takes its source's pointer and dereferences it. Zig 0.17
//! evaluates a dereference through a comptime-known pointer at comptime, and
//! a vector has no comptime layout, so the small-copy class (16 to 64 bytes on
//! aarch64 and x86_64) refuses a comptime source: "comptime dereference
//! requires '@Vector(16, u8)' to have a well-defined layout". Zig 0.16
//! materializes the constant and loads it at runtime, so this is a 0.17-only
//! failure, and it appears only where a test or a fixture builder passes a
//! constant (`&golden.some_fixture`, a literal) as the source.
//!
//! The copy here costs one stack copy: the constant lands in a `var`, and
//! `fastmem.copy` reads it through a runtime pointer. The test machinery is
//! the only caller; a codec's hot paths copy runtime buffers.

const assert = @import("std").debug.assert;

const fastmem = @import("fastmem");

/// Copies `source` into the front of `target`. `target` must be at least
/// `source.len` bytes.
pub fn copyInto(comptime source: []const u8, target: []u8) void {
    assert(target.len >= source.len);
    var bytes: [source.len]u8 = source[0..source.len].*;
    fastmem.copy(u8, target[0..source.len], &bytes);
}
