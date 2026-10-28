#!/usr/bin/env bash
set -uo pipefail

# Structural tests for .github/workflows/npm-publish.yml.
#
# The main package's license checks must run before any package is published.
# npm cannot republish a version, so a license failure discovered in
# publish-main after the six platform packages already went out leaves the
# release half-published and unrecoverable. These tests fail if the preflight
# job disappears, if publish-platforms stops depending on it, or if the
# packlist check drifts back into inline scripts.
#
# Run: bash test/test-npm-publish-order.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/npm-publish.yml"

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq is required for workflow structure tests" >&2
  exit 0
fi

# job_needs <job>
# Prints one need per line, accepting both the string and list YAML forms.
job_needs() {
  yq -r ".jobs.\"$1\".needs | select(tag == \"!!seq\") | .[]" "$WORKFLOW"
  yq -r ".jobs.\"$1\".needs | select(tag == \"!!str\")" "$WORKFLOW"
}

# job_uses <job>
job_uses() {
  yq -r ".jobs.\"$1\".steps[] | .uses // \"\"" "$WORKFLOW"
}

# job_runs <job>
job_runs() {
  yq -r ".jobs.\"$1\".steps[] | .run // \"\"" "$WORKFLOW"
}

# 1. The preflight job exists.
preflight=$(yq -r '.jobs["preflight-license"].name // ""' "$WORKFLOW")
if [[ -n "$preflight" ]]; then
  pass
else
  fail "npm-publish must define a preflight-license job that validates before publishing"
fi

# 2. The preflight runs after license detection and before the platform matrix.
if job_needs preflight-license | grep -qx 'detect-license'; then
  pass
else
  fail "preflight-license must run after detect-license"
fi

# 3. The preflight stages the license with the shared action, so resolution
#    precedence and symlink handling match publish-main.
if job_uses preflight-license | grep -q '/stage-license@'; then
  pass
else
  fail "preflight-license must use the shared stage-license action"
fi

# 4. The preflight runs the shared tarball check, not an inline copy.
if job_uses preflight-license | grep -q '/verify-license-pack@'; then
  pass
else
  fail "preflight-license must use the shared verify-license-pack action"
fi

# 5. The preflight validates only; it never publishes.
if ! job_uses preflight-license | grep -q '/npm-publish@' &&
  ! job_runs preflight-license | grep -qi 'npm publish'; then
  pass
else
  fail "preflight-license must not publish anything"
fi

# 6. publish-platforms depends on the preflight, so no platform package ships
#    before the main package's license is known to be publishable.
if job_needs publish-platforms | grep -qx 'preflight-license' &&
  job_needs publish-platforms | grep -qx 'detect-license'; then
  pass
else
  fail "publish-platforms must need both detect-license and preflight-license"
fi

# 7. publish-main still stages the license: staged files do not carry between
#    jobs, so the preflight cannot replace this step.
if job_uses publish-main | grep -q '/stage-license@'; then
  pass
else
  fail "publish-main must keep its stage-license step"
fi

# 8. publish-main uses the same shared packlist check as the preflight.
if job_uses publish-main | grep -q '/verify-license-pack@'; then
  pass
else
  fail "publish-main must use the shared verify-license-pack action"
fi

# 9. The packlist check lives in the action, not in inline workflow scripts,
#    so the preflight and publish-main cannot drift.
if ! job_runs preflight-license | grep -q 'npm pack' &&
  ! job_runs publish-main | grep -q 'npm pack'; then
  pass
else
  fail "the npm packlist check must be shared, not inlined in the workflow"
fi

echo "npm-publish-order: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
