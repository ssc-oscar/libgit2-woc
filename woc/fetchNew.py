#!/usr/bin/env python3
"""
fetchNew.py -- incremental, dependency-free git fetch that downloads ONLY the
objects a repo has that WoC does not, by driving the smart-HTTP protocol-v2
negotiation with a pre-generated have-set (P2tips) instead of a local clone.

  * wants  = the repo's current ref tips (v2 ls-refs)
  * haves  = the tips WoC already has for this repo, supplied via P2tips
             (commit SHAs; see tipsR.* -- leaves of P2c filtered by empty c2cc)
  * NO thin-pack capability is requested, so the returned pack is self-contained
    and can be dropped straight into a bare repo for grab*/classify -- no delta
    bases from outside the pack are needed (that is the whole point of no-thin
    here: we have no local objects to resolve thin deltas against).

Usage:
  fetchNew.py <url> [--haves-file F | --haves sha,sha,...] [--out DIR]
              [--thin] [--list]
    <url>          https smart-HTTP repo URL (userinfo user:pass@ is honored)
    --haves-file   file with one have commit SHA per line (P2tips[repo])
    --haves        inline comma-separated have SHAs
    --out DIR      create/populate a bare repo of the NEW objects (default: tmp)
    --thin         request a thin pack (default: no-thin)
    --list         after indexing, list the new object oids+types+sizes
Prints a one-line summary: wants/haves/pack-bytes/new-objects.
"""
import sys, os, argparse, subprocess, tempfile, urllib.request, base64, urllib.parse

# ---- pkt-line ----------------------------------------------------------------
FLUSH = b"0000"; DELIM = b"0001"
def pkt(data: bytes) -> bytes:
    return b"%04x" % (len(data) + 4) + data
def pkt_str(s: str) -> bytes:
    return pkt(s.encode())

def read_pkt(stream):
    """Return (kind, payload). kind: 'eof'|'flush'|'delim'|'resp-end'|'data'."""
    hdr = _readn(stream, 4)
    if len(hdr) < 4:
        return ("eof", b"")             # HTTP body exhausted
    n = int(hdr, 16)
    if n == 0: return ("flush", b"")
    if n == 1: return ("delim", b"")
    if n == 2: return ("resp-end", b"")
    return ("data", _readn(stream, n - 4))

def _readn(stream, n):
    buf = b""
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk: break
        buf += chunk
    return buf

# ---- HTTP transport ----------------------------------------------------------
def _split_auth(url):
    p = urllib.parse.urlsplit(url)
    if "@" in p.netloc:
        userinfo, host = p.netloc.rsplit("@", 1)
        clean = urllib.parse.urlunsplit((p.scheme, host, p.path, p.query, p.fragment))
        return clean, userinfo
    return url, None

def _req(url, data=None, ctype=None):
    clean, userinfo = _split_auth(url)
    headers = {"Git-Protocol": "version=2", "User-Agent": "git/2.43.5 fetchNew"}
    if data is not None:
        headers["Content-Type"] = ctype
        headers["Accept"] = "application/x-git-upload-pack-result"
    # 'a:a' is the WoC pipeline's dummy anonymous marker; real Basic auth of it
    # makes googlesource 400. Send auth only for genuine credentials.
    if userinfo and userinfo != "a:a":
        headers["Authorization"] = "Basic " + base64.b64encode(userinfo.encode()).decode()
    return urllib.request.Request(clean, data=data, headers=headers, method=("POST" if data else "GET"))

def discover(url):
    """v2 capability advertisement via GET info/refs."""
    u = url.rstrip("/") + "/info/refs?service=git-upload-pack"
    resp = urllib.request.urlopen(_req(u), timeout=60)
    caps, ver = {}, None
    while True:
        kind, pl = read_pkt(resp)
        if kind == "eof": break
        if kind != "data": continue          # skip the "# service" banner's flush, etc.
        line = pl.rstrip(b"\n").decode("latin-1")
        if line.startswith("version "): ver = line.split()[1]
        elif "=" in line:
            k, v = line.split("=", 1); caps[k] = v
        else: caps[line] = ""
    if ver != "2":
        sys.exit(f"server did not negotiate protocol v2 (got version {ver})")
    return caps

