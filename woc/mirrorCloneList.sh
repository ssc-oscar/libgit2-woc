#!/bin/bash
# Clone (--mirror) any listed project URL that is ABSENT, using the woc/doOtrVer
# folder convention: drop protocol, replace the first two '/' with '_', deeper
# path components stay as nested subfolders
#   (https://h/a/b/c -> h_a_b/c , i.e. dir h_a_b containing repo at c).
# Skips repos already present, so it is safely resumable.
#   mirrorCloneList.sh <dir> <url-list> [parallel]
set -u
dir=${1:?usage: mirrorCloneList.sh <dir> <url-list> [parallel]}
LIST=${2:?}; PAR=${3:-12}
cd "$dir" || exit 1
mangle(){ perl -ane 's|^gh:([^/]+)/|$1_|;s|^bb:([^/]+)/|bitbucket.org_$1_|;s|^gl:([^/]+)/|gitlab.com_$1_|;s|^dr:([^/]+)/|drupal.com_$1_|;s|^https://([^/]*)/([^/]*)/|$1_$2_|;s|^https://([^/]*)/|$1_|;print'; }
clone1(){
  local u=$1 j r
  j=$(printf '%s' "$u" | mangle)
  r=$(printf '%s' "$u" | sed 's#^https://#https://a:a@#;s#^https://a:a@git.launchpad.net/#lp:#')
  # skip if already a valid bare mirror with refs
  if git --git-dir="$j" rev-parse --is-bare-repository >/dev/null 2>&1 \
     && [ -n "$(git --git-dir="$j" for-each-ref --count=1 2>/dev/null)" ]; then return; fi
  # init+fetch (works even when $j already holds nested child subrepos, or is a
  # killed partial clone -- fetch just completes it); --mirror clone cannot.
  mkdir -p "$j"
  git init -q --bare "$j" >/dev/null 2>&1 || { echo "FAIL init $u"; return; }
  git --git-dir="$j" config remote.origin.url   "$r"
  git --git-dir="$j" config remote.origin.mirror true
  git --git-dir="$j" config remote.origin.fetch '+refs/*:refs/*'
  if git --git-dir="$j" remote update >/dev/null 2>&1; then echo "OK $j"; else echo "FAIL $u"; fi
}
export -f mangle clone1
xargs -P "$PAR" -I{} bash -c 'clone1 "$@"' _ {} < "$LIST"
