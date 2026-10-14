//! The benchmark corpus generator (bench/README.md). Deterministic: the same
//! bytes on every host, so a generated tree reproduces the committed
//! `bench/corpus/SHA256SUMS` exactly. That file is the trust anchor and the
//! only corpus file tracked in git. The bytes themselves live in a gitignored
//! directory (default `bench/corpus-gen/`), generated on demand.
//!
//! The shapes (see `Shape`) come at two sizes, 32 KiB and 64 KiB. The first
//! five mirror the codec bench files (src/flate/bench.zig). Alongside each raw
//! file the generator writes the reference compressed blob per codec: flate,
//! gzip, and zlib at level `.fast`, and the snappy raw block, all produced by
//! the zcompress one-shots. Decompression rows decode these exact blobs, so
//! every implementation's decoder sees identical input bytes.
//!
//! The `.zst` blobs come from the pinned zstd CLI instead (v1.5.7, from the
//! flake), so the decode rows read the reference encoder's own frames — the
//! one shape every zstd decoder must handle. The CLI runs at the shape's
//! `zstdLevel`: level 1 matches the fast class of the other rows, and the
//! entropy shapes (`words`, `skewlit`) use level 19, whose matcher leaves the
//! literals to the Huffman streams that the level-1 rows never exercise. The
//! generator decodes each frame with our decoder
//! (`zcompress.zstd.decode.decompress`) and requires the raw bytes back before
//! writing it. Every run checks the CLI's version first (`zstd_cli_version`),
//! so a different PATH binary fails the run instead of silently rewriting the
//! corpus.
//!
//! The `.br` streams come from the pinned brotli CLI (1.2.0, from the flake),
//! because zcompress has no brotli encoder. Every shape uses quality 11, the
//! CLI's default and the class of a precompressed `.br` asset; quality is a
//! coverage choice here, not a fairness one, since no arm compresses brotli.
//! The CLI reads the file by path, so it picks the window from the file size
//! (WBITS 16 for 32 KiB, 17 for 64 KiB) and passes the size as a hint; piping
//! the same bytes through stdin writes WBITS 24 and different streams. The
//! generator decodes each stream with our decoder
//! (`zcompress.brotli.decode.decompress`) and requires the raw bytes back
//! before writing it, and checks `brotli --version` against
//! `brotli_cli_version` first.
//!
//! After writing every file the generator checks the result against the
//! committed anchor, file by file, and fails naming any disagreement. The
//! manifest is written next to the bytes only if it reproduces the anchor.
//!
//! Run from the repo root: `zig build corpus [-- DIR]` (`just corpus`),
//! default DIR bench/corpus-gen. Rewrites only files whose bytes differ.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;
const DefaultPrng = std.Random.DefaultPrng;
const Sha256 = std.crypto.hash.sha2.Sha256;

const fastmem = @import("fastmem");

const zcompress = @import("zcompress");

pub const Shape = enum {
    text, // repetitive English-ish text (highly compressible)
    random, // PRNG bytes (incompressible -> stored blocks)
    html, // tag-heavy markup (compressible, short matches)
    rle, // single-byte run (extreme RLE)
    mixed, // structured + random (realistic-ish record batch)
    // The entropy pair: literals-heavy shapes whose `.zst` blobs the CLI
    // writes at level 19, so the frames carry real FSE-described Huffman
    // tables and four-stream literals, the decode path the fast-class shapes
    // starve.
    words, // dictionary-word text (compressible, literals-heavy)
    skewlit, // skewed-distribution bytes (Huffman-literals-heavy)
};

pub const sizes = [_]usize{ 32 * 1024, 64 * 1024 };

/// The generated corpus directory (gitignored): the raw shapes and the
/// reference blobs generate here on demand. A positional DIR overrides it.
const default_dir = "bench/corpus-gen";

/// The committed trust anchor: the only corpus file tracked in git. Every
/// generated file is checked against it before anything trusts the bytes.
const committed_sums_path = "bench/corpus/SHA256SUMS";

/// The zstd CLI level of the fast-class shapes' `.zst` reference blobs. The
/// CLI's own default is 3; level 1 is the fast class every other arm's rows
/// measure (zc `.fast`, klauspost/libdeflate/zlib-ng level 1).
const zstd_cli_level = "-1";

