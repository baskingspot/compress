//! Fuzz targets for brotli (RFC 7932): the one-shot `decode.decompress`, the
//! streaming `Reader`, and the layers they are composed from.
//!
//! The codec is decoder-only (the encoder seat is empty, `README.md`), so
//! there is no self-round-trip and no in-process reference encoder. The
//! corpus is therefore the pinned CLI's own output and the hand-built wire
//! vectors of `golden.zig`, every one verified against brotli 1.2.0 before it
//! landed; and the differential that *is* available in-process is the
//! one-shot against the streaming `Reader` — the same bytes through both must
//! give the same verdict, the same named class, and the same output.
//! `fuzzDifferential` runs that pairing over every mutation the other targets
//! produce. The encoder half of the differential gap stays open until the
//! encoder milestone; the external half is the oracle lane
//! (`just brotli-oracle`).
//!
//! Targets, each with the property it checks in its own doc comment:
//!
//!   - `fuzzGoldenCorpus`: every golden vector at the exact cap, with slack,
//!     and one byte short, byte-exact, with the corpus's refusal class pinned
//!   - `fuzzTruncation`: a strict prefix of a valid stream is `Truncated`
//!     (`§10`), never a short decode
//!   - `fuzzCorruption`: the mutation taxonomy over the corpus, with the
//!     named class pinned wherever the wire rule makes the verdict
//!     deterministic (`§9.1`'s 0010001, `§10`'s truncation rule, T4's
//!     trailing bytes)
//!   - `fuzzDifferential`: the one-shot against the `Reader` — verdict,
//!     class, bytes, the `§9.1` window cap, and the exact boundary (T4)
//!   - `fuzzReaderMachinery`: the consumer surface (`peek`/`take`/`discard`/
//!     `stream`/poll), the ring wrap, `StreamTooLong`, the sticky end
//!   - `fuzzAmplification`: caps below, at, and above the decoded length, and
//!     a zero-bit-command bomb (`§5`, `§9.3`) against a bounded drain
//!   - `fuzzBits`: `§1.5.1`'s reads against a bit-at-a-time model, including
//!     the checked align and the cross-byte reads
//!   - `fuzzHeaders`: the stream header and the meta-block ladder over
//!     arbitrary bytes, and the invariants a parsed `Header` must hold
//!   - `fuzzPrefixCodes`: `§3.4`/`§3.5`'s tree reading over arbitrary bytes
//!   - `fuzzContextMaps`: `§7.3`'s maps — the RLEMAX runs and the IMTF
//!   - `fuzzDictionary`: `§8`'s word arithmetic against an independent model
//!     of the 121 transforms, and its two refusals
//!
//! Run with `just fuzz <budget>` (ReleaseSafe only: a Debug-mode fuzz run
//! hits ziglang/zig#30655). Every target caps its per-iteration input, its
//! output, and its call count, so a budget run finishes and a hostile input
//! cannot spin: a `Reader` that neither serves bytes nor fails inside its
//! call budget is `error.PumpStalled`, reported, never a timeout.
//!
//! Spec: docs/research/specs/rfc7932-brotli.txt. API and contracts:
//! README.md; the per-layer corner lists these targets were built from:
//! AGENTS.md.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;
const Smith = testing.Smith;
const math = std.math;
const mem = std.mem;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const bits = @import("bits.zig");
const context = @import("context.zig");
const data = @import("dictionary_data.zig");
const decode = @import("decode.zig");
const dictionary = @import("dictionary.zig");
const frame = @import("frame.zig");
const golden = @import("golden.zig");
const huffman = @import("huffman.zig");
const Reader = @import("Reader.zig");

// ---------------------------------------------------------------------------
// Shared harness
// ---------------------------------------------------------------------------

/// Bytes past a decode's cap checked on every one-shot decode: an
/// out-of-bounds write lands in this region.
const guard_len: usize = 256;

/// The corpus's widest decoded output (`cli_small_window`: 4,400 bytes)
/// rounded up, so the corpus target's cap holds every vector.
const corpus_out_max: usize = 8192;

/// The one-shot cap the mutation targets use. A mutation can declare any
/// MLEN (`§9.2`: up to 2^24), so the cap — not the declaration — bounds the
/// work: a stream that wants more is `BufferTooSmall` before its first
/// write.
const out_max: usize = 64 * 1024;

/// The mutation source cap: a stream handed to a target is at most this
/// long, and a mutation may grow it by `growth_max`.
const source_max: usize = 4096;
const growth_max: usize = 64;
const mutation_max: usize = source_max + growth_max;

/// The marker bytes an appended tail carries, to prove the decode stops at
/// the stream's last byte and not somewhere in the tail (T4).
const marker_byte: u8 = 0xa5;

/// A Smith-chosen value in `[at_least, at_most]`. `Smith.valueRangeAtMost`
/// rejects `usize` (no fixed bitsize), so bounded lengths go through a `u32`
/// and widen here; every call site is inside a per-iteration cap.
fn rangeAtMost(smith: *Smith, at_least: usize, at_most: usize) usize {
    assert(at_least <= at_most);
    assert(at_most <= math.maxInt(u32));
    return smith.valueRangeAtMost(u32, @intCast(at_least), @intCast(at_most));
}

/// A Smith-serialized `u64`: the little-endian form every `smith.value` call
/// consumes, so hand-built seeds can pin the values the target reads.
fn u64Le(comptime value: u64) [8]u8 {
    var out: [8]u8 = undefined;
    mem.writeInt(u64, &out, value, .little);
    return out;
}

/// A seed that selects corpus vector `index` in the index-addressed targets:
/// the little-endian u64 `smith.valueRangeAtMost` consumes, then zeros for
/// the fields that follow.
fn indexSeed(comptime index: usize) [64]u8 {
    var seed: [64]u8 = @splat(0);
    seed[0..8].* = u64Le(index);
    return seed;
}

/// A raw-stream seed in Smith's serialized form: the u64 that selects the
/// raw slice source (1), the u64 that selects the corpus index, then the
/// `u32-le` length plus the stream's bytes. The fields that follow read as
/// zeros — the `none` operator — so the seed itself is the stream under
/// test. Comptime-only, and written byte by byte because the seed tables are
/// comptime values (`fastmem` is a runtime primitive).
fn streamSeed(comptime stream: []const u8) [20 + stream.len]u8 {
    var seed: [20 + stream.len]u8 = @splat(0);
    seed[0] = 1; // the mode selector, a little-endian u64
    seed[16] = @truncate(stream.len);
    seed[17] = @truncate(stream.len >> 8);
    seed[18] = @truncate(stream.len >> 16);
    seed[19] = @truncate(stream.len >> 24);
    for (stream, 0..) |byte, i| seed[20 + i] = byte;
    return seed;
}

// ---------------------------------------------------------------------------
// The reader pump: bounded, so a hang is reported and never a timeout
// ---------------------------------------------------------------------------

/// How many `stream` calls a bounded pump may take: each call either serves
/// buffered bytes or fills with at least one, so two per output byte plus
/// slack. More calls than this is a hang, not a timeout.
fn pumpLimit(out_cap: usize) usize {
    return 64 + 2 * out_cap;
}

/// Consecutive zero-serve calls a bounded pump tolerates. A zero-serve call
/// means the reader's buffer was empty and the fill either added bytes (the
/// next call serves them) or failed, so two in a row is the worst legitimate
/// case; more is the spin the bit seam's two infinite loops were.
const stall_limit: usize = 16;

/// How a bounded pump stopped. `output_full` is the harness's own cap, not a
/// codec failure.
const Stop = enum { end_of_stream, read_failed, output_full };

const Pumped = struct {
    /// Bytes served to the writer.
    served: usize,
    stop: Stop,
    /// The reader's detailed refusal once `stop == .read_failed`.
    detail: ?Reader.Error,
};

/// Pump `host` into `w` until the stream ends, the reader fails, or `w` is
/// full, bounded by `call_limit` calls and `stall_limit` consecutive
/// zero-serve calls. `error.PumpStalled` is the hang report: a reader that
/// neither serves bytes nor fails is a bug, and a fuzz target that hung
/// would spin a core until the run timed out.
fn pumpCapped(host: *Reader, w: *Io.Writer, call_limit: usize) !Pumped {
    var calls: usize = 0;
    var stalls: usize = 0;
    var served: usize = 0;
    while (true) {
        calls += 1;
        if (calls > call_limit) return error.PumpStalled;
        const n = host.reader.stream(w, .unlimited) catch |err| switch (err) {
            error.EndOfStream => return .{
                .served = served,
                .stop = .end_of_stream,
                .detail = null,
            },
            error.ReadFailed => return .{
                .served = served,
                .stop = .read_failed,
                .detail = host.err,
            },
            error.WriteFailed => return .{
                .served = served,
                .stop = .output_full,
                .detail = null,
            },
        };
        served += n;
        stalls = if (n == 0) stalls + 1 else 0;
        if (stalls > stall_limit) return error.PumpStalled;
    }
}

/// The verdict of one streaming decode.
const Streamed = struct {
    served: usize,
    stop: Stop,
    detail: ?Reader.Error,
    /// The ring's capacity, `1 << wbits`: `§9.1`'s window authorization.
    capacity: usize,
    /// Bytes the source reader consumed. Exact at a clean end for an
    /// unbuffered input: the stream's last byte + 1 (T4).
    consumed: usize,
};

/// Decode `source` through a streaming `Reader` over `buffer`, with the
/// input handed over in `chunk`-sized pieces (`chunk.len == 0` hands the
/// whole slice over at once, which is also the case whose `consumed` is the
/// exact boundary). Output goes into `out`, whose length is the drain cap.
fn streamSource(
    comptime wbits: usize,
    source: []const u8,
    buffer: *Reader.Buffer(wbits),
    out: []u8,
    chunk: []u8,
) !Streamed {
    var fixed_in: Io.Reader = .fixed(source);
    var limited: Io.Reader.Limited = undefined;
    const input: *Io.Reader = if (chunk.len == 0) &fixed_in else blk: {
        limited = .init(&fixed_in, .unlimited, chunk);
        break :blk &limited.interface;
    };
    var r: Reader = .init(wbits, input, buffer);
    var w: Io.Writer = .fixed(out);
    const pumped = try pumpCapped(&r, &w, pumpLimit(out.len));
    return .{
        .served = pumped.served,
        .stop = pumped.stop,
        .detail = pumped.detail,
        .capacity = buffer.ring.len,
        .consumed = fixed_in.seek,
    };
}

/// The stream's declared window size (`§9.1`), or null when the header does
/// not parse. The `Reader`'s `WindowTooLarge` cap is exactly this against
/// the ring's capacity.
fn declaredWindowSize(source: []const u8) ?u32 {
    var br: bits.BitReader = .init(source);
    const header = frame.readStreamHeader(bits.BitReader, &br) catch return null;
    return header.window_size;
}

/// The one-shot's name for a `Reader` refusal, or null for the names only
/// the reader has. `BadStreamStart` is the reader's name for the same wire
/// pattern `decompress` calls `BadWindowBits` (F10: the names differ by
/// entry point, never by bytes).
fn sharedName(err: Reader.Error) ?decode.DecompressError {
    return switch (err) {
        error.BadStreamStart => error.BadWindowBits,
        error.BadWindowBits => error.BadWindowBits,
        error.Truncated => error.Truncated,
        error.ReservedBit => error.ReservedBit,
        error.ExuberantNibble => error.ExuberantNibble,
        error.ExuberantMetaNibble => error.ExuberantMetaNibble,
        error.BadPadding => error.BadPadding,
        error.SimpleHuffmanAlphabet => error.SimpleHuffmanAlphabet,
        error.SimpleHuffmanSame => error.SimpleHuffmanSame,
        error.BadCodeLengthCode => error.BadCodeLengthCode,
        error.BadHuffmanCode => error.BadHuffmanCode,
        error.BadBlockLength => error.BadBlockLength,
        error.ContextMapRepeat => error.ContextMapRepeat,
        error.BadDistance => error.BadDistance,
        error.BadTransform => error.BadTransform,
        error.BadDictionary => error.BadDictionary,
        error.TooManyTrees => error.TooManyTrees,
        // The reader's own names: pinned by the target that reaches them,
        // never by the one-shot's verdict.
        error.WindowTooLarge,
        error.StreamTooLong,
        error.ReadFailed,
        error.EndOfStream,
        => null,
    };
}

/// The differential harness's storage. Heap-allocated once by the test body:
/// `DefaultBuffer` is about 16.7 MiB (`README.md`), which cannot be a stack
/// local, and the two output caps keep the target's own frame small.
const Storage = struct {
    /// The one-shot's target, filled with the sentinel before every decode.
    out: [out_max + guard_len]u8 = undefined,
    /// The streaming decode's drain buffer.
    read_out: [out_max + guard_len]u8 = undefined,
    ring10: Reader.Buffer(10) = undefined,
    ring16: Reader.Buffer(16) = undefined,
    ring24: Reader.DefaultBuffer = undefined,
    chunk: [64]u8 = undefined,
};

// ---------------------------------------------------------------------------
// The corpus: every golden vector, its model, and its pinned refusal
// ---------------------------------------------------------------------------

