#!/usr/bin/env python3
"""
Babysit WoC object extraction: scan New*.err files, and for shards that are
idle (no live grabGitI.perl worker) and whose only mismatches are tags/trees,
regenerate just that object type from the authoritative olist.<shard>.gz and
swap it in -- leaving commit/blob outputs untouched.

Safety:
  * never touches a shard with a live grabGitI worker
  * never auto-fixes commit/"other" mismatches -> reported for manual review
  * regenerates to a .redo temp, verifies 0 mismatches AND identical sha-set
    vs the existing idx, then atomically renames into place
  * tag backups (tiny) go next to the output; tree backups (~500MB) go to the
    large trees disk to spare the small out/b disks
  * on success the .err is renamed .err.fixed so it is not reprocessed

Usage:
  wocFixErr.py            # scan all, fix idle tag/tree shards
  wocFixErr.py --dry      # report only, change nothing
  wocFixErr.py V2605.017  # restrict to one dataset
"""
import re, os, sys, glob, subprocess, shutil

OUT_ROOTS = ["/media/volume/out", "/media/volume/b"]
TREES     = "/media/volume/trees"
HOME      = os.path.expanduser("~")
GRAB      = f"perl -I {HOME}/lib64/perl5 {HOME}/bin/grabGitIType.perl"
TREE_BK   = f"{TREES}/woc_tree_backups"            # big tree backups on large disk
OFFENDERS = f"{TREES}/offenders"                   # running registry: repo;size;summary

def record_offender(repo, gb, summary, excluded=""):
    """Append 'repo;size;excluded;summary' to the registry, once per repo.
    The 'excluded' field notes whether the repo's blobs were dropped from the
    dump (set to e.g. a date once excluded; empty until then)."""
    try:    seen = set(l.split(';',1)[0] for l in open(OFFENDERS))
    except FileNotFoundError: seen = set()
    if repo in seen: return
    with open(OFFENDERS, 'a') as f:
        f.write(f"{repo};{gb:.1f}GB;{excluded};{summary}\n")

def mark_excluded(repo, tag="excluded"):
    """Set the 'excluded' field for an existing offender line."""
    try:    lines = open(OFFENDERS).read().splitlines()
    except FileNotFoundError: return
    out = []
    for l in lines:
        p = l.split(';', 3)
        if len(p) == 4 and p[0] == repo:
            p[2] = tag; l = ";".join(p)
        out.append(l)
    open(OFFENDERS, 'w').write("\n".join(out) + "\n")

ERR_RE = re.compile(r'(New202605V2605\.(\d+)\.(\d+))\.err$')

BLOB_SHARD_MIN = 100 * 10**9   # only flag a shard whose blob.bin exceeds this
BLOB_REPO_MIN  =  30 * 10**9   # ...and only if some single repo exceeds this

# Datasets that are finalized and whose repos/dumps are being (or have been)
# removed.  The babysitter ignores them entirely -- no fix attempts, no blob
# alerts -- avoiding noise while deletion is in progress.  One token per line,
# e.g.  V2605.023
DONE_FILE = f"{HOME}/bin/wocFixErr.done"
def done_datasets():
    try:    return set(l.strip() for l in open(DONE_FILE) if l.strip() and not l.startswith('#'))
    except FileNotFoundError: return set()

def live_shards():
    ps = subprocess.run(["ps","-eo","cmd"], capture_output=True, text=True).stdout
    workers = " ".join(l for l in ps.splitlines() if 'grabGitI.perl' in l)
    return set(re.findall(r'New202605V2605\.\d+\.\d+', workers))

def classify(errpath):
    b = open(errpath,'rb').read(); parts = b.split(b"sha do not match: ")
    c = {'tag':0,'tree':0,'commit':0,'other':0}
    for rec in parts[1:]:
        nl = rec.find(b"\n"); head = rec[:nl]; body = rec[nl+1:nl+60]
        if re.match(rb"[0-9a-f]{40} vs ", head):       c['tag']    += 1
        elif re.match(rb"tree [0-9a-f]{40}\n", body):  c['commit'] += 1
        elif re.match(rb"0?[0-7]{5,6} ", body):        c['tree']   += 1
        else:                                          c['other']  += 1
    return c

def idx_shas(p):
    return set(l.split(';')[3] for l in open(p,encoding='latin-1') if l.count(';') >= 4)

