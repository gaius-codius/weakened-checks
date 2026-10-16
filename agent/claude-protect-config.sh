#!/usr/bin/env bash
# Claude Code PreToolUse hook: before an agent changes a file that defines a
# project's checks, or adds a lint or test suppression, ask the human to
# approve it. An agent stuck on a finding can otherwise make it go away by
# weakening the check, and the detector only reports that once a pull request
# is open, after the agent has built on it.
#
# Install: symlink it into ~/.claude/hooks/ from a clone of this repository
# (it reads ../lib/config.bash beside its real path) and register it under
# PreToolUse for Edit|Write|MultiEdit|Bash (README, "Claude Code hook").
#
# It works in any git repository, with paths relative to the repository root
# of the edited file (of cwd, for Bash). What asks:
#   - A check-config path: the detector's config-path list, read from
#     .github/weakened-checks.conf as committed on the default branch (the
#     first of origin/HEAD, origin/main, origin/master, main, master), or the
#     built-in list without one. The config and the exceptions file always
#     ask. A config that doesn't parse protects the built-in list plus every
#     pathspec on its config-path lines.
#   - A Cargo.toml at any depth, only when the change touches a [lints] or
#     [workspace.lints] table or a lints key (or the old text can't be found).
#   - A source file, when the new text holds a suppression the old text
#     doesn't: each match runs to the end of its attribute or comment, so
#     widening one asks as adding one does. The detector's annotation rules:
#     Rust allow/expect (also in cfg_attr), ignore, rustfmt::skip and a
#     disabling cfg; //nolint and t.Skip; @ts-nocheck, @ts-ignore,
#     @ts-expect-error without a reason, eslint-disable, biome-ignore, JS
#     test skip/only; svelte-ignore; Python skips; nosemgrep. A rule the
#     config disables doesn't ask. "x as unknown as T" outside the test paths
#     only adds context, unless the config prohibits ts-as-unknown there and
#     the exceptions file (read from HEAD) doesn't allow it.
#   - Bash, best effort: a command that names a protected path (or a
#     directory holding one) and writes with sed -i, perl -i, tee, mv, cp,
#     rm, truncate, ln, install, patch or git checkout/restore/rm/mv/apply,
#     or redirects into one; a Cargo.toml with "lints"; a source file with a
#     suppression. A write through any other program is not seen.
#
# Outcomes:
#   exit 0 with JSON permissionDecision "ask": a protected change. Claude
#     Code asks the user, showing the reason.
#   exit 0, nothing: anything else, outside a git repository, or
#     WEAKENED_CHECKS_PROTECT_CONFIG=off.
#   exit 0 with JSON additionalContext: an advisory note, or the check could
#     not run (jq or git missing, input jq can't read, lib/ missing, bash
#     older than 4.3). Never blocks, never silent.
set -uo pipefail

opt_out="Set WEAKENED_CHECKS_PROTECT_CONFIG=off to turn this hook off."
cfg_file=.github/weakened-checks.conf
cfg_note=""

# say <message>: tell the agent something without blocking, then exit 0.
say() {
  local m="weakened-checks hook: $1"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg m "$m" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
  else
    m=${m//\\/\\\\}; m=${m//\"/\\\"}; m=${m//$'\n'/\\n}; m=${m//$'\t'/\\t}
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$m"
  fi
  exit 0
}

# ask <reason>: hand the decision to the user, then exit 0. Only called with jq.
ask() {
  local r="weakened-checks hook: $1"
  [[ -z $cfg_note ]] || r+=" $cfg_note"
  jq -n --arg r "$r $opt_out" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
  exit 0
}

# done_quiet: nothing to ask; a config that didn't parse is still said.
done_quiet() {
  [[ -z $cfg_note ]] || say "$cfg_note"
  exit 0
}

[[ ${WEAKENED_CHECKS_PROTECT_CONFIG:-} == off ]] && exit 0

input=$(cat)

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
  say "bash ${BASH_VERSION} is older than 4.3, so this change was not checked for weakened checks."
fi
command -v git >/dev/null 2>&1 || say "git is not on PATH, so this change was not checked for weakened checks."
self=$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null) || self=${BASH_SOURCE[0]}
lib=$(dirname -- "$self")/../lib/config.bash
[[ -r $lib ]] || say "$lib is missing (the hook must be a symlink into a clone of weakened-checks), so this change was not checked for weakened checks."
# shellcheck source=lib/config.bash
source "$lib" || say "could not load $lib, so this change was not checked for weakened checks."
cfg_error=""
# shellcheck disable=SC2329 # called by the parsers in lib/config.bash.
wc_config_error() { cfg_error=$1; }