/// One golden vector: the stream, the bytes it decodes to (empty for the
/// refusal vectors), and the refusal class the unit suite and the pinned CLI
/// recorded for it — `null` for the decodable ones. A refusal vector's
/// stream still carries the wire pattern its class names: the fuzz targets
/// pin the class, not merely "it errors".
const Vector = struct {
    name: []const u8,
    stream: []const u8,
    plain: []const u8,
    refusal: ?decode.DecompressError = null,
};

const vectors = [_]Vector{
    // The empty family (RFC 7932 §9.2; the notes' §7.2 table): one stream
    // header, ISLAST + ISLASTEMPTY, zero fill, and nothing else.
    .{ .name = "empty_wbits16", .stream = golden.empty_streams[0], .plain = "" },
    .{ .name = "empty_wbits17", .stream = golden.empty_streams[1], .plain = "" },
    .{ .name = "empty_wbits10", .stream = golden.empty_streams[2], .plain = "" },
    .{ .name = "empty_wbits11", .stream = golden.empty_streams[3], .plain = "" },
    .{ .name = "empty_wbits12", .stream = golden.empty_streams[4], .plain = "" },
    .{ .name = "empty_wbits13", .stream = golden.empty_streams[5], .plain = "" },
    .{ .name = "empty_wbits14", .stream = golden.empty_streams[6], .plain = "" },
    .{ .name = "empty_wbits15", .stream = golden.empty_streams[7], .plain = "" },
    .{ .name = "empty_wbits18", .stream = golden.empty_streams[8], .plain = "" },
    .{ .name = "empty_wbits19", .stream = golden.empty_streams[9], .plain = "" },
    .{ .name = "empty_wbits20", .stream = golden.empty_streams[10], .plain = "" },
    .{ .name = "empty_wbits21", .stream = golden.empty_streams[11], .plain = "" },
    .{ .name = "empty_wbits22", .stream = golden.empty_streams[12], .plain = "" },
    .{ .name = "empty_wbits23", .stream = golden.empty_streams[13], .plain = "" },
    .{ .name = "empty_wbits24", .stream = golden.empty_streams[14], .plain = "" },
    // RFC 7932 §9.2, T5 — an ISLAST metadata meta-block ends the stream.
    .{ .name = "last_metadata_1a", .stream = golden.last_metadata_streams[0], .plain = "" },
    .{ .name = "last_metadata_81160058", .stream = golden.last_metadata_streams[1], .plain = "" },
    // RFC 7932 §9.2 — metadata skipped mid-stream: neither output nor
    // context.
    .{
        .name = "metadata_xy",
        .stream = golden.metadata_streams[0].bytes,
        .plain = golden.metadata_streams[0].plain,
    },
    .{
        .name = "metadata_between",
        .stream = golden.metadata_streams[1].bytes,
        .plain = golden.metadata_streams[1].plain,
    },
    .{
        .name = "metadata_between2",
        .stream = golden.metadata_streams[2].bytes,
        .plain = golden.metadata_streams[2].plain,
    },
    // RFC 7932 §9.2 — uncompressed meta-blocks.
    .{
        .name = "uncompressed_hi",
        .stream = golden.uncompressed_streams[0].bytes,
        .plain = golden.uncompressed_streams[0].plain,
    },
    .{
        .name = "uncompressed_abcdef",
        .stream = golden.uncompressed_streams[1].bytes,
        .plain = golden.uncompressed_streams[1].plain,
    },
    // RFC 7932 §9.2, §3.4, §7.1-§7.3 — the compressed ladder in nine bytes.
    .{
        .name = "hand_stream",
        .stream = golden.hand_stream.bytes,
        .plain = golden.hand_stream.plain,
    },
    .{
        .name = "unordered_symbol",
        .stream = golden.unordered_symbol_stream.bytes,
        .plain = golden.unordered_symbol_stream.plain,
    },
    // RFC 7932 §3.4, T7 — ALPHABET_BITS is a width, and the 7-bit reading is
    // corrupt in both references.
    .{
        .name = "wide_symbol",
        .stream = golden.wide_symbol_stream.bytes,
        .plain = golden.wide_symbol_stream.plain,
    },
    .{
        .name = "floor_log",
        .stream = &golden.floor_log_stream,
        .plain = "",
        .refusal = error.Truncated,
    },
    .{
        .name = "high_literal",
        .stream = golden.high_literal_stream.bytes,
        .plain = golden.high_literal_stream.plain,
    },
    // RFC 7932 §3.4 — the two simple-form rejections.
    .{
        .name = "duplicate_symbol",
        .stream = golden.duplicate_symbol_streams[0],
        .plain = "",
        .refusal = error.SimpleHuffmanSame,
    },
    .{
        .name = "out_of_alphabet",
        .stream = golden.out_of_alphabet_streams[0],
        .plain = "",
        .refusal = error.SimpleHuffmanAlphabet,
    },
    // RFC 7932 §3.5 — the complex form, the 17 and 16 repeats, and the
    // single-symbol code-length code.
    .{
        .name = "complex_tree",
        .stream = golden.complex_tree_stream.bytes,
        .plain = golden.complex_tree_stream.plain,
    },
    .{
        .name = "complex_single",
        .stream = golden.complex_single_stream.bytes,
        .plain = golden.complex_single_stream.plain,
    },
    .{
        .name = "repeat16",
        .stream = golden.repeat16_stream.bytes,
        .plain = golden.repeat16_stream.plain,
    },
    // RFC 7932 §7.3 — a context map with RLEMAX runs and the IMTF.
    .{
        .name = "context_map",
        .stream = golden.context_map_stream.bytes,
        .plain = golden.context_map_stream.plain,
    },
    // RFC 7932 §4, §10 — the distance ring and the copy machinery.
    .{
        .name = "special_codes",
        .stream = golden.special_codes.bytes,
        .plain = golden.special_codes.plain,
    },
    .{
        .name = "ring_init_second",
        .stream = golden.ring_init_second.bytes,
        .plain = golden.ring_init_second.plain,
    },
    .{
        .name = "ring_init_third",
        .stream = golden.ring_init_third.bytes,
        .plain = golden.ring_init_third.plain,
    },
    .{
        .name = "ring_init_last",
        .stream = golden.ring_init_last.bytes,
        .plain = golden.ring_init_last.plain,
    },
    .{
        .name = "ring_no_push_zero",
        .stream = golden.ring_no_push_zero.bytes,
        .plain = golden.ring_no_push_zero.plain,
    },
    // RFC 7932 §9.3 — the ignored copy, and the two MLEN overruns (F4, F7).
    .{
        .name = "mlen_exact_insert",
        .stream = golden.mlen_exact_insert.bytes,
        .plain = golden.mlen_exact_insert.plain,
    },
    .{
        .name = "mlen_insert_overrun",
        .stream = golden.mlen_insert_overrun.bytes,
        .plain = "",
        .refusal = error.BadBlockLength,
    },
    .{
        .name = "mlen_copy_overrun",
        .stream = golden.mlen_copy_overrun.bytes,
        .plain = "",
        .refusal = error.BadBlockLength,
    },
    // RFC 7932 §4 — a special code resolving to zero.
    .{
        .name = "negative_special",
        .stream = golden.negative_special.bytes,
        .plain = "",
        .refusal = error.BadDistance,
    },
    // RFC 7932 §6, T1, T2 — the three block switches.
    .{
        .name = "block_switch_literal_t1",
        .stream = golden.block_switch_literal_t1.bytes,
        .plain = golden.block_switch_literal_t1.plain,
    },
    .{
        .name = "block_switch_command",
        .stream = golden.block_switch_command.bytes,
        .plain = golden.block_switch_command.plain,
    },
    .{
        .name = "distance_switch_t2",
        .stream = golden.distance_switch_t2.bytes,
        .plain = golden.distance_switch_t2.plain,
    },
    // RFC 7932 §4 — NDIRECT and NPOSTFIX arithmetic.
    .{ .name = "ndirect", .stream = golden.ndirect.bytes, .plain = golden.ndirect.plain },
    .{ .name = "npostfix", .stream = golden.npostfix.bytes, .plain = golden.npostfix.plain },
    // RFC 7932 §7.2, §7.1 — the distance context and the three modes.
    .{
        .name = "distance_context",
        .stream = golden.distance_context.bytes,
        .plain = golden.distance_context.plain,
    },
    .{
        .name = "context_mode_msb6",
        .stream = golden.context_mode_msb6.bytes,
        .plain = golden.context_mode_msb6.plain,
    },
    .{
        .name = "context_mode_utf8",
        .stream = golden.context_mode_utf8.bytes,
        .plain = golden.context_mode_utf8.plain,
    },
    .{
        .name = "context_mode_signed",
        .stream = golden.context_mode_signed.bytes,
        .plain = golden.context_mode_signed.plain,
    },
    // RFC 7932 §8 — the dictionary class, the transforms, and the two
    // refusals.
    .{
        .name = "dictionary_word",
        .stream = golden.dictionary_word.bytes,
        .plain = golden.dictionary_word.plain,
    },
    .{
        .name = "dictionary_ferment",
        .stream = golden.dictionary_ferment.bytes,
        .plain = golden.dictionary_ferment.plain,
    },
    .{
        .name = "dictionary_ferment_utf8",
        .stream = golden.dictionary_ferment_utf8.bytes,
        .plain = golden.dictionary_ferment_utf8.plain,
    },
    .{
        .name = "dictionary_affix",
        .stream = golden.dictionary_affix.bytes,
        .plain = golden.dictionary_affix.plain,
    },
    .{
        .name = "dictionary_omit",
        .stream = golden.dictionary_omit.bytes,
        .plain = golden.dictionary_omit.plain,
    },
    .{
        .name = "dictionary_identity_24",
        .stream = golden.dictionary_identity_24.bytes,
        .plain = golden.dictionary_identity_24.plain,
    },
    .{
        .name = "dictionary_empty",
        .stream = golden.dictionary_empty.bytes,
        .plain = golden.dictionary_empty.plain,
    },
    .{
        .name = "dictionary_transform",
        .stream = golden.dictionary_transform.bytes,
        .plain = "",
        .refusal = error.BadTransform,
    },
    .{
        .name = "dictionary_length",
        .stream = golden.dictionary_length.bytes,
        .plain = "",
        .refusal = error.BadDictionary,
    },
    // RFC 7932 §10 — a cross-meta-block copy and the stream-scoped ring.
    .{
        .name = "cross_meta_block",
        .stream = golden.cross_meta_block.bytes,
        .plain = golden.cross_meta_block.plain,
    },
    .{
        .name = "uncompressed_context",
        .stream = golden.uncompressed_context.bytes,
        .plain = golden.uncompressed_context.plain,
    },
    // RFC 7932 §8 — the window bound with WBITS 10.
    .{
        .name = "window_bound",
        .stream = golden.window_bound.bytes,
        .plain = golden.window_bound.plain,
    },
    // The pinned CLI's own streams (brotli 1.2.0, the flake's): the corpus's
    // encoder half, and the ring's live vector under a `Buffer(10)`.
    .{
        .name = "cli_text_q1",
        .stream = golden.cli_text_q1.bytes,
        .plain = golden.cli_text_q1.plain,
    },
    .{
        .name = "cli_text_q2",
        .stream = golden.cli_text_q2.bytes,
        .plain = golden.cli_text_q2.plain,
    },
    .{
        .name = "cli_text_q5",
        .stream = golden.cli_text_q5.bytes,
        .plain = golden.cli_text_q5.plain,
    },
    .{
        .name = "cli_text_q9",
        .stream = golden.cli_text_q9.bytes,
        .plain = golden.cli_text_q9.plain,
    },
    .{
        .name = "cli_text_q11",
        .stream = golden.cli_text_q11.bytes,
        .plain = golden.cli_text_q11.plain,
    },
    .{
        .name = "cli_small_window",
        .stream = golden.cli_small_window.bytes,
        .plain = golden.cli_small_window.plain,
    },
    .{
        .name = "cli_repeat_q1",
        .stream = golden.cli_repeat_q1.bytes,
        .plain = golden.cli_repeat_q1.plain,
    },
    .{
        .name = "cli_repeat_q2",
        .stream = golden.cli_repeat_q2.bytes,
        .plain = golden.cli_repeat_q2.plain,
    },
    .{
        .name = "cli_repeat_q5",
        .stream = golden.cli_repeat_q5.bytes,
        .plain = golden.cli_repeat_q5.plain,
    },
    .{
        .name = "cli_repeat_q9",
        .stream = golden.cli_repeat_q9.bytes,
        .plain = golden.cli_repeat_q9.plain,
    },
    .{
        .name = "cli_repeat_q11",
        .stream = golden.cli_repeat_q11.bytes,
        .plain = golden.cli_repeat_q11.plain,
    },
    .{ .name = "cli_run_q1", .stream = golden.cli_run_q1.bytes, .plain = golden.cli_run_q1.plain },
    .{ .name = "cli_run_q2", .stream = golden.cli_run_q2.bytes, .plain = golden.cli_run_q2.plain },
    .{ .name = "cli_run_q5", .stream = golden.cli_run_q5.bytes, .plain = golden.cli_run_q5.plain },
    .{ .name = "cli_run_q9", .stream = golden.cli_run_q9.bytes, .plain = golden.cli_run_q9.plain },
    .{
        .name = "cli_run_q11",
        .stream = golden.cli_run_q11.bytes,
        .plain = golden.cli_run_q11.plain,
    },
    .{
        .name = "cli_digits_q1",
        .stream = golden.cli_digits_q1.bytes,
        .plain = golden.cli_digits_q1.plain,
    },
    .{
        .name = "cli_digits_q2",
        .stream = golden.cli_digits_q2.bytes,
        .plain = golden.cli_digits_q2.plain,
    },
    .{
        .name = "cli_digits_q5",
        .stream = golden.cli_digits_q5.bytes,
        .plain = golden.cli_digits_q5.plain,
    },
    .{
        .name = "cli_digits_q9",
        .stream = golden.cli_digits_q9.bytes,
        .plain = golden.cli_digits_q9.plain,
    },
    .{
        .name = "cli_digits_q11",
        .stream = golden.cli_digits_q11.bytes,
        .plain = golden.cli_digits_q11.plain,
    },
};

