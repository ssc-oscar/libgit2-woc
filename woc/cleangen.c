/* cleangen.c -- da5-side, BASE-AWARE re-conversion of one layered gen shard.
 *
 * convgen runs on da8 (no base access) so it can't dedup vs the base; ~1% of gen
 * objects are base-dups (watermark skew: grabbed vs an older base, base since advanced).
 * This runs on da5 (base reachable) and, per (type,sec):
 *   - drops gen objects already in BASE (exact /fast/All.sha1 lookup) + any intra-gen dup
 *   - renumbers survivors contiguously (0..M-1)  -> no numbering gaps
 *   - rewrites the CLEAN gen .bin/.idx (LZF slices copied verbatim, no recompress)
 *   - writes MEMBERSHIP  sha1Dir/sha1.<type>_<sec>.GEN.tch : sha -> pack("w", base_count+id)
 *   - writes OFFSET      sha1oDir/sha1.<type>_<sec>.tch (overwrite gen keys): sha -> pack("w w", base_size+off, len)
 * Base is read-only. Membership goes to a SEPARATE .GEN.tch (NOT the live /fast/All.sha1
 * that grab hasObj reads) -> no concurrency risk. Clean .bin/.idx atomically renamed in.
 *
 *   cleangen <type> <sec> <baseBinDir> <genDir> <sha1Dir> <sha1oDir>
 * build: cc -O2 -o cleangen cleangen.c -ltokyocabinet
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <tchdb.h>

/* Perl pack("w",v): base-128, MSB first, 0x80 on all but the last byte */
static int berenc(unsigned long v, unsigned char*o){
  unsigned char t[10]; int n=0;
  do { t[n++]=v&0x7f; v>>=7; } while(v);
  for(int i=n-1;i>=0;i--) *o++ = t[i] | (i?0x80:0);
  return n;
}
static int hexb(const char*s,unsigned char*o){
  for(int i=0;i<20;i++){int a=s[2*i],b=s[2*i+1];a=a<='9'?a-'0':(a|32)-'a'+10;b=b<='9'?b-'0':(b|32)-'a'+10;if(a<0||a>15||b<0||b>15)return 0;o[i]=(a<<4)|b;}return 1;
}
/* intra-gen seen-set (open addressing, 20-byte keys) */
static unsigned char *SET; static size_t MASK;
static int seen_add(const unsigned char*k){
  size_t i=(*(uint64_t*)k)&MASK;
  for(;;){ unsigned char*s=SET+i*20; int z=1; for(int j=0;j<20;j++) if(s[j]){z=0;break;}
    if(z){ memcpy(s,k,20); return 1; }
    if(!memcmp(s,k,20)) return 0; i=(i+1)&MASK; }
}
int main(int argc,char**argv){
  if(argc<7){fprintf(stderr,"usage: cleangen <type> <sec> <baseBinDir> <genDir> <sha1Dir> <sha1oDir>\n");return 2;}
  const char*TY=argv[1]; int sec=atoi(argv[2]);
  const char*BB=argv[3],*GD=argv[4],*S1=argv[5],*S1O=argv[6];
  char p[800]; struct stat st;
  /* base membership (read-only) + base_count + base_size */
  snprintf(p,sizeof p,"%s/sha1.%s_%d.tch",S1,TY,sec);
  TCHDB*base=tchdbnew(); if(!tchdbopen(base,p,HDBOREADER|HDBONOLCK)){fprintf(stderr,"open base %s: %s\n",p,tchdberrmsg(tchdbecode(base)));return 1;}
  long long base_count=tchdbrnum(base);
  snprintf(p,sizeof p,"%s/%s_%d.bin",BB,TY,sec); if(stat(p,&st)){fprintf(stderr,"stat base bin %s\n",p);return 1;} long long base_size=st.st_size;
  /* gen in */
  snprintf(p,sizeof p,"%s/%s_%d.idx",GD,TY,sec); FILE*gi=fopen(p,"r"); if(!gi){fprintf(stderr,"no gen idx %s\n",p);return 1;}
  char gbinp[800]; snprintf(gbinp,sizeof gbinp,"%s/%s_%d.bin",GD,TY,sec); int gb=open(gbinp,O_RDONLY); if(gb<0){fprintf(stderr,"no gen bin\n");return 1;}
  /* clean out (temp) */
  char nbinp[800],nidxp[800]; snprintf(nbinp,sizeof nbinp,"%s/%s_%d.bin.new",GD,TY,sec); snprintf(nidxp,sizeof nidxp,"%s/%s_%d.idx.new",GD,TY,sec);
  FILE*cb=fopen(nbinp,"w"),*ci=fopen(nidxp,"w"); if(!cb||!ci){fprintf(stderr,"cant open clean out\n");return 1;}
  /* membership out (.GEN.tch) */
  snprintf(p,sizeof p,"%s/sha1.%s_%d.GEN.tch",S1,TY,sec); TCHDB*mem=tchdbnew(); tchdbtune(mem,1000003,-1,-1,HDBTLARGE);
  if(!tchdbopen(mem,p,HDBOWRITER|HDBOCREAT|HDBOTRUNC)){fprintf(stderr,"open mem %s\n",p);return 1;}
  /* offset map (overwrite gen keys) */
  snprintf(p,sizeof p,"%s/sha1.%s_%d.tch",S1O,TY,sec); TCHDB*off=tchdbnew(); tchdbtune(off,1000003,-1,-1,HDBTLARGE);
  if(!tchdbopen(off,p,HDBOWRITER|HDBOCREAT)){fprintf(stderr,"open off %s\n",p);return 1;}
  /* intra-gen seen-set: size from gen idx bytes (~45 B/line), >=2x headroom */
  snprintf(p,sizeof p,"%s/%s_%d.idx",GD,TY,sec); long long idxsz=(stat(p,&st)==0)?st.st_size:0; long long est=idxsz/40+1;
  size_t bits=20; while(((size_t)1<<bits) < (size_t)(est*2)) bits++;
  MASK=((size_t)1<<bits)-1; SET=calloc((size_t)1<<bits,20); if(!SET){fprintf(stderr,"set alloc 2^%zu\n",bits);return 1;}
  char *line=NULL; size_t cap=0; unsigned char sha[20]; unsigned char val[24];
  long long newid=0,newoff=0,kept=0,base_dup=0,gen_dup=0; size_t bcap=1<<20; unsigned char*buf=malloc(bcap);
  while(getline(&line,&cap,gi)>0){
    char*q=line; strtoll(q,&q,10); if(*q!=';')continue; q++;            /* skip id */
    long long o=strtoll(q,&q,10); if(*q!=';')continue; q++;             /* off */
    long len=strtol(q,&q,10); if(*q!=';')continue; q++;                 /* len */
    char*s=q; if(strlen(s)<40||!hexb(s,sha))continue;
    int sz; void*bv=tchdbget(base,sha,20,&sz); if(bv){free(bv);base_dup++;continue;}  /* in base -> drop */
    if(!seen_add(sha)){gen_dup++;continue;}                             /* intra-gen dup */
    if((size_t)len>bcap){bcap=len;buf=realloc(buf,bcap);}
    if(pread(gb,buf,len,o)!=len){fprintf(stderr,"short read off %lld len %ld\n",o,len);continue;}
    fwrite(buf,1,len,cb);
    fprintf(ci,"%lld;%lld;%ld;%.40s\n",newid,newoff,len,s);
    int vl=berenc((unsigned long)(base_count+newid),val); tchdbput(mem,sha,20,val,vl);     /* membership */
    vl=berenc((unsigned long)(base_size+newoff),val); vl+=berenc((unsigned long)len,val+vl); tchdbput(off,sha,20,val,vl); /* offset */
    newid++; newoff+=len; kept++;
  }
  free(line); free(buf); free(SET);
  fclose(gi); close(gb); fclose(cb); fclose(ci);
  tchdbclose(base); tchdbdel(base); tchdbclose(mem); tchdbdel(mem); tchdbclose(off); tchdbdel(off);
  /* atomic replace gen .bin/.idx */
  char obin[800],oidx[800]; snprintf(obin,sizeof obin,"%s/%s_%d.bin",GD,TY,sec); snprintf(oidx,sizeof oidx,"%s/%s_%d.idx",GD,TY,sec);
  if(rename(nbinp,obin)||rename(nidxp,oidx)){fprintf(stderr,"rename failed\n");return 1;}
  fprintf(stderr,"%s sec %d: kept=%lld base_dup=%lld gen_dup=%lld (base_count=%lld base_size=%lld)\n",TY,sec,kept,base_dup,gen_dup,base_count,base_size);
  return 0;
}
