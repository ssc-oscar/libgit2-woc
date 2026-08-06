/* getObjGen <type> <PREC> <PREO> <BASEBIN>   (env LAYERED=gens, ENC=b64|raw, RLIMIT auto)
 *
 * Gen-aware content reader -- the missing companion to showCnt.perl (which is BASE-ONLY and silently
 * misses gen-layer objects). Reads `sha[;rest]` per line from STDIN (rest ignored), resolves the object
 * content from base UNION gen, exactly like cmputeDiffGenFB.getObj:
 *     primary  content .tch : <PREC>/<type>_<sec>.tch           (commit/tag/tkns live here)
 *     fallback base offset  : <PREO>/sha1.<type>_<sec>.tch -> <BASEBIN>/<type>_<sec>.bin  (tree/blob)
 *     fallback gen          : <LAYERED>/<type>_gen1/<type>_<sec>.sidx -> .bin            (RT/backfill)
 * <sec> = first_sha_byte % 128. Machinery (clzf/getContent/readObj/lookup/gen_lookup) lifted verbatim
 * from cmputeDiffGenFB.c so results are byte-identical.
 *
 * Output per input sha (default ENC=b64, one SAFE line even for binary/multiline content):
 *     <sha>;<base64(content)>
 * ENC=raw  -> writes the raw object bytes to stdout with NO framing (use for a single object, cat-style).
 * Missing (not in base or gen) -> `no <type> <sha>` on stderr, nothing on stdout (like showCnt).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <errno.h>
#include <tchdb.h>
extern unsigned int lzf_decompress(const void*, unsigned int, void*, unsigned int);

#define NSEC 128
#define MAXSEG 16
static const char *TYPE, *PREC, *PREO, *BASEBIN, *LAYERED;

/* ---------- Compress::LZF decompress (verbatim from cmputeDiffGenFB.c) ---------- */
static long clzf(const uint8_t*in,size_t n,uint8_t*out,size_t outcap){
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
  return lzf_decompress(in+p,n-p,out,us)==us ? (long)us : -1;
}

/* ---------- primary: content .tch (single type) ---------- */
static TCHDB *CTCH[NSEC];
static long getContent(int sec,const uint8_t*sha20,uint8_t*out,size_t cap){
  if(!CTCH[sec]){ char p[600]; snprintf(p,sizeof p,"%s/%s_%d.tch",PREC,TYPE,sec);
    TCHDB*h=tchdbnew(); if(!tchdbopen(h,p,HDBOREADER|HDBONOLCK)){ tchdbdel(h); CTCH[sec]=(TCHDB*)-1; } else CTCH[sec]=h; }
  TCHDB*h=CTCH[sec]; if(h==(TCHDB*)-1) return -1;
  int sz; void*v=tchdbget(h,sha20,20,&sz); if(!v) return -1;
  long r=clzf(v,sz,out,cap); free(v); return r;
}
/* ---------- fallback: offset .tch + segment bins (base + gens) ---------- */
typedef struct { int fd; long long base,size; } Seg;
typedef struct { Seg s[MAXSEG]; int n,built; } SecSegs;
static SecSegs SEG[NSEC];
static void add_seg(SecSegs*S,const char*path,long long cum){ struct stat st; if(stat(path,&st)!=0)return;
  int fd=open(path,O_RDONLY); if(fd<0)return; S->s[S->n].fd=fd; S->s[S->n].base=cum; S->s[S->n].size=st.st_size; S->n++; }
static void build_segs(int sec){ SecSegs*S=&SEG[sec]; if(S->built)return; S->built=1; S->n=0;
  char p[700]; long long cum=0; snprintf(p,sizeof p,"%s/%s_%d.bin",BASEBIN,TYPE,sec);
  long pre=S->n; add_seg(S,p,cum); if(S->n>pre)cum+=S->s[S->n-1].size;
  if(LAYERED) for(int g=1;g<MAXSEG;g++){ snprintf(p,sizeof p,"%s/%s_gen%d/%s_%d.bin",LAYERED,TYPE,g,TYPE,sec);
    struct stat st; if(stat(p,&st)!=0)break; pre=S->n; add_seg(S,p,cum); if(S->n>pre)cum+=S->s[S->n-1].size; } }
static long readObj(int sec,long long goff,int len,uint8_t*cbuf,size_t cap){ build_segs(sec); SecSegs*S=&SEG[sec];
  for(int i=0;i<S->n;i++) if(goff>=S->s[i].base && goff<S->s[i].base+S->s[i].size){
    if((size_t)len>cap)return -1; if(pread(S->s[i].fd,cbuf,len,goff-S->s[i].base)!=len)return -1; return len; } return -1; }
static TCHDB *TCH[NSEC];
static void open_tch(int sec){ if(TCH[sec])return; char p[600]; snprintf(p,sizeof p,"%s/sha1.%s_%d.tch",PREO,TYPE,sec);
  TCHDB*h=tchdbnew(); if(!tchdbopen(h,p,HDBOREADER|HDBONOLCK)){ tchdbdel(h); TCH[sec]=(TCHDB*)-1; return; } TCH[sec]=h; }
