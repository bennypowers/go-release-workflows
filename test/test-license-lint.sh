#!/usr/bin/env bash
set -uo pipefail

# Tests for .github/actions/license-lint/license-lint.sh
# Run: bash test/test-license-lint.sh

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/actions/license-lint/license-lint.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A deterministic stand-in for npm: `npm pack --dry-run --json` emits the paths
# listed in .packlist in the current directory, so the tests never depend on
# npm's own packlist rules.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/npm" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" != "pack" ]]; then
  echo "unexpected npm invocation: $*" >&2
  exit 1
fi
[[ -f .packlist ]] || { echo "no .packlist" >&2; exit 1; }
json='[{"files":['
first=1
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  [[ $first -eq 1 ]] || json+=','
  first=0
  json+="{\"path\":\"$path\"}"
done < .packlist
json+=']}]'
printf '%s\n' "$json"
FAKE
chmod +x "$WORK/bin/npm"

# run_lint <workdir> [npm-dir] [license-file] [license] [platforms-dir] [npm-mode]
run_lint() {
  local dir="$1" npm_dir="${2:-npm}" license_file="${3:-}" license="${4:-}"
  local platforms_dir="${5:-platforms}" npm_mode="${6:-auto}"
  OUT="$dir/output"
  : > "$OUT"
  (
    cd "$dir" || exit 1
    PATH="$WORK/bin:$PATH" GITHUB_OUTPUT="$OUT" bash "$SCRIPT" \
      "$npm_dir" "$license_file" "$license" "$platforms_dir" "$npm_mode"
  ) > "$dir/stdout" 2> "$dir/stderr"
  STATUS=$?
}

new_case() {
  init_case "$WORK" "$1"
  mkdir -p "$DIR/npm"
  printf 'MIT License\n' > "$DIR/LICENSE"
  printf '{"name":"@scope/app","version":"1.0.0","license":"MIT"}\n' > "$DIR/npm/package.json"
  printf 'LICENSE\npackage.json\n' > "$DIR/npm/.packlist"
}

new_platform() {
  local name="$1"
  mkdir -p "$DIR/platforms/$name"
  printf '{"name":"@scope/app-linux-x64","version":"1.0.0","license":"MIT"}\n' \
    > "$DIR/platforms/$name/package.json"
  printf 'LICENSE\npackage.json\napp\n' > "$DIR/platforms/$name/.packlist"
}

# 1. clean package and platform package pass
new_case passes
new_platform app-linux-x64
cp "$DIR/LICENSE" "$DIR/platforms/app-linux-x64/LICENSE"
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] &&
  grep -qx 'license=MIT' "$OUT" &&
  grep -qx 'license-file=LICENSE' "$OUT" &&
  grep -qx 'platform-packages=1' "$OUT"; then
  pass
else
  fail "clean layout should pass (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 2. missing license file fails
new_case missing-license
rm "$DIR/LICENSE"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'No license file found' "$DIR/stderr"; then
  pass
else
  fail "missing license file must fail (status=$STATUS)"
fi

# 3. empty license file fails
new_case empty-license
: > "$DIR/LICENSE"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]]; then
  pass
else
  fail "empty license file must fail"
fi

# 4. ambiguous license files fail
new_case ambiguous
printf 'Apache License\n' > "$DIR/COPYING"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'Multiple license files found' "$DIR/stderr"; then
  pass
else
  fail "ambiguous license files must fail (status=$STATUS)"
fi

# 5. manifest without a license fails when there is no root fallback
new_case no-manifest-license
printf '{"name":"@scope/app","version":"1.0.0"}\n' > "$DIR/npm/package.json"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'no SPDX license found' "$DIR/stderr"; then
  pass
else
  fail "manifest without license must fail (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 6. explicit license that disagrees with the manifest fails
new_case license-mismatch
run_lint "$DIR" npm "" Apache-2.0
if [[ $STATUS -ne 0 ]] && grep -q 'does not match' "$DIR/stderr"; then
  pass
else
  fail "explicit/manifest license mismatch must fail (status=$STATUS)"
fi

# 7. invalid SPDX expression fails
new_case invalid-spdx
printf '{"name":"@scope/app","version":"1.0.0","license":"MIT OR (:"}\n' > "$DIR/npm/package.json"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'not a valid SPDX expression' "$DIR/stderr"; then
  pass
else
  fail "invalid SPDX expression must fail (status=$STATUS)"
fi

# 8. license missing from the main tarball fails
new_case main-packlist
printf 'package.json\n' > "$DIR/npm/.packlist"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'main package tarball would not include LICENSE' "$DIR/stderr"; then
  pass
else
  fail "license missing from main packlist must fail (status=$STATUS)"
