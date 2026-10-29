#!/usr/bin/env bash
set -uo pipefail

# Tests for .github/actions/detect-license/detect-license.sh
# Run: bash test/test-detect-license.sh

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/actions/detect-license/detect-license.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# run_detect <workdir> <repository> [explicit] [npm-dir]
# Sets OUT, STATUS.
run_detect() {
  local dir="$1" repo="$2" explicit="${3:-}" npm_dir="${4:-npm}"
  OUT="$dir/output"
  : > "$OUT"
  (
    cd "$dir" || exit 1
    GITHUB_OUTPUT="$OUT" PATH="$dir/bin:$PATH" \
      bash "$SCRIPT" "$repo" "$explicit" "$npm_dir"
  ) > "$dir/stdout" 2> "$dir/stderr"
  STATUS=$?
}

# make_fake_gh <dir> [license] [status]
make_fake_gh() {
  local dir="$1" license="${2:-}" status="${3:-0}"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/gh" << EOF
#!/usr/bin/env bash
printf '%s\n' "$license"
exit $status
EOF
  chmod +x "$dir/bin/gh"
}

new_case() {
  init_case "$WORK" "$1"
  make_fake_gh "$DIR"
}

# 1. explicit license wins over manifest and API
new_case explicit-wins
mkdir -p "$DIR/npm"
echo '{"license":"MIT"}' > "$DIR/npm/package.json"
make_fake_gh "$DIR" "Apache-2.0"
run_detect "$DIR" owner/repo "GPL-3.0-or-later"
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=GPL-3.0-or-later" ]]; then
  pass
else
  fail "explicit license should win (status=$STATUS out=$(cat "$OUT"))"
fi

# 2. npm-dir package.json license
new_case npm-dir-manifest
mkdir -p "$DIR/npm"
echo '{"license":"GPL-3.0-or-later"}' > "$DIR/npm/package.json"
echo '{"license":"MIT"}' > "$DIR/package.json"
make_fake_gh "$DIR" "Apache-2.0"
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=GPL-3.0-or-later" ]]; then
  pass
else
  fail "npm-dir package.json license should win over root manifest (status=$STATUS out=$(cat "$OUT"))"
fi

# 3. legacy license object form
new_case license-object
mkdir -p "$DIR/npm"
echo '{"license":{"type":"BSD-3-Clause","url":"https://example.com"}}' > "$DIR/npm/package.json"
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=BSD-3-Clause" ]]; then
  pass
else
  fail "license object type should be read (status=$STATUS out=$(cat "$OUT"))"
fi

# 4. root package.json fallback when npm-dir has no manifest
new_case root-manifest
echo '{"license":"MPL-2.0"}' > "$DIR/package.json"
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=MPL-2.0" ]]; then
  pass
else
  fail "root package.json should be a fallback (status=$STATUS out=$(cat "$OUT"))"
fi

# 5. GitHub API fallback when manifests carry no license
new_case api-fallback
mkdir -p "$DIR/npm"
echo '{"name":"x"}' > "$DIR/npm/package.json"
make_fake_gh "$DIR" "GPL-3.0"
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=GPL-3.0" ]]; then
  pass
else
  fail "GitHub API should be the last fallback (status=$STATUS out=$(cat "$OUT"))"
fi

# 6. NOASSERTION from API is rejected, never emitted
new_case api-noassertion
make_fake_gh "$DIR" "NOASSERTION"
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -ne 0 && ! -s "$OUT" ]]; then
  pass
else
  fail "NOASSERTION must not be accepted (status=$STATUS out=$(cat "$OUT"))"
fi

# 7. empty detection fails, never defaults to MIT
new_case no-license
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -ne 0 && ! -s "$OUT" ]] && ! grep -q "MIT" "$DIR/stdout" "$DIR/stderr"; then
  pass
else
  fail "missing license must fail without MIT default (status=$STATUS out=$(cat "$OUT"))"
fi

# 8. explicit NOASSERTION is rejected
new_case explicit-noassertion
run_detect "$DIR" owner/repo "NOASSERTION"
if [[ $STATUS -ne 0 && ! -s "$OUT" ]]; then
  pass
else
  fail "explicit NOASSERTION must be rejected (status=$STATUS out=$(cat "$OUT"))"
