/* grabCommitsRT.c -- maximally-efficient commit-only RT fetcher (no per-project repos).
 *
 * WHY C: fetchNew.py hand-rolls protocol-v2 + `filter tree:0` (libgit2 has neither), but its pack
 * read is a pure-Python byte loop -> the GIL serializes any threaded fusion (measured 68x slower,
 * lost 76% of commits). C has no GIL: raw v2 client via libcurl -> in-memory pack -> git_indexer
 * (libgit2 resolves deltas in C) -> git_odb walk -> commits, with real pthread parallelism and no
 * intermediate bare repo (no 195M-inode scaffolding, no double cat-file IO).
 *
 * Reads `repo<TAB|;>before<TAB|;>head` lines on stdin. PAR worker threads fetch+extract in parallel
 * (each with its own /dev/shm scratch); commits buffer into 128 shard buffers; then a parallel write
 * phase puts them into commits_sh (LMDB, dedup via MDB_NOOVERWRITE). No DB_SH => emit shas to stdout.
 *
 * build: cc -O2 -o grabCommitsRT grabCommitsRT.c -Iinclude -Lbuild -lgit2 -lcurl -lz -lpthread -llmdb
 *        (system liblmdb.so.0.0.0 = LMDB 0.9.29; on-disk format matches py-lmdb's shards)
 * env:  DB_SH (128-shard commits_sh dir; unset=stdout), PAR (fetch threads, def 32),
 *       WPAR (shard-write threads, def 16), SHARD_GB (map size, def 16), SCRATCH_ROOT (def /dev/shm/gcrt)
 */
#include <git2.h>
#include <curl/curl.h>
#include <zlib.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <dirent.h>
#include <time.h>
#include <sys/stat.h>

/* ---- vendored minimal LMDB API (0.9.x, stable ABI; validated by round-trip vs py-lmdb) -------- */
typedef struct MDB_env MDB_env; typedef struct MDB_txn MDB_txn; typedef unsigned int MDB_dbi;
typedef struct MDB_val { size_t mv_size; void *mv_data; } MDB_val;
#define MDB_CREATE       0x40000      /* dbi flag */
#define MDB_NOOVERWRITE  0x10         /* put flag */
#define MDB_KEYEXIST     (-30799)
#define MDB_SUCCESS      0
extern int  mdb_env_create(MDB_env **);
extern int  mdb_env_set_mapsize(MDB_env *, size_t);
extern int  mdb_env_set_maxreaders(MDB_env *, unsigned int);
extern int  mdb_env_open(MDB_env *, const char *, unsigned int, int);
extern int  mdb_txn_begin(MDB_env *, MDB_txn *, unsigned int, MDB_txn **);
extern int  mdb_dbi_open(MDB_txn *, const char *, unsigned int, MDB_dbi *);
extern int  mdb_put(MDB_txn *, MDB_dbi, MDB_val *, MDB_val *, unsigned int);
extern int  mdb_txn_commit(MDB_txn *);
extern void mdb_txn_abort(MDB_txn *);
extern int  mdb_env_sync(MDB_env *, int);
extern void mdb_env_close(MDB_env *);
extern char *mdb_strerror(int);

#define NSHARD 128

/* ---- growable byte buffer ------------------------------------------------------------------- */
typedef struct { char *p; size_t n, cap; } buf_t;
static void buf_add(buf_t *b, const void *d, size_t n) {
    if (b->n + n > b->cap) { b->cap = (b->n + n) * 2 + 4096; b->p = realloc(b->p, b->cap); }
    memcpy(b->p + b->n, d, n); b->n += n;
}
static void buf_reset(buf_t *b) { b->n = 0; }

/* ---- pkt-line ------------------------------------------------------------------------------- */
static void pkt(buf_t *b, const char *s) {
    char h[5]; size_t L = strlen(s) + 4; snprintf(h, sizeof h, "%04zx", L); buf_add(b, h, 4); buf_add(b, s, strlen(s));
}
static void pkt_flush(buf_t *b) { buf_add(b, "0000", 4); }
static void pkt_delim(buf_t *b) { buf_add(b, "0001", 4); }

