#!/usr/bin/env bash
# conspector's check-weakened.sh cases, from its scripts/check-scripts.test.sh:
# the harness, the "# check-weakened.sh" section and the closing lines, each
# unchanged (tests/ported/extract.sh). tests/run-ported.sh runs them against
# this repository's detector.
set -euo pipefail

# Run from a git hook, git's own variables (GIT_INDEX_FILE, GIT_DIR) would
# point the test repositories at the real one.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

scripts=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

# A fresh repository on branch main with one commit holding a crate that
# inherits the workspace lints; prints nothing.
fresh() {
  rm -rf "$tmp/repo" && mkdir -p "$tmp/repo/crates/a/src" && cd "$tmp/repo"
  git init -q -b main
  git config user.name test && git config user.email test@example.org
  git config commit.gpgsign false
  printf '[workspace]\nmembers = ["crates/*"]\n\n[workspace.lints.clippy]\npedantic = { level = "warn", priority = -1 }\n' > Cargo.toml
  printf '[package]\nname = "a"\nversion.workspace = true\n\n[lints]\nworkspace = true\n' > crates/a/Cargo.toml
  printf '#[test]\nfn t() {}\n' > crates/a/src/lib.rs
  git add -A && git commit -qm base && git checkout -qb pr
}
commit() { git add -A && git commit -qm change; }

# expect pass|fail NAME COMMAND...
expect() {
  local want=$1 name=$2 got out
  shift 2
  if out=$("$@" 2>&1); then got=pass; else got=fail; fi
  if [[ $got != "$want" ]]; then
    echo "FAIL: $name: wanted $want, got $got"
    printf '    %s\n' "${out//$'\n'/$'\n'    }"
    fail=1
  fi
}
weakened() { PR_BODY='Adds a thing.' "$scripts/check-weakened.sh" main HEAD; }
big() { head -c $((1024 * 1024 + 1)) /dev/zero > "$1"; }

# check-weakened.sh
fresh; echo '# docs' > README.md; commit
expect pass "unrelated change" weakened
expect fail "a base that doesn't exist" "$scripts/check-weakened.sh" no-such-base HEAD
fresh; printf 'disallowed-methods = []\n' > crates/a/clippy.toml; commit
expect fail "a crate's own clippy.toml" weakened
fresh; mkdir .cargo; printf '[build]\nrustflags = ["-Aclippy::all"]\n' > .cargo/config.toml; commit
expect fail ".cargo/config.toml" weakened
fresh; printf '[extend]\nuseDefault = true\n' > .gitleaks.toml; commit
expect fail ".gitleaks.toml" weakened
fresh; mkdir -p crates/b/src; printf '[package]\nname = "b"\nversion.workspace = true\n' > crates/b/Cargo.toml; echo > crates/b/src/lib.rs; commit
expect fail "a new crate without the workspace lints" weakened
fresh; mkdir -p crates/b/src; printf '[package]\nname = "b"\nversion.workspace = true\n\n[lints]\nworkspace = true\n' > crates/b/Cargo.toml; echo > crates/b/src/lib.rs; commit
expect pass "a new crate with the workspace lints" weakened
fresh; git checkout -q main; sed -i 's/^\[lints\]$/[lints] # inherited/' crates/a/Cargo.toml; git commit -qam header; git checkout -q pr; git merge -q --ff-only main
sed -i 's/^version.workspace = true$/version = "0.1.0"/' crates/a/Cargo.toml; commit
expect pass "a commented [lints] header" weakened
fresh; sed -i '/^workspace = true/d' crates/a/Cargo.toml; commit
expect fail "a crate stops inheriting the workspace lints" weakened
fresh; sed -i "s/^pedantic = .*/pedantic = 'allow'/" Cargo.toml; commit
expect fail "a lint level in single quotes" weakened
fresh; { echo '[workspace.metadata]'; for i in $(seq 1 20000); do echo "k$i = 1"; done; } >> Cargo.toml; sed -i 's/level = "warn"/level = "allow"/' Cargo.toml; commit
expect fail "a lint change at the top of a large manifest diff" weakened
fresh; printf '#[cfg_attr(all(), allow(clippy::pedantic, reason = "x"))]\nfn f() {}\n' >> crates/a/src/lib.rs; commit
expect fail "an allow inside a nested cfg_attr" weakened
fresh; printf '#[cfg_attr(unix, ignore)]\n#[test]\nfn u() {}\n' >> crates/a/src/lib.rs; commit
expect fail "a test ignored under cfg_attr" weakened
fresh; printf '#[doc = "Callers may ignore the result."]\npub fn d() {}\n' >> crates/a/src/lib.rs; commit
expect pass "ignore inside a doc string" weakened
fresh; printf '#[test]\n#[ignore = "slow"]\nfn s() {}\n' >> crates/a/src/lib.rs; commit
expect fail "a test ignored with a reason" weakened
fresh; printf '#[rustfmt::skip]\nfn f() {}\n' >> crates/a/src/lib.rs; commit
expect fail "rustfmt::skip" weakened
fresh; printf 'fn f() {}\n' > crates/a/src/lib.rs; commit
expect fail "a test removed" weakened
fresh; printf '#[allow(dead_code)]\nfn f() {}\n' >> crates/a/src/lib.rs; commit
expect fail "an allow, no explanation" weakened
expect pass "an allow, explained" env PR_BODY=$'Adds f.\n\nCheck changes: f is kept for later.' "$scripts/check-weakened.sh" main HEAD
fresh; mkdir systemd; echo 'NoNewPrivileges=no' > systemd/csp@.service.in; commit
expect fail "a unit template" weakened
fresh; mkdir scripts; printf '#!/bin/sh\n' > scripts/install-units.sh; commit
expect fail "the script that renders the units" weakened
fresh; mkdir scripts; printf '#!/bin/sh\nexec "$@"\n' > scripts/without-git-env.sh; commit
expect fail "the wrapper lefthook runs the checks through" weakened
fresh; mkdir scripts; printf '#!/bin/sh\n' > scripts/other.sh; commit
expect pass "another script" weakened
fresh; echo '# docs' > README.md; commit; git checkout -q main; printf 'disallowed-methods = []\n' > clippy.toml; printf 'fn f() {}\n' > crates/a/src/lib.rs; git add -A; git commit -qm main-moves; git checkout -q pr
expect pass "changes made on main after the branch left it" weakened

if (( fail )); then exit 1; fi
echo "check-scripts: all cases pass"
