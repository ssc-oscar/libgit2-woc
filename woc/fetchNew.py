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
import sys, os, argparse, subprocess, tempfile, urllib.request, urllib.error, base64, urllib.parse, random

# ---- WoC P2tips helpers ------------------------------------------------------
def repo_to_url(repo):
    """WoC repo name -> upstream URL: replace the FIRST '_' with '/'.
    e.g. 0-shelder-0_aspnetcore -> https://github.com/0-shelder-0/aspnetcore"""
    return "https://github.com/" + repo.replace("_", "/", 1)

def read_p2tips(path, repo):
    """Read a P2tips file (lines 'repo;tip_sha') and return tip SHAs for `repo`."""
    tips = []
    for ln in open(path):
        ln = ln.strip()
        if not ln or ";" not in ln:
            continue
        r, sha = ln.split(";", 1)
        if r == repo and sha:
            tips.append(sha.strip())
    return tips

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

_TOKEN = None
def _gh_token():
    """One token per process from a pool (GH_TOKENS_FILE, one per line) or GH_TOKEN.
    A pool distributes across repos (each fetchNew process = one repo) to raise the
    aggregate GitHub ceiling (per-token 5000/hr vs 60/hr unauth per-IP)."""
    global _TOKEN
    if _TOKEN is not None:
        return _TOKEN or None
    toks = []
    tf = os.environ.get("GH_TOKENS_FILE")
    if tf and os.path.exists(tf):
        toks = [l.strip() for l in open(tf) if l.strip() and not l.startswith("#")]
    if os.environ.get("GH_TOKEN"):
        toks.append(os.environ["GH_TOKEN"].strip())
    _TOKEN = random.choice(toks) if toks else ""
    return _TOKEN or None

def _req(url, data=None, ctype=None):
    clean, userinfo = _split_auth(url)
    # centralized auth: if no explicit creds and this is github.com, inject a pooled token
    if (not userinfo or userinfo == "a:a") and urllib.parse.urlsplit(clean).netloc.endswith("github.com"):
        tok = _gh_token()
        if tok:
            userinfo = "x-access-token:" + tok
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
    refs = []                                   # [(oid, refname)]
    while True:
        kind, pl = read_pkt(resp)
        if kind == "eof": break
        if kind != "data": continue
        parts = pl.rstrip(b"\n").split(b" ")
        oid = parts[0].decode()
        name = parts[1].decode() if len(parts) > 1 else None
        if len(oid) in (40, 64): refs.append((oid, name))
    return refs

