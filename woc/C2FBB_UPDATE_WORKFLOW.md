# Incremental c2fbb update workflow (per new version V<N>)

Produces the per-section **c2fbb increment** (`commit;path;newblob;oldblob` per changed file) for the
delta V<N−1> → V<N>, correctly and with offender repos excluded. Debugged Jul 2026 (V2604→V2605).
Two execution modes: **da5** (has the store; offset + gen-sidx fallback) and **other servers**
(clone0/da3/da4; content-only, fed a shipped `.tch` extract).

TL;DR data flow:
```
new commits (.cs delta) + parents (parentsFP)
   └─ filter offender commits (from olist)                → clean .cs
        └─ BFS tree closure over the clean set (isaac)     → closure.<sec>.gz
             └─ build content .tch (commits∪parents, trees) → commit_<sec>.tch, tree_<sec>.tch
                  └─ run diff:  da5 (offset+gensidx)  |  elsewhere (content-only)  → diff.<sec>.gz → da8
```

---

## Inputs (per version, produced upstream by isaac + the grab)
| input | what | location |
|---|---|---|
| `V<N-1>V<N>.<sec>.cs` | delta commit shas (new since prior version), gz, sharded by `commit_sha[0]%128` | `da8:update/V<N>d/` |
| `parentsFP.<sec>.gz`  | **parent** commit shas of the delta (sharded by `parent_sha[0]%128`) — the completeness gate | `da8:update/V<N>d/` |
| `closure.<sec>.gz`    | BFS tree closure the diff reads (child + parent-side trees), sha[0]%128-sharded | isaac → `da5:/fast/closure2/` |
| `offenders`           | offender repo list (`mangled;flag;date;reason`), ~25k rows | `/media/volume/trees/offenders` |
| `list202605.V26051.<NNN>` + `New*.olist.gz` | grab repo lists (mangled) + per-object `repo;type;sha` olists | `da8:update/V<N>/` |
| base store            | `da5:/data/All.blobs` (bins) + `/fast/All.sha1o` (tree offsets, **base-only**) + `/fast/All.sha1c` (commit content) | da5 |
| gen store             | `da5:/fast/All.blobsGen/{tree,commit}_gen1/*.{bin,sidx,bf}` (gen index = **sidx**, offsets LOCAL) | da5 |

---

## Steps

### 1. New commits + parents
Delta commits = the `.cs`. Their parents = `parentsFP.<sec>.gz`. Both are needed as **content** so the
diff can read each commit's tree + parent pointer, and each parent's tree.

### 2. Filter offender commits  (offenders are excluded at the COMMIT level, not tree)
Offender-repo commits must not be diffed (commit-bombs = ~20% of the delta = spam).
- `offenderObjs`/`offCommits.sh` (da8): for each grab batch, `grepField.perl -n offenders.gz` the
  mangled repo list `list202605.V26051.<NNN>` → line# → **16-slice** `MM` (each list splits into 16
  equal pieces → second index 00..15) → read only `New*.<NNN>.<MM>.olist.gz` → keep `type==commit`
  rows of offender repos → `offender_commits.txt`. (Only ~901/25k offenders were actually grabbed;
  the rest = excluded-upfront megacluster, nothing in the store.)
- `filterCS.sh` (da8): shard `offender_commits` by `sha[0]%128`, then `comm -23 (sorted .cs) offenders`
  → **clean `.cs`** in `da8:update/V<N>d/clean/`.
- Result V2605: removed 176 M offender commits (1.44 B → 1.26 B clean).

### 3. BFS tree closure
Use isaac's `closure.<sec>.gz` (trees reachable by walking each clean-delta commit's tree diff vs its
parent, both sides). This IS the tree set; do not harvest from diff logs.

### 4. Build content `.tch` for distribution
Two content sets, both **LZF-valued** (so `getContent` in the reader decompresses correctly):
- **commits**: `commitExtract <shalist=.cs∪parentsFP> <All.sha1c> <All.blobsGen> <outdir>` → `commit_<sec>.tch`
  (base commits copied raw from `All.sha1c`; gen commits read raw from `commit_gen1` bin via its sidx).
  **Gate:** `parentsFP.<sec> ⊆ commit_<sec>.tch` (V2605: 752/10.7 M missing = offenders, OK).
- **trees**: stage the closure → `tree_<sec>.tch` via `gatherWS` (`stageWS.sh`; gen via sidx, base via
  clean `sha1o`→`/data` bin). Offender/absent trees just don't stage (filtered anyway).
- Both are **global** (all 128 of each type) — a commit's parent/tree can land in any section.

### 5. Run the diff — two modes of the SAME binary `cmputeDiffGenFB`
- **da5 (store-resident):** `cmputeDiffGenFB <treeContentDir> <offTchDir=/fast/All.sha1o> <baseBin=/data/All.blobs>`
  `LAYERED=/fast/All.blobsGen` — `HAVEFB=1`. Resolves: content subset → base `sha1o` → **gen `sidx`**.
- **other servers (content-only):** `cmputeDiffGenFB <contentDir>` (1 arg) — `HAVEFB=0`, pure
  `getContent` from `contentDir/{tree,commit}_<sec>.tch`. Ship both `.tch` sets to the host first.
- Driver: `diffRun.sh` (loops 0..127, PAR-parallel, resumable via `diff.<sec>.done`). Output
  `diff.<sec>.gz` → drain to `da8:update/V<N>d/diffs/` (`drainDiffs.sh`) for isaac to assemble.

---

