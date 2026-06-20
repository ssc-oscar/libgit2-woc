# Layered (generational) content store for the full-clone pipeline

A design to replace per-ingest mutation of the multi-TB WoC content shards with an
**immutable base + append-only generations** in a continuous offset space. It makes
ingest near-instant, keeps the base un-mutable (so a failed update can never harm
it), and — for the first time — makes the ~3 PB store **incrementally rsync-backable**.

Status: **prototype validated** (`/media/volume/trees/ovp_proto/overlay_proto.py`,
on a 2.5 GB slice of `tree_0`, read-only on the live base). Not yet productized.

## Problem with the current store
Per shard/type: `{blob,tree,commit}_<sec>.bin` (LZF objects concatenated) + `.idx`
(`id;offset;len;sha`) read via `seek(offset);read(len);decompress`. A blob shard is
**> 3 TB**. Ingest (`AllUpdateObj`) appends new objects and updates the index
**object-by-object**. Three pains:
1. **Index update is slow & fragile** — inserting into a multi-GB TokyoCabinet/`.idx`
   for a 3 TB shard on every ingest; `.tch` is corruption-prone under heavy update.
2. **Mutating a 3 TB file is risky** — a bad ingest can damage the canonical store.
3. **Backup-hostile** — appending to a 3 TB `.bin` forces rsync to re-scan the whole
   file; the `.tch` scatters changes throughout → near-full re-transfer per ingest.
   This is a big reason the store is effectively un-backed-up.

## Design: immutable base + frozen generations, continuous offset space
- **Content = immutable segments.** The current shards are *generation 0* (frozen).
  Each ingest's new objects become a **new generation** `*_<sec>.bin.gen<N>` — or,
  cheapest, **the grab's own `.bin` files just *become* generations** (no rewrite).
- **Continuous global offset.** `global_off = cumulative_segment_base + relative_off`.
  A small `segments.json` lists `(name, bin, base, size)`; a read finds the segment
  with `base ≤ goff < base+size` and `seek(goff − base)`. Generalizes to N segments;
  for one new layer it is exactly "if `goff ≥ old_size`, use the new file."
- **Index = the only new artifact, and it is FROZEN per generation.** Each generation
  gets its own immutable index — a sorted `sha[20] | global_off[u64] | len[u32]`
  file (`.sidx`, bsearch) — built once, never updated. (A *frozen* per-gen LMDB works
  too; a single *growing* LMDB does NOT — see "Backup".) The **base index stays
  frozen**; new objects only ever touch the newest gen's index.
- **Lookup / `hasObj`:** **BF (negative cache) → gen indexes (newest→oldest) → base.**
  A sha lives in exactly one generation; its `global_off` routes the read to the
  right segment.

## Ingest = register + batch (near-instant)
Per ingest: write the new segment (or adopt the grab `.bin`), build its frozen
`.sidx` (one sort + batched write), append one line to `segments.json`. **No base
touched, no per-object work.** Prototype: **564,962 index recs in 1.1 s (~508 k/s)**;
base `.bin` and base index mtimes unchanged.

## Safety
The base `.bin` *and* base index are immutable. A failed / garbled ingest can only
damage the newest generation + its index, both of which are re-buildable from the
grab. The 3 PB base is **never at risk** — "if something goes wrong, it's only a
problem with the update."

## Backup (the big win)
Every generation (content **and** index) is append-only / immutable:
- plain incremental rsync **skips all frozen segments** (size+mtime unchanged) and
  ships only the newest generation;
- `--link-dest` snapshots **hardlink every old generation at zero extra space**.

Prototype, 3-segment store (base 2.0 GB + gen1 0.25 GB + gen2 0.25 GB):
- first backup = 2.31 GB; **incremental snapshot after adding gen2 = 259 MB literal**
  (just gen2.bin + gen2.sidx + manifest); `base.bin` & `gen1.bin` hardlinked.

NB: a **single growing LMDB index defeats this** — `writemap` pre-allocates `map_size`
and COW-updates pages throughout, so it re-transfers per ingest. Hence the index must
be **frozen per generation** (sorted `.sidx`, or a frozen small LMDB per gen).

## Compaction (rare, controlled)
When generations accumulate (read amplification, or scheduled), merge them into a
**fresh base generation** + one index rebuild, then drop the old ones. It is a
copy-on-write file swap → a new immutable artifact, backed up once. Off-line and
controlled — never an in-place mutation of a live 3 TB shard.

## Read amplification & tuning
A read may bsearch several gen indexes before hitting. Mitigated by: the BF
short-circuiting negatives, RAM-resident gen indexes (small), and compaction bounding
the gen count. Apply to **blobs, trees, and commits** alike.

## Relation to the real-time track
Same pattern as the real-time LMDB commit store (`commit_store.py`): immutable
content + an index over a frozen base. The layered store is its full-clone analogue;
both can eventually share the BF-as-oracle + eviction loop.

## Verified prototype (reproduce)
`/media/volume/trees/ovp_proto/` — `overlay_proto.py`:
- `mksidx <idx> <sidx>` build a frozen sorted index; `stats`; `read|md5 <sha>…`.
Reads were verified **byte-identical to the live `tree_0`** across both segment
boundaries (base|gen1 and gen1|gen2). All prototype work was on a copy; the live
base shards were read-only throughout.

## Migration sketch
1. Freeze current shards as generation 0 (no change to files).
2. Point new grabs at new generations (the grab `.bin` becomes a gen; build its
   `.sidx`); extend the reader to N segments + BF→gen→base lookup.
3. Schedule compaction (e.g. monthly) to fold gens into a new base generation.
4. Enable incremental rsync/`--link-dest` backups — now feasible.
