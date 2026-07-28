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
static long http(const char *url, const void *body, size_t blen, buf_t *out) {
    CURL *c = curl_easy_init(); if (!c) return -1;
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
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, wcb);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, out);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, 600L);
    curl_easy_setopt(c, CURLOPT_USERAGENT, "git/2.43 grabCommitsRT");
    CURLcode rc = curl_easy_perform(c);
    long code = -1; if (rc == CURLE_OK) curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &code);
    curl_slist_free_all(h); curl_easy_cleanup(c);
    return rc == CURLE_OK ? code : -1;
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
static void parse_pack(buf_t *r, buf_t *pack) {
    size_t i = 0; int in_pack = 0;
    while (i + 4 <= r->n) {
        char hx[5]; memcpy(hx, r->p + i, 4); hx[4] = 0; long L = strtol(hx, NULL, 16);
        if (L == 0 || L == 1 || L == 2) { i += 4; continue; }
        if (L < 4 || i + (size_t)L > r->n) break;
        char *pl = r->p + i + 4; size_t pn = L - 4;
        if (pn >= 9 && !memcmp(pl, "packfile\n", 9)) { in_pack = 1; i += L; continue; }
        if (pn >= 7 && (!memcmp(pl,"acknowl",7)||!memcmp(pl,"shallow",7)||!memcmp(pl,"wanted-",7))) { in_pack = 0; i += L; continue; }
        if (in_pack && pn >= 1) {
            unsigned char band = (unsigned char)pl[0];
            if (band == 1) buf_add(pack, pl + 1, pn - 1);
            else if (band == 3) fprintf(stderr, "remote error: %.*s\n", (int)(pn-1), pl+1);
        }
        i += L;
    }
}

