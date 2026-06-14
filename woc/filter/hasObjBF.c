// hasObjBF.c -- negative-cache dedup front-end (sketch).
// Loads the 128 per-shard blob binary-fuse filters (mmap, RAM-resident via page
// cache) and streams an olist (repo;type;sha;) from stdin:
//   * blob line, filter says ABSENT  -> definitely NOT in WoC -> SURVIVOR -> stdout
//   * blob line, filter says PRESENT -> maybe (incl ~0.39% FP) -> DEFER to da5
//   * non-blob (commit/tree/tag)     -> no local filter yet  -> DEFER to da5
// Wrapper then runs the deferred set through da5's exact hasObj and merges:
//   hasObjBF /fast/blobFilters defer.gz < olist > survivors
//   pigz -dc defer.gz | ssh da5 hasObj >> survivors
// Filters have NO false negatives, so "ABSENT" is exact -> zero data-loss risk.
//
//   build: gcc -O3 -o hasObjBF hasObjBF.c -lm   (needs binaryfusefilter.h)
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "binaryfusefilter.h"

#define NSHARD 128
static binary_fuse8_t filt[NSHARD];
static int loaded[NSHARD];

static int load_filter(const char *dir, int sec) {
  char path[512]; snprintf(path, sizeof path, "%s/blob_%d.bf", dir, sec);
  int fd = open(path, O_RDONLY); if (fd < 0) return 0;
  struct stat st; fstat(fd, &st);
  unsigned char *p = mmap(NULL, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
  close(fd); if (p == MAP_FAILED) return 0;
  if (memcmp(p, "BF8\1", 4) != 0) return 0;
  binary_fuse8_t *f = &filt[sec];
  memcpy(&f->Seed, p + 4, 8);
  uint32_t h[6]; memcpy(h, p + 12, 24);
  f->Size=h[0]; f->SegmentLength=h[1]; f->SegmentLengthMask=h[2];
  f->SegmentCount=h[3]; f->SegmentCountLength=h[4]; f->ArrayLength=h[5];
  f->Fingerprints = p + 36;            // mmap'd; stays RAM-resident in page cache
  return 1;
}

static inline int hexval(int c){ return c<='9'?c-'0':(c|32)-'a'+10; }

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: hasObjBF <filterdir> <deferfile>\n"); return 2; }
  for (int s = 0; s < NSHARD; s++) loaded[s] = load_filter(argv[1], s);
  FILE *defer = fopen(argv[2], "w"); if (!defer) { perror("defer"); return 1; }

  char *line = NULL; size_t lcap = 0; ssize_t len;
  long surv = 0, deferred = 0;
  while ((len = getline(&line, &lcap, stdin)) > 0) {
    // parse repo;type;sha;  -> type = field 1, sha = field 2 (40 hex)
    char *p = line, *f0 = p;
    char *s1 = strchr(p, ';'); if (!s1) { fputs(line, defer); deferred++; continue; }
    char *type = s1 + 1;
    char *s2 = strchr(type, ';'); if (!s2) { fputs(line, defer); deferred++; continue; }
    char *sha = s2 + 1;
    int isblob = (s2 - type == 4 && memcmp(type, "blob", 4) == 0);
    if (!isblob) { fputs(line, defer); deferred++; continue; }     // no local filter
    // sec = first byte %128 ; key = first 8 bytes (little-endian) of the 20-byte sha
    int b0 = (hexval(sha[0])<<4)|hexval(sha[1]); int sec = b0 % NSHARD;
    if (!loaded[sec]) { fputs(line, defer); deferred++; continue; } // filter missing
    uint64_t key = 0;
    for (int i = 0; i < 8; i++) key |= (uint64_t)((hexval(sha[2*i])<<4)|hexval(sha[2*i+1])) << (8*i);
    if (binary_fuse8_contain(key, &filt[sec])) { fputs(line, defer); deferred++; } // maybe -> da5
    else { fputs(line, stdout); surv++; }                          // absent -> survivor (exact)
    (void)f0;
  }
  fclose(defer);
  fprintf(stderr, "hasObjBF: local survivors=%ld  deferred-to-da5=%ld\n", surv, deferred);
  return 0;
}
