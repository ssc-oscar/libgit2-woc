/* cmputeDiffGenFB.c -- diff against a CONTENT-indexed SSD subset with HDD fallback.
 *
 * Purpose: the V2605 diff working set (tree closure + delta commits) is staged on SSD
 * (clone0 /fast) as CONTENT .tch maps -- sha20 -> LZF-compressed object content,
 * hash-indexed, NO offset/bin layer (da5 All.sha1c style: <type>_<sec>.tch). Every
 * read tries the subset first (SSD, hash-indexed, no random HDD seek); an object
 * missing from the subset (deep residual beyond BFS level 4, or a staging gap) falls
 * back to the REGULAR offset+content store on HDD (offset .tch -> goff,len -> pread
 * of <type>_<sec>.bin, base + LAYERED gens). Bail/skip semantics apply only when an
 * object is missing from BOTH stores, matching cmputeDiffGen on its single store.
 *
 * Same diff logic/output as cmputeDiffGen.c (byte-identical fields; name-cap 9+"...";
 * badBlob suppression; heap recursion buffer). Only the object-read layer differs.
 *
 *   cmputeDiffGenFB <contentTchDir> [<offTchDir> <baseBin>]   < commitShas
 *     primary (SSD subset): <contentTchDir>/<type>_<sec>.tch, value = LZF object content
 *     fallback (HDD full):  <offTchDir>/sha1.<type>_<sec>.tch + <baseBin>/<type>_<sec>.bin
 *                           (+ env LAYERED gens, as in cmputeDiffGen); omit both args
 *                           to run subset-only (miss => bail, for closure QA runs).
 *   env WOC_FBLOG = file to append one line per fallback read: "<type> <sha40>"
 *       (accounting for closure gaps); stderr prints total fallback counts at exit.
 *
 * build: cc -O2 -o cmputeDiffGenFB cmputeDiffGenFB.c -ltokyocabinet /usr/lib64/liblzf.so.1
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <errno.h>
#include <tchdb.h>
extern unsigned int lzf_decompress(const void*, unsigned int, void*, unsigned int);

#define NSEC 128
#define MAXSEG 16
#define EMPTYTREE "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
static const char *PREC;                   /* primary: content-tch dir (SSD subset) */
static const char *PREO, *BASEBIN, *LAYERED;   /* fallback: offset store (HDD full) */
static int HAVEFB=0;
static unsigned long FBCNT[2];             /* fallback reads: [0]=commit [1]=tree */
static FILE *FBLOG=0;
static const char *TYPES[2]={"commit","tree"};

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

/* ---------- PRIMARY: content .tch (sha20 -> LZF content), SSD subset ---------- */
static TCHDB *CTCH[2][NSEC];
static long getContent(int t,int sec,const uint8_t*sha20,uint8_t*out,size_t cap){
  if(!CTCH[t][sec]){
    char p[600]; snprintf(p,sizeof p,"%s/%s_%d.tch",PREC,TYPES[t],sec);
    TCHDB*h=tchdbnew();
    if(!tchdbopen(h,p,HDBOREADER|HDBONOLCK)){ tchdbdel(h); CTCH[t][sec]=(TCHDB*)-1; }
    else CTCH[t][sec]=h;
  }
  TCHDB*h=CTCH[t][sec]; if(h==(TCHDB*)-1) return -1;
  int sz; void*v=tchdbget(h,sha20,20,&sz); if(!v) return -1;
  long r=clzf(v,sz,out,cap); free(v); return r;
}