def fetch(url, objfmt, wants, haves, thin=False, filt=None):
    body  = pkt_str("command=fetch\n") + pkt_str(f"object-format={objfmt}\n") + DELIM
    for w in wants: body += pkt_str(f"want {w}\n")
    for h in haves: body += pkt_str(f"have {h}\n")
    body += pkt_str("ofs-delta\n") + pkt_str("no-progress\n")
    if thin: body += pkt_str("thin-pack\n")     # omitted by default => no-thin
    # partial-clone filter (e.g. blob:none = commits+trees only, tree:0 = commits
    # only). Composes with haves: with WoC tips as haves, 'filter blob:none'
    # fetches ONLY the new commits/trees beyond WoC and NO blobs -- the cheap,
    # fast path for huge UPDATED repos. Caller verifies the server advertised
    # the 'filter' capability before passing filt.
    if filt: body += pkt_str(f"filter {filt}\n")
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
    ap.add_argument("url", nargs="?",
                    help="repo URL; optional if --repo is given (URL derived from WoC name)")
    ap.add_argument("--repo", help="WoC repo name (first '_' -> '/'); derives the GitHub URL")
    ap.add_argument("--p2tips", help="P2tips file ('repo;sha' lines); haves auto-selected for --repo")
    ap.add_argument("--haves-file"); ap.add_argument("--haves", default="")
    ap.add_argument("--out"); ap.add_argument("--thin", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--filter", default=None,
                    help="partial-clone filter, e.g. 'blob:none' (commits+trees, "
                         "no blobs) or 'tree:0' (commits only). Applied only if the "
                         "server advertises the 'filter' capability; otherwise the "
                         "fetch degrades to unfiltered and the summary reports applied=0.")
    ap.add_argument("--want-file",
                    help="file of explicit object OIDs (one per line) to request as "
                         "wants instead of the repo's ref tips -- used for the phase-2 "
                         "blob backfill. Skips ls-refs/--write-refs. Do NOT combine "
                         "with haves (the server would exclude reachable blobs).")
    ap.add_argument("--write-refs", action="store_true",
                    help="write packed-refs for advertised refs whose tip is present in the "
                         "partial pack -- so the bare repo is enumerable by "
                         "`git rev-list --objects --all --missing=allow-any` (gitListSimp)")
    a = ap.parse_args()

    # Resolve URL: explicit positional wins; else derive from --repo.
    url = a.url or (repo_to_url(a.repo) if a.repo else None)
    if not url:
        sys.exit("error: provide a URL or --repo NAME")

    haves = []
    if a.p2tips:
        if not a.repo:
            sys.exit("error: --p2tips requires --repo to select that repo's tips")
        haves += read_p2tips(a.p2tips, a.repo)
    if a.haves_file:
        haves += [l.strip() for l in open(a.haves_file) if l.strip()]
    if a.haves:
        haves += [h for h in a.haves.split(",") if h]
    # de-dupe haves, keep order
    seen = set(); haves = [h for h in haves if not (h in seen or seen.add(h))]

    # phase-2 backfill: wants come from an explicit OID list, no refs/haves.
    want_oids = None
    if a.want_file:
        seen = set(); want_oids = []
        for l in open(a.want_file):
            o = l.strip()
            if o and o not in seen and len(o) in (40, 64):
                seen.add(o); want_oids.append(o)
        haves = []   # never send haves with explicit wants -> server keeps the blobs

    try:
        caps = discover(url)
        objfmt = caps.get("object-format", "sha1")
        # filter is honored only if the server advertised it. In protocol v2 it
        # is a sub-feature of the 'fetch' command capability (e.g.
        # 'fetch=shallow wait-for-done filter ...'), NOT a top-level key.
        filt = None
        if a.filter:
            if "filter" in caps.get("fetch", "").split(): filt = a.filter
            else: sys.stderr.write(f"warning: server does not advertise fetch 'filter'; "
                                   f"fetching {url} unfiltered\n")
        if want_oids is not None:
            refs = []                              # backfill mode: no ref negotiation
            wants = want_oids
        else:
            refs = ls_refs(url, objfmt)
            if not refs:
                sys.exit(f"error: no refs advertised (empty or inaccessible repo): {url}")
            seen=set(); wants=[]                   # unique want oids, order-preserving
            for o,_ in refs:
                if o not in seen: seen.add(o); wants.append(o)
        pack, nbytes = fetch(url, objfmt, wants, haves, thin=a.thin, filt=filt)
    except urllib.error.HTTPError as e:
        # gone/renamed/private repos: GitHub answers 401/404 -> fail cleanly, not a traceback
        sys.exit(f"error: HTTP {e.code} for {url} (repo gone, renamed, or private?)")
    except urllib.error.URLError as e:
        sys.exit(f"error: cannot reach {url}: {e.reason}")

    outdir = a.out or tempfile.mkdtemp(prefix="fetchNew.")
    # empty --template => skip the 13 hooks/*.sample + info/exclude + description git copies into
    # every new repo (~14 of the ~32 inodes/repo of pure scaffolding); we only need objects+refs.
    subprocess.run(["git", "init", "-q", "--bare", "--template=", outdir], check=True)
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
        if a.write_refs:
            # write packed-refs for advertised refs whose tip object is present in
            # the partial pack (skip wants already in WoC -> absent here, would dangle)
            chk = subprocess.run(["git", "-C", outdir,
                                  "cat-file", "--batch-check=%(objectname) %(objecttype)"],
                                 input="\n".join(o for o, _ in refs).encode(),
                                 capture_output=True)
            present = set()
            for line in chk.stdout.decode().splitlines():
                f = line.split()
                if len(f) >= 2 and f[1] != "missing": present.add(f[0])
            rows = [(o, n) for o, n in refs if n and o in present]
            if rows:
                with open(os.path.join(outdir, "packed-refs"), "w") as fh:
                    fh.write("# pack-refs with: peeled fully-peeled sorted\n")
                    for o, n in rows: fh.write(f"{o} {n}\n")
    print(f"wants={len(wants)} haves={len(haves)} thin={a.thin} "
          f"filter={a.filter or '-'} filter_applied={int(filt is not None)} "
          f"pack_bytes={nbytes} new_objects={nobj} out={outdir}")

if __name__ == "__main__":
    main()