static const uint8_t* berdec(const uint8_t*p,const uint8_t*e,unsigned long*v){ unsigned long x=0; while(p<e){ x=(x<<7)|(*p&0x7f); if(!(*p++&0x80))break; } *v=x; return p; }
static int lookup(int sec,const uint8_t*sha20,long long*goff,int*len){ open_tch(sec); TCHDB*h=TCH[sec]; if(h==(TCHDB*)-1||!h)return 0;
  int sz; void*v=tchdbget(h,sha20,20,&sz); if(!v)return 0; unsigned long o,l; const uint8_t*p=v,*e=(uint8_t*)v+sz; p=berdec(p,e,&o); berdec(p,e,&l); *goff=o; *len=(int)l; free(v); return 1; }
/* ---------- gen sidx (per layer: gen1,gen2,... == seg index 1,2,... after base=seg0) ---------- */
#define MAXGEN 8
static int GSFD[MAXGEN][NSEC]; static long GSN[MAXGEN][NSEC];
static int gen_lookup_g(int g,int sec,const uint8_t*sha20,long long*goff,int*len){ if(!LAYERED)return 0;
  if(GSFD[g][sec]==0){ char p[600]; snprintf(p,sizeof p,"%s/%s_gen%d/%s_%d.sidx",LAYERED,TYPE,g,TYPE,sec);
    int fd=open(p,O_RDONLY); struct stat st;
    if(fd<0){ if(errno==EMFILE||errno==ENFILE){ fprintf(stderr,"FATAL: fd limit -- raise RLIMIT_NOFILE\n"); exit(3);} GSFD[g][sec]=-1; return 0; }
    if(fstat(fd,&st)!=0){ close(fd); GSFD[g][sec]=-1; return 0; } GSFD[g][sec]=fd; GSN[g][sec]=st.st_size/32; }
  if(GSFD[g][sec]==-1)return 0; int fd=GSFD[g][sec]; long lo=0,hi=GSN[g][sec]-1; uint8_t rec[32];
  while(lo<=hi){ long mid=(lo+hi)/2; if(pread(fd,rec,32,(off_t)mid*32)!=32)return 0; int c=memcmp(rec,sha20,20);
    if(c==0){ unsigned long long o; unsigned int l; memcpy(&o,rec+20,8); memcpy(&l,rec+28,4);
      build_segs(sec);                                     /* gen g == seg[g]; goff = seg[g].base + local */
      long long base=(g<SEG[sec].n)?SEG[sec].s[g].base:((SEG[sec].n>0)?SEG[sec].s[0].size:0);
      *goff=(long long)o+base; *len=(int)l; return 1; }
    if(c<0)lo=mid+1; else hi=mid-1; } return 0; }

static int fromhex(const char*s,uint8_t*o){ for(int i=0;i<20;i++){int a=s[2*i],b=s[2*i+1]; a=a<='9'?a-'0':(a|32)-'a'+10; b=b<='9'?b-'0':(b|32)-'a'+10; if(a<0||a>15||b<0||b>15)return 0; o[i]=(a<<4)|b;} return 1; }
static void tohex(const uint8_t*b,char*o){ static const char*h="0123456789abcdef"; for(int i=0;i<20;i++){o[2*i]=h[b[i]>>4];o[2*i+1]=h[b[i]&15];} o[40]=0; }

/* SCAN mode: iterate the gen sidx for a sec, gen-decode every record, emit the shas that fail.
 * Skips the base content/offset lookups (all gen recs miss those) -> just readObj+clzf per record.
 * Output: `<decodefail|readfail>\t<sec>\t<sha>`; stderr a one-line per-sec summary. */
static void scan_gen(int sec){
  if(!LAYERED) return;
  char p[600]; snprintf(p,sizeof p,"%s/%s_gen1/%s_%d.sidx",LAYERED,TYPE,TYPE,sec);
  int fd=open(p,O_RDONLY); if(fd<0) return;
  struct stat st; if(fstat(fd,&st)!=0){ close(fd); return; }
  long n=st.st_size/32;
  build_segs(sec); long long bs=(SEG[sec].n>0)?SEG[sec].s[0].size:0;
  static uint8_t cbuf[1<<26], obuf[1<<26]; uint8_t rec[32]; char hx[41];
  long ndec=0,nrd=0;
  for(long i=0;i<n;i++){
    if(pread(fd,rec,32,(off_t)i*32)!=32) continue;
    unsigned long long o; unsigned int l; memcpy(&o,rec+20,8); memcpy(&l,rec+28,4);
    long rr=readObj(sec,(long long)o+bs,(int)l,cbuf,sizeof cbuf);
    tohex(rec,hx);
    if(rr<0){ printf("readfail\t%d\t%s\n",sec,hx); nrd++; continue; }
    if(clzf(cbuf,rr,obuf,sizeof obuf)<0){ printf("decodefail\t%d\t%s\n",sec,hx); ndec++; }
  }
  close(fd);
  fprintf(stderr,"[scan] %s sec %d: %ld recs, %ld decodefail, %ld readfail\n",TYPE,sec,n,ndec,nrd);
}

