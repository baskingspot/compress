#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__ZLIB
#include "wuffs-v0.4.c"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e9 + t.tv_nsec; }
static uint8_t work[1 << 16];
static size_t decode(uint8_t *in, size_t n, uint8_t *out, size_t cap) {
  static wuffs_zlib__decoder dec;
  wuffs_zlib__decoder__initialize(&dec, sizeof dec, WUFFS_VERSION, WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED);
  wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader(in, n, true);
  wuffs_base__io_buffer dst = wuffs_base__ptr_u8__writer(out, cap);
  wuffs_base__status st = wuffs_zlib__decoder__transform_io(&dec, &dst, &src, wuffs_base__make_slice_u8(work, sizeof work));
  if (!wuffs_base__status__is_ok(&st)) { fprintf(stderr, "%s\n", st.repr); exit(1); }
  return dst.meta.wi;
}
int main(int argc, char **argv) {
  uint8_t *in = malloc(64 << 20), *out = malloc(200 << 20);
  for (int a = 1; a < argc; a++) {
    FILE *f = fopen(argv[a], "rb"); size_t n = fread(in, 1, 64 << 20, f); fclose(f);
    size_t m = decode(in, n, out, 200 << 20);
    size_t iters = 30000000 / m; if (!iters) iters = 1;
    double best = 1e30;
    for (int r = 0; r < 9; r++) { double t = now(); for (size_t i = 0; i < iters; i++) decode(in, n, out, 200 << 20); t = (now() - t) / iters; if (t < best) best = t; }
    const char *b = strrchr(argv[a], '/'); b = b ? b + 1 : argv[a];
    printf("%s\t%.1f\tMB/s\t%.0f\tns\n", b, m * 1000.0 / best, best);
  }
}