def fix_one(errpath, live, dry):
    d  = os.path.dirname(errpath); bn = os.path.basename(errpath)
    m  = ERR_RE.match(bn)
    if not m: return ('skip', bn, 'not-a-shard-err')
    base, ds, shard = m.group(1), m.group(2), m.group(3)
    if f"V2605.{ds}" in DONE:                   return ('skip', base, 'dataset-done')
    if os.path.getsize(errpath) == 0:          return ('skip', base, 'empty')
    if base in live:                           return ('skip', base, 'LIVE-worker')
    c = classify(errpath)
    if c['commit'] or c['other']:
        return ('MANUAL', base, f"commit={c['commit']} other={c['other']}")
    types = [t for t in ('tag','tree') if c[t] > 0]
    if not types:                              return ('skip', base, 'no-tag/tree')
    repos = f"{TREES}/V2605.{ds}"
    olist = f"{d}/New202605V2605.{ds}.olist.{shard}.gz"
    if not os.path.exists(olist):              return ('skip', base, 'no-olist')
    # data may have been rsynced to da8 and removed: skip if the repo clones are
    # gone (emptied dir) or the shard's own output dump is gone -- can't/needn't fix
    try:    nrepo = sum(1 for e in os.scandir(repos) if e.is_dir())
    except FileNotFoundError: nrepo = 0
    if nrepo < 100:                            return ('skip', base, f'repos-removed({nrepo})')
    if any(not os.path.exists(f"{d}/{base}.{t}.idx") for t in types):
        return ('skip', base, 'dump-removed')
    if dry:
        return ('WOULD-FIX', base, " ".join(f"{t}={c[t]}" for t in types))

    done = []
    for t in types:
        redobase = f"{d}/{base}.redo"
        redoerr  = f"{d}/{base}.{t}.redoerr"
        cmd = (f"cd {repos} && gunzip -c {olist} | awk -F';' '$2==\"{t}\"' "
               f"| {GRAB} {redobase} {t} 2> {redoerr}")
        subprocess.run(cmd, shell=True, executable="/bin/bash")
        idx_old = f"{d}/{base}.{t}.idx"; bin_old = f"{d}/{base}.{t}.bin"
        idx_new = f"{redobase}.{t}.idx"; bin_new = f"{redobase}.{t}.bin"
        mm  = sum(1 for l in open(redoerr,'rb') if b'sha do not match' in l) if os.path.exists(redoerr) else -1
        oth = sum(1 for l in open(redoerr,encoding='latin-1')
                  if l.strip() and 'sha do not match' not in l) if os.path.exists(redoerr) else -1
        if not os.path.exists(idx_new):
            return ('FAIL', base, f'{t}: no redo idx')
        diff = len(idx_shas(idx_old) ^ idx_shas(idx_new)) if os.path.exists(idx_old) else -1
        if mm != 0 or oth != 0 or diff != 0:
            for x in (idx_new, bin_new):
                if os.path.exists(x): os.remove(x)
            return ('FAIL', base, f'{t}: mm={mm} oth={oth} shaset-diff={diff}')
        # verified -> backup + atomic swap
        if t == 'tag':
            bk = f"{d}/redo_backup_20260603"; os.makedirs(bk, exist_ok=True)
            shutil.copy2(idx_old, f"{bk}/{base}.tag.idx.bak")
            shutil.copy2(bin_old, f"{bk}/{base}.tag.bin.bak")
        else:
            bk = f"{TREE_BK}/V2605.{ds}"; os.makedirs(bk, exist_ok=True)
            shutil.copy2(idx_old, f"{bk}/{base}.tree.idx.bak")
            shutil.move(bin_old,  f"{bk}/{base}.tree.bin.bak")   # free small-disk space
        os.replace(idx_new, idx_old)
        os.replace(bin_new, bin_old)
        done.append(f"{t}({c[t]})")
    os.replace(errpath, errpath + ".fixed")
    return ('FIXED', base, " ".join(done))

def gh_url(repo):
    """dataset repo dir name -> GitHub URL (first '_' separates owner/repo)."""
    return "https://github.com/" + repo.replace("_", "/", 1)

