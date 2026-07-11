/* t2ctBuild.c <idx> <bin>  -- sequential tree -> child-tree (t2ct) edge extractor.
 * Streams <idx> (id;off;len;sha) in offset order, preads <bin>[off,len] (=> sequential access),
 * LZF-decompresses each tree, parses entries, and for every subdir (mode 040000) entry emits
 *   "<this_tree_sha>;<child_tree_sha>"   (40-hex ; 40-hex) to stdout.
 * One (idx,bin) pair per call (run once for the base layer, once for the gen layer, per section).
 * Sequential -> HDD is fine. build: cc -O2 -o t2ctBuild t2ctBuild.c /usr/lib64/liblzf.so.1
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
extern unsigned int lzf_decompress(const void*, unsigned int, void*, unsigned int);

/* Compress::LZF decompress (byte-exact, from cmputeDiffGen) */
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
static void tohex(const uint8_t*b,char*o){ static const char*h="0123456789abcdef"; for(int i=0;i<20;i++){o[2*i]=h[b[i]>>4];o[2*i+1]=h[b[i]&15];} o[40]=0; }

int main(int argc,char**argv){
  if(argc<3){ fprintf(stderr,"usage: t2ctBuild <idx> <bin>\n"); return 1; }
  FILE*I=fopen(argv[1],"r"); if(!I){ perror(argv[1]); return 2; }
  int b=open(argv[2],O_RDONLY); if(b<0){ perror(argv[2]); return 2; }
  posix_fadvise(b,0,0,POSIX_FADV_SEQUENTIAL);   /* aggressive readahead: per-tree preads then hit cache */
  static uint8_t cbuf[1<<26], out[1<<26];
  char *ob=malloc(1<<22); if(ob) setvbuf(stdout,ob,_IOFBF,1<<22);
  char line[256], phex[41], chex[41], shahex[64];
  long long id, off, nt=0, ne=0; long len;
  while(fgets(line,sizeof line,I)){
    if(sscanf(line,"%lld;%lld;%ld;%63s",&id,&off,&len,shahex)!=4) continue;
    if(len<=0 || len>(long)sizeof cbuf) continue;
    if(pread(b,cbuf,len,off)!=len) continue;
    long n=clzf(cbuf,len,out,sizeof out); if(n<0) continue;
    nt++; memcpy(phex,shahex,40); phex[40]=0;
    long p=0;
    while(p<n){
      long ms=p; while(p<n&&out[p]!=' ')p++; if(p>=n)break;
      char mb[16]; int ml=p-ms; if(ml>15)ml=15; memcpy(mb,out+ms,ml); mb[ml]=0; int mode=strtol(mb,0,8); p++;
      while(p<n&&out[p]!=0)p++; if(p>=n)break; p++;
      if(p+20>n)break; const uint8_t*sha=out+p; p+=20;
      if(mode==040000){ tohex(sha,chex); fputs(phex,stdout); putchar(';'); fputs(chex,stdout); putchar('\n'); ne++; }
    }
  }
  fclose(I); close(b);
  fprintf(stderr,"t2ctBuild %s: trees=%lld childedges=%lld\n",argv[1],nt,ne);
  return 0;
}
