/* The brotli-c arm (bench/README.md): the pinned google/brotli v1.2.0
 * decoder and encoder, the native reference. The decode rows match the zc
 * arm's `brotli/decompress/...` rows (bench/zig/bench_compress.zig), over
 * the same `.br` reference streams (the pinned CLI at quality 11); the
 * encode rows match the zc arm's `brotli/compress/...` rows: the q3 class,
 * the CLI's automatic window (the smallest lgwin whose backward limit holds
 * the input), the size hint the CLI sets, and the one-shot's single FINISH
 * call — `BrotliEncoderCompress`'s call sequence, run over an instance
 * whose allocations come from the arena.
 *
 * The timed loop is the codec alone. The library has no decoder reset, so
 * one stream is one instance: BrotliDecoderCreateInstance, one
 * BrotliDecoderDecompressStream call over the whole blob and the whole
 * output, BrotliDecoderDestroyInstance. The one-shot BrotliDecoderDecompress
 * is those same calls over the default allocator, which on the corpus is 4
 * to 10 malloc/free pairs per stream (the state, the shared-dictionary
 * record, the block-type trees, the ring sized to the output, and each
 * meta-block's context maps and tree groups: 52 to 114 KiB). That is a
 * per-iteration allocator cost the other arms do not pay (the google/snappy
 * driver's precedent), so the instance allocates from a bump arena that is
 * allocated and pre-faulted once in setup and rewound per stream. The
 * encoder is the same shape: no encoder reset either, and the one-shot
 * BrotliEncoderCompress allocates its instance from the default allocator,
 * so the encode row creates, runs, and destroys one instance from the same
 * arena.
 *
 * What stays in the loop is the library's own per-stream work: the decoder's
 * state init (including the shared-dictionary record's memset), the
 * tree-group setup, the decode into the ring, and the ring-to-output copy;
 * the encoder's hasher setup and the q3 emission. The C decoder always
 * decodes through its ring; the zc one-shot decodes in place. That is an
 * API difference the rows measure, not a harness artifact.
 *
 * Library defaults otherwise: canny ring allocation on, large window off,
 * BROTLI_STATIC_INIT_NONE (compile-time tables). Build defines:
 * CBENCH_TARGET (triple string), CBENCH_CPU, ZIG_VERSION,
 * COMPETITOR_VERSION.
 */
#include <stdlib.h>
#include <string.h>

#include <brotli/decode.h>
#include <brotli/encode.h>

#define ARM "brotli-c"
#define IMPL "brotli-c"
#define TOOL "google/brotli"
#define CBENCH_CODECS {"brotli"}
#define CBENCH_CODEC_COUNT 1
#define CBENCH_DIRECTIONS {"compress", "decompress"}
#define CBENCH_DIRECTION_COUNT 2

/* 4 MiB covers the format's worst decode meta-block (256 trees per category,
 * about 2.7 MiB of tables) plus a 64 KiB ring, and the encoder's q3 state at
 * the corpus windows (the ring, the H3 table, the command buffer, the output
 * window: about 1 MiB). Exhaustion returns NULL: the codec fails with an
 * allocation error and the check reports it. */
#define ARENA_BYTES ((size_t)4 << 20)
#define ARENA_ALIGN ((size_t)64)

static unsigned char *arena;
static size_t arena_used;

static void *arena_alloc(void *opaque, size_t size)
{
    (void)opaque;
    size_t start = (arena_used + ARENA_ALIGN - 1) & ~(ARENA_ALIGN - 1);
    if (start > ARENA_BYTES || size > ARENA_BYTES - start) return NULL;
    arena_used = start + size;
    return arena + start;
}

/* Rewound wholesale per stream in impl_compress/impl_decompress. */
static void arena_free(void *opaque, void *address)
{
    (void)opaque;
    (void)address;
}

static void impl_setup(void)
{
    arena = (unsigned char *)malloc(ARENA_BYTES);
    if (!arena) exit(1);
    /* Touch every page now, so the timed loop never takes a page fault. */
    memset(arena, 0, ARENA_BYTES);
    arena_used = 0;
}

static void impl_teardown(void)
{
    free(arena);
    arena = NULL;
}

/* The CLI's automatic-window rule (brotli.c: the smallest lgwin in 10..24
 * whose backward limit holds the whole input). The zc one-shot follows the
 * same rule, so the encode rows are the same class. */
static int lgwin_for(size_t in_len)
{
    int lgwin = BROTLI_MIN_WINDOW_BITS;
    while ((uint64_t)(((size_t)1 << lgwin) - 16) < (uint64_t)in_len) {
        lgwin++;
        if (lgwin == BROTLI_MAX_WINDOW_BITS) break;
    }
    return lgwin;
}

/* The encode row: the one-shot's call sequence (quality 3, the CLI's
 * window, the size hint the CLI sets, one FINISH call) over an instance the
 * arena owns. */
static size_t impl_compress(const char *codec, const unsigned char *in, size_t in_len,
                            unsigned char *out, size_t out_cap)
{
    (void)codec; /* one codec: the brotli stream */
    arena_used = 0;
    BrotliEncoderState *state = BrotliEncoderCreateInstance(arena_alloc, arena_free, NULL);
    if (!state) return 0;
    BROTLI_BOOL ok = BrotliEncoderSetParameter(state, BROTLI_PARAM_QUALITY, 3) &&
        BrotliEncoderSetParameter(state, BROTLI_PARAM_LGWIN, (uint32_t)lgwin_for(in_len)) &&
        BrotliEncoderSetParameter(state, BROTLI_PARAM_SIZE_HINT, (uint32_t)in_len);
    size_t available_in = in_len;
    size_t available_out = out_cap;
    const uint8_t *next_in = in;
    uint8_t *next_out = out;
    size_t total_out = 0;
    while (ok && !BrotliEncoderIsFinished(state)) {
        ok = BrotliEncoderCompressStream(
            state, BROTLI_OPERATION_FINISH,
            &available_in, &next_in, &available_out, &next_out, &total_out);
    }
    BROTLI_BOOL finished = BrotliEncoderIsFinished(state);
    BrotliEncoderDestroyInstance(state);
    /* The whole input must be consumed and the stream finished. */
    if (!ok || !finished || available_in != 0) return 0;
    return out_cap - available_out;
}

static size_t impl_decompress(const char *codec, const unsigned char *in, size_t in_len,
                              unsigned char *out, size_t out_cap)
{
    (void)codec; /* one codec: the brotli stream */
    arena_used = 0;
    BrotliDecoderState *state = BrotliDecoderCreateInstance(arena_alloc, arena_free, NULL);
    if (!state) return 0;
    size_t available_in = in_len;
    size_t available_out = out_cap;
    const uint8_t *next_in = in;
    uint8_t *next_out = out;
    BrotliDecoderResult result = BrotliDecoderDecompressStream(
        state, &available_in, &next_in, &available_out, &next_out, NULL);
    BrotliDecoderDestroyInstance(state);
    /* Each blob is exactly one stream: input left over is a corpus bug. */
    if (result != BROTLI_DECODER_RESULT_SUCCESS || available_in != 0) return 0;
    return out_cap - available_out;
}

#include "cbench.h"
