/* gatherWS.c -- gather the tree CLOSURE (working set) into a compact, gen-shaped
 * SSD store for the fast cmputeDiffGen pass.
 *
 * Consumes isaac's closure output (bare tree-sha per line, byte-sharded by sha[0]%128,
 * `coord/isaac/closure-status.md`). For each closure tree-sha it resolves (goff,len) via
 * the SAME layered lookup as cmputeDiffGen (gen .sidx FIRST, then base offset .tch), reads
 * the objects in OFFSET ORDER (one sequential HDD sweep, NOT 43-IOPS random), and writes a
 * gen-shaped store:
 *     <ws>/tree_gen1/tree_<sec>.bin    concatenated compressed tree bytes
 *     <ws>/tree_gen1/tree_<sec>.sidx   sha20 + off(u64le) + len(u32le), 32B, sorted by sha
 * cmputeDiffGen then runs with LAYERED=<ws> (SSD): closure trees resolve via the WS sidx
 * (SSD, fast); the small deep residual (not in the closure) misses the WS sidx and falls
 * through to the base .tch on HDD -- exactly cmputeDiffGen's existing sidx-first-then-base path.
 *
 * build: cc -O2 -o gatherWS gatherWS.c -ltokyocabinet
 * env: PREO (base offset tch dir, default /fast/All.sha1o), BASEBIN (base bins, default
 *      /data/All.blobs), LAYERED (source gen dir, e.g. /fast/All.blobsGen).
 * usage: LAYERED=<gen> gatherWS <closure-shalist> <ws-out-dir> [onlysec]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <tcutil.h>
#include <tchdb.h>

#define NSEC 128
#define MAXSEG 16
static const char *PREO, *BASEBIN, *LAYERED;
static const char *TYPES[2]={"commit","tree"};

/* ---- store-access: verbatim from cmputeDiffGen.c (segments, readObj, tch, sidx, lookup) ---- */
typedef struct { int fd; long long base, size; } Seg;
typedef struct { Seg s[MAXSEG]; int n; int built; } SecSegs;
static SecSegs SEG[2][NSEC];
static void add_seg(SecSegs*S,const char*path,long long cum){ struct stat st; if(stat(path,&st)!=0)return; int fd=open(path,O_RDONLY); if(fd<0)return; S->s[S->n].fd=fd; S->s[S->n].base=cum; S->s[S->n].size=st.st_size; S->n++; }
static void build_segs(int t,int sec){ SecSegs*S=&SEG[t][sec]; if(S->built)return; S->built=1; S->n=0; char p[700]; long long cum=0;
  snprintf(p,sizeof p,"%s/%s_%d.bin",BASEBIN,TYPES[t],sec); long pre=S->n; add_seg(S,p,cum); if(S->n>pre)cum+=S->s[S->n-1].size;
  if(LAYERED){ for(int g=1;g<MAXSEG;g++){ snprintf(p,sizeof p,"%s/%s_gen%d/%s_%d.bin",LAYERED,TYPES[t],g,TYPES[t],sec); struct stat st; if(stat(p,&st)!=0)break; pre=S->n; add_seg(S,p,cum); if(S->n>pre)cum+=S->s[S->n-1].size; } } }