/// The level the entropy shapes' `.zst` blobs generate at: level 19's
/// matcher spends itself on matches a dictionary-word or skewed-literal
/// shape barely offers, so the literals go out Huffman-coded under a real
/// FSE-described table, the entropy path the level-1 rows never exercise.
const zstd_cli_level_entropy = "-19";

/// The zstd CLI level a shape's `.zst` blob generates at.
fn zstdLevel(shape: Shape) []const u8 {
    return switch (shape) {
        .words, .skewlit => zstd_cli_level_entropy,
        else => zstd_cli_level,
    };
}

/// The pinned zstd CLI version the `.zst` reference blobs come from (v1.5.7,
/// the flake): every run checks `zstd --version` against it once, so a
/// different PATH binary cannot silently produce blobs the committed corpus
/// was not generated with.
const zstd_cli_version = "v1.5.7";

/// The pinned brotli CLI version the `.br` reference streams come from
/// (1.2.0, the flake; the same tag as the brotli-c arm's source pin).
const brotli_cli_version = "brotli 1.2.0";

/// The brotli CLI quality of every shape's `.br` stream: 11, the CLI's
/// default (`-Z`, `--best`).
const brotli_cli_quality = "11";

/// The four one-shot encoders' error unions: they share the payload (`usize`,
/// the produced length) and their error sets coerce to this one, so
/// `writeBlob` takes one named type rather than a duck-typed value.
const Generated = error{ BufferTooSmall, Unimplemented }!usize;

/// One definition of the corpus shapes: the benchmark drivers read the files
/// this generates; nothing regenerates shapes on the boxes.
pub fn makeShape(shape: Shape, buf: []u8) void {
    switch (shape) {
        .text => fill(buf, "the quick brown fox jumps over the lazy dog. "),
        .random => {
            var rng: DefaultPrng = .init(0xC0FFEE);
            for (buf) |*b| b.* = rng.random().int(u8);
        },
        .html => fill(buf, "<div class=\"row\"><span>hello</span><span>flate</span></div>"),
        .rle => fastmem.set(u8, buf, 0x41),
        .mixed => {
            var rng: DefaultPrng = .init(0x5A4BEEF);
            for (buf, 0..) |*b, i| b.* = @truncate(rng.random().int(u8) ^ @as(u8, @truncate(i)));
        },
        .words => {
            // Dictionary-word text: a small fixed vocabulary, PRNG-chosen
            // word by word and space-joined. The words repeat but the
            // sequences rarely do, so the compressor's wins come from the
            // literals' skew, not long matches.
            var rng: DefaultPrng = .init(0xD1C710);
            var i: usize = 0;
            while (i < buf.len) {
                const word = dictionary[rng.random().uintLessThan(usize, dictionary.len)];
                const n = @min(word.len, buf.len - i);
                fastmem.copy(u8, buf[i..][0..n], word[0..n]);
                i += n;
                if (i < buf.len) {
                    buf[i] = ' ';
                    i += 1;
                }
            }
        },
        .skewlit => {
            // Skewed literals: uniform bytes squared into a 64-value
            // range, so the distribution piles up at low values (12.5% of
            // bytes are 0) — ~5.6 bits/byte of entropy, compressible
            // almost only through the literals' entropy coding.
            var rng: DefaultPrng = .init(0x5CEBE1);
            for (buf) |*b| {
                const x: u16 = rng.random().int(u8);
                b.* = @truncate(x * x >> 10);
            }
        },
    }
}

/// The `words` shape's vocabulary: 64 common English words, fixed, so the
/// shape is the same bytes on every host.
const dictionary = [_][]const u8{
    "the",  "of",    "and",  "a",     "to",    "in",    "is",   "you",
    "that", "it",    "he",   "was",   "for",   "on",    "are",  "as",
    "with", "his",   "they", "at",    "be",    "this",  "have", "from",
    "or",   "one",   "had",  "by",    "word",  "but",   "not",  "what",
    "all",  "were",  "we",   "when",  "your",  "can",   "said", "there",
    "use",  "an",    "each", "which", "she",   "do",    "how",  "their",
    "if",   "will",  "up",   "other", "about", "out",   "many", "then",
    "them", "these", "so",   "some",  "her",   "would", "make", "like",
};

