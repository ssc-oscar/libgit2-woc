# P2tips — spec for incremental, dedup-aware git fetch (avoid full clones)

Handoff from the Jetstream2 instance to the **da5 / WoC** instance. Goal: let WoC
re-fetch repos (especially 100K+-commit monorepos like linux, chromium, gecko,
llvm) **without re-downloading objects WoC already has** — i.e. drive git's
fetch negotiation with a WoC-derived `have` set instead of a local clone.

WoC keeps deduplicated objects + maps but **no repo clones and no ref tips**.
The negotiation only needs the repo's *tip* commits as `have` lines; the server
then sends only `reachable(remote tips) − reachable(haves)`. So we need a map
**P2tips: project → its tip (leaf) commits**, derived from maps WoC already has.

---

## 1. Definition

For a project/repo `R` with WoC maps
- `P2c[R]`   = the set of commit SHAs WoC has recorded for `R`
- `c2cc[c]`  = the child commits of `c` (commit→child-commits)

```
tips_R = { c ∈ P2c[R] : c2cc[c] ∩ P2c[R] = ∅ }      # leaves of R's commit DAG
```

A tip/leaf is a commit that **no commit in R descends from** — exactly the
branch/tag heads (plus any unmerged dangling tips WoC saw).

### Simplified query (the primary, leading-edge case)
For the canonical/leading-edge repos that are the main target, their heads are
**global** leaves (nobody in WoC has committed past linux's HEAD), so the
intersection collapses to a plain emptiness test:

```
tips_R = { c ∈ P2c[R] : c2cc[c] is empty }          # "anything with no child commit"
```

One `P2c[R]` read + one `c2cc` existence check per commit. For linux (~1M+
commits) that's ~1M cheap lookups — **not** a global 6B scan.

### Correctness caveat (only matters for trailing forks)
`c2cc` is **global**: a commit that is genuinely `R`'s branch tip but whose only
recorded child lives in a *sibling fork* would have non-empty `c2cc` and be
missed by the simplified test (→ under-advertised haves → some history
re-downloaded; never incorrect data, just less saving). If P2tips is ever used
for trailing forks, use the full definition (intersect `c2cc[c]` with `P2c[R]`),
or union in the fork-community's leaves. For leading-edge upstreams the simple
test is exact.

---

## 2. Inputs (resolve to the current WoC version's maps)
- `P2c`  — project → commits   (use the current version, e.g. the latest letter)
- `c2cc` — commit → child commits

Access via the standard WoC lookup tooling in `~/lookup` (the `getValues` /
`oscar`/`WoC::Get` style readers, sharded by SHA prefix). Pick the version that
matches the commit data you fetch against; tips computed against version X are
valid haves as long as X reflects the last snapshot of `R`.

---

## 3. Batch precompute (the run)
Given the list of repos to (re)fetch for a batch (millions of repos):

```
for R in repos:
    C = P2c[R]                              # one map read; may be ~1M for linux
    tips_R = [ c for c in C if c2cc[c] is empty ]      # (or ∩ C for trailing forks)
    emit  R \t  (space-joined tips_R)       # -> P2tips
```
- Parallelize across repos (SLURM array; this is embarrassingly parallel).
- `first-time` repos (`P2c[R]` empty/absent) → no tips → full fetch (correct;
  all their objects are genuinely new).
- The expensive global 6B×c2cc scan is **not** required — work is per-repo,
  bounded by `|P2c[R]|`, and only a handful of repos are huge.

## 4. Incremental maintenance (cheaper than recompute)
If P2tips is persisted, keep it current at ingest instead of recomputing — this
is the "tips become parents after each update" case:

```
on ingesting R's new commits N (e.g. the delta fetched by fetchNew):
    tips_R -= { p : p ∈ parents(c), c ∈ N, p ∈ tips_R }   # parents of new commits stop being tips
    tips_R += { c ∈ N : c2cc[c] empty within R }          # new leaves
```
`O(|N|)` per refresh — the delta you just fetched — never a full re-scan.

---

## 5. Output / interface to the consumer
P2tips can be a WoC-style map (`project → tip SHAs`) or, for a fetch run, a flat
per-repo have-list. The consumer (`fetchNew.py`, shipped alongside) only needs,
per repo, the list of have commit SHAs.

`fetchNew.py` (dependency-free, smart-HTTP **protocol v2**, this repo's
`~/bin/fetchNew.py`):
```
fetchNew.py <url> --haves-file tips_R   --out R.new      # --haves sha,.. also works
   wants = ls-refs (current remote tips)
   haves = tips_R  (from P2tips)
   NO thin-pack capability  ->  self-contained pack
   -> git index-pack into a fresh bare repo R.new  (only the NEW objects)
   prints: wants=.. haves=.. pack_bytes=.. new_objects=..
```
`R.new` is a tiny bare repo containing exactly the objects WoC lacks; feed it to
`classify | grab*` like a normal (but minimal) clone. **no-thin is essential**:
WoC has no local objects to resolve thin-pack delta bases against, so the server
must send complete objects.

Per-repo pipeline:
```
tips_R (from P2tips)  ->  fetchNew.py <url> --haves-file tips_R --out R.new
                      ->  classify R.new | grab*  ->  ingest  ->  update P2tips (§4)
```

---

## 6. Validation already done (Jetstream2, octocat/Hello-World, 3 divergent refs)
| haves supplied            | pack bytes | new objects |
|---------------------------|-----------:|------------:|
| none (cold)               |       1586 |          13 |
| HEAD only                 |        918 |           6 |
| all tips (full P2tips)    |     **32** |       **0** |

→ more WoC tips advertised ⇒ less downloaded; nothing when WoC is current. The
no-thin pack indexed standalone into an empty bare repo (confirming
self-containment). The negotiation and have-injection work; what remains is
wiring `tips_R` to the real `P2c`/`c2cc` on da5.

## 7. Next step on da5
1. Implement `tipsR` (read `P2c[R]`, filter by empty `c2cc`) against the current
   WoC maps; test on `torvalds/linux` — dump `|tips_R|` (expect a few hundred:
   branch + tag heads).
2. `fetchNew.py https://github.com/torvalds/linux --haves-file tips_linux` and
   compare `pack_bytes` / `new_objects` to a full `git clone --mirror` of linux.
3. Wire `tips_R → fetchNew → classify|grab*` and the §4 incremental update.

Files in this handoff: `P2tips.spec.md` (this), `fetchNew.py` (the client).