fi

# 9. whitespace around explicit license is trimmed
new_case explicit-trim
run_detect "$DIR" owner/repo "  MIT  "
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=MIT" ]]; then
  pass
else
  fail "explicit license should be trimmed (status=$STATUS out=$(cat "$OUT"))"
fi

# 10. API failure with no manifests fails cleanly
new_case api-failure
make_fake_gh "$DIR" "" 1
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -ne 0 && ! -s "$OUT" ]]; then
  pass
else
  fail "API failure without manifests must fail (status=$STATUS out=$(cat "$OUT"))"
fi

# 11. legacy licenses array form
new_case licenses-array
mkdir -p "$DIR/npm"
echo '{"licenses":[{"type":"ISC"}]}' > "$DIR/npm/package.json"
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=ISC" ]]; then
  pass
else
  fail "licenses array type should be read (status=$STATUS out=$(cat "$OUT"))"
fi

# 12. npm-dir "." reads the root manifest once, correctly
new_case npm-dir-dot
echo '{"license":"Apache-2.0"}' > "$DIR/package.json"
run_detect "$DIR" owner/repo "" "."
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=Apache-2.0" ]]; then
  pass
else
  fail "npm-dir '.' should read the root package.json license (status=$STATUS out=$(cat "$OUT"))"
fi

# 12b. npm-dir "." makes a malformed root manifest fatal: the root package is
# the package being published, not unrelated tooling.
new_case npm-dir-dot-malformed
printf '{not json\n' > "$DIR/package.json"
make_fake_gh "$DIR" "Apache-2.0"
run_detect "$DIR" owner/repo "" "."
if [[ $STATUS -ne 0 && ! -s "$OUT" ]] &&
  grep -q "Could not parse package.json" "$DIR/stderr"; then
  pass
else
  fail "malformed root manifest with npm-dir '.' must fail (status=$STATUS out=$(cat "$OUT") err=$(cat "$DIR/stderr"))"
fi

# 13. npm-dir with trailing slash
new_case npm-dir-trailing-slash
mkdir -p "$DIR/npm"
echo '{"license":"Apache-2.0"}' > "$DIR/npm/package.json"
run_detect "$DIR" owner/repo "" "npm/"
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=Apache-2.0" ]]; then
  pass
else
  fail "npm-dir 'npm/' (trailing slash) should read npm/package.json license (status=$STATUS out=$(cat "$OUT"))"
fi

# 14. npm-dir manifest without license falls through to root manifest
new_case manifest-fallthrough
mkdir -p "$DIR/npm"
echo '{"name":"x"}' > "$DIR/npm/package.json"
echo '{"license":"MPL-2.0"}' > "$DIR/package.json"
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=MPL-2.0" ]]; then
  pass
else
  fail "licenseless npm-dir manifest should fall through to root package.json (status=$STATUS out=$(cat "$OUT"))"
fi

# 15. literal null from the GitHub API is rejected, never emitted
new_case api-null
make_fake_gh "$DIR" "null"
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -ne 0 && ! -s "$OUT" ]]; then
  pass
else
  fail "literal null license from API must be rejected (status=$STATUS out=$(cat "$OUT"))"
fi

# 16. compound and file-reference SPDX expressions are accepted
new_case explicit-spdx-expression
run_detect "$DIR" owner/repo "(MIT OR Apache-2.0)"
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=(MIT OR Apache-2.0)" ]]; then
  pass
else
  fail "compound SPDX expression should be accepted (status=$STATUS out=$(cat "$OUT") err=$(cat "$DIR/stderr"))"
fi

# 17. SEE LICENSE IN file reference is accepted
new_case explicit-see-license
run_detect "$DIR" owner/repo "SEE LICENSE IN LICENSE"
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=SEE LICENSE IN LICENSE" ]]; then
  pass
else
  fail "SEE LICENSE IN expression should be accepted (status=$STATUS out=$(cat "$OUT") err=$(cat "$DIR/stderr"))"
fi

# 18. shell metacharacters in an explicit license are rejected
new_case explicit-shell-metacharacters
run_detect "$DIR" owner/repo 'MIT; echo pwned'
if [[ $STATUS -ne 0 && ! -s "$OUT" ]] && grep -q "not a valid SPDX expression" "$DIR/stderr"; then
  pass
