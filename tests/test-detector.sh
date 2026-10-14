#!/usr/bin/env bash
# Tests check-weakened.sh in throwaway repositories: the annotation rules in
# each language, the Svelte fallback, the diff rules, the config and its
# prohibitions, the exceptions file, and one case per historical gap in the
# scripts this detector replaces (GAI-359, GAI-379, GAI-413, GAI-422,
# GAI-480), each as the diff it should catch.
#
# Requires: what check-weakened.sh needs (ast-grep is fetched if missing).
set -euo pipefail

# shellcheck disable=SC2046 # one variable name per word.
unset $(git rev-parse --local-env-vars)
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PR_BODY WEAKENED_CHECKS_CONFIG

script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/check-weakened.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
out=""

# A fresh repository on main with one commit, and a branch "pr" to change.
fresh() {
  rm -rf "$tmp/repo" && mkdir -p "$tmp/repo" && cd "$tmp/repo"
  git init -q -b main
  git config user.name test && git config user.email test@example.invalid
  git config commit.gpgsign false
  echo '# x' >README.md
  git add -A && git commit -qm base && git checkout -qb pr
}
# Writes FILE with CONTENT (printf %b) on main, then returns to pr from it.
on_main() {
  git checkout -q main
  mkdir -p "$(dirname "$1")"
  printf '%b' "$2" >"$1"
  git add -A && git commit -qm "main: $1"
  git checkout -q -B pr main
}
put() { mkdir -p "$(dirname "$1")" && printf '%b' "$2" >"$1"; }
commit() { git add -A && git commit -qm change; }
run() { out=$("$script" main pr 2>&1); }

# expect pass|fail NAME [ENV=VALUE...] -- runs the detector on main...pr
expect() {
  local want=$1 name=$2 got
  shift 2
  if out=$(env "$@" "$script" main pr 2>&1); then got=pass; else got=fail; fi
  if [[ $got != "$want" ]]; then
    echo "FAIL: $name: wanted $want, got $got"
    printf '    %s\n' "${out//$'\n'/$'\n'    }"
    fail=1
  fi
}
# has|lacks NAME LINE -- whether the last run printed LINE (a fixed string
# matched against whole lines).
has() {
  if ! grep -qxF -- "$2" <<<"$out"; then
    echo "FAIL: $1: no line: $2"
    printf '    %s\n' "${out//$'\n'/$'\n'    }"
    fail=1
  fi
}
lacks() {
  if grep -qF -- "$2" <<<"$out"; then
    echo "FAIL: $1: reported: $2"
    printf '    %s\n' "${out//$'\n'/$'\n'    }"
    fail=1
  fi
}
explained=PR_BODY=$'Adds a thing.\r\n\r\nCheck changes: the reason.'
unexplained=PR_BODY='Adds a thing.'

