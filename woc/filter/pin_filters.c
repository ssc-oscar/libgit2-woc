// pin_filters.c <dir> -- mmap+mlock all <type>_<sec>.bf so hasObjBF's mmap hits
// resident RAM, not HDD. Holds them locked until killed.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: pin_filters <dir>\n"); return 2; }
  const char *types[3] = {"blob","commit","tree"};
  long total = 0; int n = 0;
  for (int t = 0; t < 3; t++) for (int s = 0; s < 128; s++) {
    char p[512]; snprintf(p, sizeof p, "%s/%s_%d.bf", argv[1], types[t], s);
    int fd = open(p, O_RDONLY); if (fd < 0) continue;
    struct stat st; fstat(fd, &st);
    void *m = mmap(NULL, st.st_size, PROT_READ, MAP_SHARED|MAP_POPULATE, fd, 0);
    close(fd); if (m == MAP_FAILED) continue;
    if (mlock(m, st.st_size) == 0) { total += st.st_size; n++; }
  }
  fprintf(stderr, "pinned %d files, %.1f GB resident\n", n, total/1e9);
  pause(); return 0;
}
