/* grabCommitsRT.c -- maximally-efficient commit-only RT fetcher (no per-project repos).
 *
 * WHY C: fetchNew.py hand-rolls protocol-v2 + `filter tree:0` (libgit2 has neither), but its pack
 * read is a pure-Python byte loop -> the GIL serializes any threaded fusion (measured 68x slower,
 * lost 76% of commits). C has no GIL: raw v2 client via libcurl -> in-memory pack -> git_indexer
 * (libgit2 does the delta resolution in C) -> git_odb walk -> commits, with real pthread parallelism
 * and no intermediate bare repo (no 195M-inode scaffolding, no double cat-file IO).
 *
 * v1 (this file): SINGLE-THREADED, reads `repo<TAB>before<TAB>head` (or ';'-separated) lines on
 * stdin, and for each: discover -> ls-refs (wants) -> fetch(want=tips, have=before, filter tree:0)
 * -> index pack -> emit the 40-hex sha of every COMMIT to stdout (for the side-by-side correctness
 * diff vs the Python path). NEXT: pthreads + write straight to commits_sh / tree-blob .bin sink.
 *
 * build: cc -O2 -o grabCommitsRT grabCommitsRT.c -I<fork>/include -L<fork>/build -lgit2 -lcurl -lz
 * run:   printf 'owner/repo\t<before40>\t<head40>\n' | LD_LIBRARY_PATH=<fork>/build ./grabCommitsRT
 */
#include <git2.h>
#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

/* ---- growable byte buffer ------------------------------------------------------------------- */
typedef struct { char *p; size_t n, cap; } buf_t;
static void buf_add(buf_t *b, const void *d, size_t n) {
    if (b->n + n > b->cap) { b->cap = (b->n + n) * 2 + 4096; b->p = realloc(b->p, b->cap); }
    memcpy(b->p + b->n, d, n); b->n += n;
}
static void buf_reset(buf_t *b) { b->n = 0; }

/* ---- pkt-line ------------------------------------------------------------------------------- */
static void pkt(buf_t *b, const char *s) {
    char h[5]; size_t L = strlen(s) + 4; snprintf(h, sizeof h, "%04zx", L);
    buf_add(b, h, 4); buf_add(b, s, strlen(s));
}
static void pkt_flush(buf_t *b) { buf_add(b, "0000", 4); }
static void pkt_delim(buf_t *b) { buf_add(b, "0001", 4); }

/* ---- libcurl transport ---------------------------------------------------------------------- */
static size_t wcb(void *d, size_t sz, size_t nm, void *u) { buf_add((buf_t *)u, d, sz * nm); return sz * nm; }

