#!/usr/bin/env bash
# Tests agent/claude-protect-config.sh with fake PreToolUse hook-input JSON and
# throwaway git repos. Needs bash, git and jq.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${src_root}/agent/claude-protect-config.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# A PATH with the tools the hook uses but no jq (or no git), for the
# missing-tool cases (jq often shares /usr/bin with bash, so dropping its
# directory isn't enough). Unlike the Rust-only hook's list (bash env git
# realpath dirname basename sed head grep cat), this hook also needs mktemp, rm
# and tr, for its throwaway index and the config-path list of a config that
# doesn't parse.
mkdir -p "${work}/nojq" "${work}/nogit"
for t in bash env git realpath dirname basename sed head grep cat mktemp rm tr; do
  ln -s "$(command -v "${t}")" "${work}/nojq/${t}"
done
for t in bash env jq realpath dirname basename sed head grep cat mktemp rm tr; do
  ln -s "$(command -v "${t}")" "${work}/nogit/${t}"
done
nojq="${work}/nojq"
nogit="${work}/nogit"

# The hook's shell parser is POSIX awk (CI's is mawk). Where awk is gawk, it
# runs in POSIX mode here, so a gawk-only construct fails here first.
if awk --version 2>/dev/null | grep -q 'GNU Awk'; then
  mkdir -p "${work}/posixawk"
  printf '#!/bin/sh\nexec %s --posix "$@"\n' "$(command -v gawk)" >"${work}/posixawk/awk"
  chmod +x "${work}/posixawk/awk"
  PATH="${work}/posixawk:${PATH}"
fi

failures=0
total=0
unset WEAKENED_CHECKS_PROTECT_CONFIG
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# new_repo: a git repo at ${r}, committed on main, with a Cargo workspace, a lints
# table, a crate and some config files.
new_repo() {
  r="${work}/repo"
  rm -rf "${r}" && mkdir -p "${r}/crates/lib/src" "${r}/.github/workflows"
  git -C "${r}" init -q -b main
  git -C "${r}" config user.name tester
  git -C "${r}" config user.email tester@example.com
  git -C "${r}" config commit.gpgsign false
  printf '[workspace]\nmembers = ["crates/*"]\n\n[workspace.dependencies]\nserde = "1"\n\n[workspace.lints.clippy]\nunwrap_used = "deny"\n' >"${r}/Cargo.toml"
  printf '[package]\nname = "lib"\nedition = "2024"\n\n[dependencies]\nserde.workspace = true\n\n[lints]\nworkspace = true\n' >"${r}/crates/lib/Cargo.toml"
  printf '#[allow(dead_code)]\nfn old() {}\n\npub fn a() {}\n' >"${r}/crates/lib/src/lib.rs"
  printf '[bans]\n' >"${r}/deny.toml"
  printf 'name: ci\n' >"${r}/.github/workflows/ci.yml"
  commit_all "init"
}

# commit_all <message>: commit everything in ${r} on main.
commit_all() {
  git -C "${r}" add -A && git -C "${r}" commit -q -m "$1"
}

# commit_conf <config text> [exceptions text]: commit the detector's config (and
# exceptions file) on main of ${r}.
commit_conf() {
  printf '%s\n' "$1" >"${r}/.github/weakened-checks.conf"
  [[ $# -lt 2 ]] || printf '%s\n' "$2" >"${r}/.github/weakened-checks-exceptions"
  commit_all "config"
}

# run_json <name> <hook input JSON> <want: ask | silent | context> [want substring]
run_json() {
  local name="$1" json="$2" want="$3" sub="${4:-}" out code ok=1
  total=$((total + 1))
  out="$(printf '%s' "${json}" | (cd "${r}" && PATH="${HOOK_PATH:-${PATH}}" "${HOOK_BIN:-${hook}}") 2>&1)"
  code=$?
  [[ ${code} -eq 0 ]] || ok=0
  case "${want}" in
    ask) [[ "${out}" =~ \"permissionDecision\":\ ?\"ask\" && "${out}" =~ \"hookEventName\":\ ?\"PreToolUse\" ]] || ok=0 ;;
    silent) [[ -z "${out}" ]] || ok=0 ;;
    context) [[ "${out}" == *'"additionalContext"'* && "${out}" != *permissionDecision* ]] || ok=0 ;;
  esac
  [[ -z "${sub}" || "${out}" == *"${sub}"* ]] || ok=0
  if ((ok)); then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}: exit ${code}, want ${want}; output:"
    printf '%s\n' "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  fi
}

# edit <name> <file, relative to the repo> <old> <new> <want> [substring]
edit() {
  run_json "$1" "$(jq -n --arg f "${r}/$2" --arg o "$3" --arg n "$4" --arg c "${r}" \
    '{hook_event_name: "PreToolUse", cwd: $c, tool_name: "Edit", tool_input: {file_path: $f, old_string: $o, new_string: $n}}')" "$5" "${6:-}"
}

# write <name> <file, relative to the repo> <content> <want> [substring]
write() {
  run_json "$1" "$(jq -n --arg f "${r}/$2" --arg n "$3" --arg c "${r}" \
    '{hook_event_name: "PreToolUse", cwd: $c, tool_name: "Write", tool_input: {file_path: $f, content: $n}}')" "$4" "${5:-}"
}

# bash_cmd <name> <command> <want> [substring]
bash_cmd() {
  run_json "$1" "$(jq -n --arg cmd "$2" --arg c "${r}" \
    '{hook_event_name: "PreToolUse", cwd: $c, tool_name: "Bash", tool_input: {command: $cmd}}')" "$3" "${4:-}"
}

# multi <name> <file, relative to the repo> <edits JSON array> <want> [substring]
multi() {
  run_json "$1" "$(jq -n --arg f "${r}/$2" --argjson e "$3" --arg c "${r}" \
    '{hook_event_name: "PreToolUse", cwd: $c, tool_name: "MultiEdit", tool_input: {file_path: $f, edits: $e}}')" "$4" "${5:-}"
}

new_repo

# ---------------------------------------------------------------------------
# Ported from the Rust-only hook's suite. Declared, intended differences:
#   a. That hook ignores a repository without a root Cargo.toml. This one
#      protects every git repository, with the detector's built-in list, so
#      the "not ours" cases at the end now ask (and are renamed to say so).
#   b. The no-jq PATH also needs mktemp, rm and tr (see the top of the file).
#   c. Any Bash write to a Cargo.toml asks, as in rust-ci v3's hook, so
#      "sed -i on Cargo.toml dependencies" now asks.
#   d. Bash commands are parsed, and only what they write is judged (#8), so
#      cp from a protected file no longer asks.
# The reason texts differ too: "<path> is check config", "adds or widens a lint
# or test suppression", and so on.
# ---------------------------------------------------------------------------

# Every protected path asks, for Edit and Write, existing or new.
for p in deny.toml clippy.toml .clippy.toml crates/lib/clippy.toml rustfmt.toml .rustfmt.toml \
  rust-toolchain.toml rust-toolchain .config/nextest.toml typos.toml _typos.toml .typos.toml \
  .github/workflows/ci.yml .github/workflows/new.yml .github/actions/pre-test/action.yml \
  .github/actions/a/b/c.sh lefthook.yml .gitleaks.toml .github/CODEOWNERS CODEOWNERS; do
  write "Write to ${p} asks" "${p}" 'x = 1' ask "${p} is check config"
done
for p in docs/CODEOWNERS .lefthook.yaml; do
  write "Write to ${p} asks (the hook's own list)" "${p}" 'x = 1' ask "${p} is check config"
done
edit "Edit to deny.toml asks" deny.toml '[bans]' '[bans]
multiple-versions = "allow"' ask "deny.toml is check config"
edit "the reason names the opt-out" deny.toml '[bans]' '' ask "WEAKENED_CHECKS_PROTECT_CONFIG=off"
ln -s deny.toml "${r}/deny-link.toml"
mkdir -p "${r}/baseline" && printf 'x\n' >"${r}/baseline/clippy.toml.src"
ln -s baseline/clippy.toml.src "${r}/clippy.toml"
edit "a symlinked config file is judged by its own name" clippy.toml 'x' 'y' ask "clippy.toml is check config"
edit "a relative file path is resolved against cwd" "crates/../deny.toml" '[bans]' '' ask "deny.toml is check config"
rm -f "${r}/clippy.toml" "${r}/deny-link.toml"

# Cargo.toml: only the lints tables.
edit "Cargo.toml edit outside lints does not ask" Cargo.toml 'serde = "1"' 'serde = "1.0.200"' silent
edit "Cargo.toml edit inside [workspace.lints.clippy] asks" Cargo.toml 'unwrap_used = "deny"' 'unwrap_used = "allow"' ask "[workspace.lints]"
edit "a member's [lints] removal asks" crates/lib/Cargo.toml '[lints]
workspace = true
' '' ask "crates/lib/Cargo.toml"
edit "adding a lints key asks" crates/lib/Cargo.toml 'serde.workspace = true' 'serde.workspace = true
[lints.rust]
unsafe_code = "allow"' ask
edit "an old text not in the file asks (unsure)" Cargo.toml 'not = "there"' 'x' ask "can't tell"
edit "a member's dependency edit does not ask" crates/lib/Cargo.toml 'serde.workspace = true' 'serde = "1"' silent
write "Write of Cargo.toml with the same lints does not ask" Cargo.toml "$(cat "${r}/Cargo.toml")
[workspace.package]
edition = \"2024\"" silent
write "Write of Cargo.toml that drops the lints asks" Cargo.toml '[workspace]
members = ["crates/*"]
' ask "[workspace.lints]"
write "Write of a member Cargo.toml without [lints] asks" crates/lib/Cargo.toml '[package]
name = "lib"
' ask
multi "MultiEdit with one edit in the lints table asks" Cargo.toml \
  '[{"old_string": "serde = \"1\"", "new_string": "serde = \"2\""}, {"old_string": "unwrap_used = \"deny\"", "new_string": "unwrap_used = \"warn\""}]' ask
