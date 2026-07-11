# Layered content store — bounded L1 + rotation

Replace per-ingest mutation of the multi-TB WoC section shards with an
**immutable base + a bounded, append-only L1 overlay that rotates into frozen
generations under disk pressure**. Result: near-instant ingest, an immutable base
(a bad update can't harm the ~3 PB store), a **bounded file count**, and a store
that is finally **incrementally rsync-backable**.

Status: core mechanics prototyped (`overlay_proto.py`, validated on a `tree_0`
slice — byte-exact reads across segment boundaries, frozen sorted indexes,
hardlinked incremental backups). `layered.py` implements ingest/rotate/read.

## Problem with the current store
Per section/type: `{blob,tree,commit}_<sec>.bin` (LZF objects concatenated) +
`.idx` (`id;offset;len;sha`), read via `seek(off);read(len);decompress`; `sec =
sha[0..1] % 128`. A blob section is **> 3 TB**. Ingest (`AllUpdateObj`) appends new
objects and updates that section's index **object-by-object**. Pains: (1) updating
a multi-GB index for a 3 TB shard every ingest is slow and `.tch`-corruption-prone;
(2) mutating a 3 TB canonical file is risky; (3) it's **backup-hostile** — appending
forces a full re-scan, and `.tch` updates scatter throughout → near-full re-transfer
per ingest. That's a big reason the store is effectively un-backed-up.

## Layers
Per `(type, sec)` there are three layers; a read is **BF → L1 → frozen gens → base**:

- **base** — the current section shard `{type}_{sec}.bin/.idx`, **frozen** (gen 0).
  Lives on da5. Never mutated except by (rare) compaction.
- **frozen generations** `gen<N>/{type}_{sec}.bin` + `.sidx` — immutable; created by
  rotating the L1. Archived to da8.
- **L1** `L1/{type}_{sec}.bin` (append-only) + a per-sec index — the single active
  overlay every ingest appends into. **Bounded** (see rotation).

Addressing is **per-layer**: the index value is `(layer, offset, len)`; each layer's
`.bin` has its own offset space. (Within one layer the offsets are contiguous; no
global continuous-offset needed once there are multiple layers/gens.)

## A generation is a version (lifecycle)
Each frozen generation **is one collection version** (e.g. `V2605`) — the gen chain
mirrors the version watermark chain (base/gen 0 = all prior frozen versions). Its
lifecycle:
- **Collecting (live):** while version `V` is being grabbed, its gen **grows
  append-only** — new objects, already exact-deduped by `convgen` against
  base+existing-gen before they are written, are appended as chunks arrive from
  clone0. Existing objects never move, so every offset already handed out stays valid.
- **Complete (frozen):** when `V` is declared done, its gen is **frozen** — immutable
  thereafter, exactly like the base. It then folds into the frozen set for `V+1`.

**Reading sha→object is LAYERED, not a combined/extended map** (corrected 2026-07-10 — see
`DIFF_PROCESS.md`, [[layered-map-architecture]]). Each layer keeps its OWN index and the reader
consults them in order:
- **base (frozen):** commit CONTENT `/fast/All.sha1c`, tree/commit OFFSET `/fast/All.sha1o`.
- **gen:** the per-shard **`.sidx`** inside `gen<N>/` (sha20+off+len, `sidx.c`), **created as
  objects are added** by `convert_backlog.sh`. This IS the gen offset index.
- The read tool (`cmputeDiffGen`) does **sidx-first**: gen `.sidx` (fresh) → base map. So a stale
  *combined* base+gen offset tch on some host is harmless (its gen entries are never consulted);
  base objects miss the sidx and fall to the correct base map. Requires the gen be deduped so
  `gen ∩ base == 0`.
- The old `{Cmt,Tree}N2OffGen` "extend a combined `sha1.<type>_<sec>.tch` in place" path is NOT used
  by the diff reader and goes STALE if a gen is ever compacted — do not rely on it.
Invariants: **never rewrite/compact a frozen segment** (offsets above shift); if you must compact a
gen (e.g. remove base-dups, `genMinusBase`), **rebuild that gen's `.sidx`+`.bf`** (`rebuildGenIndex.sh`)
and take fresh watermarks. Never rebuild/mix the frozen BASE maps — restore from a da3/da4 copy if lost.

## BF dedup vs. the gen lifecycle (release-completion rebuild)
The grab-time dedup gate (`hasObjBF` over `/fast/<type>Filters`, see `lookup/FILTER.md`)
is built from the **frozen** set and is **static** (binary-fuse can't be appended to).
It is **not** rebuilt mid-version: storage-correctness dedup is guaranteed at **append
time** by `convgen`'s exact `.sidx`/`.idx` lookup, so a stale grab BF only risks
**re-fetching** an object already in the live gen — `convgen` drops it before append,
never duplicating it in the store (and binary-fuse's 0 false negatives mean a needed
object is never skipped, only pushed to the exact `hasObj` stage). So **rebuilding the
BF is a release-completion action**: when `V`'s gen freezes, fold it into the frozen
set and rebuild the affected `{type}` filters (`build_all_type.sh`, after removing the
old `.bf`) so the next version's grab dedups against it.

## Grab-server topology (where things live, and rotation)
Work happens on the **grab server** (clone0), which has limited disk:
1. Grab **hash-splits** objects by `sec` (it already computes `sec` — `.idx` field 3)
   and the ingest **appends** each batch's sec-slice into the local `L1/{type}_{sec}.bin`
   (+ per-sec index). Per-batch sec files are transient — consumed into L1.
2. **Rotation is triggered by local disk pressure** (L1 size / free space): when the
   grab server fills, **freeze the current L1** (per sec: the `.bin` + a frozen sorted
   `.sidx`) into `gen<N>`, **move it to da8**, and start a fresh empty L1.
3. **Compaction** (rare, offline): fold gens (+ L1) into a **new base generation** per
   sec, rebuild the base index once, drop the old layers. Produces a fresh immutable
   base, backed up once.

So **generations are rotated by space, not per batch** — that keeps the file count
bounded: ~512 base files (128 secs × 4 types × {bin,idx}) + ~512 L1 + a handful of
rotated gens between compactions. **Constant-ish, independent of batch count** — vs.
the 512 × (#batches) explosion a file-per-batch scheme would cause.

## Ingest = demux + append (near-instant, base untouched)
Per batch, per type: read the batch `.idx` (`offset;len;sec;sha`), and for each
object append its bytes (from the batch `.bin`) onto `L1/{type}_{sec}.bin`, recording
`sha → (L1, new_offset, len)` in the per-sec L1 index. No base touched, no per-object
index churn against a 3 TB file. This **doubles as the converter for the un-split da8
batches** — their `.bin` is sec-interleaved, but the `.idx` already carries `sec`, so
the demux is a single sequential pass per batch.

## Safety
base `.bin`/index and all frozen gens are immutable. A failed/garbled ingest can only
damage the current L1, which is rebuildable from the batch. The 3 PB base is never at
risk — "if something goes wrong, it's only a problem with the update."

## Backup
- **base** frozen → rsync skips it (and it's on da5);
- **frozen gens** immutable → `--link-dest` hardlinks them on da8;
- **L1** append-only → `rsync --append` ships only the grown tail.

Prototype (`overlay_proto.py`, `tree_0` slice): incremental snapshot after adding a
new segment shipped **only the new segment** (259 MB), base + prior gen hardlinked.
NB: a *single growing LMDB* index defeats this (pre-alloc + COW), so frozen gens use
a **sorted `.sidx`** (`sha[20] | offset[u64] | len[u32]`, bsearch); the L1's active
index may be LMDB (fast appends) but is frozen to a `.sidx` on rotation.

### Operational backup — per-type gen (V2605+), how-to
The base is already backed up and immutable, so back up **only** the `*_gen1/` dirs (+ optionally
the offset maps). Locations: commit/tree gens on **da5** `/fast/All.blobsGen/{commit,tree}_gen1`;
blob gen on **da8** `/mnt/ordos/data/data/layered/V2605/blob_gen1`; offset maps on **da5**
`/fast/All.sha1o/sha1.{commit,tree,blob}_<sec>.tch`.

- **Essential per sec 0–127:** `<type>_<sec>.{bin,idx}` — the actual gen data, NOT reproducible
  without re-grabbing.
- **Regenerable (skip if space-tight):** `.sidx` (`sidx build`), `.bf` (`build_bf`), and the offset
  `sha1.<type>_<sec>.tch` (`{Cmt,Tree,Blob}N2OffGen`) — all rebuildable from `.bin`+`.idx`.
- **Back up a type ONLY when its convgen/offset run is QUIESCENT for that type.** A mid-append
  snapshot can catch a torn `.bin`/`.idx` tail (bin+idx grow together but the tail may be partial).
  So: commit when its offsets are done; tree after `TreeN2OffGen` finishes; blob only after its
  convgen completes (it appends in RAM-bounded sec-bands, so mid-run there are partially-filled secs).
- **Append-only ⇒ re-running the same `rsync -a` later is incremental** (only grown bytes transfer) —
  cheap to keep the backup in sync after each increment.
- Commands (point `$BK` at the same target as the base backup):
  ```
  rsync -a /fast/All.blobsGen/commit_gen1/  $BK/V2605/commit_gen1/            # da5, quiescent
  rsync -a /fast/All.blobsGen/tree_gen1/    $BK/V2605/tree_gen1/              # da5, after offsets
  rsync -a da8:/mnt/ordos/data/data/layered/V2605/blob_gen1/  $BK/V2605/blob_gen1/   # after blob convgen done
  rsync -a /fast/All.sha1o/sha1.{commit,tree,blob}_*.tch  $BK/V2605/sha1o/    # optional (derivable)
  ```
- **Verify:** 128/128 `.bin`/`.idx` (and `.sidx`/`.bf`) per type; `convgen.log`'s `distinct stored`
  ≈ Σ `wc -l` of the per-sec idxs.
- **CAUTION (concurrent producers):** isaac/da5 may `rclone`/publish from the same gen dirs (e.g.
  isaac rclones the commit gen for c2dat/tips) — coordinate the backup window with them; `rsync -a`
  of an append-only dir during a concurrent read is safe, but don't back up mid-**write**.

## Read amplification & tuning
A read may consult L1 + a few gens before the base; the BF short-circuits negatives
and the L1/gen indexes are small/RAM-resident. Compaction bounds gen count. Applies
to blobs, trees, and commits alike.

## Coordination
Multiple producers (full-clone batches + the real-time track) append to the same L1
files → serialize per sec (a single ingest writer / per-sec lock / ingest queue),
which is also where the BF/dedup check lives.

## Tools (`woc/`)
The converter + offset index are now **C** (match the `grabGitI`/`hasObjBF`/`build_bf`
stack; the hot read/ingest paths run at mmap speed). The Python files remain as the
validated reference spec.

- `convgen.c` — converter: folds an un-split grab batch (`offset;lenC;sec;sha;…` `.idx`
  + LZF `.bin`) into per-sec `{type}_<sec>.{bin,idx}` in the **existing store format**
  (`id;offset;len;sha`) by copying the compressed slices **verbatim** (no recompress).
  Appends onto an existing shard (seeds `offset` from `.bin` size, `id` from the idx
  tail — O(1)) or starts a fresh generation. Base never mutated.
- `sidx.c` — frozen sorted offset index `sha[20]|off[u64]|len[u32]` (`build` / `get`,
  mmap+bsearch). Dependency-free and immutable → backup-friendly, can't corrupt. For a
  write-once frozen gen this **replaces a per-gen tch/LMDB** (LMDB's crash-safe
  concurrent write only matters for the live L1, which stays on clone0; da5 has no
  `lmdb.h`/py-lmdb anyway).
- `convgen_after.sh` — driver: phase 1 appends all batches (`convgen`), phase 2 builds
  `.sidx` + `.bf` **once per touched sec** from the final `.idx` (not per batch).
- `verify.pl` — reads sampled records back through the production `Compress::LZF` and
  recomputes the git sha (the correctness gate).
- `layered.py`, `overlay_proto.py` — Python reference spec (ingest/rotate/read,
  segment/backup mechanics) validated on a `tree_0` slice.

**Validated** (real `commit_0` 300k-object slice + a real 559k-object batch): append
preserves all base objects and adds new ones byte-exact; `convgen` ≈ I/O-bound
(285 MB / 559k objs in 1.7 s); every base/appended/fresh-gen record decompresses and
git-sha-matches; `sidx get` matches the authoritative `.idx` (0 miss / 0 mismatch);
`.bf` membership has 0 false negatives. Dedup note: da8 batches are already
BF-deduped **at grab time**, so the converter is append-only by default; BF-only
dedup at append is unsafe (BF's ~0.4 % false positives would drop real objects), so
any residual dedup must use an **exact** `.sidx` lookup, not the BF.

## Migration sketch
1. Freeze current section shards as gen 0 (no file change); they stay on da5.
2. New grabs hash-split by sec and **append into L1** on the grab server.
3. Rotate L1 → frozen gen and **move to da8** when the grab server fills.
4. Run the **converter (`layered.py ingest`)** over the already-copied-but-un-ingested
   da8 batches (commits 080+, trees 040+, all blobs) to fold them into L1/gens.
5. Schedule compaction to fold gens into a fresh base; enable `--append`/`--link-dest`
   backups — now feasible.

All prototype/impl work is on copies; the live base is read-only and `AllUpdateObj`
is never run.