def readme_excerpt(ds, repo, n=1000):
    """First n bytes of the top-level README from the local bare clone, with
    whitespace collapsed for one-line logging. Returns '' if none/unreadable."""
    gd = f"{TREES}/{ds}/{repo}"
    if not os.path.isdir(gd): return ""
    def git(*a):
        return subprocess.run(["git","--git-dir",gd,*a], capture_output=True, timeout=30)
    ref = None
    for r in ("HEAD", "refs/remotes/origin/HEAD"):
        if git("rev-parse","--verify","-q",r).returncode == 0: ref = r; break
    if not ref:
        outs = git("for-each-ref","--format=%(refname)","refs/heads","refs/remotes").stdout.decode().split()
        ref = outs[0] if outs else None
    if not ref: return ""
    try:
        ls = git("ls-tree","--name-only",ref).stdout.decode("utf-8","replace").splitlines()
        # prefer a README; fall back to CLAUDE.md when there is no README
        rf = next((f for f in ls if f.lower().startswith("readme")), None) \
             or next((f for f in ls if f.lower() == "claude.md"), None)
        if not rf: return ""
        txt = git("show",f"{ref}:{rf}").stdout[:n].decode("utf-8","replace")
        return " ".join(txt.split())[:300]
    except Exception:
        return ""

def blob_report(live):
    """Alert-only: shards whose blob.bin > BLOB_SHARD_MIN and that contain a
    single repo contributing > BLOB_REPO_MIN of (compressed) blob bytes. The
    user excludes such offenders manually:  grep -v 'offender;blob' | grab..."""
    alerts = []
    for root in OUT_ROOTS:
        for binf in glob.glob(f"{root}/V2605.*/New202605V2605.*.blob.bin"):
            try: sz = os.path.getsize(binf)
            except OSError: continue
            if sz <= BLOB_SHARD_MIN: continue
            base = binf[:-len('.blob.bin')]; bn = os.path.basename(base)
            mds = re.search(r'V2605\.\d+', bn)
            if mds and mds.group(0) in DONE: continue
            idx  = base + '.blob.idx'
            if not os.path.exists(idx): continue
            islive = bn in live
            if islive:
                # don't parse a growing multi-GB idx every cycle; assess when idle
                alerts.append((bn, sz, True, ["(offenders assessed when shard completes)"]))
                continue
            # sentinel cache: skip the expensive idx scan unless blob.bin changed
            sent = base + '.blobalert'
            sig  = f"{sz}:{int(os.path.getmtime(binf))}"
            if os.path.exists(sent) and open(sent).read().split('\n',1)[0] == sig:
                offenders = [l for l in open(sent).read().splitlines()[1:] if l]
            else:
                tot = {}
                with open(idx, encoding='latin-1') as fh:
                    for line in fh:
                        p = line.split(';')
                        if len(p) >= 5:
                            try: tot[p[4]] = tot.get(p[4],0) + int(p[1])
                            except ValueError: pass
                ds = mds.group(0)
                offenders = []
                for v, k in sorted(((v,k) for k,v in tot.items() if v > BLOB_REPO_MIN), reverse=True):
                    gb = v / 1e9
                    summ = readme_excerpt(ds, k) or "(no README)"
                    record_offender(k, gb, summ)          # -> ~/trees/offenders
                    offenders.append(f"{gb:.1f}GB {k} -> {gh_url(k)} :: {summ[:120]}")
                open(sent,'w').write(sig + "\n" + "\n".join(offenders) + "\n")
            if offenders:
                alerts.append((bn, sz, islive, offenders))
    return alerts

DONE = set()

def main():
    global DONE
    DONE = done_datasets()
    dsfilter = next((a for a in sys.argv[1:] if not a.startswith('-')), None)
    dry = '--dry' in sys.argv
    live = live_shards()
    files = []
    for root in OUT_ROOTS:
        files += glob.glob(f"{root}/V2605.*/New202605V2605.*.err")
    files = sorted(set(f for f in files if ERR_RE.match(os.path.basename(f))))
    if dsfilter:
        files = [f for f in files if f"/{dsfilter}/" in f]
    counts = {}
    for f in files:
        status, base, info = fix_one(f, live, dry)
        counts[status] = counts.get(status, 0) + 1
        if status not in ('skip',):
            print(f"  [{status:9}] {base:28} {info}")
    print("live workers:", sorted(live) or "none")
    print("summary:", {k: counts[k] for k in sorted(counts)})
    # NB: oversized-blob handling (detect dominant repos, kill+relaunch or
    # re-extract blobs excluding them, and log to ~/trees/offenders) is done by
    # ~/bin/deOffendWatch.sh -> deOffend.sh, run from the same cron wrapper.

if __name__ == "__main__":
    main()
