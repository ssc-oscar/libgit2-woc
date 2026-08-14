/* reshardSha <outprefix>  -- read hex-sha lines from stdin, split into 128 files
 * <outprefix><sec> where sec = (first sha byte) & 127 == sha[0]%128 (the WoC object-store
 * sharding used by gatherWS/cmputeDiffGen). Used to re-shard isaac's closure (which is
 * tree-sHash/FNV sharded) into the sha[0]%128 scheme the WS gather expects. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int hv(int c){ if(c>='0'&&c<='9')return c-'0'; if(c>='a'&&c<='f')return c-'a'+10; if(c>='A'&&c<='F')return c-'A'+10; return -1; }
int main(int argc,char**argv){
  if(argc<2){ fprintf(stderr,"usage: reshardSha <outprefix>  (stdin: hex-sha/line)\n"); return 1; }
  FILE*out[128]={0}; char path[1024]; static char line[4096]; long n=0,bad=0;
  while(fgets(line,sizeof line,stdin)){
    int h=hv((unsigned char)line[0]), l=hv((unsigned char)line[1]);
    if(h<0||l<0){ bad++; continue; }
    int sec=(((h<<4)|l))&127;
    if(!out[sec]){ snprintf(path,sizeof path,"%s%d",argv[1],sec); out[sec]=fopen(path,"w"); if(!out[sec]){ perror(path); return 2; } }
    fputs(line,out[sec]); n++;
  }
  for(int i=0;i<128;i++) if(out[i]) fclose(out[i]);
  fprintf(stderr,"reshardSha: wrote %ld shas, skipped %ld\n", n, bad);
  return 0;
}