# Annotation rules.
fresh; put a.rs '#[doc = "Callers may ignore the result."]\npub fn d() {}\n// no unsafe here\nconst S: &str = "allow(x)";\n'; commit
expect pass "a doc string, a comment and a string naming the rules" "$unexplained"
fresh; on_main a.rs 'fn f() {\n    unsafe {\n        g();\n    }\n}\n'
put a.rs 'fn f() {\n    unsafe {\n        g();\n        h();\n    }\n}\n'; commit
expect pass "a line added inside an existing unsafe block" "$unexplained"
fresh; put a.rs '#[cfg_attr(\n    all(),\n    allow(clippy::pedantic)\n)]\nfn f() {}\n'; commit
expect fail "an allow across several lines of a cfg_attr" "$unexplained"
has "an allow across several lines of a cfg_attr" '  - added: a.rs:1: #[cfg_attr( [rust-allow]'
fresh; put a.rs '#[unsafe(no_mangle)]\npub extern "C" fn f() {}\nunsafe impl Send for X {}\n'; commit
run || true
has "unsafe and no_mangle" '  - added: a.rs:1: #[unsafe(no_mangle)] [rust-no-mangle]'
has "unsafe and no_mangle" '  - added: a.rs:1: #[unsafe(no_mangle)] [rust-unsafe]'
has "unsafe and no_mangle" '  - added: a.rs:3: unsafe impl Send for X {} [rust-unsafe]'
fresh; put x.go 'package x\n\nfunc f() error { return g() } //nolint:errcheck\n'; put x_test.go 'package x\n\nfunc TestF(t *testing.T) {\n\tt.Skip("flaky")\n}\n'; commit
run || true
has "Go" '  - added: x.go:3: func f() error { return g() } //nolint:errcheck [go-nolint]'
has "Go" '  - added: x_test.go:4: t.Skip("flaky") [go-test-skip]'
fresh; put src/a.ts '// @ts-nocheck\n// @ts-expect-error\nconst a = f();\n// @ts-expect-error: the types lag the API\nconst b = g();\nconst c = d as unknown as E;\n'; put src/a.test.ts 'const c = d as unknown as E;\nit.skip("x", () => {});\n'; put src/b.js '// eslint-disable-next-line no-undef\nx();\n'; commit
run || true
has "TypeScript" '  - added: src/a.ts:1: // @ts-nocheck [ts-nocheck]'
has "TypeScript" '  - added: src/a.ts:2: // @ts-expect-error [ts-expect-error]'
lacks "TypeScript" 'a.ts:4:'
has "TypeScript" '  - added: src/a.ts:6: const c = d as unknown as E; [ts-as-unknown]'
lacks "as unknown as in a test file" 'a.test.ts:1:'
has "TypeScript" '  - added: src/a.test.ts:2: it.skip("x", () => {}); [js-test-skip]'
has "JavaScript" '  - added: src/b.js:1: // eslint-disable-next-line no-undef [eslint-disable]'
fresh; put a.py 'x = run()  # nosemgrep: python.lang.x\n'; put tests/test_a.py '@pytest.mark.skip(reason="slow")\ndef test_a():\n    pass\n'; commit
run || true
has "Python" '  - added: a.py:1: x = run()  # nosemgrep: python.lang.x [nosemgrep]'
has "Python" '  - added: tests/test_a.py:1: @pytest.mark.skip(reason="slow") [py-test-skip]'
fresh; put App.svelte '<script lang="ts">\n  // @ts-nocheck\n  const a = b as unknown as C;\n  const s = "x";\n</script>\n\n<!-- svelte-ignore a11y_click_events_have_key_events -->\n<p>// @ts-nocheck in text</p>\n'; commit
run || true
has "Svelte" '  - added: App.svelte:2: // @ts-nocheck [ts-nocheck]'
has "Svelte" '  - added: App.svelte:3: const a = b as unknown as C; [ts-as-unknown]'
has "Svelte" '  - added: App.svelte:7: <!-- svelte-ignore a11y_click_events_have_key_events --> [svelte-ignore]'
lacks "Svelte markup isn't script" 'App.svelte:8:'

# Diff rules.
fresh; on_main t.test.ts 'it("a", () => {});\nit("b", () => {});\n'; put t.test.ts 'it("a", () => {});\n'; commit
expect fail "a TypeScript test removed" "$unexplained"
has "a TypeScript test removed" '  - tests removed: 1 JavaScript or TypeScript tests deleted, 0 added'
fresh; on_main a_test.go 'package a\n\nfunc TestA(t *testing.T) {}\n'; git rm -q a_test.go; commit
expect fail "a Go test file deleted" "$unexplained"
fresh; on_main lib.rs '#[test]\nfn a() {}\n'; git mv lib.rs moved.rs; commit
expect pass "a Rust test moved to another file" "$unexplained"
fresh; on_main testdata/out.golden 'x\n'; put testdata/out.golden 'y\n'; commit
expect fail "a golden file accepted again" "$unexplained"
has "a golden file accepted again" '  - snapshot changed: testdata/out.golden'
fresh; put app/tsconfig.json '{"compilerOptions": {"strict": false}}\n'; commit
expect fail "a tsconfig, by the built-in check config" "$unexplained"
expect pass "a tsconfig, explained" "$explained"
fresh; put docs/x.md 'x\n'; commit
expect pass "no code changed: ast-grep isn't needed" "$unexplained" AST_GREP=/nonexistent