/* ---------- FALLBACK: offset .tch + segment bins (base + gens), HDD full ---------- */
typedef struct { int fd; long long base, size; } Seg;
typedef struct { Seg s[MAXSEG]; int n; int built; } SecSegs;
static SecSegs SEG[2][NSEC];
static void add_seg(SecSegs*S, const char*path, long long cum){
  struct stat st; if(stat(path,&st)!=0) return;
  int fd=open(path,O_RDONLY); if(fd<0) return;
  S->s[S->n].fd=fd; S->s[S->n].base=cum; S->s[S->n].size=st.st_size; S->n++;
}
static void build_segs(int t, int sec){
  SecSegs*S=&SEG[t][sec]; if(S->built) return; S->built=1; S->n=0;
  char p[700]; long long cum=0;
  snprintf(p,sizeof p,"%s/%s_%d.bin",BASEBIN,TYPES[t],sec);
  long pre=S->n; add_seg(S,p,cum); if(S->n>pre) cum+=S->s[S->n-1].size;
  if(LAYERED){
    for(int g=1; g<MAXSEG; g++){
      snprintf(p,sizeof p,"%s/%s_gen%d/%s_%d.bin",LAYERED,TYPES[t],g,TYPES[t],sec);
      struct stat st; if(stat(p,&st)!=0) break;
      pre=S->n; add_seg(S,p,cum); if(S->n>pre) cum+=S->s[S->n-1].size;
    }
  }
}
static long readObj(int t,int sec,long long goff,int len,uint8_t*cbuf,size_t cap){
  build_segs(t,sec); SecSegs*S=&SEG[t][sec];
  for(int i=0;i<S->n;i++) if(goff>=S->s[i].base && goff<S->s[i].base+S->s[i].size){
    if((size_t)len>cap) return -1;
    if(pread(S->s[i].fd,cbuf,len,goff-S->s[i].base)!=len) return -1;
    return len;
  }
  return -1;
}
static TCHDB *TCH[2][NSEC];
static void open_tch(int t,int sec){
  if(TCH[t][sec]) return;
  char p[600]; snprintf(p,sizeof p,"%s/sha1.%s_%d.tch",PREO,TYPES[t],sec);
  TCHDB*h=tchdbnew();
  if(!tchdbopen(h,p,HDBOREADER|HDBONOLCK)){ tchdbdel(h); TCH[t][sec]=(TCHDB*)-1; return; }
  TCH[t][sec]=h;
}
static const uint8_t* berdec(const uint8_t*p,const uint8_t*e,unsigned long*v){
  unsigned long x=0; while(p<e){ x=(x<<7)|(*p&0x7f); if(!(*p++&0x80)) break; } *v=x; return p;
}
static int lookup(int t,int sec,const uint8_t*sha20,long long*goff,int*len){
  open_tch(t,sec); TCHDB*h=TCH[t][sec]; if(h==(TCHDB*)-1||!h) return 0;
  int sz; void*v=tchdbget(h,sha20,20,&sz); if(!v) return 0;
  unsigned long o,l; const uint8_t*p=v,*e=(uint8_t*)v+sz;
  p=berdec(p,e,&o); berdec(p,e,&l); *goff=o; *len=(int)l; free(v); return 1;
}

/* ---------- hex ---------- */
static void tohex(const uint8_t*b,char*o){ static const char*h="0123456789abcdef"; for(int i=0;i<20;i++){o[2*i]=h[b[i]>>4];o[2*i+1]=h[b[i]&15];} o[40]=0; }
static int fromhex(const char*s,uint8_t*o){ for(int i=0;i<20;i++){int a=s[2*i],b=s[2*i+1]; a=a<='9'?a-'0':(a|32)-'a'+10; b=b<='9'?b-'0':(b|32)-'a'+10; if(a<0||a>15||b<0||b>15)return 0; o[i]=(a<<4)|b;} return 1; }

/* ---------- GEN sidx lookup: LAYERED/<type>_gen1/<type>_<sec>.sidx (sha20 + off u64le +
 * len u32le, sorted by sha; off is LOCAL into the gen1 bin). Binary search; returns GLOBAL
 * offset (base_size + local) so readObj's base+gen segment chain reads the gen bin. This is
 * how the reader resolves gen trees now that gen offsets are NOT grafted into base sha1o. */
