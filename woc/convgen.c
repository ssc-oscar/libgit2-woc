/* convgen.c -- converter: fold un-split grab batches into per-sec main-store
 * shards {type}_<sec>.{bin,idx} (id;offset;len;sha), copying the compressed LZF
 * slices VERBATIM (no recompress). DEDUP-ON-WRITE: a locally-cached seen-set of
 * 20-byte shas ensures each object is written (and the offset advanced) at most
 * once -> the final segments are clean (no duplicates), across all batches.
 *
 * All batches are processed in ONE invocation so the seen-set persists across
 * them. On start the set is SEEDED from any existing gen .idx files (so a re-run
 * is idempotent / resumable and never re-appends what is already there). An
 * optional sec band (--secmin/--secmax) bounds RAM for huge types (e.g. blobs):
 * run two bands instead of one giant table.
 *
 *   convgen <type> <outdir> [--capbits B] [--secmin A] [--secmax Z] \
 *           ( -L <listfile-of-prefixes> | <prefix> ... )
 *   prefix: "<...>/New<MAP>V<VER>.<NNN>.<SS>" -> "<prefix>.<type>.{idx,bin}" read.
 *   --capbits B : seen-set has 2^B slots (20 B each; 2^31 -> 40 GB). Pick so
 *                 2^B*0.55 > #distinct objects in the band. Default 28.
 *   build: cc -O2 -Wno-deprecated-declarations -o convgen convgen.c -lcrypto
 *          (LZF decompressor is bundled; only openssl -lcrypto needed. content validation =
 *           LZF decode + git-SHA1 per record, default ON, NOVALIDATE=1 to disable)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <openssl/sha.h>

/* bundled LZF decompressor (from liblzf lzf_d.c, BSD) so convgen is self-contained -- da8 has no
 * liblzf. Returns decompressed length, or 0 on error (bad stream / would overflow out_len). */
static unsigned int lzf_decompress(const void*in_data, unsigned int in_len, void*out_data, unsigned int out_len){
  const unsigned char *ip=(const unsigned char*)in_data, *in_end=ip+in_len;
  unsigned char *op=(unsigned char*)out_data, *out_end=op+out_len;
  if(in_len==0) return 0;
  do{
    unsigned int ctrl=*ip++;
    if(ctrl < (1<<5)){                       /* literal run */
      ctrl++;
      if(op+ctrl > out_end) return 0;
      if(ip+ctrl > in_end)  return 0;
      do *op++=*ip++; while(--ctrl);
    }else{                                   /* back reference */
      unsigned int len=ctrl>>5;
      unsigned char *ref=op-((ctrl&0x1f)<<8)-1;
      if(len==7){ if(ip>=in_end) return 0; len+=*ip++; }
      if(ip>=in_end) return 0;
      ref-=*ip++;
      if(op+len+2 > out_end) return 0;
      if(ref < (unsigned char*)out_data) return 0;
      *op++=*ref++; *op++=*ref++;
      do *op++=*ref++; while(--len);
    }
  }while(ip < in_end);
  return (unsigned int)(op-(unsigned char*)out_data);
}

#define NSEC 128

/* ---- content validation (LZF decode + git-sha), default ON (NOVALIDATE=1 to skip) --------------
 * The drain-time checkBin1in ran ONLY on blob+tree, so corrupt commit/tag records reached the gen
 * (18 undecodable V2605 gen commits). Validate at the FOLD so it covers ALL types: decode the LZF
 * slice and verify its git-sha == the idx sha before writing. A bad record is skipped + logged and
 * (critically) NOT added to the seen-set, so a clean duplicate in a later batch can still win. */
