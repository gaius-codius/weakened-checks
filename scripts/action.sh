#!/usr/bin/env bash
# The action's step: runs check-weakened.sh on the inputs (WC_BASE, WC_HEAD,
# WC_CONFIG, PR_BODY) and copies its report to the job summary.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -z ${WC_BASE:-} || -z ${WC_HEAD:-} ]]; then
  echo "weakened-checks: no base or head; run on pull_request, or pass both inputs" >&2
  exit 2
fi
args=("$WC_BASE" "$WC_HEAD")
# The default path may be absent (built-in defaults); any other must exist.
[[ ${WC_CONFIG:-} == .github/weakened-checks.conf ]] || args+=(--config "$WC_CONFIG")

status=0
"$root/check-weakened.sh" "${args[@]}" >"$RUNNER_TEMP/weakened-checks.txt" 2>&1 || status=$?
cat "$RUNNER_TEMP/weakened-checks.txt"
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  {
    echo "### Weakened checks"
    echo
    echo '```text'
    cat "$RUNNER_TEMP/weakened-checks.txt"
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
fi
exit "$status"
