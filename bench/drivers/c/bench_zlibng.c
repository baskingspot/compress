/* The zlib-ng arm (bench/README.md): the streaming zlib API at level 1 over
 * the three containers as windowBits -15/15/31 (raw/zlib/gzip), plus raw
 * deflate at level 6 for the zc arm's `flate6` row. Streams reset per
 * iteration (deflateReset/inflateReset), so the timed loop is the codec
 * alone.
 *
 * Built against zlib-ng in ZLIB_COMPAT mode (the zlib.h API). Build defines:
 * CBENCH_TARGET (triple string), CBENCH_CPU, ZIG_VERSION, COMPETITOR_VERSION.
 */
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define ARM "zlibng"
#define IMPL "zlibng"
#define TOOL "zlib-ng"
#define CBENCH_CODECS {"flate", "gzip", "zlib", "flate6"}
#define CBENCH_CODEC_COUNT 4
/* flate6 is the level-6 encode row: compress only (a decoder is not
 * per-level, so its round trip and reference decode ride the flate rows). */
#define CBENCH_CODEC_HAS_DIRECTION(codec, direction) \
    (strcmp(codec, "flate6") != 0 || strcmp(direction, "compress") == 0)

static z_stream deflator;
static z_stream inflator;
static int current_wbits;
static int current_level;

static int wbits_for(const char *codec)
{
    if (!strcmp(codec, "gzip")) return 31;
    if (!strcmp(codec, "zlib")) return 15;
    return -15;
}

static int level_for(const char *codec)
{
    return !strcmp(codec, "flate6") ? 6 : 1;
}

static void impl_setup(void)
{
    memset(&deflator, 0, sizeof deflator);
    memset(&inflator, 0, sizeof inflator);
    current_wbits = 0;
    current_level = 0;
}

static void impl_teardown(void)
{
    if (current_wbits) {
        deflateEnd(&deflator);
        inflateEnd(&inflator);
    }
}

/* Reinitialize when the window or the level changes; between rows the
 * streams are between streams, the documented place to re-init. Within one
 * row's timed loop the pair is sticky, so the loop is the codec alone. */
static void setup_streams(int wbits, int level)
{
    if (current_wbits == wbits && current_level == level) return;
    if (current_wbits) {
        deflateEnd(&deflator);
        inflateEnd(&inflator);
    }
    if (deflateInit2(&deflator, level, Z_DEFLATED, wbits, 8, Z_DEFAULT_STRATEGY) != Z_OK)
        exit(1);
    if (inflateInit2(&inflator, wbits) != Z_OK)
        exit(1);
    current_wbits = wbits;
    current_level = level;
}

static size_t impl_compress(const char *codec, const unsigned char *in, size_t in_len,
                            unsigned char *out, size_t out_cap)
{
    setup_streams(wbits_for(codec), level_for(codec));
    if (deflateReset(&deflator) != Z_OK) return 0;
    deflator.next_in = (unsigned char *)in;
    deflator.avail_in = (unsigned)in_len;
    deflator.next_out = out;
    deflator.avail_out = (unsigned)out_cap;
    if (deflate(&deflator, Z_FINISH) != Z_STREAM_END) return 0;
    return out_cap - deflator.avail_out;
}

static size_t impl_decompress(const char *codec, const unsigned char *in, size_t in_len,
                              unsigned char *out, size_t out_cap)
{
    setup_streams(wbits_for(codec), 1);
    if (inflateReset(&inflator) != Z_OK) return 0;
    inflator.next_in = (unsigned char *)in;
    inflator.avail_in = (unsigned)in_len;
    inflator.next_out = out;
    inflator.avail_out = (unsigned)out_cap;
    if (inflate(&inflator, Z_FINISH) != Z_STREAM_END) return 0;
    return out_cap - inflator.avail_out;
}

#include "cbench.h"
