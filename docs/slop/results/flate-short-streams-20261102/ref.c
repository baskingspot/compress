// ref.c: the same loop as main.zig over Wuffs's zlib decoder (-DWUFFS) or
// libdeflate's (-DLIBDEFLATE), whole stream into a buffer each, as libtiff
// inflates a strip; `.zs` files are a TIFF's strips.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#ifdef WUFFS
#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__ZLIB
#include "wuffs-v0.4.c"
static uint8_t work[1 << 16];
static size_t decode1(uint8_t *in, size_t n, uint8_t *out, size_t cap) {
  static wuffs_zlib__decoder dec;
  wuffs_zlib__decoder__initialize(&dec, sizeof dec, WUFFS_VERSION, WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED);
  wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader(in, n, true);
  wuffs_base__io_buffer dst = wuffs_base__ptr_u8__writer(out, cap);
  wuffs_base__status st = wuffs_zlib__decoder__transform_io(&dec, &dst, &src, wuffs_base__make_slice_u8(work, sizeof work));
  if (!wuffs_base__status__is_ok(&st)) { fprintf(stderr, "%s\n", st.repr); exit(1); }
  return dst.meta.wi;
}
#else
#include <libdeflate.h>
static struct libdeflate_decompressor *dec;
static size_t decode1(uint8_t *in, size_t n, uint8_t *out, size_t cap) {
  size_t m;
  if (libdeflate_zlib_decompress(dec, in, n, out, cap, &m) != LIBDEFLATE_SUCCESS) { fprintf(stderr, "bad\n"); exit(1); }
  return m;
}
#endif
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e9 + t.tv_nsec; }
static int multi;
static size_t decode(uint8_t *in, size_t n, uint8_t *out, size_t cap) {
  if (!multi) return decode1(in, n, out, cap);
  size_t total = 0, at = 0;
  while (at < n) { uint32_t k; memcpy(&k, in + at, 4); total += decode1(in + at + 4, k, out, cap); at += 4 + k; }
  return total;
}
int main(int argc, char **argv) {
#ifndef WUFFS
  dec = libdeflate_alloc_decompressor();
#endif
  uint8_t *in = malloc(64 << 20), *out = malloc(200 << 20);
  for (int a = 1; a < argc; a++) {
    FILE *f = fopen(argv[a], "rb"); size_t n = fread(in, 1, 64 << 20, f); fclose(f);
    size_t len = strlen(argv[a]); multi = len > 3 && !strcmp(argv[a] + len - 3, ".zs");
    size_t m = decode(in, n, out, 200 << 20);
    size_t iters = 30000000 / m; if (!iters) iters = 1;
    double best = 1e30;
    for (int r = 0; r < 9; r++) { double t = now(); for (size_t i = 0; i < iters; i++) decode(in, n, out, 200 << 20); t = (now() - t) / iters; if (t < best) best = t; }
    const char *b = strrchr(argv[a], '/'); b = b ? b + 1 : argv[a];
    printf("%s\t%.1f\tMB/s\t%.0f\tns\n", b, m * 1000.0 / best, best);
  }
}
