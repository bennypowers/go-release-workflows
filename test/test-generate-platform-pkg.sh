#!/usr/bin/env bash
set -uo pipefail

# Tests for .github/actions/generate-platform-pkg/generate-platform-pkg.sh
# Run: bash test/test-generate-platform-pkg.sh

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/actions/generate-platform-pkg/generate-platform-pkg.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

new_case() {
  init_case "$WORK" "$1"
}

# run_pkg <workdir> [license-file] [binary] [platform] [package-name] [os] [cpu]
run_pkg() {
  local dir="$1" license_file="${2:-}"
  local binary="${3:-myapp}" platform="${4:-linux-x64}" package_name="${5:-@scope/myapp}"
  local os="${6:-linux}" cpu="${7:-x64}"
  mkdir -p "$dir/platforms"
  : > "$dir/github_output"
  (
    cd "$dir" || exit 1
    GITHUB_OUTPUT="$dir/github_output" bash "$SCRIPT" "$binary" "$platform" "$package_name" v1.2.3 MIT "$os" "$cpu" owner/repo "$license_file"
  ) > "$dir/stdout" 2> "$dir/stderr"
  STATUS=$?
  PKG_DIR="$dir/platforms/${binary}-${platform}"
}

# 1. LICENSE is copied as a real file, not a symlink
new_case copies-license
printf 'MIT License\n' > "$DIR/LICENSE"
run_pkg "$DIR"
if [[ $STATUS -eq 0 && -f "$PKG_DIR/LICENSE" && ! -L "$PKG_DIR/LICENSE" ]] &&
  cmp -s "$DIR/LICENSE" "$PKG_DIR/LICENSE"; then
  pass
else
  fail "LICENSE should be copied as a regular file (status=$STATUS dir=$(ls -la "$PKG_DIR" 2>&1))"
fi

# 2. license file is listed in package.json files
new_case lists-license
printf 'MIT License\n' > "$DIR/LICENSE"
run_pkg "$DIR"
if [[ $STATUS -eq 0 ]] && jq -e '.files | index("LICENSE")' "$PKG_DIR/package.json" >/dev/null; then
  pass
else
  fail "LICENSE should be listed in package.json files (status=$STATUS)"
fi

# 3. LICENSE.md is discovered
new_case license-md
printf 'MIT License\n' > "$DIR/LICENSE.md"
run_pkg "$DIR"
if [[ $STATUS -eq 0 && -f "$PKG_DIR/LICENSE.md" ]] &&
  jq -e '.files | index("LICENSE.md")' "$PKG_DIR/package.json" >/dev/null; then
  pass
else
  fail "LICENSE.md should be discovered and listed (status=$STATUS)"
fi

# 4. LICENCE spelling is discovered
new_case licence-spelling
printf 'MIT License\n' > "$DIR/LICENCE"
run_pkg "$DIR"
if [[ $STATUS -eq 0 && -f "$PKG_DIR/LICENCE" ]]; then
  pass
else
  fail "LICENCE spelling should be discovered (status=$STATUS)"
fi

# 4b. lowercase license filename is discovered
new_case lowercase-license
printf 'MIT License\n' > "$DIR/license"
run_pkg "$DIR"
if [[ $STATUS -eq 0 && -f "$PKG_DIR/license" ]]; then
  pass
else
  fail "lowercase license filename should be discovered (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 4c. a lowercase non-license file with the same prefix is not treated as a license
new_case lowercase-non-license
printf 'console.log(1)\n' > "$DIR/license-check.js"
run_pkg "$DIR"
if [[ $STATUS -ne 0 && ! -f "$PKG_DIR/package.json" ]] &&
  grep -q "No license file found" "$DIR/stderr"; then
  pass
else
  fail "license-check.js must not be treated as the license (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 5. explicit license-file path is honored
new_case explicit-license-file
mkdir -p "$DIR/legal"
printf 'Apache License\n' > "$DIR/legal/COPYING.txt"
run_pkg "$DIR" "legal/COPYING.txt"
if [[ $STATUS -eq 0 && -f "$PKG_DIR/COPYING.txt" ]] &&
  cmp -s "$DIR/legal/COPYING.txt" "$PKG_DIR/COPYING.txt"; then
  pass
