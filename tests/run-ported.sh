#!/usr/bin/env bash
# Runs the check-weakened.sh suites ported from nota and conspector
# (tests/ported/), unchanged, against this repository's detector. Each suite
# calls scripts/check-weakened.sh beside itself; here that is a shim running
# check-weakened.sh with the project's config from examples/.
#
# nota's suite also checks nota's own tree (that its bounds carry the tag),
# so it runs in a copy of nota's layout: the vendored suite and the shim in
# scripts/, beside links to a nota checkout's crates/ and the scripts it
# reads. The checkout is $NOTA_DIR, or else a fetch of gaius-codius/nota at
# the commit the suite was vendored from ($nota_commit). conspector is
# private, so its suite is the excerpt in tests/ported/conspector, which
# needs nothing else.
#
# Usage: run-ported.sh [nota|conspector]...   (both by default)
# With NOTA_DIR or CONSPECTOR_DIR set, also checks the vendored copy still
# matches that checkout (tests/ported/extract.sh), at NOTA_REF or
# CONSPECTOR_REF (default HEAD).
#
# Requires: what check-weakened.sh needs, and network access to fetch nota
# when NOTA_DIR isn't set.
set -euo pipefail

# The nota commit tests/ported/nota/check-weakened.test.sh was taken from.
nota_commit=e7c24f9b461f15226c0f7e93ce6022823324f0e7

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0

shim() { # dir, config
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\nexec %q --config %q "$@"\n' "$root/check-weakened.sh" "$2" \
    >"$1/check-weakened.sh"
  chmod +x "$1/check-weakened.sh"
}
drift() { # project, checkout, ref, vendored file
  if ! "$root/tests/ported/extract.sh" "$1" "$2" "$3" | cmp -s - "$4"; then
    echo "run-ported: $4 no longer matches $1 at $3; refresh it with tests/ported/extract.sh" >&2
    status=1
  fi
}

run_nota() {
  local nota=${NOTA_DIR:-}
  if [[ -z $nota ]]; then
    nota=$work/nota-src
    git init -q "$nota"
    git -C "$nota" fetch -q --depth 1 https://github.com/gaius-codius/nota "$nota_commit"
    git -C "$nota" checkout -q FETCH_HEAD
    drift nota "$nota" HEAD "$root/tests/ported/nota/check-weakened.test.sh"
  else
    drift nota "$nota" "${NOTA_REF:-HEAD}" "$root/tests/ported/nota/check-weakened.test.sh"
  fi
  local layout=$work/nota
  shim "$layout/scripts" "$root/examples/nota.conf"
  cp "$root/tests/ported/nota/check-weakened.test.sh" "$layout/scripts/"
  ln -s "$(cd "$nota" && pwd)/crates" "$layout/crates"
  local f
  for f in soak-analyse.py real-capture-crash.sh; do
    ln -s "$(cd "$nota" && pwd)/scripts/$f" "$layout/scripts/$f"
  done
  echo "== nota: scripts/check-weakened.test.sh"
  if "$layout/scripts/check-weakened.test.sh"; then
    echo "nota: all cases pass"
  else
    echo "nota: FAILED" >&2
    status=1
  fi
}

run_conspector() {
  if [[ -n ${CONSPECTOR_DIR:-} ]]; then
    drift conspector "$CONSPECTOR_DIR" "${CONSPECTOR_REF:-HEAD}" \
      "$root/tests/ported/conspector/check-weakened.cases.sh"
  fi
  local dir=$work/conspector
  shim "$dir" "$root/examples/conspector.conf"
  cp "$root/tests/ported/conspector/check-weakened.cases.sh" "$dir/"
  echo "== conspector: the check-weakened.sh cases of scripts/check-scripts.test.sh"
  if "$dir/check-weakened.cases.sh"; then
    echo "conspector: all cases pass"
  else
    echo "conspector: FAILED" >&2
    status=1
  fi
}

[[ $# -gt 0 ]] || set -- nota conspector
for suite in "$@"; do
  case $suite in
    nota) run_nota ;;
    conspector) run_conspector ;;
    *) echo "usage: run-ported.sh [nota|conspector]..." >&2; exit 2 ;;
  esac
done
exit "$status"
