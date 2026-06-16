// hasObjBF.c -- negative-cache dedup front-end (blob+commit+tree).
// Loads per-(type,shard) binary-fuse filters (mmap, RAM-resident) and streams an
// olist (repo;type;sha;) from stdin:
//   * type has a filter, filter says ABSENT  -> definitely NOT in WoC -> SURVIVOR -> stdout
//   * filter says PRESENT (incl ~0.4% FP)    -> DEFER to da5 for exact check
//   * no filter for type (e.g. tag) / missing -> DEFER to da5
// Filters have NO false negatives, so ABSENT is exact -> zero data-loss risk.
// Wrapper: hasObjBF <dir> defer.gz < olist > survivors
//          pigz -dc defer.gz | ssh da5 hasObj >> survivors
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
#define NTYPE  3
static const char *TYPES[NTYPE] = { "blob", "commit", "tree" };
static binary_fuse8_t filt[NTYPE][NSHARD];
static int loaded[NTYPE][NSHARD];

static int load_one(const char *dir, int t, int sec) {
  char path[512]; snprintf(path, sizeof path, "%s/%s_%d.bf", dir, TYPES[t], sec);
  int fd = open(path, O_RDONLY); if (fd < 0) return 0;
  struct stat st; fstat(fd, &st);
  unsigned char *p = mmap(NULL, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
  close(fd); if (p == MAP_FAILED || memcmp(p, "BF8\1", 4) != 0) return 0;
  binary_fuse8_t *f = &filt[t][sec];
  memcpy(&f->Seed, p + 4, 8);
  uint32_t h[6]; memcpy(h, p + 12, 24);
  f->Size=h[0]; f->SegmentLength=h[1]; f->SegmentLengthMask=h[2];
  f->SegmentCount=h[3]; f->SegmentCountLength=h[4]; f->ArrayLength=h[5];
  f->Fingerprints = p + 36;
  return 1;
}
static inline int hexv(int c){ return c<='9'?c-'0':(c|32)-'a'+10; }
static int type_idx(const char *s, size_t n){
  for (int t=0;t<NTYPE;t++) if (strlen(TYPES[t])==n && memcmp(s,TYPES[t],n)==0) return t;
  return -1;
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: hasObjBF <filterdir> <deferfile>\n"); return 2; }
  int nloaded = 0;
  for (int t=0;t<NTYPE;t++) for (int s=0;s<NSHARD;s++) nloaded += (loaded[t][s] = load_one(argv[1], t, s));
  fprintf(stderr, "hasObjBF: loaded %d/%d filters\n", nloaded, NTYPE*NSHARD);
  FILE *defer = fopen(argv[2], "w"); if (!defer) { perror("defer"); return 1; }

  char *line=NULL; size_t cap=0; ssize_t len;
  long surv=0, deferred=0;
  while ((len = getline(&line,&cap,stdin)) > 0) {
    char *s1 = strchr(line, ';'); if (!s1) { fputs(line,defer); deferred++; continue; }
    char *type = s1+1; char *s2 = strchr(type, ';'); if (!s2) { fputs(line,defer); deferred++; continue; }
    char *sha = s2+1;
    int t = type_idx(type, s2-type);
    if (t < 0) { fputs(line,defer); deferred++; continue; }            // tag/unknown -> da5
    int sec = ((hexv(sha[0])<<4)|hexv(sha[1])) % NSHARD;
    if (!loaded[t][sec]) { fputs(line,defer); deferred++; continue; }  // missing filter -> da5
    uint64_t key=0; for (int i=0;i<8;i++) key |= (uint64_t)((hexv(sha[2*i])<<4)|hexv(sha[2*i+1])) << (8*i);
    if (binary_fuse8_contain(key, &filt[t][sec])) { fputs(line,defer); deferred++; }  // maybe -> da5
    else { fputs(line,stdout); surv++; }                               // absent -> survivor (exact)
  }
  fclose(defer);
  fprintf(stderr, "hasObjBF: local-survivors=%ld deferred-to-da5=%ld (%.1f%% resolved locally)\n",
          surv, deferred, surv+deferred? 100.0*surv/(surv+deferred):0.0);
  return 0;
}