scratch=""

# abs_path <path> <cwd>: <path> made absolute with its nearest existing
# directory resolved. The file itself is not resolved: a symlinked
# deny.toml stays deny.toml.
abs_path() {
  local p=$1 d rest
  [[ $p == /* ]] || p="$2/$p"
  d=$(dirname -- "$p")
  rest=$(basename -- "$p")
  while [[ ! -d $d ]]; do
    rest="$(basename -- "$d")/$rest"
    d=$(dirname -- "$d")
  done
  d=$(realpath -- "$d") || return 1
  printf '%s/%s\n' "${d%/}" "$rest"
}

# repo_root <dir>: the git repository's root of <dir>, or of its nearest
# existing parent (a new file may be in a directory not made yet), resolved.
repo_root() {
  local d=$1 r
  while [[ ! -d $d ]]; do d=$(dirname -- "$d"); done
  r=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || return 1
  realpath -- "$r"
}

# default_ref <root>: the default branch, as the first ref that exists.
default_ref() {
  local r
  for r in origin/HEAD origin/main origin/master main master; do
    git -C "$1" rev-parse -q --verify "$r^{commit}" >/dev/null 2>&1 && { printf '%s\n' "$r"; return 0; }
  done
  return 1
}

# load_config <root>: the config from the default branch (or the defaults),
# the exceptions from HEAD, and the protected pathspecs.
load_config() {
  local root=$1 ref text="" name=$cfg_file
  wc_reset
  if ref=$(default_ref "$root") && text=$(git -C "$root" show "$ref:$cfg_file" 2>/dev/null); then
    name="$cfg_file on $ref"
  else
    text=""
  fi
  cfg_error=""
  if ! wc_parse_config "$text" "$name"; then
    # Don't narrow what's protected: the built-in list and every pathspec
    # the config names.
    local extra
    extra=$(sed -nE 's/[[:space:]]+#.*$//; s/^[[:space:]]*config-path[[:space:]]+//p' <<<"$text" | tr -s ' \t' '\n' | grep -vx '@defaults')
    wc_reset
    wc_parse_config "" ""
    # shellcheck disable=SC2206 # pathspecs have no spaces in the config either.
    config_paths=("${default_config_paths[@]}" $extra)
    cfg_note="($cfg_error: the config did not parse, so the built-in check-config list and the config's config-path entries are protected.)"
  fi
  cfg_error=""
  local ex
  if [[ $exceptions_path != none ]] && ex=$(git -C "$root" show "HEAD:$exceptions_path" 2>/dev/null); then
    wc_parse_exceptions "$ex" || exceptions=()
  fi
  protected=("$cfg_file" .github/weakened-checks-exceptions)
  [[ $exceptions_path == none ]] || protected+=("$exceptions_path")
  if on check-config; then protected+=("${config_paths[@]}"); fi
}

# scratch_dir: a directory for throwaway git indexes, made once.
scratch_dir() {
  [[ -n $scratch ]] || scratch=$(mktemp -d) || return 1
}

# protected_matches <root> <relative path>...: prints those that match the
# protected pathspecs, by git's own pathspec rules: the paths go into a
# throwaway index (they needn't exist) and ls-files picks the matches.
protected_matches() {
  local root=$1 idx
  shift
  (($# > 0)) || return 0
  scratch_dir || return 1
  idx=$scratch/index.$RANDOM
  printf '100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\t%s\0' "$@" |
    GIT_INDEX_FILE=$idx git -C "$root" update-index --add -z --index-info 2>/dev/null
  GIT_INDEX_FILE=$idx git -C "$root" -c core.quotePath=false ls-files -- "${protected[@]}" 2>/dev/null
  rm -f "$idx"
}

# lang <relative path>: the suppression rules that apply, by file type.
lang() {
  case $1 in
    *.rs) echo rust ;;
    *_test.go) echo gotest ;;
    *.go) echo go ;;
    *.ts | *.mts | *.cts | *.tsx | *.js | *.jsx | *.mjs | *.cjs) echo ts ;;
    *.svelte) echo svelte ;;
    *.py) echo python ;;
    *.sh | *.bash) echo shell ;;
  esac
}

# Suppression rules as "rule<TAB>regex" lines (Oniguruma, for jq). Each match
# runs to the end of its attribute or comment, so a widened suppression is a
# new match. jq's $ is the end of the whole text and \s crosses lines, so
# line ends are written (?=\n|$) and spaces [ \t].
cmt='(?:(?!\*/)[^\n])*'
declare -A rules_by ere_by
rules_by[rust]="rust-allow	#\\s*!?\\s*\\[\\s*(?:allow|expect)\\s*\\([^\\]]*\\]?
rust-allow	#\\s*!?\\s*\\[\\s*cfg_attr\\s*\\([^\\]]*\\b(?:allow|expect)\\s*\\([^\\]]*\\]?
rust-ignore	#\\s*!?\\s*\\[\\s*(?:cfg_attr\\s*\\([^\\]]*\\b)?ignore\\b[^\\]]*\\]?
rust-cfg	#\\s*!?\\s*\\[\\s*cfg\\s*\\(\\s*(?:any\\s*\\(\\s*\\)|not\\s*\\(\\s*all\\s*\\(\\s*\\)\\s*\\)|false)\\s*\\)[^\\]]*\\]?
rust-rustfmt-skip	#\\s*!?\\s*\\[[^\\]]*\\b(?:rustfmt\\s*::\\s*skip|rustfmt_skip)\\b[^\\]]*\\]?"
rules_by[go]="go-nolint	//[ \\t]?nolint\\b$cmt"
rules_by[gotest]="${rules_by[go]}
go-test-skip	\\.(?:Skip|Skipf|SkipNow)[ \\t]*\\("
rules_by[ts]="ts-nocheck	@ts-nocheck\\b$cmt
ts-ignore	@ts-ignore\\b$cmt
ts-expect-error	@ts-expect-error[ \\t:-]*(?:\\*/[ \\t]*)?(?=\\n|$)
eslint-disable	\\beslint-disable$cmt
biome-ignore	\\bbiome-ignore$cmt
js-test-skip	(?<![A-Za-z0-9_\$.])(?:(?:it|test|describe|suite|bench)(?:\\.(?:concurrent|sequential))?\\.(?:skip|only|todo|skipIf|runIf)|x(?:it|test|describe))[ \\t]*\\(
ts-as-unknown	\\bas[ \\t\\n]+unknown[ \\t\\n]+as\\b"
rules_by[svelte]="${rules_by[ts]}
svelte-ignore	svelte-ignore(?:(?!-->)[^\\n])*"
rules_by[python]="py-test-skip	@[ \\t]*(?:pytest\\.mark\\.(?:skip|skipif|xfail)|unittest\\.(?:skip|skipIf|skipUnless|expectedFailure))\\b[^\\n]*
py-test-skip	\\b(?:pytest\\.skip|self\\.skipTest)[ \\t]*\\("
rules_nosemgrep="nosemgrep	\\bnosemgrep\\b$cmt"

# rules_for <lang>: its rules as a JSON array of {rule, re}, less disabled ones.
rules_for() {
  local lines=${rules_by[$1]:-}
  [[ -n $lines ]] && lines+=$'\n'
  lines+=$rules_nosemgrep
  local out="" rule re
  while IFS=$'\t' read -r rule re; do
    on "$rule" || continue
    out+=$rule$'\t'$re$'\n'
  done <<<"$lines"
  printf '%s' "$out" | jq -Rn '[inputs | split("\t") | {rule: .[0], re: (.[1:] | join("\t"))}]'
}

# Bash's view of the same suppressions (EREs), by language.
ere_by[rust]='#!?\[(allow|expect)\(|cfg_attr\(.*(allow|expect|ignore)|#\[ignore|cfg\((any\(\)|not\(all\(\)\)|false)\)|rustfmt::skip|rustfmt_skip'
ere_by[go]='//[[:space:]]?nolint|\.Skip(f|Now)?\('
ere_by[ts]='@ts-(nocheck|ignore|expect-error)|eslint-disable|biome-ignore|(it|test|describe|suite|bench)(\.(concurrent|sequential))?\.(skip|only|todo|skipIf|runIf)|(^|[^[:alnum:]_$.])x(it|test|describe)[[:space:]]*\('
ere_by[svelte]="${ere_by[ts]}|svelte-ignore"
ere_by[python]='pytest\.mark\.(skip|skipif|xfail)|unittest\.(skip|expectedFailure)|pytest\.skip|skipTest'
ere_any='nosemgrep'

# relevant <root> <rel>: whether a change to <rel> is one this hook judges.
relevant() {
  [[ -n $(protected_matches "$1" "$2") ]] && return 0
  [[ $2 == Cargo.toml || $2 == */Cargo.toml || -n $(lang "$2") ]]
}

main() {
  trap '[[ -z $scratch ]] || rm -rf "$scratch"' EXIT
  if ! command -v jq >/dev/null 2>&1; then
    # Best effort without jq, only to decide whether the change is ours to
    # report on.
    local file cwd abs root
    file=$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    cwd=$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [[ -n $cwd && -d $cwd ]] || cwd=$PWD
    if [[ -n $file ]]; then
      abs=$(abs_path "$file" "$cwd") || exit 0
      root=$(repo_root "$(dirname -- "$abs")") || exit 0
      [[ $abs == "$root"/* ]] || exit 0
      load_config "$root"
      relevant "$root" "${abs#"$root"/}" || exit 0
      say "jq is not on PATH, so this change to ${abs#"$root"/} was not checked for weakened checks."
    fi
    repo_root "$cwd" >/dev/null || exit 0
    grep -q '"command"' <<<"$input" || exit 0
    say "jq is not on PATH, so this command was not checked for changes to check config."
  fi

  local fields tool cwd
  if ! fields=$(printf '%s' "$input" | jq -c '{tool: (.tool_name // ""), cwd: (.cwd // ""), file: (.tool_input.file_path // ""), command: (.tool_input.command // "")}' 2>/dev/null); then
    say "could not read the hook input with jq, so this change was not checked for weakened checks."
  fi
  tool=$(jq -r .tool <<<"$fields")
  cwd=$(jq -r .cwd <<<"$fields")
  [[ -n $cwd && -d $cwd ]] || cwd=$PWD

  case $tool in
    Bash) judge_bash "$(jq -r .command <<<"$fields")" "$cwd" ;;
    Edit | Write | MultiEdit) judge_file "$tool" "$(jq -r .file <<<"$fields")" "$cwd" ;;
  esac
  exit 0
}

# judge_file <tool> <file> <cwd>
judge_file() {
  local tool=$1 file=$2 cwd=$3 abs root rel
  [[ -n $file ]] || exit 0
  abs=$(abs_path "$file" "$cwd") || exit 0
  root=$(repo_root "$(dirname -- "$abs")") || exit 0
  [[ $abs == "$root"/* ]] || exit 0
  rel=${abs#"$root"/}
  load_config "$root"

  if [[ -n $(protected_matches "$root" "$rel") ]]; then
    ask "$rel is check config: it sets what CI, the hooks or the weakened-checks detector check. Changing it can weaken them, so a human approves this edit."
  fi

  # The current content ("" for a new file).
  local cur=""
  [[ -f $abs ]] && cur=$(cat -- "$abs"; printf x) && cur=${cur%x}

  if [[ $rel == Cargo.toml || $rel == */Cargo.toml ]]; then
    on cargo-lint-levels || done_quiet
    judge_cargo "$rel" "$cur"
    done_quiet
  fi

  local l
  l=$(lang "$rel")
  [[ -n $l ]] || done_quiet
  local rules added
  rules=$(rules_for "$l") || say "could not build the suppression rules with jq, so this change to $rel was not checked."
  # The suppressions the new text holds more often than the old, as
  # "rule<TAB>text" lines.
  added=$(printf '%s' "$input" | jq -r --arg cur "$cur" --argjson rules "$rules" '
    def spans: . as $t | [$rules[] as $r | $t | match($r.re; "g")
      | {rule: $r.rule, s: (.string | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; ""))}];
    def bag: group_by([.rule, .s]) | map({key: (.[0].rule + "\t" + .[0].s), value: length}) | from_entries;
    (if .tool_name == "Write" then {old: [$cur], new: [.tool_input.content // ""]}
     elif .tool_name == "Edit" then {old: [.tool_input.old_string // ""], new: [.tool_input.new_string // ""]}
     else {old: [.tool_input.edits[]? | .old_string // ""], new: [.tool_input.edits[]? | .new_string // ""]}
     end) as $t
    | ([$t.old[] | spans[]] | bag) as $o
    | [$t.new[] | spans[]] | bag | to_entries[] | select(.value > ($o[.key] // 0)) | .key' 2>/dev/null) ||
    say "could not read the edit with jq, so this change to $rel was not checked for added suppressions."
  [[ -n $added ]] || done_quiet

  local asks="" unknown="" r s
  while IFS=$'\t' read -r r s; do
    if [[ $r == ts-as-unknown ]]; then
      is_test_path "$rel" || unknown=$s
    else
      asks+="${asks:+; }$s"
    fi
  done <<<"$added"
  if [[ -n $asks ]]; then
    ((${#asks} <= 300)) || asks="${asks:0:300}..."
    ask "this edit adds or widens a lint or test suppression in $rel ($asks). Silencing a lint or skipping a test can hide a real problem, so a human approves it."
  fi
  if [[ -n $unknown ]]; then
    local p rule pattern
    for p in "${prohibits[@]}"; do
      IFS=$'\t' read -r rule pattern <<<"$p"
      # shellcheck disable=SC2053 # the pattern is meant to match.
      if [[ $rule == ts-as-unknown && $rel == $pattern ]] && ! excepted ts-as-unknown "$rel" >/dev/null; then
        ask "this edit forces a type through unknown ($unknown) in $rel, where $cfg_file prohibits it (ts-as-unknown in $pattern). A human approves it."
      fi
    done
    say "this edit forces a type through unknown ($unknown) in $rel. The weakened-checks detector reports it (ts-as-unknown), and the pull request must explain it in a \"Check changes:\" line. Prefer parsing or narrowing the value."
  fi
  done_quiet
}

# judge_cargo <rel> <current content>: asks when the edit touches the lints
# tables.
judge_cargo() {
  local rel=$1 cur=$2 verdict
  verdict=$(printf '%s' "$input" | jq -r --arg cur "$cur" '
    # The lines that belong to a lints table or set a lints key, whitespace
    # removed, comments and blank lines dropped.
    def lintlines: split("\n") | reduce .[] as $l ({sec: false, out: []};
      if ($l | test("^\\s*\\[")) then
        .sec = ($l | test("lints")) | if .sec then .out += [$l | gsub("\\s+"; "")] else . end
      elif (.sec or ($l | test("lints"))) and ($l | test("^\\s*(#.*)?$") | not) then
        .out += [$l | gsub("\\s+"; "")]
      else . end) | .out;
    # The table header that holds the start of <old> in the current file.
    def section($old): ($cur | split($old)) as $parts
      | if ($parts | length) < 2 then null
        else ($parts[0] | split("\n") | map(select(test("^\\s*\\["))) | last // "") end;
    def edit_touches: (.old_string // "") as $o | (.new_string // "") as $n
      | if ($o + $n | test("lints")) then "lints"
        elif $o == "" then "no"
        else section($o) as $s
          | if $s == null then "unsure" elif ($s | test("lints")) then "lints" else "no" end
        end;
    if .tool_name == "Write" then
      if ((.tool_input.content // "") | lintlines) == ($cur | lintlines) then "no" else "lints" end
    elif .tool_name == "Edit" then .tool_input | edit_touches
    else [.tool_input.edits[]? | edit_touches] as $v
      | if any($v[]; . == "lints") then "lints" elif any($v[]; . == "unsure") then "unsure" else "no" end
    end' 2>/dev/null) || say "could not read the edit with jq, so this change to $rel was not checked for lints changes."
  case $verdict in
    lints) ask "this edit changes the [lints] or [workspace.lints] tables in $rel, which set what clippy and rustc deny. Changing them can weaken the checks, so a human approves this edit." ;;
    unsure) ask "this edit's old text isn't in $rel as it is now, so the hook can't tell whether it touches the [lints] tables. A human approves it." ;;
  esac
}

# judge_bash <command> <cwd>: best effort.
judge_bash() {
  local cmd=$1 cwd=$2 root
  [[ -n $cmd ]] || exit 0
  root=$(repo_root "$cwd") || exit 0
  load_config "$root"

  local writers="(^|[;&|({[:space:]])((sed|perl)[[:space:]][^;&|]*-[a-zA-Z]*i|tee|mv|cp|rm|truncate|ln|install|patch|git[[:space:]]+(checkout|restore|rm|mv|apply))([[:space:]]|$)"
  local writes=""
  grep -Eq -- "$writers" <<<"$cmd" && writes=1

  # The words, quotes dropped, split on spaces and shell operators; and the
  # targets of > and >>.
  local -a words targets
  read -r -a words <<<"$(tr -d "\"'" <<<"$cmd" | tr ';&|()<>=\n\t' '         ')"
  mapfile -t targets < <(tr -d "\"'" <<<"$cmd" | grep -oE '[0-9]?>>?[[:space:]]*[^[:space:];&|<>()]+' |
    sed -E 's/^[0-9]?>>?[[:space:]]*//' | grep -v '^&')

  # Each word (and target) as a path relative to the root, when it is one.
  local w abs rel
  local -A rels=() target_rels=() dirs=()
  for w in "${words[@]}" "${targets[@]}"; do
    [[ -n $w && $w != -* && $w != *://* ]] || continue
    abs=$(abs_path "$w" "$cwd" 2>/dev/null) || continue
    abs=${abs%/.}
    [[ $abs == "$root"/* ]] || continue
    rel=${abs#"$root"/}
    rel=${rel%/}
    [[ -n $rel && $rel != .git && $rel != .git/* ]] || continue
    rels[$rel]=1
    [[ -d $abs ]] && dirs[$rel]=1
  done
  for w in "${targets[@]}"; do
    abs=$(abs_path "$w" "$cwd" 2>/dev/null) || continue
    [[ $abs == "$root"/* ]] && target_rels[${abs#"$root"/}]=1
  done

  local named="" targeted="" m
  if ((${#rels[@]} > 0)); then
    while IFS= read -r m; do
      [[ -n $m ]] || continue
      named+="${named:+, }$m"
      [[ -n ${target_rels[$m]:-} ]] && targeted=1
    done < <(protected_matches "$root" "${!rels[@]}")
  fi
  # A directory word names the protected files under it, tracked or not.
  if [[ -z $named && ${#dirs[@]} -gt 0 ]]; then
    local -a existing
    mapfile -t existing < <(git -C "$root" -c core.quotePath=false ls-files --cached --others --exclude-standard -- "${protected[@]}" 2>/dev/null)
    local d f
    for d in "${!dirs[@]}"; do
      for f in "${existing[@]}"; do
        [[ $f == "$d"/* ]] && { named+="${named:+, }$d"; break; }
      done
    done
  fi
  if [[ -n $named ]] && [[ -n $writes || -n $targeted ]]; then
    ask "this command looks like it changes check config ($named). That can weaken what CI, the hooks or the weakened-checks detector check, so a human approves it."
  fi

  # Cargo.toml lints, and suppressions written into source files.
  local any_target=${#target_rels[@]}
  if [[ -n $writes || $any_target -gt 0 ]]; then
    if on cargo-lint-levels && grep -Eq -- '(^|[^[:alnum:]_.-])Cargo\.toml' <<<"$cmd" && grep -q 'lints' <<<"$cmd"; then
      ask "this command looks like it changes the lints tables in a Cargo.toml. Those set what clippy and rustc deny, so a human approves it."
    fi
    local l ere
    for rel in "${!rels[@]}"; do
      l=$(lang "$rel")
      [[ -n $l ]] || continue
      [[ $l == gotest ]] && l=go
      ere=$ere_any
      [[ -z ${ere_by[$l]:-} ]] || ere="${ere_by[$l]}|$ere"
      if grep -Eq -- "$ere" <<<"$cmd"; then
        ask "this command looks like it writes a lint or test suppression into $rel. Silencing a lint or skipping a test can hide a real problem, so a human approves it."
      fi
    done
  fi
  done_quiet
}

# Any unexpected failure inside main is reported, never a block.
out=$(main)
status=$?
if ((status != 0)); then
  say "the hook failed (exit $status), so this change was not checked for weakened checks."
fi
printf '%s' "${out:+$out$'\n'}"
exit 0
