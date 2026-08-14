/* sidx2tch <sidx> <bin> <out.tch>
 * Convert a gatherWS WS shard (tree_<sec>.sidx + tree_<sec>.bin, offset-indexed) into the
 * content .tch that cmputeDiffGenFB wants: key = sha20 (binary), value = LZF-compressed object
 * content bytes (verbatim from the bin -- same framing as All.sha1c). No recompression.
 * sidx record = 32B: sha20 + off(u64le) + len(u32le). */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <tchdb.h>
int main(int argc, char **argv){
  if(argc < 4){ fprintf(stderr, "usage: sidx2tch <sidx> <bin> <out.tch>\n"); return 1; }
  FILE *sx = fopen(argv[1], "rb"); if(!sx){ perror(argv[1]); return 2; }
  int bfd = open(argv[2], O_RDONLY); if(bfd < 0){ perror(argv[2]); return 2; }
  TCHDB *h = tchdbnew();
  tchdbtune(h, -1, -1, -1, HDBTLARGE);
  /* APPEND=1: open an existing .tch and ADD records (e.g. append gen commits to a copied base
   * All.sha1c tch to build a full base∪gen content .tch for a fallback-less worker). */
  int omode = getenv("APPEND") ? HDBOWRITER : (HDBOWRITER | HDBOCREAT | HDBOTRUNC);
  if(!tchdbopen(h, argv[3], omode)){
    fprintf(stderr, "tchdbopen fail %s (ecode %d)\n", argv[3], tchdbecode(h)); return 3; }
  uint8_t rec[32]; static uint8_t buf[1<<27]; long n = 0, bad = 0;
  while(fread(rec, 1, 32, sx) == 32){
    uint64_t off; uint32_t len;
    memcpy(&off, rec+20, 8); memcpy(&len, rec+28, 4);
    if(len > sizeof buf){ fprintf(stderr, "len %u > buf\n", len); bad++; continue; }
    if(pread(bfd, buf, len, (off_t)off) != (ssize_t)len){ bad++; continue; }
    if(!tchdbput(h, rec, 20, buf, len)){ fprintf(stderr, "put fail ecode %d\n", tchdbecode(h)); bad++; }
    n++;
  }
  if(!tchdbclose(h)){ fprintf(stderr, "tchdbclose fail ecode %d\n", tchdbecode(h)); }
  tchdbdel(h); close(bfd); fclose(sx);
  fprintf(stderr, "sidx2tch: %ld records, %ld bad -> %s\n", n, bad, argv[3]);
  return bad ? 4 : 0;
}
