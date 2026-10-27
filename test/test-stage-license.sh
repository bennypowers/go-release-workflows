#!/usr/bin/env bash
set -uo pipefail

# Tests for .github/actions/stage-license/stage-license.sh
# Run: bash test/test-stage-license.sh

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/actions/stage-license/stage-license.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# run_stage <workdir> [npm-dir] [license-file]
run_stage() {
  local dir="$1" npm_dir="${2:-npm}" license_file="${3:-}"
  OUT="$dir/output"
  : > "$OUT"
  (
    cd "$dir" || exit 1
    GITHUB_OUTPUT="$OUT" bash "$SCRIPT" "$npm_dir" "$license_file"
  ) > "$dir/stdout" 2> "$dir/stderr"
  STATUS=$?
}

new_case() {
  init_case "$WORK" "$1"
  mkdir -p "$DIR/npm"
}

# 1. LICENSE is copied into npm-dir as a real file and reported
new_case copies-license
printf 'MIT License\n' > "$DIR/LICENSE"
run_stage "$DIR"
if [[ $STATUS -eq 0 && -f "$DIR/npm/LICENSE" && ! -L "$DIR/npm/LICENSE" ]] &&
  cmp -s "$DIR/LICENSE" "$DIR/npm/LICENSE" &&
  grep -qx "license-file=LICENSE" "$OUT"; then
  pass
else
  fail "LICENSE should be copied into npm-dir and reported (status=$STATUS out=$(cat "$OUT"))"
fi

# 2. a license already in npm-dir wins
new_case existing-license
printf 'MIT License\n' > "$DIR/LICENSE"
printf 'Apache License\n' > "$DIR/npm/LICENSE"
run_stage "$DIR"
if [[ $STATUS -eq 0 ]] && cmp -s "$DIR/npm/LICENSE" <(printf 'Apache License\n'); then
  pass
else
  fail "an existing npm-dir license must not be overwritten"
fi

# 3. explicit license-file path is honored
new_case explicit-file
mkdir -p "$DIR/legal"
printf 'Apache License\n' > "$DIR/legal/COPYING.txt"
run_stage "$DIR" npm legal/COPYING.txt
if [[ $STATUS -eq 0 && -f "$DIR/npm/COPYING.txt" ]] &&
  cmp -s "$DIR/legal/COPYING.txt" "$DIR/npm/COPYING.txt"; then
  pass
else
  fail "explicit license-file should be staged (status=$STATUS)"
fi

# 4. lowercase license name is discovered
new_case lowercase
printf 'MIT License\n' > "$DIR/license"
run_stage "$DIR"
if [[ $STATUS -eq 0 && -f "$DIR/npm/license" ]]; then
  pass
else
  fail "lowercase license should be discovered (status=$STATUS)"
fi

# 5. missing license fails
new_case missing-license
run_stage "$DIR"
if [[ $STATUS -ne 0 && ! -f "$DIR/npm/LICENSE" ]] &&
  grep -q "No license file found" "$DIR/stderr"; then
  pass
else
  fail "missing license must fail with an actionable error (status=$STATUS)"
fi

# 6. empty license fails
new_case empty-license
: > "$DIR/LICENSE"
run_stage "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q "License file is empty" "$DIR/stderr"; then
  pass
else
  fail "empty license must not be staged (status=$STATUS)"
fi

# 7. missing npm-dir fails
new_case missing-npm-dir
rmdir "$DIR/npm"
printf 'MIT License\n' > "$DIR/LICENSE"
run_stage "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q "npm directory not found" "$DIR/stderr"; then
  pass
else
  fail "missing npm-dir must fail (status=$STATUS)"
fi

# 8. multiple license candidates require an explicit choice
new_case multiple-license-candidates
printf 'MIT License\n' > "$DIR/LICENSE-MIT"
printf 'Apache License\n' > "$DIR/LICENSE-APACHE"
run_stage "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q "Multiple license files" "$DIR/stderr"; then
  pass
else
  fail "multiple license candidates must fail with an actionable error (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 9. explicit license-file disambiguates multiple candidates
new_case multiple-license-explicit
printf 'MIT License\n' > "$DIR/LICENSE-MIT"
printf 'Apache License\n' > "$DIR/LICENSE-APACHE"
run_stage "$DIR" npm LICENSE-APACHE
if [[ $STATUS -eq 0 && -f "$DIR/npm/LICENSE-APACHE" ]] &&
  cmp -s "$DIR/LICENSE-APACHE" "$DIR/npm/LICENSE-APACHE"; then
  pass
else
  fail "explicit license-file should choose one candidate (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 10. a differently named license already in npm-dir wins over staging the root one
new_case existing-different-name
printf 'MIT License\n' > "$DIR/LICENSE"
printf 'Apache License\n' > "$DIR/npm/LICENCE.md"
run_stage "$DIR"
if [[ $STATUS -eq 0 ]] && [[ ! -f "$DIR/npm/LICENSE" ]] &&
  cmp -s "$DIR/npm/LICENCE.md" <(printf 'Apache License\n') &&
  grep -qx "license-file=LICENCE.md" "$OUT"; then
  pass
else
  fail "an existing npm-dir license must not be joined by a second one (status=$STATUS files=$(ls "$DIR/npm") out=$(cat "$OUT"))"
fi

# 11. a symlinked license in npm-dir is replaced with a real file
new_case symlinked-npm-license
printf 'MIT License\n' > "$DIR/LICENSE"
ln -s "$DIR/LICENSE" "$DIR/npm/LICENSE"
run_stage "$DIR"
if [[ $STATUS -eq 0 && -f "$DIR/npm/LICENSE" && ! -L "$DIR/npm/LICENSE" ]] &&
  cmp -s "$DIR/LICENSE" "$DIR/npm/LICENSE"; then
  pass
else
  fail "a symlinked npm-dir license must be replaced by a real copy (status=$STATUS)"
fi

# 12. an empty license in npm-dir does not suppress staging a real one
new_case empty-npm-license
printf 'MIT License\n' > "$DIR/LICENSE"
: > "$DIR/npm/LICENSE"
run_stage "$DIR"
if [[ $STATUS -eq 0 && -s "$DIR/npm/LICENSE" ]] &&
  cmp -s "$DIR/LICENSE" "$DIR/npm/LICENSE"; then
  pass
else
  fail "an empty npm-dir license must be replaced by the repository license (status=$STATUS)"
fi

echo "stage-license: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