static int GSFD[2][NSEC]; static long GSN[2][NSEC];
static int gen_lookup(int t,int sec,const uint8_t*sha20,long long*goff,int*len){
  if(!LAYERED) return 0;
  if(GSFD[t][sec]==0){
    char p[600]; snprintf(p,sizeof p,"%s/%s_gen1/%s_%d.sidx",LAYERED,TYPES[t],TYPES[t],sec);
    int fd=open(p,O_RDONLY); struct stat st;
    if(fd<0){ if(errno==EMFILE||errno==ENFILE){ fprintf(stderr,"FATAL: fd limit hit opening %s -- raise RLIMIT_NOFILE (miss would be silently mis-read as no-parent)\n",p); exit(3);} GSFD[t][sec]=-1; return 0; }
    if(fstat(fd,&st)!=0){ close(fd); GSFD[t][sec]=-1; return 0; }
    GSFD[t][sec]=fd; GSN[t][sec]=st.st_size/32;
  }
  if(GSFD[t][sec]==-1) return 0;
  int fd=GSFD[t][sec]; long lo=0,hi=GSN[t][sec]-1; uint8_t rec[32];
  while(lo<=hi){ long mid=(lo+hi)/2; if(pread(fd,rec,32,(off_t)mid*32)!=32) return 0;
    int c=memcmp(rec,sha20,20);
    if(c==0){ unsigned long long o; unsigned int l; memcpy(&o,rec+20,8); memcpy(&l,rec+28,4);
      build_segs(t,sec); long long bs=(SEG[t][sec].n>0)?SEG[t][sec].s[0].size:0;
      *goff=(long long)o+bs; *len=(int)l; return 1; }
    if(c<0) lo=mid+1; else hi=mid-1; }
  return 0;
}

/* ---------- unified read: SSD content subset first, then HDD offset fallback ---------- */
static long getObj(int t,const char*sha40,uint8_t*out,size_t cap){
  uint8_t sha[20]; if(!fromhex(sha40,sha)) return -1;
  int sec=sha[0]%NSEC;                     /* Perl: hex(substr($h,0,2)) = first byte; %128 */
  long r=getContent(t,sec,sha,out,cap);    /* primary: hash-indexed content, SSD */
  if(r>=0 || !HAVEFB) return r;
  long long goff; int len;                 /* fallback: base offset (sha1o), then gen sidx */
  if(!lookup(t,sec,sha,&goff,&len) && !gen_lookup(t,sec,sha,&goff,&len)) return -1;
  static uint8_t cbuf[1<<26];
  long rr=readObj(t,sec,goff,len,cbuf,sizeof cbuf); if(rr<0) return -1;
  rr=clzf(cbuf,rr,out,cap);
  if(rr>=0){ FBCNT[t]++; if(FBLOG){ fprintf(FBLOG,"%s %s\n",TYPES[t],sha40); fflush(FBLOG); } }
  return rr;
}

/* ---------- minimal chained hash: key bytes -> Names list or sha ---------- */
typedef struct Name { char *s; struct Name *next; } Name;
typedef struct HE { uint8_t *k; int kl; Name *names; uint8_t sha[20]; int hassha; struct HE *next; } HE;
typedef struct { HE **b; int nb; } Hash;
static unsigned hkey(const uint8_t*k,int kl){ unsigned h=2166136261u; for(int i=0;i<kl;i++){h^=k[i];h*=16777619u;} return h; }
static Hash* hnew(){ Hash*H=calloc(1,sizeof*H); H->nb=4096; H->b=calloc(H->nb,sizeof(HE*)); return H; }
static HE* hget(Hash*H,const uint8_t*k,int kl){ unsigned i=hkey(k,kl)&(H->nb-1); for(HE*e=H->b[i];e;e=e->next) if(e->kl==kl&&!memcmp(e->k,k,kl)) return e; return 0; }
static HE* hput(Hash*H,const uint8_t*k,int kl){ HE*e=hget(H,k,kl); if(e)return e; unsigned i=hkey(k,kl)&(H->nb-1); e=calloc(1,sizeof(HE)); e->k=malloc(kl); memcpy(e->k,k,kl); e->kl=kl; e->next=H->b[i]; H->b[i]=e; return e; }
static void addname(HE*e,const char*s){ Name*n=malloc(sizeof*n); n->s=strdup(s); n->next=e->names; e->names=n; }
static void hfree(Hash*H){ for(int i=0;i<H->nb;i++){HE*e=H->b[i]; while(e){HE*nx=e->next; Name*m=e->names; while(m){Name*mn=m->next;free(m->s);free(m);m=mn;} free(e->k);free(e);e=nx;}} free(H->b);free(H); }

