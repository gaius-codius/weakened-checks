# shellcheck shell=bash
# shellcheck disable=SC2034 # the lists and settings are for the callers.
# The rule ids, the built-in lists and the config parser, shared by
# check-weakened.sh, and any other script that sources it, so they read a
# config the same way. Sourced, not run. Needs bash 4.3 (namerefs).
#
# The caller defines wc_config_error MESSAGE, which reports a config or
# exceptions error. The detector's exits; another caller may record it
# instead, and the parse functions then return 1.

# Rules, and the built-in lists the config can replace.
rules=(check-config cargo-lint-levels cargo-workspace-lints check-bound tests-removed snapshot
  rust-allow rust-ignore rust-rustfmt-skip rust-no-mangle rust-unsafe
  go-nolint go-test-skip
  ts-nocheck ts-ignore ts-expect-error ts-as-unknown eslint-disable biome-ignore js-test-skip
  svelte-ignore py-test-skip nosemgrep)
default_config_paths=(
  .github/workflows .github/actions .github/CODEOWNERS CODEOWNERS
  lefthook.yml lefthook.yaml .lefthook.yml .pre-commit-config.yaml .husky
  'scripts/check-*'
  rust-toolchain rust-toolchain.toml deny.toml .config/nextest.toml .cargo/mutants.toml
  ':(glob)**/.cargo/config' ':(glob)**/.cargo/config.toml'
  ':(glob)**/clippy.toml' ':(glob)**/.clippy.toml' ':(glob)**/rustfmt.toml' ':(glob)**/.rustfmt.toml'
  ':(glob)**/typos.toml' ':(glob)**/_typos.toml' ':(glob)**/.typos.toml'
  ':(glob)**/.golangci.yml' ':(glob)**/.golangci.yaml' ':(glob)**/.golangci.toml' ':(glob)**/.golangci.json'
  ':(glob)**/tsconfig*.json' ':(glob)**/biome.json' ':(glob)**/biome.jsonc'
  ':(glob)**/eslint.config.*' ':(glob)**/.eslintrc*' ':(glob)**/.eslintignore'
  ':(glob)**/vitest.config.*' ':(glob)**/vitest.workspace.*' ':(glob)**/jest.config.*'
  ':(glob)**/playwright.config.*' ':(glob)**/stryker.conf*' ':(glob)**/stryker.config.*'
  ':(glob)**/.semgrep/**' .semgrep.yml .semgrepignore .gitleaks.toml .gitleaksignore
  codecov.yml .codecov.yml
)
default_snapshot_paths=('*.snap' '*.golden' ':(glob)**/__snapshots__/**')
# Shell patterns (where * also matches /) for test files.
default_test_paths=('*.test.*' '*.spec.*' '*__tests__/*' 'tests/*' '*/tests/*' 'test/*' '*/test/*'
  '*_test.go' '*_test.py' 'test_*.py' '*/test_*.py' 'testdata/*' '*/testdata/*' 'e2e/*' '*/e2e/*')

# wc_reset: the settings a repository without a config gets.
wc_reset() {
  config_paths=() snapshot_paths=() test_paths=()
  config_paths_set="" snapshot_paths_set="" test_paths_set=""
  disabled=" " prohibits=() cargo_members=':(glob)crates/*/Cargo.toml' bound_tag=check-bound
  exceptions_path=.github/weakened-checks-exceptions
  exceptions=()
}
known_rule() {
  local r
  for r in "${rules[@]}"; do [[ $r == "$1" ]] && return 0; done
  return 1
}
# A list directive's first use replaces the built-in list; "@defaults" brings
# the built-in entries back.
add_list() { # list name, set flag name, defaults name, values...
  local -n list=$1 isset=$2 defaults=$3
  shift 3
  if [[ -z $isset ]]; then list=(); isset=1; fi
  local v
  for v in "$@"; do
    if [[ $v == @defaults ]]; then list+=("${defaults[@]}"); else list+=("$v"); fi
  done
}

