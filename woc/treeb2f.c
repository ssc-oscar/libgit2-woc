/* treeb2f.c -- extract blob->filepath from a repo's trees at grab time.
 *
 * Reads commit SHAs on stdin, opens repo (argv[1]); for each DISTINCT commit
 * root-tree (memoized), git_tree_walk(PRE) emits one line per blob entry:
 *     <blob-oid>;<full-path>
 * Two dedup layers (experiment showed per-repo dedup captures ~100% of the
 * reduction -- inter-repo (blob,path) overlap is <1%, so no per-shard/global set
 * is needed here; a downstream merge handles the residual):
 *   - root-tree memo (oid set): skip commits whose root tree was already walked
 *     -> avoids re-walking identical snapshots (walk-CPU).
 *   - (blob,path) dedup (64-bit fingerprint set): emit each unique pair once
 *     per repo -> avoids the ~65x per-commit raw stream (output volume).
 * Downstream: pick shortest path per blob globally + align to blob_<sec>.idx.
 *
 * Names: ';' -> ':' and CR/LF -> '?' so the delimiter/line framing is safe.
 */
#include <git2.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "common.h"

/* --- git_oid hash set (root-tree memo) --- */
typedef struct { git_oid *s; char *u; size_t cap, n; } oidset;
static int os_add(oidset *o, const git_oid *id);
static void os_init(oidset *o){ o->cap=1024; o->n=0; o->s=calloc(o->cap,sizeof(git_oid)); o->u=calloc(o->cap,1); }
static size_t os_h(const git_oid *id, size_t cap){ unsigned long long h=1469598103934665603ULL; for(int i=0;i<20;i++){h^=id->id[i]; h*=1099511628211ULL;} return (size_t)(h & (cap-1)); }
static void os_grow(oidset *o){ size_t oc=o->cap; git_oid*os_=o->s; char*ou=o->u; o->cap*=2; o->s=calloc(o->cap,sizeof(git_oid)); o->u=calloc(o->cap,1); o->n=0; for(size_t i=0;i<oc;i++) if(ou[i]) os_add(o,&os_[i]); free(os_); free(ou); }
static int os_add(oidset *o, const git_oid *id){ if((o->n+1)*10>=o->cap*7) os_grow(o); size_t h=os_h(id,o->cap); while(o->u[h]){ if(memcmp(o->s[h].id,id->id,20)==0) return 0; h=(h+1)&(o->cap-1);} o->s[h]=*id; o->u[h]=1; o->n++; return 1; }

/* --- u64 fingerprint set ((blob,path) dedup) --- */
typedef struct { unsigned long long *k; char *u; size_t cap, n; } fpset;
static int fp_add(fpset *f, unsigned long long key);
static void fp_init(fpset *f){ f->cap=4096; f->n=0; f->k=calloc(f->cap,8); f->u=calloc(f->cap,1); }
static void fp_grow(fpset *f){ size_t oc=f->cap; unsigned long long*ok=f->k; char*ou=f->u; f->cap*=2; f->k=calloc(f->cap,8); f->u=calloc(f->cap,1); f->n=0; for(size_t i=0;i<oc;i++) if(ou[i]) fp_add(f,ok[i]); free(ok); free(ou); }
static int fp_add(fpset *f, unsigned long long key){ if((f->n+1)*10>=f->cap*7) fp_grow(f); size_t h=(size_t)(key & (f->cap-1)); while(f->u[h]){ if(f->k[h]==key) return 0; h=(h+1)&(f->cap-1);} f->k[h]=key; f->u[h]=1; f->n++; return 1; }

static unsigned long long fnv1a(const char *p, size_t n){ unsigned long long h=1469598103934665603ULL; for(size_t i=0;i<n;i++){h^=(unsigned char)p[i]; h*=1099511628211ULL;} return h; }

static fpset SEEN;            /* (blob,path) dedup, per process == per repo */

static int cb(const char *root, const git_tree_entry *e, void *payload){
  (void)payload;
  if(git_tree_entry_type(e)!=GIT_OBJ_BLOB) return 0;   /* recurse into subtrees */
  char oid[GIT_OID_HEXSZ+1];
  git_oid_tostr(oid,sizeof(oid),git_tree_entry_id(e));
  const char *name=git_tree_entry_name(e);
  /* build "oid;root+name" into a small buffer for fp + emit */
  char buf[8192]; size_t k=0;
  for(int i=0;i<GIT_OID_HEXSZ && k<sizeof(buf)-1;i++) buf[k++]=oid[i];
  if(k<sizeof(buf)-1) buf[k++]=';';
  for(const char*p=root; *p && k<sizeof(buf)-1; ++p){ char c=*p; if(c=='\n'||c=='\r')c='?'; else if(c==';')c=':'; buf[k++]=c; }
  for(const char*p=name; *p && k<sizeof(buf)-1; ++p){ char c=*p; if(c=='\n'||c=='\r')c='?'; else if(c==';')c=':'; buf[k++]=c; }
  buf[k]=0;
  if(fp_add(&SEEN, fnv1a(buf,k))){ fwrite(buf,1,k,stdout); fputc('\n',stdout); }
  return 0;
}

int main(int argc, char *argv[]){
  git_repository *repo;
  git_libgit2_init();
  if(check_lg2(git_repository_open_bare(&repo, argv[1]), "Could not open repository", NULL)!=0) exit(-1);
  oidset roots; os_init(&roots); fp_init(&SEEN);
  char *l=NULL; size_t sz=0;
  while(getline(&l,&sz,stdin)>=0){
    char *s=strdup(l); s[strcspn(s,"\r\n")]=0;
    git_object *obj=NULL;
    if(git_revparse_single(&obj,repo,s)==0 && git_object_type(obj)==GIT_OBJ_COMMIT){
      const git_oid *tid=git_commit_tree_id((git_commit*)obj);
      if(os_add(&roots,tid)){
        git_tree *t=NULL;
        if(git_tree_lookup(&t,repo,tid)==0){ git_tree_walk(t,GIT_TREEWALK_PRE,cb,NULL); git_tree_free(t); }
      }
    }
    if(obj) git_object_free(obj);
    free(s);
  }
  git_repository_free(repo);
  git_libgit2_shutdown();
  return 0;
}
