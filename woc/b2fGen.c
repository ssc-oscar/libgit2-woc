/* b2fGen.c -- streaming LAYERED-store tree iterator -> deduped blob->filename (b2f).
 *
 * (Layered-store counterpart of the grab-time treeb2f.c.) Iterates EVERY tree
 * object in the layered store for input tree secs [A..B] and emits each file
 * entry's (blob, terminal-name) exactly once, routed to 128 gzipped output
 * shards by blob_sha[0]%128:  <outdir>/b2f_<outsec>.gz  (lines "blobhex;name").
 * This is the "skinny" b2f. No tree-walk / recursion: a tree object lists its
 * files directly with basenames, so iterating all trees covers every (blob,name).
 * Offset maps are NOT needed -- we stream each layer's <type>_<sec>.{idx,bin}
 * directly (idx is in id order == bin order, so reads are sequential).
 *
 * Layers per input sec: base  <baseBinDir>/tree_<sec>.{idx,bin}
 *                       gens  $LAYERED/tree_gen<N>/tree_<sec>.{idx,bin}
 *
 * Dedup: open-addressing set of a 128-bit hash of (blob20 || name); [capbits]
 * sizes it (2^capbits slots * 16 bytes). 128-bit => collisions negligible even
 * at tens of billions of pairs. Dedup spans the processed run only.
 *
 * WHOLE-STORE run model: one invocation over secs 0..127 would need a dedup table
 * holding ALL distinct (blob,name) of the store (tens of billions) -- too big for
 * RAM. Instead run per input sec (or small batches) into a per-batch outdir, then
 * REDUCE per output sec across batches:
 *     for o in $(seq 0 127); do
 *       zcat BATCH_DIRS/b2f_$o.gz | LC_ALL=C sort -u | gzip > final/b2f_$o.gz
 *     done
 * (Within one input sec, capbits ~31-32 (32-64 GB) covers its distinct pairs.)
 *
 *   b2fGen <baseBinDir> <outDir> <firstsec> <lastsec> [capbits=31]
 *   env LAYERED=<dir with tree_gen1...>   (optional; base-only if unset)
 * build: cc -O2 -o b2fGen b2fGen.c /usr/lib64/liblzf.so.1
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
extern unsigned int lzf_decompress(const void*, unsigned int, void*, unsigned int);

#define NSEC 128
static const char *BASEBIN, *OUTDIR, *LAYERED;

/* ---------- Compress::LZF decompress (verified byte-exact vs Perl) ---------- */
static long clzf(const uint8_t*in, size_t n, uint8_t*out, size_t outcap){
  if(n==0) return 0;
  if(in[0]==0){ if(n-1>outcap) return -1; memcpy(out,in+1,n-1); return n-1; }
  unsigned long us=0; size_t p=0; unsigned c=in[p++];
  if(c<0x80) us=c;
  else if((c&0xe0)==0xc0){ us=(c&0x1f)<<6; us|=in[p++]&0x3f; }
  else if((c&0xf0)==0xe0){ us=(c&0x0f)<<12; us|=(in[p++]&0x3f)<<6; us|=in[p++]&0x3f; }
  else if((c&0xf8)==0xf0){ us=(unsigned long)(c&7)<<18; us|=(unsigned long)(in[p++]&0x3f)<<12; us|=(in[p++]&0x3f)<<6; us|=in[p++]&0x3f; }
  else if((c&0xfc)==0xf8){ us=(unsigned long)(c&3)<<24; us|=(unsigned long)(in[p++]&0x3f)<<18; us|=(unsigned long)(in[p++]&0x3f)<<12; us|=(in[p++]&0x3f)<<6; us|=in[p++]&0x3f; }
  else { us=(unsigned long)(c&1)<<30; us|=(unsigned long)(in[p++]&0x3f)<<24; us|=(unsigned long)(in[p++]&0x3f)<<18; us|=(unsigned long)(in[p++]&0x3f)<<12; us|=(in[p++]&0x3f)<<6; us|=in[p++]&0x3f; }
  if(us>outcap) return -1;
  return lzf_decompress(in+p, n-p, out, us)==us ? (long)us : -1;
}

/* ---------- 128-bit dedup set (open addressing) ---------- */
static uint64_t *Da, *Db; static size_t DMASK; static long long DCOUNT=0;
static void dedup_init(int capbits){
  size_t n=(size_t)1<<capbits; DMASK=n-1;
  Da=calloc(n,sizeof(uint64_t)); Db=calloc(n,sizeof(uint64_t));
  if(!Da||!Db){ fprintf(stderr,"dedup alloc failed (capbits=%d, ~%zu GB)\n",capbits,(n*16)>>30); exit(1); }
  fprintf(stderr,"dedup table: 2^%d slots, ~%zu GB\n",capbits,(n*16)>>30);
}
static void hash128(const uint8_t*sha,const char*nm,int nl,uint64_t*ha,uint64_t*hb){
  uint64_t a=1469598103934665603ULL;          /* FNV-1a 64 */
  for(int i=0;i<20;i++){ a^=sha[i]; a*=1099511628211ULL; }
  for(int i=0;i<nl;i++){ a^=(uint8_t)nm[i]; a*=1099511628211ULL; }
  uint64_t b=5381;                             /* djb2 variant */
  for(int i=0;i<20;i++) b=((b<<5)+b)^sha[i];
  for(int i=0;i<nl;i++) b=((b<<5)+b)^(uint8_t)nm[i];
  b^=a>>32; if((a|b)==0) a=1;                  /* avoid all-zero (empty marker) */
  *ha=a; *hb=b;
}
static int dedup_add(uint64_t a,uint64_t b){   /* 1 = newly inserted, 0 = present */
  size_t i=a&DMASK;
  while(Da[i]|Db[i]){ if(Da[i]==a&&Db[i]==b) return 0; i=(i+1)&DMASK; }
  Da[i]=a; Db[i]=b; DCOUNT++; return 1;
}

