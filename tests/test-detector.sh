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

# Swift.
fresh; put Sources/App/A.swift '@preconcurrency import Foundation\nfinal class A: Base, @unchecked Sendable {}\nextension B: @unchecked Sendable {}\nextension C: @preconcurrency P {}\nnonisolated(unsafe) var x = 1\nfunc f() {\n    nonisolated(unsafe) let q = makeQ()\n    MainActor.assumeIsolated { g() }\n    _ = unsafeBitCast(a, to: Int.self)\n}\n@MainActor(unsafe) func h() {}\n@_unsafeInheritExecutor func i() async {}\nclass D { unowned(unsafe) var e: E }\n// swift-format-ignore\n// swift-format-ignore-file\nlet y = z // swiftlint:disable:this force_cast\n/* swiftlint:disable all */\n'
put Tests/AppTests/ATests.swift '@Test(.disabled("flaky")) func a() {}\n@Suite(.enabled(if: false)) struct S {}\n@Test func b() { withKnownIssue { try c() } }\nfinal class T: XCTestCase {\n    func testD() throws { throw XCTSkip("slow") }\n    func testE() throws { try XCTSkipIf(true) }\n}\n'; commit
expect fail "Swift" "$unexplained"
has "Swift" '  - added: Sources/App/A.swift:1: @preconcurrency import Foundation [swift-unsafe-isolation]'
has "Swift" '  - added: Sources/App/A.swift:2: final class A: Base, @unchecked Sendable {} [swift-unchecked-sendable]'
has "Swift" '  - added: Sources/App/A.swift:3: extension B: @unchecked Sendable {} [swift-unchecked-sendable]'
has "Swift" '  - added: Sources/App/A.swift:4: extension C: @preconcurrency P {} [swift-unsafe-isolation]'
has "Swift" '  - added: Sources/App/A.swift:5: nonisolated(unsafe) var x = 1 [swift-unsafe-isolation]'
has "Swift" '  - added: Sources/App/A.swift:7: nonisolated(unsafe) let q = makeQ() [swift-unsafe-isolation]'
has "Swift" '  - added: Sources/App/A.swift:8: MainActor.assumeIsolated { g() } [swift-unsafe-isolation]'
has "Swift" '  - added: Sources/App/A.swift:9: _ = unsafeBitCast(a, to: Int.self) [swift-unsafe-isolation]'
has "Swift" '  - added: Sources/App/A.swift:11: @MainActor(unsafe) func h() {} [swift-unsafe-isolation]'
has "Swift" '  - added: Sources/App/A.swift:12: @_unsafeInheritExecutor func i() async {} [swift-unsafe-isolation]'
has "Swift" '  - added: Sources/App/A.swift:13: class D { unowned(unsafe) var e: E } [swift-unsafe-isolation]'
has "Swift" '  - added: Sources/App/A.swift:14: // swift-format-ignore [swift-format-ignore]'
has "Swift" '  - added: Sources/App/A.swift:15: // swift-format-ignore-file [swift-format-ignore]'
has "Swift" '  - added: Sources/App/A.swift:16: let y = z // swiftlint:disable:this force_cast [swiftlint-disable]'
has "Swift" '  - added: Sources/App/A.swift:17: /* swiftlint:disable all */ [swiftlint-disable]'
has "Swift" '  - added: Tests/AppTests/ATests.swift:1: @Test(.disabled("flaky")) func a() {} [swift-test-skip]'
has "Swift" '  - added: Tests/AppTests/ATests.swift:2: @Suite(.enabled(if: false)) struct S {} [swift-test-skip]'
has "Swift" '  - added: Tests/AppTests/ATests.swift:3: @Test func b() { withKnownIssue { try c() } } [swift-test-skip]'
has "Swift" '  - added: Tests/AppTests/ATests.swift:5: func testD() throws { throw XCTSkip("slow") } [swift-test-skip]'
has "Swift" '  - added: Tests/AppTests/ATests.swift:6: func testE() throws { try XCTSkipIf(true) } [swift-test-skip]'
expect pass "Swift, explained" "$explained"
fresh; put Sources/App/S.swift 'let a = "@unchecked Sendable, nonisolated(unsafe), @preconcurrency"\nlet b = "// swiftlint:disable all"\nlet c = """\n// swift-format-ignore\nMainActor.assumeIsolated\n"""\n'; commit
expect pass "Swift: the patterns in string literals" "$unexplained"
fresh; on_main Sources/App/A.swift 'final class A: @unchecked Sendable {\n    var a = 1\n}\n'
put Sources/App/A.swift 'final class A: @unchecked Sendable {\n    var a = 1\n    var b = 2\n}\n'; commit
expect pass "Swift: a line added next to an existing @unchecked Sendable" "$unexplained"
fresh; put Sources/App/V.swift 'struct V: View {\n    var body: some View { Button("Go") {}.disabled(true) }\n}\n'; put Tests/AppTests/VTests.swift 'func check(v: V) { v.button.disabled(true) }\n'; commit
expect pass "Swift: the SwiftUI .disabled modifier" "$unexplained"
fresh; put Sources/App/T.swift '@Test(.disabled("x")) func a() {}\n'; commit
expect pass "Swift: a test trait outside the test files" "$unexplained"
pkg='// swift-tools-version: 6.2\nlet package = Package(\n    name: "App",\n    dependencies: [\n        .package(url: "https://example.invalid/a", from: "1.0.0"),\n    ],\n    targets: [\n        .target(name: "Logic", swiftSettings: [\n            .enableUpcomingFeature("ExistentialAny"),\n            .treatAllWarnings(as: .error),\n        ]),\n    ],\n    swiftLanguageModes: [.v6]\n)\n'
fresh; on_main Package.swift "$pkg"
put Package.swift "${pkg/'            .treatAllWarnings(as: .error),\n'/}"; commit
expect fail "Swift: warnings no longer errors in Package.swift" "$unexplained"
has "Swift: warnings no longer errors in Package.swift" '  - Swift settings changed in a Package.swift: Package.swift'
fresh; on_main app/Package.swift "$pkg"
put app/Package.swift "${pkg/'.v6'/'.v5'}"; commit
expect fail "Swift: the language mode lowered" "$unexplained"
has "Swift: the language mode lowered" '  - Swift settings changed in a Package.swift: app/Package.swift'
fresh; on_main Package.swift "$pkg"
put Package.swift "${pkg/'    ],\n    targets'/'        .package(url: "https://example.invalid/b", from: "2.0.0"),\n    ],\n    targets'}"; commit
expect pass "Swift: a dependency added to Package.swift" "$unexplained"
fresh; on_main Tests/LogicTests/ATests.swift '@Test func a() {}\n@Test("b") func b() {}\n'
put Tests/LogicTests/ATests.swift '@Test func a() {}\n'; commit
expect fail "Swift: a Swift Testing test removed" "$unexplained"
has "Swift: a Swift Testing test removed" '  - tests removed: 1 Swift tests deleted, 0 added'
fresh; on_main LogicTests/ATests.swift 'final class A: XCTestCase {\n    func testA() {}\n    override func testB() async throws {}\n}\n'
git rm -q LogicTests/ATests.swift; commit
expect fail "Swift: an XCTest file deleted" "$unexplained"
has "Swift: an XCTest file deleted" '  - tests removed: 2 Swift tests deleted, 0 added'
fresh; on_main Tests/LogicTests/ATests.swift '@Test func a() {}\n@Test func b() {}\n'
put Tests/LogicTests/ATests.swift '@Test func a() {}\n'; put Tests/LogicTests/BTests.swift '@Test func b() {}\n'; commit
expect pass "Swift: a test moved to another file" "$unexplained"
fresh; on_main src/UnitTests/a.ts 'it("a", f);\nit("b", f);\n'
put src/UnitTests/a.ts 'it("a", f);\n'; commit
expect pass "Swift's test paths don't count JS tests" "$unexplained"

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

