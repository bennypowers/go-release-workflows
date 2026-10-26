#!/usr/bin/env bash
set -uo pipefail

# Guards composite actions against shell injection through expression
# interpolation. GitHub expands ${{ inputs.* }} into the run script before bash
# parses it, so an input containing a quote can break out and execute commands.
# Inputs belong in env:, referenced as quoted shell variables.
#
# Run: bash test/test-action-safety.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

fail() {
  echo "FAIL: $1" >&2
  FAIL=$((FAIL + 1))
}

pass() {
  PASS=$((PASS + 1))
}

# check_action <path>
# Prints offending lines and returns nonzero when a run block interpolates inputs.
check_action() {
  local file="$1"
  awk '
    function indent(s) { match(s, /^[[:space:]]*/); return RLENGTH }
    {
      line = $0
      if (in_run) {
        if (line ~ /^[[:space:]]*$/) next
        if (indent(line) <= run_indent) in_run = 0
      }
      if (!in_run && line ~ /^[[:space:]]*run:[[:space:]]*/) {
        if (line ~ /\$\{\{[[:space:]]*inputs\./) {
          printf "%s:%d: run block interpolates inputs directly: %s\n", FILENAME, NR, line
          bad++
        }
        if (line ~ /^[[:space:]]*run:[[:space:]]*[|>][-+]?[[:space:]]*$/) {
          in_run = 1
          run_indent = indent(line)
          next
        }
      } else if (in_run && indent(line) > run_indent && line ~ /\$\{\{[[:space:]]*inputs\./) {
        printf "%s:%d: run block interpolates inputs directly: %s\n", FILENAME, NR, line
        bad++
      }
    }
    END { exit (bad > 0) }
  ' "$file"
}

for action in "$ROOT"/.github/actions/*/action.yml; do
  [[ -f "$action" ]] || continue
  name=$(basename "$(dirname "$action")")
  if output=$(check_action "$action" 2>&1); then
    pass
  else
    fail "$name: inputs interpolated into run block"
    echo "$output" >&2
  fi
done

echo "action-safety: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