# The config, read from the base.
conf='prohibit ts-nocheck clinical/*\nprohibit nosemgrep clinical/*\nprohibit tests-removed clinical/*\n'
fresh; on_main .github/weakened-checks.conf "$conf"
put clinical/dose.ts '// @ts-nocheck\nexport const x = 1;\n'; put other/dose.ts '// @ts-nocheck\n'; commit
expect fail "a prohibited finding with a Check changes: line" "$explained"
has "a prohibited finding with a Check changes: line" '  - added: clinical/dose.ts:1: // @ts-nocheck [ts-nocheck]'
has "the same finding elsewhere is advisory" '  - added: other/dose.ts:1: // @ts-nocheck [ts-nocheck]'
expect fail "a prohibited finding, run locally" PR_BODY_UNSET=1
put .github/weakened-checks-exceptions '# rule pattern reason\nts-nocheck clinical/dose.ts generated from the schema; GAI-0 types it\n'; commit
expect fail "an exception, unexplained" "$unexplained"
has "an exception" '  - added: clinical/dose.ts:1: // @ts-nocheck [ts-nocheck] (prohibited in clinical/*; allowed by .github/weakened-checks-exceptions: generated from the schema; GAI-0 types it)'
has "the exceptions file is check config" '  - check config changed: .github/weakened-checks-exceptions'
expect pass "an exception, explained" "$explained"
fresh; on_main .github/weakened-checks.conf "$conf"
put .github/weakened-checks.conf '\n'; put clinical/a.py 'x = 1  # nosemgrep\n'; commit
expect fail "a branch dropping a prohibition is still held to it" "$explained"
has "the config is check config" '  - check config changed: .github/weakened-checks.conf'
fresh; put .github/weakened-checks.conf 'prohibit ts-nocheck *\n'; put a.ts '// @ts-nocheck\n'; commit
expect fail "a config new in the branch applies" "$explained"
fresh; on_main .github/weakened-checks.conf "$conf"
put .github/weakened-checks-exceptions 'ts-nocheck clinical/*\n'; commit
expect fail "an exception without a reason" "$explained"
grep -q 'an exception needs a reason' <<<"$out" || { echo "FAIL: no reason, no error: $out"; fail=1; }
fresh; on_main clinical/a.test.ts 'it("a", f);\nit("b", f);\n'
on_main .github/weakened-checks.conf "$conf"
put clinical/a.test.ts 'it("a", f);\n'; commit
expect fail "a test removed in a prohibited path" "$explained"
has "a test removed in a prohibited path" '  - tests removed in clinical/*: 1 deleted, 0 added'
fresh; on_main clinical/a.test.ts 'it("a", f);\nit("b", f);\n'
on_main .github/weakened-checks.conf "$conf"
put clinical/a.test.ts 'it("a", f);\n'; put clinical/b.test.ts 'it("b", f);\n'; commit
expect pass "a test moved within a prohibited path" "$explained"
fresh; on_main .github/weakened-checks.conf 'prohibit no-such-rule x\n'; put a.ts '\n'; commit
expect fail "a config naming an unknown rule" "$explained"
fresh; on_main .github/weakened-checks.conf 'config-path @defaults extra.cfg\ndisable ts-nocheck\n'
put extra.cfg 'x\n'; put .github/workflows/ci.yml 'x\n'; put a.ts '// @ts-nocheck\n'; commit
run || true
has "config-path @defaults extends the built-in list" '  - check config changed: extra.cfg'
has "config-path @defaults extends the built-in list" '  - check config changed: .github/workflows/ci.yml'
lacks "a disabled rule" 'ts-nocheck'
fresh
if "$script" --config missing.conf main pr >/dev/null 2>&1; then
  echo "FAIL: --config naming a missing file passed"; fail=1
