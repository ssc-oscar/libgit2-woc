// Binary-fuse (8-bit) filter benchmark: read 20-byte SHA keys from stdin,
// use first 8 bytes as the uint64 key, dedup, build, measure size/FP/throughput.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include "binaryfusefilter.h"

static int cmp_u64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return (x > y) - (x < y);
}
static double now(void) {
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

int main(void) {
  size_t cap = 1 << 20, n = 0;
  uint64_t *keys = malloc(cap * sizeof(uint64_t));
  size_t bufsz = 20 * 100000;
  unsigned char *buf = malloc(bufsz);
  size_t leftover = 0;
  double t0 = now();
  for (;;) {
    size_t r = fread(buf + leftover, 1, bufsz - leftover, stdin);
    size_t avail = leftover + r, recs = avail / 20;
    for (size_t i = 0; i < recs; i++) {
      if (n == cap) { cap *= 2; keys = realloc(keys, cap * sizeof(uint64_t)); }
      uint64_t k; memcpy(&k, buf + i * 20, 8); keys[n++] = k;
    }
    leftover = avail - recs * 20;
    memmove(buf, buf + recs * 20, leftover);
    if (r == 0) break;
  }
  double t_read = now() - t0;

  qsort(keys, n, sizeof(uint64_t), cmp_u64);
  size_t m = 0;
  for (size_t i = 0; i < n; i++) if (i == 0 || keys[i] != keys[i-1]) keys[m++] = keys[i];

  binary_fuse8_t filter;
  if (!binary_fuse8_allocate((uint32_t)m, &filter)) { fprintf(stderr, "alloc fail\n"); return 1; }
  double t1 = now();
  if (!binary_fuse8_populate(keys, (uint32_t)m, &filter)) { fprintf(stderr, "populate fail\n"); return 1; }
  double t_build = now() - t1;
  size_t bytes = binary_fuse8_size_in_bytes(&filter);

  size_t nq = m < 1000000 ? m : 1000000;
  double t2 = now(); size_t tp = 0;
  for (size_t i = 0; i < nq; i++) tp += binary_fuse8_contain(keys[i], &filter) ? 1 : 0;
  double tp_t = now() - t2;

  uint64_t s = 88172645463325252ULL; double t3 = now(); size_t fp = 0;
  for (size_t i = 0; i < nq; i++) { s ^= s<<13; s ^= s>>7; s ^= s<<17; fp += binary_fuse8_contain(s, &filter) ? 1 : 0; }
  double ta_t = now() - t3;

  printf("keys raw=%zu distinct=%zu (dups=%zu)\n", n, m, n - m);
  printf("read_stdin       = %.1fs\n", t_read);
  printf("filter SIZE      = %.0f MB  (%.2f bits/key)\n", bytes/1e6, (double)bytes*8/m);
  printf("build (populate) = %.1fs  (%.1f M keys/s)\n", t_build, m/t_build/1e6);
  printf("contain present  = %.1f M lookups/s  (truepos %zu/%zu)\n", nq/tp_t/1e6, tp, nq);
  printf("contain absent   = %.1f M lookups/s\n", nq/ta_t/1e6);
  printf("false positives  = %zu/%zu  (%.3f%%)\n", fp, nq, 100.0*fp/nq);
  binary_fuse8_free(&filter);
  return 0;
}