fi

# 9. platform package without the license file fails
new_case platform-missing
new_platform app-linux-x64
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'does not contain LICENSE' "$DIR/stderr"; then
  pass
else
  fail "platform package without license must fail (status=$STATUS)"
fi

# 10. platform license not in its packlist fails
new_case platform-packlist
new_platform app-linux-x64
cp "$DIR/LICENSE" "$DIR/platforms/app-linux-x64/LICENSE"
printf 'package.json\napp\n' > "$DIR/platforms/app-linux-x64/.packlist"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'tarball would not include LICENSE' "$DIR/stderr"; then
  pass
else
  fail "platform license outside its packlist must fail (status=$STATUS)"
fi

# 11. symlinked platform license fails
new_case platform-symlink
new_platform app-linux-x64
ln -s "$DIR/LICENSE" "$DIR/platforms/app-linux-x64/LICENSE"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'is a symlink' "$DIR/stderr"; then
  pass
else
  fail "symlinked platform license must fail (status=$STATUS)"
fi

# 12. platform package publishing a different license fails
new_case platform-license-mismatch
new_platform app-linux-x64
cp "$DIR/LICENSE" "$DIR/platforms/app-linux-x64/LICENSE"
printf '{"name":"@scope/app-linux-x64","version":"1.0.0","license":"Apache-2.0"}\n' \
  > "$DIR/platforms/app-linux-x64/package.json"
run_lint "$DIR"
if [[ $STATUS -ne 0 ]] && grep -q 'publishes' "$DIR/stderr"; then
  pass
else
  fail "platform license mismatch must fail (status=$STATUS)"
fi

# 13. absent platforms directory is skipped, not an error
new_case no-platforms
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] && grep -qx 'platform-packages=0' "$OUT"; then
  pass
else
  fail "absent platforms dir should pass with zero packages (status=$STATUS)"
fi

# 14. custom license-file and npm-dir are honored
new_case custom-paths
mkdir -p "$DIR/pkg" "$DIR/legal"
printf 'Apache License\n' > "$DIR/legal/COPYING.txt"
printf '{"name":"@scope/app","version":"1.0.0","license":"Apache-2.0"}\n' > "$DIR/pkg/package.json"
printf 'COPYING.txt\npackage.json\n' > "$DIR/pkg/.packlist"
run_lint "$DIR" pkg legal/COPYING.txt "" platforms
if [[ $STATUS -eq 0 ]] && grep -qx 'license-file=COPYING.txt' "$OUT"; then
  pass
else
  fail "custom npm-dir and license-file should pass (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 15. a project without npm packages passes with a license file (auto)
new_case no-npm-auto
rm -rf "$DIR/npm"
printf '{"name":"repo","private":true}\n' > "$DIR/package.json"
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] &&
  grep -qx 'license-file=LICENSE' "$OUT" &&
  grep -qx 'platform-packages=0' "$OUT" &&
  grep -q 'linting the repository license only' "$DIR/stderr"; then
  pass
else
  fail "repository without npm packages should pass in auto mode (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 16. a project without npm packages passes with no npm metadata at all
new_case no-npm-no-metadata
rm -rf "$DIR/npm" "$DIR/package.json"
run_lint "$DIR"
if [[ $STATUS -eq 0 ]] && grep -q 'no SPDX metadata found' "$DIR/stderr"; then
  pass
else
  fail "repository without npm or SPDX metadata should still lint its license file (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 17. npm-mode=required fails when there is no package manifest
new_case no-npm-required
rm -rf "$DIR/npm"
run_lint "$DIR" npm "" "" platforms required
if [[ $STATUS -ne 0 ]] && grep -q 'npm-mode=required' "$DIR/stderr"; then
  pass
else
  fail "npm-mode=required without a manifest must fail (status=$STATUS)"
fi

# 18. npm-mode=none skips npm checks even when a broken package exists
new_case npm-none
printf '{"name":"@scope/app","version":"1.0.0"}\n' > "$DIR/npm/package.json"
run_lint "$DIR" npm "" "" platforms none
if [[ $STATUS -eq 0 ]] && grep -q 'skipped npm package checks' "$DIR/stderr"; then
  pass
else
  fail "npm-mode=none should skip npm checks (status=$STATUS stderr=$(cat "$DIR/stderr"))"
fi

# 19. an unknown npm-mode is rejected
new_case npm-mode-invalid
run_lint "$DIR" npm "" "" platforms sometimes
if [[ $STATUS -eq 2 ]] && grep -q 'npm-mode must be auto, required, or none' "$DIR/stderr"; then
  pass
else
  fail "unknown npm-mode must be rejected with exit 2 (status=$STATUS)"
fi

echo "license-lint: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
