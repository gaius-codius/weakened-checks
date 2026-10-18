#!/usr/bin/env bash
# Lists changes that weaken or bypass a check, so they're seen and explained
# rather than slipped in. Coding agents reach for these when a check is in the
# way; sometimes they're right, but never silently.
#
# Usage: check-weakened.sh BASE [HEAD] [--config FILE]
#
# Compares HEAD with its merge base with BASE (`git diff BASE...HEAD`), so on
# a branch behind BASE, what BASE gained since isn't counted as removed.
# Prints each finding. Two kinds:
#
# - Advisory findings pass when explained: in CI, by a line starting
#   "Check changes:" in the PR body (passed in the PR_BODY environment
#   variable). Locally, with no PR_BODY, they're only reported.
# - Prohibited findings (a rule the config prohibits in a path) fail whatever
#   the PR body says, locally too. Only an entry in the exceptions file waives
#   one, which makes it advisory again.
#
# The config (default .github/weakened-checks.conf) is read from BASE, so a
# branch can't relax the rules it is checked against; from HEAD when BASE has
# none yet; and from disk when it isn't in the repository at all. The
# exceptions file is read from HEAD. Both count as check config. See
# README.md for the rules, the config format and the exceptions file.
#
# Requires: bash 4, git, awk, jq; ast-grep (scripts/install-ast-grep.sh
# fetches the pinned version when a changed file needs it).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  echo "usage: check-weakened.sh BASE [HEAD] [--config FILE]" >&2
  exit 2
}
die() {
  echo "check-weakened: $*" >&2
  exit 2
}

# Arguments.
config_arg=${WEAKENED_CHECKS_CONFIG:-}
config_given=${WEAKENED_CHECKS_CONFIG:+1}
positional=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --config) [[ $# -ge 2 ]] || usage; config_arg=$2 config_given=1; shift 2 ;;
    --config=*) config_arg=${1#--config=} config_given=1; shift ;;
    -h | --help) usage ;;
    --) shift; positional+=("$@"); break ;;
    -*) usage ;;
    *) positional+=("$1"); shift ;;
  esac
