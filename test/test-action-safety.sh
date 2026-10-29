#!/usr/bin/env bash
set -uo pipefail

# Guards composite actions and workflows against shell injection through
# expression interpolation. GitHub expands ${{ inputs.* }} and ${{ matrix.* }}
# into the run script before bash parses it, so a value containing a quote can
# break out and execute commands. Values belong in env:, referenced as quoted
# shell variables. Lines carrying `# action-safety: ignore` are skipped for
# values that are scripts by design.
#
# Run: bash test/test-action-safety.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
      if (!in_run && line ~ /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/) {
        if (line ~ /# action-safety: ignore/) next
        if (tolower(line) ~ /\$\{\{[[:space:]]*(inputs|matrix)[[:space:]]*[.[]/) {
          printf "%s:%d: run block interpolates inputs or matrix directly: %s\n", FILENAME, NR, line
          bad++
        }
        if (line ~ /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[|>][-+]?[[:space:]]*$/) {
          in_run = 1
          match(line, /run:/)
          run_indent = RSTART - 1
          next
        }
      } else if (in_run && indent(line) > run_indent) {
        if (line ~ /# action-safety: ignore/) next
        if (tolower(line) ~ /\$\{\{[[:space:]]*(inputs|matrix)[[:space:]]*[.[]/) {
          printf "%s:%d: run block interpolates inputs or matrix directly: %s\n", FILENAME, NR, line
          bad++
        }
      }
    }
    END { exit (bad > 0) }
  ' "$file"
}

# Self-check: the scanner must also catch a step written with `run:` as a
# list-item key (`- run: ...`), which is a common YAML shape.
fixture=$(mktemp)
trap 'rm -f "$fixture"' EXIT
cat > "$fixture" <<'EOF'
name: fixture
runs:
  using: composite
  steps:
    - run: echo '${{ inputs.bad }}'
      shell: bash
EOF
if output=$(check_action "$fixture" 2>&1); then
  fail "action-safety: list-item run block interpolation was not detected"
else
  pass
fi

# Self-check: bracket property access must be detected too.
cat > "$fixture" <<'EOF'
name: fixture
runs:
  using: composite
  steps:
    - run: echo "${{ inputs['bad'] }}"
      shell: bash
EOF
if output=$(check_action "$fixture" 2>&1); then
  fail "action-safety: bracket-access inputs interpolation was not detected"
else
  pass
fi

# Self-check: matrix values in a workflow run block must be detected too.
cat > "$fixture" <<'EOF'
name: fixture
jobs:
  build:
    steps:
      - run: make ${{ matrix.platform }}
EOF
if output=$(check_action "$fixture" 2>&1); then
  fail "action-safety: matrix interpolation was not detected"
else
  pass
fi

checked=0
for action in "$ROOT"/.github/actions/*/action.yml; do
  [[ -f "$action" ]] || continue
  checked=$((checked + 1))
  name=$(basename "$(dirname "$action")")
  if output=$(check_action "$action" 2>&1); then
    pass
  else
    fail "$name: inputs or matrix interpolated into run block"
    echo "$output" >&2
  fi
done

for workflow in "$ROOT"/.github/workflows/*.yml; do
  [[ -f "$workflow" ]] || continue
  name="workflows/$(basename "$workflow")"
  if output=$(check_action "$workflow" 2>&1); then
    pass
  else
    fail "$name: inputs or matrix interpolated into run block"
    echo "$output" >&2
  fi
done

# Every script an action invokes through ${{ github.action_path }} is executed
# directly, so it must be tracked as 100755. A 100644 file only fails at
# runtime with "Permission denied". Actions use two forms:
#   "${{ github.action_path }}/x.sh"
#   ACTION_PATH="${{ github.action_path }}"; "${ACTION_PATH}/x.sh"
bad_modes=()
ref_count=0
variable_ref_count=0
check_action_script() {
  local action_dir="$1" ref="$2" script entry mode
  script="$action_dir/$ref"
  entry=$(git -C "$ROOT" ls-files -s -- "$script" 2>/dev/null || true)
  mode=${entry%% *}
  if [[ "$mode" != "100755" || ! -x "$script" ]]; then
    bad_modes+=("${script#"$ROOT"/} (${mode:-not tracked})")
  fi
}
for action in "$ROOT"/.github/actions/*/action.yml; do
  [[ -f "$action" ]] || continue
  action_dir=$(dirname "$action")

  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    ref_count=$((ref_count + 1))
    check_action_script "$action_dir" "$ref"
  done < <(grep -oE '\$\{\{ github\.action_path \}\}/[A-Za-z0-9._/-]+\.sh' "$action" |
    sed 's|.*action_path }}/||')

  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    while IFS= read -r ref; do
      [[ -n "$ref" ]] || continue
      ref_count=$((ref_count + 1))
      variable_ref_count=$((variable_ref_count + 1))
      check_action_script "$action_dir" "$ref"
    done < <(grep -oE '\$\{'"$var"'\}/[A-Za-z0-9._/-]+\.sh' "$action" |
      sed "s|.*${var}}/||")
  done < <(grep -oE '[A-Za-z_][A-Za-z0-9_]*="\$\{\{ github\.action_path \}\}"' "$action" |
    cut -d= -f1 | tr -d '"')
done

if [[ $ref_count -eq 0 ]]; then
  fail "action-safety: no action_path script references were found (vacuous mode check)"
elif [[ $variable_ref_count -eq 0 &&
  -f "$ROOT/.github/actions/validate-build/action.yml" ]]; then
  fail "action-safety: the \${ACTION_PATH}/X.sh form was not detected"
elif [[ ${#bad_modes[@]} -eq 0 ]]; then
  pass
else
  fail "action scripts must be mode 100755 in git and executable on disk: ${bad_modes[*]}"
fi

if [[ $checked -eq 0 ]]; then
  fail "action-safety: no composite action files found under $ROOT/.github/actions"
fi

echo "action-safety: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
