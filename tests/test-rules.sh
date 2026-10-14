#!/usr/bin/env bash
# Checks the ast-grep rules: they load, each rule id (less its @language)
# is one check-weakened.sh knows, and the TypeScript rules' two copies (for
# typescript and for tsx) are the same apart from the language.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sg=$("$root/scripts/install-ast-grep.sh")
status=0
fail() {
  echo "test-rules: $*" >&2
  status=1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo 'fn f() {}' >"$tmp/a.rs"
(cd "$tmp" && "$sg" scan -c "$root/rules/sgconfig.yml" a.rs >/dev/null) || fail "the rules don't load"

known=$(sed -n '/^rules=(/,/)$/p' "$root/check-weakened.sh" | tr -s ' ()' '\n')
while IFS= read -r id; do
  grep -qxF "${id%@*}" <<<"$known" || fail "rule $id isn't one check-weakened.sh knows"
done < <(grep -h '^id: ' "$root"/rules/*/*.yml | cut -d' ' -f2 | sort -u)

copy() { # language: the TypeScript rules written for it, with the language taken out
  awk -v lang="$1" 'BEGIN { RS = "\n---\n" } $0 ~ ("\nlanguage: " lang "\n") { print }' \
    "$root/rules/ts/ts.yml" | sed -E "s/@$1\$//; /^language: /d; /^#/d"
}
[[ -n $(copy typescript) ]] || fail "no TypeScript rules found"
[[ $(copy typescript) == "$(copy tsx)" ]] || fail "the typescript and tsx copies of rules/ts/ts.yml differ"

(( status == 0 )) && echo "test-rules: all checks pass"
exit "$status"