done
[[ ${#positional[@]} -ge 1 && ${#positional[@]} -le 2 ]] || usage
base_arg=${positional[0]} head_arg=${positional[1]:-HEAD}

# Every diff below runs where `set -e` can't see git fail, so a missing
# commit or merge base (a shallow clone, unrelated histories) must stop the
# script here, or it would report nothing found.
base=$(git rev-parse -q --verify "$base_arg^{commit}") || die "no commit $base_arg"
head=$(git rev-parse -q --verify "$head_arg^{commit}") || die "no commit $head_arg"
if ! mb=$(git merge-base "$base" "$head"); then
  die "no merge base of $base_arg and $head_arg (a shallow clone?)"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gitq() { git -c core.quotePath=false "$@"; }

# The rule ids, the built-in lists and the config parser.
# shellcheck source=lib/config.bash
source "$here/lib/config.bash"

# The config.
cfg_path=${config_arg:-.github/weakened-checks.conf}
cfg_text="" cfg_in_repo=""
if cfg_text=$(git show "$base:$cfg_path" 2>/dev/null); then
  cfg_in_repo=$cfg_path
elif cfg_text=$(git show "$head:$cfg_path" 2>/dev/null); then
  cfg_in_repo=$cfg_path
elif [[ -f $cfg_path ]]; then
  cfg_text=$(<"$cfg_path")
elif [[ -n $config_given ]]; then
  die "no config $cfg_path at $base_arg, at $head_arg or on disk"
else
  cfg_text=""
fi

wc_config_error() { die "$@"; }
wc_reset
wc_parse_config "$cfg_text" "$cfg_path"

# The exceptions file, from HEAD: one "RULE PATTERN REASON..." per line.
if [[ $exceptions_path != none ]] && ex_text=$(git show "$head:$exceptions_path" 2>/dev/null); then
  wc_parse_exceptions "$ex_text"
fi

# Findings: rule, path, message.
f_rule=() f_path=() f_msg=()
finding() {
  on "$1" || return 0
  f_rule+=("$1") f_path+=("$2") f_msg+=("$3")
}

# Config that defines the checks, this detector's own config and exceptions
# included.
if on check-config; then
  paths=("${config_paths[@]}")
  [[ -n $cfg_in_repo ]] && paths+=("$cfg_in_repo")
  [[ $exceptions_path != none ]] && paths+=("$exceptions_path")
  if [[ ${#paths[@]} -gt 0 ]]; then
    while IFS= read -r f; do
      [[ -n $f ]] && finding check-config "$f" "check config changed: $f"
    done < <(gitq diff --name-only "$mb" "$head" -- "${paths[@]}" | sort -u)
  fi
fi

# A diff's lines, each prefixed with its file: "path<TAB>line". The path is
# the new one, or the old one for a deleted file.
diff_lines() { # git diff arguments...
  gitq diff -U0 --no-color --no-ext-diff "$mb" "$head" "$@" | awk '
    /^diff --git / { header = 1; next }
    header && /^--- / { old = substr($0, 5); sub(/^a\//, "", old); next }
    header && /^\+\+\+ / { new = substr($0, 5); sub(/^b\//, "", new); file = new == "/dev/null" ? old : new; next }
    /^@@/ { header = 0; next }
    header { next }
    { print file "\t" $0 }'
}

# Lint table edits in any Cargo.toml. Adding the lines that inherit the
# workspace lints ("[lints]", "workspace = true") is fine; removing them isn't.
if on cargo-lint-levels; then
  while IFS= read -r f; do
    [[ -n $f ]] && finding cargo-lint-levels "$f" "lint levels changed in a Cargo.toml: $f"
  done < <(diff_lines -- ':(glob)**/Cargo.toml' | awk -F'\t' '
    {
      line = substr($0, length($1) + 2)
      if (line !~ /^[-+][^-+]/) next
      if (line !~ /\[(workspace\.)?lints/ && line !~ /^[-+][ \t]*workspace[ \t]*=/ &&
          line !~ /["\047](allow|warn|deny|forbid)["\047]/) next
      if (line ~ /^\+[ \t]*(\[lints\]|workspace[ \t]*=[ \t]*true)[ \t]*$/) next
      if (!($1 in seen)) { seen[$1] = 1; print $1 }
    }')
fi

# A crate that doesn't inherit the workspace lints has none of them. Only in
# a workspace that has lints to inherit.
if on cargo-workspace-lints && [[ $cargo_members != none ]] &&
  git show "$head:Cargo.toml" 2>/dev/null | grep -qE '^[[:space:]]*\[workspace\.lints'; then
  while IFS= read -r f; do
    [[ -z $f ]] && continue
    if ! git show "$head:$f" | awk '
        /^[[:space:]]*\[/ { in_lints = ($0 ~ /^[[:space:]]*\[lints\][[:space:]]*(#.*)?$/) }
        in_lints && /^[[:space:]]*workspace[[:space:]]*=[[:space:]]*true/ { found = 1 }
        END { exit !found }'; then
      finding cargo-workspace-lints "$f" "crate does not inherit the workspace lints: $f"
    fi
  done < <(gitq diff --name-only --diff-filter=AM "$mb" "$head" -- "$cargo_members")
fi

# Annotations that silence a check or skip a test, on lines the branch adds:
# ast-grep rules (rules/) on the branch's copy of each changed file, and a
# regex fallback for .svelte files, which ast-grep can't parse.
ast_exts=('*.rs' '*.go' '*.ts' '*.mts' '*.cts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' '*.py' '*.sh' '*.bash')
# Added line ranges: "path<TAB>first<TAB>last".
gitq diff -U0 --no-color --no-ext-diff --diff-filter=AMR "$mb" "$head" -- "${ast_exts[@]}" '*.svelte' |
  awk '
    /^diff --git / { header = 1; next }
    header && /^\+\+\+ / { file = substr($0, 5); sub(/^b\//, "", file); next }
    /^@@/ {
      header = 0
      n = split(substr($3, 2), p, ",")
      count = n > 1 ? p[2] : 1
      if (count > 0) print file "\t" p[1] "\t" p[1] + count - 1
    }' >"$tmp/added"
src=$tmp/src
annotation_files=() svelte_files=()
while IFS= read -r f; do
  [[ -n $f ]] || continue
  mkdir -p "$src/$(dirname "$f")"
  git cat-file blob "$head:$f" >"$src/$f"
  if [[ $f == *.svelte ]]; then svelte_files+=("$f"); else annotation_files+=("$f"); fi
done < <(cut -f1 "$tmp/added" | sort -u)

: >"$tmp/matches" # "path<TAB>rule<TAB>first<TAB>last"
if [[ ${#annotation_files[@]} -gt 0 ]]; then
  sg=$("$here/scripts/install-ast-grep.sh") || die "ast-grep is needed for the changed files"
  (cd "$src" && "$sg" scan -c "$here/rules/sgconfig.yml" --json=stream --include-metadata \
    -- "${annotation_files[@]}") >"$tmp/sg.json" || die "ast-grep failed on the changed files"
  jq -r '[.file, (.ruleId | sub("@.*$"; "")), .range.start.line + 1,
      (if .metadata.anchor == "start" then .range.start.line else .range.end.line end) + 1] | @tsv' \
    "$tmp/sg.json" >>"$tmp/matches"
fi
# Svelte: comments and code in <script> blocks, and markup comments.
for f in "${svelte_files[@]}"; do
  awk -v file="$f" '
    function hit(rule) { print file "\t" rule "\t" FNR "\t" FNR }
    {
      line = $0
      if (line ~ /nosemgrep/) hit("nosemgrep")
      if (line ~ /<!--.*svelte-ignore/) hit("svelte-ignore")
      if (!in_script && line ~ /<script([ \t>]|$)/) { in_script = 1; sub(/^.*<script[^>]*>?/, "", line) }
      if (in_script) {
        code = line
        if (line ~ /<\/script>/) { in_script = 0; sub(/<\/script>.*$/, "", code) }
        if (code ~ /(\/\/|\/\*).*@ts-nocheck/) hit("ts-nocheck")
        if (code ~ /(\/\/|\/\*).*@ts-ignore/) hit("ts-ignore")
        if (code ~ /(\/\/|\/\*).*@ts-expect-error[ \t:-]*(\*\/[ \t]*)?$/) hit("ts-expect-error")
        if (code ~ /(\/\/|\/\*).*eslint-disable/) hit("eslint-disable")
        if (code ~ /(\/\/|\/\*).*biome-ignore/) hit("biome-ignore")
        if (code ~ /[ \t)]as[ \t]+unknown[ \t]+as[ \t]/) hit("ts-as-unknown")
        if (code ~ /(^|[^A-Za-z0-9_.$])((it|test|describe)(\.(concurrent|sequential))?\.(skip|only|todo)|x(it|test|describe))[ \t]*\(/) hit("js-test-skip")
      }
    }' "$src/$f" >>"$tmp/matches"
done
# Keep the matches that touch an added line, reported at the first one.
while IFS=$'\t' read -r f rule line; do
  on "$rule" || continue
  [[ $rule == ts-as-unknown ]] && is_test_path "$f" && continue
  text=$(sed -n "${line}p" "$src/$f" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  finding "$rule" "$f" "added: $f:$line: $text [$rule]"
done < <(awk -F'\t' '
    NR == FNR { n[$1]++; lo[$1, n[$1]] = $2; hi[$1, n[$1]] = $3; next }
    {
      first = 0
      for (i = 1; i <= n[$1]; i++) {
        s = lo[$1, i] > $3 ? lo[$1, i] : $3
        e = hi[$1, i] < $4 ? hi[$1, i] : $4
        if (s <= e && (first == 0 || s < first)) first = s
      }
      if (first && !(($1, $2, first) in seen)) { seen[$1, $2, first] = 1; print $1 "\t" $2 "\t" first }
    }' "$tmp/added" "$tmp/matches" | LC_ALL=C sort -t$'\t' -k1,1 -k3,3n -k2,2)

# Bounds a test or harness checks (a crash test's loss limit, a capture
# harness's lag bound, a sweep's floor on the crash points it reached, a
# soak's pass limits) carry a check-bound comment on the line that sets
# them, so a change to that line is reported: a new value, a deleted
# constant or a dropped tag. In Rust, Go, TypeScript, JavaScript and Svelte
# the tag is a `//` comment anywhere on the line. In a shell or Python
# script (`.sh`, `.bash`, `.py`) it's a `#` comment after code that ends the
# line, with nothing after the tag, so a tag quoted in a string or mentioned
# in a comment isn't one. A bound loosened where it's compared, not where
# it's set, is left to review. Lines are compared with their file's path,
# so a tagged line moved unchanged within its file isn't counted, and two
# files swapping values are.
bound_lines() { # - for the base's side, + for the branch's
  gitq diff -U0 --no-color --no-ext-diff "$mb" "$head" -- \
    '*.rs' '*.go' '*.ts' '*.mts' '*.cts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' '*.svelte' \
    '*.sh' '*.bash' '*.py' |
    awk -v side="$1" -v tag="$bound_tag" '
      BEGIN {
        slash_re = "//[ \t]*" tag "([^A-Za-z0-9_-]|$)"
        hash_re = "^.[ \t]*[^# \t].*[ \t]#[ \t]*" tag "[ \t\r]*$"
      }
      /^diff --git / { header = 1; hashed = /\.(sh|bash|py)$/; next }
      header && /^--- / { old = substr($0, 5); sub(/^a\//, "", old); next }
      header && /^\+\+\+ / { new = substr($0, 5); sub(/^b\//, "", new); next }
      /^@@/ { header = 0; next }
      header { next }
      substr($0, 1, 1) != side { next }
      hashed ? $0 ~ hash_re : $0 ~ slash_re {
        line = substr($0, 2); sub(/^[ \t]+/, "", line)
        print (side == "-" ? old : new) "\t" line
      }' |
    LC_ALL=C sort || true
}
if on check-bound; then
  bound_lines - >"$tmp/bounds-"
  bound_lines + >"$tmp/bounds+"
  while IFS=$'\t' read -r f line; do
    [[ -n $f ]] && finding check-bound "$f" "bound set: $f: $line"
  done < <(LC_ALL=C comm -13 "$tmp/bounds-" "$tmp/bounds+")
  while IFS=$'\t' read -r f line; do
    [[ -n $f ]] && finding check-bound "$f" "bound was: $f: $line"
  done < <(LC_ALL=C comm -23 "$tmp/bounds-" "$tmp/bounds+")
fi

# Tests removed: more test declarations deleted than added, per language
# (Rust's #[test] attributes in any file; Go, JavaScript, TypeScript and
# Python test functions in test files). Counted over the whole diff, so a
# test moved between files isn't reported.
test_counts() { # prints "language<TAB>path<TAB>removed<TAB>added" per file
  diff_lines -- '*.rs' '*.go' '*.ts' '*.mts' '*.cts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' '*.py' |
    awk -F'\t' '
      {
        line = substr($0, length($1) + 2)
        sign = substr(line, 1, 1)
        if (sign != "-" && sign != "+") next
        body = substr(line, 2)
        lang = ""
        if ($1 ~ /\.rs$/) { if (body ~ /^[ \t]*#\[(test|proptest|rstest)/) lang = "rust" }
        else if ($1 ~ /_test\.go$/) { if (body ~ /^func[ \t]+(Test|Fuzz)[A-Za-z0-9_]*[ \t]*\(/) lang = "go" }
        else if ($1 ~ /\.py$/) { if (body ~ /^[ \t]*(async[ \t]+)?def[ \t]+test[A-Za-z0-9_]*[ \t]*\(/) lang = "python" }
        else if (body ~ /^[ \t]*(it|test)(\.[A-Za-z]+)*[ \t]*\(/) lang = "js"
        if (lang == "") next
        key = lang "\t" $1
        if (!(key in order)) { order[key] = ++n; keys[n] = key }
        if (sign == "-") removed[key]++; else added[key]++
      }
      END { for (i = 1; i <= n; i++) print keys[i] "\t" removed[keys[i]] + 0 "\t" added[keys[i]] + 0 }'
}
test_counts | while IFS=$'\t' read -r lang f r a; do
  # Rust's attributes count anywhere; the other languages only in test files.
  if [[ $lang == rust ]] || is_test_path "$f"; then printf '%s\t%s\t%s\t%s\n' "$lang" "$f" "$r" "$a"; fi
done >"$tmp/tests"
if on tests-removed; then
  declare -A t_removed=() t_added=()
  while IFS=$'\t' read -r lang f r a; do
    t_removed[$lang]=$((${t_removed[$lang]:-0} + r))
    t_added[$lang]=$((${t_added[$lang]:-0} + a))
  done <"$tmp/tests"
  for lang in rust go js python; do
    r=${t_removed[$lang]:-0} a=${t_added[$lang]:-0}
    (( r > a )) || continue
    case $lang in
      rust) msg="tests removed: $r test attributes deleted, $a added" ;;
      go) msg="tests removed: $r Go test functions deleted, $a added" ;;
      js) msg="tests removed: $r JavaScript or TypeScript tests deleted, $a added" ;;
      python) msg="tests removed: $r Python test functions deleted, $a added" ;;
    esac
    finding tests-removed "" "$msg"
  done
fi

# Snapshot and golden files changed (accepted again, or deleted).
if on snapshot; then
  while IFS= read -r f; do
    [[ -n $f ]] && finding snapshot "$f" "snapshot changed: $f"
  done < <(gitq diff --name-only --diff-filter=MD "$mb" "$head" -- "${snapshot_paths[@]}")
fi

# Prohibitions. A finding is prohibited when its rule is prohibited in a
# pattern its path matches; tests removed are counted again over the files
# each pattern matches, so tests moved within it aren't. An exception for the
# rule and a pattern matching the path (or, for tests removed, the
# prohibition's pattern) makes it advisory again.
advisory=() prohibited=()
classify() { # rule, path, message
  local p rule pattern reason
  for p in "${prohibits[@]}"; do
    IFS=$'\t' read -r rule pattern <<<"$p"
    # shellcheck disable=SC2053 # the pattern is meant to match.
    if [[ $rule == "$1" && -n $2 && $2 == $pattern ]]; then
      if reason=$(excepted "$1" "$2"); then
        advisory+=("$3 (prohibited in $pattern; allowed by $exceptions_path: $reason)")
      else
        prohibited+=("$3")
      fi
      return
    fi
  done
  advisory+=("$3")
}
for i in "${!f_rule[@]}"; do
  classify "${f_rule[$i]}" "${f_path[$i]}" "${f_msg[$i]}"
done
if on tests-removed; then
  for p in "${prohibits[@]}"; do
    IFS=$'\t' read -r rule pattern <<<"$p"
    [[ $rule == tests-removed ]] || continue
    r=0 a=0
    while IFS=$'\t' read -r lang f fr fa; do
      # shellcheck disable=SC2053 # the pattern is meant to match.
      [[ $f == $pattern ]] && r=$((r + fr)) a=$((a + fa))
    done <"$tmp/tests"
    (( r > a )) || continue
    msg="tests removed in $pattern: $r deleted, $a added"
    if reason=$(excepted tests-removed "$pattern"); then
      advisory+=("$msg (prohibited; allowed by $exceptions_path: $reason)")
    else
      prohibited+=("$msg")
    fi
  done
fi

if (( ${#advisory[@]} + ${#prohibited[@]} == 0 )); then
  echo "check-weakened: nothing found"
  exit 0
fi

if (( ${#advisory[@]} > 0 )); then
  echo "Changes that weaken or bypass a check:"
  printf '  - %s\n' "${advisory[@]}"
fi
if (( ${#prohibited[@]} > 0 )); then
  echo "Prohibited here (a \"Check changes:\" line doesn't allow these; an entry in $exceptions_path does):"
  printf '  - %s\n' "${prohibited[@]}"
  echo "Undo these, or add an exception with its reason to $exceptions_path." >&2
  exit 1
fi

if [[ -z ${PR_BODY+x} ]]; then
  echo "(report only; in CI the PR body must explain these in a \"Check changes:\" line)"
  exit 0
fi
if grep -qiE '^[[:space:]]*check changes:[[:space:]]*[^[:space:]]' <<<"$PR_BODY"; then
  echo "Explained in the PR body."
  exit 0
fi
echo "Add a line starting \"Check changes:\" to the PR body explaining why." >&2
exit 1