fn vectorAt(index: usize) *const Vector {
    return &vectors[index % vectors.len];
}

/// The widest vector stream, for the seed tables' comptime sizing.
const widest_stream = blk: {
    var most: usize = 0;
    for (vectors) |vector| most = @max(most, vector.stream.len);
    break :blk most;
};

/// The index-addressed seeds: one per vector, so the smoke run (and the
/// fuzzer's first pass) walks the whole corpus.
const corpus_seeds: [vectors.len][]const u8 = blk: {
    var out: [vectors.len][]const u8 = undefined;
    for (&out, 0..) |*seed, i| seed.* = &index_seed_bytes[i];
    break :blk out;
};

const index_seed_bytes: [vectors.len][64]u8 = blk: {
    var out: [vectors.len][64]u8 = undefined;
    for (&out, 0..) |*seed, i| seed.* = indexSeed(i);
    break :blk out;
};

/// The raw-stream seeds: the corpus bytes as `fuzzCorruption` and
/// `fuzzDifferential` read them, so byte-level mutation starts from real
/// streams instead of discovering the format from scratch.
const stream_seeds: [vectors.len][]const u8 = blk: {
    var out: [vectors.len][]const u8 = undefined;
    for (&out, 0..) |*seed, i| {
        const len = 20 + vectors[i].stream.len;
        seed.* = stream_seed_bytes[i][0..len];
    }
    break :blk out;
};

const stream_seed_bytes: [vectors.len][20 + widest_stream]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var out: [vectors.len][20 + widest_stream]u8 = undefined;
    for (&out, 0..) |*slot, i| {
        const seed = streamSeed(vectors[i].stream);
        for (slot, 0..) |*byte, j| byte.* = if (j < seed.len) seed[j] else 0;
    }
    break :blk out;
};

// ---------------------------------------------------------------------------
// Mutation: the corruption taxonomy, shared by the corruption and
// differential targets
// ---------------------------------------------------------------------------

/// The operators `fuzzCorruption` applies to a corpus stream. Three of them
/// have a deterministic verdict on the wire and are pinned where they are
/// applied: `truncate` (`§10`), `invalid_wbits` (`§9.1`), and `append_tail`
/// (T4).
const Mutation = enum(u8) {
    /// The stream as it is.
    none,
    /// A strict prefix (`§10`: "If the stream ends before the completion of
    /// the last meta-block, then the stream should be rejected as invalid").
    truncate,
    flip_bit,
    flip_byte,
    zero_run,
    fill_run,
    drop_run,
    duplicate_run,
    insert_run,
    /// `§9.1`'s 0010001 pattern in the first seven bits, T3's large-window
    /// marker: `BadWindowBits` for the one-shot, `BadStreamStart` for a
    /// reader at a start position (F10).
    invalid_wbits,
    /// Bytes after the stream's last byte: ignored by the one-shot (T4).
    append_tail,
};

const Built = struct {
    source: []const u8,
    /// The corpus vector the source came from, when it did not come from the
    /// raw input.
    vector: ?*const Vector,
    op: Mutation,
};

/// Build one mutated stream: a corpus vector or the raw input, then one
/// operator. Every field is read from the Smith input in a fixed order, so a
/// hand-built seed can pin each one.
fn buildMutation(smith: *Smith, buf: []u8) Built {
    const mode = rangeAtMost(smith, 0, 1);
    const index = rangeAtMost(smith, 0, vectors.len - 1);
    var raw_buf: [source_max]u8 = undefined;
    const raw_len = smith.slice(&raw_buf);
    const op = smith.value(Mutation);
    const base: []const u8 = if (mode == 0) vectors[index].stream else raw_buf[0..raw_len];
    const vector: ?*const Vector = if (mode == 0) &vectors[index] else null;

    // The operator's parameters, read up front so the seed layout is fixed.
    const at = rangeAtMost(smith, 0, base.len);
    const run = rangeAtMost(smith, 0, base.len);
    const value = rangeAtMost(smith, 0, 255);
    return .{ .source = applyMutation(op, base, buf, at, run, value), .vector = vector, .op = op };
}