else
  fail "explicit license-file should be copied (status=$STATUS)"
fi

# 6. missing license fails instead of publishing non-compliant package
new_case missing-license
run_pkg "$DIR"
if [[ $STATUS -ne 0 && ! -f "$PKG_DIR/package.json" ]] &&
  grep -q "No license file found" "$DIR/stderr"; then
  pass
else
  fail "missing license file must fail without writing package.json and print an actionable error (status=$STATUS pkgjson=$(ls "$PKG_DIR" 2>&1))"
fi

# 7. package metadata still correct
new_case metadata
printf 'MIT License\n' > "$DIR/LICENSE"
run_pkg "$DIR"
if [[ $STATUS -eq 0 ]] &&
  jq -e '.name == "@scope/myapp-linux-x64" and .version == "1.2.3" and .license == "MIT" and .os == ["linux"] and .cpu == ["x64"]' "$PKG_DIR/package.json" >/dev/null; then
  pass
else
  fail "package.json metadata should be preserved (status=$STATUS)"
fi

# 8. unscoped package on win32-x64
new_case unscoped-win32
printf 'MIT License\n' > "$DIR/LICENSE"
run_pkg "$DIR" "" myapp win32-x64 myapp win32 x64
if [[ $STATUS -eq 0 ]] &&
  jq -e '.name == "myapp-win32-x64" and .os == ["win32"] and .cpu == ["x64"]' "$PKG_DIR/package.json" >/dev/null; then
  pass
else
  fail "unscoped win32-x64 package should be named myapp-win32-x64 with os/cpu set (status=$STATUS)"
fi

# 9. license-file output is written for the workflow verifier
new_case license-file-output
printf 'MIT License\n' > "$DIR/LICENSE.md"
run_pkg "$DIR"
if [[ $STATUS -eq 0 && "$(cat "$DIR/github_output")" == "license-file=LICENSE.md" ]]; then
  pass
else
  fail "license-file output should name the copied license (status=$STATUS output=$(cat "$DIR/github_output" 2>&1))"
fi

# 10. empty explicit license file fails
new_case empty-explicit-license
mkdir -p "$DIR/legal"
: > "$DIR/legal/COPYING"
run_pkg "$DIR" "legal/COPYING"
if [[ $STATUS -ne 0 && ! -f "$PKG_DIR/package.json" ]] &&
  grep -q "License file is empty" "$DIR/stderr"; then
  pass
else
  fail "empty explicit license file must fail (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 11. empty auto-discovered license is skipped in favor of a non-empty one
new_case empty-auto-license-skipped
: > "$DIR/LICENSE"
printf 'MIT License\n' > "$DIR/LICENSE.md"
run_pkg "$DIR"
if [[ $STATUS -eq 0 && -s "$PKG_DIR/LICENSE.md" ]] &&
  jq -e '.files | index("LICENSE.md")' "$PKG_DIR/package.json" >/dev/null; then
  pass
else
  fail "empty LICENSE should be skipped in favor of LICENSE.md (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 12. an empty auto-discovered license alone still fails
new_case empty-auto-license-only
: > "$DIR/LICENSE"
run_pkg "$DIR"
if [[ $STATUS -ne 0 && ! -f "$PKG_DIR/package.json" ]] &&
  grep -q "License file is empty" "$DIR/stderr"; then
  pass
else
  fail "an empty license must not satisfy the license requirement (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 13. license filenames with control characters are rejected
new_case control-character-license-name
printf 'MIT License\n' > "$DIR/"$'LIC\nENSE'
run_pkg "$DIR" $'LIC\nENSE'
if [[ $STATUS -ne 0 && ! -f "$PKG_DIR/package.json" ]] &&
  grep -q "control characters" "$DIR/stderr"; then
  pass
else
  fail "control characters in the license filename must be rejected (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 14. package.json values are JSON-escaped
new_case json-escaping
printf 'MIT License\n' > "$DIR/LICENSE"
(
  cd "$DIR" || exit 1
  GITHUB_OUTPUT="$DIR/github_output" bash "$SCRIPT" 'my"app' linux-x64 'my"app' 'v1.2.3"x' 'MIT"quoted' linux x64 'own"er/repo'
) > "$DIR/stdout" 2> "$DIR/stderr"
STATUS=$?
PKG_DIR="$DIR/platforms/my\"app-linux-x64"
if [[ $STATUS -eq 0 ]] &&
  jq -e '.name == "my\"app-linux-x64" and .version == "1.2.3\"x" and .license == "MIT\"quoted" and .repository.url == "https://github.com/own\"er/repo"' "$PKG_DIR/package.json" >/dev/null; then
  pass