/* ---------- 128 gzip output writers ---------- */
static FILE *OUT[NSEC];
static void open_outputs(void){
  char cmd[700];
  for(int s=0;s<NSEC;s++){
    snprintf(cmd,sizeof cmd,"gzip > '%s/b2f_%d.gz'",OUTDIR,s);
    OUT[s]=popen(cmd,"w");
    if(!OUT[s]){ fprintf(stderr,"cannot open output shard %d\n",s); exit(1); }
  }
}
static void close_outputs(void){ for(int s=0;s<NSEC;s++) if(OUT[s]) pclose(OUT[s]); }

static const char HX[]="0123456789abcdef";
static void emit(const uint8_t*sha,const char*nm){
  FILE*f=OUT[sha[0]%NSEC];
  char hx[41]; for(int i=0;i<20;i++){hx[2*i]=HX[sha[i]>>4];hx[2*i+1]=HX[sha[i]&15];} hx[40]=0;
  fputs(hx,f); fputc(';',f); fputs(nm,f); fputc('\n',f);
}
static void sanit(char*s){ for(;*s;s++){ if(*s=='\r')*s='_'; else if(*s=='\n')*s='_'; else if(*s==';')*s=':'; } }

/* parse one decompressed tree: "<mode> <name>\0<20-byte sha>"* ; emit blob entries */
static void parse_tree(const uint8_t*t,long n){
  long p=0;
  while(p<n){
    long ms=p; while(p<n && t[p]!=' ') p++; if(p>=n) break;
    char mb[16]; int ml=p-ms; if(ml>15) ml=15; memcpy(mb,t+ms,ml); mb[ml]=0;
    long mode=strtol(mb,0,8); p++;
    long ns=p; while(p<n && t[p]!=0) p++; if(p>=n) break;
    char nm[4096]; int nl=p-ns; if(nl>4095) nl=4095; memcpy(nm,t+ns,nl); nm[nl]=0; sanit(nm); p++;
    if(p+20>n) break; const uint8_t*sha=t+p; p+=20;
    long type=mode & 0170000;            /* 040000 dir, 0100000 file, 0120000 symlink, 0160000 gitlink */
    if(type==0100000 || type==0120000){  /* a blob: regular file or symlink */
      uint64_t a,b; hash128(sha,nm,(int)strlen(nm),&a,&b);
      if(dedup_add(a,b)) emit(sha,nm);
    }
  }
}

static long long stream_layer(const char*idxpath,const char*binpath){
  FILE*ix=fopen(idxpath,"r"); if(!ix) return 0;
  int bf=open(binpath,O_RDONLY); if(bf<0){ fclose(ix); return 0; }
  posix_fadvise(bf,0,0,POSIX_FADV_SEQUENTIAL);
  static uint8_t cbuf[1<<26], obuf[1<<26];
  char line[256]; long long trees=0;
  while(fgets(line,sizeof line,ix)){
    char*p=line; while(*p&&*p!=';')p++; if(!*p)continue; p++;        /* skip id */
    long long off=strtoll(p,&p,10); if(*p!=';')continue; p++;
    long len=strtol(p,&p,10);
    if(len<=0||(size_t)len>sizeof cbuf) continue;
    if(pread(bf,cbuf,len,off)!=len) continue;
    long un=clzf(cbuf,len,obuf,sizeof obuf); if(un<0) continue;
    parse_tree(obuf,un); trees++;
  }
  close(bf); fclose(ix);
  fprintf(stderr,"  %s: %lld trees\n",idxpath,trees);
  return trees;
}

int main(int argc,char**argv){
  if(argc<5){ fprintf(stderr,"usage: b2fGen <baseBinDir> <outDir> <firstsec> <lastsec> [capbits=31]\n  env LAYERED=<gen dir>\n"); return 2; }
  BASEBIN=argv[1]; OUTDIR=argv[2];
  int A=atoi(argv[3]), B=atoi(argv[4]);
  int capbits=argc>5?atoi(argv[5]):31;
  LAYERED=getenv("LAYERED");
  dedup_init(capbits);
  open_outputs();
  for(int sec=A; sec<=B; sec++){
    char ip[700], bp[700];
    snprintf(ip,sizeof ip,"%s/tree_%d.idx",BASEBIN,sec);
    snprintf(bp,sizeof bp,"%s/tree_%d.bin",BASEBIN,sec);
    stream_layer(ip,bp);
    if(LAYERED){
      for(int g=1; g<16; g++){
        struct stat st;
        snprintf(ip,sizeof ip,"%s/tree_gen%d/tree_%d.idx",LAYERED,g,sec);
        if(stat(ip,&st)!=0) break;
        snprintf(bp,sizeof bp,"%s/tree_gen%d/tree_%d.bin",LAYERED,g,sec);
        stream_layer(ip,bp);
      }
    }
    fprintf(stderr,"sec %d done; cumulative distinct b2f=%lld\n",sec,DCOUNT);
  }
  close_outputs();
  fprintf(stderr,"DONE secs %d..%d: distinct (blob;name) pairs=%lld\n",A,B,DCOUNT);
  return 0;
}