fn fill(buf: []u8, phrase: []const u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const n = @min(phrase.len, buf.len - i);
        fastmem.copy(u8, buf[i..][0..n], phrase[0..n]);
        i += n;
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var dir_path: []const u8 = default_dir;
    for (args[1..]) |arg| {
        if (mem.startsWith(u8, arg, "-")) {
            std.debug.print("corpus: unknown flag {s} (usage: corpus [DIR])\n", .{arg});
            return error.UnknownFlag;
        }
        dir_path = arg;
    }
    try refuseCommittedDir(arena, dir_path);
    try checkCliVersion(io, arena, "zstd", zstd_cli_version);
    try checkCliVersion(io, arena, "brotli", brotli_cli_version);

    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var sums: std.ArrayList(u8) = .empty;
    for (std.enums.values(Shape)) |shape| {
        for (sizes) |size| {
            const raw = try arena.alloc(u8, size);
            makeShape(shape, raw);
            const base_name = try std.fmt.allocPrint(arena, "{s}-{d}", .{ @tagName(shape), size });
            try writeFile(io, arena, dir, &sums, base_name, raw);

            // One blob at a time: every encoder writes the same scratch, so
            // the write must complete before the next encode starts.
            const target = try arena.alloc(u8, maxCompressedLength(size));
            try writeBlob(io, arena, dir, &sums, base_name, "flate", target, zcompress.flate.encode.compress(raw, target, .{}));
            try writeBlob(io, arena, dir, &sums, base_name, "gz", target, zcompress.gzip.encode.compress(raw, target, .{}));
            try writeBlob(io, arena, dir, &sums, base_name, "zz", target, zcompress.zlib.encode.compress(raw, target, .{}));
            try writeBlob(io, arena, dir, &sums, base_name, "snappy", target, zcompress.snappy.encode.compressBlock(raw, target));
            try writeZstdBlob(io, arena, dir, dir_path, shape, base_name, raw);
            try writeBrotliBlob(io, arena, dir, dir_path, base_name, raw);
        }
    }

    // The CLI-written streams: hash them into the manifest, sorted, after the
    // generated rows — the .zst frames, then the .br streams, the order the
    // anchor grew in — so the manifest reproduces the committed SHA256SUMS
    // byte for byte.
    try hashSorted(io, arena, dir, &sums, ".zst");
    try hashSorted(io, arena, dir, &sums, ".br");

    // The committed anchor is what the harness trusts, so the generated
    // bytes must reproduce it before the manifest is written.
    const file_count = try verifyAgainstCommitted(io, arena, sums.items);
    try dir.writeFile(io, .{ .sub_path = "SHA256SUMS", .data = sums.items });
    var out_buf: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &out_buf);
    try stdout.interface.print("corpus: {s} reproduces {s} ({d} files)\n", .{
        dir_path, committed_sums_path, file_count,
    });
    try stdout.interface.flush();
}

fn writeBlob(
    io: Io,
    arena: Allocator,
    dir: Io.Dir,
    sums: *std.ArrayList(u8),
    base_name: []const u8,
    ext: []const u8,
    target: []u8,
    generated: Generated,
) !void {
    const n = generated catch |err| {
        std.debug.print("corpus: {s} {s} failed: {s}\n", .{ base_name, ext, @errorName(err) });
        return err;
    };
    const blob_name = try std.fmt.allocPrint(arena, "{s}.{s}", .{ base_name, ext });
    try writeFile(io, arena, dir, sums, blob_name, target[0..n]);
}