/* ---- libcurl transport ---------------------------------------------------------------------- */
static size_t wcb(void *d, size_t sz, size_t nm, void *u) { buf_add((buf_t *)u, d, sz * nm); return sz * nm; }
/* one persistent easy handle PER WORKER THREAD, reused across every request. curl_easy_reset keeps
 * the live connection pool + DNS cache + TLS session cache -> keep-alive to github.com, no per-request
 * TLS handshake/DNS (was ~78k handshakes/hr = the 6h cutover blowup). */
static __thread CURL *TLC = NULL;
static void set_common(CURL *c) {
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, wcb);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, 600L);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 20L);          /* fast-fail dead/slow repos */
    curl_easy_setopt(c, CURLOPT_USERAGENT, "git/2.43 grabCommitsRT");
    curl_easy_setopt(c, CURLOPT_TCP_KEEPALIVE, 1L);
}
/* ---- self-rate-limiting: GLOBAL backoff on GitHub 403/429 (secondary rate limit) -------------
 * A 403/429 means GitHub is throttling this IP; hammering harder gets it flagged (the 4h cutover
 * blowup: 1346x403 + 2282x401). So ALL threads pause via a shared BACKOFF_UNTIL when any one is
 * throttled (honor Retry-After, else exponential on the streak), and the throttled request retries
 * after backing off. THROTTLE_STREAK resets on a 200 so backoff decays as things recover. */
static long BACKOFF_UNTIL = 0, THROTTLE_STREAK = 0, BACKOFF_EVENTS = 0;
static long RATE_BACKOFF = 60;      /* base backoff (s) when no Retry-After; env RATE_BACKOFF */
static int  MAX_RETRY    = 5;       /* per-request retries on 403/429;      env MAX_RETRY     */
static void wait_backoff(void) {
    for (;;) {
        long until = __atomic_load_n(&BACKOFF_UNTIL, __ATOMIC_RELAXED), now = time(NULL);
        if (until <= now) return;
        long d = until - now; if (d > 5) d = 5;                  /* re-check (peer may extend) */
        sleep(d);
    }
}
static void note_throttle(CURL *c) {
    curl_off_t ra = 0; curl_easy_getinfo(c, CURLINFO_RETRY_AFTER, &ra);
    long streak = __atomic_add_fetch(&THROTTLE_STREAK, 1, __ATOMIC_RELAXED);
    long delay = ra > 0 ? (long)ra : RATE_BACKOFF * (streak < 4 ? streak : 4);
    if (delay > 600) delay = 600;
    long until = time(NULL) + delay, cur;
    do { cur = __atomic_load_n(&BACKOFF_UNTIL, __ATOMIC_RELAXED); if (until <= cur) break; }
    while (!__atomic_compare_exchange_n(&BACKOFF_UNTIL, &cur, until, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED));
    if (__atomic_add_fetch(&BACKOFF_EVENTS, 1, __ATOMIC_RELAXED) % 100 == 1)
        fprintf(stderr, "THROTTLE 403/429 -> global backoff %lds (streak=%ld)\n", delay, streak);
}
/* build the request on the thread's persistent handle */
static struct curl_slist *http_setup(CURL *c, const char *url, const void *body, size_t blen) {
    curl_easy_reset(c);
    struct curl_slist *h = curl_slist_append(NULL, "Git-Protocol: version=2");
    if (body) {
        h = curl_slist_append(h, "Content-Type: application/x-git-upload-pack-request");
        h = curl_slist_append(h, "Accept: application/x-git-upload-pack-result");
        curl_easy_setopt(c, CURLOPT_POST, 1L);
        curl_easy_setopt(c, CURLOPT_POSTFIELDS, body);
        curl_easy_setopt(c, CURLOPT_POSTFIELDSIZE, (long)blen);
    }
    curl_easy_setopt(c, CURLOPT_URL, url);
    curl_easy_setopt(c, CURLOPT_HTTPHEADER, h);
    set_common(c);
    return h;
}
static long http(const char *url, const void *body, size_t blen, buf_t *out) {
    if (!TLC && !(TLC = curl_easy_init())) return -1;
    CURL *c = TLC; long code = -1; int tries = 0;
    for (;;) {
        struct curl_slist *h = http_setup(c, url, body, blen);
        curl_easy_setopt(c, CURLOPT_WRITEDATA, out);
        buf_reset(out);                                          /* drop any partial from a retry */
        wait_backoff();
        CURLcode rc = curl_easy_perform(c);
        code = -1; if (rc == CURLE_OK) curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &code);
        curl_slist_free_all(h);
        if (rc == CURLE_OK && (code == 403 || code == 429)) { note_throttle(c); if (++tries <= MAX_RETRY) continue; }
        if (rc != CURLE_OK) return -1;
        if (code == 200) __atomic_store_n(&THROTTLE_STREAK, 0, __ATOMIC_RELAXED);
        return code;
    }
}