multi "MultiEdit outside the lints table does not ask" Cargo.toml \
  '[{"old_string": "serde = \"1\"", "new_string": "serde = \"2\""}]' silent

# .rs files: adding a suppression asks, removing one or a normal edit doesn't.
edit "an edit adding #[allow( asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[allow(clippy::unwrap_used)]
pub fn a() {}' ask "adds or widens a lint or test suppression"
edit "an edit adding #![allow( asks" crates/lib/src/lib.rs 'pub fn a() {}' '#![allow(warnings)]
pub fn a() {}' ask "#![allow("
edit "an edit adding #[expect( asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[expect(dead_code)] pub fn a() {}' ask
edit "an edit adding a cfg_attr allow asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[cfg_attr(test, allow(dead_code))] pub fn a() {}' ask
edit "an edit adding #[ignore] asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[test]
#[ignore = "flaky"]
fn t() {}' ask "#[ignore"
edit "an edit adding #[cfg(any())] asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[cfg(any())]
pub fn a() {}' ask
edit "an edit adding #[cfg(not(all()))] asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[cfg(not(all()))] pub fn a() {}' ask
edit "an edit removing #[allow( does not ask" crates/lib/src/lib.rs '#[allow(dead_code)]
fn old() {}' 'fn old() {}' silent
edit "an edit keeping an existing #[allow( does not ask" crates/lib/src/lib.rs '#[allow(dead_code)]
fn old() {}' '#[allow(dead_code)]
fn older() {}' silent
edit "a normal .rs edit does not ask" crates/lib/src/lib.rs 'pub fn a() {}' 'pub fn a() -> u8 { 1 }' silent
write "a Write keeping the same suppressions does not ask" crates/lib/src/lib.rs '#[allow(dead_code)]
fn old() {}
pub fn b() {}' silent
write "a Write adding a suppression asks" crates/lib/src/lib.rs '#[allow(dead_code)]
fn old() {}
#[allow(unused)]
pub fn b() {}' ask
write "a new .rs file with #[ignore] asks" crates/lib/src/new.rs '#[test] #[ignore] fn t() {}' ask
multi "a MultiEdit adding a suppression asks" crates/lib/src/lib.rs \
  '[{"old_string": "pub fn a() {}", "new_string": "#[allow(unused)] pub fn a() {}"}]' ask

# Other files and tools.
write "a Markdown file does not ask" NOTES.md '# notes' silent
write "a file under .github outside workflows and actions does not ask" .github/dependabot.yml 'version: 2' silent
run_json "NotebookEdit is not judged" "$(jq -n --arg f "${r}/n.ipynb" '{tool_name: "NotebookEdit", tool_input: {notebook_path: $f, new_source: "x"}}')" silent

# Bash, best effort.
bash_cmd "sed -i on deny.toml asks" "sed -i 's/deny/allow/' deny.toml" ask "this command looks like it changes"
bash_cmd "a redirect into rustfmt.toml asks" "printf 'x\\n' > rustfmt.toml" ask
bash_cmd "tee into a workflow asks" "echo x | tee .github/workflows/ci.yml" ask
bash_cmd "rm of a workflow directory asks" "rm -rf .github/workflows" ask
bash_cmd "git checkout of clippy.toml asks" "git checkout main -- clippy.toml" ask
bash_cmd "sed -i on Cargo.toml lints asks" "sed -i '/\\[workspace.lints/,\$d' Cargo.toml" ask "lints tables"
bash_cmd "appending #[allow( to a .rs file asks" "printf '#[allow(dead_code)]\\n' >> crates/lib/src/lib.rs" ask "writes a lint or test suppression"
bash_cmd "reading deny.toml does not ask" "cat deny.toml | grep bans" silent
bash_cmd "cargo test does not ask" "cargo test --workspace 2>&1 | tail" silent
bash_cmd "sed -i on Cargo.toml dependencies asks" "sed -i 's/serde = \"1\"/serde = \"2\"/' Cargo.toml" ask "a Cargo.toml"
bash_cmd "a .rs write without a suppression does not ask" "printf 'fn x() {}\\n' >> crates/lib/src/lib.rs" silent

# Opt-out.
export WEAKENED_CHECKS_PROTECT_CONFIG=off
write "WEAKENED_CHECKS_PROTECT_CONFIG=off turns the hook off" deny.toml 'x' silent
bash_cmd "WEAKENED_CHECKS_PROTECT_CONFIG=off turns Bash checks off" "sed -i 's/a/b/' deny.toml" silent
edit "WEAKENED_CHECKS_PROTECT_CONFIG=off turns the suppression check off" crates/lib/src/lib.rs 'pub fn a() {}' '#[allow(unused)] pub fn a() {}' silent
unset WEAKENED_CHECKS_PROTECT_CONFIG

# A tool failure never asks and is never silent.
HOOK_PATH="${nojq}" write "missing jq is reported through additionalContext" deny.toml 'x' context "jq is not on PATH"
HOOK_PATH="${nojq}" write "missing jq is quiet for a file that isn't ours" NOTES.md 'x' silent
run_json "unreadable input is reported, not asked" '{not json' context "could not read the hook input"

# Not the Rust hook's to judge, but this one protects every git repository.
p="${work}/plain"
mkdir -p "${p}/.github/workflows" && git -C "${p}" init -q -b main
r="${p}"
write "a non-Rust repo is protected too" .github/workflows/ci.yml 'x' ask ".github/workflows/ci.yml is check config"
write "deny.toml in a non-Rust repo is protected too" deny.toml 'x' ask "deny.toml is check config"
bash_cmd "Bash in a non-Rust repo is protected too" "sed -i 's/a/b/' deny.toml" ask "this command looks like it changes"
mkdir -p "${p}/sub" && printf '[package]\nname = "sub"\n' >"${p}/sub/Cargo.toml"
write "a crate below a non-Rust repo root is protected too" sub/clippy.toml 'x' ask "sub/clippy.toml is check config"

# ---------------------------------------------------------------------------
# New: the config, read from the default branch.
# ---------------------------------------------------------------------------

new_repo
commit_conf 'config-path @defaults extra/*.cfg'
write "config from main: @defaults plus a glob asks for the glob" extra/a.cfg 'x' ask "extra/a.cfg is check config"
write "config from main: @defaults keeps the built-in list" deny.toml 'x' ask "deny.toml is check config"

new_repo
commit_conf 'config-path only.cfg'
write "config from main: without @defaults the listed path asks" only.cfg 'x' ask "only.cfg is check config"
write "config from main: without @defaults deny.toml is silent" deny.toml 'x' silent

new_repo
printf 'config-path extra2.cfg\n' >"${r}/.github/weakened-checks.conf"
write "an uncommitted config is not used (its path is silent)" extra2.cfg 'x' silent
write "an uncommitted config is not used (the defaults still ask)" deny.toml 'x' ask "deny.toml is check config"
edit "editing the working-tree config itself asks" .github/weakened-checks.conf 'extra2.cfg' 'other.cfg' ask ".github/weakened-checks.conf is check config"

new_repo
commit_conf 'config-path @defaults'
edit "an edit widening the config asks" .github/weakened-checks.conf 'config-path @defaults' 'config-path only.cfg' ask ".github/weakened-checks.conf is check config"
write "a Write to the exceptions file asks" .github/weakened-checks-exceptions 'x' ask ".github/weakened-checks-exceptions is check config"

new_repo
commit_conf 'exceptions other/ex.txt'
write "a configured exceptions path asks" other/ex.txt 'x' ask "other/ex.txt is check config"
write "the default exceptions path still asks with a configured one" .github/weakened-checks-exceptions 'x' ask ".github/weakened-checks-exceptions is check config"

new_repo
commit_conf 'disable check-config'
write "disable check-config: deny.toml is silent" deny.toml 'x' silent
write "disable check-config: the config file still asks" .github/weakened-checks.conf 'x' ask ".github/weakened-checks.conf is check config"