static long readObj(int t,int sec,long long goff,int len,uint8_t*cbuf,size_t cap){ build_segs(t,sec); SecSegs*S=&SEG[t][sec]; for(int i=0;i<S->n;i++) if(goff>=S->s[i].base && goff<S->s[i].base+S->s[i].size){ if((size_t)len>cap)return -1; if(pread(S->s[i].fd,cbuf,len,goff-S->s[i].base)!=len)return -1; return len; } return -1; }
static TCHDB *TCH[2][NSEC];
static void open_tch(int t,int sec){ if(TCH[t][sec])return; char p[600]; snprintf(p,sizeof p,"%s/sha1.%s_%d.tch",PREO,TYPES[t],sec); TCHDB*h=tchdbnew(); if(!tchdbopen(h,p,HDBOREADER|HDBONOLCK)){ tchdbdel(h); TCH[t][sec]=(TCHDB*)-1; return; } TCH[t][sec]=h; }
static const uint8_t* berdec(const uint8_t*p,const uint8_t*e,unsigned long*v){ unsigned long x=0; while(p<e){ x=(x<<7)|(*p&0x7f); if(!(*p++&0x80))break; } *v=x; return p; }
typedef struct { const uint8_t*p; long nrec; int tried; } Sidx;
static Sidx SIDX[2][NSEC][MAXSEG];
static void open_sidx(int t,int sec,int g){ Sidx*S=&SIDX[t][sec][g]; if(S->tried)return; S->tried=1; if(!LAYERED)return; char path[700]; snprintf(path,sizeof path,"%s/%s_gen%d/%s_%d.sidx",LAYERED,TYPES[t],g,TYPES[t],sec); int fd=open(path,O_RDONLY); if(fd<0)return; struct stat st; if(fstat(fd,&st)!=0||st.st_size<32){ close(fd); return; } void*m=mmap(NULL,st.st_size,PROT_READ,MAP_PRIVATE,fd,0); close(fd); if(m==MAP_FAILED)return; S->p=m; S->nrec=st.st_size/32; }
static int sidx_lookup(int t,int sec,const uint8_t*sha20,long long*goff,int*len){ build_segs(t,sec); SecSegs*S=&SEG[t][sec]; for(int g=1;g<S->n;g++){ open_sidx(t,sec,g); Sidx*sx=&SIDX[t][sec][g]; if(!sx->p)continue; long lo=0,hi=sx->nrec-1; while(lo<=hi){ long mid=(lo+hi)/2; const uint8_t*rec=sx->p+(long long)mid*32; int c=memcmp(sha20,rec,20); if(c==0){ uint64_t off; uint32_t l; memcpy(&off,rec+20,8); memcpy(&l,rec+28,4); *goff=S->s[g].base+(long long)off; *len=(int)l; return 1; } if(c<0)hi=mid-1; else lo=mid+1; } } return 0; }
static int lookup(int t,int sec,const uint8_t*sha20,long long*goff,int*len){ if(sidx_lookup(t,sec,sha20,goff,len))return 1; open_tch(t,sec); TCHDB*h=TCH[t][sec]; if(h&&h!=(TCHDB*)-1){ int sz; void*v=tchdbget(h,sha20,20,&sz); if(v){ unsigned long o,l; const uint8_t*p=v,*e=(uint8_t*)v+sz; p=berdec(p,e,&o); berdec(p,e,&l); *goff=o; *len=(int)l; free(v); return 1; } } return 0; }

/* ---- gather ---- */
#define HV(c) ((c)<='9'?(c)-'0':(((c)|32)-'a'+10))
static int fromhex(uint8_t*o,const char*h){ for(int i=0;i<20;i++){ int a=h[2*i],b=h[2*i+1]; if(!isxdigit(a)||!isxdigit(b))return 0; o[i]=(HV(a)<<4)|HV(b); } return 1; }
typedef struct { uint8_t sha[20]; long long off; long long wsoff; int len; } Rec;  /* off=src goff; wsoff=WS offset */
static int cmp_off(const void*a,const void*b){ long long x=((const Rec*)a)->off,y=((const Rec*)b)->off; return x<y?-1:x>y?1:0; }
static int cmp_sha(const void*a,const void*b){ return memcmp(((const Rec*)a)->sha,((const Rec*)b)->sha,20); }

