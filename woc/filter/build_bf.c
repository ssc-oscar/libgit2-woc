// build_bf.c -- build a binary-fuse8 filter from 20-byte SHA keys on stdin
// (first 8 bytes used as the uint64 key) and serialize it to <outfile>.
//   header: magic "BF8\1", Seed(u64), then 6x u32 (Size,SegLen,SegLenMask,
//           SegCount,SegCountLen,ArrayLength), then ArrayLength fingerprint bytes.
// Usage:  <extract first-40-hex sha as 20 raw bytes> | build_bf  out.bf
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "binaryfusefilter.h"

static int cmp_u64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return (x > y) - (x < y);
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: build_bf <outfile>\n"); return 2; }
  size_t cap = 1 << 20, n = 0;
  uint64_t *keys = malloc(cap * sizeof(uint64_t));
  size_t bufsz = 20 * 100000; unsigned char *buf = malloc(bufsz); size_t leftover = 0;
  for (;;) {
    size_t r = fread(buf + leftover, 1, bufsz - leftover, stdin);
    size_t avail = leftover + r, recs = avail / 20;
    for (size_t i = 0; i < recs; i++) {
      if (n == cap) { cap *= 2; keys = realloc(keys, cap * sizeof(uint64_t)); }
      uint64_t k; memcpy(&k, buf + i * 20, 8); keys[n++] = k;
    }
    leftover = avail - recs * 20; memmove(buf, buf + recs * 20, leftover);
    if (r == 0) break;
  }
  qsort(keys, n, sizeof(uint64_t), cmp_u64);
  size_t m = 0; for (size_t i = 0; i < n; i++) if (i == 0 || keys[i] != keys[i-1]) keys[m++] = keys[i];

  binary_fuse8_t f;
  if (!binary_fuse8_allocate((uint32_t)m, &f)) { fprintf(stderr, "alloc fail\n"); return 1; }
  if (!binary_fuse8_populate(keys, (uint32_t)m, &f)) { fprintf(stderr, "populate fail\n"); return 1; }

  FILE *o = fopen(argv[1], "wb"); if (!o) { perror("fopen"); return 1; }
  fwrite("BF8\1", 1, 4, o);
  fwrite(&f.Seed, 8, 1, o);
  uint32_t hdr[6] = { f.Size, f.SegmentLength, f.SegmentLengthMask, f.SegmentCount, f.SegmentCountLength, f.ArrayLength };
  fwrite(hdr, 4, 6, o);
  fwrite(f.Fingerprints, 1, f.ArrayLength, o);
  fclose(o);
  fprintf(stderr, "built %s: distinct=%zu (dups=%zu) array=%u bytes=%.0fMB bits/key=%.2f\n",
          argv[1], m, n - m, f.ArrayLength, f.ArrayLength/1e6, (double)f.ArrayLength*8/m);
  binary_fuse8_free(&f);
  return 0;
}