new_repo
commit_conf 'frobnicate x
config-path @defaults extra/*.cfg'
write "a config that doesn't parse still protects its config-path entries" extra/a.cfg 'x' ask "did not parse"
write "a config that doesn't parse still protects the built-in list" deny.toml 'x' ask "deny.toml is check config"
write "a config that doesn't parse is reported on a harmless write" NOTES.md '# notes' context "did not parse"

new_repo
commit_conf 'disable go-nolint'
edit "disable go-nolint: adding //nolint is silent" a.go 'x := 1' 'x := 1 //nolint:errcheck' silent

# ---------------------------------------------------------------------------
# New: Go.
# ---------------------------------------------------------------------------

new_repo
edit "Go: adding //nolint:errcheck asks" a.go 'a()' 'a() //nolint:errcheck' ask "adds or widens a lint or test suppression"
edit "Go: widening //nolint:errcheck to //nolint asks" a.go 'a() //nolint:errcheck' 'a() //nolint' ask
edit "Go: keeping an identical //nolint:errcheck while editing other code is silent" a.go 'a() //nolint:errcheck
b()' 'a() //nolint:errcheck
c()' silent
edit "Go: t.Skip added to a_test.go asks" a_test.go 'x()' 't.Skip("x")' ask
edit "Go: t.Skip added to a non-test a.go is silent" a.go 'x()' 't.Skip("x")' silent
write "Go: Write to .golangci.yml asks" .golangci.yml 'x: 1' ask ".golangci.yml is check config"
write "Go: Write to sub/.golangci.yaml asks" sub/.golangci.yaml 'x: 1' ask "sub/.golangci.yaml is check config"

# ---------------------------------------------------------------------------
# New: Rust widening.
# ---------------------------------------------------------------------------

edit "Rust: widening #[allow(dead_code)] to #[allow(dead_code, unused)] asks" crates/lib/src/lib.rs '#[allow(dead_code)]' '#[allow(dead_code, unused)]' ask
multi "Rust: a MultiEdit removing one #[allow] and adding a different #[ignore] asks" crates/lib/src/lib.rs \
  '[{"old_string": "#[allow(dead_code)]\nfn old() {}", "new_string": "fn old() {}"}, {"old_string": "pub fn a() {}", "new_string": "#[ignore] pub fn a() {}"}]' ask
edit "Rust: adding #[rustfmt::skip] asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[rustfmt::skip]
pub fn a() {}' ask

# ---------------------------------------------------------------------------
# New: TypeScript.
# ---------------------------------------------------------------------------

while IFS='|' read -r label text; do
  edit "TypeScript: adding ${label} asks" src/a.ts 'const a = 1;' "const a = 1;
${text}" ask "adds or widens a lint or test suppression"
done <<'EOF'
// @ts-ignore|// @ts-ignore
// @ts-nocheck|// @ts-nocheck
/* eslint-disable */|/* eslint-disable */
// biome-ignore lint/x: y|// biome-ignore lint/x: y
it.skip(|it.skip("x", () => {});
test.only(|test.only("x", () => {});
describe.skip(|describe.skip("x", () => {});
xit(|xit("x", () => {});
EOF
edit "TypeScript: // @ts-expect-error with no reason in the middle of new text asks" src/a.ts 'const a = 1;' 'const a = 1;
// @ts-expect-error
const b: string = a;
const c = 2;' ask
edit "TypeScript: // @ts-expect-error with a reason is silent" src/a.ts 'const a = 1;' '// @ts-expect-error: the vendor types are wrong
const a = 1;' silent
edit "TypeScript: exit(1) is not xit" src/a.ts 'const a = 1;' 'const a = 1;
exit(1);' silent
edit "TypeScript: widening eslint-disable-next-line to eslint-disable asks" src/a.ts '// eslint-disable-next-line no-console' '/* eslint-disable */' ask
for p in tsconfig.json packages/a/tsconfig.build.json biome.json vitest.config.ts eslint.config.js; do
  write "TypeScript: Write to ${p} asks" "${p}" '{}' ask "${p} is check config"
done

# as unknown as: context, or ask where the config prohibits it and no exception allows it.
edit "ts-as-unknown in src/a.ts gives context" src/a.ts 'const a = 1;' 'const a = x as unknown as Y;' context "ts-as-unknown"
edit "ts-as-unknown in src/a.test.ts is silent" src/a.test.ts 'const a = 1;' 'const a = x as unknown as Y;' silent
new_repo
commit_conf 'prohibit ts-as-unknown src/*'
edit "ts-as-unknown asks where the config prohibits it" src/a.ts 'const a = 1;' 'const a = x as unknown as Y;' ask "ts-as-unknown"
new_repo
commit_conf 'prohibit ts-as-unknown src/*' 'ts-as-unknown src/a.ts reason here'
edit "ts-as-unknown is context again with an exception at HEAD" src/a.ts 'const a = 1;' 'const a = x as unknown as Y;' context "ts-as-unknown"

# ---------------------------------------------------------------------------
# New: Svelte, Python and shell.
# ---------------------------------------------------------------------------

new_repo
edit "Svelte: adding svelte-ignore asks" src/A.svelte '<button />' '<!-- svelte-ignore a11y_click_events -->
<button />' ask "adds or widens a lint or test suppression"
edit "Svelte: // @ts-ignore in a script block asks" src/A.svelte '<button />' '<script lang="ts">
// @ts-ignore
let x = 1;
</script>
<button />' ask
edit "Python: adding @pytest.mark.skip asks" tests/test_a.py 'def test_a():' '@pytest.mark.skip
def test_a():' ask "adds or widens a lint or test suppression"
edit "Python: adding pytest.skip( asks" tests/test_a.py 'x = 1' 'pytest.skip("later")' ask
edit "Shell: adding # nosemgrep to run.sh asks" run.sh 'rm -f tmp' 'rm -f tmp # nosemgrep' ask

# ---------------------------------------------------------------------------
# New: Bash.
# ---------------------------------------------------------------------------

p="${work}/untracked"
rm -rf "${p}" && mkdir -p "${p}/.github/workflows" && git -C "${p}" init -q -b main
printf 'name: new\n' >"${p}/.github/workflows/new.yml"
r="${p}"
bash_cmd "Bash: rm -rf .github asks when the workflow in it is untracked" "rm -rf .github" ask "this command looks like it changes check config"
new_repo
bash_cmd "Bash: a redirect with no space asks" "echo x >>.github/workflows/ci.yml" ask
bash_cmd "Bash: reading a workflow with 2>&1 and a pipe is silent" "cat .github/workflows/ci.yml 2>&1 | grep x" silent
bash_cmd "Bash: printf a @ts-ignore into a .ts file asks" "printf '// @ts-ignore\\n' >> src/a.ts" ask "writes a lint or test suppression"
bash_cmd "Bash: cp README.md docs/ is silent" "cp README.md docs/" silent

# ---------------------------------------------------------------------------
# New: tool failures and installation shapes.
# ---------------------------------------------------------------------------

HOOK_PATH="${nogit}" write "missing git is reported through additionalContext" deny.toml 'x' context "git is not on PATH"

mkdir -p "${work}/orphan/agent"
cp "${hook}" "${work}/orphan/agent/claude-protect-config.sh"
HOOK_BIN="${work}/orphan/agent/claude-protect-config.sh" write "a hook without ../lib/config.bash is reported" deny.toml 'x' context "is missing"

mkdir -p "${work}/links"
ln -s "${hook}" "${work}/links/hook.sh"
HOOK_BIN="${work}/links/hook.sh" write "a hook symlinked from another directory still works" deny.toml 'x' ask "deny.toml is check config"

# ---------------------------------------------------------------------------
# New: outside a git repository.
# ---------------------------------------------------------------------------

r="${work}/nogitdir"
mkdir -p "${r}/.github/workflows"
write "outside a git repository a workflow write is silent" .github/workflows/ci.yml 'x' silent
bash_cmd "outside a git repository Bash is silent" "sed -i 's/a/b/' .github/workflows/ci.yml" silent

# ---------------------------------------------------------------------------
# New: opt-out for each tool.
# ---------------------------------------------------------------------------

new_repo
export WEAKENED_CHECKS_PROTECT_CONFIG=off
edit "opt-out: Edit is silent" deny.toml '[bans]' '' silent
write "opt-out: Write is silent" deny.toml 'x' silent
bash_cmd "opt-out: Bash is silent" "sed -i 's/a/b/' deny.toml" silent
unset WEAKENED_CHECKS_PROTECT_CONFIG

# ---------------------------------------------------------------------------
# New: changes the first version of this hook let through.
# ---------------------------------------------------------------------------

new_repo
mkdir -p "${r}/src"
printf '#![deny(warnings)]\n#[allow(dead_code)]\n#[cfg(test)]\nmod t {}\n' >"${r}/crates/lib/src/lib.rs"
edit "an Edit of part of an #[allow(..)] that widens it asks" crates/lib/src/lib.rs 'dead_code)]' 'dead_code, clippy::all)]' ask "dead_code, clippy::all"
edit "an Edit turning deny(warnings) into allow(warnings) asks" crates/lib/src/lib.rs 'deny(warnings)' 'allow(warnings)' ask
edit "an Edit turning cfg(test) into cfg(false) asks" crates/lib/src/lib.rs 'cfg(test)' 'cfg(false)' ask
printf 'const a = 1;\n// @ts-expect-error: because upstream types\nfoo(a);\n' >"${r}/src/b.ts"
edit "an Edit dropping a @ts-expect-error's reason asks" src/b.ts ': because upstream types' '' ask "@ts-expect-error"
printf 'func TestA(t *testing.T) {\n\tt.Log("x")\n}\n' >"${r}/a_test.go"
edit "an Edit turning t.Log into t.Skip asks" a_test.go 'Log' 'Skip' ask
printf 'test.skipIf(false)("a", () => {});\n' >"${r}/src/c.test.ts"
edit "an Edit enabling a skipIf asks" src/c.test.ts 'false' 'true' ask "skipIf(true)"
edit "test.skip.each asks" src/c.test.ts 'test.skipIf(false)("a", () => {});' 'test.skip.each([1, 2])("case", () => {});' ask
printf '[package]\nname = "deny"\n\n[lints.rust]\nunused = "deny"\n' >"${r}/crates/lib/Cargo.toml"
run_json "a replace_all Edit reaching the lints table asks" "$(jq -n --arg f "${r}/crates/lib/Cargo.toml" \
  '{tool_name: "Edit", tool_input: {file_path: $f, old_string: "\"deny\"", new_string: "\"allow\"", replace_all: true}}')" ask "[workspace.lints]"
yes 'const filler = 1;' | head -n 20000 >"${r}/src/big.ts"
printf '// x\n' >>"${r}/src/big.ts"
edit "a suppression added to a file over 128 KiB asks" src/big.ts '// x' '// @ts-ignore' ask

new_repo
commit_conf 'config-path @defaults :(exclude).github/**'
write "an :(exclude) in the config doesn't unprotect the config" .github/weakened-checks.conf 'disable check-config' ask ".github/weakened-checks.conf is check config"
write "an :(exclude) in the config doesn't unprotect the exceptions file" .github/weakened-checks-exceptions 'x' ask

new_repo
commit_conf 'frobnicate x
config-path extra/*.cfg'
mkdir -p "${r}/extra" && printf 'x\n' >"${r}/extra/a.cfg"
write "a config that doesn't parse protects new files its glob matches" extra/new.cfg 'x' ask "extra/new.cfg is check config"

new_repo
ln -s deny.toml "${r}/alias.toml"
edit "an Edit through a symlink to a protected file asks" alias.toml '[bans]' '' ask "deny.toml is check config"
bash_cmd "tee through a symlink to a protected file asks" "printf 'x\\n' | tee alias.toml" ask "deny.toml"
rm -f "${r}/alias.toml"
bash_cmd "sed -i.bak asks" "sed -i.bak 's/deny/allow/' deny.toml" ask
bash_cmd "sed by its full path asks" "/usr/bin/sed -i 's/deny/allow/' deny.toml" ask
bash_cmd "git -C . restore asks" "git -C . restore deny.toml" ask
bash_cmd "a >| redirect asks" "echo x >| .github/workflows/ci.yml" ask
bash_cmd "dd of= asks" "dd if=/dev/null of=deny.toml" ask
bash_cmd "pnpm install with tsconfig.json named is silent" "pnpm install && pnpm exec tsc -p tsconfig.json --noEmit" silent
long="cat > .github/workflows/ci.yml <<'EOF'"$'\n'"$(yes 'run: echo step done here' | head -n 1000)"$'\n'"EOF"
start=${SECONDS}
bash_cmd "a long heredoc into a workflow asks" "${long}" ask
((SECONDS - start < 8)) || { echo "FAIL a long heredoc took $((SECONDS - start))s"; failures=$((failures + 1)); }

# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "a redirect to \$PWD/deny.toml asks" 'printf x > "$PWD/deny.toml"' ask
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "sed -i on \$(pwd)/deny.toml asks" 'sed -i s/a/b/ "$(pwd)/deny.toml"' ask
bash_cmd "git checkout of the whole tree asks" "git checkout HEAD -- ." ask "the whole repository"
bash_cmd "git restore . asks" "git restore ." ask
bash_cmd "git add . is silent" "git add . && git status" silent
bash_cmd "Bash t.Skip into a non-test .go file is silent" "printf 't.Skip()\\n' >> a.go" silent
bash_cmd "Bash latest.only( into a .ts file is silent" "printf 'latest.only()\\n' >> src/a.ts" silent
norp="${work}/norealpath"
mkdir -p "${norp}"
for t in bash env git jq dirname basename sed head grep cat mktemp rm tr readlink; do
  ln -s "$(command -v "${t}")" "${norp}/${t}"
done
HOOK_PATH="${norp}" write "without realpath a protected Write still asks" deny.toml 'x' ask "deny.toml is check config"

fakejq="${work}/fakejq"
mkdir -p "${fakejq}" && printf '#!/bin/sh\nexit 1\n' >"${fakejq}/jq" && chmod +x "${fakejq}/jq"
HOOK_PATH="${fakejq}:${PATH}" write "a jq that fails still gives JSON, never silence" deny.toml 'x' context "could not read the hook input"

# ---------------------------------------------------------------------------
# New: what rust-ci v3's hook asked for and this one didn't (#5).
# ---------------------------------------------------------------------------

new_repo
# The hook's own paths, beside the built-in list.
for p in lefthook-local.yml lefthook-local.yaml .lefthook-local.yml .gitattributes crates/lib/.gitattributes \
  build.rs crates/lib/build.rs .github/zizmor.yml .github/zizmor.yaml .github/actionlint.yml .github/actionlint.yaml; do
  write "Write to ${p} asks (the hook's own list)" "${p}" 'x = 1' ask "${p} is check config"
done
bash_cmd "writing a .gitattributes asks" "echo '*.rs -diff' > crates/lib/.gitattributes" ask "crates/lib/.gitattributes"
bash_cmd "cp onto build.rs asks" "cp /tmp/b.rs build.rs" ask "build.rs"
bash_cmd "tee into lefthook-local.yml asks" "echo 'skip_output: true' | tee lefthook-local.yml" ask
bash_cmd "a redirect into .github/zizmor.yml asks" "printf 'rules: {}\\n' > .github/zizmor.yml" ask
bash_cmd "reading build.rs does not ask" "cat build.rs" silent
commit_conf 'config-path @defaults'
write "config from main: @defaults keeps the hook's own paths" build.rs 'x' ask "build.rs is check config"
commit_conf 'config-path only.cfg'
write "config from main: without @defaults the hook's own paths are silent" build.rs 'x' silent
commit_conf 'frobnicate x'
write "a config that doesn't parse still protects the hook's own paths" build.rs 'x' ask "build.rs is check config"
commit_conf 'disable check-config'
write "disable check-config: the hook's own paths are silent" build.rs 'x' silent

# Cargo.toml: [profile] tables, and the table a dotted lints key sits under.
new_repo
edit "adding a [profile] setting asks" Cargo.toml 'serde = "1"' 'serde = "1"

[profile.release]
overflow-checks = false' ask "[profile]"
printf '[package]\nname = "lib"\n\n[profile.dev]\ndebug-assertions = true\n\n[lints]\nworkspace = true\n' >"${r}/crates/lib/Cargo.toml"
edit "changing a [profile] value asks" crates/lib/Cargo.toml 'debug-assertions = true' 'debug-assertions = false' ask "[profile]"
edit "an inline profile table at the root asks" crates/lib/Cargo.toml '[package]' 'profile = { dev = { overflow-checks = false } }
[package]' ask
edit "a profile key under [package] does not ask" crates/lib/Cargo.toml 'name = "lib"' 'name = "lib"
profile = "x"' silent
mkdir -p "${r}/crates/dot"
printf '# dot crate\nlints.clippy.unwrap_used = "deny"\n\n[package]\nname = "dot"\n' >"${r}/crates/dot/Cargo.toml"
write "a Write moving a dotted lints key under another table asks" crates/dot/Cargo.toml '# dot crate
[package.metadata]
lints.clippy.unwrap_used = "deny"

[package]
name = "dot"
' ask "[lints]"
edit "an Edit putting a table header above a dotted lints key asks" crates/dot/Cargo.toml '# dot crate' '# dot crate
[package.metadata]' ask "[lints]"
edit "an Edit below the dotted lints key outside lints does not ask" crates/dot/Cargo.toml 'name = "dot"' 'name = "dots"' silent
edit "an Edit adding a table header outside lints does not ask" Cargo.toml 'serde = "1"' 'serde = "1"

[workspace.package]
edition = "2024"' silent
write "a lints table written another way, same lints, does not ask" Cargo.toml '[workspace]
members = ["crates/*"]

[workspace.dependencies]
serde = "1"

[workspace.lints]
clippy.unwrap_used = "deny"
' silent
write "the same lints written another way with a weaker level asks" Cargo.toml '[workspace]
members = ["crates/*"]

[workspace.dependencies]
serde = "1"

[workspace.lints]
clippy.unwrap_used = "warn"
' ask "[workspace.lints]"
printf '[workspace]\nmembers = [\n  "crates/*",\n]\n\n[workspace.lints.rust]\nunexpected_cfgs = { level = "warn", check-cfg = [\n  "cfg(a)",\n] }\n' >"${r}/Cargo.toml"
edit "a line of a multi-line array in a lints table asks" Cargo.toml '  "cfg(a)",' '  "cfg(a)",
  "cfg(b)",' ask
edit "a line of a multi-line array outside lints does not ask" Cargo.toml '  "crates/*",' '  "crates/*",
  "tools/*",' silent
edit "an array line that looks like a header is not taken for one" Cargo.toml '  "crates/*",' '  "crates/*",
  ["x"]
' silent
new_repo
commit_conf 'disable cargo-lint-levels'
edit "disable cargo-lint-levels: a [profile] edit is silent" Cargo.toml 'serde = "1"' 'serde = "1"
[profile.dev]
opt-level = 0' silent

# .rs files: more suppressions, and removed lint attributes.
new_repo
edit "an edit adding #[should_panic] asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[test] #[should_panic] fn t() {}' ask "#[should_panic]"
edit "an edit adding #[should_panic(expected)] asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[test]
#[should_panic(expected = "boom")]
fn t() {}' ask
edit "an edit adding #[cfg(miri)] asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[cfg(miri)] pub fn a() {}' ask
edit "an edit adding #[cfg(windows)] does not ask" crates/lib/src/lib.rs 'pub fn a() {}' '#[cfg(windows)] pub fn a() {}' silent
edit "respacing an #[allow] does not ask" crates/lib/src/lib.rs '#[allow(dead_code)]' '#[allow( dead_code )]' silent
edit "respacing an #[allow] while widening it asks, showing it as written" crates/lib/src/lib.rs '#[allow(dead_code)]' '#[allow( dead_code, unused )]' ask "#[allow( dead_code, unused )]"
d_rs='#![forbid(unsafe_code)]
#![deny(clippy::unwrap_used, clippy::expect_used)]

#[warn(missing_docs)]
#[cfg_attr(test, deny(dead_code))]
pub fn a() {}
'
printf '%s' "${d_rs}" >"${r}/crates/lib/src/d.rs"
edit "removing a #![forbid] asks" crates/lib/src/d.rs '#![forbid(unsafe_code)]
' '' ask "#![forbid(unsafe_code)]"
edit "narrowing a #![deny] list asks" crates/lib/src/d.rs 'clippy::unwrap_used, clippy::expect_used' 'clippy::unwrap_used' ask "#![deny(clippy::expect_used)]"
edit "widening a #![deny] list does not ask" crates/lib/src/d.rs 'clippy::unwrap_used, clippy::expect_used' 'clippy::unwrap_used, clippy::expect_used, clippy::panic' silent
edit "turning #[warn] into #[allow] asks" crates/lib/src/d.rs '#[warn(missing_docs)]' '#[allow(missing_docs)]' ask
edit "removing a cfg_attr deny asks" crates/lib/src/d.rs '#[cfg_attr(test, deny(dead_code))]
' '' ask "removes or narrows a lint attribute"
edit "respacing a #![deny] does not ask" crates/lib/src/d.rs '#![deny(clippy::unwrap_used, clippy::expect_used)]' '#![deny( clippy::unwrap_used,  clippy::expect_used )]' silent
edit "an unrelated edit next to a #![deny] does not ask" crates/lib/src/d.rs 'pub fn a() {}' 'pub fn b() {}' silent
write "a Write dropping a #![deny] asks" crates/lib/src/d.rs '#![forbid(unsafe_code)]

#[warn(missing_docs)]
#[cfg_attr(test, deny(dead_code))]
pub fn a() {}
' ask "#![deny("
write "a Write moving the lint attributes does not ask" crates/lib/src/d.rs "// moved
${d_rs}" silent
edit "an edit whose old text isn't in the file is judged on its own text" crates/lib/src/d.rs '#![deny(clippy::panic)]' '' ask "#![deny(clippy::panic)]"
bash_cmd "sed -i deleting a deny line asks" "sed -i '/deny(/d' crates/lib/src/d.rs" ask "deny or forbid"
bash_cmd "grep for deny in a .rs file does not ask" "grep -n deny crates/lib/src/d.rs" silent
commit_conf 'disable rust-allow'
edit "disable rust-allow: removing a #![forbid] is silent" crates/lib/src/d.rs '#![forbid(unsafe_code)]
' '' silent
bash_cmd "disable rust-allow: sed -i deleting a deny line is silent" "sed -i '/deny(/d' crates/lib/src/d.rs" silent

# gitleaks:allow, in any file.
new_repo
edit "an edit adding gitleaks:allow to a .rs file asks" crates/lib/src/lib.rs 'pub fn a() {}' 'const K: &str = "k"; // gitleaks:allow' ask "gitleaks:allow"
write "a Markdown file gaining gitleaks:allow asks" NOTES.md 'token: abc <!-- gitleaks:allow -->' ask "secret scanning"
write "a Cargo.toml gaining gitleaks:allow asks" crates/lib/Cargo.toml "$(cat "${r}/crates/lib/Cargo.toml")
# gitleaks:allow" ask "gitleaks:allow"
printf 'key = abc # gitleaks\n' >"${r}/app.ini"
edit "an edit completing a gitleaks:allow asks" app.ini '# gitleaks' '# gitleaks:allow' ask "gitleaks:allow"
printf 'key = abc # gitleaks:allow\n' >"${r}/app.ini"
edit "an edit keeping a gitleaks:allow does not ask" app.ini 'key = abc' 'key = abd' silent
bash_cmd "appending gitleaks:allow to any file asks" "echo 'key = abc # gitleaks:allow' >> config/app.ini" ask "gitleaks:allow"
bash_cmd "grep for gitleaks:allow does not ask" "grep -rn gitleaks:allow ." silent
HOOK_PATH="${nojq}" write "missing jq is reported for a gitleaks:allow in any file" NOTES.md 'x <!-- gitleaks:allow -->' context "jq is not on PATH"
commit_conf 'disable cargo-lint-levels'
write "disable cargo-lint-levels: a Cargo.toml gaining gitleaks:allow still asks" crates/lib/Cargo.toml "$(cat "${r}/crates/lib/Cargo.toml")
# gitleaks:allow" ask "gitleaks:allow"

# Bash: any write to a Cargo.toml, and Rust suppressions written another way.
new_repo
bash_cmd "sed -i on Cargo.toml without the word lints asks" "sed -i '/unsafe_code/a warnings = \"allow\"' Cargo.toml" ask "a Cargo.toml"
bash_cmd "perl -i on a member Cargo.toml asks" "perl -i -pe 's/workspace = true//' crates/lib/Cargo.toml" ask
bash_cmd "appending to Cargo.toml asks" "printf '[profile.dev]\\nopt-level = 1\\n' >> Cargo.toml" ask
bash_cmd "mv onto Cargo.toml asks" "mv /tmp/x.toml Cargo.toml" ask
bash_cmd "reading Cargo.toml does not ask" "grep -n lints Cargo.toml" silent
bash_cmd "cargo add does not ask" "cargo add serde --features derive" silent
bash_cmd "--manifest-path with a tee does not ask" "cargo test --manifest-path crates/lib/Cargo.toml 2>&1 | tee test.log" silent
bash_cmd "--manifest-path= with a tee does not ask" "cargo build --manifest-path=crates/lib/Cargo.toml | tee build.log" silent
bash_cmd "sed -i adding #[ allow(...)] with a space asks" "sed -i 's/^pub fn a/#[ allow(warnings)]\\npub fn a/' crates/lib/src/lib.rs" ask
bash_cmd "sed -i adding an escaped #\\[allow( asks" "sed -i 's/^pub fn a/#\\[allow(warnings)]\\npub fn a/' crates/lib/src/lib.rs" ask
bash_cmd "appending #[should_panic] asks" "printf '#[should_panic]\\n' >> crates/lib/src/lib.rs" ask
bash_cmd "appending #[cfg_attr(miri, ignore)] asks" "printf '#[cfg_attr(miri, ignore)]\\n' >> crates/lib/src/lib.rs" ask
bash_cmd "appending #[cfg(miri)] asks" "printf '#[cfg( miri )]\\n' >> crates/lib/src/lib.rs" ask
bash_cmd "appending #[rustfmt::skip] asks" "printf '#[rustfmt::skip]\\n' >> crates/lib/src/lib.rs" ask

# ---------------------------------------------------------------------------
# New: Claude Code's project settings and hooks, which can turn this hook off
# (#6).
# ---------------------------------------------------------------------------

new_repo
mkdir -p "${r}/.claude/hooks" "${r}/apps/web/.claude"
printf '{}\n' >"${r}/.claude/settings.json"
printf '{}\n' >"${r}/.claude/settings.local.json"
printf '#!/bin/sh\n' >"${r}/.claude/hooks/check.sh"
printf '{}\n' >"${r}/apps/web/.claude/settings.local.json"
for p in .claude/settings.json .claude/settings.local.json .claude/hooks/check.sh .claude/hooks/new.sh \
  apps/web/.claude/settings.local.json apps/web/.claude/settings.json apps/web/.claude/hooks/x.sh; do
  write "Write to ${p} asks" "${p}" '{"env": {"WEAKENED_CHECKS_PROTECT_CONFIG": "off"}}' ask "${p} is Claude Code's project settings"
done
for p in .claude/settings.json .claude/settings.local.json .claude/hooks/check.sh apps/web/.claude/settings.local.json; do
  edit "Edit to ${p} asks" "${p}" '{}' '{"env": {"WEAKENED_CHECKS_PROTECT_CONFIG": "off"}}' ask "${p} is Claude Code's project settings"
  bash_cmd "a Bash redirect into ${p} asks" "echo '{}' > ${p}" ask "${p}"
done
bash_cmd "sed -i on .claude/settings.local.json asks" "sed -i 's/{}/{\"disableAllHooks\": true}/' .claude/settings.local.json" ask
bash_cmd "rm -rf .claude/hooks asks" "rm -rf .claude/hooks" ask ".claude/hooks"
bash_cmd "mv .claude/hooks away asks" "mv .claude/hooks /tmp/hooks" ask ".claude/hooks"
bash_cmd "rm -rf .claude asks" "rm -rf .claude" ask ".claude"
bash_cmd "rm -rf apps/web asks for its .claude" "rm -rf apps/web" ask "apps/web"
write "a Write to .claude/commands does not ask" .claude/commands/x.md '# x' silent
write "a file merely named settings.json elsewhere does not ask" config/settings.json '{}' silent
bash_cmd "reading .claude/settings.json does not ask" "cat .claude/settings.json" silent
printf '.claude/settings.local.json\n' >"${r}/.gitignore"
bash_cmd "a Bash write to a gitignored settings.local.json asks" "printf '{}' > .claude/settings.local.json" ask
bash_cmd "rm -rf .claude asks with only a gitignored settings.local.json" "rm -f .claude/settings.json && rm -rf .claude" ask
commit_conf 'disable check-config'
write "disable check-config: .claude/settings.json still asks" .claude/settings.json '{}' ask ".claude/settings.json is Claude Code's project settings"
commit_conf 'config-path @defaults :(exclude).claude/** :(exclude)**/.claude/**'
write "an :(exclude) in the config doesn't unprotect .claude/hooks" .claude/hooks/check.sh 'x' ask ".claude/hooks/check.sh is Claude Code's project settings"
bash_cmd "an :(exclude) in the config doesn't unprotect .claude/hooks for rm" "rm -rf .claude/hooks" ask

# ---------------------------------------------------------------------------
# New: ways around the #5 and #6 checks that the first version let through.
# ---------------------------------------------------------------------------

new_repo
write "Write to a nested .cargo/mutants.toml asks (the hook's own list)" crates/lib/.cargo/mutants.toml 'x = 1' ask "crates/lib/.cargo/mutants.toml is check config"
write "Write to .lefthook-local.yaml asks (the hook's own list)" .lefthook-local.yaml 'x = 1' ask ".lefthook-local.yaml is check config"
printf '[package]\nname = "lib"\n\n[profile.release]\noverflow-checks = true # check\n\n[lints.clippy]\nunwrap_used = "deny"\n' >"${r}/crates/lib/Cargo.toml"
edit "quoting a lints header into one key asks" crates/lib/Cargo.toml '[lints.clippy]' '["lints.clippy"]' ask "[lints]"
edit "quoting a profile header into one key asks" crates/lib/Cargo.toml '[profile.release]' '["profile.release"]' ask
edit "quoting a header's segments separately does not ask" crates/lib/Cargo.toml '[lints.clippy]' '["lints"."clippy"]' silent
edit "a profile header spelled with an escape asks" crates/lib/Cargo.toml 'name = "lib"' 'name = "lib"
["profile".dev]
overflow-checks = false' ask
edit "changing only a comment beside a profile value does not ask" crates/lib/Cargo.toml '# check' '# keep check' silent
write "wrapping the lints table in a multi-line string asks" crates/lib/Cargo.toml '[package]
name = "lib"
description = """

[lints.clippy]
unwrap_used = "deny"
#"""
[profile.release]
overflow-checks = true # check
' ask
printf '[workspace.lints.rust]\nunexpected_cfgs = { level = "deny", check-cfg = [\n  '"'"'cfg(mode, values("a b"))'"'"',\n] }\n\n[profile.dev]\nrustflags = [\n  "-C", "debug-assertions=no",\n  "-C", "debug-assertions=yes",\n]\n' >"${r}/Cargo.toml"
edit "a space inside a string in a lints value asks" Cargo.toml 'values("a b")' 'values("ab")' ask
multi "reordering the lines of a profile array asks" Cargo.toml \
  '[{"old_string": "  \"-C\", \"debug-assertions=no\",\n  \"-C\", \"debug-assertions=yes\",", "new_string": "  \"-C\", \"debug-assertions=yes\",\n  \"-C\", \"debug-assertions=no\","}]' ask

printf '#![deny(unsafe_code)]\n#![deny(dead_code, reason = "one, two")]\n#[warn(missing_docs)]\npub fn a() {}\n#[test]\n#[should_panic(expected = "[foo] not found")]\nfn t() {}\n' >"${r}/crates/lib/src/m.rs"
edit "commenting out a #![deny] asks" crates/lib/src/m.rs '#![deny(unsafe_code)]' '// #![deny(unsafe_code)]' ask "#![deny(unsafe_code)]"
edit "a #![deny] put in a block comment asks" crates/lib/src/m.rs '#![deny(unsafe_code)]' '/* #![deny(unsafe_code)] */' ask
edit "a #![deny] put in a string asks" crates/lib/src/m.rs '#![deny(unsafe_code)]' 'const _S: &str = "#![deny(unsafe_code)]";' ask
edit "deny to forbid does not ask" crates/lib/src/m.rs '#![deny(unsafe_code)]' '#![forbid(unsafe_code)]' silent
edit "warn to deny does not ask" crates/lib/src/m.rs '#[warn(missing_docs)]' '#[deny(missing_docs)]' silent
edit "deny to warn asks" crates/lib/src/m.rs '#![deny(unsafe_code)]' '#![warn(unsafe_code)]' ask "#![deny(unsafe_code)]"
edit "changing a reason with commas in it does not ask" crates/lib/src/m.rs 'one, two' 'one, three' silent
edit "a lint named only in a reason is still removed" crates/lib/src/m.rs '#![deny(unsafe_code)]' '#![deny(missing_docs, reason = ",unsafe_code,")]' ask
edit "narrowing a should_panic with a ] in its string asks" crates/lib/src/m.rs '"[foo] not found"' '"[foo]"' ask "should_panic"

for i in $(seq 1001); do printf '#[deny(dead_code)]\nfn f%d() {}\n' "${i}"; done >"${r}/crates/lib/src/many.rs"
edit "a file with over 1000 lint attributes says it wasn't checked for removed ones" crates/lib/src/many.rs 'fn f10()' 'fn g10()' context "over 1000 lint attributes"
printf 'key = abc # gitleaks:alow\n' >"${r}/app.ini"
edit "an edit completing a gitleaks:allow without the word gitleaks asks" app.ini 'alow' 'allow' ask "gitleaks:allow"

new_repo
mkdir -p "${r}/tools/cc" "${r}/empty/.claude"
ln -s tools/cc "${r}/.claude"
write "a Write through a symlinked .claude asks" .claude/settings.local.json '{"env": {}}' ask "is Claude Code's project settings"
edit "an Edit through a symlinked .claude asks" .claude/hooks/x.sh 'a' 'b' ask "is Claude Code's project settings"
rm -f "${r}/.claude"
bash_cmd "symlinking a directory in as .claude asks" "mkdir -p tools/cc && ln -s tools/cc .claude" ask ".claude"
bash_cmd "copying settings into an empty .claude asks" "cp /tmp/settings.json empty/.claude/" ask "empty/.claude"
bash_cmd "moving settings into an empty .claude asks" "mv /tmp/settings.json empty/.claude" ask

# ---------------------------------------------------------------------------
# New: a Bash command is parsed, and only the files it writes are judged (#8).
# ---------------------------------------------------------------------------

new_repo
mkdir -p "${r}/app" "${r}/scripts" "${r}/empty"
printf '{}\n' >"${r}/app/tsconfig.json"
printf 'export {}\n' >"${r}/scripts/check-biome-strict.mjs"
printf 'name: test\n' >"${r}/.github/workflows/test.yml"
commit_all "#8 fixtures"

# The reported false positives.
bash_cmd "#8: jq --arg with JSON naming a workflow is silent" \
  "jq -n --arg f .github/workflows/ci.yml '{tool_name: \"Edit\", tool_input: {file_path: \$f}}' | agent/claude-protect-config.sh" silent
bash_cmd "#8: a quoted sed -i fixture passed to a function is silent" \
  "run Bash '{\"command\":\"sed -i s/a/b/ .github/workflows/ci.yml\"}' ask" silent
bash_cmd "#8: read-only grep and sed -n on a protected script are silent" \
  'grep -n biome .github/workflows/test.yml | head; sed -n 1,80p scripts/check-biome-strict.mjs; grep -n "^export" scripts/check-biome-strict.mjs; biome check --reporter=json src/some.js; echo rc=$?' silent
bash_cmd "#8: cd into a directory holding check config is silent" \
  "cd app && npx svelte-kit sync; vitest related --run src/lib/a.ts" silent
review=$'cat > /tmp/review.md <<\'EOF\'\nThe hook asks for .gitleaks.toml, CODEOWNERS, build.rs and .gitattributes.\nrm -rf .github; cp x deny.toml; sed -i s/a/b/ .github/workflows/ci.yml\nEOF\ngit worktree remove ../wt-8 && git fetch origin && git push -u origin wc-8'
bash_cmd "#8: a push after a review heredoc naming protected files is silent" "${review}" silent
bash_cmd "#8: a review heredoc fed to gh --body-file - is silent" \
  $'gh pr comment 12 --body-file - <<\'EOF\'\nsed -i s/a/b/ deny.toml > .github/workflows/ci.yml\nEOF\ngit push' silent
bash_cmd "#8: a stray . with rm of another file is silent" "ls . && rm -f /tmp/x.log" silent
bash_cmd "#8: git checkout of a branch is silent" "git checkout -b wc-8 && git status ." silent
bash_cmd "#8: cp from a protected file is silent" "cp .github/workflows/ci.yml /tmp/ci.yml" silent
bash_cmd "#8: cp into the root is silent" "cp /tmp/notes.txt ." silent
bash_cmd "#8: a quoted path in echo is silent" "echo 'edit deny.toml next' > /tmp/plan.txt" silent
bash_cmd "#8: sed -n is not sed -i" "sed -n 's/a/b/p' deny.toml" silent
bash_cmd "#8: find -delete with a filter that matches nothing protected is silent" "find . -name '*.orig' -delete" silent
bash_cmd "#8: a here-string to a reader is silent" "grep -c x <<< 'rm -rf .github'" silent
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: arithmetic and parameter expansion parse" 'echo $((1 + 2)) ${x:-"a b"} ${#arr[@]} a#b $'"'"'q\x27'"'"'; (( i++ ))' silent
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: a case pattern parses" 'case $x in a) echo deny.toml;; esac' silent

# Real writes the parser must still see.
bash_cmd "#8: a quoted path for sed -i asks" "sed -i 's/a/b/' \".github/workflows/ci.yml\"" ask "ci.yml"
bash_cmd "#8: sed -n -i asks" "sed -n -i 's/a/b/p' deny.toml" ask
bash_cmd "#8: sed --in-place asks" "sed --in-place=.bak 's/a/b/' deny.toml" ask
bash_cmd "#8: sed -ie asks" "sed -ie 's/a/b/' deny.toml" ask
bash_cmd "#8: BSD sed -i '' asks" "sed -i '' 's/a/b/' deny.toml" ask
bash_cmd "#8: perl -0777 -pi asks" "perl -0777 -pi -e 's/a/b/' deny.toml" ask
bash_cmd "#8: gsed -i asks" "gsed -i 's/a/b/' deny.toml" ask
bash_cmd "#8: sponge asks" "jq . deny.toml | sponge deny.toml" ask
bash_cmd "#8: bash -c asks" "bash -c 'sed -i s/a/b/ deny.toml'" ask
bash_cmd "#8: bash -lc asks" "bash -lc 'sed -i s/a/b/ deny.toml'" ask
bash_cmd "#8: eval asks" "eval 'echo x > deny.toml'" ask
bash_cmd "#8: a heredoc fed to bash asks" $'bash <<\'EOF\'\nsed -i s/a/b/ deny.toml\nEOF' ask
bash_cmd "#8: a heredoc piped to sh asks" $'cat <<\'EOF\' | sh\nrm -f deny.toml\nEOF' ask
bash_cmd "#8: echo piped to sh asks" "echo 'rm -f deny.toml' | sh" ask
bash_cmd "#8: sudo tee asks" "echo x | sudo -u root tee .github/workflows/ci.yml" ask
bash_cmd "#8: env with assignments asks" "env -u HOME LC_ALL=C sed -i s/a/b/ deny.toml" ask
bash_cmd "#8: env -S asks" "env -S 'sed -i s/a/b/ deny.toml'" ask
bash_cmd "#8: timeout asks" "timeout -s KILL 10 rm -f deny.toml" ask
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: a write in a command substitution asks" 'echo $(sed -i s/a/b/ deny.toml)' ask
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: a write in a command substitution in quotes asks" 'echo "$(sed -i s/a/b/ deny.toml)"' ask
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: a write in backticks asks" 'echo `rm -f deny.toml`' ask
bash_cmd "#8: a write in a heredoc that expands asks" $'cat > /tmp/x <<EOF\n$(rm -f deny.toml)\nEOF' ask
bash_cmd "#8: a write after a variable assignment asks" "X=1 sed -i s/a/b/ deny.toml" ask
bash_cmd "#8: a write after then asks" "if true; then rm -f deny.toml; fi" ask
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: a write after a case pattern asks" 'case $x in a) sed -i s/a/b/ deny.toml;; esac' ask
bash_cmd "#8: a write in a subshell asks" "(cd /tmp && true; rm -f '${r}/deny.toml')" ask
bash_cmd "#8: a redirect after a loop asks" "for x in a b; do echo \$x; done > .github/workflows/ci.yml" ask
bash_cmd "#8: a redirect after a group asks" "{ echo a; echo b; } > deny.toml" ask
bash_cmd "#8: a redirect after a subshell asks" "(echo '[profile.dev]') >> Cargo.toml" ask "a Cargo.toml"
bash_cmd "#8: a redirect first asks" ": > deny.toml" ask
bash_cmd "#8: >& a file asks" "echo x >& deny.toml" ask
bash_cmd "#8: &> a file asks" "echo x &> deny.toml" ask
bash_cmd "#8: <> a file asks" "exec 3<> deny.toml" ask
bash_cmd "#8: a quoted heredoc into a protected file asks" $'cat <<\'EOF\' > deny.toml\n[bans]\nEOF' ask
bash_cmd "#8: a heredoc diff fed to patch asks" $'patch -p1 <<\'EOF\'\n--- a/deny.toml\n+++ b/deny.toml\n@@ -1 +1 @@\n-[bans]\n+[x]\nEOF' ask
bash_cmd "#8: git apply of a heredoc diff asks" $'git apply <<\'EOF\'\n--- a/.github/workflows/ci.yml\n+++ b/.github/workflows/ci.yml\nEOF' ask
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: a for loop over workflows with sed -i asks" 'for f in .github/workflows/*.yml; do sed -i "s/a/b/" "$f"; done' ask
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: a target held in a variable asks" 'f=deny.toml; sed -i s/a/b/ "$f"' ask
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: a redirect to a variable asks" 'out=deny.toml; echo x > $out' ask
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: sed -i on a command's output asks" 'sed -i s/a/b/ $(grep -l name .github/workflows/*.yml)' ask
bash_cmd "#8: xargs rm asks" "git ls-files .github | xargs rm -f" ask
bash_cmd "#8: find -exec sed -i asks" "find .github -name '*.yml' -exec sed -i s/a/b/ {} +" ask
bash_cmd "#8: find -delete of the tree asks" "find . -delete" ask "the whole repository"
bash_cmd "#8: find -name matching a protected file asks" "find . -name 'deny.toml' -delete" ask "deny.toml"
bash_cmd "#8: find -exec writing a suppression into .rs files asks" "find . -name '*.rs' -exec sed -i 's/^fn/#[allow(dead_code)]\\nfn/' {} +" ask "suppression"
bash_cmd "#8: cd then a relative write asks" "cd .github/workflows && sed -i s/a/b/ ci.yml" ask "ci.yml"
bash_cmd "#8: git -C then a relative path asks" "git -C .github checkout -- workflows/ci.yml" ask "ci.yml"
bash_cmd "#8: cp into the root of a protected name asks" "cp /tmp/deny.toml ." ask "deny.toml"
bash_cmd "#8: cp -t into a protected directory asks" "cp -t .github/workflows /tmp/new.yml" ask
bash_cmd "#8: ln with one argument asks" "ln -s /tmp/deny.toml" ask "deny.toml"
bash_cmd "#8: a suppression written to /tmp and moved in asks" \
  $'cat > /tmp/new.rs <<\'EOF\'\n#[allow(dead_code)]\nfn x() {}\nEOF\nmv /tmp/new.rs crates/lib/src/lib.rs' ask "suppression"
bash_cmd "#8: gitleaks:allow written to /tmp and copied in asks" \
  "echo 'k = a # gitleaks:allow' > /tmp/a.ini && cp /tmp/a.ini config.ini" ask "gitleaks:allow"
bash_cmd "#8: gitleaks:allow written outside the repository is silent" "echo 'k = a # gitleaks:allow' > /tmp/a.ini" silent
bash_cmd "#8: git restore --staged . still asks" "git restore --staged ." ask "the whole repository"
bash_cmd "#8: rm -rf app asks for its check config" "rm -rf app" ask "app"
bash_cmd "#8: an unterminated quote falls back to all the words" $'sed -i s/a/b/ deny.toml\necho \'oops' ask "could not be parsed"

# Ways around the parser.
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: git restore . with a variable target elsewhere still names the repository" 'git restore .; out=/tmp/x; echo x > "$out"' ask "the whole repository"
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: a write in \${x:-\$(...)} asks" 'echo "${x:-$(rm .github/workflows/ci.yml)}"' ask
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: a write in \$(( \$(...) )) asks" 'echo $(( $(rm .github/workflows/ci.yml) + 1 ))' ask
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: a write after a case pattern in \$(...) asks" 'echo $(case x in x) rm .github/workflows/ci.yml;; esac)' ask
bash_cmd "#8: a write in a function body asks" "function f { rm .github/workflows/ci.yml; }; f" ask
bash_cmd "#8: a write in a function() body asks" "f() { rm .github/workflows/ci.yml; }; f" ask
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: a target with a literal directory before an expansion asks" 'sed -i s/a/b/ .github/workflows/$(printf ci).yml' ask
mkdir -p "${r}/.github/actions-src"
bash_cmd "#8: cp -r into a directory holding check config asks" "cp -r /tmp/payload/. .github" ask ".github"
bash_cmd "#8: xargs sed -i asks" "git ls-files .github | xargs sed -i s/a/b/" ask
bash_cmd "#8: sudo --user asks" "sudo --user root rm .github/workflows/ci.yml" ask
bash_cmd "#8: timeout --signal asks" "timeout --signal KILL 10 rm .github/workflows/ci.yml" ask
bash_cmd "#8: command rm -v asks" "command rm -v .github/workflows/ci.yml" ask
bash_cmd "#8: command -v is silent" "command -v rm && command -v sed" silent
bash_cmd "#8: env -C asks" "env -C .github rm workflows/ci.yml" ask "ci.yml"
bash_cmd "#8: git -C twice asks" "git -C .github -C workflows checkout -- ci.yml" ask "ci.yml"
bash_cmd "#8: find with ! -name asks" "find .github ! -name '*.orig' -exec rm {} +" ask
bash_cmd "#8: find -iname asks" "find .github -iname 'CI.YML' -exec rm {} +" ask "ci.yml"
bash_cmd "#8: find -exec with an explicit target asks" "find . -name '*.txt' -exec rm .github/workflows/ci.yml {} +" ask
bash_cmd "#8: find -exec sh -c asks" "find . -name '*.txt' -exec sh -c 'rm .github/workflows/ci.yml' sh {} +" ask
bash_cmd "#8: find from a protected file asks" "find .github/workflows/ci.yml -name ci.yml -exec rm {} +" ask
bash_cmd "#8: find -exec sed -i on Cargo.toml asks" "find . -name Cargo.toml -exec sed -i s/a/b/ {} +" ask "a Cargo.toml"
bash_cmd "#8: find -exec sed -i adding gitleaks:allow asks" "find . -name '*.ini' -exec sed -i 's/x/gitleaks:allow/' {} +" ask "gitleaks:allow"
bash_cmd "#8: find -name with -print is silent" "find . -name '*.yml' -print" silent
bash_cmd "#8: a \$'...' heredoc delimiter falls back to all the words" $'cat <<$\'E\\x4fF\'\ntext\nEOF\nrm .github/workflows/ci.yml' ask
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: a cd to a variable with only reads is silent" 'dir=.; cd "$dir"; cat .github/workflows/ci.yml' silent
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: a cd to a variable then a write asks" 'dir=.github; cd "$dir"; rm -f workflows/ci.yml' ask
bash_cmd "#8: bash -n -c is silent" "bash -n -c 'rm .github/workflows/ci.yml'" silent
bash_cmd "#8: truncate --reference is silent" "truncate --reference .github/workflows/ci.yml /tmp/newfile" silent
bash_cmd "#8: busybox sed -i asks" "busybox sed -i 's/deny/allow/' deny.toml" ask
bash_cmd "#8: coproc sed -i asks" "coproc sed -i 's/deny/allow/' deny.toml" ask
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: git -C to a variable then a write asks" 'git -C "$WT" restore -- deny.toml' ask
bash_cmd "#8: env -C then sed -i asks" "env -C .github/workflows sed -i 's/name/x/' ci.yml" ask "ci.yml"
bash_cmd "#8: a string comparison in [[ ]] is silent" "[[ deny.toml > clippy.toml ]] && echo later" silent
bash_cmd "#8: a redirect in [ ] asks" "[ x > deny.toml ]" ask
bash_cmd "#8: git apply of a file may write anything the command names" "git apply /tmp/fix.patch; grep bans deny.toml" ask
bash_cmd "#8: patch from a file asks for what the command names" "patch -p1 < /tmp/fix.patch && cat .github/workflows/ci.yml" ask
bash_cmd "#8: a line continuation before a cp destination asks" $'cp /tmp/evil.toml deny.toml \\\n  && echo ok' ask
bash_cmd "#8: a line continuation after sudo asks" $'sudo \\\n  rm deny.toml' ask
bash_cmd "#8: a line continuation after git asks" $'git \\\n  rm deny.toml' ask
bash_cmd "#8: a line continuation first asks" $'  \\\n  rm deny.toml' ask
bash_cmd "#8: cp into a directory, with the file protected, asks" "cp /tmp/x/rustfmt.toml app/" ask "app/rustfmt.toml"
bash_cmd "#8: cp -t into a directory, with the file protected, asks" "cp -t app /tmp/x/rustfmt.toml" ask "app/rustfmt.toml"
bash_cmd "#8: ln -s into a directory, with the file protected, asks" "ln -s /tmp/x/biome.json app/" ask "app/biome.json"
bash_cmd "#8: a protected file and its directory both written ask" "sed -i 's/deny/allow/' crates/lib/clippy.toml; true 2>/dev/null >crates/lib" ask "crates/lib/clippy.toml"
cdloop="$(for i in $(seq 1 13); do printf '(cd crates/lib && cargo test); cd app; npm test; cd ..; '; done)rm deny.toml"
start=${SECONDS}
bash_cmd "#8: many cd round trips stay fast and still ask" "${cdloop}" ask
((SECONDS - start < 4)) || { echo "FAIL many cd round trips took $((SECONDS - start))s"; failures=$((failures + 1)); }
bash_cmd "#8: xargs perl -i asks" "echo deny.toml | xargs -I% perl -pi -e s/a/b/ %" ask
bash_cmd "#8: xargs git rm asks" "echo deny.toml | xargs git rm" ask
bash_cmd "#8: xargs sed -i adding a suppression asks" "git ls-files '*.rs' | xargs sed -i '1i #![allow(clippy::all)]'" ask
bash_cmd "#8: find -exec sudo rm asks" "find . -name deny.toml -exec sudo rm {} +" ask
bash_cmd "#8: find -exec git rm asks" "find . -name deny.toml -exec git rm {} +" ask
bash_cmd "#8: find -exec cp into a protected directory asks" "find /tmp/evil -name '*.yml' -exec cp {} .github/workflows/ \;" ask
for w in "nix develop -c" "uv run" "mise exec --" "fakeroot" "strace -o /dev/null" "direnv exec ." "busybox"; do
  bash_cmd "#8: rm through ${w} asks" "${w} rm deny.toml" ask
done
bash_cmd "#8: watch runs its command through sh" "watch -n1 'rm deny.toml'" ask
bash_cmd "#8: uv run pytest is silent" "uv run pytest -q tests/" silent
# shellcheck disable=SC2016 # the command text is meant literally.
bash_cmd "#8: rm -rf . with a variable target elsewhere still names the repository" 'rm -rf -- . ; echo "$x" > "$f"' ask "the whole repository"
bash_cmd "#8: (( << )) after while is arithmetic" $'while (( n << 1 )); do :; done\nsed -i s/a/b/ deny.toml' ask
bash_cmd "#8: (( << )) after ! is arithmetic" $'! (( 1 << 2 ))\nrm deny.toml' ask
bash_cmd "#8: (( << )) after if is silent" "if (( 1 << 2 )); then echo yes; fi" silent
bash_cmd "#8: sudo -D asks" "sudo -D .github rm workflows/ci.yml" ask "ci.yml"
bash_cmd "#8: cp -rT onto a directory holding check config asks" "cp -rT /tmp/evil .github" ask ".github"
bash_cmd "#8: find -exec rm on Cargo.toml asks" "find crates -name Cargo.toml -exec rm {} +" ask "a Cargo.toml"
bash_cmd "#8: bash -c -- asks" "bash -c -- 'rm deny.toml'" ask
bash_cmd "#8: bash -O extglob -c asks" "bash -O extglob -c 'rm deny.toml'" ask

# Long commands finish well inside the hook's timeout.
cds="$(for i in $(seq 0 40); do printf 'cd d%d; ' "${i}"; done)true"
start=${SECONDS}
bash_cmd "#8: many cds stay fast" "${cds}" silent
((SECONDS - start < 4)) || { echo "FAIL many cds took $((SECONDS - start))s"; failures=$((failures + 1)); }
# shellcheck disable=SC2016 # the text is meant literally.
big="gh pr create --body-file - <<'EOF'"$'\n'"$(yes 'notes with `code`, $vars and "quotes" about deny.toml' | head -n 2000)"$'\n'"EOF"
start=${SECONDS}
bash_cmd "#8: a 100 kB heredoc stays fast" "${big}" silent
((SECONDS - start < 8)) || { echo "FAIL a 100 kB heredoc took $((SECONDS - start))s"; failures=$((failures + 1)); }
words="echo $(seq -s ' ' 20000) > /tmp/x"
start=${SECONDS}
bash_cmd "#8: a 20000-word command stays fast" "${words}" silent
((SECONDS - start < 8)) || { echo "FAIL a 20000-word command took $((SECONDS - start))s"; failures=$((failures + 1)); }

mkdir -p "${work}/tmpdir"
TMPDIR="${work}/tmpdir" write "a protected Write (for the scratch check)" deny.toml 'x' ask
TMPDIR="${work}/tmpdir" bash_cmd "a Bash command (for the scratch check)" "ls" silent
total=$((total + 1))
if [[ -z "$(ls -A "${work}/tmpdir")" ]]; then echo "ok   the hook leaves no scratch directories"; else
  echo "FAIL the hook left scratch directories: $(ls -A "${work}/tmpdir")"; failures=$((failures + 1)); fi

echo "${total} cases"
if [[ ${failures} -ne 0 ]]; then
  echo "${failures} failed"
  exit 1
fi
echo "all passed"
