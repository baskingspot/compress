/* The brotli-c arm (bench/README.md): the pinned google/brotli v1.2.0
 * decoder, the native reference, decode only. zcompress ships no brotli
 * encoder, so a compress row would have no zc counterpart. The rows match
 * the zc arm's `brotli/decompress/...` rows (bench/zig/bench_zcompress.zig),
 * over the same `.br` reference streams (the pinned CLI at quality 11).
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
 * allocated and pre-faulted once in setup and rewound per stream.
 *
 * What stays in the loop is the library's own per-stream work: the state
 * init (including the shared-dictionary record's memset), the tree-group
 * setup, the decode into the ring, and the ring-to-output copy. The C
 * decoder always decodes through its ring; the zc one-shot decodes in place.
 * That is an API difference the rows measure, not a harness artifact.
 *
 * Library defaults otherwise: canny ring allocation on, large window off,
 * BROTLI_STATIC_INIT_NONE (compile-time tables). Build defines:
 * CBENCH_TARGET (triple string), CBENCH_CPU, ZIG_VERSION,
 * COMPETITOR_VERSION.
 */
#include <stdlib.h>
#include <string.h>

#include <brotli/decode.h>

#define ARM "brotli-c"
#define IMPL "brotli-c"
#define TOOL "google/brotli"
#define CBENCH_CODECS {"brotli"}
#define CBENCH_CODEC_COUNT 1
#define CBENCH_DIRECTIONS {"decompress"}
#define CBENCH_DIRECTION_COUNT 1

/* 4 MiB covers the format's worst meta-block (256 trees per category, about
 * 2.7 MiB of tables) plus a 64 KiB ring. Exhaustion returns NULL: the
 * decoder fails with an allocation error and the check reports it. */
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

/* Rewound wholesale per stream in impl_decompress. */
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

/* Never called: CBENCH_DIRECTIONS is decode only. */
static size_t impl_compress(const char *codec, const unsigned char *in, size_t in_len,
                            unsigned char *out, size_t out_cap)
{
    (void)codec;
    (void)in;
    (void)in_len;
    (void)out;
    (void)out_cap;
    return 0;
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