# A config entry git rejects as a pathspec is a config error (exit 2), and
# the other entries still match.
exit_code() { # NAME WANT [ENV=VALUE...]
  local name=$1 want=$2 got=0
  shift 2
  out=$(env "$@" "$script" main pr 2>&1) || got=$?
  if [[ $got != "$want" ]]; then
    echo "FAIL: $name: wanted exit $want, got $got"
    printf '    %s\n' "${out//$'\n'/$'\n'    }"
    fail=1
  fi
}
fresh; on_main .github/weakened-checks.conf 'config-path @defaults :(bogus)x extra.cfg\n'
put extra.cfg 'x\n'; put .github/workflows/ci.yml 'x\n'; commit
exit_code "a config-path entry git rejects" 2 "$explained"
has "a config-path entry git rejects" '  - check config changed: extra.cfg'
has "a config-path entry git rejects" '  - check config changed: .github/workflows/ci.yml'
grep -qF ".github/weakened-checks.conf: config-path: git rejects the pathspec :(bogus)x" <<<"$out" ||
  { echo "FAIL: the rejected config-path entry isn't named: $out"; fail=1; }
fresh; on_main a.snap 'x\n'; on_main .github/weakened-checks.conf 'snapshot-path *.snap :(bogus)y\n'
put a.snap 'y\n'; commit
exit_code "a snapshot-path entry git rejects" 2 "$explained"
has "a snapshot-path entry git rejects" '  - snapshot changed: a.snap'
fresh; on_main other.txt 'x\n'; on_main .github/weakened-checks.conf 'snapshot-path :(bogus)y :!vendor/*\n'
put other.txt 'y\n'; commit
exit_code "only an exclude left once the rejected entry goes" 2 "$explained"
lacks "only an exclude left once the rejected entry goes" 'snapshot changed: other.txt'
fresh; on_main Cargo.toml '[workspace.lints.rust]\nunsafe_code = "deny"\n'
on_main .github/weakened-checks.conf 'cargo-members :(bogus)z\n'
put crates/a/Cargo.toml '[package]\nname = "a"\n'; commit
exit_code "a cargo-members pathspec git rejects" 2 "$explained"
grep -qF 'cargo-members: git rejects the pathspec :(bogus)z' <<<"$out" ||
  { echo "FAIL: the rejected cargo-members value isn't named: $out"; fail=1; }