# wc_parse_config TEXT NAME: sets the lists and settings from a config's
# text (NAME is its path, for messages), after wc_reset.
wc_parse_config() {
  local text=$1 name=$2 lineno=0 line key where r p
  local -a words values
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    line=$(sed -E 's/[[:space:]]+#.*$//' <<<"$line")
    read -r -a words <<<"$line"
    key=${words[0]} values=("${words[@]:1}")
    where="$name:$lineno"
    case $key in
      config-path) add_list config_paths config_paths_set default_config_paths "${values[@]}" ;;
      snapshot-path) add_list snapshot_paths snapshot_paths_set default_snapshot_paths "${values[@]}" ;;
      test-path) add_list test_paths test_paths_set default_test_paths "${values[@]}" ;;
      cargo-members)
        [[ ${#values[@]} -eq 1 ]] || { wc_config_error "$where: cargo-members takes one pathspec, or none"; return 1; }
        cargo_members=${values[0]} ;;
      bound-tag)
        [[ ${#values[@]} -eq 1 && ${values[0]} =~ ^[A-Za-z0-9_-]+$ ]] ||
          { wc_config_error "$where: bound-tag takes one word of letters, digits, - and _"; return 1; }
        bound_tag=${values[0]} ;;
      exceptions)
        [[ ${#values[@]} -eq 1 ]] || { wc_config_error "$where: exceptions takes one path"; return 1; }
        exceptions_path=${values[0]} ;;
      disable)
        for r in "${values[@]}"; do known_rule "$r" || { wc_config_error "$where: no rule $r"; return 1; }; done
        disabled+="${values[*]} " ;;
      prohibit)
        [[ ${#values[@]} -ge 2 ]] || { wc_config_error "$where: prohibit takes a rule and at least one path pattern"; return 1; }
        known_rule "${values[0]}" || { wc_config_error "$where: no rule ${values[0]}"; return 1; }
        for p in "${values[@]:1}"; do prohibits+=("${values[0]}"$'\t'"$p"); done ;;
      *) wc_config_error "$where: unknown directive $key"; return 1 ;;
    esac
  done <<<"$text"
  [[ -n $config_paths_set ]] || config_paths=("${default_config_paths[@]}")
  [[ -n $snapshot_paths_set ]] || snapshot_paths=("${default_snapshot_paths[@]}")
  [[ -n $test_paths_set ]] || test_paths=("${default_test_paths[@]}")
  return 0
}

# wc_parse_exceptions TEXT: the exceptions file's entries, one
# "RULE PATTERN REASON..." per line, into exceptions.
wc_parse_exceptions() {
  local text=$1 lineno=0 line rule pattern reason
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    reason=""
    read -r rule pattern reason <<<"$line"
    known_rule "$rule" || { wc_config_error "$exceptions_path:$lineno: no rule $rule"; return 1; }
    [[ -n ${reason:-} ]] || { wc_config_error "$exceptions_path:$lineno: an exception needs a reason after its path"; return 1; }
    exceptions+=("$rule"$'\t'"$pattern"$'\t'"$reason")
  done <<<"$text"
  return 0
}

on() { [[ $disabled != *" $1 "* ]]; }
# wc_match TEXT PATTERN: whether TEXT matches a shell pattern from the config
# or the exceptions file. A bracket expression matches either one character
# of its class, as in bash, or its own text, so a route segment such as
# routes/[id]/x.ts matches that path.
wc_match() {
  local literal=${2//\[/\\[}
  literal=${literal//\]/\\]}
  # shellcheck disable=SC2053 # the pattern is meant to match.
  [[ $1 == $2 || $1 == $literal ]]
}
is_test_path() {
  local p
  for p in "${test_paths[@]}"; do
    wc_match "$1" "$p" && return 0
  done
  return 1
}
excepted() { # rule, path; prints the reason
  local e rule pattern reason
  for e in "${exceptions[@]}"; do
    IFS=$'\t' read -r rule pattern reason <<<"$e"
    if [[ $rule == "$1" ]] && wc_match "$2" "$pattern"; then
      echo "$reason"
      return 0
    fi
  done
  return 1
}