/* unified read: content .tch -> base offset -> gen sidx.
 * Distinct negative codes so a caller can tell ABSENCE from a located-but-undecodable record:
 *   -1 = not found (not in base content, base offset, or gen sidx)
 *   -2 = FOUND (offset resolved) but readObj failed (bad offset/segment)
 *   -3 = FOUND + read OK but LZF decode failed (rare corrupt gen record; ~7e-4 of gen commits)   */
static long getObj(const char*sha40,uint8_t*out,size_t cap){
  uint8_t sha[20]; if(!fromhex(sha40,sha)) return -1; int sec=sha[0]%NSEC;
  long r=getContent(sec,sha,out,cap); if(r>=0) return r;   /* base content tch (its own clzf; miss->fall through) */
  static uint8_t cbuf[1<<26]; long long goff; int len, seen=0;
  if(lookup(sec,sha,&goff,&len)){ seen=1; long rr=readObj(sec,goff,len,cbuf,sizeof cbuf);   /* base offset */
    if(rr>=0){ long dr=clzf(cbuf,rr,out,cap); if(dr>=0) return dr; } }                        /* decodefail -> fall through */
  build_segs(sec);                                          /* DECODEFAIL-FALLTHROUGH: try gen1..N, skip undecodable */
  for(int g=1; g<MAXGEN && g<SEG[sec].n; g++){              /*   -> a clean later gen (or V2608 fix layer) overrides   */
    if(!gen_lookup_g(g,sec,sha,&goff,&len)) continue; seen=1;   /*     a corrupt earlier gen record.                   */
    long rr=readObj(sec,goff,len,cbuf,sizeof cbuf); if(rr<0) continue;
    long dr=clzf(cbuf,rr,out,cap); if(dr>=0) return dr;
  }
  return seen ? -3 : -1;    /* -3 = found but no layer decoded; -1 = not found in any layer; -2 folded into -3 */
}

static const char B64[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static void b64out(const uint8_t*d,long n){ long i; for(i=0;i+2<n;i+=3){ unsigned v=(d[i]<<16)|(d[i+1]<<8)|d[i+2];
    putchar(B64[v>>18&63]);putchar(B64[v>>12&63]);putchar(B64[v>>6&63]);putchar(B64[v&63]); }
  int r=n-i; if(r==1){ unsigned v=d[i]<<16; putchar(B64[v>>18&63]);putchar(B64[v>>12&63]);putchar('=');putchar('='); }
  else if(r==2){ unsigned v=(d[i]<<16)|(d[i+1]<<8); putchar(B64[v>>18&63]);putchar(B64[v>>12&63]);putchar(B64[v>>6&63]);putchar('='); } }

int main(int argc,char**argv){
  if(argc<5){ fprintf(stderr,"usage: %s <type> <PREC> <PREO> <BASEBIN>  (env LAYERED, ENC=b64|raw) < shas\n",argv[0]); return 1; }
  struct rlimit rl; if(getrlimit(RLIMIT_NOFILE,&rl)==0){ rl.rlim_cur=rl.rlim_max; setrlimit(RLIMIT_NOFILE,&rl); }
  TYPE=argv[1]; PREC=argv[2]; PREO=argv[3]; BASEBIN=argv[4]; LAYERED=getenv("LAYERED");
  const char*enc=getenv("ENC"); int raw = enc && !strcmp(enc,"raw");
  if(getenv("SCAN")){                          /* SCAN mode: iterate gen sidx, emit decode/read failures */
    const char*se=getenv("SEC");
    if(se) scan_gen(atoi(se)); else for(int s=0;s<NSEC;s++) scan_gen(s);
    return 0;
  }
  static uint8_t out[1<<26]; char line[8192];
  while(fgets(line,sizeof line,stdin)){
    char*nl=strpbrk(line,"\r\n;"); if(nl)*nl=0;                 /* sha[;rest] -> sha */
    if(strlen(line)<40) continue;
    long n=getObj(line,out,sizeof out);
    if(n==-1){ fprintf(stderr,"no %s %s\n",TYPE,line); continue; }              /* absent */
    if(n==-2){ fprintf(stderr,"readfail %s %s (bad offset/segment)\n",TYPE,line); continue; }
    if(n==-3){ fprintf(stderr,"decodefail %s %s (found in gen; LZF decode failed -- corrupt record)\n",TYPE,line); continue; }
    if(raw){ fwrite(out,1,n,stdout); }
    else { fputs(line,stdout); putchar(';'); b64out(out,n); putchar('\n'); }
  }
  return 0;
}
