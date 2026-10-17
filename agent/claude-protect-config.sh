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
#     built-in list without one. Wherever the built-in list applies, so do
#     the hook's own paths (hook_config_paths below), which CI doesn't
#     report. The config, the exceptions file and Claude Code's project
#     settings and hooks (.claude/settings.json, .claude/settings.local.json,
#     .claude/hooks/, at any depth) always ask. A config that doesn't parse
#     protects the built-in list plus every pathspec on its config-path lines.
#   - A Cargo.toml at any depth, only when the change touches the [lints],
#     [workspace.lints] or [profile] tables, compared by each value's full
#     dotted path, so the table a key sits under counts and its spelling
#     doesn't (or when the old text can't be found).
#   - A source file, when the new text holds a suppression the old text
#     doesn't: each match runs to the end of its attribute or comment, so
#     widening one asks as adding one does. The detector's annotation rules:
#     Rust allow/expect (also in cfg_attr), ignore, rustfmt::skip and a
#     disabling cfg; //nolint and t.Skip; @ts-nocheck, @ts-ignore,
#     @ts-expect-error without a reason, eslint-disable, biome-ignore, JS
#     test skip/only; svelte-ignore; Python skips; nosemgrep. Beyond them:
#     Rust should_panic and cfg(miri), a removed or narrowed Rust deny,
#     forbid or warn (not a raised level; a commented-out one counts), and
#     gitleaks:allow in any file. Rust attributes are compared without their
#     whitespace. A rule the config disables doesn't
#     ask (should_panic goes with rust-ignore, removed lint attributes with
#     rust-allow; gitleaks:allow can't be disabled). "x as unknown as T"
#     outside the test paths only adds context, unless the config prohibits
#     ts-as-unknown there and the exceptions file (read from HEAD) doesn't
#     allow it. An Edit is applied to the file before the comparison, and a
#     symlink is judged by its own name and its destination.
#   - Bash, best effort: the command is parsed (quotes, heredocs, $(...),
#     bash -c, eval, wrappers such as sudo and env), and only the files it
#     writes are judged: redirect targets, and what sed -i, perl -i, tee,
#     sponge, mv, cp, ln, install, rm, truncate, patch, dd, find -delete or
#     -exec, xargs and git checkout/restore/rm/mv/apply are given (against
#     cwd and any directory a cd or git -C names). It asks for a protected
#     path written (or a directory holding one, removed or checked out); any
#     write to a Cargo.toml; a source file written by a command whose text
#     holds a suppression, or a .rs file by one saying deny or forbid;
#     gitleaks:allow in a command that writes in the repository. A target in
#     a variable makes every literal path in the command count. A command
#     that doesn't parse is judged on all its words. A write through any
#     other program is not seen.
#
# Outcomes:
#   exit 0 with JSON permissionDecision "ask": a protected change. Claude
#     Code asks the user, showing the reason.
#   exit 0, nothing: anything else, outside a git repository, or
#     WEAKENED_CHECKS_PROTECT_CONFIG=off.
#   exit 0 with JSON additionalContext: an advisory note, or the check could
#     not run (jq or git missing or failing, input jq can't read, lib/ missing, bash
#     older than 4.4). Never blocks, never silent. Without awk, a Bash command
#     is judged on all its words, and an ask says so.
set -uo pipefail

opt_out="Set WEAKENED_CHECKS_PROTECT_CONFIG=off to turn this hook off."
cfg_file=.github/weakened-checks.conf
cfg_note=""
ask_note=""

# say <message>: tell the agent something without blocking, then exit 0.
# emit <field> <text>: the hook's JSON with one field, through jq, or written
# out by hand when jq is missing or fails.
emit() {
  local key=$1 m=$2
  if command -v jq >/dev/null 2>&1 &&
    jq -n --arg k "$key" --arg m "$m" '{hookSpecificOutput: ({hookEventName: "PreToolUse"} +
      if $k == "ask" then {permissionDecision: "ask", permissionDecisionReason: $m} else {additionalContext: $m} end)}' 2>/dev/null; then
    return 0
  fi
  m=${m//\\/\\\\}; m=${m//\"/\\\"}; m=${m//$'\n'/\\n}; m=${m//$'\t'/\\t}; m=${m//$'\r'/\\r}
  if [[ $key == ask ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$m"
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$m"
  fi
}

say() {
  emit context "weakened-checks hook: $1"
  exit 0
}

# ask <reason>: hand the decision to the user, then exit 0.
ask() {
  local r="weakened-checks hook: $1"
  [[ -z $ask_note ]] || r+=" $ask_note"
  [[ -z $cfg_note ]] || r+=" $cfg_note"
  emit ask "$r $opt_out"
  exit 0
}

# done_quiet: nothing to ask; a config that didn't parse is still said.
done_quiet() {
  [[ -z $cfg_note ]] || say "$cfg_note"
  exit 0
}

[[ ${WEAKENED_CHECKS_PROTECT_CONFIG:-} == off ]] && exit 0

input=$(cat)

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  say "bash ${BASH_VERSION} is older than 4.4, so this change was not checked for weakened checks."
fi
command -v git >/dev/null 2>&1 || say "git is not on PATH, so this change was not checked for weakened checks."
self=$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null) ||
  self=${BASH_SOURCE[0]}
lib=$(dirname -- "$self")/../lib/config.bash
[[ -r $lib ]] || say "$lib is missing (the hook must be a symlink into a clone of weakened-checks), so this change was not checked for weakened checks."
# shellcheck source=lib/config.bash
source "$lib" || say "could not load $lib, so this change was not checked for weakened checks."
# The hook's own additions to the built-in check-config list: files that
# define checks, protected wherever the built-in list is (no config-path,
# @defaults, a config that doesn't parse). Not in the detector's list, so CI
# doesn't report them; widening that list is a major version (README).
hook_config_paths=(
  docs/CODEOWNERS .lefthook.yaml lefthook-local.yml lefthook-local.yaml .lefthook-local.yml .lefthook-local.yaml
  .github/zizmor.yml .github/zizmor.yaml .github/actionlint.yml .github/actionlint.yaml
  ':(glob)**/.gitattributes' ':(glob)**/build.rs' ':(glob)**/.cargo/mutants.toml'
)
default_config_paths+=("${hook_config_paths[@]}")
cfg_error=""
# shellcheck disable=SC2329 # called by the parsers in lib/config.bash.
wc_config_error() { cfg_error=$1; }

scratch=""

# phys_dir <existing dir>: the directory with symlinks resolved, without
# needing realpath.
phys_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

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
  d=$(phys_dir "$d") || return 1
  printf '%s/%s\n' "${d%/}" "$rest"
}

# lexical_path <path> <resolved cwd>: <path> made absolute, with . and ..
# resolved as text and no process started: a long command has many words.
lexical_path() {
  local p=$1 part
  [[ $p == /* ]] || p="$2/$p"
  local -a parts kept=()
  IFS=/ read -r -a parts <<<"$p"
  for part in "${parts[@]}"; do
    case $part in
      '' | .) ;;
      ..) ((${#kept[@]} == 0)) || unset 'kept[-1]' ;;
      *) kept+=("$part") ;;
    esac
  done
  local IFS=/
  printf '/%s\n' "${kept[*]}"
}

# repo_root <dir>: the git repository's root of <dir>, or of its nearest
# existing parent (a new file may be in a directory not made yet), resolved.
repo_root() {
  local d=$1 r
  while [[ ! -d $d ]]; do d=$(dirname -- "$d"); done
  r=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || return 1
  phys_dir "$r"
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
    local -a extra
    mapfile -t extra < <(sed -nE 's/[[:space:]]+#.*$//; s/^[[:space:]]*config-path[[:space:]]+//p' <<<"$text" |
      tr -s ' \t' '\n' | grep -vx -e '@defaults' -e '')
    wc_reset
    wc_parse_config "" ""
    config_paths=("${default_config_paths[@]}" "${extra[@]}")
    cfg_note="($cfg_error: the config did not parse, so the built-in check-config list and the config's config-path entries are protected.)"
  fi
  cfg_error=""
  local ex
  if [[ $exceptions_path != none ]] && ex=$(git -C "$root" show "HEAD:$exceptions_path" 2>/dev/null); then
    wc_parse_exceptions "$ex" || exceptions=()
  fi
  # The config and the exceptions file are matched by name, so no pathspec
  # in the config (an :(exclude), say) can take them out.
  mandatory=("$cfg_file" .github/weakened-checks-exceptions)
  [[ $exceptions_path == none ]] || mandatory+=("$exceptions_path")
  protected=("${mandatory[@]}")
  if on check-config; then protected+=("${config_paths[@]}"); fi
}

# claude_settings <relative path>: whether it is Claude Code's project
# settings or hooks, at any depth (Claude Code reads them from the directory
# it starts in, which needn't be the repository root), or a .claude directory
# itself (a symlink or copy put in its place). Their env can turn this hook
# off, so they always ask, like the config.
claude_settings() {
  case /$1 in
    */.claude | */.claude/settings.json | */.claude/settings.local.json | */.claude/hooks | */.claude/hooks/*) return 0 ;;
  esac
  return 1
}

# holds_claude_settings <absolute dir>: whether the directory holds them,
# directly or as its .claude, tracked or not.
holds_claude_settings() {
  local d=$1 c
  for c in "$d/.claude" "$d"; do
    [[ $c == */.claude ]] || continue
    [[ -e $c/settings.json || -e $c/settings.local.json || -e $c/hooks ]] && return 0
  done
  return 1
}

