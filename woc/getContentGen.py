#!/usr/bin/env python3
"""Gen-aware (base UNION gen) WoC object-content reader for Python.

WHY: python-woc / show_content / showCnt.perl read the BASE layer ONLY and return a FALSE
"not found" for ANY gen-layer object (RT / backfill / anything past the base watermark). The gen
index is a per-shard .sidx resolved by the C reader only, so Python must go through it. This module
wraps da5's `getObjGen` (via the `getContent.sh` wrapper) to resolve base+gen for ANY in-store object.

TYPES: commit | tree | blob | tag | tkns.

PORTABILITY: paths are env-overridable so the same module works on any host that has the binary built:
  GETCONTENT  -> path to getContent.sh wrapper (default ~/bin/getContent.sh)
  BIN, PREC, PREO, BASEBIN, LAYERED -> passed through to getObjGen (defaults baked for da5 in the wrapper)

USAGE:
  from getContentGen import get_content, read_content, DecodeFail
  data = get_content("fab365...", "tree")            # bytes, or None if absent; raises DecodeFail on corrupt gen
  for sha, status, content in read_content(shas, "commit"):   # batch: ONE getObjGen process
      # status in {"content","absent","decodefail"}
      ...

The 3 outcomes (do NOT read "absent" as proof of non-existence without this reader):
  content    -> resolved from base or gen.
  absent     -> genuinely not in base content / base offset / gen sidx ("no <type> <sha>").
  decodefail -> record EXISTS in gen but its LZF content won't decode (rare corrupt gen record;
                a re-grab candidate, NOT absence).
"""
import base64
import os
import subprocess

GETCONTENT = os.environ.get("GETCONTENT", os.path.expanduser("~/bin/getContent.sh"))


class DecodeFail(Exception):
    """The record exists in the gen layer but its LZF content failed to decode (corrupt gen record)."""


def _parse(line):
    line = line.rstrip("\n")
    if not line:
        return None
    if line.startswith("no "):                       # "no <type> <sha>"
        return line.rsplit(" ", 1)[-1], "absent", None
    if line.startswith("decodefail "):               # "decodefail <type> <sha> (...)"
        parts = line.split(" ")
        return (parts[2] if len(parts) > 2 else ""), "decodefail", None
    i = line.find(";")                               # "<sha>;<base64(content)>"
    if i < 0:
        return line, "absent", None
    sha, b64 = line[:i], line[i + 1:]
    return sha, "content", (base64.b64decode(b64) if b64 else b"")


def read_content(shas, otype="commit"):
    """Batch-resolve. Yields (sha, status, content_bytes|None) for each input sha, order preserved,
    through ONE getObjGen process. status in {"content","absent","decodefail"}."""
    shas = [s if ";" not in s else s.split(";", 1)[0] for s in shas]
    if not shas:
        return
    p = subprocess.Popen([GETCONTENT, otype], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, text=True, bufsize=1 << 20)
    out, _ = p.communicate("\n".join(shas) + "\n")
    for line in out.splitlines():
        r = _parse(line)
        if r is not None:
            yield r


def get_content(sha, otype="commit"):
    """Single object: return content bytes, or None if absent. Raises DecodeFail on a corrupt gen record."""
    for _sha, status, content in read_content([sha], otype):
        if status == "content":
            return content
        if status == "decodefail":
            raise DecodeFail(f"{otype} {sha}: record in gen layer but LZF decode failed")
        return None
    return None


if __name__ == "__main__":
    import sys
    _otype = sys.argv[1] if len(sys.argv) > 1 else "commit"
    _shas = sys.argv[2:] or [l.strip() for l in sys.stdin if l.strip()]
    for _s, _st, _c in read_content(_shas, _otype):
        print(_s, _st, (len(_c) if _c is not None else "-"), sep="\t")
