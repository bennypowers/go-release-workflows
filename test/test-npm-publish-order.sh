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
VERIFY="$ROOT/.github/actions/verify-license-pack/verify-license-pack.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# job_steps <job>
# Prints one identity per step, in order: the step name when it has one, else
# its uses reference. Unlike job_runs and job_uses, this preserves the relative
# order of heterogeneous steps.
job_steps() {
  yq -r ".jobs.\"$1\".steps[] | (.name // .uses // \"\")" "$WORKFLOW"
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

# 10. The preflight must run the caller's pre-publish script, and before the
#     packlist check, because that script can rewrite package.json files.
preflight_script_line=$(job_runs preflight-license | grep -n -F 'inputs.pre-main-publish-script' | cut -d: -f1)
preflight_verify_line=$(job_uses preflight-license | grep -n -F 'verify-license-pack' | cut -d: -f1)
main_has_script=$(job_runs publish-main | grep -c -F 'inputs.pre-main-publish-script')
if [[ -n "$preflight_script_line" && -n "$preflight_verify_line" ]] &&
  [[ "$preflight_script_line" -lt "$preflight_verify_line" ]] &&
  [[ "$main_has_script" -eq 1 ]]; then
  pass
else
  fail "preflight-license must run pre-main-publish-script before verify-license-pack, and publish-main must still run it"
fi

# 10b. The preflight must mirror publish-main's version update, after the
#      pre-publish script and before the packlist check. `npm version` runs the
#      package's version lifecycle script, which can delete the license or drop
#      a custom license name from files; validating before it would pass a
#      package that publish-main then rejects after the platforms shipped.
preflight_steps=$(job_steps preflight-license)
stage_step_line=$(grep -n -F 'stage-license@' <<<"$preflight_steps" | cut -d: -f1)
script_step_line=$(grep -n -F 'Run pre-publish script' <<<"$preflight_steps" | cut -d: -f1)
version_step_line=$(grep -n -F 'Update version' <<<"$preflight_steps" | cut -d: -f1)
verify_step_line=$(grep -n -F 'verify-license-pack@' <<<"$preflight_steps" | cut -d: -f1)
preflight_runs=$(job_runs preflight-license)
if [[ -n "$stage_step_line" && -n "$script_step_line" &&
  -n "$version_step_line" && -n "$verify_step_line" ]] &&
  [[ "$stage_step_line" -lt "$script_step_line" ]] &&
  [[ "$script_step_line" -lt "$version_step_line" ]] &&
  [[ "$version_step_line" -lt "$verify_step_line" ]] &&
  grep -qF 'npm version' <<<"$preflight_runs" &&
  grep -qF -- '--no-git-tag-version --allow-same-version' <<<"$preflight_runs"; then
  pass
else
  fail "preflight-license must order stage-license, pre-main-publish-script, npm version, verify-license-pack (got: $(tr '\n' '|' <<<"$preflight_steps"))"
fi

# Behavioral tests share one helper. They use real npm because the whole point
# is npm's lifecycle behavior; a fake would have to reimplement prepublishOnly,
# prepack, prepare, and --ignore-scripts, which is exactly what can drift.
# run_verify <case-dir> [npm-dir] [license-file]
run_verify() {
  local dir="$1" npm_dir="${2:-npm}" license_file="${3:-LICENSE}"
  (
    cd "$dir" || exit 1
    bash "$VERIFY" "$npm_dir" "$license_file"
  ) >"$dir/verify.out" 2>"$dir/verify.err"
  VERIFY_STATUS=$?
}

# make_verify_pkg <case-dir> <name> <json-scripts>
make_verify_pkg() {
  local dir="$1" name="$2" scripts="$3"
  mkdir -p "$dir/npm"
  printf 'MIT License\n' >"$dir/npm/LICENSE"
  printf 'module.exports = 1\n' >"$dir/npm/index.js"
  cat >"$dir/npm/package.json" <<EOF
{"name":"$name","version":"1.0.0","license":"MIT","files":["index.js","LICENSE"],"scripts":$scripts}
EOF
}

if ! command -v npm >/dev/null 2>&1; then
  echo "SKIP: npm is required for lifecycle tests" >&2
  pass
else
  # 11. A prepack script that deletes the license must fail: npm publish would
  #     pack the post-script tree, not the tree the old --ignore-scripts check
  #     inspected.
  make_verify_pkg "$WORK/prepack" "@scope/prepack" '{"prepack":"rm -f LICENSE"}'
  run_verify "$WORK/prepack"
  if [[ $VERIFY_STATUS -ne 0 ]] &&
    grep -q 'missing from the main package tarball' "$WORK/prepack/verify.err"; then
    pass
  else
    fail "a prepack script that deletes the license must fail verification (status=$VERIFY_STATUS err=$(cat "$WORK/prepack/verify.err"))"
  fi

  # 12. prepublishOnly runs on publish but not on pack; the check must match
  #     publish and catch this too.
  make_verify_pkg "$WORK/prepublish-only" "@scope/prepublish-only" '{"prepublishOnly":"rm -f LICENSE"}'
  run_verify "$WORK/prepublish-only"
  if [[ $VERIFY_STATUS -ne 0 ]] &&
    grep -q 'missing from the main package tarball' "$WORK/prepublish-only/verify.err"; then
    pass
  else
    fail "a prepublishOnly script that deletes the license must fail verification (status=$VERIFY_STATUS err=$(cat "$WORK/prepublish-only/verify.err"))"
  fi

  # 13. Lifecycle scripts may write to stdout; the JSON extraction must still
  #     find npm's packlist and pass.
  make_verify_pkg "$WORK/noisy" "@scope/noisy" '{"prepack":"echo script-output; echo script-warning >&2"}'
  run_verify "$WORK/noisy"
  if [[ $VERIFY_STATUS -eq 0 ]] &&
    grep -q 'includes LICENSE' "$WORK/noisy/verify.err" &&
    grep -q 'script-warning' "$WORK/noisy/verify.err" &&
    ! grep -q '::warning::' "$WORK/noisy/verify.err" &&
    ! grep -q 'npm notice' "$WORK/noisy/verify.err"; then
    pass
  else
    fail "noisy lifecycle output must parse, surface script warnings plainly, and not annotate npm notices (status=$VERIFY_STATUS err=$(cat "$WORK/noisy/verify.err"))"
  fi

  # 14. A pre-main-publish-script that drops a custom license name from the
  #     files list must fail the check that runs after it in the preflight.
  #     LICENSE is auto-included by npm, so use a name that only ships when
  #     the manifest lists it.
  make_verify_pkg "$WORK/pre-main" "@scope/pre-main" '{}'
  mv "$WORK/pre-main/npm/LICENSE" "$WORK/pre-main/npm/LEGAL.txt"
  (
    cd "$WORK/pre-main/npm" || exit 1
    jq '.files = ["index.js", "LEGAL.txt"]' package.json >package.json.tmp &&
      mv package.json.tmp package.json
  )
  run_verify "$WORK/pre-main" npm LEGAL.txt
  pre_rewrite_status=$VERIFY_STATUS
  (
    cd "$WORK/pre-main/npm" || exit 1
    jq '.files = ["index.js"]' package.json >package.json.tmp &&
      mv package.json.tmp package.json
  )
  run_verify "$WORK/pre-main" npm LEGAL.txt
  if [[ $pre_rewrite_status -eq 0 && $VERIFY_STATUS -ne 0 ]] &&
    grep -q 'missing from the main package tarball' "$WORK/pre-main/verify.err"; then
    pass
  else
    fail "a rewritten manifest that drops the license from files must fail verification (before=$pre_rewrite_status after=$VERIFY_STATUS err=$(cat "$WORK/pre-main/verify.err"))"
  fi

  # 15. A lifecycle script that prints its own JSON packlist must not
  #     contribute a stale LICENSE entry: only npm's outer publish result may
  #     supply the file list.
  make_verify_pkg "$WORK/script-json" "@scope/script-json" '{"prepack":"./prepack.sh"}'
  cat >"$WORK/script-json/npm/prepack.sh" <<'PREPACK'
#!/usr/bin/env bash
node -e 'console.log(JSON.stringify({files:[{path:"LICENSE"}]}, null, 2))'
rm -f LICENSE
PREPACK
  chmod +x "$WORK/script-json/npm/prepack.sh"
  run_verify "$WORK/script-json"
  if [[ $VERIFY_STATUS -ne 0 ]] &&
    grep -q 'JSON values' "$WORK/script-json/verify.err" &&
    grep -q 'npm stderr:' "$WORK/script-json/verify.err"; then
    pass
  else
    fail "lifecycle JSON must not be merged with the publish packlist and stderr must be included (status=$VERIFY_STATUS err=$(cat "$WORK/script-json/verify.err"))"
  fi

  # 16. A package literally named "files" must not be mistaken for a bare
  #     package object when npm keys its result by package name.
  make_verify_pkg "$WORK/package-named-files" "files" '{}'
  # "files" is a real package; use a version the registry cannot have.
  (
    cd "$WORK/package-named-files/npm" || exit 1
    jq '.version = "999.999.999"' package.json >package.json.tmp &&
      mv package.json.tmp package.json
  )
  run_verify "$WORK/package-named-files"
  if [[ $VERIFY_STATUS -eq 0 ]] &&
    grep -q 'includes LICENSE' "$WORK/package-named-files/verify.err"; then
    pass
  else
    fail "a package named 'files' must parse correctly (status=$VERIFY_STATUS err=$(cat "$WORK/package-named-files/verify.err"))"
  fi

  # 17. `npm version` runs the package's version lifecycle script. A version
  #     script that deletes the license must fail the shared check, because the
  #     preflight now runs npm version before verifying. Without that step the
  #     preflight would pass and publish-main would fail after the platform
  #     packages were already published.
  make_verify_pkg "$WORK/version-script" "@scope/version-script" \
    '{"version":"rm -f LICENSE"}'
  cp -R "$WORK/version-script" "$WORK/version-script-run"
  (
    cd "$WORK/version-script-run/npm" || exit 1
    npm version 9.9.9 --no-git-tag-version --allow-same-version
  ) >"$WORK/version-script-run/version.out" 2>"$WORK/version-script-run/version.err"
  version_status=$?
  run_verify "$WORK/version-script-run"
  if [[ $version_status -eq 0 && $VERIFY_STATUS -ne 0 ]] &&
    grep -q 'missing from the main package tarball' \
      "$WORK/version-script-run/verify.err"; then
    pass
  else
    fail "a version lifecycle script that deletes the license must fail verification (version=$version_status verify=$VERIFY_STATUS err=$(cat "$WORK/version-script-run/verify.err"); version err=$(cat "$WORK/version-script-run/version.err"))"
  fi
fi

echo "npm-publish-order: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
