/* sidx.c -- frozen sorted offset index for a converted shard (no deps, immutable).
 * Record = sha[20] + offset(u64,LE) + len(u32,LE) = 32 bytes, sorted by sha.
 * Built once from {type}_<sec>.idx (id;offset;len;sha); read by mmap+bsearch
 * (same idiom as hasObjBF). Replaces a per-gen tch/LMDB for write-once shards.
 *
 *   sidx build <in.idx> <out.sidx>
 *   sidx get   <in.sidx> < shas        # 40-hex per line -> "sha;off;len" or "sha;MISS"
 *   build: cc -O2 -o sidx sidx.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define REC 32
typedef struct { unsigned char k[20]; uint64_t off; uint32_t len; } __attribute__((packed)) Rec;

static int hexb(const char*h,unsigned char*o){
  for(int i=0;i<20;i++){ int a=h[2*i],b=h[2*i+1];
    a=(a<='9')?a-'0':(a|32)-'a'+10; b=(b<='9')?b-'0':(b|32)-'a'+10;
    if(a<0||a>15||b<0||b>15) return 0; o[i]=(a<<4)|b; } return 1; }
static int cmp(const void*A,const void*B){ return memcmp(A,B,20); }

static int build(const char*in,const char*out){
  FILE*f=fopen(in,"rb"); if(!f){perror(in);return 1;}
  size_t cap=1<<20, n=0; Rec*r=malloc(cap*sizeof(Rec));
  char*line=NULL; size_t lc=0;
  while(getline(&line,&lc,f)>0){
    /* id;offset;len;sha */
    char*p=line; strtoll(p,&p,10); if(*p!=';')continue; p++;
    long long off=strtoll(p,&p,10); if(*p!=';')continue; p++;
    long long len=strtoll(p,&p,10); if(*p!=';')continue; p++;
    char*sha=p; while(*sha==' ')sha++;
    if(strlen(sha)<40)continue;
    if(n==cap){cap*=2; r=realloc(r,cap*sizeof(Rec));}
    if(!hexb(sha,r[n].k))continue;
    r[n].off=off; r[n].len=len; n++;
  }
  fclose(f);
  qsort(r,n,sizeof(Rec),cmp);
  FILE*o=fopen(out,"wb"); if(!o){perror(out);return 1;}
  fwrite(r,sizeof(Rec),n,o); fclose(o); free(r);
  fprintf(stderr,"[sidx build] %s: %zu recs\n",out,n);
  return 0;
}

static const unsigned char* mm; static size_t N;
static const unsigned char* getrec(const unsigned char*key){
  long lo=0,hi=N;
  while(lo<hi){ long m=(lo+hi)/2; const unsigned char*k=mm+m*REC;
    int c=memcmp(k,key,20);
    if(c<0)lo=m+1; else if(c>0)hi=m; else return k; }
  return NULL;
}
static int get(const char*in){
  int fd=open(in,O_RDONLY); if(fd<0){perror(in);return 1;}
  struct stat st; fstat(fd,&st); N=st.st_size/REC;
  mm=mmap(NULL,st.st_size,PROT_READ,MAP_SHARED,fd,0); close(fd);
  if(mm==MAP_FAILED){perror("mmap");return 1;}
  char*line=NULL; size_t lc=0; unsigned char key[20];
  while(getline(&line,&lc,stdin)>0){
    char*nl=strchr(line,'\n'); if(nl)*nl=0;
    if(strlen(line)<40){printf("%s;MISS\n",line);continue;}
    if(!hexb(line,key)){printf("%s;MISS\n",line);continue;}
    const unsigned char*r=getrec(key);
    if(!r){printf("%s;MISS\n",line);continue;}
    uint64_t off; uint32_t len; memcpy(&off,r+20,8); memcpy(&len,r+28,4);
    printf("%s;%llu;%u\n",line,(unsigned long long)off,len);
  }
  return 0;
}
int main(int c,char**v){
  if(c==4&&!strcmp(v[1],"build"))return build(v[2],v[3]);
  if(c==3&&!strcmp(v[1],"get"))return get(v[2]);
  fprintf(stderr,"usage: sidx build <in.idx> <out.sidx> | sidx get <in.sidx> <shas\n"); return 2;
}
