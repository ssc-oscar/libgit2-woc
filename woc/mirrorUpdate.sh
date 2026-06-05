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
#   mirrorUpdate.sh <dir> [--list <urls>] [--out <olist>] [--par N] [--initial]
# Then extract (cwd = <dir>):
#   cat <olist> | perl -I ~/lib64/perl5 ~/bin/grabGitI.perl <base>
#   (optionally pipe through hasObj.perl first, like runExo, for global dedup).
#
# --initial (a.k.a. --all): FIRST/initial extraction of a kept collection that
#   has never been extracted before. Instead of the tip-diff (objects new since
#   the last snapshot), list ALL objects for EVERY repo -- i.e. take the
#   freshly-cloned path (`git rev-list --objects --all`) for every repo, with no
#   `remote update`. Global WoC dedup (runExo's da5 hasObj step) then trims the
#   set; this mode just produces the complete olist.
#   git-cinnabar caveat: hg.mozilla.org mirrors converted with git-cinnabar keep
#   their OWN metadata under refs/cinnabar/* and refs/notes/cinnabar (a metadata
#   commit plus helper trees/blobs) -- these are NOT real upstream objects. For
#   any repo carrying such refs, --initial lists objects reachable from the real
#   refs only (everything except refs/cinnabar/* and refs/notes/cinnabar) rather
#   than --all, so the cinnabar bookkeeping objects are excluded.
set -u
dir=${1:?usage: mirrorUpdate.sh <dir> [--list urls] [--out olist] [--par N] [--initial]}; shift
LIST=""; OUT=""; PAR=8; INITIAL=0
while [ $# -gt 0 ]; do case $1 in
  --list) LIST=$2; shift 2;; --out) OUT=$2; shift 2;; --par) PAR=$2; shift 2;;
  --initial|--all) INITIAL=1; shift;; *) shift;; esac; done
export INITIAL
OUT=${OUT:-$dir/new-objects.olist}
# WORK holds one per-repo olist each (for --initial these sum to the whole
# collection -- many GB). Default it next to $OUT on the big output disk instead
# of /tmp, unless the caller pinned $TMPDIR. (tip-diff mode is small; either is
# fine there.) mktemp still honors an explicit $TMPDIR for both modes.
if [ "$INITIAL" = 1 ] && [ -z "${TMPDIR:-}" ]; then
  WORK=$(mktemp -d "$(dirname "$OUT")/mirrorUpdate.work.XXXXXX")
else
  WORK=$(mktemp -d)
fi
export dir WORK
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

# list ALL objects of a repo, but drop git-cinnabar bookkeeping (refs/cinnabar/*,
# refs/notes/cinnabar) when present so only real upstream objects are emitted.
# Falls back to plain --all for repos without cinnabar metadata.
allObjects(){
  local gd=${1:?allObjects: missing git-dir}
  if git --git-dir="$gd" for-each-ref --count=1 'refs/cinnabar/*' 'refs/notes/cinnabar' 2>/dev/null | grep -q .; then
    git --git-dir="$gd" for-each-ref --format='%(objectname)' \
        --exclude='refs/cinnabar/*' --exclude='refs/notes/cinnabar' 2>/dev/null \
      | git --git-dir="$gd" rev-list --objects --stdin 2>/dev/null
  else
    git --git-dir="$gd" rev-list --objects --all 2>/dev/null
  fi
}

worker(){
  local r=${1:-} gd key
  [ -n "$r" ] || return            # skip empty repo names (set -u safe)
  gd=$dir/$r
  git --git-dir="$gd" config --get remote.origin.mirror >/dev/null 2>&1 || return
  key=${r//\//_}
  if [ "$INITIAL" = 1 ]; then
    allObjects "$gd" > "$WORK/$key.no"      # initial extraction: all objects (minus cinnabar)
  elif [ -f "$WORK/$key.NEW" ]; then
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
export -f worker allObjects

# discover bare repos at ANY depth (deep paths nest as subfolders), repo = dir holding objects/
find . -type d -name objects -prune 2>/dev/null | sed 's#/objects$##; s#^\./##' \
  | xargs -P "$PAR" -I{} bash -c 'worker "$@"' _ {}

cat "$WORK"/*.olist > "$OUT" 2>/dev/null
echo "new objects: $(wc -l < "$OUT" 2>/dev/null || echo 0) -> $OUT"
echo "  by type:"; cut -d';' -f2 "$OUT" 2>/dev/null | sort | uniq -c | sed 's/^/    /'
rm -rf "$WORK"