def post(url, body):
    u = url.rstrip("/") + "/git-upload-pack"
    return urllib.request.urlopen(_req(u, data=body,
        ctype="application/x-git-upload-pack-request"), timeout=600)

# ---- v2 commands -------------------------------------------------------------
def ls_refs(url, objfmt):
    body = pkt_str("command=ls-refs\n") + pkt_str(f"object-format={objfmt}\n") + DELIM
    body += pkt_str("peel\n") + pkt_str("ref-prefix refs/heads/\n") \
          + pkt_str("ref-prefix refs/tags/\n") + FLUSH
    resp = post(url, body)
    wants = []
    while True:
        kind, pl = read_pkt(resp)
        if kind == "eof": break
        if kind != "data": continue
        oid = pl.split(b" ", 1)[0].decode()
        if len(oid) in (40, 64): wants.append(oid)
    # de-dupe, keep order
    seen=set(); out=[]
    for w in wants:
        if w not in seen: seen.add(w); out.append(w)
    return out

def fetch(url, objfmt, wants, haves, thin=False):
    body  = pkt_str("command=fetch\n") + pkt_str(f"object-format={objfmt}\n") + DELIM
    for w in wants: body += pkt_str(f"want {w}\n")
    for h in haves: body += pkt_str(f"have {h}\n")
    body += pkt_str("ofs-delta\n") + pkt_str("no-progress\n")
    if thin: body += pkt_str("thin-pack\n")     # omitted by default => no-thin
    body += pkt_str("done\n") + FLUSH
    resp = post(url, body)
    section, packparts, nbytes = None, [], 0
    while True:
        kind, pl = read_pkt(resp)
        if kind == "eof": break
        if kind != "data": continue          # skip flush/delim/resp-end between sections
        if pl in (b"acknowledgments\n", b"shallow-info\n", b"wanted-refs\n",
                  b"packfile\n"):
            section = pl.strip().decode(); continue
        if section == "packfile" and pl:
            band = pl[0]
            if band == 1:                 # pack data
                packparts.append(pl[1:]); nbytes += len(pl) - 1
            elif band == 3:               # fatal
                sys.exit("remote error: " + pl[1:].decode("latin-1", "replace"))
            # band 2 = progress -> ignore
    return b"".join(packparts), nbytes

# ---- main --------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--haves-file"); ap.add_argument("--haves", default="")
    ap.add_argument("--out"); ap.add_argument("--thin", action="store_true")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()

    haves = []
    if a.haves_file:
        haves += [l.strip() for l in open(a.haves_file) if l.strip()]
    if a.haves:
        haves += [h for h in a.haves.split(",") if h]

    caps = discover(a.url)
    objfmt = caps.get("object-format", "sha1")
    wants = ls_refs(a.url, objfmt)
    if not wants:
        sys.exit("no refs advertised")
    pack, nbytes = fetch(a.url, objfmt, wants, haves, thin=a.thin)

    outdir = a.out or tempfile.mkdtemp(prefix="fetchNew.")
    subprocess.run(["git", "init", "-q", "--bare", outdir], check=True)
    nobj = 0
    if pack and pack[:4] == b"PACK":
        p = subprocess.run(["git", "-C", outdir, "index-pack", "--stdin",
                            "--keep=fetchNew"], input=pack,
                           capture_output=True)
        if p.returncode != 0:
            sys.stderr.write(p.stderr.decode("latin-1")); sys.exit("index-pack failed")
        # count objects now present (pack started from an empty repo => all new)
        c = subprocess.run(["git", "-C", outdir, "cat-file", "--batch-all-objects",
                            "--batch-check=%(objectname)"], capture_output=True, text=True)
        objs = [l for l in c.stdout.splitlines() if l]
        nobj = len(objs)
        if a.list:
            subprocess.run(["git", "-C", outdir, "cat-file", "--batch-all-objects",
                            "--batch-check"])
    print(f"wants={len(wants)} haves={len(haves)} thin={a.thin} "
          f"pack_bytes={nbytes} new_objects={nobj} out={outdir}")

if __name__ == "__main__":
    main()
