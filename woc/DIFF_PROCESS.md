# Computing commit diffs (c2fbb increments) for a new release — process

**Purpose.** For each new WoC release `V` (e.g. V2604→V2605), compute the commit-vs-parent tree
diffs for the commits added *since the previous release* `pV`. The diff output is the **c2fbb
increment** (`commit;path;newblob;oldblob|renames`), which feeds the c2fbb assemble/merge
(`roots-c2fbb-assemble.slurm`: prior `c2fbbFull.pV` + new increment → `c2fbbFull.V`).

- **KEY INPUT**  = (1) the full **object + offset setup** (base layer frozen + this release's gen
  layer, with their maps), and (2) the **per-shard `.cs`** = the commits grabbed since `pV`
  (the release delta), one gzip file per 128 sha-sections.
- **KEY OUTPUT** = per-shard `.gz` diffs (the c2fbb increment) + two exception lists extracted from
  the diff's own `.err` (no pre-processing): `cIdent` (no-change commits) and `cLarge` (abstentions).

---

## 0. Layered store & map model (get this right — see [[layered-map-architecture]])

- **Base layer is frozen in its entirety** — object bins/idx AND its maps. NEVER rebuild/delete/mix.
  - commits: CONTENT map `/fast/All.sha1c/commit_<sec>.tch` (value = stored LZF bytes).
  - trees: OFFSET map `/fast/All.sha1o/sha1.tree_<sec>.tch` (value = pack"w w",goff,len).
  - (base commit OFFSET maps also exist precomputed on da3/da4 for DiffCT.)
  - Frozen base maps are replicated on da3/da4 `/da{3,4}_fast/All.sha1o`; restore da5 from there if
    ever lost — by **copy**, never rebuild.
- **Gen layer** (`/fast/All.blobsGen/<type>_gen1/`, one per release) holds `.bin .idx .sidx .bf`.
  Its offset index is the **`sidx`** (`sidx.c`: sha20+off+len, sorted, mmap+bsearch), **created as
  objects are added** by `convert_backlog.sh`. Gen never goes into the base dirs.
- **Once a release's gen is complete+correct it is ALSO frozen** (like base). The gen MUST NOT
  contain base objects — `convgen` dedups-on-write vs the base BF; if an irregular transition bleeds
  base objects into the gen (04→05 did, ~734M), clean with `genMinusBase`/`fixGenLayer`, then rebuild
  the gen `sidx`+`bf` (`rebuildGenIndex.sh`).

## 1. Prepare the layers (once per release, on da5)

1. Ensure this release's gen is **clean** (gen ∩ base == 0). Check overlap on a section
   (`comm -12` of base vs gen shas). If significant (commit/tree 04→05 were ~50%), run
   `fixGenLayer{,Par}.sh <type>` (drops base-dups, `genMinusBase.c`) then `rebuildGenIndex.sh`
   (rebuild `sidx`+`bf` from the compacted idx). Blobs were ~0.04% → left as-is.
2. **Record release watermarks** `~/update/All.<type>.<V>` (128 lines, last LAYERED record per
   section = `globalId;globalOff;len;sha`, globalId = base_count + gen_local): `mkNewObjList.sh
   record <type> <V>` for commit, tree, blob (blob GENROOT = da8 layered dir). Do this with the
   CLEAN gen (a watermark taken over a dirty gen is wrong).

## 2. Build the per-shard `.cs` (release delta = commits since pV)

`.cs` = **base-tail ∪ gen** for `<type>=commit`, past the `pV` watermark, sorted+deduped, gzip:
`mkNewObjList.sh newlist commit <pV> <V> <outdir>` → `<pV><V>.<sec>.cs`. It is NOT just base-tail
(misses the gen) and NOT just the gen (misses the base-overflow); it is the union past `nn(pV)` in
the layered id space. Sorted by sha so the downstream merge-sort works.

## 3. Object/offset setup per host (DiffT vs DiffCT)

The diff reader resolves each sha→object via **sidx-first**: gen `sidx` (fresh) → base map. This is
what lets a host keep a stale *combined* base+gen offset tch (its gen entries are never consulted;
base entries are correct). Requires the gen be deduped so `gen sidx ∩ base == 0`.

- **da5 = DiffT**: base commits via **content** (`COMMIT_CONTENT=/fast/All.sha1c`), gen via sidx,
  trees via offset. Gen is LOCAL (`/fast/All.blobsGen`) → fastest → most parallelism.
- **da3/da4 = DiffCT**: base commits via **offset** (precomputed `/fast/All.sha1o/sha1.commit`),
  trees via offset, gen via sidx over the `/da5_fast` mount → slower → fewer streams.

## 4. Run the diffs (per shard) — NO pre-processing

`woc/runDiff.sh <sec>` (env `MAXTREE`, and `COMMIT_CONTENT` on da5):
```
zcat V<pV><V>.<sec>.cs | MAXTREE=250000 [COMMIT_CONTENT=/fast/All.sha1c] cmputeDiffGen <PREO> <BASEBIN>
    2> V<pV><V>.<sec>.err | gzip > V<pV><V>.<sec>.gz      # <- the c2fbb increment
grep '^identical trees:' .err | awk '{print $5}' | gzip > cIdentFull.V.<sec>.cs   # no-change commits
grep '^large tree:'      .err | awk '{print $5}' | gzip > cLargeFull.V.<sec>.cs   # abstentions (MAXTREE)
```
- Every category falls out of the diff's `.err` — **do not pre-filter the `.cs`.**
- **Empty-tree commits are NOT skipped** — the empty tree `4b825dc6…` is a valid sha; vs a
  non-empty parent it diffs to all-deletions. Only commits whose (non-empty) tree is genuinely
  absent from the store yield no output.
- `MAXTREE` is a cheap `rootLen` guard (root tree stored len): 250000 skips ~top 0.1% monster roots
  to `cLarge` for a separate later pass. Threshold picked from the size/depth distribution
  (`cmputeDiffGen STATS` + `distQuant.sh`; size, not depth, is the cost driver).

## 5. Distribute shards + drive

128 shards across da3(×3)/da4(×5)/da5(×7), pre-assigned by measured single-stream speed (da5 fastest,
gen-local). One shard per host to calibrate relative speed → proportional assignment → ETA. Bounded
concurrency per host (xargs -P). Outputs land in the shared `update/V2605d` on da8.

## Lessons baked in (this cycle)
- Don't confuse `rootLen<0` with "no tree": it's the empty tree (constant, unstored) or a genuine gap.
- Don't rebuild/replace/mix the frozen base maps; restore from a da3/da4 copy if lost.
- After any gen bin/idx change, rebuild the gen `sidx`+`bf` (not a tch, not in base dirs).
- Watermark/.cs are a **release delta**, unrelated to the layer split; take them over the CLEAN gen.
- NEXT transition: freeze base exactly at the version watermark, route the whole delta to the gen
  (avoids the base-overflow that forced the 04→05 gen cleanup).
