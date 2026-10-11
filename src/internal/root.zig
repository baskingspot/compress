//! The codec-agnostic shares every zcompress codec may import
//! (docs/zcompress-plan.md, "Architecture"): imports only `std` and
//! `fastmem`, holds no codec-specific state, and travels with a codec that
//! uses it. Never re-exported by the barrel (`src/root.zig`) or a codec
//! namespace.
//!
//! Contracts: README.md (the Io codec pattern book).

/// The decode-overrun sentinel: the constants, the fill, and the check every
/// decode test runs (AGENTS.md, "Rules").
pub const sentinel = @import("sentinel.zig");
/// The reader lifecycle (`State`, `guard`, `fail`) and the generated
/// `Io.Reader` vtable entries (`VTable`).
pub const reader = @import("reader.zig");
/// The shared writer machinery: the generated `Io.Writer` vtable entries and
/// the poisoned `finish` every compressing codec writer runs (`VTable`).
pub const writer = @import("writer.zig");
/// Endian-bound integer access: the one home of the codecs' `readInt`/
/// `writeInt` (`Int`, `little`, `big`).
pub const int = @import("int.zig");
/// The container driver: the framing-agnostic machinery a container codec
/// over an inner codec shares (`ReaderHooks`/`WriterHooks`/`EncodeHooks`/
/// `DecodeHooks`, `readExact`), parameterized over the codec's framing.
pub const container = @import("container.zig");