/* ---- pkt-line parsers ----------------------------------------------------------------------- */
static void parse_refs(buf_t *r, buf_t *wants, int *nref) {
    size_t i = 0; *nref = 0;
    while (i + 4 <= r->n) {
        char hx[5]; memcpy(hx, r->p + i, 4); hx[4] = 0; long L = strtol(hx, NULL, 16);
        if (L == 0 || L == 1 || L == 2) { i += 4; continue; }
        if (L < 4 || i + (size_t)L > r->n) break;
        char *pl = r->p + i + 4; size_t pn = L - 4;
        if (pn >= 40) { int hex = 1; for (int k = 0; k < 40; k++) { char ch = pl[k];
            if (!((ch>='0'&&ch<='9')||(ch>='a'&&ch<='f'))) { hex = 0; break; } }
            if (hex) { buf_add(wants, pl, 40); (*nref)++; } }
        i += L;
    }
}
/* ---- STREAMING fetch: demux the sideband and feed pack bytes straight to git_indexer_append,
 * so the whole pack is never held in RAM -- only a <64KB residual (one partial pkt-line) + curl's
 * chunk. Requires DISK scratch (the indexer writes the pack to scratch; on tmpfs that would just
 * move the pack into RAM). Bounds per-repo fetch memory regardless of history depth. ------------ */
typedef struct { git_indexer *idx; git_indexer_progress *st; buf_t resid; int in_pack, got_pack, err; } fetch_ctx;
static size_t fetch_wcb(void *data, size_t sz, size_t nm, void *u) {
    fetch_ctx *fc = u; size_t total = sz * nm;
    buf_add(&fc->resid, data, total);
    size_t pos = 0;
    while (fc->resid.n - pos >= 4) {
        char hx[5]; memcpy(hx, fc->resid.p + pos, 4); hx[4] = 0; long L = strtol(hx, NULL, 16);
        if (L == 0 || L == 1 || L == 2) { pos += 4; continue; }      /* flush/delim/resp-end */
        if (L < 4) { fc->err = 1; return 0; }
        if (fc->resid.n - pos < (size_t)L) break;                    /* wait for the rest of this pkt */
        char *pl = fc->resid.p + pos + 4; size_t pn = L - 4;
        if (pn >= 9 && !memcmp(pl, "packfile\n", 9)) fc->in_pack = 1;
        else if (pn >= 7 && (!memcmp(pl,"acknowl",7)||!memcmp(pl,"shallow",7)||!memcmp(pl,"wanted-",7))) fc->in_pack = 0;
        else if (fc->in_pack && pn >= 1) {
            unsigned char band = (unsigned char)pl[0];
            if (band == 1) { if (git_indexer_append(fc->idx, pl+1, pn-1, fc->st)) { fc->err = 1; return 0; } fc->got_pack = 1; }
            else if (band == 3) { fc->err = 1; return 0; }           /* remote fatal */
        }
        pos += L;
    }
    if (pos) { memmove(fc->resid.p, fc->resid.p + pos, fc->resid.n - pos); fc->resid.n -= pos; }
    return total;
}
static long http_stream(const char *url, const void *body, size_t blen, fetch_ctx *fc) {
    if (!TLC && !(TLC = curl_easy_init())) return -1;
    CURL *c = TLC; long code = -1; int tries = 0;
    for (;;) {
        struct curl_slist *h = http_setup(c, url, body, blen);
        curl_easy_setopt(c, CURLOPT_WRITEDATA, fc);
        curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, fetch_wcb);  /* streaming demuxer -> git_indexer */
        wait_backoff();
        CURLcode rc = curl_easy_perform(c);
        code = -1; if (rc == CURLE_OK) curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &code);
        curl_slist_free_all(h);
        /* 403/429 hits BEFORE any pack bytes (GitHub rejects up front) -> got_pack==0 -> safe to retry. */
        if (rc == CURLE_OK && (code == 403 || code == 429) && !fc->got_pack) {
            note_throttle(c); if (++tries <= MAX_RETRY) continue;
        }
        if (rc != CURLE_OK) return -1;
        if (code == 200) __atomic_store_n(&THROTTLE_STREAK, 0, __ATOMIC_RELAXED);
        return code;
    }
}

