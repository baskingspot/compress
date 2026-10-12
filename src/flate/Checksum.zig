//! The checksum hook: how a container's checksum (gzip's CRC-32, zlib's
//! Adler-32) sees the payload passing through `Writer` and `Reader`. Each
//! streaming layer has an optional `checksum` field of this type, null by
//! default. When it is set, the layer calls `update` with every payload byte
//! exactly once, in stream order, in contiguous runs, so the container needs
//! no extra buffer, copy, or pass over the data.
//!
//! The hook knows nothing about checksums. The container owns the state and
//! the arithmetic, reads its result when the stream ends, and writes any
//! trailer; flate keeps no checksum state and writes no trailer. Nothing here
//! allocates. `Writer.Checksum` and `Reader.Checksum` name this type.

const Checksum = @This();

/// The container's checksum state, passed to `update_fn` untouched. It must
/// outlive the `Writer` or `Reader` holding the hook.
context: *anyopaque,
/// Fold one run of payload bytes into the state. Runs arrive in stream order,
/// each byte exactly once, and are never empty. Must not allocate.
update_fn: *const fn (context: *anyopaque, bytes: []const u8) void,

/// Fold `bytes` into the container's state.
pub fn update(checksum: Checksum, bytes: []const u8) void {
    checksum.update_fn(checksum.context, bytes);
}
