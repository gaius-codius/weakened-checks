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
#   - Bash, best effort: a command that names a protected path (or a
#     directory holding one) and writes with sed -i, perl -i, tee, mv, cp,
#     rm, truncate, ln, install, patch, dd or git checkout/restore/rm/mv/apply,
#     or redirects into one (paths resolved against cwd, so a cd earlier in
#     the command isn't followed); any write to a Cargo.toml; a source file
#     with a suppression, or a .rs file with deny or forbid; gitleaks:allow.
#     A write through any other program is not seen.
#
# Outcomes:
#   exit 0 with JSON permissionDecision "ask": a protected change. Claude
#     Code asks the user, showing the reason.
#   exit 0, nothing: anything else, outside a git repository, or
#     WEAKENED_CHECKS_PROTECT_CONFIG=off.
#   exit 0 with JSON additionalContext: an advisory note, or the check could
#     not run (jq or git missing or failing, input jq can't read, lib/ missing, bash
#     older than 4.4). Never blocks, never silent.
set -uo pipefail

opt_out="Set WEAKENED_CHECKS_PROTECT_CONFIG=off to turn this hook off."
cfg_file=.github/weakened-checks.conf
cfg_note=""

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

# judge_bash <command> <cwd>: best effort.
judge_bash() {
  local cmd=$1 cwd=$2 root
  [[ -n $cmd ]] || exit 0
  root=$(repo_root "$cwd") || exit 0
  load_config "$root"
  local rcwd
  rcwd=$(phys_dir "$cwd") || say "could not resolve $cwd, so this command was not checked for changes to check config."
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

# Any unexpected failure inside main is reported, never a block.
out=$(main)
status=$?
if ((status != 0)); then
  say "the hook failed (exit $status), so this change was not checked for weakened checks."
fi
printf '%s' "${out:+$out$'\n'}"
exit 0