/* ---- 128 shard buffers with INCREMENTAL FLUSH (bound memory regardless of hour size) --------- */
typedef struct { unsigned char sha[20]; unsigned char *data; uint32_t len; } cobj;
typedef struct { cobj *v; size_t n, cap, bytes; pthread_mutex_t mu; } sbuf;
static sbuf SH[NSHARD];
static int  TO_STDOUT = 0;
static const char *DB_SH; static size_t MAP_SIZE; static size_t FLUSH_BYTES; static size_t ZTHRESH = 512;
static long TOT_STORED = 0, TOT_DUP = 0, COMMIT_CNT = 0;

/* flush one shard's buffer to its LMDB env (caller holds SH[n].mu). OPEN/write/sync/CLOSE per flush
 * -- do NOT keep 128 envs mmap'd, or their touched pages accumulate in RSS (that + git_indexer was
 * the 74GB in the dry-run). One writer per env at a time (shard lock), so open/close is safe.
 * Dedup on MDB_NOOVERWRITE; frees the copied contents and resets the buffer. */
static void flush_shard_locked(int n) {
    sbuf *s = &SH[n]; if (s->n == 0 || TO_STDOUT) return;
    char path[1024]; snprintf(path, sizeof path, "%s/shard_%03d", DB_SH, n); mkdir(path, 0755);
    MDB_env *env; if (mdb_env_create(&env)) return;
    mdb_env_set_mapsize(env, MAP_SIZE); mdb_env_set_maxreaders(env, 8);
    if (mdb_env_open(env, path, 0, 0664)) { mdb_env_close(env); return; }
    MDB_txn *txn; MDB_dbi dbi;
    if (mdb_txn_begin(env, NULL, 0, &txn)) { mdb_env_close(env); return; }
    mdb_dbi_open(txn, NULL, 0, &dbi);
    long stored = 0, dup = 0; int r;
    for (size_t i = 0; i < s->n; i++) {
        void *vd = s->v[i].data; size_t vl = s->v[i].len; unsigned char *zbuf = NULL;
        if (vl >= ZTHRESH) {                              /* compress fat-tail values (0x01 tag) */
            uLongf zl = compressBound(vl); zbuf = malloc(zl + 1);
            if (zbuf && compress2(zbuf + 1, &zl, vd, vl, 6) == Z_OK && (size_t)zl + 1 < vl) {
                zbuf[0] = 1; vd = zbuf; vl = zl + 1;
            } else { free(zbuf); zbuf = NULL; }
        }
        MDB_val k = { 20, s->v[i].sha }, v = { vl, vd };
        r = mdb_put(txn, dbi, &k, &v, MDB_NOOVERWRITE);
        if (r == MDB_SUCCESS) stored++; else if (r == MDB_KEYEXIST) dup++;
        free(zbuf);
    }
    if (mdb_txn_commit(txn)) mdb_txn_abort(txn);
    mdb_env_sync(env, 1); mdb_env_close(env);
    for (size_t i = 0; i < s->n; i++) free(s->v[i].data);
    s->n = 0; s->bytes = 0;
    __atomic_fetch_add(&TOT_STORED, stored, __ATOMIC_RELAXED);
    __atomic_fetch_add(&TOT_DUP, dup, __ATOMIC_RELAXED);
}
static void sh_add(const unsigned char *sha, const void *data, uint32_t len) {
    __atomic_fetch_add(&COMMIT_CNT, 1, __ATOMIC_RELAXED);
    if (TO_STDOUT) { char hex[41]; for (int k=0;k<20;k++) sprintf(hex+2*k,"%02x",sha[k]);
        pthread_mutex_lock(&SH[0].mu); puts(hex); pthread_mutex_unlock(&SH[0].mu); return; }
    int n = sha[0] % NSHARD; sbuf *s = &SH[n];
    pthread_mutex_lock(&s->mu);
    if (s->n == s->cap) { s->cap = s->cap ? s->cap*2 : 4096; s->v = realloc(s->v, s->cap*sizeof(cobj)); }
    cobj *c = &s->v[s->n++]; memcpy(c->sha, sha, 20); c->len = len;
    c->data = malloc(len); memcpy(c->data, data, len); s->bytes += len + 24;
    if (s->bytes >= FLUSH_BYTES) flush_shard_locked(n);           /* incremental: keep RAM bounded */
    pthread_mutex_unlock(&s->mu);
}

