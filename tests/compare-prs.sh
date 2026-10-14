#!/usr/bin/env bash
# Runs an old check-weakened.sh and this detector over a repository's recent
# merged pull requests (their real diffs and bodies, through gh) and lists
# where they differ: the exit status, and each finding only one of them
# reported. Run by hand before replacing a project's script; not part of CI.
#
# Usage: compare-prs.sh OWNER/REPO CLONE OLD_REF CONFIG [COUNT]
#   CLONE    a local clone of the repository (only read: it is cloned again)
#   OLD_REF  the commit of CLONE whose scripts/check-weakened.sh is compared
#   CONFIG   the config this detector runs with (examples/<project>.conf)
#   COUNT    how many merged pull requests, newest first (default 20)
#
# Findings are compared after the formats are made alike: this detector's
# "added: PATH:LINE: TEXT [RULE]" is compared as "added: TEXT", and its
# "lint levels changed in a Cargo.toml: PATH" without the path.
#
# Requires: gh (signed in, with access to the repository), git, jq.
set -euo pipefail

[[ $# -ge 4 && $# -le 5 ]] || {
  echo "usage: compare-prs.sh OWNER/REPO CLONE OLD_REF CONFIG [COUNT]" >&2
  exit 2
}
repo=$1 clone=$2 old_ref=$3 config=$(cd "$(dirname "$4")" && pwd)/$(basename "$4") count=${5:-20}
detector=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/check-weakened.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone -q --bare "$clone" "$work/repo.git"
git -C "$clone" show "$old_ref:scripts/check-weakened.sh" >"$work/old.sh"
gh pr list -R "$repo" --state merged -L "$count" \
  --json number,title,baseRefOid,headRefOid,body >"$work/prs.json"
refspecs=()
while IFS= read -r n; do refspecs+=("refs/pull/$n/head:refs/pr/$n"); done < <(jq -r '.[].number' "$work/prs.json")
git -C "$work/repo.git" fetch -q "https://github.com/$repo" "${refspecs[@]}"
# shellcheck disable=SC2046 # one commit per word.
git -C "$work/repo.git" fetch -q "https://github.com/$repo" \
  $(jq -r '.[].baseRefOid' "$work/prs.json" | sort -u) 2>/dev/null || true

findings() { # output file; prints its findings, normalised, one per line
  sed -n 's/^  - //p' "$1" |
    sed -E 's/^added: [^:]+:[0-9]+: (.*) \[[a-z-]+\]$/added: \1/;
      s/^(lint levels changed in a Cargo.toml): .*/\1/' |
    LC_ALL=C sort -u
}

same=0 differ=0
total=$(jq length "$work/prs.json")
for i in $(seq 0 $((total - 1))); do
  n=$(jq -r ".[$i].number" "$work/prs.json")
  title=$(jq -r ".[$i].title" "$work/prs.json")
  base=$(jq -r ".[$i].baseRefOid" "$work/prs.json")
  body=$(jq -r ".[$i].body // \"\"" "$work/prs.json")
  head=refs/pr/$n
  old_status=0 new_status=0
  (cd "$work/repo.git" && PR_BODY=$body bash "$work/old.sh" "$base" "$head") >"$work/old.out" 2>&1 || old_status=$?
  (cd "$work/repo.git" && PR_BODY=$body "$detector" --config "$config" "$base" "$head") >"$work/new.out" 2>&1 || new_status=$?
  only_old=$(LC_ALL=C comm -23 <(findings "$work/old.out") <(findings "$work/new.out"))
  only_new=$(LC_ALL=C comm -13 <(findings "$work/old.out") <(findings "$work/new.out"))
  n_found=$(findings "$work/new.out" | grep -c . || true)
  if [[ $old_status == "$new_status" && -z $only_old && -z $only_new ]]; then
    same=$((same + 1))
    printf '#%s same (exit %s, %s findings): %s\n' "$n" "$new_status" "$n_found" "${title:0:70}"
  else
    differ=$((differ + 1))
    printf '#%s DIFFERS (old exit %s, new exit %s): %s\n' "$n" "$old_status" "$new_status" "${title:0:70}"
    [[ -z $only_old ]] || printf '    only old: %s\n' "${only_old//$'\n'/$'\n    only old: '}"
    [[ -z $only_new ]] || printf '    only new: %s\n' "${only_new//$'\n'/$'\n    only new: '}"
    if [[ $new_status -ge 2 ]]; then sed 's/^/    new: /' "$work/new.out"; fi
  fi
done
echo "$repo: $same of $total the same, $differ different"
