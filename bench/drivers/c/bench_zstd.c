/* The zstd-c arm (bench/README.md): the pinned facebook/zstd v1.5.7, the
 * native reference, using whole-buffer ZSTD_compress2 at the CCtx's level-1
 * and level-3 parameters (the fast classes the zc arm's `zstd` and `zstd3`
 * rows measure) and ZSTD_decompressDCtx on reused contexts. This is the
 * simple one-shot API and matches the zc arm's `zstd/...` rows
 * (bench/zig/bench_compress.zig).
 *
 * Window limit: ZSTD_d_windowLogMax is pinned to ZSTD_WINDOWLOG_LIMIT_DEFAULT
 * (27, the reference default). This is the driver's own setting, recorded so
 * the arm cannot silently accept windows the default build refuses. It does
 * not mirror the zc arm: our one-shot has no window cap (its history is the
 * destination buffer), and the corpus frames are single-segment with
 * Window_Size = FCS <= 64 KiB, so every arm's limit accepts them either way.
 *
 * Build defines: CBENCH_TARGET (triple string), CBENCH_CPU, ZIG_VERSION,
 * COMPETITOR_VERSION.
 */
#include <stdlib.h>
#include <string.h>

#include <zstd.h>

#define ARM "zstd-c"
#define IMPL "zstd-c"
#define TOOL "zstd"
#define CBENCH_CODECS {"zstd", "zstd3"}
#define CBENCH_CODEC_COUNT 2
#define CBENCH_DIRECTIONS {"compress", "decompress"}
#define CBENCH_DIRECTION_COUNT 2
/* zstd3 is the level-3 encode row: compress only (a decoder is not
 * per-level, so its round trip and reference decode ride the zstd rows). */
#define CBENCH_CODEC_HAS_DIRECTION(codec, direction) \
    (strcmp(codec, "zstd3") != 0 || strcmp(direction, "compress") == 0)

/* Owned by impl_setup/impl_teardown; the documented reuse pattern, so the
 * timed loop is the compress/decode alone. */
static ZSTD_CCtx *cctx;
static ZSTD_DCtx *dctx;
static int cctx_level;

static void impl_setup(void)
{
    cctx = ZSTD_createCCtx();
    dctx = ZSTD_createDCtx();
    if (!cctx || !dctx) exit(1);
    /* The fair grid: the zc one-shot's default form writes the 4-byte XXH64
     * trailer (byte parity with the CLI's default output), so the library
     * arm pays its checksum flag too — without this the C arm skips ~2.5
     * us per 64 KiB on ARM, ~35% of the html-64K encode row, and every
     * zstd comparison overstates the gap. The compression level moves here
     * too: ZSTD_compress2 has no level argument, it takes the sticky
     * parameters set here. */
    if (ZSTD_isError(ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, 1)))
        exit(1);
    cctx_level = 1;
    if (ZSTD_isError(ZSTD_CCtx_setParameter(cctx, ZSTD_c_checksumFlag, 1)))
        exit(1);
    /* 27 = ZSTD_WINDOWLOG_LIMIT_DEFAULT (zstd_internal.h — the public
     * zstd.h hides it behind the static-linking-only section). */
    if (ZSTD_isError(ZSTD_DCtx_setParameter(dctx, ZSTD_d_windowLogMax, 27)))
        exit(1);
}

static void impl_teardown(void)
{
    ZSTD_freeCCtx(cctx);
    ZSTD_freeDCtx(dctx);
    cctx = NULL;
    dctx = NULL;
}

/* Move the CCtx to `level` when the row changes. Between ZSTD_compress2
 * calls the CCtx is between frames, the documented place to set it; within
 * one row's timed loop the level is sticky, so the loop is the codec
 * alone. */
static void setup_level(int level)
{
    if (cctx_level == level) return;
    if (ZSTD_isError(ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, level)))
        exit(1);
    cctx_level = level;
}

static size_t impl_compress(const char *codec, const unsigned char *in, size_t in_len,
                            unsigned char *out, size_t out_cap)
{
    /* Level 1 (the `zstd` rows) or level 3 (the `zstd3` rows). The call is
     * ZSTD_compress2, not ZSTD_compressCCtx: the one-shot CCtx variant
     * ignores the CCtx's sticky parameters (the vendored zstd.h, "API
     * design": "do not apply to one-shot variants such as
     * ZSTD_compressCCtx()"), so the checksum flag set in impl_setup never
     * reached the frame and the C arm skipped ~12 us per 64 KiB on the
     * literal-heavy encode rows — the first checksum-fair attempt was a
     * no-op. compress2 applies the parameters: the frame form matches the
     * zc one-shot's (content size + XXH64 trailer) and the size rows are
     * exact parity. */
    setup_level(!strcmp(codec, "zstd3") ? 3 : 1);
    size_t n = ZSTD_compress2(cctx, out, out_cap, in, in_len);
    if (ZSTD_isError(n)) return 0;
    return n;
}

static size_t impl_decompress(const char *codec, const unsigned char *in, size_t in_len,
                              unsigned char *out, size_t out_cap)
{
    (void)codec; /* the frame format is one: the decoder is not per-level */
    size_t n = ZSTD_decompressDCtx(dctx, out, out_cap, in, in_len);
    if (ZSTD_isError(n)) return 0;
    return n;
}

#include "cbench.h"
