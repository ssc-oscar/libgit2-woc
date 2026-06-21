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
 *   build: cc -O2 -o convgen convgen.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#define NSEC 128

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
  long long stored=0,dup=0; unsigned char sha[20];
  while(getline(&line,&cap,fi)>0){
    char*p=line;                                  /* offset;lenC;sec;sha;... */
    long long o=strtoll(p,&p,10); if(*p!=';')continue; p++;
    long long lc=strtoll(p,&p,10); if(*p!=';')continue; p++;
    int sec=(int)strtol(p,&p,10); if(*p!=';')continue; p++;
    char*s=p; char*e=strchr(p,';'); if(!e)e=strchr(p,'\n'); if(!e)continue;
    if(sec<SECMIN||sec>SECMAX) continue;
    if(e-s!=40||lc<=0||!hexb(s,sha)) continue;
    if(!set_add(sha)){ dup++; continue; }         /* seen -> no write, no offset advance */
    if(!opened[sec]) open_sec(sec);
    if((size_t)lc>bufcap){ bufcap=lc; buf=realloc(buf,bufcap); }
    if(pread(bf,buf,lc,o)!=lc){ fprintf(stderr,"short read %s off %lld len %lld\n",bp,o,lc); continue; }
    fwrite(buf,1,lc,fbin[sec]);
    fprintf(fidx[sec],"%lld;%lld;%lld;%.*s\n", id[sec], off[sec], lc, 40, s);
    off[sec]+=lc; id[sec]++; stored++;
  }
  free(line); free(buf); fclose(fi); close(bf);
  fprintf(stderr,"[convgen %s] %s stored=%lld dup=%lld\n",TYPE,pref,stored,dup);
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
  mkdir(OUT,0775);
  set_init(capbits);
  fprintf(stderr,"[convgen %s] outdir=%s capbits=%d secs=%d..%d\n",TYPE,OUT,capbits,SECMIN,SECMAX);
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