## Critical fixes / gotchas (the debugging lessons)
1. **Base offset tch must be base-only.** The `*N2OffGen` graft that put gen offsets into
   `sha1.<type>_<sec>.tch` breaks any base-bin-only reader (a gen sha there carries a *global* offset
   that misreads against the base bin). Rebuild base-only from `<type>_<sec>.idx` with `idx2offtch`
   (BER `off,len`, `bnum≈records` to avoid O(chain) tail; verify `records==idx`). Applies to **da5
   tree offsets** and **da3/da4 commit offsets** (da3/da4 are copies of each other — copy, don't rebuild).
2. **…but the diff reader then needs the gen `sidx`.** `cmputeDiffGenFB` resolved gen (deep parent)
   trees through those grafted offsets. After cleaning, add a **gen-sidx tier** to `getObj` (binary
   search `<type>_gen1/<type>_<sec>.sidx`, LOCAL off → global `base_size+off` → `readObj` gen segment).
   Without it: ~97% empty `oldblob`; with it: normal (~40–65% populated).
3. **The extract is commits + parents, not just trees.** `getCT`→`getObj(commit)` is called for the
   delta commit AND its parent. `commit_<sec>.tch` must hold **`.cs ∪ parentsFP`**, gated by `parentsFP`.
4. **Offenders excluded by COMMIT** (via olist `repo;type;sha`), not by tree — a grabbed offender's
   trees exist, so only dropping its commits keeps them out of the diff.
5. **Missing trees = offenders.** WoC clone `--mirror`s, so any tree absent from base+gen is an
   offender repo (excluded at grab) — not a coverage gap; never "backfill trees" for it.
6. **Store-resident mode needs `RLIMIT_NOFILE` raised** (fixed `f63107096`). `HAVEFB=1` caches an fd
   per (type,section) for content-tch + offset-tch + `sidx` + base-bin + gen-bins ≈ **1400 fds** (128
   sec × 2 types); the default `ulimit -n` **1024** is exceeded partway through, after which `open()`
   returns **EMFILE**, which `gen_lookup`/`build_segs` couldn't tell from "absent" → **silent `no
   parent`** (~44% of gen commits dropped, *masquerading as never-ingested*). Fix: `setrlimit(NOFILE,
   hard_max)` in `main()`; EMFILE→`exit(3)` (loud, not silent). **Content-only (`HAVEFB=0`) opens only
   ~256 tch fds → immune.** Diagnostic tell: "missing" fraction large + systematic ⇒ check fd/ulimit,
   not the data (the gen `sidx` off is correct: u64le, local-to-gen-bin, `goff=off+base_size`; gen bin
   is WoC-framed LZF via `clzf`). Cross-check content-only vs store-resident output to catch it.
7. **`getCT` must bound the `parent[]` append** (fixed `66f0ca6db`). A malformed/bomb object (e.g. an
   ~11 MB blob mis-stored as a commit) can decompress to content with **>512 lines starting `"parent "`**;
   `getCT` appended each into the caller's fixed `parent[40*512+1]` with no bound → BSS overflow →
   **SIGSEGV** (only under `-O2`; `-O0` dodged it via `clzf` returning −1, so it's optimization-sensitive
   UB). Only sections containing such a bomb crashed (rc=139, `.gz.tmp` left, no `.done`). Fix: cap at
   `pl+40<=40*512`. Debug tip: no gdb/ASan on da5 → `LD_PRELOAD=/lib64/libSegFault.so` + `addr2line`.
8. **`diffRun.sh` PAR = queue depth (~64), NOT core count.** The content-only diff is random-read
   I/O-bound — workers sit in D-state (`filemap_update_page`) at QD1 each; throughput ≈ workers ×
   per-worker-IOPS. Measured (da3 4×SATA SSD, O_DIRECT randread): QD1 8k IOPS → 8-way 63k → **64-way
   235k IOPS**. QD1 is identical across da3/da5, so a "slow" host is usually **under-parallelized, not
   slow hardware** (da3 at PAR=8 → ~91 h for 43 sec; PAR=64 → ~25 h). Run PAR≈64 on **every** host,
   few-core boxes included (D-state workers don't need cores). Verify per host with an O_DIRECT randread
   scaling test. This is why the even 3-way split needs equal PAR, not PAR=cores, to balance.

---

## Tool inventory (all in `libgit2-woc/woc/`, built on da5 `/da5_fast/bin`)
| tool | role |
|---|---|
| `cmputeDiffGenFB` | the diff; 3-arg (da5 offset+gensidx) / 1-arg (content-only) |
| `commitExtract`   | build `commit_<sec>.tch` from `.cs∪parentsFP` (base tch + gen sidx, raw LZF) |
| `gatherWS`/`stageWS.sh` | stage the tree closure → `tree_<sec>.tch` |
| `idx2offtch`      | rebuild base-only offset tch from `<type>_<sec>.idx` (BER off,len) |
| `tchmiss`/`tchkeys` | membership / key dump for gates & audits |
| `offCommits.sh` + `grepField.perl` | offender commits from olist via list 16-slice |
| `filterCS.sh`     | remove offender commits from `.cs` (comm -23) |
| `diffRun.sh` / `drainDiffs.sh` | run 128 sections / drain output to da8 |
| `boundaryTest`    | verify base/gen bin seam (last-base ↔ first-gen) |

## Per-version checklist
- [ ] `.cs`, `parentsFP`, `closure` present on da8/da5 for V<N>
- [ ] offset tch base-only on da5(tree)+da3/da4(commit) (`idx2offtch`, verified)
- [ ] `cmputeDiffGenFB` has the gen-sidx tier
- [ ] offender_commits built → clean `.cs`
- [ ] commit extract + `parentsFP` gate pass; tree closure staged
- [ ] diff run (da5 and/or distributed) → drained to da8 → isaac assembles c2fbb