/* ---- extract commits from an indexed pack via a per-thread scratch bare repo ----------------- */
static void reset_scratch(const char *scratch) {
    char pd[1100]; snprintf(pd, sizeof pd, "%s/objects/pack", scratch);
    DIR *d = opendir(pd); if (!d) return; struct dirent *e;
    while ((e = readdir(d))) { if (e->d_name[0]=='.') continue;
        char f[2400]; snprintf(f, sizeof f, "%s/%s", pd, e->d_name); unlink(f); }
    closedir(d);
}
struct wctx { git_odb *odb; long ncommit; };
static int walk_cb(const git_oid *id, void *payload) {
    struct wctx *c = payload; git_odb_object *o;
    if (git_odb_read(&o, c->odb, id) != 0) return 0;
    if (git_odb_object_type(o) == GIT_OBJECT_COMMIT) {
        sh_add(id->id, git_odb_object_data(o), (uint32_t)git_odb_object_size(o)); c->ncommit++;
    }
    git_odb_object_free(o); return 0;
}
/* stream-fetch a repo's commit-only pack directly into the indexer, then walk the odb for commits.
 * Returns commit count, or -1 on fetch/index error. Never holds the whole pack in RAM. */
static long fetch_extract(const char *fetchurl, const void *body, size_t blen, const char *scratch) {
    git_repository *grepo = NULL; git_odb *odb = NULL; git_indexer *idx = NULL;
    if (git_repository_init(&grepo, scratch, 1) != 0) return -1;
    git_repository_odb(&odb, grepo);
    char packdir[1100]; snprintf(packdir, sizeof packdir, "%s/objects/pack", scratch);
    git_indexer_progress st = {0};
    git_indexer_options iopt = GIT_INDEXER_OPTIONS_INIT; iopt.verify = 0;   /* skip connectivity check */
    if (git_indexer_new(&idx, packdir, 0, odb, &iopt) != 0) { git_odb_free(odb); git_repository_free(grepo); return -1; }
    fetch_ctx fc = { idx, &st, {0}, 0, 0, 0 };
    long code = http_stream(fetchurl, body, blen, &fc);
    free(fc.resid.p);
    long rc;
    if (code < 0) rc = -1;                       /* net/transport error   -> classify net  */
    else if (code != 200) rc = -code;            /* HTTP error (404->-404)-> classify gone  */
    else if (fc.err) rc = -999;                  /* pack sideband / index-append error       */
    else if (!fc.got_pack) rc = 0;               /* nothing new beyond haves (success, 0)    */
    else if (git_indexer_commit(idx, &st) != 0) rc = -999;
    else { git_odb_refresh(odb); struct wctx c = { odb, 0 }; git_odb_foreach(odb, walk_cb, &c); rc = c.ncommit; }
    git_indexer_free(idx); git_odb_free(odb); git_repository_free(grepo);
    reset_scratch(scratch);
    return rc;
}

