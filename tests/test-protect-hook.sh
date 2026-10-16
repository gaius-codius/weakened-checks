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
#   b. docs/CODEOWNERS is not in the detector's built-in list, so writing it is
#      silent here (the Rust hook asked). .lefthook.yaml was covered by that
#      hook's kind() but isn't in the built-in list either: also silent.
#   c. The no-jq PATH also needs mktemp, rm and tr (see the top of the file).
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
write "Write to docs/CODEOWNERS is silent (not in the built-in list)" docs/CODEOWNERS 'x = 1' silent
write "Write to .lefthook.yaml is silent (not in the built-in list)" .lefthook.yaml 'x = 1' silent
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
bash_cmd "sed -i on Cargo.toml dependencies does not ask" "sed -i 's/serde = \"1\"/serde = \"2\"/' Cargo.toml" silent
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
