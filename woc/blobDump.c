/* blobDump <offTchDir> <baseBin> <out.tch>   (env LAYERED=gens)
 * Read blob shas (hex/line) from stdin, resolve each from the layered blob store
 * (offset tch sha1.blob_<sec>.tch -> blob_<sec>.bin base + LAYERED gens), LZF-decompress
 * (Compress::LZF framing), and write sha20 -> decompressed content into <out.tch>.
 * Machinery (clzf/readObj/lookup) lifted verbatim from cmputeDiffGenFB.c. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <tchdb.h>
extern unsigned int lzf_decompress(const void*, unsigned int, void*, unsigned int);
#define NSEC 128
#define MAXSEG 16
#define T 2                 /* blob type index */
static const char *BASEBIN, *LAYERED, *PREO;
static const char *TYPES[3]={"commit","tree","blob"};

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
  return lzf_decompress(in+p, n-p, out, us)==us ? (long)us : -1;
}
typedef struct { int fd; long long base, size; } Seg;
typedef struct { Seg s[MAXSEG]; int n, built; } SecSegs;
static SecSegs SEG[NSEC];
static void add_seg(SecSegs*S,const char*path,long long cum){ struct stat st; if(stat(path,&st)!=0)return; int fd=open(path,O_RDONLY); if(fd<0)return; S->s[S->n].fd=fd; S->s[S->n].base=cum; S->s[S->n].size=st.st_size; S->n++; }
static void build_segs(int sec){ SecSegs*S=&SEG[sec]; if(S->built)return; S->built=1; S->n=0; char p[700]; long long cum=0;
  snprintf(p,sizeof p,"%s/%s_%d.bin",BASEBIN,TYPES[T],sec); long pre=S->n; add_seg(S,p,cum); if(S->n>pre)cum+=S->s[S->n-1].size;
  if(LAYERED){ for(int g=1;g<MAXSEG;g++){ snprintf(p,sizeof p,"%s/%s_gen%d/%s_%d.bin",LAYERED,TYPES[T],g,TYPES[T],sec); struct stat st; if(stat(p,&st)!=0)break; pre=S->n; add_seg(S,p,cum); if(S->n>pre)cum+=S->s[S->n-1].size; } } }
static long readObj(int sec,long long goff,int len,uint8_t*cbuf,size_t cap){ build_segs(sec); SecSegs*S=&SEG[sec];
  for(int i=0;i<S->n;i++) if(goff>=S->s[i].base && goff<S->s[i].base+S->s[i].size){ if((size_t)len>cap)return -1; if(pread(S->s[i].fd,cbuf,len,goff-S->s[i].base)!=len)return -1; return len; } return -1; }
static TCHDB *TCH[NSEC];
static void open_tch(int sec){ if(TCH[sec])return; char p[600]; snprintf(p,sizeof p,"%s/sha1.%s_%d.tch",PREO,TYPES[T],sec); TCHDB*h=tchdbnew(); if(!tchdbopen(h,p,HDBOREADER|HDBONOLCK)){ tchdbdel(h); TCH[sec]=(TCHDB*)-1; return; } TCH[sec]=h; }
static const uint8_t* berdec(const uint8_t*p,const uint8_t*e,unsigned long*v){ unsigned long x=0; while(p<e){ x=(x<<7)|(*p&0x7f); if(!(*p++&0x80))break; } *v=x; return p; }
static int lookup(int sec,const uint8_t*sha20,long long*goff,int*len){ open_tch(sec); TCHDB*h=TCH[sec]; if(h==(TCHDB*)-1||!h)return 0; int sz; void*v=tchdbget(h,sha20,20,&sz); if(!v)return 0; unsigned long o,l; const uint8_t*p=v,*e=(uint8_t*)v+sz; p=berdec(p,e,&o); berdec(p,e,&l); *goff=o; *len=(int)l; free(v); return 1; }
static int fromhex(const char*s,uint8_t*o){ for(int i=0;i<20;i++){int a=s[2*i],b=s[2*i+1]; a=a<='9'?a-'0':(a|32)-'a'+10; b=b<='9'?b-'0':(b|32)-'a'+10; if(a<0||a>15||b<0||b>15)return 0; o[i]=(a<<4)|b;} return 1; }

int main(int argc,char**argv){
  if(argc<4){ fprintf(stderr,"usage: [LAYERED=..] blobDump <offTchDir> <baseBin> <out.tch> < blobShas\n"); return 1; }
  PREO=argv[1]; BASEBIN=argv[2]; LAYERED=getenv("LAYERED");
  TCHDB*out=tchdbnew(); tchdbtune(out,-1,-1,-1,HDBTLARGE);
  if(!tchdbopen(out,argv[3],HDBOWRITER|HDBOCREAT|HDBOTRUNC)){ fprintf(stderr,"tchopen fail %s\n",argv[3]); return 2; }
  static uint8_t cbuf[1<<28], obuf[1<<28]; char line[64]; uint8_t sha[20]; long n=0,got=0,miss=0,dup=0;
  while(fgets(line,sizeof line,stdin)){
    if(!fromhex(line,sha)) continue; n++;
    int sz; void*ex=tchdbget(out,sha,20,&sz); if(ex){ free(ex); dup++; continue; }
    int sec=sha[0]%NSEC; long long goff; int len;
    if(!lookup(sec,sha,&goff,&len)){ miss++; continue; }
    long r=readObj(sec,goff,len,cbuf,sizeof cbuf); if(r<0){ miss++; continue; }
    long u=clzf(cbuf,r,obuf,sizeof obuf); if(u<0){ miss++; continue; }
    tchdbput(out,sha,20,obuf,u); got++;
    if(n%200000==0){ fprintf(stderr,"[blobDump] %ld shas %ld got %ld miss %ld dup\n",n,got,miss,dup); fflush(stderr); }
  }
  tchdbclose(out); tchdbdel(out);
  fprintf(stderr,"[blobDump] DONE %ld shas %ld got %ld miss %ld dup -> %s\n",n,got,miss,dup,argv[3]);
  return 0;
}
