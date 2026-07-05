# Building the standalone gen tools (convgen / sidx / build_bf)

These are dependency-light C tools (no libgit2 link needed) used by `convert_backlog.sh` to
build the layered-store generations + indexes. Build them natively wherever they run:

```
gcc -O2 -o convgen  convgen.c
gcc -O2 -o sidx     sidx.c
gcc -O2 -o build_bf build_bf.c -lm      # needs libm (log)
```
`build_bf` also needs the vendored `binaryfusefilter.h` (in this dir). `extract_sha.pl` is Perl.

## Where they run
- **da8** (build side, near update/ landing): historically built into `/tmp/conv` (ad-hoc — prefer
  building in this checkout).
- **da5** (read side): build in the shared-`/home` checkout `~audris/swsc/libgit2-woc/woc`
  (da cluster shares `/home`, so one build is visible to da5/da8). RHEL 9.7; the tools are glibc-
  portable (da8's Ubuntu-built binaries also run on da5, but native build is cleaner).

## Gen build→read run (see coord/clone0/mount-layout.md for the full pipeline)
On da5, append V2605 <=141 into the read-side gens and index them:
```
cd ~audris/swsc/libgit2-woc/woc
UPDATE_DIR=/da8_data/update/V2605 GEN_ROOT=/fast/All.blobsGen BIN=$PWD \
  GATE_SKIP=1 EXCLUDE=$(seq -s, 142 159) ./convert_backlog.sh commit 0
# then offsets:  LAYERED=/fast/All.blobsGen ~/lookup/CmtN2OffGen.perl <sec>   # 0..127
```