fi

# The historical gaps, each the diff it should have caught.
# GAI-359: a crash test's loss limit loosened (in the nota suite too).
fresh; on_main crates/a/src/tests.rs 'const LOSS_LIMIT: usize = 4; // check-bound\n'
put crates/a/src/tests.rs 'const LOSS_LIMIT: usize = 40; // check-bound\n'; commit
expect fail "GAI-359: a loosened loss limit" "$unexplained"
has "GAI-359" '  - bound set: crates/a/src/tests.rs: const LOSS_LIMIT: usize = 40; // check-bound'
# GAI-379: a sweep's coverage floor lowered, and a harness script's floor.
fresh; on_main tests.rs 'fn s(summary: S) {\n    assert!(summary.scenario_ops > 150, "{summary:?}"); // check-bound\n}\n'
on_main crash.sh 'min_rows=20 # check-bound\n'
put tests.rs 'fn s(summary: S) {\n    assert!(summary.scenario_ops > 1, "{summary:?}"); // check-bound\n}\n'; put crash.sh 'min_rows=0 # check-bound\n'; commit
expect fail "GAI-379: lowered coverage floors" "$unexplained"
has "GAI-379" '  - bound was: tests.rs: assert!(summary.scenario_ops > 150, "{summary:?}"); // check-bound'
has "GAI-379" '  - bound set: crash.sh: min_rows=0 # check-bound'
# GAI-413: a floor's tag moved onto a comment line of its own (the floor is
# then untagged), and a kind dropped from the tagged list a sweep must reach.
fresh; on_main disk_full.rs 'fn s() {\n    sweep.interrupted_at_least(ops - 1); // check-bound\n    let kinds = [Write, Sync, Rename]; // check-bound\n}\n'
put disk_full.rs 'fn s() {\n    // check-bound\n    sweep.interrupted_at_least(1);\n    let kinds = [Write, Sync]; // check-bound\n}\n'; commit
expect fail "GAI-413: an untagged floor, a dropped kind" "$unexplained"
has "GAI-413" '  - bound was: disk_full.rs: sweep.interrupted_at_least(ops - 1); // check-bound'
has "GAI-413" '  - bound was: disk_full.rs: let kinds = [Write, Sync, Rename]; // check-bound'
# GAI-422: a crash sweep's floor deleted, so the sweep can pass having
# reached nothing.
fresh; on_main journal.rs 'fn s() {\n    for at in 0..ops {\n        fs.crash_after(at);\n        sweep.crash_point(&fs);\n    }\n    sweep.interrupted_more_than(ops / 2); // check-bound\n}\n'
put journal.rs 'fn s() {\n    for at in 0..ops {\n        fs.crash_after(at);\n        sweep.crash_point(&fs);\n    }\n}\n'; commit
expect fail "GAI-422: a sweep's floor deleted" "$unexplained"
has "GAI-422" '  - bound was: journal.rs: sweep.interrupted_more_than(ops / 2); // check-bound'
# GAI-480: the soak analyser's limits, in Python: the quantile judged and the
# highest lag allowed.
fresh; on_main scripts/soak-analyse.py 'LAG_QUANTILE = 0.99  # check-bound\nMAX_LAG_S = 3.0  # check-bound\n'
put scripts/soak-analyse.py 'LAG_QUANTILE = 0.5  # check-bound\n'; commit
expect fail "GAI-480: the soak's limits loosened" "$unexplained"
has "GAI-480" '  - bound set: scripts/soak-analyse.py: LAG_QUANTILE = 0.5  # check-bound'
has "GAI-480" '  - bound was: scripts/soak-analyse.py: MAX_LAG_S = 3.0  # check-bound'

if (( fail )); then exit 1; fi
echo "test-detector: all cases pass"
