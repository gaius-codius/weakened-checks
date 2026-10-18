#!/usr/bin/env bash
# Builds the repository CI's actions job runs the action against, in DIR:
# main with a config that prohibits @ts-nocheck under clinical/, a branch
# allowing a Rust lint (advisory) and a branch turning type checking off in
# clinical/ (prohibited). Prints base=, advisory= and prohibited= commit
# lines for $GITHUB_OUTPUT.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: action-fixture.sh DIR" >&2; exit 2; }
mkdir -p "$1" && cd "$1"
git init -q -b main
git config user.name fixture && git config user.email fixture@example.invalid
git config commit.gpgsign false
mkdir -p .github clinical
echo 'prohibit ts-nocheck clinical/*' >.github/weakened-checks.conf
printf 'pub fn f() {}\n' >a.rs
git add -A && git commit -qm base
echo "base=$(git rev-parse HEAD)"
git checkout -qb advisory
printf '#[allow(dead_code)]\npub fn f() {}\n' >a.rs
git commit -qam advisory
echo "advisory=$(git rev-parse HEAD)"
git checkout -q -b prohibited main
printf '// @ts-nocheck\nexport const dose = 1;\n' >clinical/dose.ts
git add -A && git commit -qm prohibited
echo "prohibited=$(git rev-parse HEAD)"
