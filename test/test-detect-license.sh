#!/usr/bin/env bash
set -uo pipefail

# Tests for .github/actions/detect-license/detect-license.sh
# Run: bash test/test-detect-license.sh

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/actions/detect-license/detect-license.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

fail() {
  echo "FAIL: $1" >&2
  FAIL=$((FAIL + 1))
}

pass() {
  PASS=$((PASS + 1))
}

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
  local name="$1"
  DIR="$WORK/$name"
  mkdir -p "$DIR"
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

echo "detect-license: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