/// Apply one operator to `base`, writing into `out` and returning the
/// mutated slice. `out.len` must be at least `base.len + growth_max`; every
/// operator is bounded by the slice it is given.
fn applyMutation(
    op: Mutation,
    base: []const u8,
    out: []u8,
    at: usize,
    run: usize,
    value: usize,
) []const u8 {
    @setEvalBranchQuota(20_000);
    assert(out.len >= base.len + growth_max);
    const len = base.len;
    switch (op) {
        .none => {
            fastmem.copy(u8, out[0..len], base);
            return out[0..len];
        },
        .truncate => {
            // A strict prefix, so the `§10` rule applies: the full stream is
            // valid (or refuses at a point the prefix cannot reach) and this
            // is shorter.
            const cut = if (len == 0) 0 else at % len;
            fastmem.copy(u8, out[0..cut], base[0..cut]);
            return out[0..cut];
        },
        .flip_bit, .flip_byte => {
            fastmem.copy(u8, out[0..len], base);
            if (len == 0) return out[0..0];
            if (op == .flip_bit) {
                const bit = at % (len * 8);
                out[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
            } else {
                out[at % len] ^= @intCast(1 + value % 255);
            }
            return out[0..len];
        },
        .zero_run, .fill_run => {
            fastmem.copy(u8, out[0..len], base);
            if (len == 0) return out[0..0];
            const start = at % len;
            const count = @min(1 + run % 32, len - start);
            const byte: u8 = if (op == .zero_run) 0 else @intCast(value);
            fastmem.set(u8, out[start..][0..count], byte);
            return out[0..len];
        },
        .drop_run => {
            if (len == 0) return out[0..0];
            const start = at % len;
            const count = @min(1 + run % 32, len - start);
            const kept = len - count;
            fastmem.copy(u8, out[0..start], base[0..start]);
            fastmem.copy(u8, out[start..kept], base[start + count ..][0 .. kept - start]);
            return out[0..kept];
        },
        .duplicate_run, .insert_run => {
            const start = if (len == 0) 0 else at % len;
            const count = @min(1 + run % 32, len - start);
            fastmem.copy(u8, out[0..start], base[0..start]);
            if (op == .duplicate_run) {
                fastmem.copy(u8, out[start..][0..count], base[start..][0..count]);
            } else {
                fastmem.set(u8, out[start..][0..count], @intCast(value));
            }
            const tail = len - start;
            fastmem.copy(u8, out[start + count ..][0..tail], base[start..][0..tail]);
            return out[0 .. len + count];
        },
        .invalid_wbits => {
            fastmem.copy(u8, out[0..len], base);
            if (len == 0) return out[0..0];
            // §9.1's 0010001, transmitted low bit first: bit 0 = 1, bit 4 = 1.
            out[0] = (out[0] & 0x80) | 0x11;
            return out[0..len];
        },
        .append_tail => {
            const count = 1 + value % growth_max;
            fastmem.copy(u8, out[0..len], base);
            fastmem.set(u8, out[len..][0..count], marker_byte);
            return out[0 .. len + count];
        },
    }
}

/// The refusal `truncate` pins on a prefix of `vector`: `§10`'s `Truncated`
/// for a valid stream; for a refusing stream either `Truncated` or the same
/// class the full stream reports, because the parse of a prefix is a prefix
/// of the full stream's parse (a prefix can only run out of input, never
/// find a different failure).
fn truncationRefusal(vector: ?*const Vector, err: decode.DecompressError) bool {
    if (err == error.Truncated) return true;
    const v = vector orelse return false;
    const want = v.refusal orelse return false;
    return err == want;
}

// ---------------------------------------------------------------------------
// The golden corpus through the one-shot decoder
// ---------------------------------------------------------------------------

/// The golden corpus through the one-shot decoder, at the exact cap, with
/// slack, and one byte short of the decoded length.
///
/// The property: a valid vector decodes to exactly its model bytes, with
/// every byte past them untouched; a refusal vector fails with the class the
/// pinned CLI recorded (`brotli -d -v -c`'s reason, `AGENTS.md`'s table); and
/// a cap one byte below the decoded length is `BufferTooSmall` before the
/// write that would pass it (`§9.3`'s accounting stays the invalid-stream
/// class, never this one). The guard check runs on every outcome: pass or
/// fail, nothing at or past the cap moved.
fn fuzzGoldenCorpus(_: void, smith: *Smith) anyerror!void {
    const vector = vectorAt(rangeAtMost(smith, 0, vectors.len - 1));
    var target: [corpus_out_max + guard_len]u8 = undefined;
    sentinel.fill(&target);

    if (vector.refusal) |want| {
        try testing.expectError(want, decode.decompress(vector.stream, &target));
        try sentinel.expect(&target, corpus_out_max);
        return;
    }

    const shape = rangeAtMost(smith, 0, 2);
    const cap: usize = switch (shape) {
        0 => vector.plain.len,
        1 => @min(vector.plain.len + rangeAtMost(smith, 1, guard_len), corpus_out_max),
        else => vector.plain.len -| 1,
    };
    const result = decode.decompress(vector.stream, target[0..cap]);
    if (vector.plain.len > cap) {
        // §9.3 — the cap is the caller's, checked before the write.
        try testing.expectError(error.BufferTooSmall, result);
        try sentinel.expect(&target, cap);
        return;
    }
    const n = try result;
    try testing.expectEqual(vector.plain.len, n);
    try testing.expectEqualSlices(u8, vector.plain, target[0..n]);
    try sentinel.expect(&target, cap);
}

// ---------------------------------------------------------------------------
// The truncation ladder
// ---------------------------------------------------------------------------

/// A strict prefix of a corpus stream, through both entry points.
///
/// RFC 7932 §10: "If the stream ends before the completion of the last
/// meta-block, then the stream should be rejected as invalid" — every strict
/// prefix of a valid stream is `Truncated`, never accepted as a shorter
/// stream. A prefix of a *refusing* stream is `Truncated` or the same class
/// the full stream reports, because the parse of a prefix is a prefix of the
/// full stream's parse: it can run out of input, never find a different
/// failure. The `Reader` must agree, and the one-shot's cap is never touched.
fn fuzzTruncation(storage: *Storage, smith: *Smith) anyerror!void {
    const vector = vectorAt(rangeAtMost(smith, 0, vectors.len - 1));
    const cut = if (vector.stream.len == 0) 0 else rangeAtMost(smith, 0, vector.stream.len - 1);
    const source = vector.stream[0..cut];

    sentinel.fill(&storage.out);
    const result = decode.decompress(source, storage.out[0..corpus_out_max]);
    try sentinel.expect(&storage.out, corpus_out_max);
    if (result) |n| {
        // A prefix of a valid stream decoded: §10 says it cannot, and the
        // corpus has no vector whose refusal lives in the bytes a prefix
        // drops.
        if (vector.refusal == null) {
            std.debug.print("brotli fuzz: prefix of {s} decoded {d} bytes\n", .{ vector.name, n });
            return error.ShortDecode;
        }
        return;
    } else |err| {
        if (!truncationRefusal(vector, err)) {
            std.debug.print(
                "brotli fuzz: prefix of {s} cut at {d} refused with {t}\n",
                .{ vector.name, cut, err },
            );
            return error.TruncationClass;
        }
        // The streaming reader over the same prefix must report the same
        // class. (A prefix of a *refusing* stream can reach the refusal, so
        // the shared class is the assertion; `Truncated` is the valid
        // vectors' case, which `truncationRefusal` pinned above.)
        const streamed = try streamSource(24, source, &storage.ring24, &storage.read_out, &.{});
        try testing.expectEqual(Stop.read_failed, streamed.stop);
        const detail = streamed.detail.?;
        if (detail != err) {
            std.debug.print(
                "brotli fuzz: {s}'s prefix: one-shot {t}, reader {t}\n",
                .{ vector.name, err, detail },
            );
            return error.ReaderTruncationClass;
        }
        return;
    }
}

// ---------------------------------------------------------------------------
// The corruption taxonomy
// ---------------------------------------------------------------------------

/// The mutation taxonomy over the corpus, with the named class pinned where
/// the wire rule makes the verdict deterministic.
///
/// RFC 7932 has no integrity check (T6), so a random flip may either fail
/// with a named class or decode to *different* bytes; both are conformant,
/// and this target asserts neither. What it does assert: the error is a name
/// from `DecompressError` (the type is the proof), the guard past the cap is
/// untouched on every outcome, and the three mutations whose verdict the
/// format fixes are pinned by class — `§9.1`'s 0010001 (`BadWindowBits`),
/// `§10`'s truncation rule (`Truncated`), and T4's trailing bytes (the
/// vector's own verdict, byte for byte).
fn fuzzCorruption(_: void, smith: *Smith) anyerror!void {
    var buf: [mutation_max]u8 = undefined;
    const built = buildMutation(smith, &buf);
    var target: [out_max + guard_len]u8 = undefined;
    sentinel.fill(&target);

    const result = decode.decompress(built.source, target[0..out_max]);
    try sentinel.expect(&target, out_max);
    if (result) |n| {
        try testing.expect(n <= out_max);
    } else |_| {
        // Every failure is a name from `DecompressError`: the return type is
        // the proof, and the guard above is the write check.
    }

    switch (built.op) {
        .truncate => {
            if (result) |n| {
                if (built.vector) |vector| {
                    std.debug.print(
                        "brotli fuzz: prefix of {s} decoded {d} bytes\n",
                        .{ vector.name, n },
                    );
                    return error.ShortDecode;
                }
            } else |err| {
                const vector = built.vector orelse return;
                if (!truncationRefusal(vector, err)) {
                    std.debug.print(
                        "brotli fuzz: prefix of {s} refused with {t}\n",
                        .{ vector.name, err },
                    );
                    return error.TruncationClass;
                }
            }
        },
        .invalid_wbits => {
            // §9.1 — 0010001 "is invalid and must not be used", read first.
            if (built.source.len > 0) try testing.expectError(error.BadWindowBits, result);
        },
        .append_tail => {
            // T4 — the bytes after a *complete* stream's last byte are not
            // the decoder's: the verdict is the vector's own, and a valid
            // vector still decodes to its model. (A stream that failed
            // because it ran out of input is not complete, so a tail changes
            // what it parses; those vectors are skipped.)
            const vector = built.vector orelse return;
            if (vector.refusal != null and vector.refusal.? == error.Truncated) return;
            if (vector.refusal) |want| try testing.expectError(want, result);
            if (vector.refusal == null) {
                const n = try result;
                try testing.expectEqual(vector.plain.len, n);
                try testing.expectEqualSlices(u8, vector.plain, target[0..n]);
            }
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// The in-process differential: one-shot against the streaming reader
// ---------------------------------------------------------------------------

/// The one-shot against the `Reader`: the same bytes through both entry
/// points must give the same verdict, the same named class, and the same
/// output.
///
/// This is the differential the codec can run in-process — there is no
/// encoder and no in-process reference decoder, so the one-shot is the
/// oracle the streaming path is checked against (and `just brotli-oracle`
/// the external one). It runs on the corpus and on every mutation the
/// corruption target produces. Three wire rules are pinned exactly: `§9.1`'s
/// window cap (`WindowTooLarge` exactly when the declared window exceeds the
/// ring), F10's name split (`BadStreamStart` is the reader's name for the
/// pattern the one-shot calls `BadWindowBits`), and T4's boundary (a
/// `Reader` over an unbuffered input consumes the stream's last byte + 1).
/// The one-shot's own cap (`BufferTooSmall`) has no reader counterpart — the
/// ring is the reader's cap — so a stream that declares more than the cap
/// only requires that the reader not have ended cleanly short of it.
fn fuzzDifferential(storage: *Storage, smith: *Smith) anyerror!void {
    var buf: [mutation_max]u8 = undefined;
    const built = buildMutation(smith, &buf);
    const source = built.source;

    sentinel.fill(&storage.out);
    const one = decode.decompress(source, storage.out[0..out_max]);
    try sentinel.expect(&storage.out, out_max);

    // The input's handover: whole at once, or in chunks from the four-byte
    // floor the reader's `StreamBits` seam needs (`README.md`).
    const chunk_len = rangeAtMost(smith, 0, storage.chunk.len);
    const chunk: []u8 = if (chunk_len < 4) &.{} else storage.chunk[0..chunk_len];
    const streamed = switch (rangeAtMost(smith, 0, 3)) {
        0 => try streamSource(10, source, &storage.ring10, &storage.read_out, chunk),
        1 => try streamSource(16, source, &storage.ring16, &storage.read_out, chunk),
        else => try streamSource(24, source, &storage.ring24, &storage.read_out, chunk),
    };
    // §9.1 — the ring is the window authorization: `WindowTooLarge` exactly
    // when the stream's declared window exceeds the ring's capacity, before
    // any meta-block byte.
    if (streamed.detail) |err| {
        if (err == error.WindowTooLarge) {
            const declared = declaredWindowSize(source) orelse return error.WindowWithoutHeader;
            try testing.expect(declared > streamed.capacity - 16);
            try testing.expectEqual(@as(usize, 0), streamed.served);
            if (one) |_| {} else |one_err| {
                // The one-shot read the same header bits; it cannot have
                // refused them.
                try testing.expect(one_err != error.BadWindowBits);
            }
            return;
        }
    }

    // The reader never consumes past its input, whatever it decoded.
    try testing.expect(streamed.consumed <= source.len);
    // T4 — an unbuffered reader that ends cleanly consumed the stream's last
    // byte + 1, which for an unmutated corpus stream is the whole slice. (A
    // raw source may carry trailing bytes the stream does not own.)
    if (built.vector != null and built.op == .none and chunk.len == 0) {
        if (streamed.stop == .end_of_stream) {
            try testing.expectEqual(source.len, streamed.consumed);
        }
    }

    if (one) |n| {
        // The one-shot decoded the whole stream inside the cap: the reader
        // must have served exactly it and ended cleanly. (`end_of_stream`
        // wins even when the stream ends exactly at the drain cap: the
        // reader's done state is checked before the writer is touched, which
        // the bomb test's exact-cap case pins.)
        if (streamed.stop != .end_of_stream or streamed.served != n) {
            std.debug.print(
                "brotli fuzz: one-shot {d} bytes, reader {s} after {d}\n",
                .{ n, @tagName(streamed.stop), streamed.served },
            );
            return error.VerdictMismatch;
        }
        try testing.expectEqualSlices(u8, storage.out[0..n], storage.read_out[0..n]);
        return;
    } else |one_err| {
        try expectOneShotRefusal(streamed, one_err);
    }
}

/// The reader's side of a one-shot refusal: the same class through
/// `sharedName`, except for `BufferTooSmall`, which the reader has no name
/// for (its cap is the ring).
fn expectOneShotRefusal(streamed: Streamed, one_err: decode.DecompressError) !void {
    if (one_err == error.BufferTooSmall) {
        // The one-shot says the stream's declared output exceeds the cap, so
        // the reader — whose own cap is its ring, drained at most `out_max`
        // bytes — cannot have ended cleanly: that would mean the stream fit
        // after all.
        if (streamed.stop == .end_of_stream) {
            std.debug.print(
                "brotli fuzz: one-shot BufferTooSmall, reader ended after {d}\n",
                .{streamed.served},
            );
            return error.CapMismatch;
        }
        return;
    }
    try testing.expectEqual(Stop.read_failed, streamed.stop);
    const detail = streamed.detail.?;
    const mapped = sharedName(detail) orelse {
        std.debug.print("brotli fuzz: reader-only refusal {t} on a pump\n", .{detail});
        return error.ReaderOnlyRefusal;
    };
    if (mapped != one_err) {
        std.debug.print("brotli fuzz: one-shot {t}, reader {t}\n", .{ one_err, detail });
        return error.ClassMismatch;
    }
}

test "brotli fuzz: golden corpus" {
    try testing.fuzz({}, fuzzGoldenCorpus, .{ .corpus = &corpus_seeds });
}

test "brotli fuzz: truncation ladder" {
    const storage = try testing.allocator.create(Storage);
    defer testing.allocator.destroy(storage);
    try testing.fuzz(storage, fuzzTruncation, .{ .corpus = &corpus_seeds });
}

test "brotli fuzz: corruption" {
    try testing.fuzz({}, fuzzCorruption, .{ .corpus = &stream_seeds });
}

test "brotli fuzz: one-shot vs reader" {
    const storage = try testing.allocator.create(Storage);
    defer testing.allocator.destroy(storage);
    try testing.fuzz(storage, fuzzDifferential, .{ .corpus = &stream_seeds });
}

// ---------------------------------------------------------------------------
// The reader's consumer surface
// ---------------------------------------------------------------------------

/// The consumer operations `fuzzReaderMachinery` mixes: the `Io.Reader`
/// calls a consumer makes, plus the two the reader's own policy answers.
const ReadOp = enum(u8) {
    peek,
    take,
    discard,
    stream_fixed,
    /// The zero-length request (a poll): `stream` with `.limited(0)` answers
    /// 0 without filling, even mid-stream.
    poll,
    /// A contiguous request one byte past the ring's room at the read
    /// position: the documented `StreamTooLong`, never an assert (std's own
    /// `rebase` asserts here).
    over_cap_peek,
};

/// The ring for one instantiation, from the harness's storage.
fn ringFor(comptime wbits: usize, storage: *Storage) *Reader.Buffer(wbits) {
    return switch (wbits) {
        10 => &storage.ring10,
        16 => &storage.ring16,
        else => &storage.ring24,
    };
}

/// The `Io.Reader` consumer surface over the corpus, with a ring small
/// enough to wrap under a real copy.
///
/// Exercises `peek`/`take`/`discard`/`stream`, the zero-length poll, the
/// contiguous-read cap (`StreamTooLong`), the ring wrap, the sticky end, and
/// the exact input boundary (T4). Every served byte is checked against the
/// vector's model, and every request is bounded by the ring's room at the
/// read position — the README's consumer contract — except the one op that
/// deliberately asks past it. A `WindowTooLarge` stream, a refusal vector,
/// and a clean end each have one pinned outcome.
fn fuzzReaderMachinery(storage: *Storage, smith: *Smith) anyerror!void {
    const vector = vectorAt(rangeAtMost(smith, 0, vectors.len - 1));
    const chunk_len = rangeAtMost(smith, 0, storage.chunk.len);
    const chunk: []u8 = if (chunk_len < 4) &.{} else storage.chunk[0..chunk_len];
    const ops = 1 + rangeAtMost(smith, 0, 63);
    // The ring: the smallest instantiation that admits the stream's declared
    // window half the time (so the ring wraps under real copies), and the
    // floor the other half, where the window cap is the pin.
    const declared = declaredWindowSize(vector.stream) orelse 1008;
    const smallest: usize = if (declared <= 1008) 10 else if (declared <= 65520) 16 else 24;
    const wbits = if (rangeAtMost(smith, 0, 1) == 0) smallest else 10;
    switch (wbits) {
        10 => try machineryAt(10, storage, vector, chunk, ops, smith),
        16 => try machineryAt(16, storage, vector, chunk, ops, smith),
        else => try machineryAt(24, storage, vector, chunk, ops, smith),
    }
}

fn machineryAt(
    comptime wbits: usize,
    storage: *Storage,
    vector: *const Vector,
    chunk: []u8,
    ops: usize,
    smith: *Smith,
) !void {
    var fixed_in: Io.Reader = .fixed(vector.stream);
    var limited: Io.Reader.Limited = undefined;
    const input: *Io.Reader = if (chunk.len == 0) &fixed_in else blk: {
        limited = .init(&fixed_in, .unlimited, chunk);
        break :blk &limited.interface;
    };
    var r: Reader = .init(wbits, input, ringFor(wbits, storage));
    var wbuf: [512]u8 = undefined;

    // A valid vector's model is its decoded bytes; a refusal vector has no
    // model, so its ops run against the ring's room alone and only the
    // refusal class is pinned.
    const valid = vector.refusal == null;
    var pos: usize = 0;
    var count: usize = 0;
    while (count < ops) : (count += 1) {
        if (valid and pos == vector.plain.len) break;
        // The contiguous room the reader's rebase grants, from the same
        // expression it uses.
        const room = r.reader.buffer.len - r.reader.seek;
        const left = if (valid) vector.plain.len - pos else room;
        const want = if (room == 0)
            @as(usize, 1)
        else
            @min(left, 1 + rangeAtMost(smith, 0, room - 1));
        switch (smith.value(ReadOp)) {
            .peek, .take => {
                const got = r.reader.peek(want) catch |err| {
                    return expectTerminal(vector, err, &r, &fixed_in, pos, wbits, chunk.len);
                };
                try testing.expectEqual(want, got.len);
                if (valid) try testing.expectEqualSlices(u8, vector.plain[pos..][0..want], got);
                r.reader.toss(want);
                pos += want;
            },
            .discard => {
                r.reader.discardAll(want) catch |err| {
                    return expectTerminal(vector, err, &r, &fixed_in, pos, wbits, chunk.len);
                };
                pos += want;
            },
            .stream_fixed => {
                // The request is also bounded by the harness's own buffer:
                // the writer, not the reader, is the one that can overflow.
                const request = @min(want, wbuf.len);
                var w: Io.Writer = .fixed(&wbuf);
                const n = r.reader.stream(&w, .limited(request)) catch |err| {
                    return expectTerminal(vector, err, &r, &fixed_in, pos, wbits, chunk.len);
                };
                if (valid) try testing.expectEqualSlices(u8, vector.plain[pos..][0..n], wbuf[0..n]);
                pos += n;
            },
            .poll => {
                var w: Io.Writer = .fixed(&wbuf);
                try testing.expectEqual(@as(usize, 0), try r.reader.stream(&w, .limited(0)));
            },
            .over_cap_peek => {
                // One past the ring itself, so no wrap can make room for it:
                // `Io.Reader.rebase` forwards to the reader's policy, which
                // refuses with `StreamTooLong`.
                const got = r.reader.peek(r.reader.buffer.len + 1) catch |err| {
                    try testing.expectEqual(error.ReadFailed, err);
                    try testing.expectEqual(Reader.Error.StreamTooLong, r.err.?);
                    return;
                };
                _ = got;
                return error.PeekPastRoomServed;
            },
        }
    }
}

/// A `peek`/`discard`/`stream` failure: the clean end, the window cap, or
/// the vector's own refusal — each pinned, and the boundary checked at a
/// clean end (T4).
fn expectTerminal(
    vector: *const Vector,
    err: Io.Reader.StreamError,
    r: *Reader,
    input: *Io.Reader,
    pos: usize,
    comptime wbits: usize,
    chunk_len: usize,
) !void {
    switch (err) {
        error.EndOfStream => {
            // A clean end is the valid vectors' outcome, and it serves the
            // whole model and nothing else.
            if (vector.refusal != null) {
                std.debug.print("brotli fuzz: {s} refused but the reader ended\n", .{vector.name});
                return error.RefusalDecoded;
            }
            if (pos != vector.plain.len) {
                std.debug.print(
                    "brotli fuzz: {s} ended at {d} of {d}\n",
                    .{ vector.name, pos, vector.plain.len },
                );
                return error.EarlyEnd;
            }
            // T4 — an unbuffered input is consumed through the stream's last
            // byte and no further.
            if (chunk_len == 0) try testing.expectEqual(vector.stream.len, input.seek);
        },
        error.ReadFailed => {
            const detail = r.err.?;
            if (detail == error.WindowTooLarge) {
                const declared = declaredWindowSize(vector.stream) orelse
                    return error.WindowWithoutHeader;
                try testing.expect(declared > (@as(u32, 1) << wbits) - 16);
                return;
            }
            const want = vector.refusal orelse {
                std.debug.print(
                    "brotli fuzz: {s} refused {t} with none expected\n",
                    .{ vector.name, detail },
                );
                return error.UnexpectedRefusal;
            };
            if (detail != want) {
                std.debug.print(
                    "brotli fuzz: {s} refused {t}, want {t}\n",
                    .{ vector.name, detail, want },
                );
                return error.RefusalClass;
            }
        },
        // The fixed writer is sized by the request, so this cannot happen.
        error.WriteFailed => return error.UnexpectedWriteFailure,
    }
}

// ---------------------------------------------------------------------------
// Amplification: caps and bombs
// ---------------------------------------------------------------------------

/// The bomb's command: `§5`'s range-0 symbol for insert 5 and copy 9 with
/// the implicit distance, whose extra-bit fields are both empty. A
/// single-symbol tree decodes it in zero bits, so the command stream costs
/// nothing and the declared MLEN is produced from a handful of bytes.
const bomb_insert = 5;
const bomb_copy = 9;
const bomb_command: u16 = (bomb_insert << 3) | (bomb_copy - 2);

/// The largest bomb MLEN: a whole number of commands under `§9.2`'s 24-bit
/// maximum, verified against the pinned CLI (`brotli -d -c` decodes it to
/// 16,777,208 bytes of `'A'`).
const bomb_mlen_max: u32 = 14 * 1_198_372;

/// The smallest MLEN the bomb can express: one insert-only command.
const bomb_mlen_min: u32 = bomb_insert;

/// `§9.2`'s MNIBBLES for `mlen`: the smallest of 4, 5, and 6 nibbles that
/// holds it, which is also what keeps the top nibble nonzero (the
/// `ExuberantNibble` rule).
fn bombNibbles(mlen: u32) u5 {
    if (mlen <= 1 << 16) return 4;
    if (mlen <= 1 << 20) return 5;
    return 6;
}

/// Build the bomb stream for `mlen` into `out`, returning its bytes. The
/// wire is `golden.Packer`'s; the shape was verified against the pinned CLI
/// (brotli 1.2.0) before landing: `brotli -d -c` decodes `bombStream(5)` to
/// five `'A'`s (the last command's copy is ignored, `§9.3`), `14` to
/// fourteen, and refuses 4, 6..13, and 15..18 with
/// `FORMAT_BLOCK_LENGTH_2 (-10)` — our `BadBlockLength` (F7).
fn bombStream(mlen: u32, out: []u8) usize {
    // Any MLEN the 24-bit field can hold is buildable: the lengths the
    // command stream cannot land on exactly are the refusals under test.
    assert(mlen >= 1);
    assert(mlen <= bomb_mlen_max);
    var p: golden.Packer = .{};
    // §9.1 — WBITS 10 (the 7-bit pattern 1, 0b000, 0b010): a 1,008-byte
    // window, so a `Buffer(10)` ring (1,024 bytes) admits the bomb and wraps
    // under its copies.
    p.pack(1, 1);
    p.pack(0, 3);
    p.pack(2, 3);
    p.pack(1, 1); // ISLAST
    p.pack(0, 1); // ISLASTEMPTY = 0
    const nibbles = bombNibbles(mlen);
    p.pack(nibbles - 4, 2); // MNIBBLES
    p.pack(mlen - 1, nibbles * 4);
    p.pack(0, 1); // NBLTYPESL = 1
    p.pack(0, 1); // NBLTYPESI = 1
    p.pack(0, 1); // NBLTYPESD = 1
    p.pack(0, 2); // NPOSTFIX = 0
    p.pack(0, 4); // NDIRECT = 0
    p.pack(0, 2); // context mode LSB6
    p.pack(0, 1); // NTREESL = 1
    p.pack(0, 1); // NTREESD = 1
    packSingleTree(&p, 'A', 8); // the literal tree
    packSingleTree(&p, bomb_command, 10); // the insert-and-copy tree
    packSingleTree(&p, 0, 6); // the distance tree
    const stream = p.slice();
    fastmem.copy(u8, out[0..stream.len], stream);
    return stream.len;
}

/// `§3.4`'s simple form with NSYM = 1: one symbol, zero bits per decode.
fn packSingleTree(p: *golden.Packer, symbol: u16, alphabet_bits: u5) void {
    p.pack(1, 2); // the simple form
    p.pack(0, 2); // NSYM - 1 = 0
    p.pack(symbol, alphabet_bits);
}

/// Caps against bomb-shaped streams: a small input must never decode past
/// the declared output length, and a bomb must fail closed rather than
/// allocate or write unbounded.
///
/// The bomb is a real one: ten bytes that declare up to 16 MiB (`§9.2`'s
/// 24-bit MLEN) and produce it with zero-bit commands (`§5`). Two rules are
/// checked. First, the cap: at the declared length the decode is exact and
/// byte-identical to the model, one byte short is `BufferTooSmall` *before*
/// the write, and a declared length above the cap is refused with nothing
/// written past it — the guard region proves it. Second, the streaming side:
/// the ring is the reader's cap, so a bomb is drained only up to the
/// harness's own cap, with every served byte checked against the model and
/// the drain terminating inside the call budget (a reader that spun here is
/// the bug class this catches).
fn fuzzAmplification(storage: *Storage, smith: *Smith) anyerror!void {
    var stream_buf: [128]u8 = undefined;
    const shape = rangeAtMost(smith, 0, 4);
    const mlen: u32 = switch (shape) {
        0 => bomb_mlen_max,
        1 => 14 * @as(u32, @intCast(1 + rangeAtMost(smith, 0, 4680))),
        2 => bomb_mlen_min,
        3 => bomb_mlen_min - 1,
        // A copy overrun: one byte past a whole number of commands.
        else => 14 * @as(u32, @intCast(1 + rangeAtMost(smith, 0, 8))) + 1,
    };
    const stream = stream_buf[0..bombStream(mlen, &stream_buf)];
    // §9.3 — a command lands exactly when MLEN is a whole number of commands
    // (14 bytes each: a 5-literal insert and a 9-byte copy) or one insert
    // short of one (a 5-byte tail, where the copy is ignored). Anything else
    // overruns: the CLI's FORMAT_BLOCK_LENGTH_2 (F7), our `BadBlockLength`.
    const lands = mlen % 14 == 0 or
        (mlen >= bomb_insert and (mlen - bomb_insert) % 14 == 0);
    const overrun = !lands;

    sentinel.fill(&storage.out);
    if (overrun and mlen <= out_max) {
        try testing.expectError(
            error.BadBlockLength,
            decode.decompress(stream, storage.out[0..out_max]),
        );
        try sentinel.expect(&storage.out, out_max);
    } else if (mlen > corpus_out_max) {
        // Above the cap: refused before the write that would pass it.
        try testing.expectError(
            error.BufferTooSmall,
            decode.decompress(stream, storage.out[0..corpus_out_max]),
        );
        try sentinel.expect(&storage.out, corpus_out_max);
    } else {
        // At the declared length: exact, byte for byte against the model.
        const n = try decode.decompress(stream, storage.out[0..mlen]);
        try testing.expectEqual(mlen, n);
        // The model: every command inserts `'A'` and copies a four-byte
        // window of what it already wrote, so the output is all `'A'`.
        for (storage.out[0..n]) |byte| try testing.expectEqual(@as(u8, 'A'), byte);
        try sentinel.expect(&storage.out, mlen);
        // One byte short: `BufferTooSmall`, nothing past the cap.
        if (mlen > 0) {
            sentinel.fill(&storage.out);
            try testing.expectError(
                error.BufferTooSmall,
                decode.decompress(stream, storage.out[0 .. mlen - 1]),
            );
            try sentinel.expect(&storage.out, mlen - 1);
        }
    }

    // The streaming side: the 1 KiB ring is the cap, the drain stops at
    // `out_max`, and every byte served is the model's. The bomb's WBITS is
    // 10, so the ring admits it and wraps under the copies.
    const streamed = try streamSource(10, stream, &storage.ring10, &storage.read_out, &.{});
    try testing.expect(streamed.served <= out_max);
    for (storage.read_out[0..streamed.served]) |byte| try testing.expectEqual(@as(u8, 'A'), byte);
    if (streamed.stop == .read_failed) {
        // An MLEN the commands cannot land on is the same `BadBlockLength`
        // through the reader. Any other refusal means the bomb was
        // mis-built: the window cap cannot fire (the bomb declares WBITS 10
        // and the ring is `Buffer(10)`).
        const detail = streamed.detail.?;
        if (!overrun or detail != error.BadBlockLength) {
            std.debug.print("brotli fuzz: bomb refused {t}\n", .{detail});
            return error.BombRefused;
        }
    }
}

// ---------------------------------------------------------------------------
// The bit reader
// ---------------------------------------------------------------------------

/// The model bit at absolute index `i` of `source` (`§1.5.1`: bit `i` is
/// byte `i / 8`, bit `i % 8`), zero past the input's end — the padding `peek`
/// reads and `take` refuses.
fn modelBit(source: []const u8, i: usize) u32 {
    if (i >= source.len * 8) return 0;
    return (source[i / 8] >> @intCast(i % 8)) & 1;
}

/// The model's `n`-bit value at `pos`, least significant bit first.
fn modelBits(source: []const u8, pos: usize, n: u6) u32 {
    var value: u32 = 0;
    var i: u6 = 0;
    while (i < n) : (i += 1) value |= modelBit(source, pos + i) << @intCast(i);
    return value;
}

/// The bit reader (`§1.5`) against a bit-at-a-time model.
///
/// Every read is checked against the model of `§1.5.1`: `peek` never fails
/// and reads zero padding past the input's end; `take` succeeds exactly when
/// `n` bits remain and is the gate that turns a starved read into
/// `Truncated`, never a value out of padding; `alignToByte` is the checked
/// fill (`BadPadding` on a nonzero fill, `§9.2`/`§9.3`); `takeBytes` and
/// `skipBytes` are exact at a byte boundary; and `attach`/`rewind` — the
/// streaming seam (F11) — preserve the bits the accumulator holds.
fn fuzzBits(_: void, smith: *Smith) anyerror!void {
    var source_buf: [source_max]u8 = undefined;
    const source = source_buf[0..smith.slice(&source_buf)];
    var br: bits.BitReader = .init(source);

    const ops = 1 + rangeAtMost(smith, 0, 31);
    var op: usize = 0;
    while (op < ops) : (op += 1) {
        const pos: usize = @intCast(br.bit_pos);
        switch (rangeAtMost(smith, 0, 5)) {
            0, 1 => {
                const n: u6 = @intCast(1 + rangeAtMost(smith, 0, bits.max_read_bits - 1));
                const peeked = try br.peek(n);
                try testing.expectEqual(modelBits(source, pos, n), peeked);
                if (pos + n <= source.len * 8) {
                    try testing.expectEqual(peeked, try br.take(n));
                    try testing.expectEqual(pos + n, br.bit_pos);
                    try testing.expectEqual((source.len * 8) - pos - n, br.availableBits());
                } else {
                    try testing.expectError(error.Truncated, br.take(n));
                    try testing.expectEqual(pos, br.bit_pos);
                }
            },
            2 => {
                // The checked align: the skipped bits are a fill field the
                // format requires to be zero.
                const skip: u6 = @intCast((8 - (pos & 7)) & 7);
                if (skip == 0) continue;
                if (pos + skip > source.len * 8) {
                    // Starved: the take refuses before consuming a bit.
                    try testing.expectError(error.Truncated, br.alignToByte());
                    try testing.expectEqual(pos, br.bit_pos);
                    continue;
                }
                const fill = modelBits(source, pos, skip);
                if (fill != 0) {
                    // `BadPadding`, and the fill is already consumed: the
                    // check runs after the take, and every caller aborts on
                    // the refusal, so the position past it is not observable.
                    try testing.expectError(error.BadPadding, br.alignToByte());
                    try testing.expectEqual(pos + skip, br.bit_pos);
                } else {
                    try br.alignToByte();
                    try testing.expectEqual(pos + skip, br.bit_pos);
                    try testing.expect(br.atByteBoundary());
                }
            },
            3, 4 => {
                if (!br.atByteBoundary()) continue;
                var target: [64]u8 = undefined;
                const count = 1 + rangeAtMost(smith, 0, target.len - 1);
                if (pos / 8 + count <= source.len) {
                    try br.takeBytes(target[0..count]);
                    try testing.expectEqualSlices(
                        u8,
                        source[pos / 8 ..][0..count],
                        target[0..count],
                    );
                    try testing.expectEqual(pos + count * 8, br.bit_pos);
                } else {
                    try testing.expectError(error.Truncated, br.takeBytes(target[0..count]));
                    try testing.expectEqual(pos, br.bit_pos);
                    try testing.expectError(error.Truncated, br.skipBytes(@intCast(count)));
                    try testing.expectEqual(pos, br.bit_pos);
                }
            },
            else => {
                // F11's seam: the accumulator's bits survive an `attach`,
                // and a `rewind` at a byte boundary loses nothing.
                br.attach(source, 0);
                try testing.expectEqual(modelBits(source, pos, 1), try br.peek(1));
                if (br.atByteBoundary()) {
                    br.rewind();
                    const n: u6 = @intCast(1 + rangeAtMost(smith, 0, 16));
                    try testing.expectEqual(modelBits(source, pos, n), try br.peek(n));
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// The header and the meta-block ladder
// ---------------------------------------------------------------------------

/// The stream header and the meta-block ladder over arbitrary bytes.
///
/// The ladder is where a hostile input meets the tree region, the context
/// arena, and the OQ8 cap, so the property is: a refusal is one of the
/// layer's names, and a `Header` that parsed satisfies every invariant the
/// layers above rely on — WBITS in 10..24 with `window_size = (1 << WBITS) -
/// 16` (`§9.1`); MLEN in 1..2^24 (`§9.2`); the block-type and tree counts
/// inside the format's ceilings and the region's cap (OQ8); NPOSTFIX in 0..3
/// and NDIRECT a multiple of `1 << NPOSTFIX` (`§4`); and every context-map
/// value inside its NTREES (`§7.3`) — the property the command layer relies
/// on and never re-checks.
fn fuzzHeaders(_: void, smith: *Smith) anyerror!void {
    var source_buf: [source_max]u8 = undefined;
    const source = source_buf[0..smith.slice(&source_buf)];
    var br: bits.BitReader = .init(source);
    const stream = frame.readStreamHeader(bits.BitReader, &br) catch |err| {
        // §9.1 — the header's only refusal is the 0010001 pattern; a short
        // input is `Truncated`.
        try testing.expect(err == error.BadWindowBits or err == error.Truncated);
        return;
    };
    try testing.expect(stream.wbits >= 10 and stream.wbits <= 24);
    try testing.expectEqual(@as(u32, 1) << stream.wbits, stream.window_size + 16);

    var header: frame.Header = undefined;
    const blocks = 1 + rangeAtMost(smith, 0, 7);
    var i: usize = 0;
    while (i < blocks) : (i += 1) {
        const meta = frame.nextMetaBlock(bits.BitReader, &br, &header) catch |err| {
            try testing.expect(isFrameRefusal(err));
            return;
        } orelse return;
        try testing.expect(meta.mlen >= 1 and meta.mlen <= 1 << 24);
        if (meta.kind == .uncompressed) return; // the payload is not parsed here
        try checkHeader(&header);
    }
}

/// The invariants a parsed compressed `Header` must hold.
fn checkHeader(header: *const frame.Header) !void {
    try testing.expect(header.npostfix <= 3);
    try testing.expect(header.ndirect <= 120);
    try testing.expect(header.ndirect % (@as(u8, 1) << header.npostfix) == 0);
    for (0..3) |cat| {
        // §9.2 — NBLTYPES* and NTREES* are 1..256 on the wire; the tree
        // categories are capped at OQ8's 64.
        try testing.expect(header.block_types[cat] >= 1 and header.block_types[cat] <= 256);
        try testing.expect(header.num_trees[cat] >= 1);
        try testing.expect(header.num_trees[cat] <= huffman.max_trees);
        if (header.block_types[cat] == 1) {
            try testing.expectEqual(@as(u32, 1) << 24, header.first_block_count[cat]);
        }
    }
    try testing.expectEqual(header.block_types[1], header.num_trees[1]);
    // §7.3 — the maps' values are tree indexes in [0, NTREES), which is what
    // the command layer indexes the tree region with.
    const literal_map = header.context.literal_map[0 .. 64 * header.block_types[0]];
    for (literal_map) |value| try testing.expect(value < header.num_trees[0]);
    const distance_map = header.context.distance_map[0 .. 4 * header.block_types[2]];
    for (distance_map) |value| try testing.expect(value < header.num_trees[2]);
}

/// The framing layer's composed error set, listed so a new name cannot slip
/// into a target's `catch` unexamined.
fn isFrameRefusal(err: anyerror) bool {
    return switch (err) {
        error.Truncated,
        error.BadPadding,
        error.BadWindowBits,
        error.ReservedBit,
        error.ExuberantNibble,
        error.ExuberantMetaNibble,
        error.TooManyTrees,
        error.SimpleHuffmanAlphabet,
        error.SimpleHuffmanSame,
        error.BadCodeLengthCode,
        error.BadHuffmanCode,
        error.ContextMapRepeat,
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// The prefix codes
// ---------------------------------------------------------------------------

/// `§3.4`/`§3.5`'s tree reading over arbitrary bytes, plus the `build`
/// surface the Kraft checks live on.
///
/// A tree description either refuses with one of the prefix-code layer's
/// names (both forms' rejection sites, the two Kraft equalities, the repeat
/// arithmetic, the table-bound guard) or builds a complete code; a built
/// code then decodes symbols inside its declared alphabet, consumes no bits
/// for the single-symbol form and at least one otherwise, and turns a
/// starved source into `Truncated`, never a symbol out of padding.
fn fuzzPrefixCodes(_: void, smith: *Smith) anyerror!void {
    var source_buf: [source_max]u8 = undefined;
    const source = source_buf[0..smith.slice(&source_buf)];
    switch (rangeAtMost(smith, 0, 3)) {
        0 => try prefixAt(huffman.LiteralTree, smith, source),
        1 => try prefixAt(huffman.CommandTree, smith, source),
        2 => try prefixAt(huffman.DistanceTree, smith, source),
        else => try buildAt(huffman.BlockCountTree, smith),
    }
}

fn prefixAt(comptime T: type, smith: *Smith, source: []const u8) !void {
    const alphabet: u16 = @intCast(1 + rangeAtMost(smith, 0, T.alphabet_size - 1));
    var tree: T = undefined;
    var br: bits.BitReader = .init(source);
    huffman.readTree(T, bits.BitReader, &br, &tree, alphabet) catch |err| {
        try testing.expect(isPrefixRefusal(err));
        return;
    };
    var decoded: usize = 0;
    while (decoded < 16) : (decoded += 1) {
        const before = br.bit_pos;
        const symbol = tree.decode(bits.BitReader, &br) catch |err| {
            try testing.expectEqual(error.Truncated, err);
            return;
        };
        if (symbol >= alphabet) {
            std.debug.print(
                "brotli fuzz: readTree alphabet {d} decoded symbol {d}\n",
                .{ alphabet, symbol },
            );
            return error.SymbolOutOfAlphabet;
        }
        if (tree.single) |single| {
            // §3.4 — the one-symbol code consumes no bits.
            try testing.expectEqual(before, br.bit_pos);
            try testing.expectEqual(single, symbol);
        } else {
            try testing.expect(br.bit_pos > before);
        }
    }
}

/// The `build` surface: a Smith-chosen length set either refuses with
/// `BadHuffmanCode` or builds, and a table built from a *complete* set
/// decodes every root window to a symbol inside the alphabet without
/// starving.
///
/// `build` itself refuses a set that is not a complete prefix code — its
/// `§3.5` Kraft check covers the over-subscribed sets that used to overflow
/// the canonical `next_code` accumulator (the fuzz report's finding) — so an
/// arbitrary length set is inside the contract here, and the refusal classes
/// are the Kraft equality and the table bound.
fn buildAt(comptime T: type, smith: *Smith) !void {
    var lens: [T.alphabet_size]u4 = @splat(0);
    const n = 1 + rangeAtMost(smith, 0, T.alphabet_size - 1);
    for (lens[0..n]) |*len| len.* = @intCast(rangeAtMost(smith, 0, 15));
    var tree: T = undefined;
    if (tree.build(lens[0..n])) |_| {
        // Every eight-bit root window, with eight more bits behind it: a
        // complete code is at most 15 bits, so each decode lands inside the
        // alphabet and consumes at least one bit.
        var window: usize = 0;
        while (window < 256) : (window += 1) {
            var window_source: [2]u8 = undefined;
            mem.writeInt(u16, &window_source, @intCast(window | (window << 8)), .little);
            var br: bits.BitReader = .init(&window_source);
            const symbol = try tree.decode(bits.BitReader, &br);
            if (symbol >= n) {
                std.debug.print(
                    "brotli fuzz: build n {d} window {d} decoded symbol {d}\n",
                    .{ n, window, symbol },
                );
                return error.BuiltSymbolOutOfRange;
            }
            try testing.expect(br.bit_pos > 0);
        }
    } else |err| {
        try testing.expectEqual(error.BadHuffmanCode, err);
    }
}

/// The prefix-code layer's composed error set.
fn isPrefixRefusal(err: anyerror) bool {
    return switch (err) {
        error.Truncated,
        error.SimpleHuffmanAlphabet,
        error.SimpleHuffmanSame,
        error.BadCodeLengthCode,
        error.BadHuffmanCode,
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// The context maps
// ---------------------------------------------------------------------------

/// `§7.3`'s context maps over arbitrary bytes: RLEMAX's runs, the map's own
/// prefix code, and the IMTF bit.
///
/// The property the layers above rely on: a map either refuses (the zero-run
/// overrun is `ContextMapRepeat`, the tree's own refusals are the prefix
/// layer's, a starved map is `Truncated`) or every value it produced is a
/// tree index in `[0, NTREES)` — nothing downstream re-checks an index, so
/// this is the check.
fn fuzzContextMaps(_: void, smith: *Smith) anyerror!void {
    var source_buf: [source_max]u8 = undefined;
    const source = source_buf[0..smith.slice(&source_buf)];
    const num_trees: u16 = @intCast(2 + rangeAtMost(smith, 0, huffman.max_trees - 2));
    var values_buf: [64 * 256]u8 = undefined;
    const values = values_buf[0 .. 1 + rangeAtMost(smith, 0, values_buf.len - 1)];
    var tree: huffman.ContextMapTree = undefined;
    var br: bits.BitReader = .init(source);
    context.readMap(bits.BitReader, &br, &tree, values, num_trees) catch |err| {
        try testing.expect(isMapRefusal(err));
        return;
    };
    for (values) |value| try testing.expect(value < num_trees);
}

/// The context layer's composed error set.
fn isMapRefusal(err: anyerror) bool {
    return switch (err) {
        error.Truncated,
        error.SimpleHuffmanAlphabet,
        error.SimpleHuffmanSame,
        error.BadCodeLengthCode,
        error.BadHuffmanCode,
        error.ContextMapRepeat,
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// The dictionary
// ---------------------------------------------------------------------------

/// The elementary transform ids of the generated table, in the C
/// reference's numbering (`§8`, Appendix B).
const ferment_first = 10;
const ferment_all = 11;
const omit_first_1 = 12;

/// `§8`, Appendix B — the length-prefixed string at `offset` in the
/// generated pool: one length byte, then that many bytes.
fn poolString(offset: u16) []const u8 {
    const len = data.prefix_suffix[offset];
    return data.prefix_suffix[offset + 1 ..][0..len];
}

/// `§8` — `DOFFSET[length]`, from the recursion `DOFFSET[k + 1] =
/// DOFFSET[k] + k * NWORDS[k]` over Appendix A's NDBITS. Recomputed here
/// rather than read from `dictionary.zig`'s private table: the model must
/// not share the arithmetic it checks.
fn wordOffset(length: u32) u32 {
    var offset: u32 = 0;
    var k: u32 = 0;
    while (k < length) : (k += 1) {
        const nwords: u32 = if (k < dictionary.min_word_len) 0 else @as(u32, 1) << data.ndbits[k];
        offset += k * nwords;
    }
    return offset;
}

/// `§8` — the RFC's own `Ferment`, transcribed from the C the spec prints:
/// "case-flip" the UTF-8 sequence at `word[pos]`, returning the sequence's
/// length (1..3). A one-byte sequence flips a lowercase ASCII letter's bit 5,
/// a two-byte sequence the second byte's, a three-byte sequence the third
/// byte's bits 0 and 2; the two bounds guards are the spec's.
fn modelFerment(word: []u8, pos: usize) usize {
    if (word[pos] < 192) {
        if (word[pos] >= 97 and word[pos] <= 122) word[pos] ^= 32;
        return 1;
    } else if (word[pos] < 224) {
        if (pos + 1 < word.len) word[pos + 1] ^= 32;
        return 2;
    } else {
        if (pos + 2 < word.len) word[pos + 2] ^= 5;
        return 3;
    }
}

/// `§8`, Appendix B — the model: the transformed word for `(word_id,
/// length)`, composed from the generated tables by this file's own reading
/// of the RFC (prefix + elementary step + suffix, with the Omit classes'
/// saturating arithmetic and the spec's own Ferment C). `null` only for a
/// transform id above 120, which is the decoder's refusal.
fn modelWord(scratch: []u8, word_id: u32, length: u32) ?[]const u8 {
    const ndbits = data.ndbits[length];
    const transform_id: u32 = word_id >> ndbits;
    if (transform_id > dictionary.max_transform_id) return null;
    const triplet = data.transforms[transform_id];
    const elementary = triplet[1];
    const index = word_id % (@as(u32, 1) << ndbits);
    const offset = wordOffset(length) + index * length;
    const base = dictionary.words[offset..][0..length];
    var source = base;
    var len = base.len;
    if (elementary >= omit_first_1) {
        // OmitFirstk: "the last (length(word) - k) bytes of word, or empty
        // string if length(word) < k".
        const skip = @min(@as(usize, elementary - omit_first_1 + 1), len);
        source = base[skip..];
        len -= skip;
    } else if (elementary <= 9) {
        // Identity, or OmitLastk: "the first (length(word) - k) bytes".
        len -|= @as(usize, elementary);
    }
    // 10 and 11 (FermentFirst and FermentAll) take the whole word, and the
    // case-flip lands on the word between the affixes.
    const prefix = poolString(data.prefix_suffix_map[triplet[0]]);
    const suffix = poolString(data.prefix_suffix_map[triplet[2]]);
    var out: usize = 0;
    for (prefix) |byte| {
        scratch[out] = byte;
        out += 1;
    }
    const start = out;
    for (source[0..len]) |byte| {
        scratch[out] = byte;
        out += 1;
    }
    const region = scratch[start..out];
    switch (elementary) {
        ferment_first => {
            if (region.len > 0) _ = modelFerment(region, 0);
        },
        ferment_all => {
            var pos: usize = 0;
            while (pos < region.len) pos += modelFerment(region, pos);
        },
        else => {},
    }
    for (suffix) |byte| {
        scratch[out] = byte;
        out += 1;
    }
    return scratch[0..out];
}

/// `§8`'s word arithmetic: the class boundary (`word_id`'s transform id
/// against 120), the two refusals, the 38-byte scratch bound, and the
/// transform classes against the independent model.
///
/// `word_id = distance - (max allowed distance + 1)`, `index = word_id %
/// NWORDS[length]`, `transform_id = word_id >> NDBITS[length]` (`§8`), so the
/// last valid word_id for a length is `(121 << NDBITS[length]) - 1` and the
/// next one is `BadTransform` — the boundary is pinned on both sides. A
/// produced word is bounded by the base word plus the largest affix pair
/// (24 + 13) and by the scratch (38, T8), and for every class the model
/// covers it must match byte for byte.
fn fuzzDictionary(_: void, smith: *Smith) anyerror!void {
    const length: u32 = @intCast(dictionary.min_word_len + rangeAtMost(smith, 0, 20));
    const ndbits = data.ndbits[length];
    const last_valid: u32 = (@as(u32, 121) << ndbits) - 1;
    const word_id: u32 = @intCast(rangeAtMost(smith, 0, last_valid + 8));
    var scratch: [dictionary.scratch_len]u8 = undefined;
    const word = dictionary.transformedWord(&scratch, word_id, length) catch |err| {
        try testing.expectEqual(error.BadTransform, err);
        if (word_id <= last_valid) return error.BadTransformBelowBound;
        return;
    };
    if (word_id > last_valid) return error.TransformAboveBoundAccepted;
    // §8's bound: the largest base word plus the largest prefix + suffix.
    try testing.expect(word.len <= dictionary.scratch_len);
    try testing.expect(word.len <= length + 13);
    var model_buf: [dictionary.scratch_len]u8 = undefined;
    if (modelWord(&model_buf, word_id, length)) |want| {
        if (!mem.eql(u8, want, word)) {
            std.debug.print(
                "brotli fuzz: word_id {d} length {d}: model {s} vs decoder {s}\n",
                .{ word_id, length, want, word },
            );
            return error.ModelMismatch;
        }
    }
    var again: [dictionary.scratch_len]u8 = undefined;
    try testing.expectEqualSlices(
        u8,
        word,
        try dictionary.transformedWord(&again, word_id, length),
    );
}

test "brotli fuzz: reader machinery" {
    const storage = try testing.allocator.create(Storage);
    defer testing.allocator.destroy(storage);
    try testing.fuzz(storage, fuzzReaderMachinery, .{ .corpus = &corpus_seeds });
}

test "brotli fuzz: amplification caps" {
    const storage = try testing.allocator.create(Storage);
    defer testing.allocator.destroy(storage);
    try testing.fuzz(storage, fuzzAmplification, .{});
}

test "brotli fuzz: bit reader" {
    try testing.fuzz({}, fuzzBits, .{ .corpus = &stream_seeds });
}

test "brotli fuzz: header ladder" {
    try testing.fuzz({}, fuzzHeaders, .{ .corpus = &stream_seeds });
}

test "brotli fuzz: prefix codes" {
    try testing.fuzz({}, fuzzPrefixCodes, .{ .corpus = &stream_seeds });
}

test "brotli fuzz: context maps" {
    try testing.fuzz({}, fuzzContextMaps, .{ .corpus = &stream_seeds });
}

test "brotli fuzz: dictionary words" {
    try testing.fuzz({}, fuzzDictionary, .{});
}

// ---------------------------------------------------------------------------
// The corpus and the corner lists, pinned without the fuzzer
//
// These run in the plain suite (`just test`), so a regression in any single
// golden vector, any truncation prefix, or any of the register's corner
// rows fails the build before a fuzzer budget is spent.
// ---------------------------------------------------------------------------

// The whole golden corpus through the one-shot decoder: the exact cap,
// slack, the refusal classes, and T4's trailing bytes. The machine half of
// `fuzzGoldenCorpus`.
test "brotli fuzz: the corpus decodes to its models" {
    const storage = try testing.allocator.create(Storage);
    defer testing.allocator.destroy(storage);

    for (&vectors) |*vector| {
        try expectVectorOneShot(storage, vector, vector.stream);
        // T4 — the bytes after a *complete* stream's last byte are the
        // caller's. (A stream that fails because it ran out of input is not
        // complete: a tail changes what it parses, so the rule does not
        // apply to the `Truncated` vectors.)
        if (vector.refusal == null) {
            var framed: [mutation_max]u8 = undefined;
            fastmem.copy(u8, framed[0..vector.stream.len], vector.stream);
            fastmem.set(u8, framed[vector.stream.len..][0..8], marker_byte);
            try expectVectorOneShot(storage, vector, framed[0 .. vector.stream.len + 8]);
        }

        // The streaming reader with the smallest ring that admits the
        // stream's declared window, so the wrap vectors really wrap.
        const declared = declaredWindowSize(vector.stream) orelse 1008;
        if (declared <= 1008) {
            try expectVectorStreamed(10, storage, vector, vector.stream);
        } else if (declared <= 65520) {
            try expectVectorStreamed(16, storage, vector, vector.stream);
        } else {
            try expectVectorStreamed(24, storage, vector, vector.stream);
        }
    }
}

/// One vector through the one-shot decoder: the model, the refusal class,
/// the sentinel past the decoded length, and the cap one byte short.
fn expectVectorOneShot(storage: *Storage, vector: *const Vector, source: []const u8) !void {
    sentinel.fill(&storage.out);
    const result = decode.decompress(source, storage.out[0..corpus_out_max]);
    if (vector.refusal) |want| {
        try testing.expectError(want, result);
        try sentinel.expect(&storage.out, corpus_out_max);
        return;
    }
    const n = try result;
    try testing.expectEqual(vector.plain.len, n);
    try testing.expectEqualSlices(u8, vector.plain, storage.out[0..n]);
    try sentinel.expect(&storage.out, corpus_out_max);
    if (source.len != vector.stream.len) return; // the framed copy: same verdict
    if (n > 0) {
        sentinel.fill(&storage.out);
        try testing.expectError(
            error.BufferTooSmall,
            decode.decompress(source, storage.out[0 .. n - 1]),
        );
        try sentinel.expect(&storage.out, n - 1);
    }
}

/// One vector through the streaming reader, with the ring the caller chose:
/// the model bytes, the refusal class, and the exact input boundary (T4).
fn expectVectorStreamed(
    comptime wbits: usize,
    storage: *Storage,
    vector: *const Vector,
    source: []const u8,
) !void {
    const streamed = try streamSource(
        wbits,
        source,
        ringFor(wbits, storage),
        storage.read_out[0..corpus_out_max],
        &.{},
    );
    if (vector.refusal) |want| {
        try testing.expectEqual(Stop.read_failed, streamed.stop);
        try testing.expectEqual(want, streamed.detail.?);
        return;
    }
    try testing.expectEqual(Stop.end_of_stream, streamed.stop);
    try testing.expectEqual(vector.plain.len, streamed.served);
    try testing.expectEqualSlices(u8, vector.plain, storage.read_out[0..streamed.served]);
    // T4 — the reader consumed the stream's last byte + 1, whatever follows.
    try testing.expectEqual(vector.stream.len, streamed.consumed);
}

// RFC 7932 §10 — every strict prefix of a valid stream is `Truncated`,
// through both entry points. The prefixes the fuzzer samples at random, run
// exhaustively here.
test "brotli fuzz: every strict prefix is Truncated" {
    const storage = try testing.allocator.create(Storage);
    defer testing.allocator.destroy(storage);
    const streams = [_][]const u8{
        golden.hand_stream.bytes,
        golden.cli_small_window.bytes,
        golden.cli_text_q11.bytes,
        golden.window_bound.bytes,
        golden.cross_meta_block.bytes,
        golden.dictionary_affix.bytes,
        golden.uncompressed_streams[1].bytes,
        golden.metadata_streams[1].bytes,
        golden.last_metadata_streams[1],
    };
    for (streams) |stream| {
        for (0..stream.len) |cut| {
            sentinel.fill(&storage.out);
            try testing.expectError(
                error.Truncated,
                decode.decompress(stream[0..cut], storage.out[0..corpus_out_max]),
            );
            try sentinel.expect(&storage.out, corpus_out_max);
        }
    }
    // The empty family's one- and two-byte forms: any prefix is no stream.
    for (golden.empty_streams) |stream| {
        for (0..stream.len) |cut| {
            sentinel.fill(&storage.out);
            try testing.expectError(
                error.Truncated,
                decode.decompress(stream[0..cut], storage.out[0..corpus_out_max]),
            );
        }
    }
    // The reader on the same ladder, for the stream whose ring wraps.
    for (0..golden.cli_small_window.bytes.len) |cut| {
        const streamed = try streamSource(
            10,
            golden.cli_small_window.bytes[0..cut],
            &storage.ring10,
            storage.read_out[0..corpus_out_max],
            &.{},
        );
        try testing.expectEqual(Stop.read_failed, streamed.stop);
        try testing.expectEqual(error.Truncated, streamed.detail.?);
    }
}

// `§9.3`'s MLEN accounting on the bomb, at the values the pinned CLI
// verified: the insert-only and whole-command lengths decode to the model,
// and every length the command stream cannot land on exactly is
// `BadBlockLength` (the CLI's `FORMAT_BLOCK_LENGTH_2 (-10)`, F7).
test "brotli fuzz: the bomb's MLEN boundary" {
    const storage = try testing.allocator.create(Storage);
    defer testing.allocator.destroy(storage);
    var stream_buf: [128]u8 = undefined;

    // Verified with `brotli -d -c` (brotli 1.2.0): 5 -> five 'A's (the
    // last command's copy is ignored), 14 -> fourteen, 196 -> 196.
    for ([_]u32{ 5, 14, 28, 196, 65534 }) |mlen| {
        const stream = stream_buf[0..bombStream(mlen, &stream_buf)];
        sentinel.fill(&storage.out);
        const n = try decode.decompress(stream, storage.out[0..mlen]);
        try testing.expectEqual(mlen, n);
        for (storage.out[0..n]) |byte| try testing.expectEqual(@as(u8, 'A'), byte);
        try sentinel.expect(&storage.out, mlen);
    }
    // Verified with `brotli -d -v -c`: FORMAT_BLOCK_LENGTH_2 for the insert
    // overrun (4) and for every copy overrun between the two landing points.
    for ([_]u32{ 4, 6, 9, 13, 15, 18, 20, 27, 29 }) |mlen| {
        const stream = stream_buf[0..bombStream(mlen, &stream_buf)];
        sentinel.fill(&storage.out);
        try testing.expectError(
            error.BadBlockLength,
            decode.decompress(stream, storage.out[0..corpus_out_max]),
        );
        try sentinel.expect(&storage.out, corpus_out_max);
    }
    // The maximum bomb: 16,777,208 declared bytes from eleven, refused
    // before any write when the cap is smaller — and drained through a
    // 1 KiB ring only up to the harness's cap, every byte the model's.
    const big = stream_buf[0..bombStream(bomb_mlen_max, &stream_buf)];
    try testing.expect(big.len <= 16);
    sentinel.fill(&storage.out);
    try testing.expectError(
        error.BufferTooSmall,
        decode.decompress(big, storage.out[0..corpus_out_max]),
    );
    try sentinel.expect(&storage.out, corpus_out_max);
    const streamed = try streamSource(10, big, &storage.ring10, storage.read_out[0..out_max], &.{});
    try testing.expectEqual(Stop.output_full, streamed.stop);
    try testing.expectEqual(out_max, streamed.served);
    for (storage.read_out[0..streamed.served]) |byte| try testing.expectEqual(@as(u8, 'A'), byte);

    // Exactly at the drain cap (14 x 585 = 8,190): the writer's fullness and
    // the reader's end coincide, and the clean end wins — the pump's own cap
    // must not be mistaken for the stream's.
    const exact = stream_buf[0..bombStream(14 * 585, &stream_buf)];
    const drained = try streamSource(10, exact, &storage.ring10, storage.read_out[0..8190], &.{});
    try testing.expectEqual(Stop.end_of_stream, drained.stop);
    try testing.expectEqual(@as(usize, 8190), drained.served);
    for (storage.read_out[0..drained.served]) |byte| try testing.expectEqual(@as(u8, 'A'), byte);
}

// OQ8's tree cap through the public entry point: a meta-block declaring 65
// trees in a capped category fails `TooManyTrees`, never a bigger region.
test "brotli fuzz: the tree cap is TooManyTrees" {
    // NTREESL = 65: the literal trees' region holds 64.
    var p: golden.Packer = .{};
    packCompressedHead(&p);
    packCount(&p, 65);
    var target: [guard_len]u8 = undefined;
    sentinel.fill(&target);
    try testing.expectError(error.TooManyTrees, decode.decompress(p.slice(), &target));
    try sentinel.expect(&target, 0);

    // NBLTYPESI = 65: the command trees are the region's command category.
    var q: golden.Packer = .{};
    packCompressedHead(&q);
    q.pack(0, 1); // NBLTYPESL = 1
    packCount(&q, 65);
    sentinel.fill(&target);
    try testing.expectError(error.TooManyTrees, decode.decompress(q.slice(), &target));
    try sentinel.expect(&target, 0);
}

/// WBITS 16, ISLAST=1, ISLASTEMPTY=0, MNIBBLES=4, MLEN=1 — the head of a
/// single last compressed meta-block, through the three block-type counts
/// and the context mode.
fn packCompressedHead(p: *golden.Packer) void {
    p.pack(0, 1); // WBITS 16
    p.pack(1, 1); // ISLAST
    p.pack(0, 1); // ISLASTEMPTY = 0
    p.pack(0, 2); // MNIBBLES = 4
    p.pack(0, 16); // MLEN - 1 = 0
    p.pack(0, 1); // NBLTYPESL = 1
    p.pack(0, 1); // NBLTYPESI = 1
    p.pack(0, 1); // NBLTYPESD = 1
    p.pack(0, 2); // NPOSTFIX = 0
    p.pack(0, 4); // NDIRECT = 0
    p.pack(0, 2); // context mode LSB6
}

/// `§9.2`'s 1..11-bit count code (NBLTYPESL/I/D, NTREESL/D): the values
/// 1..256, `count - 1` on the wire, low bit first.
fn packCount(p: *golden.Packer, count: u32) void {
    assert(count >= 1);
    assert(count <= 256);
    if (count == 1) {
        p.pack(0, 1);
        return;
    }
    if (count == 2) {
        p.pack(1, 1);
        p.pack(0, 3);
        return;
    }
    const value = count - 1;
    var nbits: u5 = 1;
    while ((@as(u32, 1) << (nbits + 1)) <= value) : (nbits += 1) {}
    p.pack(1, 1);
    p.pack(nbits, 3);
    p.pack(value - (@as(u32, 1) << nbits), nbits);
}

// The reader's ring wrap, the walk's boundary, and the contiguous-read cap.
test "brotli fuzz: the ring wraps and the walk refuses a bad tail" {
    const storage = try testing.allocator.create(Storage);
    defer testing.allocator.destroy(storage);

    // The ring-wrap vector: 49 bytes in, 4,400 out, one copy of 4,355 at
    // distance 45, so a `Buffer(10)` ring (1,024 bytes) wraps under the
    // copy's previous pass.
    const stream = golden.cli_small_window.bytes;
    var fixed_in: Io.Reader = .fixed(stream);
    var r: Reader = .init(10, &fixed_in, &storage.ring10);
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    _ = try r.reader.streamRemaining(&plain.writer);
    try testing.expectEqualStrings(golden.cli_small_window.plain, plain.written());
    try testing.expectEqual(stream.len, fixed_in.seek);

    // T4 — `streamAll` walks at the boundary: a doubled stream decodes
    // twice, zero bytes is the walk's clean end, and a tail that cannot
    // begin a stream is `BadStreamStart` (F10).
    var framed: Io.Writer.Allocating = .init(testing.allocator);
    defer framed.deinit();
    try framed.writer.writeAll(golden.hand_stream.bytes);
    try framed.writer.writeAll(golden.hand_stream.bytes);
    var in: Io.Reader = .fixed(framed.written());
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const served = try Reader.streamAll(16, &in, &out.writer, &storage.ring16);
    try testing.expectEqual(2 * golden.hand_stream.plain.len, served);
    try testing.expectEqualStrings(
        golden.hand_stream.plain ++ golden.hand_stream.plain,
        out.written(),
    );
    var empty: Io.Reader = .fixed("");
    try testing.expectEqual(
        @as(usize, 0),
        try Reader.streamAll(16, &empty, &out.writer, &storage.ring16),
    );

    var tail: Io.Writer.Allocating = .init(testing.allocator);
    defer tail.deinit();
    try tail.writer.writeAll(golden.hand_stream.bytes);
    try tail.writer.splatBytesAll(&[_]u8{0x11}, 3);
    var tail_in: Io.Reader = .fixed(tail.written());
    try testing.expectError(
        error.ReadFailed,
        Reader.streamAll(16, &tail_in, &out.writer, &storage.ring16),
    );
    var tail_in2: Io.Reader = .fixed(tail.written());
    var r2: Reader = .init(16, &tail_in2, &storage.ring16);
    var sink: Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    _ = try r2.reader.streamRemaining(&sink.writer);
    try testing.expectEqualStrings(golden.hand_stream.plain, sink.written());
    var r3: Reader = .init(16, &tail_in2, &storage.ring16);
    try testing.expectError(error.ReadFailed, r3.reader.streamRemaining(&sink.writer));
    try testing.expectEqual(Reader.Error.BadStreamStart, r3.err.?);
    // The one-shot names the same wire pattern `BadWindowBits` (T3).
    sentinel.fill(&storage.out);
    try testing.expectError(
        error.BadWindowBits,
        decode.decompress(&[_]u8{0x11}, storage.out[0..guard_len]),
    );

    // The contiguous-read cap: a request past the ring's room at the read
    // position is `StreamTooLong`, never an assert (std's own `rebase`
    // asserts here).
    var cap_in: Io.Reader = .fixed(golden.cli_small_window.bytes);
    var r4: Reader = .init(10, &cap_in, &storage.ring10);
    _ = try r4.reader.peek(4);
    try testing.expectError(error.ReadFailed, r4.reader.peek(storage.ring10.ring.len + 1));
    try testing.expectEqual(Reader.Error.StreamTooLong, r4.err.?);
}

// `§8`'s transforms against the model: every (length, transform) pair the
// format can name — 2,541 of them, the sweep the slice-4 landing ran
// against the pinned CLI — at the first, last, and a scattered word index,
// plus the corpus's own words as CLI-verified anchors.
test "brotli fuzz: the dictionary model reproduces the corpus's words" {
    var pairs: usize = 0;
    for (dictionary.min_word_len..dictionary.max_word_len + 1) |length| {
        const ndbits = data.ndbits[length];
        const nwords: u32 = @as(u32, 1) << ndbits;
        const indices = [_]u32{ 0, nwords - 1, (@as(u32, @intCast(length)) * 7 + 3) % nwords };
        var transform_id: u32 = 0;
        while (transform_id <= dictionary.max_transform_id) : (transform_id += 1) {
            for (indices) |index| {
                const word_id = (transform_id << ndbits) + index;
                var scratch: [dictionary.scratch_len]u8 = undefined;
                const word = try dictionary.transformedWord(&scratch, word_id, @intCast(length));
                var model_buf: [dictionary.scratch_len]u8 = undefined;
                const want = modelWord(&model_buf, word_id, @intCast(length)) orelse continue;
                try testing.expectEqualSlices(u8, want, word);
                pairs += 1;
            }
        }
    }
    // 21 lengths x 121 transforms x 3 indexes = 7,623 pairs: the model
    // covers all of them (its only decline is a transform id above 120, and
    // the sweep stops at 120), so this is exact.
    try testing.expectEqual(@as(usize, 7623), pairs);

    // The CLI-verified anchors: the corpus's own plaintexts, from the same
    // arithmetic the wire uses.
    var anchor: [dictionary.scratch_len]u8 = undefined;
    try testing.expectEqualStrings("time", modelWord(&anchor, 0, 4).?);
    const affix = modelWord(&anchor, 73 << 10, 4).?;
    try testing.expectEqualStrings(golden.dictionary_affix.plain, affix);
    const identity = modelWord(&anchor, 0, 24).?;
    try testing.expectEqualStrings(golden.dictionary_identity_24.plain, identity);
    // `dictionary_omit` is transform 54 of the last 24-byte word: the
    // golden plain is what the model must produce for index 31.
    const omit = modelWord(&anchor, (54 << 5) + 31, 24).?;
    try testing.expectEqualStrings(golden.dictionary_omit.plain, omit);
}

// The bit reader against the model at every position and every width — the
// T6 (the register's divergence row) — the format has no integrity check: a
// flipped bit may either fail with a named class or decode without error to
// *different* bytes. The lane asserts the disjunction, never "corruption
// errors": this walks every bit of every valid corpus stream and counts the
// three outcomes, so the property is measured rather than assumed (over this
// corpus: 1,009 flips decode to the same bytes, 2,063 to different ones, and
// 6,496 are refused — a third of the flips silently change the output, which
// is what a container's checksum is for).
test "brotli fuzz: corruption is error or difference (T6)" {
    var target: [corpus_out_max + guard_len]u8 = undefined;
    var decoded_same: usize = 0;
    var decoded_diff: usize = 0;
    var refused: usize = 0;
    for (&vectors) |*vector| {
        if (vector.refusal != null) continue;
        for (vector.stream, 0..) |_, at| {
            var bit: u4 = 0;
            while (bit < 8) : (bit += 1) {
                var mutated: [mutation_max]u8 = undefined;
                fastmem.copy(u8, mutated[0..vector.stream.len], vector.stream);
                mutated[at] ^= @as(u8, 1) << @intCast(bit);
                sentinel.fill(&target);
                const verdict = decode.decompress(
                    mutated[0..vector.stream.len],
                    target[0..corpus_out_max],
                );
                if (verdict) |n| {
                    try sentinel.expect(&target, n);
                    if (mem.eql(u8, target[0..n], vector.plain)) {
                        decoded_same += 1;
                    } else {
                        decoded_diff += 1;
                    }
                } else |_| {
                    try sentinel.expect(&target, corpus_out_max);
                    refused += 1;
                }
            }
        }
    }
    // Every flip lands in exactly one class, no flip panics, and the
    // no-integrity-check property is real on this corpus.
    try testing.expect(decoded_diff > 0);
    try testing.expect(decoded_same + decoded_diff + refused > 9000);
}

// exhaustive half of `fuzzBits`.
test "brotli fuzz: the bit reader's reads are exact at every position" {
    var source: [64]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @truncate(i *% 37 +% 11);
    const total_bits = source.len * 8;
    var pos: usize = 0;
    while (pos < total_bits) : (pos += 1) {
        var n: u6 = 1;
        while (n <= bits.max_read_bits) : (n += 1) {
            // A fresh reader per width: the reads below consume, and a
            // single take serves at most `max_read_bits`.
            var br: bits.BitReader = .init(&source);
            var skip: usize = pos;
            while (skip > 0) {
                const chunk: u6 = @intCast(@min(skip, bits.max_read_bits));
                _ = try br.take(chunk);
                skip -= chunk;
            }
            try testing.expectEqual(modelBits(&source, pos, n), try br.peek(n));
            if (pos + n <= total_bits) {
                try testing.expectEqual(modelBits(&source, pos, n), try br.take(n));
                try testing.expectEqual(pos + n, br.bit_pos);
            } else {
                try testing.expectError(error.Truncated, br.take(n));
                try testing.expectEqual(pos, br.bit_pos);
            }
        }
    }
}
