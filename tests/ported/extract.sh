#!/usr/bin/env bash
# Prints the ported suites' fixtures from the sources they came from, so
# tests/run-ported.sh --check can tell whether a vendored copy has drifted.
#
# Usage: extract.sh nota|conspector CHECKOUT [REF]
# REF (default HEAD) is the commit of CHECKOUT to read.
#
# nota's scripts/check-weakened.test.sh is copied whole. conspector's cases
# live in scripts/check-scripts.test.sh beside the tests of its other scripts
# (and conspector is private), so only its harness (from `set -euo pipefail`
# up to "# check-files.sh"), its check-weakened.sh section (up to
# "# install-units.sh") and its last two lines are taken, each unchanged.
set -euo pipefail

[[ $# -ge 2 && $# -le 3 ]] || set -- usage
show() { git -C "$checkout" show "$ref:$1"; }
checkout=${2:-} ref=${3:-HEAD}
case $1 in
  nota) show scripts/check-weakened.test.sh ;;
  conspector)
    src=$(show scripts/check-scripts.test.sh)
    cat <<'HEADER'
#!/usr/bin/env bash
# conspector's check-weakened.sh cases, from its scripts/check-scripts.test.sh:
# the harness, the "# check-weakened.sh" section and the closing lines, each
# unchanged (tests/ported/extract.sh). tests/run-ported.sh runs them against
# this repository's detector.
HEADER
    awk '/^set -euo pipefail$/ { on = 1 } /^# check-files\.sh$/ { on = 0 } on' <<<"$src"
    awk '/^# check-weakened\.sh$/ { on = 1 } /^# install-units\.sh$/ { on = 0 } on' <<<"$src"
    tail -n 2 <<<"$src"
    ;;
  *)
    echo "usage: extract.sh nota|conspector CHECKOUT [REF]" >&2
    exit 2
    ;;
esac