/// Compress `raw` with the pinned zstd CLI at the shape's `zstdLevel` and
/// write the frame as `<base_name>.zst`, but only after our decoder
/// reproduces the raw bytes exactly: the reference tool encodes and our
/// decoder checks. The manifest entry is added by the sorted `.zst` pass in
/// main.
fn writeZstdBlob(
    io: Io,
    arena: Allocator,
    dir: Io.Dir,
    dir_path: []const u8,
    shape: Shape,
    base_name: []const u8,
    raw: []const u8,
) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, base_name });
    const result = try std.process.run(arena, io, .{
        .argv = &.{ "zstd", "-q", "--no-progress", zstdLevel(shape), "-c", "--", path },
    });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("corpus: zstd CLI failed on {s}: {s}\n", .{ base_name, result.stderr });
            return error.ZstdCliFailed;
        },
        else => return error.ZstdCliFailed,
    }
    const back = try arena.alloc(u8, raw.len);
    const n = zcompress.zstd.decode.decompress(result.stdout, back) catch |err| {
        std.debug.print("corpus: our zstd decoder rejected the CLI frame for {s}: {s}\n", .{
            base_name, @errorName(err),
        });
        return err;
    };
    if (n != raw.len or !mem.eql(u8, back, raw)) return error.ZstdBlobMismatch;
    const name = try std.fmt.allocPrint(arena, "{s}.zst", .{base_name});
    // A missing blob is the normal first-run case; any other read failure is
    // the run's, not a reason to overwrite the file blindly.
    const current: ?[]u8 = dir.readFileAlloc(io, name, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    if (current == null or !mem.eql(u8, current.?, result.stdout)) {
        try dir.writeFile(io, .{ .sub_path = name, .data = result.stdout });
    }
}

/// Compress `raw` with the pinned brotli CLI at `brotli_cli_quality`, reading
/// the file by path (the file form: the CLI sizes the window to the file),
/// and write the stream as `<base_name>.br`, but only after our decoder
/// reproduces the raw bytes exactly. The manifest entry is added by the
/// sorted `.br` pass in main.
fn writeBrotliBlob(
    io: Io,
    arena: Allocator,
    dir: Io.Dir,
    dir_path: []const u8,
    base_name: []const u8,
    raw: []const u8,
) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, base_name });
    const result = try std.process.run(arena, io, .{
        .argv = &.{ "brotli", "-c", "-q", brotli_cli_quality, "--", path },
    });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("corpus: brotli CLI failed on {s}: {s}\n", .{
                base_name, result.stderr,
            });
            return error.BrotliCliFailed;
        },
        else => return error.BrotliCliFailed,
    }
    const back = try arena.alloc(u8, raw.len);
    const n = zcompress.brotli.decode.decompress(result.stdout, back) catch |err| {
        std.debug.print("corpus: our brotli decoder rejected the CLI stream for {s}: {s}\n", .{
            base_name, @errorName(err),
        });
        return err;
    };
    if (n != raw.len or !mem.eql(u8, back, raw)) return error.BrotliBlobMismatch;
    const name = try std.fmt.allocPrint(arena, "{s}.br", .{base_name});
    const current: ?[]u8 = dir.readFileAlloc(io, name, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    if (current == null or !mem.eql(u8, current.?, result.stdout)) {
        try dir.writeFile(io, .{ .sub_path = name, .data = result.stdout });
    }
}

/// Hash every `ext` file in `dir` into the manifest, in name order.
fn hashSorted(
    io: Io,
    arena: Allocator,
    dir: Io.Dir,
    sums: *std.ArrayList(u8),
    ext: []const u8,
) !void {
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .file and mem.endsWith(u8, entry.name, ext)) {
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    for (names.items) |name| {
        const blob = try dir.readFileAlloc(io, name, arena, .unlimited);
        try writeFile(io, arena, dir, sums, name, blob);
    }
}

/// `<tool> --version` against the pin: a mismatch fails the run before any
/// blob is written, so the committed corpus's provenance is the pinned CLIs
/// alone.
fn checkCliVersion(io: Io, arena: Allocator, tool: []const u8, pin: []const u8) !void {
    const result = try std.process.run(arena, io, .{ .argv = &.{ tool, "--version" } });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CliFailed,
        else => return error.CliFailed,
    }
    if (mem.indexOf(u8, result.stdout, pin) == null) {
        std.debug.print("corpus: `{s} --version` is not the pinned {s}: {s}\n", .{
            tool, pin, result.stdout,
        });
        return error.CliVersionMismatch;
    }
}

