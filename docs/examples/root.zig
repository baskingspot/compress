//! Every example the guide embeds. Each file is a complete program
//! that `zig build test` compiles and runs, so a guide page cannot
//! show code that does not build.

const std = @import("std");

pub const oneshot_roundtrip = @import("oneshot_roundtrip.zig");
pub const choose_buffers = @import("choose_buffers.zig");
pub const errors_named = @import("errors_named.zig");
pub const streaming_pump = @import("streaming_pump.zig");
pub const dictionary_zstd = @import("dictionary_zstd.zig");
pub const dictionary_zlib = @import("dictionary_zlib.zig");

test {
    std.testing.refAllDecls(@This());
}