fresh; on_main .github/weakened-checks.conf 'config-path @defaults :(bogus)x\n'
put .github/weakened-checks.conf 'config-path @defaults\n'; commit
exit_code "a branch fixing the base's rejected entry" 0 "$explained"
has "a branch fixing the base's rejected entry" '  - check config changed: .github/weakened-checks.conf'
grep -qF "which this branch's config fixes" <<<"$out" ||
  { echo "FAIL: the base's config error isn't reported: $out"; fail=1; }
fresh; on_main .github/weakened-checks.conf 'config-path @defaults :(bogus)x\n'
git rm -q .github/weakened-checks.conf; commit
exit_code "a branch deleting a config git rejects" 0 "$explained"
for spec in ':(top)*.snap' ':(glob)**/*.snap'; do
  fresh; on_main a.snap 'x\n'; on_main .github/weakened-checks.conf "snapshot-path $spec :(bogus)y\n"
  put a.snap 'y\n'; commit
  exit_code "a positive $spec next to a rejected entry" 2 "$explained"
  has "a positive $spec next to a rejected entry" '  - snapshot changed: a.snap'
done
for spec in ':/!vendor/*' ':(top,exclude)vendor/*'; do
  fresh; on_main other.txt 'x\n'; on_main .github/weakened-checks.conf "snapshot-path :(bogus)y $spec\n"
  put other.txt 'y\n'; commit
  exit_code "only $spec left once the rejected entry goes" 2 "$explained"
  lacks "only $spec left once the rejected entry goes" 'snapshot changed: other.txt'