fn maxCompressedLength(input_len: usize) usize {
    return @max(
        zcompress.gzip.encode.maxCompressedLength(input_len),
        @max(
            zcompress.zlib.encode.maxCompressedLength(input_len),
            zcompress.snappy.encode.maxCompressedLength(input_len),
        ),
    );
}

/// Write `bytes` as `name`, hash it into the SHA256SUMS accumulator, and skip
/// the write when the file already holds exactly these bytes (a regenerated
/// corpus leaves the generated tree untouched).
fn writeFile(
    io: Io,
    arena: Allocator,
    dir: Io.Dir,
    sums: *std.ArrayList(u8),
    name: []const u8,
    bytes: []const u8,
) !void {
    // A missing file (first run) and a file past the one-byte-larger limit
    // (different bytes by construction) both mean "rewrite"; any other read
    // failure is the run's, never a reason to overwrite blindly.
    const current: ?[]u8 = dir.readFileAlloc(io, name, arena, .limited(bytes.len + 1)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => null,
        else => |e| return e,
    };
    if (current == null or !mem.eql(u8, current.?, bytes)) {
        try dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try sums.print(arena, "{s}  {s}\n", .{ hex, name });
}

const Sum = struct { name: []const u8, digest: []const u8 };

/// Parse a SHA256SUMS body (`<hex>  <name>` per line, the sha256sum format)
/// into name/digest pairs.
fn parseSums(arena: Allocator, text: []const u8) !std.ArrayList(Sum) {
    var sums: std.ArrayList(Sum) = .empty;
    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const separator = mem.indexOf(u8, line, "  ") orelse return error.MalformedSums;
        try sums.append(arena, .{
            .digest = line[0..separator],
            .name = line[separator + 2 ..],
        });
    }
    return sums;
}

fn findSum(sums: []const Sum, name: []const u8) ?[]const u8 {
    for (sums) |sum| {
        if (mem.eql(u8, sum.name, name)) return sum.digest;
    }
    return null;
}

/// Check the generated manifest against the committed anchor file by file
/// and fail naming every file that disagrees, is missing, or is extra.
/// Returns the number of verified files.
fn verifyAgainstCommitted(io: Io, arena: Allocator, generated: []const u8) !usize {
    const committed = Io.Dir.cwd().readFileAlloc(io, committed_sums_path, arena, .unlimited) catch |err| {
        std.debug.print("corpus: cannot read the committed anchor {s}: {s}\n", .{
            committed_sums_path, @errorName(err),
        });
        return err;
    };
    const generated_sums = try parseSums(arena, generated);
    const committed_sums = try parseSums(arena, committed);
    var mismatches: usize = 0;
    for (generated_sums.items) |sum| {
        const recorded = findSum(committed_sums.items, sum.name) orelse {
            std.debug.print("corpus: {s} is not in the committed anchor\n", .{sum.name});
            mismatches += 1;
            continue;
        };
        if (!mem.eql(u8, recorded, sum.digest)) {
            std.debug.print("corpus: {s}: generated {s}, committed {s}\n", .{
                sum.name, sum.digest, recorded,
            });
            mismatches += 1;
        }
    }
    for (committed_sums.items) |sum| {
        if (findSum(generated_sums.items, sum.name) == null) {
            std.debug.print("corpus: {s} is missing from the generated corpus\n", .{sum.name});
            mismatches += 1;
        }
    }
    if (mismatches != 0) {
        std.debug.print("corpus: {d} file(s) disagree with {s} (the trust anchor)\n", .{
            mismatches, committed_sums_path,
        });
        return error.CorpusMismatch;
    }
    return generated_sums.items.len;
}

/// The committed anchor directory holds SHA256SUMS alone: generating into it
/// would drop untracked blobs into the tracked tree.
fn refuseCommittedDir(arena: Allocator, dir_path: []const u8) !void {
    const anchor_dir = std.fs.path.dirname(committed_sums_path).?;
    const target = try std.fs.path.resolve(arena, &.{dir_path});
    const anchor = try std.fs.path.resolve(arena, &.{anchor_dir});
    if (mem.eql(u8, target, anchor)) {
        std.debug.print("corpus: {s} is the committed anchor directory; generate into {s}\n", .{
            dir_path, default_dir,
        });
        return error.CommittedDirRefused;
    }
}
