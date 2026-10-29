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

# run_stage_timeout <seconds> <workdir> [npm-dir] [license-file]
# Like run_stage, but bounds the run so a FIFO license entry cannot hang the
# suite before the script learns to reject it.
run_stage_timeout() {
  local seconds="$1" dir="$2" npm_dir="${3:-npm}" license_file="${4:-}"
  OUT="$dir/output"
  : > "$OUT"
  (
    cd "$dir" || exit 1
    GITHUB_OUTPUT="$OUT" timeout -k 2 "$seconds" bash "$SCRIPT" "$npm_dir" "$license_file"
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

# 13. files that merely share a LICENSE prefix are not licenses
new_case non-license-prefixes
printf 'MIT License\n' > "$DIR/LICENSE"
printf 'console.log(1)\n' > "$DIR/LICENSE-check.js"
printf 'third-party header\n' > "$DIR/LICENSE-HEADER.txt"
printf 'third-party notices\n' > "$DIR/LICENSE-THIRD-PARTY"
run_stage "$DIR"
if [[ $STATUS -eq 0 && -f "$DIR/npm/LICENSE" ]] &&
  cmp -s "$DIR/LICENSE" "$DIR/npm/LICENSE" &&
  [[ ! -e "$DIR/npm/LICENSE-check.js" && ! -e "$DIR/npm/LICENSE-HEADER.txt" &&
    ! -e "$DIR/npm/LICENSE-THIRD-PARTY" ]]; then
  pass
else
  fail "LICENSE-prefixed non-license files must be ignored (status=$STATUS files=$(ls "$DIR/npm") err=$(cat "$DIR/stderr"))"
fi

# 14. a LICENSE-prefixed non-license file is not staged when no license exists
new_case only-non-license
printf 'console.log(1)\n' > "$DIR/LICENSE-check.js"
run_stage "$DIR"
if [[ $STATUS -ne 0 && ! -e "$DIR/npm/LICENSE-check.js" ]] &&
  grep -q "No license file found" "$DIR/stderr"; then
  pass
else
  fail "license-check.js must not satisfy the license requirement (status=$STATUS files=$(ls "$DIR/npm"))"
fi

# 15. mixed-case conventional names are discovered
for mixed in License Licence License.md Copying; do
  new_case "mixed-case-${mixed//./-}"
  printf 'MIT License\n' > "$DIR/$mixed"
  run_stage "$DIR"
  if [[ $STATUS -eq 0 && -f "$DIR/npm/$mixed" ]] &&
    cmp -s "$DIR/$mixed" "$DIR/npm/$mixed"; then
    pass
  else
    fail "mixed-case $mixed should be discovered (status=$STATUS files=$(ls "$DIR/npm") err=$(cat "$DIR/stderr"))"
  fi
done

# 16. the same inode reached through two names is one candidate, not ambiguity.
# On a case-insensitive filesystem the OS reports one entry; hard links model
# the duplicate inode on Linux without requiring such a filesystem.
new_case inode-dedupe-root
printf 'MIT License\n' > "$DIR/LICENSE"
ln "$DIR/LICENSE" "$DIR/License"
run_stage "$DIR"
if [[ $STATUS -eq 0 ]] && [[ $(find "$DIR/npm" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 ]]; then
  pass
else
  fail "hard-linked LICENSE/License must not report false ambiguity (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 17. the same inode in npm-dir is one candidate, not ambiguity
new_case inode-dedupe-npm
printf 'MIT License\n' > "$DIR/LICENSE"
printf 'Apache License\n' > "$DIR/npm/LICENSE"
ln "$DIR/npm/LICENSE" "$DIR/npm/Licence"
run_stage "$DIR"
if [[ $STATUS -eq 0 ]] &&
  [[ $(find "$DIR/npm" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 ]] &&
  cmp -s "$DIR/npm/LICENSE" <(printf 'Apache License\n'); then
  pass
else
  fail "hard-linked npm-dir licenses must collapse to one (status=$STATUS err=$(cat "$DIR/stderr") files=$(ls "$DIR/npm"))"
fi

# 18. a symlinked npm license keeps its target's text, not the root license's
new_case symlink-keeps-target
mkdir -p "$DIR/legal"
printf 'MIT License\n' > "$DIR/LICENSE"
printf 'Apache License\n' > "$DIR/legal/APACHE"
ln -s ../legal/APACHE "$DIR/npm/LICENSE"
run_stage "$DIR"
if [[ $STATUS -eq 0 && -f "$DIR/npm/LICENSE" && ! -L "$DIR/npm/LICENSE" ]] &&
  cmp -s "$DIR/npm/LICENSE" <(printf 'Apache License\n'); then
  pass
else
  fail "a symlinked npm license must keep its target text (status=$STATUS content=$(cat "$DIR/npm/LICENSE" 2>/dev/null) err=$(cat "$DIR/stderr"))"
fi

# 19. a dangling npm license symlink fails instead of swapping in the root license
new_case symlink-dangling
printf 'MIT License\n' > "$DIR/LICENSE"
ln -s ../legal/MISSING "$DIR/npm/LICENSE"
run_stage "$DIR"
if [[ $STATUS -ne 0 ]] && grep -qi "missing\|broken" "$DIR/stderr" &&
  cmp -s "$DIR/LICENSE" <(printf 'MIT License\n'); then
  pass
else
  fail "a dangling npm license symlink must fail actionably (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 20. a symlink to an empty target fails
new_case symlink-empty-target
mkdir -p "$DIR/legal"
printf 'MIT License\n' > "$DIR/LICENSE"
: > "$DIR/legal/EMPTY"
ln -s ../legal/EMPTY "$DIR/npm/LICENSE"
run_stage "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q "empty" "$DIR/stderr"; then
  pass
else
  fail "a symlink to an empty license must fail (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 21. an empty differently named npm license is removed when the root license is staged
new_case empty-different-name-replaced
printf 'MIT License\n' > "$DIR/LICENSE"
: > "$DIR/npm/LICENCE.md"
run_stage "$DIR"
if [[ $STATUS -eq 0 && -f "$DIR/npm/LICENSE" ]] &&
  cmp -s "$DIR/npm/LICENSE" "$DIR/LICENSE" &&
  [[ ! -e "$DIR/npm/LICENCE.md" ]] &&
  [[ $(find "$DIR/npm" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 ]]; then
  pass
else
  fail "an empty differently named npm license must not be left beside the staged one (status=$STATUS files=$(ls "$DIR/npm"))"
fi

# 22. more than one non-empty npm license is ambiguous, not first-by-sort
new_case multiple-npm-licenses
printf 'MIT License\n' > "$DIR/LICENSE"
printf 'Apache License\n' > "$DIR/npm/LICENSE"
printf 'BSD License\n' > "$DIR/npm/LICENCE"
run_stage "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q "Multiple license files" "$DIR/stderr"; then
  pass
else
  fail "two non-empty npm licenses must fail rather than pick one (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 23. an explicit license-file wins over an existing npm-dir license
new_case explicit-wins-over-existing
mkdir -p "$DIR/legal"
printf 'MIT License\n' > "$DIR/LICENSE"
printf 'Apache License\n' > "$DIR/npm/LICENSE"
printf 'GPL License\n' > "$DIR/legal/COPYING"
run_stage "$DIR" npm legal/COPYING
if [[ $STATUS -eq 0 && -f "$DIR/npm/COPYING" && ! -e "$DIR/npm/LICENSE" ]] &&
  cmp -s "$DIR/npm/COPYING" "$DIR/legal/COPYING" &&
  [[ $(find "$DIR/npm" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 ]] &&
  grep -qx "license-file=COPYING" "$OUT"; then
  pass
else
  fail "an explicit license-file must win over an existing npm-dir license (status=$STATUS files=$(ls "$DIR/npm") err=$(cat "$DIR/stderr"))"
fi

# 24. an explicit license-file with the same name replaces the existing content
new_case explicit-same-name
mkdir -p "$DIR/legal"
printf 'MIT License\n' > "$DIR/LICENSE"
printf 'Apache License\n' > "$DIR/npm/LICENSE"
printf 'GPL License\n' > "$DIR/legal/LICENSE"
run_stage "$DIR" npm legal/LICENSE
if [[ $STATUS -eq 0 ]] && cmp -s "$DIR/npm/LICENSE" "$DIR/legal/LICENSE" &&
  [[ $(find "$DIR/npm" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 ]]; then
  pass
else
  fail "an explicit license-file must replace a same-named npm license (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 25. success logging goes to stderr so stdout stays clean
new_case stderr-logging
printf 'MIT License\n' > "$DIR/LICENSE"
run_stage "$DIR"
if [[ $STATUS -eq 0 && ! -s "$DIR/stdout" ]] && grep -q "Staged" "$DIR/stderr"; then
  pass
else
  fail "success logging must go to stderr (status=$STATUS stdout=$(cat "$DIR/stdout") stderr=$(cat "$DIR/stderr"))"
fi

# 26. a license filename containing a newline is rejected
new_case newline-filename
printf 'MIT License\n' > "$DIR/"$'LICENSE\nX'
run_stage "$DIR" npm $'LICENSE\nX'
if [[ $STATUS -ne 0 ]] && grep -q "control characters" "$DIR/stderr"; then
  pass
else
  fail "a license filename containing a newline must be rejected (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 27. a directory named LICENSE in npm-dir is rejected, not used as a cp target
# (cp would otherwise exit 0 after writing the staged file inside the directory).
new_case npm-license-directory
printf 'MIT License\n' > "$DIR/LICENSE"
mkdir "$DIR/npm/LICENSE"
run_stage "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q "not a regular file" "$DIR/stderr" &&
  [[ $(find "$DIR/npm" -mindepth 1 -maxdepth 2 | wc -l) -eq 1 ]]; then
  pass
else
  fail "a directory named LICENSE in npm-dir must fail without writing into it (status=$STATUS entries=$(find "$DIR/npm" -mindepth 1 -maxdepth 2) err=$(cat "$DIR/stderr"))"
fi

# 28. a FIFO named LICENSE in npm-dir is rejected instead of blocking forever.
# Skip when the platform cannot create one or has no timeout.
new_case npm-license-fifo
printf 'MIT License\n' > "$DIR/LICENSE"
if ! command -v mkfifo >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1 ||
  ! mkfifo "$DIR/npm/LICENSE" 2>/dev/null; then
  echo "SKIP: mkfifo or timeout unavailable" >&2
  pass
else
  run_stage_timeout 10 "$DIR"
  if [[ $STATUS -ne 0 && $STATUS -ne 124 ]] &&
    grep -q "not a regular file" "$DIR/stderr" && [[ -p "$DIR/npm/LICENSE" ]]; then
    pass
  else
    fail "a FIFO named LICENSE in npm-dir must be rejected, not block (status=$STATUS err=$(cat "$DIR/stderr"))"
  fi
fi

# 29. the staged license is world-readable, not the 0600 of the mktemp snapshot
new_case staged-mode
printf 'MIT License\n' > "$DIR/LICENSE"
run_stage "$DIR"
mode=$(stat -c '%a' "$DIR/npm/LICENSE" 2>/dev/null || stat -f '%Lp' "$DIR/npm/LICENSE" 2>/dev/null)
if [[ $STATUS -eq 0 && "$mode" == "644" ]]; then
  pass
else
  fail "the staged license must be mode 0644 (status=$STATUS mode=$mode)"
fi

# 30. a dangling root license symlink is diagnosed, not called empty
new_case root-symlink-dangling
ln -s "$DIR/legal/MISSING" "$DIR/LICENSE"
run_stage "$DIR"
if [[ $STATUS -ne 0 ]] && grep -qi "broken" "$DIR/stderr" &&
  ! grep -q "License file is empty" "$DIR/stderr"; then
  pass
else
  fail "a dangling root license symlink must be reported as broken (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 31. a root license symlink pointing at a directory is diagnosed
new_case root-symlink-directory
mkdir -p "$DIR/legal"
ln -s legal "$DIR/LICENSE"
run_stage "$DIR"
if [[ $STATUS -ne 0 ]] &&
  grep -q "does not point to a regular file" "$DIR/stderr" &&
  ! grep -q "License file is empty" "$DIR/stderr"; then
  pass
else
  fail "a root license symlink to a directory must be diagnosed (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 32. a root license symlink loop is diagnosed, not called empty
new_case root-symlink-loop
ln -s LICENSE "$DIR/LICENSE"
run_stage "$DIR"
if [[ $STATUS -ne 0 ]] && grep -qi "broken" "$DIR/stderr" &&
  ! grep -q "License file is empty" "$DIR/stderr"; then
  pass
else
  fail "a looping root license symlink must be reported as broken (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 33. an SPDX-suffixed license may carry one conventional extension
new_case spdx-suffix-extension
printf 'MIT License\n' > "$DIR/LICENSE-MIT.md"
run_stage "$DIR"
if [[ $STATUS -eq 0 && -f "$DIR/npm/LICENSE-MIT.md" ]] &&
  cmp -s "$DIR/LICENSE-MIT.md" "$DIR/npm/LICENSE-MIT.md" &&
  grep -qx "license-file=LICENSE-MIT.md" "$OUT"; then
  pass
else
  fail "LICENSE-MIT.md must be discovered and staged (status=$STATUS files=$(ls "$DIR/npm") err=$(cat "$DIR/stderr"))"
fi

# 34. adding an extension does not let two SPDX licenses slip past ambiguity
new_case spdx-suffix-extension-ambiguous
printf 'MIT License\n' > "$DIR/LICENSE-MIT.md"
printf 'Apache License\n' > "$DIR/LICENSE-APACHE"
run_stage "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q "Multiple license files" "$DIR/stderr"; then
  pass
else
  fail "LICENSE-MIT.md plus LICENSE-APACHE must still be ambiguous (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

echo "stage-license: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