/* ---- orchestration outputs (fail.txt / ok repo;head / classified counts) --------------------- */
static long OK_CNT = 0, FAIL_CNT = 0;
static long C_GONE = 0, C_THROTTLE = 0, C_NET = 0, C_OTHER = 0;
static buf_t FAILBUF = {0}, OKBUF = {0};                 /* mutex-guarded line accumulators */
static pthread_mutex_t OUTMU = PTHREAD_MUTEX_INITIALIZER;
static void classify(long code) {                        /* GitHub HTTP -> failure bucket */
    if (code == 429 || code == 403) __atomic_fetch_add(&C_THROTTLE,1,__ATOMIC_RELAXED);
    else if (code == 401 || code == 404 || code == 0) __atomic_fetch_add(&C_GONE,1,__ATOMIC_RELAXED);
    else if (code < 0) __atomic_fetch_add(&C_NET,1,__ATOMIC_RELAXED);
    else __atomic_fetch_add(&C_OTHER,1,__ATOMIC_RELAXED);
}
static void note_fail(const char *repo, long code, const char *stage) {
    __atomic_fetch_add(&FAIL_CNT,1,__ATOMIC_RELAXED); classify(code);
    pthread_mutex_lock(&OUTMU); buf_add(&FAILBUF, repo, strlen(repo)); buf_add(&FAILBUF, "\n", 1); pthread_mutex_unlock(&OUTMU);
    fprintf(stderr, "FAIL %s %s HTTP %ld\n", repo, stage, code);
}
static void note_ok(const char *repo, const char *head) {
    __atomic_fetch_add(&OK_CNT,1,__ATOMIC_RELAXED);
    if (head && *head) { pthread_mutex_lock(&OUTMU);
        buf_add(&OKBUF, repo, strlen(repo)); buf_add(&OKBUF, ";", 1); buf_add(&OKBUF, head, strlen(head)); buf_add(&OKBUF, "\n", 1);
        pthread_mutex_unlock(&OUTMU); }
}

/* ---- one repo: discover -> ls-refs -> fetch(filter tree:0) -> extract ------------------------ */
static void do_repo(const char *repo, const char *before, const char *head, const char *scratch) {
    char url[1024], u2[1200];
    snprintf(url, sizeof url, "https://github.com/%s", repo);
    snprintf(u2, sizeof u2, "%s/info/refs?service=git-upload-pack", url);
    buf_t disc = {0}; long code = http(u2, NULL, 0, &disc); free(disc.p);
    if (code != 200) { note_fail(repo, code, "discover"); return; }
    snprintf(u2, sizeof u2, "%s/git-upload-pack", url);
    buf_t body = {0};
    pkt(&body,"command=ls-refs\n"); pkt(&body,"object-format=sha1\n"); pkt_delim(&body);
    pkt(&body,"peel\n"); pkt(&body,"ref-prefix refs/heads/\n"); pkt(&body,"ref-prefix refs/tags/\n"); pkt_flush(&body);
    buf_t lr = {0}; code = http(u2, body.p, body.n, &lr); buf_reset(&body);
    if (code != 200) { note_fail(repo, code, "ls-refs"); free(body.p); free(lr.p); return; }
    buf_t wants = {0}; int nref = 0; parse_refs(&lr, &wants, &nref); free(lr.p);
    if (nref == 0) { note_fail(repo, 0, "no-refs"); free(body.p); free(wants.p); return; }
    pkt(&body,"command=fetch\n"); pkt(&body,"object-format=sha1\n"); pkt_delim(&body);
    for (int k = 0; k < nref; k++) { char w[64]; snprintf(w,sizeof w,"want %.40s\n", wants.p + (size_t)k*40); pkt(&body,w); }
    if (before && strlen(before) >= 40 && strncmp(before,"0000000000000000000000000000000000000000",40)) {
        char hv[64]; snprintf(hv,sizeof hv,"have %.40s\n",before); pkt(&body,hv); }
    pkt(&body,"ofs-delta\n"); pkt(&body,"no-progress\n"); pkt(&body,"filter tree:0\n"); pkt(&body,"done\n"); pkt_flush(&body);
    long nc = fetch_extract(u2, body.p, body.n, scratch); free(body.p); free(wants.p);
    if (nc < 0) { long e = -nc; note_fail(repo, e == 1 ? -1 : (e == 999 ? 500 : e), "fetch"); return; }
    note_ok(repo, head);
}

