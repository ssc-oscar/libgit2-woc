/* convgen.c -- converter: fold an un-split grab batch into per-sec main-store
 * shards, in the EXISTING {type}_<sec>.{bin,idx} format (id;offset;len;sha).
 *
 * Reads a grab batch .idx (offset;lenC;sec;sha;dir...) + .bin (concatenated
 * Compress::LZF-compressed objects) and APPENDS each object's compressed bytes
 * VERBATIM onto <out>/<type>_<sec>.bin, appending "id;offset;lenC;sha" to
 * <out>/<type>_<sec>.idx. Seeds id/offset from any existing per-sec files, so it
 * appends onto a base shard copy (or starts a fresh generation if <out> empty).
 * No (de)compression -- the byte slice is copied as-is, so the output is
 * consumable by the existing WoC read path unchanged. BF / existence index are
 * rebuilt from the .idx AFTERWARD (decoupled), not maintained here.
 *
 *   convgen <type> <batch.idx> <batch.bin> <outdir>
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
static FILE *fbin[NSEC], *fidx[NSEC];
static long long off[NSEC], id[NSEC];   /* next offset / next id, per sec */
static int opened[NSEC];

static void open_sec(const char *out, const char *type, int sec){
  char p[600];
  snprintf(p,sizeof p,"%s/%s_%d.bin",out,type,sec);
  struct stat st;
  off[sec] = (stat(p,&st)==0) ? st.st_size : 0;     /* append offset = current bin size */
  fbin[sec] = fopen(p,"ab");
  if(!fbin[sec]){ perror(p); exit(1);}              
  snprintf(p,sizeof p,"%s/%s_%d.idx",out,type,sec);
  /* seed id = (last existing idx record's id)+1, read cheaply from the file tail
   * (nothing downstream keys on id -- it is a row counter -- so O(1) is enough). */
  long long n=0; int fd=open(p,O_RDONLY); struct stat si;
  if(fd>=0 && fstat(fd,&si)==0 && si.st_size>0){
    off_t back = si.st_size>4096 ? 4096 : si.st_size;
    char tb[4097]; ssize_t k=pread(fd,tb,back,si.st_size-back);
    if(k>0){ tb[k]=0;
      char *nl=tb+k-1; if(*nl=='\n') *nl=0;          /* drop trailing newline */
      char *ls=strrchr(tb,'\n'); ls = ls?ls+1:tb;    /* start of last record */
      n = strtoll(ls,NULL,10) + 1;                    /* last id + 1 */
    }
  }
  if(fd>=0) close(fd);
  id[sec]=n;
  fidx[sec]=fopen(p,"ab");
  if(!fidx[sec]){ perror(p); exit(1);}              
  opened[sec]=1;
}

int main(int argc,char**argv){
  if(argc!=5){ fprintf(stderr,"usage: convgen <type> <batch.idx> <batch.bin> <outdir>\n"); return 2; }
  const char *type=argv[1], *bidx=argv[2], *bbin=argv[3], *out=argv[4];
  int bf=open(bbin,O_RDONLY); if(bf<0){ perror(bbin); return 1; }
  FILE *fi=fopen(bidx,"rb"); if(!fi){ perror(bidx); return 1; }
  mkdir(out,0775);

  char *line=NULL; size_t cap=0; ssize_t L;
  char *buf=NULL; size_t bufcap=0;
  long long n=0, bytes=0;
  while((L=getline(&line,&cap,fi))>0){
    /* offset;lenC;sec;sha;... */
    char *p=line;
    long long o = strtoll(p,&p,10); if(*p!=';') continue; p++;
    long long lc= strtoll(p,&p,10); if(*p!=';') continue; p++;
    int sec     = (int)strtol(p,&p,10); if(*p!=';') continue; p++;
    char *sha=p; char *e=strchr(p,';'); if(!e) e=strchr(p,'\n'); if(!e) continue;
    size_t shalen=e-sha;
    if(sec<0||sec>=NSEC||shalen!=40||lc<=0) continue;
    if(!opened[sec]) open_sec(out,type,sec);
    if((size_t)lc>bufcap){ bufcap=lc; buf=realloc(buf,bufcap); }
    ssize_t r=pread(bf,buf,lc,o);
    if(r!=lc){ fprintf(stderr,"short read sec %d off %lld len %lld got %zd\n",sec,o,lc,r); continue; }
    fwrite(buf,1,lc,fbin[sec]);
    fprintf(fidx[sec],"%lld;%lld;%lld;%.*s\n", id[sec], off[sec], lc, (int)shalen, sha);
    off[sec]+=lc; id[sec]++; n++; bytes+=lc;
  }
  for(int s=0;s<NSEC;s++){ if(opened[s]){ fclose(fbin[s]); fclose(fidx[s]); } }
  close(bf); fclose(fi);
  fprintf(stderr,"[convgen %s] objects=%lld bytes=%lld\n",type,n,bytes);
  return 0;
}
