# da5 store quick-reference — READ / DIFF an object (base ∪ gen). Don't improvise.

Ground truth verified on da5, V2605 (2026-08-04). This is the canonical layout + the exact commands so
an agent does NOT reverse-engineer paths. The #1 trap is at the bottom (base-only readers miss gen).

## Base store layout (frozen, V2605) — content vs offset differs BY TYPE
| type | primary map on da5 | kind | content bin |
|---|---|---|---|
| **commit** (also tag, tkns) | `/fast/All.sha1c/commit_<sec>.tch` | **CONTENT** (sha20 → LZF bytes) | — (self-contained) |
| **tree** | `/fast/All.sha1o/sha1.tree_<sec>.tch` | **OFFSET** (sha20 → goff,len) | `/data/All.blobs/tree_<sec>.bin` |
| **blob** | `/fast/All.sha1o/sha1.blob_<sec>.tch` | **OFFSET** | base blob content NOT on `/data/All.blobs` (stub); not needed for diffs |

`<sec> = first_sha_byte % 128` (= `int(sha[:2],16) & 127`). So commits are **content** in `All.sha1c`;
trees/blobs are **offset** in `All.sha1o` → `All.blobs` bins. (da3/da4 also precompute a commit OFFSET
`sha1.commit_*.tch` — "DiffCT" mode; da5 uses commit CONTENT — "DiffT". See DIFF_PROCESS.md.)

## Gen layer (append-only, past the base watermark)
`/fast/All.blobsGen/{commit,tree}_gen1/<type>_<sec>.{bin,idx,sidx}` — `.bin` = LZF content,
`.idx` = text `id;localoff;len;sha`, `.sidx` = binary `sha20 + u64le localoff`. A reader resolves a gen
object as: find sha in `.sidx`/`.idx` → local off → read `.bin` segment → LZF-decompress. Gen offsets are
**local** (NOT grafted into base `sha1o`); the reader adds `base_size+off` internally.

## Logical DIFF of a commit — USE THE WRAPPER (gen-aware, verified)
```bash
cmputeDiff.sh <sha> [<sha>...]      # da5:~/bin ; or:  cat shalist | cmputeDiff.sh
```
Defaults baked in: `CONTENT=/fast/All.sha1c OFFT=/fast/All.sha1o BASEBIN=/data/All.blobs LAYERED=/fast/All.blobsGen`.
All three base args are required: commit content from `All.sha1c` (arg1), **tree resolved via the OFFSET
fallback** `All.sha1o`→`All.blobs` (args 2-3), gen commit/tree via `LAYERED` sidx. Output per changed
file: `commit ; new_path ; new_blob_sha ; old_path` (empty old_path = added; new_path≠old_path = rename).
Resolves base ∪ gen → works for ANY in-store commit **regardless of BF-closure membership** (the closure
is only the pre-staged fast subset; this reads the full store). `commit=0` printed ⇒ objects not in store
(fetch first). **Do NOT pass an empty dir or `/fast/All.sha1o` as arg1** — that's blob-offset only, every
commit lookup misses → `commit=0`.

## Batch diff (per-shard, version delta): use `diffRun.sh` / `runDiff.sh`
Same binary; per-sec `.cs` shalists staged. See DIFF_PROCESS.md / C2FBB_UPDATE_WORKFLOW.md.

## ⚠️ TRAP: the perl content readers are BASE-ONLY (miss gen objects)
`showCmt.perl / showTree.perl / showBlob.perl / catCmt.perl` read ONLY the base maps — a commit/tree/blob
that lives in the **gen layer** (anything past the V2605 base watermark: RT/backfill objects) returns a
FALSE "not found." Do not conclude an object is absent from a base-only reader.
- **GEN-AWARE content reader (use this, not the perl show*):** `getContent.sh <type> [-r]` (da5:~/bin,
  binary `getObjGen`). Reads `sha[;rest]` from STDIN like showCnt; resolves base∪gen. `<type>` =
  commit|tree|blob|tag|tkns. Default output `<sha>;<base64(content)>` (one safe line, even binary/multiline
  blobs — the showCnt "encode to one line" option); `-r` = raw bytes (single object, cat-style). Verified:
  a gen commit that `showCnt.perl commit` reports `no commit … in 0` IS resolved by `getContent.sh commit`.
  (blob base content isn't on da5, so `blob` resolves only from gen here; run blob content on the blob store.)
- other gen-aware paths: `cmputeDiffGenFB` (diff), `blobDump` (blob batch, offset+base∪gen).
