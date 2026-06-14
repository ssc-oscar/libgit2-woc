#!/usr/bin/env python3
# Build a bloom filter over 20-byte SHA keys read from stdin, benchmark
# RAM-membership throughput, and emit a query file (hex) for the tch baseline.
import sys, time, math, numpy as np

P = 0.01                      # target false-positive rate
NQ = 1_000_000                # present queries (+ NQ absent)

t0 = time.time()
buf = sys.stdin.buffer.read()
n = len(buf) // 20
keys = np.frombuffer(buf[:n*20], dtype=np.uint8).reshape(n, 20)
t_read = time.time() - t0

m = int(-n * math.log(P) / (math.log(2) ** 2)); m = (m + 7) // 8 * 8
k = max(1, round(m / n * math.log(2)))
bits = np.zeros(m // 8, dtype=np.uint8)

def hashes(K):
    a = np.ascontiguousarray(K[:, 0:8]).view(np.uint64).reshape(-1)
    b = np.ascontiguousarray(K[:, 8:16]).view(np.uint64).reshape(-1)
    return a, b

t0 = time.time()
a, b = hashes(keys)
mm = np.uint64(m)
for i in range(k):
    pos = (a + np.uint64(i) * b) % mm
    byte = (pos >> np.uint64(3)).astype(np.int64)
    mask = (np.uint8(1) << (pos & np.uint64(7)).astype(np.uint8))
    np.bitwise_or.at(bits, byte, mask)
t_build = time.time() - t0

def member(K):
    a, b = hashes(K)
    out = np.ones(K.shape[0], dtype=bool)
    for i in range(k):
        pos = (a + np.uint64(i) * b) % mm
        byte = (pos >> np.uint64(3)).astype(np.int64)
        bit = ((bits[byte] >> (pos & np.uint64(7)).astype(np.uint8)) & np.uint8(1)).astype(bool)
        out &= bit
    return out

# present sample (first NQ keys) + absent (random 20-byte; ~0 chance in set)
present = keys[:NQ]
rng = np.random.default_rng(1)
absent = rng.integers(0, 256, size=(NQ, 20), dtype=np.uint8)

t0 = time.time(); mp = member(present); tp = time.time() - t0
t0 = time.time(); ma = member(absent);  ta = time.time() - t0

fp = int(ma.sum())                      # absent keys the filter calls "present"
truepos = int(mp.sum())                 # should be all NQ (no false negatives)
nbench = 2 * NQ

print(f"keys(n)            = {n:,}")
print(f"read_stdin         = {t_read:.1f}s  ({len(buf)/1e9:.2f} GB)")
print(f"filter m,k         = {m:,} bits, k={k}")
print(f"filter SIZE        = {m/8/1e6:.0f} MB  ({m/n:.2f} bits/key)")
print(f"build              = {t_build:.1f}s  ({n/t_build/1e6:.1f} M keys/s)")
print(f"membership present = {NQ/tp/1e6:.1f} M lookups/s  (truepos {truepos}/{NQ})")
print(f"membership absent  = {NQ/ta/1e6:.1f} M lookups/s")
print(f"overall RAM memb   = {nbench/(tp+ta)/1e6:.1f} M lookups/s")
print(f"false positives    = {fp}/{NQ}  ({100*fp/NQ:.3f}%)")

# write query hex (present+absent) for the tch baseline
with open("/tmp/q.hex", "w") as f:
    for K in (present, absent):
        for row in K:
            f.write(row.tobytes().hex() + "\n")
print("wrote /tmp/q.hex")