done
fresh; on_main .github/weakened-checks.conf 'config-path @defaults\n'
put .github/weakened-checks.conf 'config-path @defaults :(bogus)x\n'; commit
exit_code "a branch adding an entry git rejects" 2 "$explained"
grep -qF '.github/weakened-checks.conf at pr: config-path: git rejects the pathspec :(bogus)x' <<<"$out" ||
  { echo "FAIL: the branch's rejected entry isn't named: $out"; fail=1; }
fresh; on_main .github/weakened-checks.conf 'config-path @defaults\n'
put .github/weakened-checks.conf 'config-path @defaults\nno-such-directive x\n'; commit
exit_code "a branch adding an unknown directive" 2 "$explained"
fresh; on_main .github/weakened-checks.conf 'disable snapshot\n'
put .github/weakened-checks.conf 'disable snapshot\nexceptions ../x\n'; commit
exit_code "a branch adding an exceptions path outside the repository" 2 "$explained"
grep -qF 'exceptions: git rejects the path ../x' <<<"$out" ||
  { echo "FAIL: the rejected exceptions path isn't named: $out"; fail=1; }
fresh; on_main .github/weakened-checks.conf 'exceptions ../x\n'; put a.txt 'x\n'; commit
exit_code "a base exceptions path outside the repository" 2 "$explained"
lacks "a config error isn't nothing found" 'nothing found'

# Renames: a test file renamed out of a prohibited pattern, or out of the
# test paths, takes its tests with it.
conf='prohibit tests-removed clinical/*\n'
fresh; on_main clinical/a.test.ts 'it("a", f);\nit("b", f);\n'; on_main .github/weakened-checks.conf "$conf"
mkdir -p other && git mv clinical/a.test.ts other/a.test.ts; commit
expect fail "a test file renamed out of a prohibited path" "$explained"
has "a test file renamed out of a prohibited path" '  - tests removed in clinical/*: 2 deleted, 0 added'
lacks "a rename moves tests, whole-diff" 'JavaScript or TypeScript tests deleted'
fresh; on_main clinical/a.test.ts 'it("a", f);\nit("b", f);\n'; on_main .github/weakened-checks.conf "$conf"
git mv clinical/a.test.ts clinical/b.test.ts; commit
expect pass "a test file renamed within a prohibited path" "$unexplained"
fresh; on_main clinical/lib.rs '#[test]\nfn a() {}\n'; on_main .github/weakened-checks.conf "$conf"
git mv clinical/lib.rs clinical/moved.rs; commit
expect pass "a Rust test file renamed within a prohibited path" "$unexplained"
fresh; on_main other/lib.rs '#[test]\nfn a() {}\n'; on_main .github/weakened-checks.conf "$conf"
mkdir -p clinical && git mv other/lib.rs clinical/lib.rs; commit
expect pass "a Rust test file renamed into a prohibited path" "$unexplained"
fresh; on_main src/a.test.ts 'it("a", f);\nit("b", f);\n'
git mv src/a.test.ts src/a.ts; commit
expect fail "a test file renamed out of the test paths" "$unexplained"
has "a test file renamed out of the test paths" '  - tests removed: 2 JavaScript or TypeScript tests deleted, 0 added'
fresh; on_main snaps/a.snap 'x\nx\nx\nx\nx\n'
git mv snaps/a.snap snaps/b.snap; commit
expect pass "a snapshot renamed unchanged" "$unexplained"
fresh; on_main snaps/a.snap 'x\nx\nx\nx\nx\n'
git mv snaps/a.snap snaps/b.snap; put snaps/b.snap 'x\nx\nx\nx\ny\n'; commit
expect fail "a snapshot renamed and accepted again" "$unexplained"
has "a snapshot renamed and accepted again" '  - snapshot changed: snaps/a.snap -> snaps/b.snap'
fresh; on_main golden/a.snap 'x\nx\nx\nx\nx\n'; on_main .github/weakened-checks.conf 'prohibit snapshot golden/*\n'
mkdir -p other && git mv golden/a.snap other/a.snap; put other/a.snap 'x\nx\nx\nx\ny\n'; commit
expect fail "a snapshot renamed out of a prohibited path and accepted again" "$explained"
fresh; on_main golden/a.snap 'x\n'; on_main .github/weakened-checks.conf 'prohibit snapshot golden/*\n'
mkdir -p other && git mv golden/a.snap other/a.snap; commit
expect fail "a snapshot moved unchanged out of a prohibited path" "$explained"
has "a snapshot moved unchanged out of a prohibited path" '  - snapshot moved out of golden/*: golden/a.snap -> other/a.snap'
fresh; on_main golden/a.snap 'x\n'; on_main .github/weakened-checks.conf 'prohibit snapshot golden/*\n'
git mv golden/a.snap golden/b.snap; commit
expect pass "a snapshot moved unchanged within a prohibited path" "$unexplained"
fresh; on_main 'tests/my dir/a.test.ts' 'it("a", f);\nit("b", f);\n'
put 'tests/my dir/a.test.ts' 'it("a", f);\n'; commit
expect fail "a test removed in a path with a space" "$unexplained"
fresh; on_main tests/a.test.ts 'it("a", f);\nit("b", f);\n'
mkdir -p 'tests/my dir' && git mv tests/a.test.ts 'tests/my dir/a.test.ts'; commit
expect pass "a test file renamed into a path with a space" "$unexplained"
fresh; on_main Cargo.toml '[workspace.lints.rust]\nunsafe_code = "deny"\n'
on_main crates/a/Cargo.toml '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2021"\n\n[lints]\nworkspace = true\n'
mkdir -p crates/b && git mv crates/a/Cargo.toml crates/b/Cargo.toml
put crates/b/Cargo.toml '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2021"\n'; commit
run || true
has "a crate moved without the workspace lints" '  - crate does not inherit the workspace lints: crates/b/Cargo.toml'