else
  fail "shell metacharacters in a license must be rejected (status=$STATUS out=$(cat "$OUT") err=$(cat "$DIR/stderr"))"
fi

# 19. control characters in an explicit license are rejected
new_case explicit-control-character
run_detect "$DIR" owner/repo $'MIT\nApache-2.0'
if [[ $STATUS -ne 0 && ! -s "$OUT" ]] && grep -q "control characters" "$DIR/stderr"; then
  pass
else
  fail "control characters in a license must be rejected (status=$STATUS out=$(cat "$OUT") err=$(cat "$DIR/stderr"))"
fi

# 20. malformed npm-dir manifest is fatal before any package is published
new_case malformed-npm-manifest
mkdir -p "$DIR/npm"
printf '{not json\n' > "$DIR/npm/package.json"
echo '{"license":"MPL-2.0"}' > "$DIR/package.json"
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -ne 0 && ! -s "$OUT" ]] &&
  grep -q "Could not parse npm/package.json" "$DIR/stderr"; then
  pass
else
  fail "malformed npm-dir manifest must fail (status=$STATUS out=$(cat "$OUT") err=$(cat "$DIR/stderr"))"
fi

# 21. malformed root manifest warns and falls through (root may be unrelated tooling)
new_case malformed-root-manifest
mkdir -p "$DIR/npm"
echo '{"name":"x"}' > "$DIR/npm/package.json"
printf '{not json\n' > "$DIR/package.json"
make_fake_gh "$DIR" "Apache-2.0"
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=Apache-2.0" ]] &&
  grep -q "::warning::Could not parse package.json" "$DIR/stderr"; then
  pass
else
  fail "malformed root manifest should warn and fall through (status=$STATUS out=$(cat "$OUT") err=$(cat "$DIR/stderr"))"
fi

# 21. API failure surfaces the captured error and an actionable hint
new_case api-error-message
mkdir -p "$DIR/bin"
cat > "$DIR/bin/gh" << 'EOF'
#!/usr/bin/env bash
echo "HTTP 403: API rate limit exceeded" >&2
exit 1
EOF
chmod +x "$DIR/bin/gh"
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -ne 0 && ! -s "$OUT" ]] &&
  grep -q "HTTP 403: API rate limit exceeded" "$DIR/stderr" &&
  grep -q "GH_TOKEN" "$DIR/stderr" &&
  grep -q "rate limit" "$DIR/stderr"; then
  pass
else
  fail "API failure should include the captured error and GH_TOKEN/rate-limit hint (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 22. SEE LICENSE IN with a path is accepted (npm file-reference syntax)
new_case explicit-see-license-path
run_detect "$DIR" owner/repo "SEE LICENSE IN ../LICENSE"
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=SEE LICENSE IN ../LICENSE" ]]; then
  pass
else
  fail "SEE LICENSE IN with a path should be accepted (status=$STATUS out=$(cat "$OUT") err=$(cat "$DIR/stderr"))"
fi

# 23. non-string license object values are ignored, not coerced
new_case license-object-nonstring
mkdir -p "$DIR/npm"
echo '{"license":{"type":false}}' > "$DIR/npm/package.json"
echo '{"license":"MIT"}' > "$DIR/package.json"
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=MIT" ]]; then
  pass
else
  fail "non-string license type should fall through to the next tier (status=$STATUS out=$(cat "$OUT"))"
fi

# 24. a legacy licenses array of strings is skipped without a bogus parse warning
new_case licenses-array-nonobject
mkdir -p "$DIR/npm"
echo '{"licenses":["MIT"]}' > "$DIR/npm/package.json"
echo '{"license":"MPL-2.0"}' > "$DIR/package.json"
run_detect "$DIR" owner/repo "" "npm"
if [[ $STATUS -eq 0 && "$(cat "$OUT")" == "license=MPL-2.0" ]] &&
  ! grep -q "Could not parse" "$DIR/stderr"; then
  pass
else
  fail "licenses array of strings should fall through without a parse warning (status=$STATUS out=$(cat "$OUT") err=$(cat "$DIR/stderr"))"
fi

echo "detect-license: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