# protected_matches <root> <relative path>...: prints those that match the
# protected pathspecs, by git's own pathspec rules: the paths go into a
# throwaway index (they needn't exist) and ls-files picks the matches.
# Returns 1 when git fails, so the caller can say so.
protected_matches() {
  local root=$1 idx p m ok=0
  shift
  (($# > 0)) || return 0
  for p in "$@"; do
    for m in "${mandatory[@]}"; do [[ $p == "$m" ]] && printf '%s\n' "$p"; done
    claude_settings "$p" && printf '%s\n' "$p"
  done
  # git refuses some paths (.git/..., a path with ..) in an index; those
  # aren't check config, so they're left out rather than failing the rest.
  local -a valid=()
  for p in "$@"; do
    [[ $p == .git || $p == .git/* || /$p/ == */../* || /$p/ == */./* ]] || valid+=("$p")
  done
  ((${#valid[@]} > 0)) || return 0
  idx=$scratch/index.$BASHPID
  printf '100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\t%s\0' "${valid[@]}" |
    GIT_INDEX_FILE=$idx git -C "$root" update-index --add -z --index-info 2>/dev/null &&
    GIT_INDEX_FILE=$idx git -C "$root" -c core.quotePath=false ls-files -- "${protected[@]}" 2>/dev/null ||
    ok=1
  rm -f "$idx"
  return "$ok"
}
git_failed="git could not match paths against the check-config list, so this change was not checked for weakened checks."

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
rules_by[rust]="rust-allow	#\\s*!?\\s*\\[\\s*(?:allow|expect)\\s*\\((?:[^\\]\"]|\"(?:[^\"\\\\]|\\\\.)*\")*\\]?
rust-allow	#\\s*!?\\s*\\[\\s*cfg_attr\\s*\\([^\\]]*\\b(?:allow|expect)\\s*\\([^\\]]*\\]?
rust-ignore	#\\s*!?\\s*\\[\\s*(?:cfg_attr\\s*\\([^\\]]*\\b)?(?:ignore|should_panic)\\b(?:[^\\]\"]|\"(?:[^\"\\\\]|\\\\.)*\")*\\]?
rust-cfg	#\\s*!?\\s*\\[\\s*cfg\\s*\\(\\s*(?:any\\s*\\(\\s*\\)|not\\s*\\(\\s*all\\s*\\(\\s*\\)\\s*\\)|false|miri)\\s*\\)[^\\]]*\\]?
rust-rustfmt-skip	#\\s*!?\\s*\\[[^\\]]*\\b(?:rustfmt\\s*::\\s*skip|rustfmt_skip)\\b[^\\]]*\\]?"
rules_by[go]="go-nolint	//[ \\t]?nolint\\b$cmt"
rules_by[gotest]="${rules_by[go]}
go-test-skip	\\.(?:Skip|Skipf|SkipNow)[ \\t]*\\("
rules_by[ts]="ts-nocheck	@ts-nocheck\\b$cmt
ts-ignore	@ts-ignore\\b$cmt
ts-expect-error	@ts-expect-error[ \\t:-]*(?:\\*/[ \\t]*)?(?=\\n|$)
eslint-disable	\\beslint-disable$cmt
biome-ignore	\\bbiome-ignore$cmt
js-test-skip	(?<![A-Za-z0-9_\$.])(?:(?:it|test|describe|suite|bench)(?:\\.(?:concurrent|sequential))?\\.(?:skip|only|todo)(?:\\.[A-Za-z]+)*|x(?:it|test|describe)(?:\\.[A-Za-z]+)*)[ \\t]*\\(
js-test-skip	(?<![A-Za-z0-9_\$.])(?:it|test|describe|suite|bench)(?:\\.(?:concurrent|sequential))?\\.(?:skipIf|runIf)[ \\t]*\\([^)\\n]*\\)?
ts-as-unknown	\\bas[ \\t\\n]+unknown[ \\t\\n]+as\\b"
rules_by[svelte]="${rules_by[ts]}
svelte-ignore	svelte-ignore(?:(?!-->)[^\\n])*"
rules_by[python]="py-test-skip	@[ \\t]*(?:pytest\\.mark\\.(?:skip|skipif|xfail)|unittest\\.(?:skip|skipIf|skipUnless|expectedFailure))\\b[^\\n]*
py-test-skip	\\b(?:pytest\\.skip|self\\.skipTest)[ \\t]*\\("
rules_nosemgrep="nosemgrep	\\bnosemgrep\\b$cmt"
# In any file. No detector rule, so the config can't turn it off.
rules_any="gitleaks-allow	gitleaks:allow"
# A Rust deny, forbid, warn or cfg_attr attribute, whole (a "]" in a string
# literal doesn't end it), and the ones that make lints stricter, whose
# removal asks.
rust_lvl_attr_re='#\s*!?\s*\[\s*(?:deny|forbid|warn|cfg_attr)\b(?:[^\]"]|"(?:[^"\\]|\\.)*")*\]'
rust_strict_re='^#!?\[(deny|forbid|warn)\(|^#!?\[cfg_attr\(.*\b(deny|forbid|warn)\('

# rules_for <lang>: its rules as a JSON array of {rule, re}, less disabled
# ones; for no language, only gitleaks:allow.
rules_for() {
  local lines=$rules_any
  if [[ -n $1 ]]; then
    [[ -z ${rules_by[$1]:-} ]] || lines+=$'\n'${rules_by[$1]}
    lines+=$'\n'$rules_nosemgrep
  fi
  local out="" rule re
  while IFS=$'\t' read -r rule re; do
    on "$rule" || continue
    out+=$rule$'\t'$re$'\n'
  done <<<"$lines"
  printf '%s' "$out" | jq -Rn '[inputs | split("\t") | {rule: .[0], re: (.[1:] | join("\t"))}]'
}

# Bash's view of the same suppressions (EREs), by language.
# Rust's tolerates spaces and a sed script's \[ and \(.
ere_by[rust]='#[[:space:]]*!?[[:space:]]*\\?\[[[:space:]]*(allow|expect|ignore|should_panic|rustfmt[[:space:]]*::[[:space:]]*skip)([^[:alnum:]_]|$)|cfg_attr[[:space:]]*\\?\(.*([^[:alnum:]_](allow|expect|ignore|should_panic)|rustfmt[[:space:]]*::[[:space:]]*skip)([^[:alnum:]_]|$)|#[[:space:]]*!?[[:space:]]*\\?\[[[:space:]]*cfg[[:space:]]*\\?\([[:space:]]*(any[[:space:]]*\\?\([[:space:]]*\\?\)|not[[:space:]]*\\?\([[:space:]]*all[[:space:]]*\\?\([[:space:]]*\\?\)[[:space:]]*\\?\)|false|miri)[[:space:]]*\\?\)|rustfmt_skip'
# A .rs write that says deny or forbid may remove or loosen one.
rust_strict_ere='(^|[^[:alnum:]_])(deny|forbid)([^[:alnum:]_]|$)'
ere_by[go]='//[[:space:]]?nolint'
ere_by[gotest]='//[[:space:]]?nolint|\.Skip(f|Now)?\('
ere_by[ts]='@ts-(nocheck|ignore|expect-error)|eslint-disable|biome-ignore|(^|[^[:alnum:]_$.])(it|test|describe|suite|bench)(\.(concurrent|sequential))?\.(skip|only|todo|skipIf|runIf)|(^|[^[:alnum:]_$.])x(it|test|describe)[[:space:]]*\('
ere_by[svelte]="${ere_by[ts]}|svelte-ignore"
ere_by[python]='pytest\.mark\.(skip|skipif|xfail)|unittest\.(skip|expectedFailure)|pytest\.skip|skipTest'
ere_any='nosemgrep'

# relevant <root> <rel>: whether a change to <rel> is one this hook judges.
relevant() {
  [[ -n $(protected_matches "$1" "$2") ]] && return 0
  [[ $input == *gitleaks* ]] && return 0
  [[ $2 == Cargo.toml || $2 == */Cargo.toml || -n $(lang "$2") ]]
}

main() {
  scratch=$(mktemp -d) || say "mktemp failed, so this change was not checked for weakened checks."
  trap 'rm -rf "$scratch"' EXIT
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
  abs=$(abs_path "$file" "$cwd") || say "could not resolve $file, so this change was not checked for weakened checks."
  root=$(repo_root "$(dirname -- "$abs")") || exit 0
  [[ $abs == "$root"/* ]] || exit 0
  rel=${abs#"$root"/}
  load_config "$root"

  # A symlink is judged by its own name and by the file it writes to, and a
  # path through a symlinked directory by its name as given too.
  local -a names=("$rel")
  local dest lex
  lex=$(lexical_path "$file" "$(phys_dir "$cwd" || printf '%s' "$cwd")")
  [[ $lex == "$root"/* && $lex != "$abs" ]] && names+=("${lex#"$root"/}")
  if [[ -L $abs ]] && dest=$(realpath -m -- "$abs" 2>/dev/null) && [[ $dest == "$root"/* ]]; then
    names+=("${dest#"$root"/}")
  fi
  local hit
  hit=$(protected_matches "$root" "${names[@]}") || say "$git_failed"
  hit=${hit%%$'\n'*}
  if [[ -n $hit ]] && claude_settings "$hit"; then
    ask "$hit is Claude Code's project settings or hooks, which can turn this hook off (an env setting, disableAllHooks, a changed hook), so a human approves this edit."
  fi
  if [[ -n $hit ]]; then
    ask "$hit is check config: it sets what CI, the hooks or the weakened-checks detector check. Changing it can weaken them, so a human approves this edit."
  fi

  # The current content, as a file for jq (empty for a new file): a large
  # file doesn't fit in one argument.
  local cur=$scratch/empty
  : >"$cur"
  [[ -f $abs && -r $abs ]] && cur=$abs

  if [[ $rel == Cargo.toml || $rel == */Cargo.toml ]] && on cargo-lint-levels; then
    judge_cargo "$rel" "$cur"
  fi

  local l
  l=$(lang "$rel")
  # Any other file is only read for an added gitleaks:allow, when the edit or
  # the file mentions gitleaks (an edit can complete the marker).
  [[ -n $l || $input == *gitleaks* ]] || grep -q gitleaks "$cur" || done_quiet
  local rules strict=false
  rules=$(rules_for "$l") || say "could not build the suppression rules with jq, so this change to $rel was not checked."
  # Removed lint attributes, only when there can be one: a match pass over a
  # large attribute-dense file is slow.
  local lvl_re='(deny|forbid|warn)[[:space:]]*\('
  if [[ $l == rust ]] && on rust-allow && { grep -Eq "$lvl_re" "$cur" || grep -Eq "$lvl_re" <<<"$input"; }; then
    strict=true
    # jq's cost grows with the square of the matches; past this many the
    # hook would outlive its timeout, so it says so instead.
    if (($(grep -Ec "$lvl_re" "$cur") > 1000)); then
      strict=false
      cfg_note+="${cfg_note:+ }($rel has over 1000 lint attributes, so this edit was not checked for removed ones.)"
    fi
  fi
  # The suppressions the new text holds more often than the old, as
  # "rule<TAB>text" lines, and with strict, the Rust deny, forbid and warn
  # lints the old text holds more often than the new, as "-strict<TAB>text".
  # Rust attributes are compared with their whitespace removed, so respacing
  # one is no change; the text shown is the first as written.
  local found
  found=$(printf '%s' "$input" | jq -r --rawfile cur "$cur" --argjson rules "$rules" --arg lang "$l" \
    --argjson strict "$strict" --arg lvl_attr "$rust_lvl_attr_re" --arg strict_re "$rust_strict_re" '
    def shown: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
    def key: if $lang == "rust" then gsub("\\s+"; "") else shown end;
    def spans: . as $t | [$rules[] as $r | $t | match($r.re; "g") | .string
      | {rule: $r.rule, k: key, s: shown}];
    # The deny, forbid, warn and cfg_attr attributes outside comments and
    # strings, so one commented out or quoted is gone. Only these are
    # matched (each match costs jq a pass over the text before it), and
    # where each one sits is read from the text before it: inside a block
    # comment, or after a // or an open quote on its line. The strings inside
    # an attribute are emptied.
    def attrs: . as $t | [match($lvl_attr; "g") | .offset as $at | .string
      | ($t[0:$at]) as $pre | ($pre | rindex("/*")) as $open | ($pre | rindex("*/")) as $close
      | ($pre[(($pre | rindex("\n")) // -1) + 1:] | gsub("\\\\."; "")) as $line
      | select(($open == null or ($close != null and $close > $open))
          and ($line | test("//") | not) and ([$line | match("\""; "g")] | length % 2 == 0))
      | gsub("\"(?:[^\"\\\\]|\\\\.)*\""; "\"\"")];
    def rank: {warn: 1, deny: 2, forbid: 3}[.];
    # Each deny, forbid or warn as one (level, lint) pair, so adding a lint to
    # the list is no removal; a cfg_attr applying one stays whole.
    def stricts: [attrs[] | gsub("\\s+"; "") | select(test($strict_re))
      | (capture("^#(?<b>!?)\\[(?<lvl>deny|forbid|warn)\\((?<l>.*)\\)\\]$") // null) as $c
      | if $c == null then {rule: "-strict", k: ., s: .}
        else $c.l | split(",")[] | select(. != "" and (test("^reason=") | not))
          | ("#" + $c.b + "[" + $c.lvl + "(" + . + ")]") as $p
          | {rule: "-strict", k: $p, s: $p, lint: ($c.b + .), lvl: ($c.lvl | rank)}
        end];
    # The strictest level each lint has, so raising one (warn to deny, deny to
    # forbid) is no removal.
    def best: map(select(.lint != null)) | group_by(.lint) | map({key: .[0].lint, value: (map(.lvl) | max)}) | from_entries;
    def bag: group_by([.rule, .k]) | map({key: (.[0].rule + "\t" + .[0].k), value: (.[0] + {n: length})}) | from_entries;
    def more($a; $b): ($b | bag) as $o | $a | bag | to_entries[] | select(.value.n > ($o[.key].n // 0)) | .value;
    # An edit is applied to the current file, so a change to part of a
    # suppression is judged on the whole of it. An edit whose old text is
    # not in the file is judged on its own texts.
    def apply($e): ($e.old_string // "") as $o | ($e.new_string // "") as $n
      | (if $o == "" then [] else .text | split($o) end) as $p
      | if ($p | length) < 2 then .old += [$o] | .new += [$n]
        elif $e.replace_all then .text = ($p | join($n))
        else .text = $p[0] + $n + ($p[1:] | join($o)) end;
    (if .tool_name == "Write" then {old: [$cur], new: [.tool_input.content // ""]}
     else (if .tool_name == "Edit" then [.tool_input] else [.tool_input.edits[]?] end) as $edits
       | reduce $edits[] as $e ({text: $cur, old: [], new: []}; apply($e))
       | {old: ([$cur] + .old), new: ([.text] + .new)}
     end) as $t
    | (more([$t.new[] | spans[]]; [$t.old[] | spans[]]) | .rule + "\t" + .s),
      (if $strict then [$t.new[] | stricts[]] as $n | ($n | best) as $best
         | more([$t.old[] | stricts[]]; $n) | select(.lint == null or ($best[.lint] // 0) < .lvl) | .rule + "\t" + .s
       else empty end)' 2>/dev/null) ||
    say "could not read the edit with jq, so this change to $rel was not checked for added suppressions."
  [[ -n $found ]] || done_quiet

  local asks="" unknown="" leaks="" removed="" r s
  while IFS=$'\t' read -r r s; do
    case $r in
      ts-as-unknown) is_test_path "$rel" || unknown=$s ;;
      gitleaks-allow) leaks=$s ;;
      -strict) removed+="${removed:+, }$s" ;;
      *) asks+="${asks:+; }$s" ;;
    esac
  done <<<"$found"
  if [[ -n $asks ]]; then
    ((${#asks} <= 300)) || asks="${asks:0:300}..."
    ask "this edit adds or widens a lint or test suppression in $rel ($asks). Silencing a lint or skipping a test can hide a real problem, so a human approves it."
  fi
  if [[ -n $removed ]]; then
    ((${#removed} <= 300)) || removed="${removed:0:300}..."
    ask "this edit removes or narrows a lint attribute in $rel ($removed). A deny, forbid or warn in the code is a check, so a human approves loosening it."
  fi
  if [[ -n $leaks ]]; then
    ask "this edit adds a $leaks comment to $rel, which hides a line from secret scanning, so a human approves it."
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

# judge_cargo <rel> <current content>: asks when the edit changes the lints
# or [profile] tables.
judge_cargo() {
  local rel=$1 cur=$2 verdict
  verdict=$(printf '%s' "$input" | jq -r --rawfile cur "$cur" --arg q "'" '
    def seg: "(?:\"(?:[^\"\\\\]|\\\\.)*\"|" + $q + "[^" + $q + "]*" + $q + "|[A-Za-z0-9_-]+)";
    # A key as its dotted segments, spaces removed and a quoted segment
    # unquoted, unless it holds a dot or an escape: ["lints.clippy"] is one
    # key, not the lints.clippy table.
    def keyof: [match(seg; "g") | .string
      | if test("^[\"" + $q + "]") and (.[1:-1] | test("[.\\\\]") | not) then .[1:-1] else . end] | join(".");
    # A value with the spaces and the comment outside its strings removed.
    def vnorm: gsub("(?<s>\"(?:[^\"\\\\]|\\\\.)*\"|" + $q + "[^" + $q + "]*" + $q + ")|\\s+|#.*$";
      if .s != null then .s else "" end);
    def odd($d): [match($d; "g")] | length % 2 == 1;
    # Each key as "<full dotted path>=<value>", so the table context counts
    # and the spelling does not: a key under [workspace.lints.clippy] and the
    # dotted clippy.<key> under [workspace.lints] are the same. A line that is
    # neither a header nor a key (a multi-line array) is added, in order, to
    # the key above it, as is every line of a multi-line string. Kept: the
    # keys under lints, workspace.lints or profile, any that mention lints,
    # and any whose key holds an escape (it could spell one of those).
    def records: split("\n") | reduce .[] as $l ({tbl: "", last: false, ml: null, out: []};
      if .ml != null then
        .ml as $d | .out[(.out | length) - 1] += "+" + $l | if ($l | odd($d)) then .ml = null else . end
      elif ($l | test("^\\s*(#.*)?$")) then .
      elif ($l | test("^\\s*\\[\\[?\\s*" + seg + "(\\s*\\.\\s*" + seg + ")*\\s*\\]\\]?\\s*(#.*)?$")) then
        .tbl = ($l | capture("^\\s*\\[\\[?(?<k>[^\\]]*)\\]").k | keyof) | .last = false
      else ([$l | capture("^\\s*(?<k>" + seg + "(\\s*\\.\\s*" + seg + ")*)\\s*=(?<v>.*)$")] | .[0]) as $m
        | if $m != null then
            ((if .tbl == "" then "" else .tbl + "." end) + ($m.k | keyof)) as $p
            | .last = true | .out += [$p + "=" + ($m.v | vnorm)]
            | if ($m.v | odd("\"\"\"")) then .ml = "\"\"\""
              elif ($m.v | odd($q + $q + $q)) then .ml = ($q + $q + $q) else . end
          elif .last then .out[(.out | length) - 1] += "+" + ($l | vnorm)
          else .out += [.tbl + "+" + ($l | vnorm)]
          end
      end) | .out
      | map(select(test("^((workspace\\.)?lints|profile)([.=+]|$)") or test("lints") or test("^[^=+]*\\\\"))) | sort;
    # The file with the edits applied, or null when an old text is missing.
    def applied($edits): reduce $edits[] as $e ($cur;
      if . == null then null else
        ($e.old_string // "") as $o | ($e.new_string // "") as $n
        | if $o == "" then (if . == "" then $n else null end)
          else split($o) as $p
            | if ($p | length) < 2 then null
              elif $e.replace_all then $p | join($n)
              else $p[0] + $n + ($p[1:] | join($o)) end
          end
      end);
    (if .tool_name == "Write" then .tool_input.content // ""
     else applied(if .tool_name == "Edit" then [.tool_input] else [.tool_input.edits[]?] end) end) as $after
    | if $after == null then
        (if ([.tool_input, .tool_input.edits[]?] | map((.old_string // "") + (.new_string // "")) | join("\n")
             | test("lints|profile")) then "lints" else "unsure" end)
      elif ($after | records) == ($cur | records) then "no"
      else "lints" end' 2>/dev/null) || say "could not read the edit with jq, so this change to $rel was not checked for lints changes."
  case $verdict in
    lints) ask "this edit changes the [lints], [workspace.lints] or [profile] tables in $rel, which set what clippy, rustc and the tests check. Changing them can weaken the checks, so a human approves this edit." ;;
    unsure) ask "this edit's old text isn't in $rel as it is now, so the hook can't tell whether it touches the [lints] or [profile] tables. A human approves it." ;;
  esac
}

# judge_bash_words <command> <root> <resolved cwd>: the fallback for a
# command the parser can't read: a writer word anywhere and a protected path
# anywhere ask, as the hook did before it parsed commands.
judge_bash_words() {
  local cmd=$1 root=$2 rcwd=$3
  # $PWD and $(pwd) are the working directory the command starts in.
  # shellcheck disable=SC2016 # the literal text is what's replaced.
  cmd=${cmd//'$(pwd)'/$rcwd} cmd=${cmd//'${PWD}'/$rcwd} cmd=${cmd//'$PWD'/$rcwd}

  # install only where a command starts, so "pnpm install" isn't a write.
  local bin="(/[^[:space:];&|]*/)?"
  local writers="(^|[;&|({[:space:]])$bin((sed|perl)[[:space:]][^;&|]*-[a-zA-Z]*i[^[:space:]]*|tee|mv|cp|rm|truncate|ln|patch|dd|git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--[a-z-]+=[^[:space:]]+|-[a-z]))*[[:space:]]+(checkout|restore|rm|mv|apply))([[:space:]]|$)"
  local starts_install="(^|[;&|({])[[:space:]]*(sudo[[:space:]]+)?${bin}install[[:space:]]"
  local writes=""
  grep -Eq -- "$writers" <<<"$cmd" && writes=1
  grep -Eq -- "$starts_install" <<<"$cmd" && writes=1

  # The words, quotes dropped, split on spaces and shell operators; and the
  # targets of > and >>.
  local -a words targets
  read -r -a words <<<"$(tr -d "\"'" <<<"$cmd" | tr ';&|()<>=\n\t' '         ')"
  mapfile -t targets < <(tr -d "\"'" <<<"$cmd" | grep -oE '[0-9]?>(>|\|)?[[:space:]]*[^[:space:];&|<>()]+' |
    sed -E 's/^[0-9]?>(>|\|)?[[:space:]]*//' | grep -v '^&')

  # Each word (and target) as a path relative to the root, when it is one.
  local w abs rel dest
  local -A rels=() target_rels=() dirs=()
  for w in "${targets[@]}"; do
    abs=$(lexical_path "$w" "$rcwd")
    [[ $abs == "$root"/* ]] || continue
    target_rels[${abs#"$root"/}]=1
    if [[ -L $abs ]] && dest=$(realpath -m -- "$abs" 2>/dev/null) && [[ $dest == "$root"/* ]]; then
      target_rels[${dest#"$root"/}]=1
    fi
  done
  for w in "${words[@]}" "${targets[@]}"; do
    [[ -n $w && $w != -* && $w != *://* ]] || continue
    abs=$(lexical_path "$w" "$rcwd")
    [[ $abs == "$root"/* ]] || continue
    rel=${abs#"$root"/}
    rel=${rel%/}
    [[ -n $rel && $rel != .git && $rel != .git/* ]] || continue
    rels[$rel]=1
    [[ -d $abs ]] && dirs[$rel]=1
    # A symlink writes to its destination.
    if [[ -L $abs ]] && dest=$(realpath -m -- "$abs" 2>/dev/null) && [[ $dest == "$root"/* ]]; then
      rels[${dest#"$root"/}]=1
    fi
  done

  local named="" targeted="" m hits=""
  if ((${#rels[@]} > 0)); then
    hits=$(protected_matches "$root" "${!rels[@]}") || say "$git_failed"
    while IFS= read -r m; do
      [[ -n $m && $named != *"$m"* ]] || continue
      named+="${named:+, }$m"
      [[ -n ${target_rels[$m]:-} ]] && targeted=1
    done <<<"$hits"
  fi
  # git checkout/restore or rm of the whole tree, from its root.
  if [[ -z $named ]] && grep -Eq -- "(^|[;&|({[:space:]])${bin}(rm[[:space:]]|git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+(checkout|restore)[[:space:]])" <<<"$cmd"; then
    for w in "${words[@]}"; do
      [[ $w != -* ]] || continue
      [[ $(lexical_path "$w" "$rcwd") == "$root" ]] && { named="the whole repository"; break; }
    done
  fi
  # A directory word names the protected files under it, tracked or not.
  if [[ -z $named && ${#dirs[@]} -gt 0 ]]; then
    local -a existing
    mapfile -t existing < <(git -C "$root" -c core.quotePath=false ls-files --cached --others --exclude-standard -- "${protected[@]}" 2>/dev/null)
    for m in "${mandatory[@]}"; do [[ ! -e $root/$m ]] || existing+=("$m"); done
    # Claude Code's settings and hooks, deeper down, unless gitignored.
    mapfile -t -O "${#existing[@]}" existing < <(git -C "$root" -c core.quotePath=false ls-files --cached --others --exclude-standard -- \
      ':(glob)**/.claude/settings.json' ':(glob)**/.claude/settings.local.json' ':(glob)**/.claude/hooks/**' 2>/dev/null)
    local d f
    for d in "${!dirs[@]}"; do
      # Directly in it, or as it, they count even when gitignored.
      holds_claude_settings "$root/$d" && { named+="${named:+, }$d"; continue; }
      for f in "${existing[@]}"; do
        [[ $f == "$d"/* ]] && { named+="${named:+, }$d"; break; }
      done
    done
  fi
  if [[ -n $named ]] && [[ -n $writes || -n $targeted ]]; then
    ask "this command looks like it changes check config ($named). That can weaken what CI, the hooks or the weakened-checks detector check, so a human approves it."
  fi

  # Any write to a Cargo.toml: from a command line there's no telling which
  # table it lands in. A --manifest-path argument only names one. Then
  # suppressions written into source files, and gitleaks:allow anywhere.
  local any_target=${#target_rels[@]}
  if [[ -n $writes || $any_target -gt 0 ]]; then
    if on cargo-lint-levels; then
      local cargo="" t
      for t in "${!target_rels[@]}"; do [[ $t == Cargo.toml || $t == */Cargo.toml ]] && cargo=1; done
      [[ -n $writes ]] && sed -E 's/--manifest-path(=|[[:space:]]+)[^[:space:];&|]+//g' <<<"$cmd" |
        grep -Eq -- '(^|[^[:alnum:]_.-])Cargo\.toml' && cargo=1
      if [[ -n $cargo ]]; then
        ask "this command looks like it changes a Cargo.toml. Its lints tables and [profile] set what clippy, rustc and the tests check, so a human approves it."
      fi
    fi
    local l ere
    for rel in "${!rels[@]}"; do
      l=$(lang "$rel")
      [[ -n $l ]] || continue
      ere=$ere_any
      [[ -z ${ere_by[$l]:-} ]] || ere="${ere_by[$l]}|$ere"
      if grep -Eq -- "$ere" <<<"$cmd"; then
        ask "this command looks like it writes a lint or test suppression into $rel. Silencing a lint or skipping a test can hide a real problem, so a human approves it."
      fi
      if [[ $l == rust ]] && on rust-allow && grep -Eq -- "$rust_strict_ere" <<<"$cmd"; then
        ask "this command looks like it writes to $rel and says deny or forbid, so it may remove or loosen a lint attribute. A human approves it."
      fi
    done
    if grep -q -- 'gitleaks:allow' <<<"$cmd"; then
      ask "this command looks like it writes a gitleaks:allow comment, which hides a line from secret scanning, so a human approves it."
    fi
  fi
  done_quiet
}

# The shell parser, in POSIX awk. It reads a command on stdin and prints one
# record per line, fields split by tabs, with \, tab and newline escaped:
#   C <id> <pipeline>       a simple command starts
#   W <id> <L|X> <word>     one of its words, quotes removed (X: it holds a $
#                           or backtick expansion, kept as written)
#   R <id> <L|X> <word>     a file a redirect writes (>, >>, >|, &>, >& file, <>)
#   H <id> <quoted> <body>  a heredoc the command reads
#   I <id> <word>           a here-string the command reads
#   E                       the command didn't parse (an open quote or $( )
# $(...), backticks and <(...) inside a word, in double quotes or in a heredoc
# whose delimiter isn't quoted are parsed as commands of their own.
read -r -d '' shell_awk <<'AWK'
BEGIN {
  S = ""
  while ((getline line) > 0) S = S line "\n"
  N = length(S); P = 1; CUR = 0; PIPE = 1; NC = 0; NH = 0; HB = 0; ERR = 0
  parse_list("")
  if (ERR) print "E"
  exit
}
function ch(i) { return substr(S, i, 1) }
# enc(s): s with \, tab and newline escaped, so a record is one line.
function enc(s,   out, m, c) {
  out = ""
  while ((m = match(s, /[\\\t\n]/)) > 0) {
    c = substr(s, m, 1)
    out = out substr(s, 1, m - 1) (c == "\\" ? "\\\\" : c == "\t" ? "\\t" : "\\n")
    s = substr(s, m + 1)
  }
  return out s
}
# next_at(re): the offset from P (1 is P itself) of the next character
# matching re, or 0. It reads a window at a time, so a long command isn't
# copied for every quote.
function next_at(re,   off, m) {
  for (off = 0; P + off <= N; off += 512)
    if ((m = match(substr(S, P + off, 512), re)) > 0) return off + m
  return 0
}
function new_cmd() { NC++; CUR = NC; print "C\t" NC "\t" PIPE }
# parse_list(term): commands up to term (")") or the end. A ")" with no "("
# (a case pattern) ends a command.
function parse_list(term,   c, d) {
  while (P <= N && !ERR) {
    c = ch(P)
    if (c == " " || c == "\t") { P++; continue }
    if (c == "\n") { P++; CUR = 0; PIPE++; if (NH > HB) read_heredocs(); continue }
    if (c == "#") { d = next_at("\n"); P = d ? P + d - 1 : N + 1; continue }
    if (c == ")") { if (term == ")") return 1; P++; CUR = 0; PIPE++; continue }
    if (c == "(") {
      if (CUR == 0 && ch(P + 1) == "(") { skip_parens(); continue }
      P++
      if (CUR == 0) {
        parse_list(")")
        if (P > N) { ERR = 1; return 0 }
        P++; CUR = 0
      }
      continue
    }
    if (c == "&" && ch(P + 1) == ">") { P++; redirect("&"); continue }
    if (c == "|") {
      d = ch(P + 1); P += (d == "|" || d == "&") ? 2 : 1
      CUR = 0; if (d == "|") PIPE++
      continue
    }
    if (c == ";" || c == "&") {
      P++
      while (ch(P) == ";" || (ch(P) == "&" && ch(P + 1) != ">")) P++
      CUR = 0; PIPE++
      continue
    }
    if (c == "<" || c == ">") { redirect(""); continue }
    read_word()
    # A file descriptor number before a redirect isn't a word.
    if (!RWQ && !RWX && RW ~ /^[0-9]+$/ && (ch(P) == "<" || ch(P) == ">")) continue
    if (CUR == 0) new_cmd()
    print "W\t" CUR "\t" (RWX ? "X" : "L") "\t" enc(RW)
  }
  return 0
}
# read_word: one word into RW; RWX says it holds an expansion, RWQ that some
# of it was quoted or escaped.
function read_word(   w, wx, wq, c, d) {
  w = ""; wx = 0; wq = 0
  while (P <= N && !ERR) {
    c = ch(P)
    if (index(" \t\n;&|()<>", c)) break
    if (c == "\\") { if (ch(P + 1) != "\n") { w = w ch(P + 1); wq = 1 } P += 2; continue }
    if (c == "'") {
      P++; d = next_at("'")
      if (!d) { ERR = 1; break }
      w = w substr(S, P, d - 1); P += d; wq = 1
      continue
    }
    if (c == "\"") { P++; w = w scan_dq(0); wx = wx || DQX; wq = 1; continue }
    if (c == "$") {
      d = ch(P + 1)
      if (d == "'") {
        P += 2; wq = 1
        while (P <= N && ch(P) != "'") { if (ch(P) == "\\") { w = w substr(S, P, 2); P += 2 } else { w = w ch(P); P++ } }
        if (P > N) { ERR = 1; break }
        P++
        continue
      }
      if (d == "(" || d == "{") { w = w dollar(); wx = 1; continue }
      w = w "$"; P++; wx = 1
      continue
    }
    if (c == "`") { w = w backtick(); wx = 1; continue }
    w = w c; P++
  }
  RW = w; RWX = wx; RWQ = wq
}
# scan_dq(eos): the inside of double quotes (with eos, a heredoc body to the
# end). DQX says it holds an expansion.
function scan_dq(eos,   out, c, d, x) {
  out = ""; x = 0
  while (P <= N && !ERR) {
    d = next_at(eos ? "[\\\\$`]" : "[\\\\\"$`]")
    if (!d) { out = out substr(S, P); P = N + 1; break }
    out = out substr(S, P, d - 1); P += d - 1; c = ch(P)
    if (c == "\"") { P++; DQX = x; return out }
    if (c == "\\") {
      d = ch(P + 1)
      if (d != "" && index("$`\"\\", d)) out = out d
      else if (d != "\n") out = out "\\" d
      P += 2
      continue
    }
    if (c == "$") {
      if (ch(P + 1) == "(" || ch(P + 1) == "{") out = out dollar()
      else { out = out "$"; P++ }
      x = 1
      continue
    }
    out = out backtick(); x = 1
  }
  if (!eos) ERR = 1
  DQX = x
  return out
}
# dollar: the $((...)), ${...} or $(...) at P, as written; $(...) is parsed.
function dollar(   st, sc, sp) {
  st = P
  if (ch(P + 1) == "{") { P += 2; skip_brace(); return substr(S, st, P - st) }
  if (ch(P + 2) == "(") { P++; skip_parens(); return substr(S, st, P - st) }
  P += 2; sc = CUR; sp = PIPE; CUR = 0; PIPE++
  parse_list(")")
  CUR = sc; PIPE = sp
  if (P > N) { ERR = 1; return "" }
  P++
  return substr(S, st, P - st)
}
function backtick(   st, inner) {
  st = P; P++
  while (P <= N && ch(P) != "`") P += (ch(P) == "\\") ? 2 : 1
  if (P > N) { ERR = 1; return "" }
  inner = substr(S, st + 1, P - st - 1); P++
  gsub(/\\`/, "`", inner)
  sub_parse(inner, 0)
  return substr(S, st, P - st)
}
# skip_parens: past the arithmetic (( ... )) at P.
function skip_parens(   n, c) {
  n = 0
  while (P <= N) {
    c = ch(P); P++
    if (c == "(") n++
    else if (c == ")" && --n == 0) return
  }
  ERR = 1
}
# skip_brace: past a ${...} whose "${" is behind P.
function skip_brace(   n, c) {
  n = 1
  while (P <= N) {
    c = ch(P)
    if (c == "\\") { P += 2; continue }
    if (c == "'" || c == "\"") {
      P++
      while (P <= N && ch(P) != c) P += (c == "\"" && ch(P) == "\\") ? 2 : 1
      P++
      continue
    }
    P++
    if (c == "{") n++
    else if (c == "}" && --n == 0) return
  }
  ERR = 1
}
# sub_parse(text, dq): text parsed as commands (with dq, as a heredoc body
# that expands), the parser's place saved around it.
function sub_parse(text, dq,   s0, n0, p0, c0, hb0) {
  s0 = S; n0 = N; p0 = P; c0 = CUR; hb0 = HB
  S = dq ? text : text "\n"; N = length(S); P = 1; CUR = 0; PIPE++; HB = NH
  if (dq) scan_dq(1); else parse_list("")
  NH = HB; HB = hb0; S = s0; N = n0; P = p0; CUR = c0; PIPE++
}
# procsub: the <(...) or >(...) at P.
function procsub(   sc, sp) {
  P += 2; sc = CUR; sp = PIPE; CUR = 0; PIPE++
  parse_list(")")
  CUR = sc; PIPE = sp
  if (P > N) { ERR = 1; return }
  P++
}
# redirect(pre): the redirect at P ("&" when an & came before it).
function redirect(pre,   op, c, d, w) {
  c = ch(P); d = ch(P + 1)
  if (pre == "&") { op = (d == ">") ? "&>>" : "&>"; P += (d == ">") ? 2 : 1 }
  else if (d == "(") { procsub(); return }
  else if (c == ">") {
    if (d == ">" || d == "|" || d == "&") { op = c d; P += 2 } else { op = ">"; P++ }
  } else if (d == "<") {
    if (ch(P + 2) == "<") { op = "<<<"; P += 3 }
    else if (ch(P + 2) == "-") { op = "<<-"; P += 3 }
    else { op = "<<"; P += 2 }
  } else if (d == ">" || d == "&") { op = c d; P += 2 }
  else { op = "<"; P++ }
  while (ch(P) == " " || ch(P) == "\t") P++
  if (CUR == 0) new_cmd()
  read_word(); w = RW
  if (op == "<<" || op == "<<-") { NH++; HD[NH] = w; HDASH[NH] = (op == "<<-"); HC[NH] = CUR; HQ[NH] = RWQ; return }
  if (op == "<<<") { print "I\t" CUR "\t" enc(w); return }
  if (op == "<" || op == "<&") return
  if (op == ">&" && w ~ /^[0-9]*-?$/) return
  print "R\t" CUR "\t" (RWX ? "X" : "L") "\t" enc(w)
}
# read_heredocs: the bodies of the heredocs begun on the line just ended. One
# without its delimiter runs to the end, as in bash.
function read_heredocs(   k, st, d, t, body, found, n) {
  n = NH
  for (k = HB + 1; k <= n; k++) {
    st = P; found = 0
    while (P <= N) {
      d = next_at("\n")
      t = d ? substr(S, P, d - 1) : substr(S, P)
      if (HDASH[k]) sub(/^\t+/, "", t)
      if (t == HD[k]) { body = substr(S, st, P - st); P = d ? P + d : N + 1; found = 1; break }
      P = d ? P + d : N + 1
    }
    if (!found) body = substr(S, st)
    print "H\t" HC[k] "\t" HQ[k] "\t" enc(body)
    if (!HQ[k]) sub_parse(body, 1)
  }
  NH = HB
}
AWK

# Programs that write the files they're given, for xargs and find -exec.
writer_progs=" tee rm rmdir unlink shred truncate sponge mv cp ln install patch dd "

# judge_bash <command> <cwd>: best effort. The command is parsed, and only
# the files it can write are judged: its redirect targets and the files its
# writing programs are given.
judge_bash() {
  local cmd=$1 cwd=$2 root rcwd
  [[ -n $cmd ]] || exit 0
  root=$(repo_root "$cwd") || exit 0
  load_config "$root"
  rcwd=$(phys_dir "$cwd") || say "could not resolve $cwd, so this command was not checked for changes to check config."
  if ! command -v awk >/dev/null 2>&1; then
    ask_note="(awk is not on PATH, so the command was judged on all its words.)"
    judge_bash_words "$cmd" "$root" "$rcwd"
  fi

  # What the parse finds: targets by path relative to the root (names, and
  # trees for programs that write everything under a directory, "/" for the
  # root itself), the directories the command may run in, its literal words,
  # whether a target or a cd is an expansion, and whether it parsed.
  local -A tnames=() ttrees=() lang_pats=()
  local -a bases=("$rcwd") lits=() existing=()
  local unresolved="" bad_parse="" any_in_repo="" have_existing=""
  shell_scan "$cmd" 0
  if [[ -n $bad_parse ]]; then
    ask_note="(The command could not be parsed, so it was judged on all its words.)"
    judge_bash_words "$cmd" "$root" "$rcwd"
  fi
  # A target held in a variable or a command's output, or a cd to one: any
  # literal path in the command may be it.
  if [[ -n $unresolved ]]; then
    local w
    for w in "${lits[@]}"; do
      [[ $w != -* ]] || continue
      add_target "$w" L 1
    done
    unset 'ttrees[/]'
  fi

  local named="" m hits="" t
  local -a cands=()
  for t in "${!tnames[@]}" "${!ttrees[@]}"; do [[ $t == / ]] || cands+=("$t"); done
  if ((${#cands[@]} > 0)); then
    hits=$(protected_matches "$root" "${cands[@]}") || say "$git_failed"
    while IFS= read -r m; do
      [[ -n $m && ", $named, " != *", $m, "* ]] || continue
      named+="${named:+, }$m"
    done <<<"$hits"
  fi
  [[ -z ${ttrees[/]:-} ]] || named+="${named:+, }the whole repository"
  # A directory a tree-writer is given names the protected files under it,
  # tracked or not.
  local d f
  for d in "${!ttrees[@]}"; do
    [[ $d != / && -d $root/$d && ", $named, " != *", $d, "* ]] || continue
    # Directly in it, or as it, they count even when gitignored.
    holds_claude_settings "$root/$d" && { named+="${named:+, }$d"; continue; }
    list_existing "$root"
    for f in "${existing[@]}"; do
      [[ $f == "$d"/* ]] && { named+="${named:+, }$d"; break; }
    done
  done
  if [[ -n $named ]]; then
    ask "this command looks like it changes check config ($named). That can weaken what CI, the hooks or the weakened-checks detector check, so a human approves it."
  fi

  # A write to a Cargo.toml: from a command line there's no telling which
  # table it lands in. Then suppressions in the text of a command that writes
  # a source file (heredocs included: the text may reach the file through a
  # temporary one), and gitleaks:allow in one that writes in the repository.
  if on cargo-lint-levels; then
    for t in "${!tnames[@]}" "${!ttrees[@]}"; do
      if [[ $t == Cargo.toml || $t == */Cargo.toml ]]; then
        ask "this command looks like it changes a Cargo.toml. Its lints tables and [profile] set what clippy, rustc and the tests check, so a human approves it."
      fi
    done
  fi
  local l ere
  for t in "${!tnames[@]}" "${!ttrees[@]}" "${!lang_pats[@]}"; do
    l=$(lang "$t")
    [[ -n $l ]] || continue
    ere=$ere_any
    [[ -z ${ere_by[$l]:-} ]] || ere="${ere_by[$l]}|$ere"
    if grep -Eq -- "$ere" <<<"$cmd"; then
      ask "this command looks like it writes a lint or test suppression into $t. Silencing a lint or skipping a test can hide a real problem, so a human approves it."
    fi
    if [[ $l == rust ]] && on rust-allow && grep -Eq -- "$rust_strict_ere" <<<"$cmd"; then
      ask "this command looks like it writes to $t and says deny or forbid, so it may remove or loosen a lint attribute. A human approves it."
    fi
  done
  if [[ -n $any_in_repo ]] && grep -q -- 'gitleaks:allow' <<<"$cmd"; then
    ask "this command looks like it writes a gitleaks:allow comment, which hides a line from secret scanning, so a human approves it."
  fi
  done_quiet
}

# list_existing <root>: the protected files that exist, tracked or not, into
# existing (once).
list_existing() {
  [[ -z $have_existing ]] || return 0
  have_existing=1
  mapfile -t existing < <(git -C "$1" -c core.quotePath=false ls-files --cached --others --exclude-standard -- "${protected[@]}" 2>/dev/null)
  local m
  for m in "${mandatory[@]}"; do [[ ! -e $1/$m ]] || existing+=("$m"); done
  # Claude Code's settings and hooks, deeper down, unless gitignored.
  mapfile -t -O "${#existing[@]}" existing < <(git -C "$1" -c core.quotePath=false ls-files --cached --others --exclude-standard -- \
    ':(glob)**/.claude/settings.json' ':(glob)**/.claude/settings.local.json' ':(glob)**/.claude/hooks/**' 2>/dev/null)
}

# unesc <field>: a parser field with its escapes undone, and $PWD and $(pwd)
# replaced by the directory the command starts in, into u.
unesc() {
  local v=${1//\\\\/$'\x01'}
  v=${v//\\n/$'\n'}
  v=${v//\\t/$'\t'}
  v=${v//$'\x01'/\\}
  # shellcheck disable=SC2016 # the literal text is what's replaced.
  v=${v//'$(pwd)'/$rcwd} v=${v//'${PWD}'/$rcwd} v=${v//'$PWD'/$rcwd}
  u=$v
}

# add_target <word> <L|X|U> <tree: 0|1> [dir...]: a file the command may write,
# resolved against each directory it may run in (and the extra ones given).
add_target() {
  local w=$1 x=$2 tree=$3 b abs rel dest
  shift 3
  if [[ $x != L && ($w == *'$'* || $w == *'`'*) ]]; then unresolved=1; return 0; fi
  [[ -n $w && $w != *://* ]] || return 0
  for b in "${bases[@]}" "$@"; do
    abs=$(lexical_path "$w" "$b")
    if [[ $abs == "$root" ]]; then
      ((tree)) && { ttrees[/]=1; any_in_repo=1; }
      continue
    fi
    [[ $abs == "$root"/* ]] || continue
    rel=${abs#"$root"/}
    [[ $rel != .git && $rel != .git/* ]] || continue
    any_in_repo=1
    if ((tree)); then ttrees[$rel]=1; else tnames[$rel]=1; fi
    # A symlink writes to its destination.
    if [[ -L $abs ]] && dest=$(realpath -m -- "$abs" 2>/dev/null) && [[ $dest == "$root"/* ]]; then
      tnames[${dest#"$root"/}]=1
    fi
  done
}

# is_dir <word>: whether it names an existing directory from any base.
is_dir() {
  local b
  for b in "${bases[@]}"; do [[ -d $(lexical_path "$1" "$b") ]] && return 0; done
  return 1
}

# shell_scan <text> <depth>: parses <text> and adds what it writes to the
# targets. Shell code inside it (bash -c, eval, a heredoc fed to sh) is
# parsed again, three levels deep at most.
shell_scan() {
  local text=$1 depth=$2 recs
  if ((depth > 3)); then bad_parse=1; return 0; fi
  recs=$(printf '%s' "$text" | LC_ALL=C awk "$shell_awk" 2>/dev/null) || { bad_parse=1; return 0; }
  local -a order=()
  local -A words=() flags=() pipe_of=() docs=() strs=() reds=()
  local k a b c u
  while IFS=$'\t' read -r k a b c; do
    case $k in
      C) order+=("$a"); pipe_of[$a]=$b ;;
      W) unesc "$c"; words[$a]+=$u$'\x1f'; flags[$a]+=$b ;;
      R) unesc "$c"; reds[$a]+=$b$u$'\x1f' ;;
      H) unesc "$c"; docs[$a]+=$u$'\n' ;;
      I) unesc "$b"; strs[$a]+=$u$'\n' ;;
      E) bad_parse=1 ;;
    esac
  done <<<"$recs"
  local id rest w
  for id in "${order[@]}"; do
    judge_simple "$id"
    rest=${reds[$id]:-}
    while [[ -n $rest ]]; do
      w=${rest%%$'\x1f'*}; rest=${rest#*$'\x1f'}
      add_target "${w:1}" "${w:0:1}" 0
    done
  done
}

# judge_simple <id>: the targets of one simple command from shell_scan.
judge_simple() {
  local id=$1 rest=${words[$1]:-} fl=${flags[$1]:-} w i=0
  local -a ws=() fs=() pa=() pf=()
  while [[ -n $rest ]]; do
    w=${rest%%$'\x1f'*}; rest=${rest#*$'\x1f'}
    ws+=("$w")
    # U: an expansion still unresolved.
    if [[ ${fl:i:1} == X && ($w == *'$'* || $w == *'`'*) ]]; then fs+=(U); else
      fs+=(L)
      lits+=("$w")
      [[ $w != *=* ]] || lits+=("${w#*=}")
    fi
    i=$((i + 1))
  done
  local n=${#ws[@]} k=0 p xargs="" o
  # Assignments and keywords before the program.
  while ((k < n)); do
    w=${ws[k]}
    if [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ]]; then k=$((k + 1)); continue; fi
    case $w in
      if | then | else | elif | do | while | until | '!' | '{' | '}' | fi | done | 'esac') k=$((k + 1)); continue ;;
      for | select | case | in | function | '[[' | '[' | test) return 0 ;;
    esac
    break
  done
  # Wrappers, with their options, before the program they run.
  while ((k < n)); do
    p=${ws[k]##*/}
    case $p in
      sudo | doas) k=$((k + 1)); skip_opts ugCDhprtUTc ;;
      command | builtin)
        for o in "${ws[@]:k+1}"; do [[ $o != -v && $o != -V ]] || return 0; done
        k=$((k + 1)); skip_opts "" ;;
      nohup | setsid | chronic) k=$((k + 1)); skip_opts "" ;;
      exec) k=$((k + 1)); skip_opts a ;;
      time) k=$((k + 1)); skip_opts fo ;;
      nice) k=$((k + 1)); skip_opts n ;;
      stdbuf) k=$((k + 1)); skip_opts ioe ;;
      ionice) k=$((k + 1)); skip_opts cnp ;;
      timeout) k=$((k + 1)); skip_opts sk; k=$((k + 1)) ;;
      xargs) k=$((k + 1)); skip_opts InLPsdEa; xargs=1 ;;
      env)
        k=$((k + 1))
        while ((k < n)); do
          case ${ws[k]} in
            -S | --split-string) shell_scan "${ws[*]:k+1}" $((depth + 1)); return 0 ;;
            -S* | --split-string=*) o=${ws[k]#-S}; o=${o#--split-string=}; shell_scan "$o ${ws[*]:k+1}" $((depth + 1)); return 0 ;;
            -u | -C | --unset | --chdir) k=$((k + 2)) ;;
            -*) k=$((k + 1)) ;;
            *=*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done ;;
      flock)
        for ((o = k + 1; o < n; o++)); do
          if [[ ${ws[o]} == -c || ${ws[o]} == --command ]]; then shell_scan "${ws[o + 1]:-}" $((depth + 1)); return 0; fi
        done
        k=$((k + 1)); skip_opts wE; k=$((k + 1)) ;;
      *) break ;;
    esac
  done
  ((k < n)) || return 0
  p=${ws[k]##*/}
  local -a args=("${ws[@]:k+1}") afs=("${fs[@]:k+1}")
  if [[ -n $xargs && $writer_progs == *" $p "* ]]; then unresolved=1; fi
  case $p in
    bash | sh | zsh | dash | ksh) shell_input ;;
    eval) shell_scan "${args[*]}" $((depth + 1)) ;;
    cd | pushd) cd_to ;;
    sed | gsed | perl) in_place ;;
    tee | sponge | unlink | shred) plain_args ""; add_all 0 ;;
    truncate) plain_args sr; add_all 0 ;;
    rm | rmdir) plain_args ""; add_all 1 ;;
    mv | cp | ln | install) to_dest ;;
    dd) for ((i = 0; i < ${#args[@]}; i++)); do [[ ${args[i]} != of=* ]] || add_target "${args[i]#of=}" "${afs[i]}" 0; done ;;
    patch) unresolved=1; diff_paths ;;
    git) git_cmd ;;
    find) find_cmd ;;
  esac
  return 0
}

# skip_opts <letters>: k past the options at k; a short option in <letters>
# takes an argument (the rest of its word, or the next word).
skip_opts() {
  local o j
  while ((k < n)); do
    o=${ws[k]}
    [[ $o == -?* ]] || return 0
    k=$((k + 1))
    [[ $o != -- ]] || return 0
    [[ $o != --* ]] || continue
    for ((j = 1; j < ${#o}; j++)); do
      if [[ -n $1 && $1 == *"${o:j:1}"* ]]; then ((j + 1 < ${#o})) || k=$((k + 1)); break; fi
    done
  done
}

# plain_args <letters>: the arguments that aren't options into pa (and their
# flags into pf); a short option in <letters> takes an argument.
plain_args() {
  local i o j rest=""
  pa=() pf=()
  for ((i = 0; i < ${#args[@]}; i++)); do
    o=${args[i]}
    if [[ -n $rest || $o != -?* ]]; then
      [[ $o == - ]] || { pa+=("$o"); pf+=("${afs[i]}"); }
      continue
    fi
    [[ $o != -- ]] || { rest=1; continue; }
    [[ $o != --* ]] || continue
    for ((j = 1; j < ${#o}; j++)); do
      if [[ -n $1 && $1 == *"${o:j:1}"* ]]; then ((j + 1 < ${#o})) || i=$((i + 1)); break; fi
    done
  done
}

# add_all <tree>: every argument from plain_args is a target.
add_all() {
  local i
  for ((i = 0; i < ${#pa[@]}; i++)); do add_target "${pa[i]}" "${pf[i]}" "$1"; done
}

# shell_input: bash/sh -c STRING is parsed; without -c, the shell reads its
# heredocs, here-strings and what the commands before it in its pipeline
# print (their arguments, as given), which are parsed as commands.
shell_input() {
  local i o stdin=1 c=""
  for ((i = 0; i < ${#args[@]}; i++)); do
    o=${args[i]}
    if [[ -n $c ]]; then shell_scan "$o" $((depth + 1)); return 0; fi
    case $o in
      --) continue ;;
      -o | +o) i=$((i + 1)) ;;
      --*) ;;
      [-+]*c*) c=1 ;;
      [-+]*s*) stdin=1; break ;;
      [-+]*) ;;
      *) stdin=""; break ;;
    esac
  done
  [[ -n $stdin ]] || return 0
  local text="${docs[$id]:-}${strs[$id]:-}" j r v
  for j in "${order[@]}"; do
    [[ $j != "$id" && ${pipe_of[$j]} == "${pipe_of[$id]}" ]] || continue
    ((j < id)) || continue
    text+="${docs[$j]:-}${strs[$j]:-}"
    local -a pw=()
    r=${words[$j]:-}
    while [[ -n $r ]]; do v=${r%%$'\x1f'*}; r=${r#*$'\x1f'}; pw+=("$v"); done
    # As one line (echo cmd args) and as lines (printf '%s\n' cmd).
    text+=$'\n'"${pw[*]:1}"$'\n'
    for v in "${pw[@]:1}"; do text+="$v"$'\n'; done
  done
  [[ -z ${text//[[:space:]]/} ]] || shell_scan "$text" $((depth + 1))
}

# cd_to: the directory a cd or pushd moves to is a base for what follows;
# one held in a variable is unknown.
cd_to() {
  local i nb b
  for ((i = 0; i < ${#args[@]}; i++)); do
    [[ ${args[i]} != -* ]] || continue
    if [[ ${afs[i]} == U ]]; then unresolved=1; return 0; fi
    local -a more=()
    for b in "${bases[@]}"; do
      nb=$(lexical_path "${args[i]}" "$b")
      [[ " ${bases[*]} ${more[*]} " == *" $nb "* ]] || more+=("$nb")
    done
    bases+=("${more[@]}")
    return 0
  done
}

# in_place: sed, gsed or perl, which write only with -i (or --in-place); then
# each file argument is a target. -i takes the rest of its word as a backup
# suffix; an option that takes an argument ends the word. Without -e or -f,
# the first argument is the script.
in_place() {
  local i o j c ip="" script="" rest=""
  local -a files=() ffl=()
  for ((i = 0; i < ${#args[@]}; i++)); do
    o=${args[i]}
    if [[ -n $rest || $o != -?* ]]; then files+=("$o"); ffl+=("${afs[i]}"); continue; fi
    case $o in
      --) rest=1; continue ;;
      --in-place*) ip=1; continue ;;
      --expression=* | --file=*) script=1; continue ;;
      --expression | --file) script=1; i=$((i + 1)); continue ;;
      --*) continue ;;
    esac
    for ((j = 1; j < ${#o}; j++)); do
      c=${o:j:1}
      case $p:$c in
        *:i) ip=1; break ;;
        sed:[ef] | gsed:[ef] | perl:[eE]) script=1; ((j + 1 < ${#o})) || i=$((i + 1)); break ;;
        sed:l | gsed:l) ((j + 1 < ${#o})) || i=$((i + 1)); break ;;
        perl:[MmIxdDC]) break ;;
      esac
    done
  done
  [[ -n $ip ]] || return 0
  [[ -n $script ]] || { files=("${files[@]:1}"); ffl=("${ffl[@]:1}"); }
  for ((i = 0; i < ${#files[@]}; i++)); do add_target "${files[i]}" "${ffl[i]}" 0; done
}

# to_dest: mv, cp, ln and install write their destination: the last argument
# or -t DIR; into a directory, as DIR/<source name>. mv also removes its
# sources, and install -d makes every argument. ln with one argument links in
# the working directory.
to_dest() {
  local i o j tdir="" tflag=L nodir="" dmode="" rest="" dest dflag into="" s
  local -a pos=() posf=()
  for ((i = 0; i < ${#args[@]}; i++)); do
    o=${args[i]}
    if [[ -n $rest || $o != -?* ]]; then pos+=("$o"); posf+=("${afs[i]}"); continue; fi
    case $o in
      --) rest=1; continue ;;
      --target-directory=*) tdir=${o#*=}; tflag=${afs[i]}; continue ;;
      --target-directory) tdir=${args[i + 1]:-}; tflag=${afs[i + 1]:-L}; i=$((i + 1)); continue ;;
      --no-target-directory) nodir=1; continue ;;
      --directory) dmode=1; continue ;;
      --*) continue ;;
    esac
    for ((j = 1; j < ${#o}; j++)); do
      case ${o:j:1} in
        t)
          if ((j + 1 < ${#o})); then tdir=${o:j+1}; tflag=${afs[i]}; else tdir=${args[i + 1]:-}; tflag=${afs[i + 1]:-L}; i=$((i + 1)); fi
          break ;;
        T) nodir=1 ;;
        d) [[ $p != install ]] || dmode=1 ;;
        S | m | o | g) ((j + 1 < ${#o})) || i=$((i + 1)); break ;;
      esac
    done
  done
  if [[ -n $dmode ]]; then
    for ((i = 0; i < ${#pos[@]}; i++)); do add_target "${pos[i]}" "${posf[i]}" 0; done
    return 0
  fi
  if [[ -n $tdir ]]; then
    dest=$tdir dflag=$tflag into=1
  elif ((${#pos[@]} >= 2)); then
    dest=${pos[-1]} dflag=${posf[-1]}
    unset 'pos[-1]' 'posf[-1]'
    [[ -z $nodir ]] && { [[ $dest == */ ]] || is_dir "$dest"; } && into=1
  elif ((${#pos[@]} == 1)) && [[ $p == ln ]]; then
    s=${pos[0]%/}
    add_target "${s##*/}" "${posf[0]}" 0
    return 0
  else
    return 0
  fi
  for ((i = 0; i < ${#pos[@]}; i++)); do
    [[ $p != mv ]] || add_target "${pos[i]}" "${posf[i]}" 1
    if [[ -n $into ]]; then
      s=${pos[i]%/}
      [[ ${posf[i]} == L ]] || dflag=U
      add_target "${dest%/}/${s##*/}" "$dflag" 0
    fi
  done
  add_target "$dest" "$dflag" 0
}

# diff_paths: the files a heredoc diff fed to patch or git apply names, with
# their a/ and b/ prefixes and without.
diff_paths() {
  local line f
  while IFS= read -r line; do
    case $line in
      '+++ '* | '--- '*) f=${line:4}; f=${f%%$'\t'*} ;;
      *) continue ;;
    esac
    [[ $f != /dev/null ]] || continue
    add_target "$f" L 0
    [[ $f != [ab]/* ]] || add_target "${f:2}" L 0
  done <<<"${docs[$id]:-}"
}

# git_cmd: git checkout, restore, rm and mv write the paths they're given
# (every file under a directory); apply writes the files its patch names.
# -C and --work-tree are bases for the paths.
git_cmd() {
  local i=0 o sub b nb
  local -a extra=()
  while ((i < ${#args[@]})); do
    o=${args[i]}
    case $o in
      -C | --work-tree)
        for b in "${bases[@]}"; do nb=$(lexical_path "${args[i + 1]:-.}" "$b"); extra+=("$nb"); done
        i=$((i + 2)) ;;
      --work-tree=*)
        for b in "${bases[@]}"; do nb=$(lexical_path "${o#*=}" "$b"); extra+=("$nb"); done
        i=$((i + 1)) ;;
      -c | --git-dir | --namespace | --exec-path | --super-prefix | --config-env) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  sub=${args[i]:-}
  case $sub in
    checkout | restore | rm | mv) ;;
    apply) unresolved=1; diff_paths; return 0 ;;
    *) return 0 ;;
  esac
  local -a saved=("${bases[@]}")
  ((${#extra[@]} == 0)) || bases=("${extra[@]}")
  args=("${args[@]:i+1}") afs=("${afs[@]:i+1}")
  plain_args bBsU
  add_all 1
  bases=("${saved[@]}")
}

# find_cmd: find with -delete, or -exec running a writer, writes what it
# finds under its start paths: the protected files there that its -name and
# -path filters can match (every one, without a filter). A filter is also a
# file name for the suppression rules.
find_cmd() {
  local i=0 o writes="" e pat
  local -a starts=() names=() paths=()
  while ((i < ${#args[@]})) && [[ ${args[i]} == -[HLP] || ${args[i]} == -O* ]]; do i=$((i + 1)); done
  while ((i < ${#args[@]})) && [[ ${args[i]} != -* && ${args[i]} != '(' && ${args[i]} != '!' ]]; do
    [[ ${afs[i]} == L ]] || unresolved=1
    starts+=("${args[i]}"); i=$((i + 1))
  done
  for (( ; i < ${#args[@]}; i++)); do
    o=${args[i]}
    case $o in
      -name | -iname) names+=("${args[i + 1]:-}"); i=$((i + 1)) ;;
      -path | -ipath | -wholename | -iwholename) paths+=("${args[i + 1]:-}"); i=$((i + 1)) ;;
      -delete) writes=1 ;;
      -exec | -execdir | -ok | -okdir)
        e=${args[i + 1]:-}; e=${e##*/}
        if [[ $writer_progs == *" $e "* ]]; then writes=1
        elif [[ $e == sed || $e == gsed || $e == perl ]]; then
          for ((i = i + 2; i < ${#args[@]}; i++)); do
            [[ ${args[i]} != ';' && ${args[i]} != + ]] || break
            [[ ${args[i]} =~ ^-[^-eEf]*i|^--in-place ]] && writes=1
          done
        fi ;;
    esac
  done
  [[ -n $writes ]] || return 0
  ((${#starts[@]} > 0)) || starts=(.)
  if ((${#names[@]} + ${#paths[@]} == 0)); then
    for o in "${starts[@]}"; do add_target "$o" L 1; done
    return 0
  fi
  for pat in "${names[@]}" "${paths[@]}"; do lang_pats[$pat]=1; done
  list_existing "$root"
  local s srel f b
  for o in "${starts[@]}"; do
    for b in "${bases[@]}"; do
      s=$(lexical_path "$o" "$b")
      [[ $s == "$root" || $s == "$root"/* ]] || continue
      srel=${s#"$root"}; srel=${srel#/}
      for f in "${existing[@]}"; do
        [[ -z $srel || $f == "$srel"/* ]] || continue
        for pat in "${names[@]}"; do
          # shellcheck disable=SC2053 # the pattern is meant to match.
          [[ ${f##*/} == $pat ]] && tnames[$f]=1 any_in_repo=1
        done
        for pat in "${paths[@]}"; do
          # shellcheck disable=SC2053 # the pattern is meant to match.
          [[ $f == $pat || ./$f == $pat || $o/${f#"$srel"/} == $pat ]] && tnames[$f]=1 any_in_repo=1
        done
      done
    done
  done
}

# Any unexpected failure inside main is reported, never a block.
out=$(main)
status=$?
if ((status != 0)); then
  say "the hook failed (exit $status), so this change was not checked for weakened checks."
fi
printf '%s' "${out:+$out$'\n'}"
exit 0