/* ---------- badBlob set (nuisance blobs: Perl woc.pm %badBlob) ---------- */
static Hash *BADBLOB=0;
static void load_badblob(void){
  BADBLOB=hnew();
  const char*f=getenv("WOC_BADBLOB"); if(!f)f="/tmp/badblob.txt";
  FILE*fp=fopen(f,"r"); if(!fp) return;
  char ln[128]; uint8_t sha[20];
  while(fgets(ln,sizeof ln,fp)){ int L=strlen(ln); while(L&&(ln[L-1]=='\n'||ln[L-1]=='\r'||ln[L-1]==' '))ln[--L]=0;
    if(L==40 && fromhex(ln,sha)) hput(BADBLOB,sha,20); }
  fclose(fp);
}
static int badblob(const uint8_t*sha20){ return BADBLOB && hget(BADBLOB,sha20,20); }

/* sanitize a tree entry name like the Perl (CR/NL/;) */
static void sanit(char*s){ for(;*s;s++){ if(*s=='\r')*s='_'; else if(*s=='\n')*s='_'; else if(*s==';')*s=':'; } }

/* parse tree content -> maps: mapd(dirsha->names)+mapdI(name->sha); mapf(filesha->names)+mapfI(name->sha) */
static void getTR(const uint8_t*t,long n,Hash*mapd,Hash*mapdI,Hash*mapf,Hash*mapfI){
  long p=0;
  while(p<n){
    long ms=p; while(p<n && t[p]!=' ') p++; if(p>=n)break; /* mode */
    char modebuf[16]; int ml=p-ms; if(ml>15)ml=15; memcpy(modebuf,t+ms,ml); modebuf[ml]=0; int mode=(int)strtol(modebuf,0,8); p++;
    long ns=p; while(p<n && t[p]!=0) p++; if(p>=n)break;
    char nm[4096]; int nl=p-ns; if(nl>4095)nl=4095; memcpy(nm,t+ns,nl); nm[nl]=0; sanit(nm); p++;
    if(p+20>n) break; const uint8_t*sha=t+p; p+=20;
    if(mode==040000){ HE*e=hput(mapd,sha,20); addname(e,nm); HE*ei=hput(mapdI,(uint8_t*)nm,strlen(nm)); memcpy(ei->sha,sha,20); ei->hassha=1; }
    else { HE*e=hput(mapf,sha,20); addname(e,nm); HE*ei=hput(mapfI,(uint8_t*)nm,strlen(nm)); memcpy(ei->sha,sha,20); ei->hassha=1; }
  }
}

static void separate2T(const char*c,const char*pre,const char*tHex,const char*tpHex);
static void printTR(const char*c,const uint8_t*tree,long n,const char*prefix,int created);

static void printTR(const char*c,const uint8_t*tree,long n,const char*prefix,int created){
  if(n<=0) return;
  long p=0;
  while(p<n){
    long ms=p; while(p<n&&tree[p]!=' ')p++; if(p>=n)break; char mb[16];int ml=p-ms;if(ml>15)ml=15;memcpy(mb,tree+ms,ml);mb[ml]=0;int mode=strtol(mb,0,8);p++;
    long ns=p; while(p<n&&tree[p]!=0)p++; if(p>=n)break; char nm[4096];int nl=p-ns;if(nl>4095)nl=4095;memcpy(nm,tree+ns,nl);nm[nl]=0;sanit(nm);p++;
    if(p+20>n)break; const uint8_t*sha=tree+p;p+=20; char hx[41];tohex(sha,hx);
    if(mode==040000){ /* recurse into subdir. MUST use a heap buffer per call: a shared
       static buffer would be clobbered by the recursive read while this level is still
       iterating `tree` (corrupts deep trees -> early loop exit -> under-production). */
      char sh2[41]; tohex(sha,sh2); uint8_t*sub=malloc(1<<26);
      if(sub){ long sn=getObj(1,sh2,sub,1<<26); char npre[8192]; snprintf(npre,sizeof npre,"%s/%s",prefix,nm); printTR(c,sub,sn,npre,created); free(sub); } }
    else { if(created) printf("%s;%s/%s;%s;\n",c,prefix,nm,hx); else printf("%s;%s/%s;;%s\n",c,prefix,nm,hx); }
  }
}