/* ---- 128 shard buffers (commits pending write) ---------------------------------------------- */
typedef struct { unsigned char sha[20]; unsigned char *data; uint32_t len; } cobj;
typedef struct { cobj *v; size_t n, cap; pthread_mutex_t mu; } sbuf;
static sbuf SH[NSHARD];
static int  TO_STDOUT = 0;
static void sh_add(const unsigned char *sha, const void *data, uint32_t len) {
    if (TO_STDOUT) { char hex[41]; for (int k=0;k<20;k++) sprintf(hex+2*k,"%02x",sha[k]);
        pthread_mutex_lock(&SH[0].mu); puts(hex); pthread_mutex_unlock(&SH[0].mu); return; }
    int n = sha[0] % NSHARD; sbuf *s = &SH[n];
    pthread_mutex_lock(&s->mu);
    if (s->n == s->cap) { s->cap = s->cap ? s->cap*2 : 4096; s->v = realloc(s->v, s->cap*sizeof(cobj)); }
    cobj *c = &s->v[s->n++]; memcpy(c->sha, sha, 20); c->len = len;
    c->data = malloc(len); memcpy(c->data, data, len);
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
static long extract_commits(buf_t *pack, const char *scratch) {
    if (pack->n < 4 || memcmp(pack->p, "PACK", 4)) return 0;
    git_repository *repo = NULL; git_odb *odb = NULL; git_indexer *idx = NULL;
    if (git_repository_init(&repo, scratch, 1) != 0) return -1;
    git_repository_odb(&odb, repo);
    char packdir[1100]; snprintf(packdir, sizeof packdir, "%s/objects/pack", scratch);
    git_indexer_progress st = {0}; long rc = 0;
    if (git_indexer_new(&idx, packdir, 0, odb, NULL) != 0) { git_odb_free(odb); git_repository_free(repo); return -1; }
    if (git_indexer_append(idx, pack->p, pack->n, &st) != 0 || git_indexer_commit(idx, &st) != 0) rc = -1;
    git_indexer_free(idx);
    if (rc == 0) { git_odb_refresh(odb); struct wctx c = { odb, 0 }; git_odb_foreach(odb, walk_cb, &c); rc = c.ncommit; }
    git_odb_free(odb); git_repository_free(repo);
    reset_scratch(scratch);
    return rc;
}

/* ---- one repo: discover -> ls-refs -> fetch(filter tree:0) -> extract ------------------------ */
static long OK_CNT = 0, FAIL_CNT = 0;
static void do_repo(const char *repo, const char *before, const char *scratch) {
    char url[1024], u2[1200];
    snprintf(url, sizeof url, "https://github.com/%s", repo);
    snprintf(u2, sizeof u2, "%s/info/refs?service=git-upload-pack", url);
    buf_t disc = {0}; long code = http(u2, NULL, 0, &disc); free(disc.p);
    if (code != 200) { __atomic_fetch_add(&FAIL_CNT,1,__ATOMIC_RELAXED); fprintf(stderr, "FAIL %s discover HTTP %ld\n", repo, code); return; }
    snprintf(u2, sizeof u2, "%s/git-upload-pack", url);
    buf_t body = {0};
    pkt(&body,"command=ls-refs\n"); pkt(&body,"object-format=sha1\n"); pkt_delim(&body);
    pkt(&body,"peel\n"); pkt(&body,"ref-prefix refs/heads/\n"); pkt(&body,"ref-prefix refs/tags/\n"); pkt_flush(&body);
    buf_t lr = {0}; code = http(u2, body.p, body.n, &lr); buf_reset(&body);
    if (code != 200) { __atomic_fetch_add(&FAIL_CNT,1,__ATOMIC_RELAXED); fprintf(stderr,"FAIL %s ls-refs HTTP %ld\n",repo,code); free(body.p); free(lr.p); return; }
    buf_t wants = {0}; int nref = 0; parse_refs(&lr, &wants, &nref); free(lr.p);
    if (nref == 0) { __atomic_fetch_add(&FAIL_CNT,1,__ATOMIC_RELAXED); fprintf(stderr,"FAIL %s no refs\n",repo); free(body.p); free(wants.p); return; }
    pkt(&body,"command=fetch\n"); pkt(&body,"object-format=sha1\n"); pkt_delim(&body);
    for (int k = 0; k < nref; k++) { char w[64]; snprintf(w,sizeof w,"want %.40s\n", wants.p + (size_t)k*40); pkt(&body,w); }
    if (before && strlen(before) >= 40 && strncmp(before,"0000000000000000000000000000000000000000",40)) {
        char hv[64]; snprintf(hv,sizeof hv,"have %.40s\n",before); pkt(&body,hv); }
    pkt(&body,"ofs-delta\n"); pkt(&body,"no-progress\n"); pkt(&body,"filter tree:0\n"); pkt(&body,"done\n"); pkt_flush(&body);
    buf_t fr = {0}; code = http(u2, body.p, body.n, &fr); free(body.p); free(wants.p);
    if (code != 200) { __atomic_fetch_add(&FAIL_CNT,1,__ATOMIC_RELAXED); fprintf(stderr,"FAIL %s fetch HTTP %ld\n",repo,code); free(fr.p); return; }
    buf_t pack = {0}; parse_pack(&fr, &pack); free(fr.p);
    long nc = extract_commits(&pack, scratch); free(pack.p);
    __atomic_fetch_add(&OK_CNT,1,__ATOMIC_RELAXED);
    if (nc < 0) fprintf(stderr, "WARN %s index failed\n", repo);
}

/* ---- worker pool: atomic work queue over the input lines ------------------------------------ */
static char **LINES; static long NLINES; static long NEXT = 0;
static const char *SCRATCH_ROOT;
static void *worker(void *arg) {
    long id = (long)arg; char scratch[256]; snprintf(scratch, sizeof scratch, "%s/w%ld", SCRATCH_ROOT, id);
    mkdir(scratch, 0755);
    for (;;) {
        long i = __atomic_fetch_add(&NEXT, 1, __ATOMIC_RELAXED); if (i >= NLINES) break;
        char *line = LINES[i]; char *repo = line, *before = NULL;
        char *t = strpbrk(line, "\t;"); if (t) { *t = 0; before = t + 1;
            char *t2 = strpbrk(before, "\t;"); if (t2) *t2 = 0; }
        do_repo(repo, before, scratch);
    }
    return NULL;
}

/* ---- parallel LMDB write phase (WPAR threads over 128 shards) -------------------------------- */
static const char *DB_SH; static size_t MAP_SIZE; static long WNEXT = 0;
static long TOT_STORED = 0, TOT_DUP = 0;
static void write_shard(int n) {
    sbuf *s = &SH[n]; if (s->n == 0) return;
    char path[1024]; snprintf(path, sizeof path, "%s/shard_%03d", DB_SH, n);
    mkdir(path, 0755);                                  /* subdir env needs the dir to pre-exist */
    MDB_env *env; MDB_txn *txn; MDB_dbi dbi; int r;
    if (mdb_env_create(&env)) return;
    mdb_env_set_mapsize(env, MAP_SIZE); mdb_env_set_maxreaders(env, 256);
    if ((r = mdb_env_open(env, path, 0, 0664))) { fprintf(stderr,"shard %d open: %s\n",n,mdb_strerror(r)); mdb_env_close(env); return; }
    if ((r = mdb_txn_begin(env, NULL, 0, &txn))) { mdb_env_close(env); return; }
    mdb_dbi_open(txn, NULL, 0, &dbi);
    long stored = 0, dup = 0;
    for (size_t i = 0; i < s->n; i++) {
        MDB_val k = { 20, s->v[i].sha }, v = { s->v[i].len, s->v[i].data };
        r = mdb_put(txn, dbi, &k, &v, MDB_NOOVERWRITE);
        if (r == MDB_SUCCESS) stored++; else if (r == MDB_KEYEXIST) dup++;
        else { fprintf(stderr,"shard %d put: %s\n",n,mdb_strerror(r)); }
    }
    if (mdb_txn_commit(txn)) mdb_txn_abort(txn);
    mdb_env_sync(env, 1); mdb_env_close(env);
    __atomic_fetch_add(&TOT_STORED, stored, __ATOMIC_RELAXED);
    __atomic_fetch_add(&TOT_DUP, dup, __ATOMIC_RELAXED);
}
static void *writer(void *arg) {
    (void)arg; for (;;) { long n = __atomic_fetch_add(&WNEXT, 1, __ATOMIC_RELAXED); if (n >= NSHARD) break; write_shard((int)n); }
    return NULL;
}

int main(int argc, char **argv) {
    curl_global_init(CURL_GLOBAL_DEFAULT); git_libgit2_init();
    DB_SH = getenv("DB_SH"); TO_STDOUT = (DB_SH == NULL);
    int PAR  = getenv("PAR")  ? atoi(getenv("PAR"))  : 32;
    int WPAR = getenv("WPAR") ? atoi(getenv("WPAR")) : 16;
    MAP_SIZE = (size_t)(getenv("SHARD_GB") ? atoi(getenv("SHARD_GB")) : 16) * 1024UL*1024*1024;
    SCRATCH_ROOT = getenv("SCRATCH_ROOT"); if (!SCRATCH_ROOT) SCRATCH_ROOT = "/dev/shm/gcrt";
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

    long ncommits = 0; for (int n = 0; n < NSHARD; n++) ncommits += SH[n].n;
    if (!TO_STDOUT && ncommits) {
        pthread_t wt[64]; if (WPAR > 64) WPAR = 64;
        for (long i = 0; i < WPAR; i++) pthread_create(&wt[i], NULL, writer, NULL);
        for (long i = 0; i < WPAR; i++) pthread_join(wt[i], NULL);
    }
    long t_all = time(NULL) - t0;
    fprintf(stderr, "[grabCommitsRT] repos=%ld ok=%ld fail=%ld commits=%ld stored=%ld dup=%ld "
            "fetch=%lds total=%lds par=%d wpar=%d\n", NLINES, OK_CNT, FAIL_CNT, ncommits,
            TOT_STORED, TOT_DUP, t_fetch, t_all, PAR, WPAR);
    git_libgit2_shutdown(); curl_global_cleanup();
    return 0;
}
