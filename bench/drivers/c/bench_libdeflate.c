/* The libdeflate arm (bench/README.md): whole-buffer
 * libdeflate_{deflate,gzip,zlib}_{compress,decompress} at level 1, the fast
 * class matching the compress level-1 rows, plus raw deflate at level 6 for
 * the zc arm's `flate6` row. Compressor and decompressor are allocated once
 * per process (the documented reuse pattern), so the timed loop is the codec
 * alone.
 *
 * Build defines: CBENCH_TARGET (triple string), CBENCH_CPU, ZIG_VERSION,
 * COMPETITOR_VERSION.
 */
#include <string.h>

#include <libdeflate.h>

#define ARM "libdeflate"
#define IMPL "libdeflate"
#define TOOL "libdeflate"
#define CBENCH_CODECS {"flate", "gzip", "zlib", "flate6"}
#define CBENCH_CODEC_COUNT 4
/* flate6 is the level-6 encode row: compress only (a decoder is not
 * per-level, so its round trip and reference decode ride the flate rows). */
#define CBENCH_CODEC_HAS_DIRECTION(codec, direction) \
    (strcmp(codec, "flate6") != 0 || strcmp(direction, "compress") == 0)

static struct libdeflate_compressor *compressor;
static struct libdeflate_compressor *compressor6;
static struct libdeflate_decompressor *decompressor;

static void impl_setup(void)
{
    compressor = libdeflate_alloc_compressor(1);
    compressor6 = libdeflate_alloc_compressor(6);
    decompressor = libdeflate_alloc_decompressor();
}

static void impl_teardown(void)
{
    libdeflate_free_compressor(compressor);
    libdeflate_free_compressor(compressor6);
    libdeflate_free_decompressor(decompressor);
}

static size_t impl_compress(const char *codec, const unsigned char *in, size_t in_len,
                            unsigned char *out, size_t out_cap)
{
    if (!strcmp(codec, "flate6"))
        return libdeflate_deflate_compress(compressor6, in, in_len, out, out_cap);
    if (!strcmp(codec, "gzip"))
        return libdeflate_gzip_compress(compressor, in, in_len, out, out_cap);
    if (!strcmp(codec, "zlib"))
        return libdeflate_zlib_compress(compressor, in, in_len, out, out_cap);
    return libdeflate_deflate_compress(compressor, in, in_len, out, out_cap);
}

static size_t impl_decompress(const char *codec, const unsigned char *in, size_t in_len,
                              unsigned char *out, size_t out_cap)
{
    size_t actual = 0;
    enum libdeflate_result result;
    if (!strcmp(codec, "gzip"))
        result = libdeflate_gzip_decompress(decompressor, in, in_len, out, out_cap, &actual);
    else if (!strcmp(codec, "zlib"))
        result = libdeflate_zlib_decompress(decompressor, in, in_len, out, out_cap, &actual);
    else
        result = libdeflate_deflate_decompress(decompressor, in, in_len, out, out_cap, &actual);
    return result == LIBDEFLATE_SUCCESS ? actual : 0;
}

#include "cbench.h"
