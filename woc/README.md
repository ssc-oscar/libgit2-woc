# WoC object-extraction tools

Custom command-line tools that enumerate and extract raw git objects from
bare repositories, used by the World of Code (WoC) data pipeline. They are
built against this in-tree libgit2 (target `libgit2package`) and installed
alongside it.

Built by default; disable with `-DBUILD_WOC=OFF`.

See [`PIPELINE.md`](PIPELINE.md) for the end-to-end data flow (inputs, stages,
and outputs) and [`pipeline.dot`](pipeline.dot) for the graph.
[`LAYERED_STORE.md`](LAYERED_STORE.md) describes the append-only base+generations
store; [`REALTIME.md`](REALTIME.md) evaluates real-time WoC feasibility (tiered
freshness, commit-first/deferred-blob backfill, and what blocks continuous update).

## Tools

| Tool | Purpose |
|------|---------|
| `classify`        | Walk objects and emit the per-shard object list (`*.olist.gz`), lines of `dir;type;sha;filename` |
| `grabc`           | Dump raw **commit** objects |
| `grabf`           | Dump raw **blob** objects (text blobs only) |
| `grabft`          | Dump raw **tree** objects |
| `grabtag`         | Dump raw **tag** objects |
| `grabGitI.perl`   | Driver: reads an olist on stdin, runs the `grab*` tools per directory, writes `<base>.<type>.{idx,bin}` |
| `grabGitIType.perl` | Type-selective variant of `grabGitI.perl`; optional 2nd arg lists which object types to (re)dump, leaving the others' outputs untouched |
| `get_new_commits` | Enumerate new commits |
| `compare`, `list`, `init` | Misc repository helpers |

The `grab*` tools emit the **raw canonical object bytes** straight from the
object database (`git_odb_read`), so the recomputed SHA-1 always matches the
stored object. Reconstructing objects from libgit2's parsed fields is lossy:
libgit2 normalizes signatures (trims `is_crud` characters from tagger/author
name and email) and tree entry modes (an integer cannot reproduce a
non-canonical `040000` with a leading zero), which would corrupt the bytes
and break the hash.

## Not built

`get_last.c` and `batch_fetch.c` are kept here for reference but excluded from
the build (see `CMakeLists.txt`): `get_last` depends on a `git_get_last()`
function that the old ssc-oscar fork had added inside the libgit2 library
itself, and `batch_fetch` contains unfinished code. This fork keeps libgit2
unmodified, so neither is compiled.