static int VALIDATE = 1;
static uint8_t *DBUF; static size_t DCAP;
static long clzf_decode(const uint8_t*in, size_t n){       /* WoC-LZF frame -> DBUF; returns len or -1 */
  if(n==0){ return 0; }
  unsigned long us=0; size_t p=0; unsigned c;
  if(in[0]==0){ us=n-1; p=1; }                             /* 0x00 = uncompressed literal */
  else { c=in[p++];
    if(c<0x80) us=c;
    else if((c&0xe0)==0xc0){ us=(c&0x1f)<<6; us|=in[p++]&0x3f; }
    else if((c&0xf0)==0xe0){ us=(c&0x0f)<<12; us|=(in[p++]&0x3f)<<6; us|=in[p++]&0x3f; }
    else if((c&0xf8)==0xf0){ us=(unsigned long)(c&7)<<18; us|=(unsigned long)(in[p++]&0x3f)<<12; us|=(in[p++]&0x3f)<<6; us|=in[p++]&0x3f; }
    else if((c&0xfc)==0xf8){ us=(unsigned long)(c&3)<<24; us|=(unsigned long)(in[p++]&0x3f)<<18; us|=(unsigned long)(in[p++]&0x3f)<<12; us|=(in[p++]&0x3f)<<6; us|=in[p++]&0x3f; }
    else { us=(unsigned long)(c&1)<<30; us|=(unsigned long)(in[p++]&0x3f)<<24; us|=(unsigned long)(in[p++]&0x3f)<<18; us|=(unsigned long)(in[p++]&0x3f)<<12; us|=(in[p++]&0x3f)<<6; us|=in[p++]&0x3f; }
  }
  if(us>DCAP){ size_t nc=us+64; uint8_t*nb=realloc(DBUF,nc); if(!nb) return -1; DBUF=nb; DCAP=nc; }
  if(in[0]==0){ memcpy(DBUF,in+1,us); return (long)us; }
  return lzf_decompress(in+p, n-p, DBUF, us)==us ? (long)us : -1;
}
/* returns 1 if the record decodes AND its git-sha matches sha20; else 0 (reason to stderr) */
static int valid_record(const char*type, const uint8_t*in, size_t n, const unsigned char*sha20, const char*sha40){
  long dl = clzf_decode(in, n);
  if(dl < 0){ fprintf(stderr,"VALIDATE decodefail %s %s len=%zu\n", type, sha40, n); return 0; }
  char hdr[64]; int hl = snprintf(hdr,sizeof hdr,"%s %ld",type,dl); hdr[hl++]='\0';
  SHA_CTX c; unsigned char md[20]; SHA1_Init(&c); SHA1_Update(&c,hdr,hl); SHA1_Update(&c,DBUF,dl); SHA1_Final(md,&c);
  if(memcmp(md,sha20,20)!=0){
    char h[41]; static const char*hx="0123456789abcdef"; for(int i=0;i<20;i++){h[2*i]=hx[md[i]>>4];h[2*i+1]=hx[md[i]&15];} h[40]=0;
    fprintf(stderr,"VALIDATE shamismatch %s idx=%s got=%s\n", type, sha40, h); return 0;
  }
  return 1;
}

/* ---- open-addressing seen-set of 20-byte keys (empty slot = all zero) ---- */
static unsigned char *SLOT; static uint64_t MASK, CNT; static int HAS_ZERO;
static int is_zero(const unsigned char*p){ for(int i=0;i<20;i++) if(p[i]) return 0; return 1; }
static void set_init(int bits){
  uint64_t cap=(uint64_t)1<<bits;
  SLOT=calloc(cap,20);
  if(!SLOT){ fprintf(stderr,"convgen: cannot alloc seen-set 2^%d (%lluGB)\n",bits,(unsigned long long)(cap*20ULL>>30)); exit(1);}
  MASK=cap-1; CNT=0; HAS_ZERO=0;
}
static int set_add(const unsigned char*k){     /* 1 = newly inserted, 0 = already present */
  if(is_zero(k)){ if(HAS_ZERO) return 0; HAS_ZERO=1; return 1; }
  uint64_t h; memcpy(&h,k,8); h&=MASK;
  for(;;){
    unsigned char*p=SLOT+h*20;
    if(is_zero(p)){ memcpy(p,k,20);
      if(++CNT > (MASK>>1)+(MASK>>2)){ fprintf(stderr,"convgen: seen-set >75%% full (%llu) -- raise --capbits or add a band\n",(unsigned long long)CNT); exit(1);}
      return 1; }
    if(memcmp(p,k,20)==0) return 0;
    h=(h+1)&MASK;
  }
}
static int hexb(const char*h,unsigned char*o){
  for(int i=0;i<20;i++){ int a=h[2*i],b=h[2*i+1];
    a=(a<='9')?a-'0':(a|32)-'a'+10; b=(b<='9')?b-'0':(b|32)-'a'+10;
    if(a<0||a>15||b<0||b>15) return 0; o[i]=(a<<4)|b; } return 1; }

static FILE *fbin[NSEC], *fidx[NSEC]; static long long off[NSEC], id[NSEC]; static int opened[NSEC];
static const char *OUT, *TYPE; static int SECMIN=0, SECMAX=127;

static void open_sec(int sec){
  char p[700]; struct stat st;
  snprintf(p,sizeof p,"%s/%s_%d.bin",OUT,TYPE,sec);
  off[sec]=(stat(p,&st)==0)?st.st_size:0;
  fbin[sec]=fopen(p,"ab"); if(!fbin[sec]){perror(p);exit(1);}
  snprintf(p,sizeof p,"%s/%s_%d.idx",OUT,TYPE,sec);
  long long n=0; FILE*r=fopen(p,"rb");        /* seed seen-set + id from existing gen idx */
  if(r){ char*l=NULL; size_t c=0; unsigned char k[20];
    while(getline(&l,&c,r)>0){ char*q=strrchr(l,';'); if(!q)continue; q++;
      char*e=q; while(*e&&*e!='\n')e++;
      if(e-q>=40&&hexb(q,k)) set_add(k); n++; }
    free(l); fclose(r); }
  id[sec]=n;
  fidx[sec]=fopen(p,"ab"); if(!fidx[sec]){perror(p);exit(1);}
  opened[sec]=1;
}

