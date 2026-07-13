/* t2bfBuild.c <idx> <bin>  -- sequential tree -> (blob, filename) extractor.
 * Streams <idx> (id;off;len;sha) in offset order, preads <bin>[off,len] (=> sequential access),
 * LZF-decompresses each tree, parses entries, and for every BLOB entry (a FILE: mode 100644 /
 * 100755 / 120000 symlink -- i.e. NOT a subtree 040000 and NOT a gitlink/submodule 160000) emits
 *   <this_tree_sha>;<blob_sha>;<filename>
 * (40-hex ; 40-hex ; raw name) to stdout. Sharded by PARENT TREE sha (= the tree_<sec> section).
 * One (idx,bin) pair per call (run once for base, once for gen, per section) -- see t2bfHost.sh.
 * Consumer: isaac re-shards by blob sha -> b2ptf (blob -> parent tree + filename).
 * Sequential -> HDD is fine. build: cc -O2 -o t2bfBuild t2bfBuild.c /usr/lib64/liblzf.so.1
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
extern unsigned int lzf_decompress(const void*, unsigned int, void*, unsigned int);

/* Compress::LZF decompress (byte-exact, from t2ctBuild/cmputeDiffGen) */
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
  if(argc<3){ fprintf(stderr,"usage: t2bfBuild <idx> <bin> [t2ct-complement-out]\n"); return 1; }
  FILE*I=fopen(argv[1],"r"); if(!I){ perror(argv[1]); return 2; }
  int b=open(argv[2],O_RDONLY); if(b<0){ perror(argv[2]); return 2; }
  /* optional: subtree edges with a NON-canonical tree mode (type 0040000 but not exactly 040000) --
   * these were missed by t2ctBuild's exact `mode==040000` test, so we emit them here to COMPLEMENT
   * t2ct (parent;child, appended so base+gen of a section accumulate). */
  FILE*CF = (argc>3) ? fopen(argv[3],"a") : 0;
  /* optional: entries whose type bits are NOT one of the 4 known git types (tree/file/symlink/gitlink)
   * -> parent;sha;mode;name, so their true object type can be resolved against the store (are they
   * blobs?) instead of guessed. Non-standard modes from imported/malformed trees land here. */
  FILE*UF = (argc>4) ? fopen(argv[4],"a") : 0;
  posix_fadvise(b,0,0,POSIX_FADV_SEQUENTIAL);   /* per-tree preads then hit readahead cache */
  static uint8_t cbuf[1<<26], out[1<<26];
  char *ob=malloc(1<<22); if(ob) setvbuf(stdout,ob,_IOFBF,1<<22);
  char line[256], phex[41], bhex[41], chex[41], shahex[64];
  long long id, off, nt=0, ne=0; long len;
  long long m_tree=0,m_treenc=0,m_file=0,m_exec=0,m_link=0,m_gitlink=0,m_other=0;   /* mode histogram */
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
      long ns=p; while(p<n&&out[p]!=0)p++; if(p>=n)break; long nl=p-ns; p++;   /* name = out[ns..p) */
      if(p+20>n)break; const uint8_t*sha=out+p; p+=20;
      int typ = mode & 0170000;                 /* git object TYPE bits (unix perms are the low bits) */
      if(typ==0040000){                         /* SUBTREE (any perms) */
        if(mode==040000) m_tree++;              /*  - canonical 040000: already captured by t2ct */
        else { m_treenc++;                      /*  - non-canonical (e.g. 040755): t2ct MISSED it -> complement */
          if(CF){ tohex(sha,chex); fputs(phex,CF); putc(';',CF); fputs(chex,CF); putc('\n',CF); } }
      }
      else if(typ==0100000){ if(mode==0100755) m_exec++; else m_file++; }
      else if(typ==0120000) m_link++;
      else if(typ==0160000) m_gitlink++;        /* gitlink -> a COMMIT, not a blob */
      else { m_other++;                         /* UNKNOWN type mask -> resolve via store, don't guess */
        if(UF){ tohex(sha,chex); fputs(phex,UF); putc(';',UF); fputs(chex,UF); fprintf(UF,";%06o;",mode);
          if(memchr(out+ns,'\n',nl)||memchr(out+ns,'\r',nl)){ for(long i=ns;i<ns+nl;i++){int ch=out[i];putc((ch=='\n'||ch=='\r')?'?':ch,UF);} }
          else fwrite(out+ns,1,nl,UF); putc('\n',UF); } }
      /* BLOB iff type is regular-file (0100000, any perms) or symlink (0120000). NOT tree (0040000),
       * NOT gitlink (0160000 -> a commit), NOT unknown. "not 040000" does NOT imply blob. */
      if(typ==0100000 || typ==0120000){
        tohex(sha,bhex);
        fputs(phex,stdout); putchar(';'); fputs(bhex,stdout); putchar(';');
        /* raw name; guard the line format against the (rare) newline/CR in a filename */
        if(memchr(out+ns,'\n',nl) || memchr(out+ns,'\r',nl)){
          for(long i=ns;i<ns+nl;i++){ int ch=out[i]; putchar((ch=='\n'||ch=='\r')?'?':ch); }
        } else fwrite(out+ns,1,nl,stdout);
        putchar('\n'); ne++;
      }
    }
  }
  fclose(I); close(b); if(CF) fclose(CF); if(UF) fclose(UF);
  fprintf(stderr,"t2bfBuild %s: trees=%lld blobentries=%lld | modes: file=%lld exec=%lld symlink=%lld"
          " | subtree_canonical=%lld subtree_noncanonical(t2ct-missed)=%lld gitlink=%lld other/unknown=%lld\n",
          argv[1],nt,ne,m_file,m_exec,m_link,m_tree,m_treenc,m_gitlink,m_other);
  return 0;
}
