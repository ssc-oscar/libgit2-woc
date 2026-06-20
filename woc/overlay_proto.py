#!/usr/bin/env python3
"""overlay_proto.py (v2) -- layered content store: immutable base + N frozen
generations in a continuous offset space.

Each generation = a content .bin (immutable) + a FROZEN sorted index .sidx
(32-byte recs: sha[20] + global_offset[<Q,8] + len[<I,4], sorted by sha; bsearch).
No growing/mutable index -> every generation (content AND index) is immutable, so
incremental backups hardlink all old gens and ship only the newest. Reads resolve
a sha by bsearch across gens, then fseek the segment the global offset lands in.
"""
import sys, os, json, struct, mmap, bisect, time, hashlib

D = "/media/volume/trees/ovp_proto"
SEG = D+"/segments.json"
REC = 32  # sha20 + Q(off) + I(len)

def mksidx(idxfile, sidxout):
    recs = []
    with open(idxfile) as f:
        for line in f:
            _id, off, ln, sha = line.rstrip().split(";")
            recs.append(bytes.fromhex(sha) + struct.pack("<QI", int(off), int(ln)))
    recs.sort()                       # by sha (first 20 bytes dominate)
    with open(sidxout, "wb") as o:
        o.write(b"".join(recs))
    return len(recs)

class Sidx:
    def __init__(self, path):
        self.f = open(path, "rb"); self.mm = mmap.mmap(self.f.fileno(), 0, access=mmap.ACCESS_READ)
        self.n = len(self.mm)//REC
    def get(self, sha20):
        lo, hi = 0, self.n
        while lo < hi:
            mid = (lo+hi)//2; k = self.mm[mid*REC:mid*REC+20]
            if k < sha20: lo = mid+1
            elif k > sha20: hi = mid
            else: return struct.unpack_from("<QI", self.mm, mid*REC+20)
        return None

def load():
    ss = json.load(open(SEG))         # [{name, bin, base, size, sidx}]
    sidx = {s["name"]: Sidx(D+"/"+s["sidx"]) for s in ss}
    return ss, sidx

def read_obj(sha, ss, sidx):
    k = bytes.fromhex(sha)
    for s in reversed(ss):            # newest gen first
        v = sidx[s["name"]].get(k)
        if v:
            goff, ln = v
            for seg in ss:            # dispatch by continuous offset
                if seg["base"] <= goff < seg["base"]+seg["size"]:
                    with open(D+"/"+seg["bin"], "rb") as f:
                        f.seek(goff-seg["base"]); return f.read(ln), s["name"], goff, ln
    return None, None, None, None

if __name__ == "__main__":
    c = sys.argv[1]
    if c == "mksidx":
        n = mksidx(sys.argv[2], sys.argv[3]); print(f"built {sys.argv[3]}: {n} recs")
    elif c == "stats":
        ss = json.load(open(SEG))
        for s in ss: print(f"  seg {s['name']:6} base={s['base']:>12} size={s['size']:>11} bin={s['bin']} sidx={s['sidx']}")
    elif c in ("read", "md5"):
        ss, sidx = load()
        for sha in sys.argv[2:]:
            data, gen, goff, ln = read_obj(sha, ss, sidx)
            if data is None: print(f"{sha}: MISS"); continue
            print(f"{sha}: {hashlib.md5(data).hexdigest() if c=='md5' else str(len(data))+'B'} (gen={gen} goff={goff} len={ln})")