/* ---- worker pool: atomic work queue over the input lines ------------------------------------ */
static char **LINES; static long NLINES; static long NEXT = 0;
static const char *SCRATCH_ROOT;
static void *worker(void *arg) {
    long id = (long)arg; char scratch[256]; snprintf(scratch, sizeof scratch, "%s/w%ld", SCRATCH_ROOT, id);
    mkdir(scratch, 0755);
    for (;;) {
        long i = __atomic_fetch_add(&NEXT, 1, __ATOMIC_RELAXED); if (i >= NLINES) break;
        char *line = LINES[i]; char *repo = line, *before = NULL, *head = NULL;
        char *t = strpbrk(line, "\t;"); if (t) { *t = 0; before = t + 1;
            char *t2 = strpbrk(before, "\t;"); if (t2) { *t2 = 0; head = t2 + 1;
                char *t3 = strpbrk(head, "\t;"); if (t3) *t3 = 0; } }
        do_repo(repo, before, head, scratch);
    }
    return NULL;
}

/* ---- final residual flush (envs are opened/closed per flush, so nothing to open up front) ----- */
static long WNEXT = 0;
static void *final_flush(void *arg) {                   /* parallel flush of residual buffers */
    (void)arg;
    for (;;) { long n = __atomic_fetch_add(&WNEXT, 1, __ATOMIC_RELAXED); if (n >= NSHARD) break;
        pthread_mutex_lock(&SH[n].mu); flush_shard_locked((int)n); pthread_mutex_unlock(&SH[n].mu); }
    return NULL;
}