static void separate2T(const char*c,const char*pre,const char*tHex,const char*tpHex){
  static uint8_t tb[1<<26], pb[1<<26];
  long tn=getObj(1,tHex,tb,sizeof tb); long pn=getObj(1,tpHex,pb,sizeof pb);
  /* missing in BOTH stores and not the empty tree => bail (emit nothing), as before. */
  if(tn<0 && strcmp(tHex,EMPTYTREE)) return;
  if(pn<0 && strcmp(tpHex,EMPTYTREE)) return;
  Hash *md=hnew(),*mdI=hnew(),*mf=hnew(),*mfI=hnew(), *pd=hnew(),*pdI=hnew(),*pf=hnew(),*pfI=hnew();
  if(tn>0) getTR(tb,tn,md,mdI,mf,mfI);
  if(pn>0) getTR(pb,pn,pd,pdI,pf,pfI);
  /* files in child */
  for(int i=0;i<mf->nb;i++) for(HE*e=mf->b[i];e;e=e->next){ char kH[41]; tohex(e->k,kH);
    HE*pe=hget(pf,e->k,20);
    if(!pe){ for(Name*n=e->names;n;n=n->next){ HE*x=hget(pfI,(uint8_t*)n->s,strlen(n->s));
        if(x){char oh[41];tohex(x->sha,oh); printf("%s;%s/%s;%s;%s\n",c,pre,n->s,kH,oh);} else printf("%s;%s/%s;%s;\n",c,pre,n->s,kH); } }
    else { /* same blob, different location(s): field4 = parent names with this blob. */
      char srcs[4096]; int sl=0,cnt=0; srcs[0]=0;
      if(!badblob(e->k)){
        for(Name*m=pe->names;m;m=m->next){
          if(cnt<9) sl+=snprintf(srcs+sl,sizeof srcs-sl, cnt==0?"%s/%s":" %s", cnt==0?pre:m->s, m->s);
          cnt++;
        }
        if(cnt>9) sl+=snprintf(srcs+sl,sizeof srcs-sl," ...");
      }
      for(Name*n=e->names;n;n=n->next){ HE*same=hget(pf,e->k,20); int innm=0; for(Name*m=same->names;m;m=m->next) if(!strcmp(m->s,n->s)){innm=1;break;}
        if(!innm) printf("%s;%s/%s;%s;%s\n",c,pre,n->s,kH,srcs); } }
  }
  /* deleted files */
  for(int i=0;i<pf->nb;i++) for(HE*e=pf->b[i];e;e=e->next){ if(hget(mf,e->k,20))continue; char kH[41];tohex(e->k,kH);
    for(Name*n=e->names;n;n=n->next){ if(!hget(mfI,(uint8_t*)n->s,strlen(n->s))) printf("%s;%s/%s;;%s\n",c,pre,n->s,kH); } }
  /* dirs in child */
  for(int i=0;i<md->nb;i++) for(HE*e=md->b[i];e;e=e->next){ if(hget(pd,e->k,20))continue; char v0H[41];tohex(e->k,v0H);
    for(Name*n=e->names;n;n=n->next){ HE*x=hget(pdI,(uint8_t*)n->s,strlen(n->s)); char npre[8192]; snprintf(npre,sizeof npre,"%s/%s",pre,n->s);
      if(x){ char ph[41];tohex(x->sha,ph); separate2T(c,npre,v0H,ph); } else { static uint8_t sub[1<<26]; long sn=getObj(1,v0H,sub,sizeof sub); printTR(c,sub,sn,npre,1); } } }
  /* deleted dirs */
  for(int i=0;i<pd->nb;i++) for(HE*e=pd->b[i];e;e=e->next){ if(hget(md,e->k,20))continue; char v0H[41];tohex(e->k,v0H);
    for(Name*n=e->names;n;n=n->next){ if(!hget(mdI,(uint8_t*)n->s,strlen(n->s))){ static uint8_t sub[1<<26]; long sn=getObj(1,v0H,sub,sizeof sub); char npre[8192]; snprintf(npre,sizeof npre,"%s/%s",pre,n->s); printTR(c,sub,sn,npre,0); } } }
  hfree(md);hfree(mdI);hfree(mf);hfree(mfI);hfree(pd);hfree(pdI);hfree(pf);hfree(pfI);
}

