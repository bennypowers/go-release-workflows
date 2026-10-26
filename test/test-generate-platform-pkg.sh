#!/usr/bin/env bash
set -uo pipefail

# Tests for .github/actions/generate-platform-pkg/generate-platform-pkg.sh
# Run: bash test/test-generate-platform-pkg.sh

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/actions/generate-platform-pkg/generate-platform-pkg.sh"
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

new_case() {
  local name="$1"
  DIR="$WORK/$name"
  mkdir -p "$DIR"
}

# run_pkg <workdir> [license-file]
run_pkg() {
  local dir="$1" license_file="${2:-}"
  mkdir -p "$dir/platforms"
  (
    cd "$dir" || exit 1
    bash "$SCRIPT" myapp linux-x64 "@scope/myapp" v1.2.3 MIT linux x64 owner/repo "$license_file"
  ) > "$dir/stdout" 2> "$dir/stderr"
  STATUS=$?
  PKG_DIR="$dir/platforms/myapp-linux-x64"
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
if [[ $STATUS -ne 0 ]]; then
  pass
else
  fail "missing license file must fail the build"
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

echo "generate-platform-pkg: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
