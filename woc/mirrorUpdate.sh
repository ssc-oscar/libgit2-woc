#!/bin/bash
# Refresh a directory of --mirror clones and extract only the NEW objects.
#  * existing mirrors: snapshot ref tips, `git remote update --prune` (mirror
#    fetch pulls only new objects), then list objects reachable from the new
#    tips but not the old ones;
#  * with --list <urls>: also `git clone --mirror` any listed project that is
#    ABSENT (newly added) -- for those, every object is new;
#  * emits an olist (repo;type;sha;path) of the new objects for grab*.
#
# (doOtrVer.sh only clones absent repos and never refreshes present ones; this
#  fills that gap for kept collections like Chromium-Gerrit.)
#
#   mirrorUpdate.sh <dir> [--list <urls>] [--out <olist>] [--par N]
# Then extract (cwd = <dir>):
#   cat <olist> | perl -I ~/lib64/perl5 ~/bin/grabGitI.perl <base>
#   (optionally pipe through hasObj.perl first, like runExo, for global dedup).
set -u
dir=${1:?usage: mirrorUpdate.sh <dir> [--list urls] [--out olist] [--par N]}; shift
LIST=""; OUT=""; PAR=8
while [ $# -gt 0 ]; do case $1 in
  --list) LIST=$2; shift 2;; --out) OUT=$2; shift 2;; --par) PAR=$2; shift 2;; *) shift;; esac; done
OUT=${OUT:-$dir/new-objects.olist}
WORK=$(mktemp -d); export dir WORK
cd "$dir" || exit 1

# URL -> directory name (same scheme as doOtrVer.sh, fully flattened)
mangle(){ perl -ane 's|^gh:([^/]+)/|$1_|;s|^bb:([^/]+)/|bitbucket.org_$1_|;s|^gl:([^/]+)/|gitlab.com_$1_|;s|^dr:([^/]+)/|drupal.com_$1_|;s|^https://([^/]*)/([^/]*)/|$1_$2_|;s|^https://([^/]*)/|$1_|;print'; }
mkurl(){ sed 's|^https://|https://a:a@|;s|^https://a:a@git.launchpad.net/|lp:|'; }

# clone phase: add newly-listed projects that are absent (all their objects new)
if [ -n "$LIST" ]; then
  while read -r u; do
    [ -z "$u" ] && continue
    j=$(printf '%s' "$u" | mangle); r=$(printf '%s' "$u" | mkurl)
    git --git-dir="$j" rev-parse --is-bare-repository >/dev/null 2>&1 \
      && [ -n "$(git --git-dir="$j" for-each-ref --count=1 2>/dev/null)" ] && continue
    # init+fetch (works when $j holds nested child subrepos; --mirror clone cannot)
    mkdir -p "$j"; git init -q --bare "$j" >/dev/null 2>&1 || { echo "CLONEFAIL $u" >&2; continue; }
    git --git-dir="$j" config remote.origin.url "$r"
    git --git-dir="$j" config remote.origin.mirror true
    git --git-dir="$j" config remote.origin.fetch '+refs/*:refs/*'
    if git --git-dir="$j" remote update >/dev/null 2>&1; then : > "$WORK/${j//\//_}.NEW"; echo "cloned NEW $j"
    else echo "CLONEFAIL $u" >&2; fi
  done < "$LIST"
fi

worker(){
  local r=$1 gd=$dir/$1 key
  git --git-dir="$gd" config --get remote.origin.mirror >/dev/null 2>&1 || return
  key=${r//\//_}
  if [ -f "$WORK/$key.NEW" ]; then
    git --git-dir="$gd" rev-list --objects --all 2>/dev/null > "$WORK/$key.no"      # freshly cloned: all new
  else
    git --git-dir="$gd" for-each-ref --format='%(objectname)' | sort -u > "$WORK/$key.old"
    git --git-dir="$gd" remote update --prune >/dev/null 2>&1 || { echo "FETCHFAIL $r" >&2; return; }
    { git --git-dir="$gd" for-each-ref --format='%(objectname)'; sed 's/^/^/' "$WORK/$key.old"; } \
      | git --git-dir="$gd" rev-list --objects --stdin 2>/dev/null > "$WORK/$key.no"
  fi
  [ -s "$WORK/$key.no" ] || return
  cut -d' ' -f1 "$WORK/$key.no" | git --git-dir="$gd" cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null > "$WORK/$key.ty"
  awk -v R="$r" 'NR==FNR{t[$1]=$2; next}{o=$1; $1=""; print R";"t[o]";"o";"substr($0,2)}' \
    "$WORK/$key.ty" "$WORK/$key.no" > "$WORK/$key.olist"
}
export -f worker

# discover bare repos at ANY depth (deep paths nest as subfolders), repo = dir holding objects/
find . -type d -name objects -prune 2>/dev/null | sed 's#/objects$##; s#^\./##' \
  | xargs -P "$PAR" -I{} bash -c 'worker "$@"' _ {}

cat "$WORK"/*.olist > "$OUT" 2>/dev/null
echo "new objects: $(wc -l < "$OUT" 2>/dev/null || echo 0) -> $OUT"
echo "  by type:"; cut -d';' -f2 "$OUT" 2>/dev/null | sort | uniq -c | sed 's/^/    /'
rm -rf "$WORK"