/* getCT: read commit, extract tree + ALL parents concatenated (40 hex each). With the
 * fallback in getObj, a parent commit absent from the SSD subset is fetched from the
 * HDD store; only a commit missing from BOTH stores still clears tree ("differs"). */
static int getCT(const char*c,char*tree,char*parent){
  tree[0]=parent[0]=0;
  static uint8_t buf[1<<24]; long n=getObj(0,c,buf,sizeof buf); if(n<=0) return 0;
  buf[n]=0; int pl=0;
  char *s=(char*)buf, *line=s;
  for(char*p=s;;p++){ if(*p=='\n'||*p==0){ int len=p-line;
      if(len>5 && !strncmp(line,"tree ",5)){ memcpy(tree,line+5,40); tree[40]=0; }
      else if(len>7 && !strncmp(line,"parent ",7)){ if(pl+40<=40*512){ memcpy(parent+pl,line+7,40); pl+=40; parent[pl]=0; } } /* cap at 512 parents = caller buffer size; a malformed/bomb commit (e.g. an 11MB blob mis-stored as a commit) can carry thousands of "parent " lines -> without this bound it overflows parent[40*512+1] (SIGSEGV under -O2). */
      if(*p==0 || (p>s && *p=='\n' && p[1]=='\n')) break; line=p+1; if(*p==0)break; }
    if(*p==0)break; }
  return tree[0]?1:0;
}

int main(int argc,char**argv){
  if(argc<2){ fprintf(stderr,"usage: %s <contentTchDir> [<offTchDir> <baseBin>] < commitShas\n",argv[0]); return 1; }
  /* Store-resident mode caches an fd per (type,section) for content-tch + offset-tch + sidx +
   * base-bin + gen-bins -- ~1400 fds across 128 sections x 2 types. The default soft limit (1024)
   * is exceeded ~part-way through, after which open() returns EMFILE and gen_lookup/build_segs
   * silently treat it as "object absent" -> bogus "no parent" (~44% of gen commits dropped).
   * Raise NOFILE to the hard max. Harmless for content-only mode (it opens only ~256 tch fds). */
  { struct rlimit rl; if(getrlimit(RLIMIT_NOFILE,&rl)==0){ rl.rlim_cur=rl.rlim_max; setrlimit(RLIMIT_NOFILE,&rl); } }
  PREC = argv[1];
  if(argc>3){ PREO=argv[2]; BASEBIN=argv[3]; LAYERED=getenv("LAYERED"); HAVEFB=1; }
  const char*fl=getenv("WOC_FBLOG"); if(fl) FBLOG=fopen(fl,"a");
  load_badblob();
  char line[64], tree[41], treeP[41], curpar[41];
  static char parent[40*512+1], pp2[40*512+1];   /* all parents concatenated */
  while(fgets(line,sizeof line,stdin)){
    int L=strlen(line); while(L&&(line[L-1]=='\n'||line[L-1]=='\r'))line[--L]=0;
    if(L!=40) continue;
    if(!getCT(line,tree,parent)){ fprintf(stderr,"no commit %s\n",line); continue; }
    if(parent[0]){
      int plen=strlen(parent);
      memcpy(curpar,parent,40); curpar[40]=0;            /* first parent */
      if(!getCT(curpar,treeP,pp2)){ fprintf(stderr,"no parent %s for %s\n",curpar,line); continue; }
      if(!strcmp(tree,treeP)){
        int idx; for(idx=40; idx<plen; idx+=40){
          memcpy(curpar,parent+idx,40); curpar[40]=0;
          getCT(curpar,treeP,pp2);   /* miss in BOTH stores clears treeP => differs */
          if(strcmp(treeP,tree)) break;
        }
        if(!strcmp(tree,treeP)){ fprintf(stderr,"identical trees %s for %s\n",tree,line); continue; }
      }
      separate2T(line,"",tree,treeP);
    } else { static uint8_t tb[1<<26]; long tn=getObj(1,tree,tb,sizeof tb); printTR(line,tb,tn,"",1); }
  }
  if(HAVEFB) fprintf(stderr,"fallback reads: commit=%lu tree=%lu\n",FBCNT[0],FBCNT[1]);
  if(FBLOG) fclose(FBLOG);
  return 0;
}
