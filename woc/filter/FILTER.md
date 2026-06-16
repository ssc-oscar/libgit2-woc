# RAM-resident membership filters for WoC object dedup

Replace per-object random lookups against the 3.3 TB `sha1.<type>_<sec>.tch`
hash DBs (on da5 `/fast`, reached over ssh by `hasObj`) with **RAM-resident
static membership filters**. Membership is the whole job (`sha → in WoC?`,
value unused), so a filter beats any KV engine.

## Why (benchmarks, da5, one shard)

| | binary-fuse | bloom | TokyoCabinet `.tch` (cached) |
|---|---|---|---|
| size (blob_0, 196.7 M keys) | **222 MB (9.01 b/key)** | 225 MB (9.59) | 9.15 GB |
| build | 186 s (C) | 222 s (numpy) | — |
| lookup | **11 M/s** (RAM, cache-miss bound) | 3 M/s | **0.038 M/s** |
| false positives | **0.39 %** | 1.82 % | exact |
| false negatives | **0** | 0 | exact |

~**290× faster lookups than even a fully page-cached `.tch`**, 0 false negatives.
Whole WoC set (~53 B objects: ~24 B blob, ~23 B tree, ~6.2 B commit) → **~63 GB
of filters** that fit in RAM (da5 has 1.26 TB; the dedup box has 122 GB).

## Use as a NEGATIVE cache (no data-loss risk)

Filters have false positives but **no false negatives**, so:
- filter says **ABSENT** → object is definitely new → **survivor** (exact, keep locally)
- filter says **PRESENT** → maybe in WoC (incl. ~0.4 % FP) → **confirm on da5**

Using a filter as the sole authority would drop ~0.4 % of new objects (data
loss); the confirm step is mandatory. With ~0.4 % FP, ≥99 % of lookups resolve
in local RAM with zero da5/network, killing both the ssh round-trips and the
96-way da5 contention.

## Source data

Build from the blob content SHAs. Robust across the **two `.idx` formats**
(`da5:/data/All.blobs/blob_<sec>.idx`): 7-field `seq;offC;lenC;len;SHA;base;off`
and 4-field `seq;off;len;SHA`. The blob sha is the **first `^[0-9a-f]{40}$`
field** (the 2nd 40-hex in the old format is the delta base — skip it). The
`.idx` is a faster source than iterating the `.tch`, works while `.tch` ingest
is underway, and is even a slight superset (~9 M blobs the `.tch` lacks).
Equivalent source: the keys of `/fast/All.sha1/sha1.blob_<sec>.tch`.

## Tools

| file | role |
|---|---|
| `binaryfusefilter.h` | vendored single-header binary-fuse8 (FastFilter, MIT) |
| `extract_sha.pl` | emit the first-40-hex sha of each `.idx` line as 20 raw bytes |
| `build_bf.c` | stdin 20-byte keys → build + serialize one binary-fuse filter |
| `build_all_blob.sh` | build all 128 blob filters from `.idx` (nice/ionice, P-way, resumable) → `/fast/blobFilters/blob_<sec>.bf` |
| `hasObjBF.c` | **negative-cache front-end (sketch)**: mmap the blob filters, stream an olist, emit definite survivors, defer "maybe present" + non-blob to da5 |
| `bench_bf.c`, `bb.py` | benchmarks (binary-fuse / bloom) used to produce the table above |

Build: `gcc -O3 -o build_bf build_bf.c -lm` (same for the others).

Filter file format: `"BF8\1"` magic, `Seed`(u64), 6×u32
(`Size,SegmentLength,SegmentLengthMask,SegmentCount,SegmentCountLength,ArrayLength`),
then `ArrayLength` fingerprint bytes — mmap'd directly by `hasObjBF`.

## Local-RAM pinning (only if running filters locally, not on da5)

Local volumes are rotational; an unpinned mmap'd filter gets evicted by the
pipeline's page-cache churn → HDD random reads (catastrophic). `pin_filters.c`
mmap+`mlock`s all `<type>_<sec>.bf` to keep them resident. Non-root `mlock` of
59 GB needs the limit raised: `sudo setcap cap_ipc_lock+ep ~/bin/pin_filters`
(per-binary capability; `ulimit -l` is otherwise capped at 8 MB and a
`limits.conf` change only reaches fresh login sessions). On **da5** none of this
is needed — its 1.26 TB RAM keeps the 59 GB page-cache-resident on its own.

## Experiment: A (local) vs B (da5) — 1 M-line olist dedup

| path | total time | da5 `.tch` lookups |
|---|---|---|
| baseline `cleanBlb \| hasObj` (da5 tch) | **346 s** | 867 K (all) |
| A — local pinned filter + da5 confirm | **12 s** | 34.5 K |
| B — da5 filter + da5 confirm | **15 s** | 34.5 K |

~**25× faster, A ≈ B**. The bottleneck was the `.tch` random reads, not the
network, so **B (run on da5) is the chosen deployment** — no mlock/eviction
fight, filters in da5 RAM. Pipe order is `… | hasObjBF | cleanBlb` (BF is
constant-memory; `cleanBlb` accumulates a unique-sha hash, so feed it the
smaller post-BF stream).

## Pitfall (fixed): 20-byte stream framing

`extract_sha.pl` MUST `chomp` before `pack("H*",...)`. The sha is the **last**
`.idx` field in the 4-field format (all commit/tree records + new blob records),
so without `chomp` its trailing `\n` makes `pack` emit **21 bytes**, misaligning
`build_bf`'s fixed 20-byte record stream → corrupted keys → ~47 % false-absent
("over-keep"). `bench_bf` self-validates against the same mis-extracted keys, so
it does **not** catch this — verify against the real tch (`hasObjBF` survivors
vs `hasObj` survivors should match, modulo small freshness). A correct shard's
key count matches the corresponding `sha1.<type>_<sec>.tch` `rnum`.

## Status / next

- All 384 filters **rebuilding** on da5 with the fixed extractor
  (`build_all_type.sh commit|blob|tree`, P=3, resumable; log `/tmp/rebuild_all.log`)
  → `/fast/{blob,commit,tree}Filters/` (~62 GB).
- After rebuild: re-copy local (if A), re-verify over-keep ≈ 0, then wire
  `hasObjBF` (3-type) into the dedup pipe, fronting the exact `hasObj` for the
  deferred maybe-present: `… | hasObjBF <dir> defer ; defer | hasObj`.
- `build_all_blob.sh` is superseded by `build_all_type.sh` (kept for reference).