else
  fail "package.json should stay valid when values need JSON escaping (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 15. multiple license candidates require an explicit choice
new_case multiple-license-candidates
printf 'MIT License\n' > "$DIR/LICENSE-MIT"
printf 'Apache License\n' > "$DIR/LICENSE-APACHE"
run_pkg "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q "Multiple license files" "$DIR/stderr"; then
  pass
else
  fail "multiple license candidates must fail with an actionable error (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 15b. platform package name follows the main npm package, not the binary name
new_case npm-name-differs-from-binary
printf 'MIT License\n' > "$DIR/LICENSE"
run_pkg "$DIR" "" rhds-mcp linux-x64 "@rhds/mcp" linux x64
if [[ $STATUS -eq 0 ]] &&
  jq -e '.name == "@rhds/mcp-linux-x64"' "$PKG_DIR/package.json" >/dev/null; then
  pass
else
  fail "platform package should be named after the main npm package (@rhds/mcp-linux-x64), got $(jq -r '.name' "$PKG_DIR/package.json" 2>/dev/null) (status=$STATUS)"
fi

# 16. explicit license-file disambiguates multiple candidates
new_case multiple-license-explicit
printf 'MIT License\n' > "$DIR/LICENSE-MIT"
printf 'Apache License\n' > "$DIR/LICENSE-APACHE"
run_pkg "$DIR" LICENSE-MIT
if [[ $STATUS -eq 0 && -f "$PKG_DIR/LICENSE-MIT" ]] &&
  cmp -s "$DIR/LICENSE-MIT" "$PKG_DIR/LICENSE-MIT"; then
  pass
else
  fail "explicit license-file should choose one candidate (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 17. LICENSE-prefixed non-license files are ignored in favor of a real license
new_case non-license-prefixes
printf 'MIT License\n' > "$DIR/LICENSE"
printf 'header\n' > "$DIR/LICENSE-HEADER.txt"
printf 'notices\n' > "$DIR/LICENSE-THIRD-PARTY"
printf 'console.log(1)\n' > "$DIR/LICENSE-check.js"
run_pkg "$DIR"
if [[ $STATUS -eq 0 && -f "$PKG_DIR/LICENSE" ]] &&
  jq -e '.files | index("LICENSE")' "$PKG_DIR/package.json" >/dev/null &&
  [[ ! -e "$PKG_DIR/LICENSE-HEADER.txt" && ! -e "$PKG_DIR/LICENSE-THIRD-PARTY" &&
    ! -e "$PKG_DIR/LICENSE-check.js" ]]; then
  pass
else
  fail "LICENSE-prefixed non-license files must be ignored (status=$STATUS files=$(ls "$PKG_DIR" 2>/dev/null) err=$(cat "$DIR/stderr"))"
fi

# 18. a mixed-case conventional name is discovered
new_case mixed-case-license
printf 'MIT License\n' > "$DIR/License.md"
run_pkg "$DIR"
if [[ $STATUS -eq 0 && -f "$PKG_DIR/License.md" ]] &&
  jq -e '.files | index("License.md")' "$PKG_DIR/package.json" >/dev/null; then
  pass
else
  fail "License.md should be discovered (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

# 19. a hard-linked duplicate inode is not ambiguous
new_case inode-dedupe
printf 'MIT License\n' > "$DIR/LICENSE"
ln "$DIR/LICENSE" "$DIR/Licence"
run_pkg "$DIR"
if [[ $STATUS -eq 0 && -f "$PKG_DIR/LICENSE" ]] &&
  [[ $(find "$PKG_DIR" -mindepth 1 -maxdepth 1 -name 'LICEN*' | wc -l) -eq 1 ]]; then
  pass
else
  fail "a hard-linked default license must not report false ambiguity (status=$STATUS err=$(cat "$DIR/stderr"))"
fi

echo "generate-platform-pkg: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