static void do_batch(const char*pref){
  char ip[800],bp[800];
  snprintf(ip,sizeof ip,"%s.%s.idx",pref,TYPE);
  snprintf(bp,sizeof bp,"%s.%s.bin",pref,TYPE);
  int bf=open(bp,O_RDONLY); if(bf<0){ fprintf(stderr,"skip (no bin) %s\n",bp); return; }
  FILE*fi=fopen(ip,"rb"); if(!fi){ fprintf(stderr,"skip (no idx) %s\n",ip); close(bf); return; }
  char*line=NULL; size_t cap=0; char*buf=NULL; size_t bufcap=0;
  long long stored=0,dup=0,bad=0; unsigned char sha[20];
  while(getline(&line,&cap,fi)>0){
    char*p=line;                                  /* offset;lenC;sec;sha;... */
    long long o=strtoll(p,&p,10); if(*p!=';')continue; p++;
    long long lc=strtoll(p,&p,10); if(*p!=';')continue; p++;
    int sec=(int)strtol(p,&p,10); if(*p!=';')continue; p++;
    char*s=p; char*e=strchr(p,';'); if(!e)e=strchr(p,'\n'); if(!e)continue;
    if(sec<SECMIN||sec>SECMAX) continue;
    if(e-s!=40||lc<=0||!hexb(s,sha)) continue;
    if((size_t)lc>bufcap){ bufcap=lc; buf=realloc(buf,bufcap); }
    if(pread(bf,buf,lc,o)!=lc){ fprintf(stderr,"short read %s off %lld len %lld\n",bp,o,lc); continue; }
    if(VALIDATE){                                 /* decode+git-sha BEFORE dedup: bad -> skip, don't poison seen-set */
      char sha40[41]; memcpy(sha40,s,40); sha40[40]=0;
      if(!valid_record(TYPE,(uint8_t*)buf,(size_t)lc,sha,sha40)){ bad++; continue; }
    }
    if(!set_add(sha)){ dup++; continue; }         /* seen -> no write, no offset advance */
    if(!opened[sec]) open_sec(sec);
    fwrite(buf,1,lc,fbin[sec]);
    fprintf(fidx[sec],"%lld;%lld;%lld;%.*s\n", id[sec], off[sec], lc, 40, s);
    off[sec]+=lc; id[sec]++; stored++;
  }
  free(line); free(buf); fclose(fi); close(bf);
  fprintf(stderr,"[convgen %s] %s stored=%lld dup=%lld bad=%lld\n",TYPE,pref,stored,dup,bad);
}

int main(int argc,char**argv){
  if(argc<3){ fprintf(stderr,"usage: convgen <type> <outdir> [--capbits B][--secmin A][--secmax Z] (-L list | <prefix>...)\n"); return 2; }
  TYPE=argv[1]; OUT=argv[2]; int capbits=28; const char*listf=NULL;
  char **prefs=NULL; int npref=0;
  for(int i=3;i<argc;i++){
    if(!strcmp(argv[i],"--capbits")) capbits=atoi(argv[++i]);
    else if(!strcmp(argv[i],"--secmin")) SECMIN=atoi(argv[++i]);
    else if(!strcmp(argv[i],"--secmax")) SECMAX=atoi(argv[++i]);
    else if(!strcmp(argv[i],"-L")) listf=argv[++i];
    else { prefs=realloc(prefs,sizeof(char*)*(npref+1)); prefs[npref++]=argv[i]; }
  }
  if(getenv("NOVALIDATE")) VALIDATE=0;             /* content decode+sha verify (default ON) */
  mkdir(OUT,0775);
  set_init(capbits);
  fprintf(stderr,"[convgen %s] outdir=%s capbits=%d secs=%d..%d validate=%d\n",TYPE,OUT,capbits,SECMIN,SECMAX,VALIDATE);
  if(listf){
    FILE*f=fopen(listf,"rb"); if(!f){perror(listf);return 1;}
    char*l=NULL; size_t c=0;
    while(getline(&l,&c,f)>0){ char*nl=strchr(l,'\n'); if(nl)*nl=0; if(*l) do_batch(l); }
    free(l); fclose(f);
  } else for(int k=0;k<npref;k++) do_batch(prefs[k]);
  for(int s=0;s<NSEC;s++) if(opened[s]){ fclose(fbin[s]); fclose(fidx[s]); }
  fprintf(stderr,"[convgen %s] distinct stored (run incl seed) ~ %llu\n",TYPE,(unsigned long long)CNT);
  free(prefs);
  return 0;
}
