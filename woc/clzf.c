/* clzf.c -- decompress Compress::LZF output (matches Compress::LZF::decompress).
 * Format: byte0==0x00 -> stored (raw = rest); else UTF-8-encoded uncompressed
 * length header + standard liblzf stream. Reads stdin (one object), writes plain.
 * build: cc -O2 -o clzf clzf.c -llzf  */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
extern unsigned int lzf_decompress(const void*, unsigned int, void*, unsigned int);
int main(void){
  static unsigned char in[1<<28]; size_t n=fread(in,1,sizeof in,stdin);
  if(n==0) return 0;
  if(in[0]==0){ fwrite(in+1,1,n-1,stdout); return 0; }              /* stored */
  unsigned long us=0; size_t p=0; unsigned char c=in[p++];
  if(c<0x80) us=c;
  else if((c&0xe0)==0xc0){ us=(c&0x1f)<<6; us|=in[p++]&0x3f; }
  else if((c&0xf0)==0xe0){ us=(c&0x0f)<<12; us|=(in[p++]&0x3f)<<6; us|=in[p++]&0x3f; }
  else if((c&0xf8)==0xf0){ us=(unsigned long)(c&0x07)<<18; us|=(in[p++]&0x3f)<<12; us|=(in[p++]&0x3f)<<6; us|=in[p++]&0x3f; }
  else if((c&0xfc)==0xf8){ us=(unsigned long)(c&0x03)<<24; us|=(unsigned long)(in[p++]&0x3f)<<18; us|=(in[p++]&0x3f)<<12; us|=(in[p++]&0x3f)<<6; us|=in[p++]&0x3f; }
  else { us=(unsigned long)(c&0x01)<<30; us|=(unsigned long)(in[p++]&0x3f)<<24; us|=(unsigned long)(in[p++]&0x3f)<<18; us|=(in[p++]&0x3f)<<12; us|=(in[p++]&0x3f)<<6; us|=in[p++]&0x3f; }
  unsigned char *out=malloc(us+1);
  unsigned int r=lzf_decompress(in+p, n-p, out, us);
  if(r!=us){ fprintf(stderr,"clzf: decompress mismatch r=%u us=%lu\n",r,us); return 1; }
  fwrite(out,1,r,stdout); return 0;
}