int main(int argc, char **argv) {
    curl_global_init(CURL_GLOBAL_DEFAULT); git_libgit2_init();
    DB_SH = getenv("DB_SH"); TO_STDOUT = (DB_SH == NULL);
    int PAR  = getenv("PAR")  ? atoi(getenv("PAR"))  : 16;   /* lower default: memory ~ PAR x indexer */
    int WPAR = getenv("WPAR") ? atoi(getenv("WPAR")) : 16;
    MAP_SIZE = (size_t)(getenv("SHARD_GB") ? atoi(getenv("SHARD_GB")) : 64) * 1024UL*1024*1024; /* sparse; 16->64 headroom */
    /* per-shard flush threshold: total RAM cap ~= NSHARD * FLUSH_MB (default 128*16MB = 2GB) */
    FLUSH_BYTES = (size_t)(getenv("FLUSH_MB") ? atoi(getenv("FLUSH_MB")) : 16) * 1024UL*1024;
    if (getenv("ZTHRESH")) ZTHRESH = (size_t)atol(getenv("ZTHRESH"));   /* compress values >= this */
    if (getenv("RATE_BACKOFF")) RATE_BACKOFF = atol(getenv("RATE_BACKOFF"));  /* 403 backoff base (s) */
    if (getenv("MAX_RETRY"))    MAX_RETRY    = atoi(getenv("MAX_RETRY"));     /* per-request retries  */
    /* DISK scratch by default: the indexer streams the pack here, so tmpfs would defeat the
     * streaming (pack back in RAM). Override SCRATCH_ROOT=/dev/shm only for small-pack workloads. */
    SCRATCH_ROOT = getenv("SCRATCH_ROOT"); if (!SCRATCH_ROOT) SCRATCH_ROOT = "/media/volume/trees/.gcrt_scratch";
    mkdir(SCRATCH_ROOT, 0755);
    for (int n = 0; n < NSHARD; n++) pthread_mutex_init(&SH[n].mu, NULL);

    /* slurp stdin -> LINES[] */
    size_t cap = 1024; LINES = malloc(cap * sizeof(char*)); char *line = NULL; size_t sz = 0; ssize_t r;
    while ((r = getline(&line, &sz, stdin)) >= 0) {
        if (r && line[r-1] == '\n') line[--r] = 0; if (!r) continue;
        if ((size_t)NLINES == cap) { cap *= 2; LINES = realloc(LINES, cap*sizeof(char*)); }
        LINES[NLINES++] = strdup(line);
    }
    free(line);

    time_t t0 = time(NULL);
    pthread_t th[512]; if (PAR > 512) PAR = 512;
    for (long i = 0; i < PAR; i++) pthread_create(&th[i], NULL, worker, (void*)i);
    for (long i = 0; i < PAR; i++) pthread_join(th[i], NULL);
    long t_fetch = time(NULL) - t0;

    /* most commits were already flushed incrementally during fetch; flush the residual buffers. */
    if (!TO_STDOUT) {
        pthread_t wt[64]; if (WPAR > 64) WPAR = 64;
        for (long i = 0; i < WPAR; i++) pthread_create(&wt[i], NULL, final_flush, NULL);
        for (long i = 0; i < WPAR; i++) pthread_join(wt[i], NULL);
    }
    long ncommits = COMMIT_CNT;
    long t_all = time(NULL) - t0;

    /* orchestration outputs for the gharchiveRThour FUSED drop-in: fail.txt, ok.txt (repo;head for
     * the p2tips 'commit' fence advance), and a manifest with the tokens gharchiveRThour parses. */
    const char *OUTDIR = getenv("OUTDIR");
    if (OUTDIR) {
        char fp[1200]; FILE *f;
        snprintf(fp, sizeof fp, "%s/fail.txt", OUTDIR); if ((f=fopen(fp,"w"))) { fwrite(FAILBUF.p,1,FAILBUF.n,f); fclose(f); }
        snprintf(fp, sizeof fp, "%s/ok.txt",   OUTDIR); if ((f=fopen(fp,"w"))) { fwrite(OKBUF.p,1,OKBUF.n,f);   fclose(f); }
        long uniq = getenv("UNIQUE") ? atol(getenv("UNIQUE")) : NLINES;
        const char *tag = getenv("TAG") ? getenv("TAG") : "rt";
        snprintf(fp, sizeof fp, "%s/manifest", OUTDIR);
        if ((f=fopen(fp,"w"))) { fprintf(f, "%s unique=%ld fetched=%ld fail=%ld gone=%ld throttle=%ld "
            "net=%ld other=%ld secs=%ld stored=%ld dup=%ld\n", tag, uniq, OK_CNT, FAIL_CNT,
            C_GONE, C_THROTTLE, C_NET, C_OTHER, t_all, TOT_STORED, TOT_DUP); fclose(f); }
    }
    fprintf(stderr, "[grabCommitsRT] repos=%ld ok=%ld fail=%ld (gone=%ld throttle=%ld net=%ld other=%ld) "
            "commits=%ld stored=%ld dup=%ld backoff_events=%ld fetch=%lds total=%lds par=%d wpar=%d\n", NLINES, OK_CNT,
            FAIL_CNT, C_GONE, C_THROTTLE, C_NET, C_OTHER, ncommits, TOT_STORED, TOT_DUP, BACKOFF_EVENTS, t_fetch, t_all, PAR, WPAR);
    git_libgit2_shutdown(); curl_global_cleanup();
    return 0;
}
