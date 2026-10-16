//! Code shared by compress codecs. Not public API: neither the barrel
//! (`src/root.zig`) nor any codec namespace re-exports it, and there is no
//! build module for it. A codec imports it by relative path
//! (`@import("../internal/root.zig")`) and takes this directory along when it
//! is copied out of the repo.
//!
//! The layer imports only `std` and `fastmem` and holds no codec-specific
//! state.

/// Decode-overrun test helper: `fill` a target with a cycling byte pattern,
/// decode into it, then `expect` that the bytes past the decoded length are
/// untouched.
pub const sentinel = @import("sentinel.zig");
/// The reader lifecycle (`State`, `guard`, `fail`) and the generated
/// `Io.Reader` vtable entries (`VTable`).
pub const reader = @import("reader.zig");
/// The generated `Io.Writer` vtable entries and the poisoned `finish` for
/// block-based compressing writers (`VTable`).
pub const writer = @import("writer.zig");
/// Integer access with a fixed byte order (`Int`, `little`, `big`): the
/// `readInt` and `writeInt` that each codec's `common.zig` binds.
pub const int = @import("int.zig");
/// Fixed-capacity buffer backed by an array (`ArrayBuffer`): the
/// `buffer + len` pair with assert-checked appends and resizes.
pub const array_buffer = @import("array_buffer.zig");
/// The driver shared by container codecs over an inner codec (`ReaderHooks`,
/// `WriterHooks`, `EncodeHooks`, `DecodeHooks`, `readExact`). Each container
/// supplies its own framing type.
pub const container = @import("container.zig");