fresh; on_main .github/workflows/ci.yml 'a\nb\nc\nd\n'; on_main .github/weakened-checks.conf 'prohibit check-config .github/workflows/*\n'
mkdir -p .husky && git mv .github/workflows/ci.yml .husky/ci.yml; commit
expect fail "a workflow moved out of a prohibited path into another config path" "$explained"
has "a workflow moved out of a prohibited path into another config path" '  - check config changed: .github/workflows/ci.yml'

# Bracket segments in shell patterns match their own text.
fresh; on_main .github/weakened-checks.conf 'prohibit ts-nocheck routes/*\n'
put 'routes/orders/[id]/edit/x.ts' '// @ts-nocheck\n'
put .github/weakened-checks-exceptions 'ts-nocheck routes/orders/[id]/edit/x.ts generated route types\n'; commit
expect pass "an exception for a bracket route segment" "$explained"
has "an exception for a bracket route segment" '  - added: routes/orders/[id]/edit/x.ts:1: // @ts-nocheck [ts-nocheck] (prohibited in routes/*; allowed by .github/weakened-checks-exceptions: generated route types)'
fresh; on_main .github/weakened-checks.conf 'prohibit ts-nocheck routes/[id]/*\n'
put 'routes/[id]/x.ts' '// @ts-nocheck\n'; commit
expect fail "a prohibition on a bracket route segment" "$explained"
fresh; on_main 'routes/[id]/a.test.ts' 'it("a", f);\nit("b", f);\n'
on_main .github/weakened-checks.conf 'prohibit tests-removed routes/[id]/*\n'
put 'routes/[id]/a.test.ts' 'it("a", f);\n'
put .github/weakened-checks-exceptions 'tests-removed routes/[id]/* the route tests moved to e2e\n'; commit
expect pass "a tests-removed exception for a bracket pattern" "$explained"
has "a tests-removed exception for a bracket pattern" '  - tests removed in routes/[id]/*: 1 deleted, 0 added (prohibited; allowed by .github/weakened-checks-exceptions: the route tests moved to e2e)'
fresh; on_main .github/weakened-checks.conf 'test-path routes/[id]/checks/*\n'
put 'routes/[id]/checks/x.ts' 'const c = d as unknown as E;\n'; commit
expect pass "a test-path with a bracket segment" "$unexplained"

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