int main(int argc,char**argv){
  if(argc<3){ fprintf(stderr,"usage: [LAYERED=..] gatherWS <closure-shalist> <ws-out-dir> [onlysec]\n"); return 1; }
  PREO=getenv("PREO"); if(!PREO)PREO="/fast/All.sha1o";
  BASEBIN=getenv("BASEBIN"); if(!BASEBIN)BASEBIN="/data/All.blobs";
  LAYERED=getenv("LAYERED");
  int onlysec = argc>3 ? atoi(argv[3]) : -1;

  static Rec* buck[NSEC]; static long bn[NSEC], bcap[NSEC];
  FILE*I=fopen(argv[1],"r"); if(!I){ perror(argv[1]); return 2; }
  char line[160]; uint8_t sha[20]; long total=0;
  while(fgets(line,sizeof line,I)){ if(!fromhex(sha,line)) continue; int sec=sha[0]%NSEC; if(onlysec>=0&&sec!=onlysec) continue;
    if(bn[sec]>=bcap[sec]){ bcap[sec]=bcap[sec]?bcap[sec]*2:1024; buck[sec]=realloc(buck[sec],bcap[sec]*sizeof(Rec)); if(!buck[sec]){ fprintf(stderr,"OOM sec %d\n",sec); return 3; } }
    memcpy(buck[sec][bn[sec]].sha,sha,20); bn[sec]++; total++; }
  fclose(I);
  fprintf(stderr,"[gatherWS] %ld closure shas\n",total);

  char dir[800]; snprintf(dir,sizeof dir,"%s/tree_gen1",argv[2]);
  { char m[900]; snprintf(m,sizeof m,"mkdir -p '%s'",dir); if(system(m)){} }

  long gathered=0, missed=0, readfail=0; long long wbytes=0;
  static uint8_t cbuf[1<<26];
  for(int sec=0;sec<NSEC;sec++){ if(!bn[sec]) continue;
    Rec*R=buck[sec]; long nr=0;
    for(long i=0;i<bn[sec];i++){ uint8_t s[20]; memcpy(s,R[i].sha,20); long long g; int l;   /* temp: no in-place alias */
      if(lookup(1,sec,s,&g,&l)){ memcpy(R[nr].sha,s,20); R[nr].off=g; R[nr].len=l; nr++; } else missed++; }
    if(!nr){ free(buck[sec]); buck[sec]=0; continue; }
    qsort(R,nr,sizeof(Rec),cmp_off);                                   /* sequential source read */
    char bp[900]; snprintf(bp,sizeof bp,"%s/tree_%d.bin",dir,sec); FILE*B=fopen(bp,"wb"); if(!B){ perror(bp); free(buck[sec]); buck[sec]=0; continue; }
    long long woff=0;
    for(long i=0;i<nr;i++){ long r=readObj(1,sec,R[i].off,R[i].len,cbuf,sizeof cbuf); if(r!=R[i].len){ R[i].len=-1; readfail++; continue; } if(fwrite(cbuf,1,r,B)!=(size_t)r){} R[i].wsoff=woff; woff+=r; wbytes+=r; gathered++; }
    fclose(B);
    long ns=0; for(long i=0;i<nr;i++) if(R[i].len>=0) R[ns++]=R[i];  /* drop read-failures */
    /* VERIFY: byte-identity WS-read vs store-read for every gathered obj (sample if VERIFY=N) */
    if(getenv("VERIFY")){ int step=atoi(getenv("VERIFY")); if(step<1)step=1;
      int wfd=open(bp,O_RDONLY); long chk=0,bad=0; static uint8_t wb[1<<26];
      for(long i=0;i<ns;i+=step){ int l=R[i].len;
        if(pread(wfd,wb,l,R[i].wsoff)!=l){ bad++; continue; }
        long sr=readObj(1,sec,R[i].off,l,cbuf,sizeof cbuf);
        if(sr!=l || memcmp(wb,cbuf,l)){ bad++; } chk++; }
      close(wfd);
      fprintf(stderr,"[gatherWS verify sec %d] checked=%ld MISMATCH=%ld\n",sec,chk,bad);
    }
    qsort(R,ns,sizeof(Rec),cmp_sha);                                  /* sidx sorted by sha */
    char sp[900]; snprintf(sp,sizeof sp,"%s/tree_%d.sidx",dir,sec); FILE*S=fopen(sp,"wb");
    for(long i=0;i<ns;i++){ uint64_t off=(uint64_t)R[i].wsoff; uint32_t l=(uint32_t)R[i].len; fwrite(R[i].sha,1,20,S); fwrite(&off,8,1,S); fwrite(&l,4,1,S); }
    fclose(S);
    free(buck[sec]); buck[sec]=0;
  }
  fprintf(stderr,"[gatherWS] gathered=%ld miss(lookup)=%ld readfail=%ld wbytes=%.3fGB -> %s\n",gathered,missed,readfail,wbytes/1e9,argv[2]);
  return 0;
}
