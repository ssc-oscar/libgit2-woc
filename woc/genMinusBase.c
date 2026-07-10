/* genMinusBase.c -- clean a gen layer shard: drop objects that are ALSO in the base.
 *   genMinusBase <baseIdx> <genIdx> <genBin> <outIdx> <outBin>
 *
 * The irregular V2604->V2605 transition wrote ~734M base-overflow objects into BOTH the
 * base and the gen (verified: same sha, same stored len, different offset), AND a small
 * set of V2604 objects leaked into the gen too. This makes gen NOT a clean increment.
 * We load every base sha (col4 of baseIdx) into an in-RAM hash set, stream genIdx in id
 * order, DROP any record whose sha is in the base, and byte-copy each KEPT record's bin
 * range re-numbered (id) + re-offset (gen-local, 0-based) so CmtN2OffGen/TreeN2OffGen can
 * re-map. NO decompression -- pure stored-range copy (filterDeoff discipline).
 *
 * build: cc -O2 -o genMinusBase genMinusBase.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* open-addressing hash set of 20-byte sha keys. 2^28 slots (268M) handles up to ~180M
 * base tree shas at 0.67 load. 20 bytes/slot = 5.4 GB. */
#define HBITS 28
#define HSIZE (1UL<<HBITS)
#define HMASK (HSIZE-1)
static uint8_t (*SET)[20];   /* SET[i] all-zero == empty slot */

static int is_zero(const uint8_t*k){ for(int i=0;i<20;i++) if(k[i]) return 0; return 1; }
static unsigned long h20(const uint8_t*k){ unsigned long h=1469598103934665603UL; for(int i=0;i<20;i++){h^=k[i];h*=1099511628211UL;} return h; }
static void set_put(const uint8_t*k){
  unsigned long i=h20(k)&HMASK;
  while(!is_zero(SET[i])){ if(!memcmp(SET[i],k,20)) return; i=(i+1)&HMASK; }
  memcpy(SET[i],k,20);
}
static int set_has(const uint8_t*k){
  unsigned long i=h20(k)&HMASK;
  while(!is_zero(SET[i])){ if(!memcmp(SET[i],k,20)) return 1; i=(i+1)&HMASK; }
  return 0;
}
static int fromhex(const char*s,uint8_t*o){ for(int i=0;i<20;i++){int a=s[2*i],b=s[2*i+1];
  a=a<='9'?a-'0':(a|32)-'a'+10; b=b<='9'?b-'0':(b|32)-'a'+10; if(a<0||a>15||b<0||b>15)return 0; o[i]=(a<<4)|b;} return 1; }

int main(int argc,char**argv){
  if(argc<6){ fprintf(stderr,"usage: genMinusBase baseIdx genIdx genBin outIdx outBin\n"); return 1; }
  const char *baseIdx=argv[1],*genIdx=argv[2],*genBin=argv[3],*outIdx=argv[4],*outBin=argv[5];
  SET=calloc(HSIZE,20); if(!SET){ fprintf(stderr,"calloc %luGB failed\n",(HSIZE*20)>>30); return 2; }

  /* load base shas */
  FILE*bf=fopen(baseIdx,"r"); if(!bf){ perror(baseIdx); return 2; }
  char line[256]; long nbase=0; uint8_t sha[20];
  while(fgets(line,sizeof line,bf)){
    char*s=strrchr(line,';'); if(!s) continue; s++;
    while(*s==' ')s++; if(strlen(s)<40) continue;
    if(fromhex(s,sha)){ set_put(sha); nbase++; }
  }
  fclose(bf);
  fprintf(stderr,"  loaded %ld base shas\n",nbase);

  FILE*gi=fopen(genIdx,"r"); if(!gi){ perror(genIdx); return 2; }
  FILE*gb=fopen(genBin,"rb"); if(!gb){ perror(genBin); return 2; }
  FILE*oi=fopen(outIdx,"w");  if(!oi){ perror(outIdx); return 2; }
  FILE*ob=fopen(outBin,"wb"); if(!ob){ perror(outBin); return 2; }
  long long noff=0; long kept=0,dropped=0,bad=0;
  static char buf[1<<26];
  while(fgets(line,sizeof line,gi)){
    long long id,off; long len; char shahex[64];
    if(sscanf(line,"%lld;%lld;%ld;%63s",&id,&off,&len,shahex)!=4){ bad++; continue; }
    if(!fromhex(shahex,sha)){ bad++; continue; }
    if(set_has(sha)){ dropped++; continue; }
    if(len>(long)sizeof buf){ fprintf(stderr,"OVERSIZE len=%ld id=%lld skip\n",len,id); bad++; continue; }
    if(fseeko(gb,off,SEEK_SET)!=0){ perror("fseeko"); return 3; }
    if(fread(buf,1,len,gb)!=(size_t)len){ fprintf(stderr,"short read id=%lld off=%lld len=%ld\n",id,off,len); return 3; }
    fwrite(buf,1,len,ob);
    fprintf(oi,"%ld;%lld;%ld;%s\n",kept,noff,len,shahex);
    noff+=len; kept++;
  }
  fclose(ob);fclose(oi);fclose(gb);fclose(gi);
  fprintf(stderr,"  [%s] base=%ld kept=%ld dropped=%ld bad=%ld newbytes=%lld\n",genIdx,nbase,kept,dropped,bad,noff);
  return 0;
}