/* GET (body==NULL) or POST git-upload-pack; returns HTTP code (200 ok), -1 on transport error. */
static long http(const char *url, const void *body, size_t blen, buf_t *out) {
    CURL *c = curl_easy_init(); if (!c) return -1;
    struct curl_slist *h = NULL;
    h = curl_slist_append(h, "Git-Protocol: version=2");
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

/* ---- pkt-line response walker: calls cb(payload,len,band_section?) per data pkt --------------- */
/* returns via out params; here we provide two specialized parsers. */

/* parse capability/ref advertisement or ls-refs: collect first token (oid) of each data line into refs */
static void parse_refs(buf_t *r, buf_t *wants /* space-free: 40-hex oids concatenated */, int *nref) {
    size_t i = 0; *nref = 0;
    while (i + 4 <= r->n) {
        char hx[5]; memcpy(hx, r->p + i, 4); hx[4] = 0;
        long L = strtol(hx, NULL, 16);
        if (L == 0 || L == 1 || L == 2) { i += 4; continue; }       /* flush/delim/end */
        if (L < 4 || i + L > r->n) break;
        char *pl = r->p + i + 4; size_t pn = L - 4;
        /* a ref line: "<oid> <refname>...". take the leading 40/64 hex as a want. */
        if (pn >= 40) {
            int hex = 1; for (int k = 0; k < 40; k++) { char ch = pl[k];
                if (!((ch>='0'&&ch<='9')||(ch>='a'&&ch<='f'))) { hex = 0; break; } }
            if (hex) { buf_add(wants, pl, 40); (*nref)++; }
        }
        i += L;
    }
}

/* demux the fetch response: append band-1 (pack) bytes into pack. */
static void parse_pack(buf_t *r, buf_t *pack) {
    size_t i = 0; int in_pack = 0;
    while (i + 4 <= r->n) {
        char hx[5]; memcpy(hx, r->p + i, 4); hx[4] = 0;
        long L = strtol(hx, NULL, 16);
        if (L == 0 || L == 1 || L == 2) { i += 4; continue; }
        if (L < 4 || i + L > r->n) break;
        char *pl = r->p + i + 4; size_t pn = L - 4;
        if (pn >= 9 && !memcmp(pl, "packfile\n", 9)) { in_pack = 1; i += L; continue; }
        if (pn >= 8 && (!memcmp(pl,"acknowl",7)||!memcmp(pl,"shallow",7)||!memcmp(pl,"wanted-",7))) { in_pack = 0; i += L; continue; }
        if (in_pack && pn >= 1) {
            unsigned char band = (unsigned char)pl[0];
            if (band == 1) buf_add(pack, pl + 1, pn - 1);       /* pack data */
            else if (band == 3) { fprintf(stderr, "remote error: %.*s\n", (int)(pn-1), pl+1); }
            /* band 2 = progress -> ignore */
        }
        i += L;
    }
}

/* ---- extract commits from an indexed pack via a scratch bare repo --------------------------- */
static const char *SCRATCH = NULL;
struct walk_ctx { git_odb *odb; long ncommit; };
static int walk_cb(const git_oid *id, void *payload) {
    struct walk_ctx *c = payload; git_odb_object *o;
    if (git_odb_read(&o, c->odb, id) != 0) return 0;
    if (git_odb_object_type(o) == GIT_OBJECT_COMMIT) {
        char hex[41]; git_oid_tostr(hex, sizeof hex, id);
        fputs(hex, stdout); fputc('\n', stdout);           /* v1: emit sha for correctness diff */
        c->ncommit++;
    }
    git_odb_object_free(o);
    return 0;
}

static long extract_commits(buf_t *pack) {
    if (pack->n < 4 || memcmp(pack->p, "PACK", 4)) return 0;
    git_repository *repo = NULL; git_odb *odb = NULL; git_indexer *idx = NULL;
    if (git_repository_init(&repo, SCRATCH, 1) != 0) return -1;
    git_repository_odb(&odb, repo);
    char packdir[1024]; snprintf(packdir, sizeof packdir, "%s/objects/pack", SCRATCH);
    git_indexer_progress st = {0};
    if (git_indexer_new(&idx, packdir, 0, odb, NULL) != 0) { git_odb_free(odb); git_repository_free(repo); return -1; }
    long rc = 0;
    if (git_indexer_append(idx, pack->p, pack->n, &st) != 0 || git_indexer_commit(idx, &st) != 0) rc = -1;
    git_indexer_free(idx);
    if (rc == 0) {
        git_odb_refresh(odb);
        struct walk_ctx c = { odb, 0 };
        git_odb_foreach(odb, walk_cb, &c);
        rc = c.ncommit;
    }
    git_odb_free(odb); git_repository_free(repo);
    /* reset scratch: drop the pack so the next repo starts clean */
    char cmd[1100]; snprintf(cmd, sizeof cmd, "rm -f %s/objects/pack/*", SCRATCH); if (system(cmd)) {}
    return rc;
}

/* ---- one repo: discover -> ls-refs -> fetch(filter tree:0) -> extract ------------------------ */
static void do_repo(const char *repo, const char *before) {
    char url[1024], u2[1100];
    snprintf(url, sizeof url, "https://github.com/%s", repo);
    /* discover (v2 caps) -- we only need it to confirm reachability; assume sha1 + filter (GitHub) */
    snprintf(u2, sizeof u2, "%s/info/refs?service=git-upload-pack", url);
    buf_t disc = {0}; long code = http(u2, NULL, 0, &disc);
    if (code != 200) { fprintf(stderr, "FAIL %s discover HTTP %ld\n", repo, code); free(disc.p); return; }
    free(disc.p);
    /* ls-refs -> wants */
    snprintf(u2, sizeof u2, "%s/git-upload-pack", url);
    buf_t body = {0};
    pkt(&body, "command=ls-refs\n"); pkt(&body, "object-format=sha1\n"); pkt_delim(&body);
    pkt(&body, "peel\n"); pkt(&body, "ref-prefix refs/heads/\n"); pkt(&body, "ref-prefix refs/tags/\n"); pkt_flush(&body);
    buf_t lr = {0}; code = http(u2, body.p, body.n, &lr); buf_reset(&body);
    if (code != 200) { fprintf(stderr, "FAIL %s ls-refs HTTP %ld\n", repo, code); free(body.p); free(lr.p); return; }
    buf_t wants = {0}; int nref = 0; parse_refs(&lr, &wants, &nref); free(lr.p);
    if (nref == 0) { fprintf(stderr, "FAIL %s no refs\n", repo); free(body.p); free(wants.p); return; }
    /* fetch: want=<tips> have=<before> filter tree:0 */
    pkt(&body, "command=fetch\n"); pkt(&body, "object-format=sha1\n"); pkt_delim(&body);
    for (int k = 0; k < nref; k++) { char w[64]; snprintf(w, sizeof w, "want %.40s\n", wants.p + k*40); pkt(&body, w); }
    if (before && strlen(before) >= 40 && strncmp(before, "0000000000000000000000000000000000000000", 40)) {
        char hv[64]; snprintf(hv, sizeof hv, "have %.40s\n", before); pkt(&body, hv);
    }
    pkt(&body, "ofs-delta\n"); pkt(&body, "no-progress\n"); pkt(&body, "filter tree:0\n"); pkt(&body, "done\n"); pkt_flush(&body);
    buf_t fr = {0}; code = http(u2, body.p, body.n, &fr); free(body.p); free(wants.p);
    if (code != 200) { fprintf(stderr, "FAIL %s fetch HTTP %ld\n", repo, code); free(fr.p); return; }
    buf_t pack = {0}; parse_pack(&fr, &pack); free(fr.p);
    long nc = extract_commits(&pack); free(pack.p);
    fprintf(stderr, "OK %s refs=%d commits=%ld\n", repo, nref, nc < 0 ? 0 : nc);
}

int main(int argc, char **argv) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    git_libgit2_init();
    SCRATCH = getenv("SCRATCH"); if (!SCRATCH) SCRATCH = "/dev/shm/grabCommitsRT.scratch";
    mkdir(SCRATCH, 0755);
    char *line = NULL; size_t sz = 0; ssize_t r;
    while ((r = getline(&line, &sz, stdin)) >= 0) {
        if (r && line[r-1] == '\n') line[r-1] = 0;
        if (!*line) continue;
        /* split on TAB or ';' : repo, before, head */
        char *repo = line, *before = NULL;
        char *t = strpbrk(line, "\t;"); if (t) { *t = 0; before = t + 1; char *t2 = strpbrk(before, "\t;"); if (t2) *t2 = 0; }
        do_repo(repo, before);
    }
    free(line);
    git_libgit2_shutdown(); curl_global_cleanup();
    return 0;
}
