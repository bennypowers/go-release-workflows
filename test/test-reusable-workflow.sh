#!/usr/bin/env bash
set -uo pipefail

# Integration checks for the cross-repository license-lint workflow.
#
# A reusable workflow runs in the caller's checkout, so a relative
# `./.github/actions/...` reference points at the caller, where the action does
# not exist. These tests assert the workflow references the action by its full
# repository path, pin its third-party actions, and that the action runs from a
# separate repository layout with the consumer's directory as the working
# directory. No GitHub Actions runner (or second real repository) is available
# here, so the second layout is simulated: the action is "fetched" into its own
# directory and executed against a consumer checkout that has no action tree.
#
# Run: bash test/test-reusable-workflow.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/license-lint.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq is required for reusable-workflow tests" >&2
  exit 0
fi

# 1. The lint step uses the action by full repository path plus major tag.
uses=$(yq -r '.jobs["license-lint"].steps[] | select(.name == "Lint license compliance") | .uses' "$WORKFLOW")
if [[ "$uses" =~ ^bennypowers/go-release-workflows/\.github/actions/license-lint@v[0-9]+$ ]]; then
  pass
else
  fail "lint step must use the full action path with a major tag, got: '$uses'"
fi

# 2. No step in the reusable workflow uses a caller-relative action path.
relative=$(yq -r '.jobs[].steps[]? | .uses // ""' "$WORKFLOW" | grep -E '^\./' || true)
if [[ -z "$relative" ]]; then
  pass
else
  fail "reusable workflow must not use caller-relative action paths: $relative"
fi

# 3. Third-party actions are pinned by commit SHA. The self-reference keeps a
# major tag, which the finding permits and which tracks the workflow version.
unpinned=$(yq -r '.jobs[].steps[]? | .uses // ""' "$WORKFLOW" |
  grep -v '^bennypowers/go-release-workflows/' |
  grep -Ev '@[0-9a-f]{40}$' || true)
if [[ -z "$unpinned" ]]; then
  pass
else
  fail "third-party actions must be pinned by full SHA: $unpinned"
fi

# 4. Simulate a second repository: the caller checks out its own project, not
# this repository, so there is no local action tree to resolve.
CONSUMER="$WORK/consumer"
mkdir -p "$CONSUMER/.github/workflows" "$CONSUMER/npm"
printf 'MIT License\n' > "$CONSUMER/LICENSE"
printf '{"name":"@scope/app","version":"1.0.0","license":"MIT"}\n' > "$CONSUMER/npm/package.json"
printf 'auto\n' > "$CONSUMER/npm/.packlist-auto"
cat > "$CONSUMER/.github/workflows/ci.yml" <<'YAML'
name: CI
on: [pull_request]
jobs:
  license-lint:
    uses: bennypowers/go-release-workflows/.github/workflows/license-lint.yml@v2
    with:
      npm-dir: npm
YAML

if [[ ! -e "$CONSUMER/.github/actions/license-lint" ]]; then
  pass
else
  fail "the simulated consumer must not contain the action tree"
fi

# "Fetch" the action into its own repository checkout, as GitHub does for a
# cross-repository action reference.
ACTION_REPO="$WORK/action-repo"
mkdir -p "$ACTION_REPO/.github"
cp -R "$ROOT/.github/actions" "$ACTION_REPO/.github/actions"

# A fake npm that lists the files actually present, so a missing staged license
# is visible.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/npm" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "pack" ]] || { echo "npm error: only pack supported" >&2; exit 1; }
shift
json=0
for arg in "$@"; do
  case "$arg" in
    --dry-run | --ignore-scripts) ;;
    --json) json=1 ;;
    *) echo "npm error: unknown option: $arg" >&2; exit 1 ;;
  esac
done
[[ "$json" -eq 1 ]] || exit 0
json_out='[{"files":['
first=1
while IFS= read -r -d '' path; do
  path=${path#./}
  [[ "$path" == .* ]] && continue
  [[ -f "$path" ]] || continue
  [[ $first -eq 1 ]] || json_out+=','
  first=0
  json_out+="{\"path\":\"$path\"}"
done < <(find . -mindepth 1 -maxdepth 1 -print0)
json_out+=']}]'
printf '%s\n' "$json_out"
FAKE
chmod +x "$WORK/bin/npm"

: > "$CONSUMER/output"
(
  cd -- "$CONSUMER" || exit 1
  PATH="$WORK/bin:$PATH" GITHUB_OUTPUT="$CONSUMER/output" \
    bash "$ACTION_REPO/.github/actions/license-lint/license-lint.sh" npm "" "" platforms auto
) > "$CONSUMER/stdout" 2> "$CONSUMER/stderr"
status=$?
if [[ $status -eq 0 ]] && grep -qx 'license-file=LICENSE' "$CONSUMER/output"; then
  pass
else
  fail "the action must run from a second repository layout (status=$status err=$(cat "$CONSUMER/stderr"))"
fi

echo "reusable-workflow: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
