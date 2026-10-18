#!/usr/bin/env bash
# Prints the ported suite from the source it came from, so
# tests/run-ported.sh can tell whether the vendored copy has drifted.
#
# Usage: extract.sh nota CHECKOUT [REF]
# REF (default HEAD) is the commit of CHECKOUT to read.
#
# nota's scripts/check-weakened.test.sh is copied whole.
set -euo pipefail

[[ $# -ge 2 && $# -le 3 ]] || set -- usage
show() { git -C "$checkout" show "$ref:$1"; }
checkout=${2:-} ref=${3:-HEAD}
case $1 in
  nota) show scripts/check-weakened.test.sh ;;
  *)
    echo "usage: extract.sh nota CHECKOUT [REF]" >&2
    exit 2
    ;;
esac
