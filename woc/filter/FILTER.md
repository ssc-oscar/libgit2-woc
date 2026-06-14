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

## Status / next

- Blob filters: building all 128 on da5 → `/fast/blobFilters/` (~28 GB).
- Trees: build from `/data/All.blobs/tree_<sec>.idx` once da5 ingest settles
  (`.tch` are mid-write); same extractor/builder.
- Wire `hasObjBF` into the dedup pipe (front the existing `ssh da5 hasObj`):
  `hasObjBF <dir> defer.gz < olist > survivors; pigz -dc defer.gz | ssh da5 hasObj >> survivors`.
